import ComputerMCPCore
import ComputerMCPEgress
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPProcess
import ComputerMCPSandbox
import ComputerMCPWorktrees
import Foundation
import GRDB

/// Owns durable launch reservations and their physical resources. All permission
/// decisions use the store; local handles only identify resources to terminate.
package final class ExecutionRevocationCoordinator: ExecutionRecoveryAuthorizing,
  @unchecked Sendable
{
  package typealias ProxyFactory =
    @Sendable (UUID, EgressPolicy, @escaping @Sendable (EgressDenial) -> Void) async throws ->
    EgressProxy
  private let store: SQLitePermissionStore
  private let launcher: ExecutionLauncher
  private let lease: FileLock
  private let ownerID: UUID
  private let permissionDiscovery: ExecutionPermissionDiscovery
  private let proxyFactory: ProxyFactory?
  private let journal: ExecutionRecoveryJournal
  private let storageDirectory: URL
  private let refreshPolicy: (@Sendable () throws -> Void)?
  private let lock = NSLock()
  private let publication = NSLock()
  private let reconciliation = ExecutionReconciliation()
  private let recovery = ExecutionReconciliation()
  private var ready = false
  private var recoveryStarted = false
  private var deliveredLimits: [UUID: EffectiveExecutionLimits] = [:]
  private var unpublishedRecovery: [UUID: ExecutionRecoveryState] = [:]
  private var limitObservers: [UUID: [@Sendable (EffectiveExecutionLimits) -> Void]] = [:]
  private var children: [UUID: any ExecutionOwnership] = [:]
  private var logicalWork: [UUID: ExecutionLogicalWork] = [:]
  private var pendingChildren: [UUID: Set<UUID>] = [:]
  private var closedAdmissions: Set<UUID> = []
  private var pendingAdmissionClosures: Set<UUID> = []
  private var pendingOwnerStops: Set<UUID> = []
  private var contexts: [UUID: WeakExecutionContext] = [:]
  private var proxies: [UUID: EgressProxy] = [:]
  private var monitoring: Task<Void, Never>?

  package init(
    store: SQLitePermissionStore, launcher: ExecutionLauncher, directory: URL,
    proxyFactory: ProxyFactory? = nil, refreshPolicy: (@Sendable () throws -> Void)? = nil
  ) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    self.store = store
    self.storageDirectory = try ProjectPathResolver.canonicalProject(directory)
    self.launcher = launcher
    self.proxyFactory = proxyFactory
    self.refreshPolicy = refreshPolicy
    let ownerID = UUID()
    self.ownerID = ownerID
    permissionDiscovery = ExecutionPermissionDiscovery(
      store: store, ownerID: ownerID, boot: launcher.bootSessionID, refreshPolicy: refreshPolicy)
    journal = try ExecutionRecoveryJournal(directory: directory.appendingPathComponent("ownership"))
    lease = try FileLock(
      path: directory.appendingPathComponent("executions.lock").path, mode: .exclusive)
  }

  deinit { monitoring?.cancel() }

  /// A lifetime lease excludes the previous host before its durable records are
  /// marked interrupted. No new execution or proxy is admitted during recovery.
  package func recover() async throws {
    try await recovery.run { [self] in
      do { try await recoverIfNeeded() } catch {
        lock.withLock { ready = false }
        throw error
      }
    }
  }

  private func recoverIfNeeded() async throws {
    guard !lock.withLock({ ready }) else { return }
    let epoch = try store.readWithDatabase { _, ledger in ledger.authorizationEpochID }
    let first = lock.withLock { !recoveryStarted }
    if first {
      try store.transactionWithDatabase { database, ledger in
        for var record in try ExecutionRuntimeRecord.all(database) where !record.completed {
          record.admissionFinished = true
          record.invocationInFlight = false
          record.workIDs = nil
          try record.auditIdentity?.record(
            "interrupted", executionID: record.id, database: database, decision: .failed)
          if ledger.executions[record.id] != nil { try ledger.interruptExecution(record.id) }
          try record.save(database)
        }
      }
      lock.withLock { recoveryStarted = true }
      startMonitoring()
    }
    try await reconcile()
    guard try journal.all().allSatisfy({ $0.completed && $0.released }) else {
      throw ExecutionEnvironmentError.unavailable("Execution recovery is incomplete")
    }
    try store.transactionWithDatabase { database, ledger in
      let records = try ExecutionRuntimeRecord.all(database)
      guard ledger.authorizationEpochID == epoch, ledger.pendingExecutionTerminations.isEmpty,
        records.allSatisfy({ $0.completed })
      else {
        throw ExecutionEnvironmentError.unavailable("Execution recovery is incomplete")
      }
      if let recovery = ledger.pendingEpochRecovery {
        try ledger.acknowledgeEpochRecovery(recovery.epochID)
      }
    }
    try requireNoUnownedScratch()
    lock.withLock { ready = true }
  }

  private func requireNoUnownedScratch() throws {
    let owned = try store.readWithDatabase { database, _ in
      Set(try ExecutionRuntimeRecord.all(database).compactMap(\.scratchDirectory))
    }
    let unowned = try FileManager.default.contentsOfDirectory(
      at: storageDirectory,
      includingPropertiesForKeys: nil
    ).filter {
      UUID(uuidString: $0.lastPathComponent) != nil && !owned.contains($0.path)
    }.map(\.lastPathComponent).sorted()
    guard unowned.isEmpty else {
      throw ExecutionEnvironmentError.unavailable(
        "Unowned private execution directories are quarantined for local owner review: "
          + unowned.prefix(8).joined(separator: ", "))
    }
  }

  package func prepare(
    authorizationID: UUID, context: GatewaySandboxContext,
    searchPath: [SandboxPath] = [try! SandboxPath("/usr/bin"), try! SandboxPath("/bin")],
    fullAccessEnvironment: [String: String] = [:], connectionID: String? = nil,
    auditContext: ExecutionContext? = nil, worktreeAdmission: WorktreeAdmission? = nil
  ) async throws -> PreparedExecutionContext {
    guard lock.withLock({ ready }) else {
      throw ExecutionEnvironmentError.unavailable("Execution recovery has not completed")
    }
    let reserved: Result<(AuthorizedExecution, GatewayExecutionConfiguration), any Error> =
      try store.transactionWithDatabase { database, ledger in
        let result = Result {
          let ownedRoot = try ProjectPathResolver.canonicalProject(storageDirectory)
          let expectedScratch = ownedRoot.appendingPathComponent(authorizationID.uuidString).path
          let ownedTemporary =
            context.temporaryDirectory.value == expectedScratch
            ? context.temporaryDirectory : nil
          let configuration = try GatewaySandboxCompiler.compile(
            ledger: &ledger, authorizationID: authorizationID, context: context,
            ownedTemporaryDirectory: ownedTemporary)
          guard
            !configuration.permitsProgramLaunch
              || launcher.supportsDurableOwnership(sandboxed: configuration.sandbox != nil)
          else {
            throw ExecutionEnvironmentError.unavailable(
              "This backend cannot enforce durable ownership in the requested execution mode")
          }
          let execution = try ledger.startExecution(
            owner: configuration.authorization.invocation.principal,
            authorizationIDs: [authorizationID])
          return (execution, configuration)
        }
        if case .success(let (execution, _)) = result {
          guard let boot = launcher.bootSessionID else {
            throw ExecutionEnvironmentError.unavailable("Execution boot identity is unavailable")
          }
          var record = ExecutionRuntimeRecord(id: execution.id, ownerID: ownerID, boot: boot)
          guard let authorization = ledger.authorizations[authorizationID] else {
            throw PermissionModelError.invalidAuthorization
          }
          record.auditIdentity = try GatewayExecutionAuditIdentity(
            database: database, ledger: ledger,
            authorization: authorization, context: auditContext)
          try record.auditIdentity?.record(
            "reserved", executionID: execution.id, database: database)
          let scratch = try ProjectPathResolver.canonicalProject(
            URL(fileURLWithPath: context.temporaryDirectory.value))
          if scratch.deletingLastPathComponent().path == storageDirectory.path,
            scratch.lastPathComponent == authorizationID.uuidString
          {
            record.scratchDirectory = scratch.path
          }
          try record.save(database)
        }
        return result
      }
    let (execution, configuration) = try reserved.get()
    let authority = GatewayExecutionAuthority(
      coordinator: self, executionID: execution.id,
      authorizationIDs: execution.authorizationIDs, principal: execution.owner,
      connectionID: connectionID)
    do {
      if let worktreeAdmission {
        let use = try worktreeAdmission.reserve(ownerID: ownerID, executionID: execution.id)
        do {
          try store.transactionWithDatabase { database, _ in
            guard var record = try ExecutionRuntimeRecord.load(execution.id, database),
              record.ownerID == ownerID, !record.completed, !record.admissionFinished
            else { throw PermissionModelError.invalidAuthorization }
            record.worktreeUse = use
            record.invocationInFlight = true
            record.worktreeDurable =
              configuration.sandbox != nil || !configuration.permitsProgramLaunch
            try record.save(database)
          }
        } catch {
          // No prepared context or child has escaped this reservation yet.
          try? worktreeAdmission.acknowledge(use)
          throw error
        }
      }
      var sandbox = configuration.sandbox
      if sandbox != nil {
        if let proxyFactory {
          let proxy = try await proxyFactory(execution.id, configuration.egress) {
            [weak permissionDiscovery] denial in
            permissionDiscovery?.receive(denial, executionID: execution.id)
          }
          lock.withLock { proxies[execution.id] = proxy }
          sandbox = try sandbox!.withProxy(await proxy.sandboxPorts())
        } else if configuration.egress.access != .none {
          throw ExecutionEnvironmentError.unavailable("Execution egress is unavailable")
        }
      }
      let environment: ExecutionEnvironment
      if let sandbox {
        environment = try ExecutionEnvironment(
          searchPath: searchPath, home: sandbox.homeDirectory,
          temporary: sandbox.temporaryDirectory, cache: sandbox.cacheDirectory)
      } else {
        environment = try ExecutionEnvironment(fullAccessVariables: fullAccessEnvironment)
      }
      let prepared = PreparedExecutionContext(
        authority: authority,
        mode: sandbox.map { .sandbox($0) } ?? .fullAccess, environment: environment,
        limits: execution.limits,
        pathAccess: GatewayPathAccess(store: store, authorizationID: authorizationID),
        permitsProgramLaunch: configuration.permitsProgramLaunch)
      _ = try authority.access(execution.id, operation: .readResult)
      lock.withLock { contexts[execution.id] = WeakExecutionContext(prepared) }
      return prepared
    } catch {
      try? finishAdmission(execution.id)
      try? await reconcile()
      throw error
    }
  }

  package func continuation(authorizationID: UUID, connectionID: String? = nil) throws
    -> any ExecutionAccessChecking
  {
    let result: Result<Principal, any Error> = try store.transactionWithDatabase { _, ledger in
      Result { try ledger.invocationAccess(authorizationID).invocation.principal }
    }
    return GatewayExecutionAccessScope(
      coordinator: self, principal: try result.get(), connectionID: connectionID,
      authorizationID: authorizationID,
      pathAccess: GatewayPathAccess(store: store, authorizationID: authorizationID))
  }

  package func recoveredExecution(_ id: UUID) throws -> EffectiveExecutionLimits? {
    guard lock.withLock({ ready }) else { throw PermissionModelError.invalidAuthorization }
    return try store.readWithDatabase { database, ledger in
      let record = try ExecutionRuntimeRecord.load(id, database)
      guard record?.completed ?? (ledger.executions[id] == nil),
        !ledger.pendingExecutionTerminations.contains(id)
      else { throw PermissionModelError.invalidAuthorization }
      guard let execution = ledger.executions[id], !execution.revoked,
        execution.retainUntil.map({ $0 > Date() }) == true
      else { return nil }
      return execution.limits
    }
  }

  package func observeExecutionLimits(
    _ id: UUID, _ observer: @escaping @Sendable (EffectiveExecutionLimits) -> Void
  ) throws {
    guard let limits = try recoveredExecution(id) else {
      throw PermissionModelError.invalidAuthorization
    }
    lock.withLock { limitObservers[id, default: []].append(observer) }
    observer(limits)
  }

  /// Also called after owner edits; polling supplies cross-process invalidation.
  package func notify() {
    Task.detached { [self] in try? await reconcile() }
  }

  /// Closing one runtime seals only its executions. Local stop intent survives
  /// failed storage writes until their owned resources and durable receipts join.
  package func stopExecutions(_ ids: Set<UUID>) async throws {
    guard !ids.isEmpty else { return }
    let resources = publication.withLock {
      lock.withLock {
        closedAdmissions.formUnion(ids)
        pendingOwnerStops.formUnion(ids)
        return (
          proxies: ids.compactMap { proxies[$0] },
          children: ids.flatMap { executionID in
            (pendingChildren[executionID] ?? []).compactMap { child in
              children[child].map { (executionID, child, $0) }
            }
          },
          cancellations: logicalWork.values.filter { ids.contains($0.executionID) }
            .compactMap { $0.takeCancellation() }
        )
      }
    }
    var firstError: (any Error)?
    do { try persistOwnerStops(ids) } catch { firstError = error }
    for cancellation in resources.cancellations { Task.detached { await cancellation() } }
    for proxy in resources.proxies {
      do { try await proxy.revoke() } catch { firstError = firstError ?? error }
    }
    for (executionID, child, ownership) in resources.children {
      do {
        _ = try await ownership.cancel()
        try confirmChild(child, executionID: executionID)
      } catch { firstError = firstError ?? error }
    }
    do { try await reconcile() } catch { firstError = firstError ?? error }
    if let firstError { throw firstError }
  }

  /// Called with the repository lock held. The persistent gate covers every
  /// principal and host; this owner can acknowledge only its own executions.
  package func terminateWorktreeWriters(
    _ admission: WorktreeAdmission, operationID: UUID,
    until deadline: ContinuousClock.Instant
  ) async throws {
    let uses = try publication.withLock { try admission.close(operationID: operationID) }
    let records = try store.readWithDatabase { database, _ in
      try uses.map { use -> ExecutionRuntimeRecord in
        guard use.ownerID == ownerID,
          let record = try ExecutionRuntimeRecord.load(use.executionID, database),
          record.worktreeUse == use
        else {
          throw WorktreeError.busy("A different execution owner must acknowledge this writer.")
        }
        return record
      }
    }
    // Best-effort Full access ownership cannot authorize destruction of a
    // writable tree. Its later adapter must retain this distinction.
    guard
      records.allSatisfy({ record in
        record.worktreeDurable == true
          && record.children.values.allSatisfy { $0.recovery?.sandboxed != false }
      })
    else {
      throw WorktreeError.busy("Unconfined writer completion cannot be proved.")
    }
    try Task.checkCancellation()
    guard ContinuousClock.now < deadline else {
      throw WorktreeError.busy("Writer deadline expired.")
    }
    try await stopExecutions(Set(uses.map(\.executionID)))
    while true {
      try Task.checkCancellation()
      guard ContinuousClock.now < deadline else {
        throw WorktreeError.busy("Worktree writer termination is incomplete.")
      }
      try await reconcile()
      do {
        try admission.requireDrained(operationID: operationID)
        return
      } catch WorktreeError.busy {
        try await Task.sleep(for: .milliseconds(10))
      }
    }
  }

  private func requireWorktreeAdmission(_ id: UUID) throws {
    let use = try store.readWithDatabase { database, _ in
      try ExecutionRuntimeRecord.load(id, database)?.worktreeUse
    }
    if let use { try use.admission.requireOpen(use) }
  }

  private func persistOwnerStops(_ ids: Set<UUID>) throws {
    guard !ids.isEmpty else { return }
    try store.transactionWithDatabase { database, ledger in
      for id in ids {
        guard var record = try ExecutionRuntimeRecord.load(id, database),
          record.ownerID == ownerID || record.completed
        else { continue }
        if !record.admissionFinished {
          record.admissionFinished = true
          for authorizationID in ledger.executions[id]?.authorizationIDs ?? [] {
            try ledger.finishInvocation(authorizationID)
          }
          try record.auditIdentity?.record("admission.closed", executionID: id, database: database)
          try record.save(database)
        }
        if let execution = ledger.executions[id],
          execution.isRunning
            || !record.completed && !ledger.pendingExecutionTerminations.contains(id)
        {
          try ledger.terminateExecution(id)
        }
      }
    }
  }

  package func reconcile() async throws {
    try await reconciliation.run { [self] in
      do {
        try await reconcileResources()
        try resumeAfterReconciliationIfDrained()
      } catch {
        lock.withLock { ready = false }
        let resources = lock.withLock {
          (
            Array(children.values), Array(proxies.values),
            logicalWork.values.compactMap { $0.takeCancellation() }
          )
        }
        for cancellation in resources.2 { Task.detached { await cancellation() } }
        for proxy in resources.1 { try? await proxy.revoke() }
        for ownership in resources.0 { _ = try? await ownership.cancel() }
        throw error
      }
    }
  }

  /// An infrastructure failure closes admission until every previously owned
  /// resource has joined and the durable recovery barrier is clear again.
  private func resumeAfterReconciliationIfDrained() throws {
    guard lock.withLock({ recoveryStarted && !ready }),
      try journal.all().allSatisfy({ $0.completed && $0.released })
    else { return }
    let resumed = try store.transactionWithDatabase { database, ledger in
      guard try ExecutionRuntimeRecord.all(database).allSatisfy(\.completed),
        ledger.pendingExecutionTerminations.isEmpty
      else { return false }
      if let pending = ledger.pendingEpochRecovery {
        try ledger.acknowledgeEpochRecovery(pending.epochID)
      }
      return true
    }
    if resumed {
      try requireNoUnownedScratch()
      lock.withLock { ready = true }
    }
  }

  private func startMonitoring() {
    lock.withLock {
      guard monitoring == nil else { return }
      monitoring = Task.detached { [weak self] in
        while !Task.isCancelled {
          try? await self?.reconcile()
          do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
          if self == nil { return }
        }
      }
    }
  }

  fileprivate func access(
    _ id: UUID, principal: Principal, connectionID: String?, operation: ExecutionOperation,
    authorizationID: UUID? = nil
  )
    throws -> EffectiveExecutionLimits
  {
    if operation == .writeInput { try requireWorktreeAdmission(id) }
    let outcome: (Result<EffectiveExecutionLimits, any Error>, Bool) =
      try store.transactionWithDatabase {
        _, ledger in
        let executions = ledger.executions
        let terminations = ledger.pendingExecutionTerminations
        let decision: PermissionDecision
        if operation == .writeInput, lock.withLock({ pendingOwnerStops.contains(id) }) {
          decision = .denied(.executionEnded)
        } else {
          decision = ledger.executionAccess(
            id, principal: principal, operation: operation,
            connectionID: connectionID, authorizingInvocation: authorizationID, now: Date())
        }
        let result: Result<EffectiveExecutionLimits, any Error>
        if decision == .allowed,
          let execution = ledger.executions[id]
        {
          if operation == .cancel { try ledger.terminateExecution(id) }
          result = .success(execution.limits)
        } else {
          result = .failure(PermissionModelError.invalidAuthorization)
        }
        return (
          result,
          decision != .allowed || operation == .cancel || ledger.executions != executions
            || ledger.pendingExecutionTerminations != terminations
        )
      }
    if outcome.1 { notify() }
    return try outcome.0.get()
  }

  fileprivate func permissionRequests(
    _ id: UUID, principal: Principal, connectionID: String?, authorizationID: UUID? = nil
  ) throws -> [PermissionRequest] {
    try permissionDiscovery.requests(
      id, principal: principal, connectionID: connectionID, authorizationID: authorizationID)
  }

  fileprivate func reserveChild(_ child: UUID, authority: GatewayExecutionAuthority) throws {
    try publication.withLock {
      try requireWorktreeAdmission(authority.executionID)
      guard lock.withLock({ ready && !closedAdmissions.contains(authority.executionID) }) else {
        throw ExecutionEnvironmentError.unavailable("Execution recovery has not completed")
      }
      let result: Result<Void, any Error> = try store.transactionWithDatabase { database, ledger in
        guard var record = try ExecutionRuntimeRecord.load(authority.executionID, database),
          record.ownerID == ownerID, !record.admissionFinished, !record.completed,
          record.children[child] == nil, ledger.executions[record.id]?.isRunning == true,
          ledger.executionAccess(
            record.id, principal: authority.principal, operation: .readResult,
            connectionID: authority.connectionID, now: Date()) == .allowed
        else { return .failure(PermissionModelError.invalidAuthorization) }
        record.children[child] = .init()
        try record.save(database)
        return .success(())
      }
      try result.get()
      lock.withLock { _ = pendingChildren[authority.executionID, default: []].insert(child) }
    }
  }

  fileprivate func bindChild(
    _ child: UUID, authority: GatewayExecutionAuthority, ownership: any ExecutionOwnership
  ) {
    lock.withLock {
      children[child] = ownership
      proxies[authority.executionID]?.attach(to: ownership)
    }
    ownership.onSandboxViolation { [weak permissionDiscovery] violation in
      permissionDiscovery?.receive(violation, executionID: authority.executionID)
    }
    ownership.beforeStart { [self] _ in
      try publication.withLock {
        try requireWorktreeAdmission(authority.executionID)
        guard lock.withLock({ ready && !closedAdmissions.contains(authority.executionID) }) else {
          throw ExecutionEnvironmentError.unavailable("Execution recovery has not completed")
        }
        let canBind = try store.readWithDatabase { database, _ in
          guard let record = try ExecutionRuntimeRecord.load(authority.executionID, database),
            let entry = record.children[child]
          else { return false }
          return !entry.completed && !record.completed
        }
        guard canBind else { throw PermissionModelError.invalidAuthorization }
        let recovery = try ownership.recoveryState()
        lock.withLock { unpublishedRecovery[child] = recovery }
        guard let boot = launcher.bootSessionID else {
          throw ExecutionEnvironmentError.unavailable("Recovery boot identity is unavailable")
        }
        // Independent of the rollbackable permission database. This receipt must
        // survive a restored database that predates the launch reservation.
        try journal.save(
          .init(
            child: child, execution: authority.executionID, owner: ownerID, boot: boot,
            recovery: recovery,
            worktreeUse: try store.readWithDatabase { database, _ in
              try ExecutionRuntimeRecord.load(authority.executionID, database)?.worktreeUse
            }))
        let result: Result<Void, any Error> = try store.transactionWithDatabase {
          database, ledger in
          guard var record = try ExecutionRuntimeRecord.load(authority.executionID, database),
            var entry = record.children[child], entry.recovery == nil, !entry.completed,
            record.ownerID == ownerID, !record.completed,
            ledger.executions[record.id]?.isRunning == true,
            ledger.executionAccess(
              record.id, principal: authority.principal, operation: .readResult,
              connectionID: authority.connectionID, now: Date()) == .allowed
          else { return .failure(PermissionModelError.invalidAuthorization) }
          entry.recovery = recovery
          record.children[child] = entry
          try record.auditIdentity?.record(
            "starting", executionID: record.id, database: database, childID: child)
          try record.save(database)
          return .success(())
        }
        try result.get()
        lock.withLock { unpublishedRecovery[child] = nil }
      }
    }
    Task.detached { [self] in
      do {
        _ = try await ownership.waitForExit()
        try confirmChild(child, executionID: authority.executionID)
      } catch {
        try? store.transactionWithDatabase { _, ledger in
          try ledger.interruptExecution(authority.executionID)
        }
      }
      notify()
    }
  }

  fileprivate func launchFailed(_ child: UUID, executionID: UUID) {
    if lock.withLock({ children[child] == nil }) {
      try? confirmChild(child, executionID: executionID)
    }
    try? finishAdmission(executionID)
    notify()
  }

  fileprivate func retainWork(
    authority: GatewayExecutionAuthority, cancellation: @escaping @Sendable () async -> Void
  ) throws -> ExecutionWorkLease {
    let workID = UUID()
    try publication.withLock {
      try requireWorktreeAdmission(authority.executionID)
      try store.transactionWithDatabase { database, ledger in
        guard lock.withLock({ ready && !closedAdmissions.contains(authority.executionID) }),
          var record = try ExecutionRuntimeRecord.load(authority.executionID, database),
          record.ownerID == ownerID, !record.admissionFinished, !record.completed,
          ledger.executions[authority.executionID]?.isRunning == true,
          ledger.executionAccess(
            authority.executionID, principal: authority.principal,
            operation: .readResult, connectionID: authority.connectionID, now: Date()) == .allowed
        else { throw PermissionModelError.invalidAuthorization }
        var workIDs = record.workIDs ?? []
        workIDs.insert(workID)
        record.workIDs = workIDs
        try record.auditIdentity?.record(
          "work.started", executionID: record.id, database: database, childID: workID)
        try record.save(database)
      }
      lock.withLock {
        logicalWork[workID] = ExecutionLogicalWork(executionID: authority.executionID, cancellation)
      }
    }
    return ExecutionWorkLease { [self] in
      lock.withLock { logicalWork[workID]?.confirmCompletion() }
      defer { notify() }
      try persistWorkCompletion(workID, executionID: authority.executionID)
    }
  }

  private func persistWorkCompletion(_ workID: UUID, executionID: UUID) throws {
    try store.transactionWithDatabase { database, _ in
      guard var record = try ExecutionRuntimeRecord.load(executionID, database) else { return }
      if record.workIDs?.remove(workID) != nil {
        try record.auditIdentity?.record(
          "work.completed", executionID: record.id, database: database, childID: workID)
        try record.save(database)
      }
    }
    lock.withLock { logicalWork[workID] = nil }
  }

  fileprivate func finishAdmission(_ id: UUID) throws {
    lock.withLock {
      closedAdmissions.insert(id)
      pendingAdmissionClosures.insert(id)
    }
    defer { notify() }
    try persistAdmissionClosure(id)
  }

  private func persistAdmissionClosure(_ id: UUID) throws {
    try store.transactionWithDatabase { database, ledger in
      guard var record = try ExecutionRuntimeRecord.load(id, database) else { return }
      guard !record.admissionFinished || record.invocationInFlight == true else { return }
      record.admissionFinished = true
      record.invocationInFlight = false
      for authorizationID in ledger.executions[id]?.authorizationIDs ?? [] {
        try ledger.finishInvocation(authorizationID)
      }
      try record.auditIdentity?.record("admission.closed", executionID: id, database: database)
      try record.save(database)
    }
    _ = lock.withLock { pendingAdmissionClosures.remove(id) }
  }

  private func confirmChild(_ child: UUID, executionID: UUID) throws {
    try publication.withLock {
      try journal.confirm(child)
      try store.transactionWithDatabase { database, _ in
        guard var record = try ExecutionRuntimeRecord.load(executionID, database),
          record.children[child] != nil
        else { return }
        record.children[child]!.recovery =
          record.children[child]!.recovery ?? lock.withLock { unpublishedRecovery[child] }
        if !record.children[child]!.completed {
          try record.auditIdentity?.record(
            "child.completed", executionID: record.id, database: database, childID: child)
          record.children[child]!.completed = true
        }
        try record.save(database)
      }
      lock.withLock {
        children[child] = nil
        unpublishedRecovery[child] = nil
        pendingChildren[executionID]?.remove(child)
        if pendingChildren[executionID]?.isEmpty == true { pendingChildren[executionID] = nil }
      }
    }
  }

  private func reconcileResources() async throws {
    try persistOwnerStops(lock.withLock { pendingOwnerStops })
    try refreshPolicy?()
    let pending = lock.withLock {
      (
        Array(pendingAdmissionClosures),
        logicalWork.compactMap { id, work in
          work.isCompleted ? (id, work.executionID) : nil
        }
      )
    }
    for id in pending.0 { try persistAdmissionClosure(id) }
    for (id, executionID) in pending.1 { try persistWorkCompletion(id, executionID: executionID) }
    try await reconcileIndependentOwnership()
    func validate(_ ledger: inout PermissionLedger) {
      // This reconciles every live proof and queues dependent terminations in
      // one fixed-point pass; individual caller access is checked at each use.
      _ = ledger.reconcileExecutionLimits(now: Date())
    }
    let preview = try store.readWithDatabase { database, original in
      var ledger = original
      validate(&ledger)
      return (
        try ExecutionRuntimeRecord.all(database), ledger,
        ledger.executions != original.executions || ledger.authorizations != original.authorizations
          || ledger.pendingExecutionTerminations != original.pendingExecutionTerminations
      )
    }
    let snapshot: ([ExecutionRuntimeRecord], PermissionLedger)
    if preview.2 {
      snapshot = try store.transactionWithDatabase { database, ledger in
        validate(&ledger)
        return (try ExecutionRuntimeRecord.all(database), ledger)
      }
    } else {
      snapshot = (preview.0, preview.1)
    }
    var firstError: (any Error)?
    for record in snapshot.0 {
      do {
        let execution = snapshot.1.executions[record.id]
        if let execution {
          lock.withLock { contexts[record.id]?.value }?.applyLimits(
            execution.limits, endReason: execution.limitEndReason)
          let observers = lock.withLock {
            guard deliveredLimits[record.id] != execution.limits else {
              return [@Sendable (EffectiveExecutionLimits) -> Void]()
            }
            deliveredLimits[record.id] = execution.limits
            return limitObservers[record.id] ?? []
          }
          for observer in observers { observer(execution.limits) }
        }
        let terminate =
          snapshot.1.pendingExecutionTerminations.contains(record.id) || execution == nil
          || snapshot.1.pendingEpochRecovery?.executionsToTerminate.contains(record.id) == true
        let proxy = lock.withLock { proxies[record.id] }
        if terminate {
          do {
            try store.transactionWithDatabase { database, _ in
              guard var current = try ExecutionRuntimeRecord.load(record.id, database),
                current.revocationRecorded != true
              else { return }
              try current.auditIdentity?.record(
                "revoked", executionID: record.id, database: database, decision: .denied)
              current.revocationRecorded = true
              try current.save(database)
            }
          } catch { if firstError == nil { firstError = error } }
          try await proxy?.revoke()
        }
        if terminate {
          for workID in record.workIDs ?? [] {
            if let cancellation = lock.withLock({ logicalWork[workID]?.takeCancellation() }) {
              Task.detached { await cancellation() }
            }
          }
          for (child, entry) in record.children
          where !entry.completed
            || lock.withLock({
              pendingOwnerStops.contains(record.id)
                && pendingChildren[record.id]?.contains(child) == true
            })
          {
            if let ownership = lock.withLock({ children[child] }) {
              _ = try await ownership.cancel()
            } else if let recovery = entry.recovery {
              guard let boot = launcher.bootSessionID else {
                throw ExecutionEnvironmentError.unavailable("Recovery boot identity is unavailable")
              }
              if record.boot == boot {
                let ownership = try await launcher.recover(recovery)
                lock.withLock { children[child] = ownership }
                _ = try await ownership.cancel()
              }
            } else if record.ownerID == ownerID {
              // A current launch may still be moving from reservation to its
              // ownership callback. That callback must fail or confirm cleanup.
              continue
            }
            try confirmChild(child, executionID: record.id)
          }
        }
        let mayComplete =
          record.completed || terminate
          || (record.children.values.allSatisfy(\.completed) && (record.workIDs?.isEmpty ?? true)
            && (record.admissionFinished || terminate))
        let completed: ExecutionRuntimeRecord? =
          record.completed
          ? record
          : !mayComplete
            ? nil
            : try store.transactionWithDatabase { database, ledger in
              guard var current = try ExecutionRuntimeRecord.load(record.id, database) else {
                return nil
              }
              guard current.children.values.allSatisfy(\.completed),
                current.workIDs?.isEmpty ?? true,
                current.invocationInFlight != true,
                current.admissionFinished
                  || ledger.pendingExecutionTerminations.contains(current.id)
                  || ledger.executions[current.id] == nil
              else { return nil }
              if !current.completed {
                if ledger.executions[current.id] != nil {
                  try ledger.finishExecution(
                    current.id, retainUntil: Date().addingTimeInterval(86_400))
                }
                try current.auditIdentity?.record(
                  "completed", executionID: current.id, database: database)
                current.completed = true
                try current.save(database)
              }
              return current
            }
        if let completed {
          guard sealAdmissionIfDrained(completed.id) else { continue }
          if let use = completed.worktreeUse {
            guard completed.invocationInFlight != true,
              try journal.all().filter({ $0.execution == completed.id }).allSatisfy(\.completed)
            else { continue }
            try use.admission.acknowledge(use)
          }
          // Ports cannot be recycled while any member remains unconfirmed.
          try await proxy?.releaseAfterExecutionEnds()
          for (child, entry) in completed.children where !entry.released {
            if let recovery = entry.recovery { try launcher.releaseRecovery(recovery) }
            try journal.release(child)
            try store.transactionWithDatabase { database, _ in
              guard var current = try ExecutionRuntimeRecord.load(completed.id, database) else {
                return
              }
              current.children[child]?.released = true
              try current.save(database)
            }
          }
          if let scratch = completed.scratchDirectory {
            let url = URL(fileURLWithPath: scratch)
            guard url.deletingLastPathComponent().path == storageDirectory.path,
              UUID(uuidString: url.lastPathComponent) != nil
            else { throw PermissionModelError.invalidAuthorization }
            if FileManager.default.fileExists(atPath: url.path) {
              try FileManager.default.removeItem(at: url)
            }
            try store.transactionWithDatabase { database, _ in
              guard var record = try ExecutionRuntimeRecord.load(completed.id, database) else {
                return
              }
              record.scratchDirectory = nil
              try record.save(database)
            }
          }
          if snapshot.1.pendingExecutionTerminations.contains(completed.id) {
            try store.transactionWithDatabase { _, ledger in
              ledger.acknowledgeExecutionTerminations([completed.id])
            }
          }
          lock.withLock {
            proxies[completed.id] = nil
            if completed.children.values.allSatisfy(\.completed),
              completed.workIDs?.isEmpty ?? true,
              pendingChildren[completed.id]?.isEmpty ?? true,
              !logicalWork.values.contains(where: { $0.executionID == completed.id })
            {
              pendingOwnerStops.remove(completed.id)
            }
          }
        }
      } catch { firstError = firstError ?? error }
    }
    if let firstError { throw firstError }
  }

  private func reconcileIndependentOwnership() async throws {
    try await reconcileOrphanedProxies()
    let records = try journal.all()
    for entry in records {
      let orphaned = try store.readWithDatabase { database, ledger in
        let record = try ExecutionRuntimeRecord.load(entry.execution, database)
        return record?.children[entry.child] == nil || ledger.executions[entry.execution] == nil
      }
      if !entry.completed && (entry.owner != ownerID || orphaned) {
        guard let boot = launcher.bootSessionID else {
          throw ExecutionEnvironmentError.unavailable("Recovery boot identity is unavailable")
        }
        try await lock.withLock { proxies[entry.execution] }?.revoke()
        if entry.boot == boot {
          let ownership: any ExecutionOwnership
          if let local = lock.withLock({ children[entry.child] }) {
            ownership = local
          } else {
            ownership = try await launcher.recover(entry.recovery)
            lock.withLock { children[entry.child] = ownership }
          }
          _ = try await ownership.cancel()
        }
        try confirmChild(entry.child, executionID: entry.execution)
      }
      if entry.completed || entry.owner != ownerID || orphaned {
        if !entry.released {
          try launcher.releaseRecovery(entry.recovery)
          try journal.release(entry.child)
        }
        // A restored SQL copy may predate the independently confirmed completion.
        let needsSync = try store.readWithDatabase { database, _ in
          guard
            let child = try ExecutionRuntimeRecord.load(entry.execution, database)?.children[
              entry.child]
          else { return false }
          return !child.completed || !child.released
        }
        if needsSync {
          try store.transactionWithDatabase { database, _ in
            guard var record = try ExecutionRuntimeRecord.load(entry.execution, database),
              var child = record.children[entry.child], !child.completed || !child.released
            else { return }
            child.completed = true
            child.released = true
            record.children[entry.child] = child
            try record.save(database)
          }
        }
      }
    }
    // A database restore may omit the execution entirely. Independent launch
    // receipts still retain its worktree use until every child is confirmed.
    let settled = try journal.all()
    for entry in settled where entry.owner != ownerID {
      guard let use = entry.worktreeUse,
        settled.filter({ $0.execution == entry.execution }).allSatisfy(\.completed),
        try store.readWithDatabase({ database, _ in
          try ExecutionRuntimeRecord.load(entry.execution, database) == nil
        })
      else { continue }
      try use.admission.acknowledge(use)
    }
  }

  private func sealAdmissionIfDrained(_ id: UUID) -> Bool {
    publication.withLock {
      lock.withLock {
        closedAdmissions.insert(id)
        return pendingChildren[id]?.isEmpty ?? true
      }
    }
  }

  private func reconcileOrphanedProxies() async throws {
    let candidates = lock.withLock { Array(proxies.keys) }
    for id in candidates {
      let orphaned = try store.readWithDatabase { database, _ in
        try ExecutionRuntimeRecord.load(id, database) == nil
      }
      guard orphaned else { continue }
      let resources = publication.withLock {
        lock.withLock {
          closedAdmissions.insert(id)
          return (
            proxies[id],
            (pendingChildren[id] ?? []).compactMap { child in
              children[child].map { (child, $0) }
            }
          )
        }
      }
      try await resources.0?.revoke()
      for (child, ownership) in resources.1 {
        _ = try await ownership.cancel()
        try confirmChild(child, executionID: id)
      }
      let receipts = try journal.all().filter { $0.execution == id }
      let drained = sealAdmissionIfDrained(id)
      // Closed admission makes this stable after every reserved child settles,
      // including children that have not reached their ownership callback yet.
      guard drained, receipts.allSatisfy(\.completed) else { continue }
      try await resources.0?.releaseAfterExecutionEnds()
      lock.withLock { proxies[id] = nil }
    }
  }
}

