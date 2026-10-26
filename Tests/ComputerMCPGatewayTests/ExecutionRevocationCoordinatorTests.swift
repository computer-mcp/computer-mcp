import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPEgress
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPSandbox
import Foundation
import Testing

@testable import ComputerMCPGateway
@testable import ComputerMCPProcess

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite struct ExecutionRevocationCoordinatorTests {
  @Test(arguments: ["prepared", "reserved", "bound", "older-record"])
  func restoredRuntimeRecordReleasesProxyAfterEveryReservationSettles(stage: String) async throws {
    let f = try ExecutionFixture()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: false)
    try f.paths.store.transactionWithDatabase { _, ledger in
      _ = try ledger.setSandboxSettings(
        .init(network: .full), for: .init(principal: f.paths.principal, projectID: "project"),
        expectedRevision: ledger.revision)
    }
    let box = ExecutionProxyBox()
    let coordinator = try f.coordinator(proxyFactory: { id, policy in
      let proxy = try await EgressProxy.start(
        executionID: id.uuidString, policy: policy,
        routing: ExecutionTestRouting(onCancel: { box.markReleased() }), limits: .init())
      box.set(proxy)
      return proxy
    })
    try await coordinator.recover()
    let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
    let pending = UUID()
    let unbound = stage == "reserved" || stage == "older-record"
    if unbound { try prepared.authority.reserveChild(pending) }
    if stage == "bound" { _ = try await f.start(prepared) }
    try f.paths.store.transactionWithDatabase { database, _ in
      if stage == "older-record" {
        var record = try #require(try ExecutionRuntimeRecord.load(prepared.executionID, database))
        record.children.removeAll()
        record.admissionFinished = true
        try record.save(database)
      } else {
        try database.execute(sql: "DELETE FROM permissionRuntimeExecutions")
      }
    }
    try await coordinator.reconcile()
    #expect(throws: (any Error).self) { try prepared.authority.reserveChild(UUID()) }
    if unbound {
      #expect(!box.released)
      prepared.authority.launchFailed(pending)
    }
    for _ in 0..<100 {
      try await coordinator.reconcile()
      if box.released { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(box.released)
    #expect(f.platform.owners.allSatisfy { $0.ended })
  }

  @Test func consumedRetryOwnsChildrenAndCannotStartTwice() async throws {
    let f = try ExecutionFixture()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: true)
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
    let first = try await f.start(prepared)
    let second = try await f.start(prepared)
    #expect(f.platform.started == 2)
    await #expect(throws: (any Error).self) {
      try await coordinator.prepare(authorizationID: id, context: f.context)
    }
    try prepared.finishAdmission()
    await #expect(throws: (any Error).self) { try await f.start(prepared) }
    _ = try await first.cancel()
    try await coordinator.reconcile()
    #expect(try f.execution(prepared.executionID).isRunning)
    _ = try await second.cancel()
    try await f.untilFinished(prepared.executionID, coordinator)
    #expect(
      try prepared.accessExecution(prepared.executionID, operation: .readResult).outputBytes
        == 8_388_608)
    #expect(throws: (any Error).self) {
      try prepared.accessExecution(prepared.executionID, operation: .writeInput)
    }
    try f.revoke()
    try await coordinator.reconcile()
    #expect(throws: (any Error).self) {
      try prepared.accessExecution(prepared.executionID, operation: .readResult)
    }
  }

  @Test func cancelQueuesEveryChildWithoutRevokingRetainedResults() async throws {
    let f = try ExecutionFixture()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: true)
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
    _ = try await f.start(prepared)
    _ = try await f.start(prepared)
    try prepared.finishAdmission()
    _ = try prepared.accessExecution(prepared.executionID, operation: .cancel)
    try await f.untilFinished(prepared.executionID, coordinator)
    #expect(f.platform.owners.allSatisfy { $0.ended })
    _ = try prepared.accessExecution(prepared.executionID, operation: .readResult)
  }

  @Test(arguments: [false, true]) func failedLaunchDoesNotResurrectRetry(afterBinding: Bool)
    async throws
  {
    let f = try ExecutionFixture()
    f.platform.fail = afterBinding ? .afterBinding : .beforeBinding
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: true)
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
    await #expect(throws: (any Error).self) { try await f.start(prepared) }
    try await f.untilFinished(prepared.executionID, coordinator)
    await #expect(throws: (any Error).self) {
      try await coordinator.prepare(authorizationID: id, context: f.context)
    }
    #expect(
      try f.paths.store.readWithDatabase { _, ledger in ledger.authorizations[id]?.executionID }
        == prepared.executionID)
  }

  @Test func revocationStopsChildrenAndClosesProxy() async throws {
    let f = try ExecutionFixture()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: false)
    try f.paths.store.transactionWithDatabase { _, ledger in
      _ = try ledger.setSandboxSettings(
        .init(network: .full), for: .init(principal: f.paths.principal, projectID: "project"),
        expectedRevision: ledger.revision)
    }
    let box = ExecutionProxyBox()
    let coordinator = try f.coordinator(proxyFactory: { id, policy in
      let proxy = try await EgressProxy.start(
        executionID: id.uuidString, policy: policy,
        routing: ExecutionTestRouting(), limits: .init())
      box.set(proxy)
      return proxy
    })
    try await coordinator.recover()
    let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
    _ = try await f.start(prepared)
    _ = try await f.start(prepared)
    try prepared.finishAdmission()
    let proxy = try #require(box.value)
    _ = try await proxy.sandboxPorts()
    try f.revoke()
    try await f.untilFinished(prepared.executionID, coordinator)
    #expect(f.platform.owners.allSatisfy { $0.ended })
    await #expect(throws: (any Error).self) { try await proxy.sandboxPorts() }
    #expect(throws: (any Error).self) {
      try prepared.accessExecution(prepared.executionID, operation: .readResult)
    }
  }

  @Test(arguments: [false, true]) func connectionLifetime(connectionLimited: Bool) async throws {
    let f = try ExecutionFixture()
    let id = try f.authorizeConnection(limited: connectionLimited)
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    let prepared = try await coordinator.prepare(
      authorizationID: id,
      context: connectionLimited ? f.programContext : f.context, connectionID: "first")
    let owner = try await f.start(prepared)
    try prepared.finishAdmission()
    try f.paths.store.transactionWithDatabase { _, ledger in
      var environment = ledger.environment
      environment.endedConnections.insert("first")
      _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    }
    try await coordinator.reconcile()
    if connectionLimited {
      try await f.untilFinished(prepared.executionID, coordinator)
      #expect(f.platform.owners.allSatisfy { $0.ended })
    } else {
      #expect(try f.execution(prepared.executionID).isRunning)
      let next = try f.paths.authorize(f.paths.project, operation: .read, once: false)
      let scope = try coordinator.continuation(authorizationID: next)
      _ = try scope.accessExecution(prepared.executionID, operation: .readResult)
      try f.paths.store.transactionWithDatabase { _, ledger in try ledger.finishInvocation(next) }
      #expect(throws: (any Error).self) {
        try scope.accessExecution(prepared.executionID, operation: .readResult)
      }
      _ = try await owner.cancel()
      try await f.untilFinished(prepared.executionID, coordinator)
    }
  }

  @Test(arguments: [
    "reserve", "child", "bind", "finish", "release", "ack", "epoch", "database-rollback",
  ])
  func crashBoundariesRecoverWithoutRestoringPermission(stage: String) async throws {
    let f = try ExecutionFixture()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: true)
    let execution = try f.paths.store.transactionWithDatabase { _, ledger in
      try ledger.startExecution(owner: f.paths.principal, authorizationIDs: [id])
    }
    let child = UUID()
    let owner = f.platform.makeOwner()
    let recovery = try owner.recoveryState()
    var record = ExecutionRuntimeRecord(id: execution.id, ownerID: UUID(), boot: "boot")
    if stage != "reserve" {
      record.children[child] = .init(
        recovery: stage == "child" ? nil : recovery,
        completed: ["finish", "release", "ack"].contains(stage),
        released: ["release", "ack"].contains(stage))
    }
    if ["finish", "release", "ack"].contains(stage) { owner.complete() }
    if stage == "ack" {
      record.completed = true
      record.admissionFinished = true
    }
    try f.paths.store.transactionWithDatabase { database, ledger in
      try record.save(database)
      if stage == "database-rollback" {
        try database.execute(sql: "DELETE FROM permissionRuntimeExecutions")
      }
    }
    if ["epoch", "database-rollback"].contains(stage) { f.paths.counter.forget() }
    if !["reserve", "child"].contains(stage) {
      let journal = try ExecutionRecoveryJournal(
        directory: f.directory.appendingPathComponent("ownership"))
      try journal.save(
        .init(
          child: child, execution: execution.id, owner: record.ownerID,
          boot: "boot", recovery: recovery, completed: owner.ended, released: stage == "ack"))
    }
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    if !["reserve", "child"].contains(stage) { #expect(owner.ended) }
    if !["epoch", "database-rollback"].contains(stage) {
      #expect(try f.execution(execution.id).interruptedAt != nil || stage == "ack")
      #expect(
        try f.paths.store.readWithDatabase { _, ledger in
          !ledger.pendingExecutionTerminations.contains(execution.id)
        })
      await #expect(throws: (any Error).self) {
        try await coordinator.prepare(authorizationID: id, context: f.context)
      }
    } else {
      #expect(
        try f.paths.store.readWithDatabase { _, ledger in
          ledger.suspendedAuthority != nil || ledger.pendingEpochRecovery != nil
        })
    }
  }

  @Test func tighteningLimitsUpdatesObserversAndEndsUnsupportedMemoryUse() async throws {
    let f = try ExecutionFixture()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: false)
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
    _ = try await f.start(prepared)
    try prepared.finishAdmission()
    try f.limits(
      .init(outputBytes: 16, memoryBytes: 1024, retentionSeconds: 1, retainedOutputBytes: 32))
    try await f.untilFinished(prepared.executionID, coordinator)
    #expect(prepared.limits.outputBytes == 16)
    #expect(prepared.limits.memoryBytes == 1024)
    #expect(prepared.limits.retentionSeconds == 1)
    #expect(prepared.limits.retainedOutputBytes == 32)
    #expect(prepared.limitEndReason == .memoryLimitUnavailable)
  }

  @Test func tighteningElapsedTimeEndsExecution() async throws {
    let f = try ExecutionFixture()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: false)
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
    _ = try await f.start(prepared)
    try prepared.finishAdmission()
    try await Task.sleep(for: .milliseconds(20))
    try f.limits(.init(timeMilliseconds: 1))
    try await f.untilFinished(prepared.executionID, coordinator)
    #expect(prepared.limitEndReason == .timeLimit)
  }
}

