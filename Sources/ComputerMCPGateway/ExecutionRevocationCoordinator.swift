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
  /// This process's execution owner; host operations record it at reservation.
  package var ownerIdentity: UUID { ownerID }
  private let permissionDiscovery: ExecutionPermissionDiscovery
  private let proxyFactory: ProxyFactory?
  private let journal: ExecutionRecoveryJournal
  private let storageDirectory: URL
  private let refreshPolicy: (@Sendable () throws -> Void)?
  private let afterWorktreeReservation: (@Sendable (WorktreeWriterUse) async -> Void)?
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
  private var pendingAuthorizationRevocations: Set<UUID> = []
  private var contexts: [UUID: WeakExecutionContext] = [:]
  private var proxies: [UUID: EgressProxy] = [:]
  private var monitoring: Task<Void, Never>?

  package convenience init(
    store: SQLitePermissionStore, launcher: ExecutionLauncher, directory: URL,
    proxyFactory: ProxyFactory? = nil, refreshPolicy: (@Sendable () throws -> Void)? = nil
  ) throws {
    try self.init(
      store: store, launcher: launcher, directory: directory,
      proxyFactory: proxyFactory, refreshPolicy: refreshPolicy, afterWorktreeReservation: nil)
  }

  init(
    store: SQLitePermissionStore, launcher: ExecutionLauncher, directory: URL,
    proxyFactory: ProxyFactory? = nil, refreshPolicy: (@Sendable () throws -> Void)? = nil,
    afterWorktreeReservation: (@Sendable (WorktreeWriterUse) async -> Void)?
  ) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    self.store = store
    self.storageDirectory = try ProjectPathResolver.canonicalProject(directory)
    self.launcher = launcher
    self.proxyFactory = proxyFactory
    self.refreshPolicy = refreshPolicy
    self.afterWorktreeReservation = afterWorktreeReservation
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
    auditContext: ExecutionContext? = nil, worktreeAdmission: WorktreeAdmission? = nil,
    provider: ProviderExecutionBinding? = nil, providerProject: ProviderProjectIdentity? = nil,
    mcpDiscovery: Bool = false,
    providerWorkingDirectory: SandboxPath? = nil, providerExecutable: SandboxPath? = nil,
    validateProvider: (@Sendable () throws -> Void)? = nil,
    callback: ProviderExecutionBinding? = nil
  ) async throws -> PreparedExecutionContext {
    guard lock.withLock({ ready }) else {
      throw ExecutionEnvironmentError.unavailable("Execution recovery has not completed")
    }
    try persistAuthorizationRevocations()
    try validateProvider?()
    let compiledAuthorizationID =
      provider?.providerAuthorization.id
      ?? callback?.providerAuthorization.id ?? authorizationID
    let providerSandboxed = provider.map {
      $0.providerAuthorization.mode == .sandbox || $0.delegatingAuthorization == nil
    }
    let reserved:
      Result<
        (AuthorizedExecution, GatewayExecutionConfiguration?, ExecutionPermissionProjection?),
        any Error
      > = try store.transactionWithDatabase { database, ledger in
        let result = Result {
          if let provider {
            guard
              (provider.delegatingAuthorization?.id ?? provider.providerAuthorization.id)
                == authorizationID,
              context.providerContainer?.identity == provider.identity
            else { throw PermissionModelError.invalidAuthorization }
            for id in provider.authorizationIDs { _ = try ledger.invocationAccess(id) }
            if context.worktree != nil {
              _ = try ledger.prepareWorktreePermissions(compiledAuthorizationID)
            }
            let projection = try ledger.prepareExecutionPermissions(
              compiledAuthorizationID, sandboxed: providerSandboxed!)
            guard
              launcher.supportsDurableOwnership(sandboxed: providerSandboxed!)
                || (!providerSandboxed! && launcher.supportsBestEffortOwnership)
            else {
              throw ExecutionEnvironmentError.unavailable(
                "This backend cannot enforce provider execution ownership")
            }
            let execution = try ledger.startExecution(
              owner: provider.owner,
              delegatedTo: provider.delegatingAuthorization == nil ? nil : provider.identity,
              authorizationIDs: provider.authorizationIDs)
            return (execution, nil as GatewayExecutionConfiguration?, Optional(projection))
          }
          let ownedRoot = try ProjectPathResolver.canonicalProject(storageDirectory)
          let expectedScratch = ownedRoot.appendingPathComponent(authorizationID.uuidString).path
          let ownedTemporary =
            context.temporaryDirectory.value == expectedScratch
            ? context.temporaryDirectory : nil
          let configuration = try GatewaySandboxCompiler.compile(
            ledger: &ledger, authorizationID: compiledAuthorizationID, context: context,
            ownedTemporaryDirectory: ownedTemporary)
          guard
            !configuration.permitsProgramLaunch
              || launcher.supportsDurableOwnership(sandboxed: configuration.sandbox != nil)
              || (configuration.sandbox == nil && launcher.supportsBestEffortOwnership)
          else {
            throw ExecutionEnvironmentError.unavailable(
              "This backend cannot enforce durable ownership in the requested execution mode")
          }
          let execution = try ledger.startExecution(
            owner: callback?.owner ?? configuration.authorization.invocation.principal,
            delegatedTo: callback?.identity,
            authorizationIDs: callback?.authorizationIDs ?? [authorizationID])
          return (execution, Optional(configuration), nil as ExecutionPermissionProjection?)
        }
        if case .success(let (execution, _, _)) = result {
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
    let (execution, initialConfiguration, projection) = try reserved.get()
    // A provider session follows its recorded authority dependencies. Standing
    // consent does not bind it to the transport that happened to start it.
    let executionConnectionID = try store.readWithDatabase { _, ledger -> String? in
      guard provider != nil || callback != nil, let connectionID else { return connectionID }
      let proofs = execution.authorizationIDs.compactMap { ledger.authorizations[$0] }
      let bound = proofs.contains { proof in
        proof.basis.contains { element in
          switch element {
          case .consent(let identity):
            guard let consent = ledger.environment.connections[connectionID]?.consent,
              consent.identity == identity, case .fullAccess(.connection) = consent.mode
            else { return false }
            return true
          default: return false
          }
        }
      }
      return bound ? connectionID : nil
    }
    let authority = GatewayExecutionAuthority(
      coordinator: self, executionID: execution.id,
      authorizationIDs: execution.authorizationIDs, principal: execution.owner,
      connectionID: executionConnectionID,
      discovery: mcpDiscovery && executionConnectionID == nil
        ? provider.flatMap { GatewayDiscoverySelection(executionID: execution.id, binding: $0) }
        : nil)
    do {
      if let worktree = context.worktree {
        guard worktreeAdmission == worktree.binding.admission else {
          throw PermissionModelError.invalidAuthorization
        }
        try worktree.binding.verify()
      }
      if let worktreeAdmission {
        let use = try worktreeAdmission.reserve(
          ownerID: ownerID, executionID: execution.id,
          unconfined: providerSandboxed.map { !$0 }
            ?? (initialConfiguration!.sandbox == nil && initialConfiguration!.permitsProgramLaunch))
        // The gate transaction has committed. SQL does not yet refer to this writer.
        await afterWorktreeReservation?(use)
        do {
          try store.transactionWithDatabase { database, _ in
            guard var record = try ExecutionRuntimeRecord.load(execution.id, database),
              record.ownerID == ownerID, !record.completed, !record.admissionFinished
            else { throw PermissionModelError.invalidAuthorization }
            record.worktreeUse = use
            record.invocationInFlight = true
            record.worktreeDurable =
              providerSandboxed
              ?? (initialConfiguration!.sandbox != nil
                || !initialConfiguration!.permitsProgramLaunch)
            try record.save(database)
          }
        } catch {
          // No prepared context or child has escaped this reservation yet.
          try? worktreeAdmission.acknowledge(use)
          throw error
        }
      }
      let configuration: GatewayExecutionConfiguration
      if let initialConfiguration {
        configuration = initialConfiguration
      } else {
        try validateProvider?()
        configuration = try store.transactionWithDatabase { _, ledger in
          let ownedRoot = try ProjectPathResolver.canonicalProject(storageDirectory)
          guard
            context.temporaryDirectory.value
              == ownedRoot.appendingPathComponent(authorizationID.uuidString).path
          else { throw PermissionModelError.invalidAuthorization }
          return try GatewaySandboxCompiler.compile(
            ledger: &ledger, authorizationID: compiledAuthorizationID, context: context,
            ownedTemporaryDirectory: context.temporaryDirectory, reservedProjection: projection,
            provider: provider, providerWorkingDirectory: providerWorkingDirectory)
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
          temporary: sandbox.temporaryDirectory, cache: sandbox.cacheDirectory,
          state: sandbox.providerContainer?.state)
      } else if let container = try context.providerContainer?.sandbox {
        environment = try ExecutionEnvironment(
          searchPath: searchPath, home: container.home, temporary: context.temporaryDirectory,
          cache: container.cache, state: container.state)
      } else {
        environment = try ExecutionEnvironment(fullAccessVariables: fullAccessEnvironment)
      }
      let validateWorktree: (@Sendable () throws -> Void)?
      if let worktree = context.worktree {
        validateWorktree = { try worktree.binding.verify() }
      } else {
        validateWorktree = nil
      }
      let provider = try provider.map { binding in
        try store.readWithDatabase { _, ledger in
          guard let own = ledger.authorizations[binding.providerAuthorization.id] else {
            throw PermissionModelError.invalidAuthorization
          }
          let caller = try binding.delegatingAuthorization.map { original in
            guard let current = ledger.authorizations[original.id] else {
              throw PermissionModelError.invalidAuthorization
            }
            return current
          }
          return try ProviderExecutionBinding(
            identity: binding.identity, registrationID: binding.registrationID,
            sourceDigest: binding.sourceDigest, providerAuthorization: own,
            delegatingAuthorization: caller)
        }
      }
      let validateLaunch: @Sendable () throws -> Void = {
        try validateProvider?()
        try GatewayProviderReadExceptions.verify(configuration.readExceptions)
      }
      let prepared = PreparedExecutionContext(
        authority: authority,
        mode: sandbox.map { .sandbox($0) } ?? .fullAccess, environment: environment,
        limits: execution.limits,
        pathAccess: GatewayPathAccess(
          store: store, authorizationID: compiledAuthorizationID,
          additionalAuthorizationIDs: callback?.authorizationIDs ?? [],
          validateWorktree: validateWorktree, validateInvocation: validateLaunch
        ),
        permitsProgramLaunch: configuration.permitsProgramLaunch,
        fixedHostOperation: context.fixedHostOperation, worktreeGit: context.worktree?.git,
        validateWorktree: validateWorktree, provider: provider, providerProject: providerProject,
        providerWorkingDirectory: providerWorkingDirectory, providerExecutable: providerExecutable,
        validateProvider: validateLaunch)
      try validateLaunch()
      _ = try authority.access(execution.id, operation: .readResult)
      lock.withLock { contexts[execution.id] = WeakExecutionContext(prepared) }
      return prepared
    } catch {
      try? finishAdmission(execution.id)
      try? await reconcile()
      throw error
    }
  }

  package func continuation(
    authorizationID: UUID, connectionID: String? = nil,
    additionalAuthorizationIDs: Set<UUID> = []
  ) throws -> any ExecutionAccessChecking {
    try persistAuthorizationRevocations()
    let result: Result<Principal, any Error> = try store.transactionWithDatabase { _, ledger in
      Result {
        for id in additionalAuthorizationIDs { _ = try ledger.invocationAccess(id) }
        return try ledger.invocationAccess(authorizationID).invocation.principal
      }
    }
    return GatewayExecutionAccessScope(
      coordinator: self, principal: try result.get(), connectionID: connectionID,
      authorizationID: authorizationID, additionalAuthorizationIDs: additionalAuthorizationIDs,
      pathAccess: GatewayPathAccess(
        store: store, authorizationID: authorizationID,
        additionalAuthorizationIDs: additionalAuthorizationIDs))
  }

  /// Seals locally before attempting storage. Failed writes remain queued until
  /// reconciliation commits them; recovery retires all work from a lost host.
  package func revokeInvocations(_ ids: Set<UUID>) {
    let executions = publication.withLock {
      lock.withLock {
        pendingAuthorizationRevocations.formUnion(ids)
        let executions = Set(
          contexts.compactMap { id, context in
            context.value?.authority.authorizationIDs.isDisjoint(with: ids) == false ? id : nil
          })
        closedAdmissions.formUnion(executions)
        pendingOwnerStops.formUnion(executions)
        return executions
      }
    }
    Task { [self] in
      do { try await stopExecutionResources(executions) } catch { notify() }
    }
    notify()
  }

  private func persistAuthorizationRevocations() throws {
    let ids = lock.withLock { pendingAuthorizationRevocations }
    guard !ids.isEmpty else { return }
    try store.transactionWithDatabase { _, ledger in
      for id in ids where ledger.authorizations[id] != nil {
        _ = try ledger.revokeAuthorization(id)
      }
    }
    lock.withLock { pendingAuthorizationRevocations.subtract(ids) }
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
  package func stopExecutions(
    _ ids: Set<UUID>, until deadline: ContinuousClock.Instant? = nil
  ) async throws {
    try await ExecutionReconciliation().run(until: deadline) { [self] in
      try await stopExecutionResources(ids)
    }
  }

  private func stopExecutionResources(_ ids: Set<UUID>) async throws {
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
        try await cancelOwnedExecution(ownership)
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
    guard records.allSatisfy({ $0.worktreeDurable != nil }) else {
      throw WorktreeError.busy("Writer ownership mode is unavailable.")
    }
    if records.contains(where: { $0.worktreeDurable == false }) {
      try await terminateMixedWorktreeWriters(
        records, admission: admission, operationID: operationID, until: deadline)
      return
    }
    guard records.allSatisfy({ $0.children.values.allSatisfy { $0.recovery?.sandboxed != false } })
    else {
      throw WorktreeError.busy("A sandbox writer has unconfined children.")
    }
    try Task.checkCancellation()
    guard ContinuousClock.now < deadline else {
      throw WorktreeError.busy("Writer deadline expired.")
    }
    try await stopExecutions(Set(uses.map(\.executionID)), until: deadline)
    while true {
      try Task.checkCancellation()
      guard ContinuousClock.now < deadline else {
        throw WorktreeError.busy("Worktree writer termination is incomplete.")
      }
      try await reconcile(until: deadline)
      guard ContinuousClock.now < deadline else {
        throw WorktreeError.busy("Worktree writer termination is incomplete.")
      }
      do {
        try admission.requireDrained(operationID: operationID)
        return
      } catch WorktreeError.busy {
        try await Task.sleep(
          until: min(deadline, ContinuousClock.now.advanced(by: .milliseconds(10))),
          clock: .continuous)
      }
    }
  }

  /// Full access releases only the worktree barrier after an attempted stop. Its
  /// execution receipts, physical cleanup and host admission failure policy remain owned.
  private func terminateMixedWorktreeWriters(
    _ records: [ExecutionRuntimeRecord], admission: WorktreeAdmission, operationID: UUID,
    until deadline: ContinuousClock.Instant
  ) async throws {
    try Task.checkCancellation()
    let unconfined = records.filter { $0.worktreeDurable == false }
    let durable = records.filter { $0.worktreeDurable == true }
    let unconfinedRoots = Set(
      unconfined.flatMap { $0.children.values.compactMap { $0.recovery?.root } })
    // Confirm sandboxed owners first; unrelated unconfined completion cannot
    // replace the sandbox receipt checks below.
    if !durable.isEmpty {
      do { try await stopExecutions(Set(durable.map(\.id)), until: deadline) } catch let failure
        as ExecutionCompletionFailure
      {
        guard unconfinedRoots.contains(try failure.ownership.recoveryState().root) else {
          throw failure
        }
      }
    }
    let ids = Set(unconfined.map(\.id))
    let resources = publication.withLock {
      lock.withLock {
        closedAdmissions.formUnion(ids)
        pendingOwnerStops.formUnion(ids)
        return (
          children: unconfined.flatMap { record in
            record.children.compactMap { child, entry in
              !entry.completed
                ? children[child].map { (record.id, child, entry.recovery?.sandboxed == false, $0) }
                : nil
            }
          },
          cancellations: logicalWork.values.filter { ids.contains($0.executionID) }.compactMap {
            $0.takeCancellation()
          }
        )
      }
    }
    try persistOwnerStops(ids)
    defer { notify() }
    for cancellation in resources.cancellations { Task.detached { await cancellation() } }
    var attempts: Set<UUID> = []
    var warnings: [UUID: [String]] = [:]
    var failure: (any Error)?
    await withTaskGroup(of: Result<(UUID, UUID, String?), any Error>.self) { group in
      for (executionID, child, bestEffort, ownership) in resources.children {
        group.addTask { [self] in
          do {
            do {
              _ = try await ownership.cancel(until: deadline)
              try confirmChild(child, executionID: executionID)
              return .success((executionID, child, nil))
            } catch is ExecutionWaitExpired where bestEffort {
              let root = try ownership.recoveryState().root
              return .success(
                (
                  executionID, child,
                  "PID \(root.processID) (identity \(root.identity)): completion unconfirmed at the caller deadline."
                ))
            } catch let error as ExecutionCompletionFailure where bestEffort {
              // A best-effort removal does not turn infrastructure failure into successful
              // execution completion or reopen global admission.
              lock.withLock { ready = false }
              Task.detached { [self] in await failClosedResources() }
              let members = error.members.map {
                "PID \($0.process.processID) (identity \($0.process.identity)): \($0.reason)"
              }
              return .success(
                (executionID, child, (members + error.reasons).joined(separator: "; ")))
            }
          } catch { return .failure(error) }
        }
      }
      for await result in group {
        switch result {
        case .success(let (executionID, child, warning)):
          attempts.insert(child)
          if let warning { warnings[executionID, default: []].append(warning) }
        case .failure(let error): failure = failure ?? error
        }
      }
    }
    if let failure { throw failure }
    while true {
      try Task.checkCancellation()
      let receipts = try journal.all()
      let current = try store.readWithDatabase { database, _ in
        try records.map { original in
          guard let record = try ExecutionRuntimeRecord.load(original.id, database),
            record.ownerID == ownerID, record.worktreeUse == original.worktreeUse
          else { throw WorktreeError.busy("Writer ownership changed during termination.") }
          return record
        }
      }
      for record in current {
        guard record.admissionFinished, record.invocationInFlight != true,
          record.workIDs?.isEmpty ?? true, let use = record.worktreeUse
        else { continue }
        if record.worktreeDurable == true {
          guard record.children.values.allSatisfy(\.completed),
            receipts.filter({ $0.execution == record.id }).allSatisfy(\.completed)
          else { continue }
          try admission.acknowledge(use)
        } else {
          guard
            record.children.allSatisfy({ child, entry in
              entry.completed || (entry.recovery?.sandboxed == false && attempts.contains(child))
            })
          else { continue }
          try admission.acknowledgeUnconfined(
            use, operationID: operationID,
            unconfirmedTermination: warnings[record.id].map { $0.joined(separator: "; ") })
        }
      }
      do {
        try admission.requireDrained(operationID: operationID)
        return
      } catch WorktreeError.busy {
        guard ContinuousClock.now < deadline else {
          throw WorktreeError.busy(
            "Host invocations or sandboxed writer receipts are still pending.")
        }
        try await Task.sleep(
          until: min(deadline, ContinuousClock.now.advanced(by: .milliseconds(10))),
          clock: .continuous)
      }
    }
  }

  /// Cleanup belongs to the execution owner, independently of any caller's wait.
  private func cancelOwnedExecution(_ ownership: any ExecutionOwnership) async throws {
    while true {
      do {
        _ = try await ownership.cancel()
        return
      } catch is ExecutionWaitExpired { continue }
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

  package func reconcile(until deadline: ContinuousClock.Instant? = nil) async throws {
    try await reconciliation.run(until: deadline) { [self] in
      do {
        try await reconcileResources()
        try resumeAfterReconciliationIfDrained()
      } catch {
        await failClosedResources()
        throw error
      }
    }
  }

  private func failClosedResources() async {
    let resources = lock.withLock {
      ready = false
      return (
        Array(children.values), Array(proxies.values),
        logicalWork.values.compactMap { $0.takeCancellation() }
      )
    }
    for cancellation in resources.2 { Task.detached { await cancellation() } }
    for proxy in resources.1 { try? await proxy.revoke() }
    for ownership in resources.0 { try? await cancelOwnedExecution(ownership) }
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
    authorizationID: UUID? = nil, additionalAuthorizationIDs: Set<UUID> = [],
    discovery: GatewayDiscoverySelection? = nil
  )
    throws -> EffectiveExecutionLimits
  {
    try persistAuthorizationRevocations()
    if operation == .writeInput { try requireWorktreeAdmission(id) }
    let outcome: (Result<EffectiveExecutionLimits, any Error>, Bool) =
      try store.transactionWithDatabase {
        _, ledger in
        for id in additionalAuthorizationIDs { _ = try ledger.invocationAccess(id) }
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
          let localStop = lock.withLock {
            pendingOwnerStops.contains(id)
              || !pendingAuthorizationRevocations.isDisjoint(
                with: discovery?.authorizationIDs ?? [])
          }
          if operation == .writeInput, decision == .denied(.executionEnded),
            let discovery, discovery.executionID == id, !localStop,
            ledger.executions[id]?.limitEndReason == .timeLimit,
            (try? discovery.validate(in: &ledger, operation: .readResult, now: Date())) != nil
          {
            result = .failure(GatewayDiscoveryExpired(selection: discovery))
          } else {
            result = .failure(PermissionModelError.invalidAuthorization)
          }
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

  /// Local stop publication precedes the policy transaction, never the reverse.
  func withDiscoveryAdmission<T>(
    _ replacement: GatewayDiscoveryReplacement?, caller: GatewayDiscoveryCaller?,
    _ body: () throws -> T
  ) throws -> T {
    try publication.withLock {
      try persistAuthorizationRevocations()
      let caller = replacement?.caller ?? caller
      let ids = (replacement?.selected.authorizationIDs ?? []).union(
        replacement?.reuse?.authority.authorizationIDs ?? []
      ).union(caller?.authorizationIDs ?? [])
      let executions = Set(
        [
          replacement?.selected.executionID, replacement?.reuse?.executionID, caller?.executionID,
        ].compactMap { $0 })
      guard
        lock.withLock({
          ready && pendingOwnerStops.isDisjoint(with: executions)
            && pendingAuthorizationRevocations.isDisjoint(with: ids)
        })
      else { throw PermissionModelError.invalidAuthorization }
      return try body()
    }
  }

  fileprivate func permissionRequests(
    _ id: UUID, principal: Principal, connectionID: String?, authorizationID: UUID? = nil,
    additionalAuthorizationIDs: Set<UUID> = []
  ) throws -> [PermissionRequest] {
    try persistAuthorizationRevocations()
    return try permissionDiscovery.requests(
      id, principal: principal, connectionID: connectionID, authorizationID: authorizationID,
      additionalAuthorizationIDs: additionalAuthorizationIDs)
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
    authority: GatewayExecutionAuthority, continuation: Bool = false,
    cancellation: @escaping @Sendable () async -> Void
  ) throws -> ExecutionWorkLease {
    // A locally sealed revocation refuses new work before storage confirms it.
    try persistAuthorizationRevocations()
    let workID = UUID()
    try publication.withLock {
      try requireWorktreeAdmission(authority.executionID)
      try store.transactionWithDatabase { database, ledger in
        guard lock.withLock({ ready && !pendingOwnerStops.contains(authority.executionID) }),
          var record = try ExecutionRuntimeRecord.load(authority.executionID, database),
          record.ownerID == ownerID, !record.completed,
          continuation
            ? !(record.workIDs ?? []).isEmpty
            : (!record.admissionFinished
              && !lock.withLock({ closedAdmissions.contains(authority.executionID) })),
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
    try persistAuthorizationRevocations()
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
      if let firstError { throw firstError }
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
            // Confirmation persists the receipt before retiring the live handle.
            // Both can have changed since the reconciliation snapshot was read.
            let (local, confirmed): ((any ExecutionOwnership)?, Bool) = try publication.withLock {
              if let ownership = lock.withLock({ children[child] }) { return (ownership, false) }
              let confirmed = try store.readWithDatabase { database, _ in
                try ExecutionRuntimeRecord.load(record.id, database)?.children[child]?.completed
                  == true
              }
              return (nil, confirmed)
            }
            if confirmed { continue }
            if let ownership = local {
              try await cancelOwnedExecution(ownership)
            } else if let recovery = entry.recovery {
              guard let boot = launcher.bootSessionID else {
                throw ExecutionEnvironmentError.unavailable("Recovery boot identity is unavailable")
              }
              if record.boot == boot {
                let ownership = try await launcher.recover(recovery)
                lock.withLock { children[child] = ownership }
                try await cancelOwnedExecution(ownership)
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
          try await cancelOwnedExecution(ownership)
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
        try await cancelOwnedExecution(ownership)
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
  let discovery: GatewayDiscoverySelection?
  init(
    coordinator: ExecutionRevocationCoordinator, executionID: UUID, authorizationIDs: Set<UUID>,
    principal: Principal, connectionID: String?, discovery: GatewayDiscoverySelection?
  ) {
    self.coordinator = coordinator
    self.executionID = executionID
    self.authorizationIDs = authorizationIDs
    self.principal = principal
    self.connectionID = connectionID
    self.discovery = discovery
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
  func retainContinuation(cancellation: @escaping @Sendable () async -> Void) throws
    -> ExecutionWorkLease
  {
    try coordinator.retainWork(authority: self, continuation: true, cancellation: cancellation)
  }
  func access(_ id: UUID, operation: ExecutionOperation) throws -> EffectiveExecutionLimits {
    try coordinator.access(
      id, principal: principal, connectionID: connectionID, operation: operation,
      discovery: discovery)
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
  private var current: (id: UUID, task: Task<Void, any Error>)?

  func run(
    until deadline: ContinuousClock.Instant? = nil,
    _ operation: @escaping @Sendable () async throws -> Void
  ) async throws {
    if current == nil {
      let id = UUID()
      let task = Task {
        defer { if current?.id == id { current = nil } }
        try await operation()
      }
      current = (id, task)
    }
    let work = current!
    if let deadline {
      // Reconciliation also serves other callers. Expiry stops this wait, while
      // the owner retains the in-flight cleanup and its durable completion proof.
      while current?.id == work.id {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
          throw WorktreeError.busy("Worktree writer termination is incomplete.")
        }
        try await Task.sleep(
          until: min(deadline, ContinuousClock.now.advanced(by: .milliseconds(10))),
          clock: .continuous)
      }
      try Task.checkCancellation()
    }
    try await work.task.value
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
  let additionalAuthorizationIDs: Set<UUID>
  let authorizationID: UUID
  let pathAccess: (any HostPathAccessChecking)?
  private let lock = NSLock()
  private var observed: Set<UUID> = []

  init(
    coordinator: ExecutionRevocationCoordinator, principal: Principal, connectionID: String?,
    authorizationID: UUID, additionalAuthorizationIDs: Set<UUID>,
    pathAccess: (any HostPathAccessChecking)?
  ) {
    self.coordinator = coordinator
    self.principal = principal
    self.connectionID = connectionID
    self.authorizationID = authorizationID
    self.additionalAuthorizationIDs = additionalAuthorizationIDs
    self.pathAccess = pathAccess
  }
  func accessExecution(_ id: UUID, operation: ExecutionOperation) throws -> EffectiveExecutionLimits
  {
    let limits = try coordinator.access(
      id, principal: principal, connectionID: connectionID, operation: operation,
      authorizationID: authorizationID, additionalAuthorizationIDs: additionalAuthorizationIDs)
    lock.withLock { _ = observed.insert(id) }
    return limits
  }

  func permissionRequests(_ id: UUID) throws -> [PermissionRequest] {
    try coordinator.permissionRequests(
      id, principal: principal, connectionID: connectionID, authorizationID: authorizationID,
      additionalAuthorizationIDs: additionalAuthorizationIDs)
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

extension GatewayDiscoveryCaller {
  init(context: InvocationContext) {
    let prepared =
      (context.executionAuthority ?? InvocationExecution.current) as? PreparedExecutionContext
    let authority = prepared?.authority as? GatewayExecutionAuthority
    let cancelled = context.isDiscoveryCancelled
    executionID = prepared?.executionID
    authorizationIDs = prepared?.authority.authorizationIDs ?? []
    check = {
      do {
        if cancelled?() == true { throw CancellationError() }
        if let prepared {
          _ = try prepared.accessExecution(prepared.executionID, operation: .writeInput)
        }
      } catch { throw GatewayDiscoveryCallerStopped(underlying: error) }
    }
    checkLedger = { ledger, now in
      do {
        if cancelled?() == true { throw CancellationError() }
        if let prepared {
          guard let authority,
            ledger.executionAccess(
              prepared.executionID, principal: authority.principal, operation: .writeInput,
              connectionID: authority.connectionID, authorizingInvocation: nil, now: now)
              == .allowed
          else { throw PermissionModelError.invalidAuthorization }
        }
      } catch { throw GatewayDiscoveryCallerStopped(underlying: error) }
    }
  }
}