private final class GatewayExecutionAuthority: ExecutionAuthorizing, Sendable {
  let coordinator: ExecutionRevocationCoordinator
  let executionID: UUID
  let authorizationIDs: Set<UUID>
  let principal: Principal
  let connectionID: String?
  init(
    coordinator: ExecutionRevocationCoordinator, executionID: UUID, authorizationIDs: Set<UUID>,
    principal: Principal, connectionID: String?
  ) {
    self.coordinator = coordinator
    self.executionID = executionID
    self.authorizationIDs = authorizationIDs
    self.principal = principal
    self.connectionID = connectionID
  }
  func reserveChild(_ id: UUID) throws { try coordinator.reserveChild(id, authority: self) }
  func bindChild(_ id: UUID, ownership: any ExecutionOwnership) {
    coordinator.bindChild(id, authority: self, ownership: ownership)
  }
  func launchFailed(_ id: UUID) { coordinator.launchFailed(id, executionID: executionID) }
  func finishAdmission() throws { try coordinator.finishAdmission(executionID) }
  func retainWork(cancellation: @escaping @Sendable () async -> Void) throws -> ExecutionWorkLease {
    try coordinator.retainWork(authority: self, cancellation: cancellation)
  }
  func access(_ id: UUID, operation: ExecutionOperation) throws -> EffectiveExecutionLimits {
    try coordinator.access(
      id, principal: principal, connectionID: connectionID, operation: operation)
  }
  func permissionRequests(_ id: UUID) throws -> [PermissionRequest] {
    try coordinator.permissionRequests(id, principal: principal, connectionID: connectionID)
  }
}