private final class ExecutionFixture: @unchecked Sendable {
  let paths: DurablePathFixture
  let platform = DurableTestPlatform()
  var directory: URL { paths.root.appendingPathComponent("runtime") }
  var context: GatewaySandboxContext {
    .init(
      directory: try! SandboxPath(paths.project.path),
      temporaryDirectory: try! SandboxPath(paths.derived.path))
  }
  var programContext: GatewaySandboxContext {
    .init(
      directory: try! SandboxPath(paths.project.path),
      temporaryDirectory: try! SandboxPath(paths.derived.path), purpose: .projectProgram)
  }
  init() throws { paths = try DurablePathFixture() }
  func coordinator(
    launcher: ExecutionLauncher? = nil,
    proxyFactory: ExecutionRevocationCoordinator.ProxyFactory? = nil
  ) throws -> ExecutionRevocationCoordinator {
    try .init(
      store: paths.store, launcher: launcher ?? ExecutionLauncher(platform: platform),
      directory: directory, proxyFactory: proxyFactory)
  }
  func start(_ prepared: PreparedExecutionContext) async throws -> any ExecutionOwnership {
    try await prepared.withValue {
      try await ExecutionLauncher(platform: platform).start(
        executable: .init("/bin/true"), arguments: [],
        directory: .init(paths.project.path), environment: prepared.environment, mode: .fullAccess)
    }
  }
  func execution(_ id: UUID) throws -> AuthorizedExecution {
    try paths.store.readWithDatabase { _, ledger in try #require(ledger.executions[id]) }
  }
  func untilFinished(_ id: UUID, _ coordinator: ExecutionRevocationCoordinator) async throws {
    for _ in 0..<100 {
      try await coordinator.reconcile()
      let completed = try paths.store.readWithDatabase { database, ledger in
        try ExecutionRuntimeRecord.load(id, database)?.completed == true
          && !ledger.pendingExecutionTerminations.contains(id)
      }
      if completed { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Execution did not finish")
  }
  func revoke() throws {
    try paths.store.transactionWithDatabase { _, ledger in
      _ = try ledger.revoke(
        principal: paths.principal, permission: .project("project"),
        expectedRevision: ledger.revision)
    }
  }
  func limits(_ limits: ExecutionLimitCeilings) throws {
    try paths.store.transactionWithDatabase { _, ledger in
      var environment = ledger.environment
      environment.limits[paths.principal] = ManagedLimits(sources: [
        .managedPreferences: .available(ManagedPolicy(executionLimits: limits))
      ])
      _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    }
  }
  func authorizeConnection(limited: Bool) throws -> UUID {
    _ = try paths.authorize(paths.project, operation: .read, once: false)
    return try paths.store.transactionWithDatabase { _, ledger in
      var environment = ledger.environment
      let mode: ComputerMCPPermissions.ExecutionMode =
        limited ? .fullAccess(.connection("first")) : .sandbox
      let consent = limited ? ledger.consent(for: paths.principal, mode: mode) : nil
      environment.connections["first"] = .init(
        principal: paths.principal, consent: consent, attenuation: .init())
      _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
      let decision = try ledger.authorize(
        invocation: .init(
          principal: paths.principal, tool: "shell.spawn", projectID: "project",
          argumentsDigest: "call"),
        requirements: .init(
          paths: [.init(path: CanonicalPath(paths.project.path), operation: .read)], mode: mode,
          sandboxProjectID: "project"), connectionID: "first", now: Date())
      guard case .allowed(let proof) = decision else {
        throw PermissionModelError.invalidAuthorization
      }
      return proof.id
    }
  }
}

private final class DurableTestPlatform: ExecutionPlatform, @unchecked Sendable {
  enum Failure { case beforeBinding, afterBinding }
  private let lock = NSLock()
  private var values: [DurableTestOwnership] = []
  var fail: Failure?
  var owners: [DurableTestOwnership] { lock.withLock { values } }
  var started: Int { owners.count }
  var supportsRecovery: Bool { true }
  var bootSessionID: String? { "boot" }
  func supportsDurableOwnership(sandboxed: Bool) -> Bool { true }
  func makeOwner() -> DurableTestOwnership {
    lock.withLock {
      let owner = DurableTestOwnership(
        member: .init(processID: Int32(values.count + 100), identity: UInt64(values.count + 100)))
      values.append(owner)
      return owner
    }
  }
  func start(
    _ command: ExecutionCommand, sandbox: SandboxConfiguration?, method: ExecutionLaunchMethod,
    input: Int32, output: Int32, error: Int32,
    bindOwnership: @Sendable (any ExecutionOwnership) -> Void
  ) async throws -> any ExecutionOwnership {
    if fail == .beforeBinding { throw CancellationError() }
    let owner = makeOwner()
    bindOwnership(owner)
    do {
      try owner.admit()
      if fail == .afterBinding { throw CancellationError() }
      return owner
    } catch {
      owner.complete()
      throw error
    }
  }
  func recover(_ state: ExecutionRecoveryState) async throws -> any ExecutionOwnership {
    try #require(owners.first { $0.member == state.root })
  }
}

private final class DurableTestOwnership: ExecutionOwnership, @unchecked Sendable {
  let member: ExecutionMember
  private let lock = NSLock()
  private var handlers: [@Sendable (ExecutionMember) throws -> Void] = []
  private var cancellations: [@Sendable () -> Void] = []
  private var finished = false
  var ended: Bool { lock.withLock { finished } }
  init(member: ExecutionMember) { self.member = member }
  func recoveryState() throws -> ExecutionRecoveryState {
    .init(root: member, sandboxed: true, backend: "test")
  }
  func beforeStart(_ handler: @escaping @Sendable (ExecutionMember) throws -> Void) {
    lock.withLock { handlers.append(handler) }
  }
  func admit() throws {
    let pending = lock.withLock {
      let pending = handlers
      handlers.removeAll()
      return pending
    }
    for handler in pending { try handler(member) }
  }
  func complete() {
    lock.withLock {
      finished = true
      handlers.removeAll()
    }
  }
  func members() async throws -> [ExecutionMember] { ended ? [] : [member] }
  func onCancellation(_ handler: @escaping @Sendable () -> Void) {
    lock.withLock { cancellations.append(handler) }
  }
  func cancel(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit {
    for handler in lock.withLock({ cancellations }) { handler() }
    complete()
    return .init(status: 0)
  }
  func wait(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit {
    while !ended {
      if ContinuousClock.now >= deadline {
        throw ExecutionCompletionFailure(
          ownership: self, members: [], reasons: ["pending"], bestEffort: false)
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    return .init(status: 0)
  }
}

private final class ExecutionProxyBox: @unchecked Sendable {
  private let lock = NSLock()
  private var proxy: EgressProxy?
  private var didRelease = false
  var value: EgressProxy? { lock.withLock { proxy } }
  var released: Bool { lock.withLock { didRelease } }
  func markReleased() { lock.withLock { didRelease = true } }
  func set(_ proxy: EgressProxy) { lock.withLock { self.proxy = proxy } }
}

private struct ExecutionTestRouting: EgressRouting {
  let onCancel: @Sendable () -> Void
  init(onCancel: @escaping @Sendable () -> Void = {}) { self.onCancel = onCancel }
  func observeChanges(_ handler: @escaping @Sendable (EgressRouteEvent) -> Void) throws
    -> any EgressRouteObservation
  { ExecutionTestObservation(onCancel: onCancel) }
  func route(to numericAddress: String) throws -> EgressRoute {
    .init(interface: "en0", interfaceIndex: 1, isTunnel: false, isDirect: false)
  }
}

private struct ExecutionTestObservation: EgressRouteObservation {
  let onCancel: @Sendable () -> Void
  func cancel() { onCancel() }
}

#if os(macOS)
  @Suite(.nativeIntegration, .serialized) struct AuthorizedProcessIntegrationTests {
    @Test(arguments: [ExecutionLaunchMethod.subprocess, .foundation, .posixSpawn], [false, true])
    func failedNativeLaunchReleasesResourcesAndAllowsNextExecution(
      method: ExecutionLaunchMethod, beforeSpawn: Bool
    ) async throws {
      let f = try ExecutionFixture()
      let launcher = testExecutionLauncher()
      try f.paths.store.transactionWithDatabase { _, ledger in
        _ = try ledger.setSandboxSettings(
          .init(network: .full), for: .init(principal: f.paths.principal, projectID: "project"),
          expectedRevision: ledger.revision)
      }
      let box = ExecutionProxyBox()
      let coordinator = try f.coordinator(
        launcher: launcher,
        proxyFactory: { id, policy in
          let proxy = try await EgressProxy.start(
            executionID: id.uuidString, policy: policy,
            routing: ExecutionTestRouting(onCancel: { box.markReleased() }), limits: .init())
          box.set(proxy)
          return proxy
        })
      try await coordinator.recover()
      let id = try f.paths.authorize(f.paths.project, operation: .read, once: true)
      let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
      let owners = FailedLaunchOwnerships()
      if beforeSpawn { try FileManager.default.removeItem(at: f.paths.project) }
      await #expect(throws: (any Error).self) {
        try await prepared.withValue {
          try await launcher.start(
            executable: .init("/usr/bin/true"), arguments: [],
            directory: .init(f.paths.project.path),
            environment: prepared.environment, mode: prepared.mode, method: method,
            bindOwnership: { owner in
              owners.bind(owner)
              if !beforeSpawn {
                owner.beforeStart { _ in
                  throw ExecutionEnvironmentError.launchFailed("Admission failed")
                }
              }
            })
        }
      }
      let owner = try #require(owners.value)
      _ = try await owner.waitForExit()
      _ = try await owner.cancel()
      try await f.untilFinished(prepared.executionID, coordinator)
      #expect(box.released)
      let children = try f.paths.store.readWithDatabase { database, _ in
        try #require(try ExecutionRuntimeRecord.load(prepared.executionID, database)).children
      }
      #expect(children.count == 1)
      #expect(children.values.allSatisfy { $0.completed && $0.released })
      await #expect(throws: (any Error).self) {
        try await coordinator.prepare(authorizationID: id, context: f.context)
      }
      if beforeSpawn {
        try FileManager.default.createDirectory(
          at: f.paths.project, withIntermediateDirectories: true)
      }
      let nextID = try f.paths.authorize(f.paths.project, operation: .read, once: true)
      let next = try await coordinator.prepare(authorizationID: nextID, context: f.context)
      let nextOwner = try await next.withValue {
        try await launcher.start(
          executable: .init("/usr/bin/true"), arguments: [], directory: .init(f.paths.project.path),
          environment: next.environment, mode: next.mode, method: method)
      }
      try next.finishAdmission()
      #expect(try await nextOwner.waitForExit().status == 0)
      try await f.untilFinished(next.executionID, coordinator)
    }

    @Test func proxyRefusesUnsupportedLaunchAndRevokedAuthority() async throws {
      let f = try ExecutionFixture()
      let launcher = testExecutionLauncher()
      let coordinator = try f.coordinator(launcher: launcher)
      try await coordinator.recover()
      let marker = f.paths.project.appendingPathComponent("unconfined-launch")
      let server = MCPServerConfig(
        id: "authorized", transport: .stdio, command: "/bin/sh",
        args: ["-c", "printf unconfined > \"$1\"", "fixture", marker.path],
        startupTimeoutMs: 1000, requestTimeoutMs: 1000)
      let client = MCPProxyClient(launcher: launcher, workingDirectory: f.paths.project)
      let id = try f.paths.authorize(f.paths.project, operation: .read, once: true)
      let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
      let calls = BlockingOperationExecutor(label: "test.authorized-proxy")
      // Stdio supervision needs a verified server context and inherited host handles.
      // Until that context is supported, the real proxy must refuse sandbox startup.
      await #expect(throws: (any Error).self) {
        try await prepared.withValue {
          try await calls.perform { try client.listTools(server: server, context: .empty) }
        }
      }
      #expect(!FileManager.default.fileExists(atPath: marker.path))
      try prepared.finishAdmission()
      try f.revoke()
      try await f.untilFinished(prepared.executionID, coordinator)
      await #expect(throws: (any Error).self) {
        try await prepared.withValue {
          try await client.callToolAsync(
            server: server, name: "inspect", arguments: .object([:]), requestID: nil,
            context: .empty)
        }
      }
      #expect(!FileManager.default.fileExists(atPath: marker.path))
      let completed = try f.paths.store.readWithDatabase { database, _ in
        try #require(try ExecutionRuntimeRecord.load(prepared.executionID, database))
      }
      #expect(completed.completed)
      #expect(completed.children.values.allSatisfy { $0.completed && $0.released })
      await client.shutdown()
    }

    @Test func proxyRejectsAuthorityWithoutPreparedLaunchContext() async throws {
      let f = try ExecutionFixture()
      let launcher = testExecutionLauncher()
      let coordinator = try f.coordinator(launcher: launcher)
      try await coordinator.recover()
      let id = try f.paths.authorize(f.paths.project, operation: .read, once: false)
      let scope = try coordinator.continuation(authorizationID: id)
      let client = MCPProxyClient(launcher: launcher, workingDirectory: f.paths.project)
      let server = MCPServerConfig(
        id: "unprepared", transport: .stdio, command: "/bin/cat", startupTimeoutMs: 1000)
      let calls = BlockingOperationExecutor(label: "test.unprepared-proxy")
      do {
        _ = try await InvocationExecution.$current.withValue(scope) {
          try await calls.perform { try client.listTools(server: server, context: .empty) }
        }
        Issue.record("Unprepared authority launched a downstream server")
      } catch {
        #expect(String(describing: error).contains("prepared launch context"))
      }
      await client.shutdown()
    }

    @Test func cliBlockingBridgeKeepsPreparedModeAndLimits() async throws {
      let f = try ExecutionFixture()
      let launcher = testExecutionLauncher()
      let coordinator = try f.coordinator(launcher: launcher)
      try await coordinator.recover()
      try f.limits(.init(outputBytes: 4))
      let id = try f.paths.authorize(f.paths.project, operation: .read, once: true)
      let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
      let cli = CLIProcessExecution(launcher: launcher, policy: .fullAccess)
      let result = try await prepared.withValue {
        try await cli.launchAsync(
          executable: "/usr/bin/printf",
          invocation: .init(arguments: ["12345678"], standardInput: Data()), cwd: f.paths.project,
          environment: [:], timeoutMilliseconds: 2000, maxOutputBytes: 1024)
      }
      try prepared.finishAdmission()
      try await f.untilFinished(prepared.executionID, coordinator)
      #expect(result.executionID == prepared.executionID)
      #expect(result.stdout.base64 == Data("5678".utf8).base64EncodedString())
      #expect(result.droppedBytes == 4)
      await cli.shutdown()
    }

    @Test func oneTimeShellOutputSurvivesCompletionAndTighteningButNotRevocation() async throws {
      let f = try ExecutionFixture()
      let launcher = testExecutionLauncher()
      let coordinator = try f.coordinator(launcher: launcher)
      try await coordinator.recover()
      let id = try f.paths.authorize(f.paths.project, operation: .read, once: true)
      let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
      let runtime = ShellSessionRuntime(launcher: launcher)
      let blocking = BlockingOperationExecutor(label: "test.authorized-shell", serial: false)
      let result = try await prepared.withValue {
        try await blocking.perform {
          try runtime.run(
            request: .init(
              mode: .argv, executable: "/bin/sh", argv: ["-c", "printf 1234; printf 5678 >&2"]),
            defaultShell: "/bin/sh", defaultWorkingDirectory: f.paths.project,
            timeoutMilliseconds: 2000, maxOutputBytes: 1024, maxSessions: 1)
        }
      }
      try prepared.finishAdmission()
      try await f.untilFinished(prepared.executionID, coordinator)
      try f.limits(.init(outputBytes: 3))
      try await coordinator.reconcile()
      let retained = try prepared.withValue {
        try runtime.read(
          sessionID: result.sessionID, stdoutCursor: 0, stderrCursor: 0, maxReadBytes: 1024,
          encoding: .utf8)
      }
      #expect(
        (retained.stdout.text?.utf8.count ?? 0) + (retained.stderr.text?.utf8.count ?? 0) == 3)
      #expect(retained.droppedBytes == 5)
      try f.revoke()
      try await coordinator.reconcile()
      #expect(throws: (any Error).self) {
        try prepared.withValue {
          try runtime.read(
            sessionID: result.sessionID, stdoutCursor: 0, stderrCursor: 0, maxReadBytes: 1024,
            encoding: .utf8)
        }
      }
      await runtime.shutdown()
    }

    @Test func asyncShellWriteRechecksAuthorityAndRevocationReleasesBlockedWriter() async throws {
      let f = try ExecutionFixture()
      let launcher = testExecutionLauncher()
      let coordinator = try f.coordinator(launcher: launcher)
      try await coordinator.recover()
      let id = try f.paths.authorize(f.paths.project, operation: .read, once: true)
      let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
      let runtime = ShellSessionRuntime(launcher: launcher)
      let blocking = BlockingOperationExecutor(label: "test.authorized-spawn", serial: false)
      let sessionID = try await prepared.withValue {
        try await blocking.perform {
          try runtime.spawn(
            request: .init(mode: .argv, executable: "/bin/sleep", argv: ["60"]),
            defaultShell: "/bin/sh", defaultWorkingDirectory: f.paths.project,
            timeoutMilliseconds: nil, maxOutputBytes: 1024, maxSessions: 1)
        }
      }
      try prepared.finishAdmission()
      await #expect(throws: (any Error).self) {
        try await runtime.writeAsync(sessionID: sessionID, data: Data("denied".utf8), close: false)
      }
      let writer = Task {
        try await prepared.withValue {
          try await runtime.writeAsync(
            sessionID: sessionID, data: Data(repeating: 65, count: 1_048_576), close: false)
        }
      }
      try await Task.sleep(for: .milliseconds(50))
      try f.revoke()
      try await coordinator.reconcile()
      await #expect(throws: (any Error).self) { try await writer.value }
      await runtime.shutdown()
    }

    @Test func unsupportedFullAccessIsRefusedBeforeReservation() async throws {
      let f = try ExecutionFixture()
      let id = try f.paths.authorize(
        f.paths.project, operation: .read, once: false, fullAccess: true)
      let coordinator = try f.coordinator(launcher: testExecutionLauncher())
      try await coordinator.recover()
      await #expect(throws: ExecutionEnvironmentError.self) {
        try await coordinator.prepare(authorizationID: id, context: f.programContext)
      }
      #expect(
        try f.paths.store.readWithDatabase { _, ledger in ledger.authorizations[id]?.executionID }
          == nil)
    }
  }
#endif

@Suite struct AuthorizedOutputRecoveryTests {
  @Test func finalAuthorityCheckRebuildsOutputAfterTightening() async throws {
    let f = try ExecutionFixture()
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: true)
    let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
    try prepared.finishAdmission()
    try await f.untilFinished(prepared.executionID, coordinator)
    let scope = GatewayTerminalSessions.Scope.isolated(UUID())
    let directory = f.paths.root.appendingPathComponent("output")
    let record = record(
      prepared, scope: scope, stdout: "12345678", stderr: "", offset: -1,
      order: [.init(stdout: true, count: 8)])
    try save([record], to: directory)
    let storage = GatewayTerminalSessions()
    let launcher = ExecutionLauncher(platform: f.platform)
    try storage.enablePersistence(at: directory, launcher: launcher, authority: coordinator)
    let runtime = ShellSessionRuntime(launcher: launcher, sessions: storage, scope: scope)
    let authority = TighteningReadAuthority(prepared: prepared) {
      try f.limits(.init(outputBytes: 3))
    }
    let value = try InvocationExecution.$current.withValue(authority) {
      try runtime.read(
        sessionID: record.snapshot.sessionID, stdoutCursor: 0, stderrCursor: 0, maxReadBytes: 1024,
        encoding: .utf8)
    }
    #expect(value.stdout.text == "678")
    #expect(value.droppedBytes == 5)
    #expect(value.permissionLimits?.outputBytes == 3)
  }

  @Test func staleInitialCallbackCannotWidenRetainedLimits() async throws {
    let f = try ExecutionFixture()
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: true)
    let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
    try prepared.finishAdmission()
    try await f.untilFinished(prepared.executionID, coordinator)
    let original = prepared.limits
    let scope = GatewayTerminalSessions.Scope.isolated(UUID())
    let directory = f.paths.root.appendingPathComponent("output")
    let record = record(
      prepared, scope: scope, stdout: "12345678", stderr: "", offset: -1,
      order: [.init(stdout: true, count: 8)])
    try save([record], to: directory)
    try f.limits(.init(outputBytes: 3, retentionSeconds: 60, retainedOutputBytes: 32))
    try await coordinator.reconcile()
    let tightened = prepared.limits
    prepared.applyLimits(original)
    #expect(prepared.limits == tightened)
    let storage = GatewayTerminalSessions()
    try storage.enablePersistence(
      at: directory, launcher: ExecutionLauncher(platform: f.platform),
      authority: ReorderedRecoveryAuthority(original: original, tightened: tightened))
    let saved = try JSONDecoder().decode(
      TerminalSessionJournal.Record.self,
      from: Data(contentsOf: directory.appendingPathComponent(record.snapshot.sessionID + ".json")))
    #expect(saved.snapshot.permissionLimits == tightened)
    #expect(saved.snapshot.stdout.base64 == Data("678".utf8).base64EncodedString())
  }

  @Test func recoveredInterleavedOutputTightensInArrivalOrder() async throws {
    let f = try ExecutionFixture()
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    let id = try f.paths.authorize(f.paths.project, operation: .read, once: true)
    let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
    try prepared.finishAdmission()
    try await f.untilFinished(prepared.executionID, coordinator)
    let scope = GatewayTerminalSessions.Scope.isolated(UUID())
    let directory = f.paths.root.appendingPathComponent("output")
    let record = record(
      prepared, scope: scope, stdout: "abcd", stderr: "efgh", offset: -1,
      order: [
        .init(stdout: true, count: 2), .init(stdout: false, count: 4),
        .init(stdout: true, count: 2),
      ])
    try save([record], to: directory)
    let storage = GatewayTerminalSessions()
    let launcher = ExecutionLauncher(platform: f.platform)
    try storage.enablePersistence(at: directory, launcher: launcher, authority: coordinator)
    let runtime = ShellSessionRuntime(
      launcher: launcher, sessions: storage, scope: scope, recoveryKey: { nil })
    try f.limits(.init(outputBytes: 3))
    try await coordinator.reconcile()
    let value = try prepared.withValue {
      try runtime.read(
        sessionID: record.snapshot.sessionID, stdoutCursor: 0, stderrCursor: 0, maxReadBytes: 1024,
        encoding: .utf8)
    }
    #expect(value.stdout.text == "cd")
    #expect(value.stderr.text == "h")
    #expect(value.droppedBytes == 5)
    #expect(value.permissionLimits?.outputBytes == 3)
    #expect(throws: (any Error).self) {
      try runtime.read(
        sessionID: record.snapshot.sessionID, stdoutCursor: 0, stderrCursor: 0, maxReadBytes: 1024,
        encoding: .utf8)
    }
  }

  @Test func retainedOutputEvictsOldestWithoutKeepingSmallerOlderResults() async throws {
    let f = try ExecutionFixture()
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    try f.limits(.init(retainedOutputBytes: 20))
    let scope = GatewayTerminalSessions.Scope.isolated(UUID())
    var records: [TerminalSessionJournal.Record] = []
    var contexts: [PreparedExecutionContext] = []
    for (index, count) in [5, 15, 10].enumerated() {
      let id = try f.paths.authorize(f.paths.project, operation: .read, once: false)
      let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
      try prepared.finishAdmission()
      try await f.untilFinished(prepared.executionID, coordinator)
      records.append(
        record(
          prepared, scope: scope, stdout: String(repeating: "x", count: count), stderr: "",
          offset: Double(index - 3), order: [.init(stdout: true, count: count)]))
      contexts.append(prepared)
    }
    let directory = f.paths.root.appendingPathComponent("output")
    try save(records, to: directory)
    let storage = GatewayTerminalSessions()
    let launcher = ExecutionLauncher(platform: f.platform)
    try storage.enablePersistence(at: directory, launcher: launcher, authority: coordinator)
    let runtime = ShellSessionRuntime(launcher: launcher, sessions: storage, scope: scope)
    let visible = try contexts[2].withValue { try runtime.list() }
    #expect(visible.map(\.sessionID) == [records[2].snapshot.sessionID])
  }

  @Test func epochRetiredResultIsRemovedWithoutBlockingStoreRestoration() async throws {
    let f = try ExecutionFixture()
    let scope = GatewayTerminalSessions.Scope.isolated(UUID())
    let directory = f.paths.root.appendingPathComponent("output")
    do {
      let coordinator = try f.coordinator()
      try await coordinator.recover()
      let id = try f.paths.authorize(f.paths.project, operation: .read, once: false)
      let prepared = try await coordinator.prepare(authorizationID: id, context: f.context)
      try prepared.finishAdmission()
      try await f.untilFinished(prepared.executionID, coordinator)
      try save(
        [
          record(
            prepared, scope: scope, stdout: "retired", stderr: "", offset: -1,
            order: [.init(stdout: true, count: 7)])
        ], to: directory)
    }
    f.paths.counter.forget()
    // The monitor has no resource lease after the final execution/context releases it.
    try await Task.sleep(for: .milliseconds(300))
    let coordinator = try f.coordinator()
    try await coordinator.recover()
    #expect(
      try f.paths.store.readWithDatabase { _, ledger in
        ledger.pendingEpochRecovery == nil && ledger.suspendedAuthority != nil
      })
    let storage = GatewayTerminalSessions()
    let launcher = ExecutionLauncher(platform: f.platform)
    try storage.enablePersistence(at: directory, launcher: launcher, authority: coordinator)
    let runtime = ShellSessionRuntime(launcher: launcher, sessions: storage, scope: scope)
    #expect(try runtime.list().isEmpty)
  }

  private func save(_ records: [TerminalSessionJournal.Record], to directory: URL) throws {
    let journal = try TerminalSessionJournal(directory: directory, bootSessionID: "boot")
    for record in records { try journal.save(record) }
  }

  private func record(
    _ prepared: PreparedExecutionContext, scope: GatewayTerminalSessions.Scope,
    stdout: String, stderr: String, offset: Double, order: [ShellOutputSegment]
  ) -> TerminalSessionJournal.Record {
    func stream(_ text: String) -> ShellStreamRead {
      .init(
        requestedCursor: 0, startCursor: 0, nextCursor: Int64(text.utf8.count),
        endCursor: Int64(text.utf8.count), missedBytes: false, truncated: false, encoding: .base64,
        text: nil, base64: Data(text.utf8).base64EncodedString())
    }
    return .init(
      recoveryKey: nil, bootSessionID: "boot", scope: scope, isRegisteredProcess: false,
      snapshot: .init(
        sessionID: UUID().uuidString, processID: nil, isRunning: false, exitCode: 0,
        signal: nil, timedOut: false, cancelled: false,
        startedAt: Date().addingTimeInterval(offset - 1),
        finishedAt: Date().addingTimeInterval(offset), launchError: nil, streamErrors: [],
        stdout: stream(stdout), stderr: stream(stderr), executionID: prepared.executionID,
        permissionLimits: prepared.limits),
      members: [], outputOrder: order)
  }
}