struct ExecutionRuntimeRecord: Codable {
  struct Child: Codable {
    var recovery: ExecutionRecoveryState?
    var completed = false
    var released = false
  }
  let id: UUID
  let ownerID: UUID
  let boot: String
  var admissionFinished = false
  var completed = false
  var children: [UUID: Child] = [:]
  var scratchDirectory: String?
  var workIDs: Set<UUID>?
  var auditIdentity: GatewayExecutionAuditIdentity?
  var revocationRecorded: Bool?
  var permissionNeeds: [DiscoveredRequirement]?
  var permissionRequestIDs: Set<UUID>?
  var worktreeUse: WorktreeWriterUse?
  /// A stopped admission is not evidence that an in-process invocation returned.
  var invocationInFlight: Bool?
  var worktreeDurable: Bool?

  func save(_ database: Database) throws {
    try database.execute(
      sql:
        "INSERT INTO permissionRuntimeExecutions (id, payload) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",
      arguments: [id.uuidString, try JSONEncoder().encode(self)])
  }
  static func load(_ id: UUID, _ database: Database) throws -> Self? {
    guard
      let bytes = try Data.fetchOne(
        database, sql: "SELECT payload FROM permissionRuntimeExecutions WHERE id=?",
        arguments: [id.uuidString])
    else { return nil }
    return try decode(bytes)
  }
  static func all(_ database: Database) throws -> [Self] {
    try Data.fetchAll(database, sql: "SELECT payload FROM permissionRuntimeExecutions").map(decode)
  }
  static func decode(_ bytes: Data) throws -> Self {
    guard bytes.count <= 16_777_216 else { throw PermissionPersistenceError.invalidCurrentState }
    return try JSONDecoder().decode(Self.self, from: bytes)
  }
}