private final class TighteningReadAuthority: ExecutionAccessChecking, @unchecked Sendable {
  let pathAccess: (any HostPathAccessChecking)? = nil
  let prepared: PreparedExecutionContext
  let tighten: @Sendable () throws -> Void
  private let lock = NSLock()
  private var calls = 0
  init(prepared: PreparedExecutionContext, tighten: @escaping @Sendable () throws -> Void) {
    self.prepared = prepared
    self.tighten = tighten
  }
  func accessExecution(_ id: UUID, operation: ExecutionOperation) throws -> EffectiveExecutionLimits
  {
    let finalCheck = lock.withLock {
      calls += 1
      return calls == 3
    }
    if finalCheck { try tighten() }
    return try prepared.accessExecution(id, operation: operation)
  }
}

private struct ReorderedRecoveryAuthority: ExecutionRecoveryAuthorizing {
  let original: EffectiveExecutionLimits
  let tightened: EffectiveExecutionLimits
  func recoveredExecution(_ id: UUID) throws -> EffectiveExecutionLimits? { original }
  func observeExecutionLimits(
    _ id: UUID, _ observer: @escaping @Sendable (EffectiveExecutionLimits) -> Void
  ) throws {
    observer(tightened)
    observer(original)
  }
}

private final class FailedLaunchOwnerships: @unchecked Sendable {
  private let lock = NSLock()
  private var owner: (any ExecutionOwnership)?
  var value: (any ExecutionOwnership)? { lock.withLock { owner } }
  func bind(_ owner: any ExecutionOwnership) { lock.withLock { self.owner = owner } }
}