private actor ExecutionReconciliation {
  private var task: Task<Void, any Error>?
  func run(_ operation: @escaping @Sendable () async throws -> Void) async throws {
    if let task { return try await task.value }
    let task = Task { try await operation() }
    self.task = task
    defer { self.task = nil }
    try await task.value
  }
}

private final class WeakExecutionContext: @unchecked Sendable {
  weak var value: PreparedExecutionContext?
  init(_ value: PreparedExecutionContext) { self.value = value }
}

private final class GatewayExecutionAccessScope: ExecutionAccessChecking, @unchecked Sendable {
  let coordinator: ExecutionRevocationCoordinator
  let principal: Principal
  let connectionID: String?
  let authorizationID: UUID
  let pathAccess: (any HostPathAccessChecking)?
  private let lock = NSLock()
  private var observed: Set<UUID> = []

  init(
    coordinator: ExecutionRevocationCoordinator, principal: Principal, connectionID: String?,
    authorizationID: UUID, pathAccess: (any HostPathAccessChecking)?
  ) {
    self.coordinator = coordinator
    self.principal = principal
    self.connectionID = connectionID
    self.authorizationID = authorizationID
    self.pathAccess = pathAccess
  }
  func accessExecution(_ id: UUID, operation: ExecutionOperation) throws -> EffectiveExecutionLimits
  {
    let limits = try coordinator.access(
      id, principal: principal, connectionID: connectionID, operation: operation,
      authorizationID: authorizationID)
    lock.withLock { _ = observed.insert(id) }
    return limits
  }

  func permissionRequests(_ id: UUID) throws -> [PermissionRequest] {
    try coordinator.permissionRequests(
      id, principal: principal, connectionID: connectionID, authorizationID: authorizationID)
  }

  func currentPermissionRequestGroups() throws -> [ExecutionPermissionRequestGroup] {
    try lock.withLock { observed }.sorted { $0.uuidString < $1.uuidString }.compactMap { id in
      let requests = try permissionRequests(id)
      return requests.isEmpty ? nil : .init(executionID: id, requests: requests)
    }
  }
}

private final class ExecutionLogicalWork: @unchecked Sendable {
  let executionID: UUID
  private let lock = NSLock()
  private var cancellation: (@Sendable () async -> Void)?
  private var completed = false
  init(executionID: UUID, _ cancellation: @escaping @Sendable () async -> Void) {
    self.executionID = executionID
    self.cancellation = cancellation
  }
  var isCompleted: Bool { lock.withLock { completed } }
  func confirmCompletion() {
    lock.withLock {
      completed = true
      cancellation = nil
    }
  }
  func takeCancellation() -> (@Sendable () async -> Void)? {
    lock.withLock {
      let result = cancellation
      cancellation = nil
      return result
    }
  }
}
