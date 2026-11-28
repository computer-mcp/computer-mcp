import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPProcess
import ComputerMCPSandbox
import ComputerMCPTestSupport
import Darwin
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPlatform
@testable import ComputerMCPPlatformDarwin

@Suite(.nativeIntegration, .serialized, .timeLimit(.minutes(1)))
struct GatewayRuntimeExecutionLifetimeTests {
  @Test(arguments: [false, true])
  func shutdownJoinsOnlyItsGenerationWhenAuthorityIsShared(synchronous: Bool) async throws {
    let fixture = try RuntimeExecutionLifetimeFixture()
    defer { fixture.removeFiles() }
    let first = try await fixture.runtime(principal: "first-runtime")
    let second = try await fixture.runtime(principal: "second-runtime")
    let firstAuthority = try fixture.database.permissionRuntime(platform: fixture.platform)
    let secondAuthority = try fixture.database.permissionRuntime(platform: fixture.platform)
    #expect(firstAuthority === secondAuthority)
    #expect(first.generationID != second.generationID)
    let firstCall = fixture.startCall(first, label: "first", synchronous: synchronous)
    var secondCall: Task<Result<JSONValue, any Error>, Never>?
    do {
      let firstStart = try await fixture.waitForStart(excluding: [], label: "first")
      let pendingSecond = fixture.startCall(second, label: "second", synchronous: synchronous)
      secondCall = pendingSecond
      let secondStart = try await fixture.waitForStart(
        excluding: [firstStart.executionID], label: "second")
      #expect(firstStart.member.processID != secondStart.member.processID)
      #expect(kill(firstStart.member.processID, 0) == 0)
      #expect(kill(secondStart.member.processID, 0) == 0)
      let stoppingFirst = ContinuousClock.now
      await first.shutdown()
      #expect(kill(firstStart.member.processID, 0) == -1 && errno == ESRCH)
      _ = await firstCall.value
      #expect(stoppingFirst.duration(to: .now) < .seconds(10))
      #expect(first.ownedWork.snapshot.isEmpty)
      #expect(kill(secondStart.member.processID, 0) == 0)
      #expect(!fixture.observation.finished("second"))
      let usable = try await fixture.call(
        second, name: "system.time", synchronous: synchronous)
      #expect(usable.objectValue?["isError"] != .bool(true))
      #expect(usable.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue != nil)
      #expect(kill(secondStart.member.processID, 0) == 0)
      let stoppingSecond = ContinuousClock.now
      await second.shutdown()
      #expect(kill(secondStart.member.processID, 0) == -1 && errno == ESRCH)
      _ = await pendingSecond.value
      #expect(stoppingSecond.duration(to: .now) < .seconds(10))
      #expect(second.ownedWork.snapshot.isEmpty)
      #expect(fixture.observation.starts.count == 2)
      fixture.expectEveryNativeAttemptExited()
    } catch {
      await first.shutdown()
      await second.shutdown()
      _ = await firstCall.value
      _ = await secondCall?.value
      throw error
    }
  }

  @Test(arguments: [false, true])
  func shutdownClosesAdmissionWhileNativeStartIsReserved(synchronous: Bool) async throws {
    let observation = RuntimeExecutionLifetimeObservation()
    let gate = RuntimeExecutionStartGate(observation: observation)
    let fixture = try RuntimeExecutionLifetimeFixture(observation: observation, gate: gate)
    defer { fixture.removeFiles() }
    let runtime = try await fixture.runtime(principal: "reserved-runtime")
    let calling = fixture.startCall(runtime, label: "reserved", synchronous: synchronous)
    var stopping: Task<Void, Never>?
    do {
      try await fixture.waitForGate(label: "reserved")
      #expect(observation.starts.isEmpty)
      #expect(observation.attempts.isEmpty)
      let shutdownStartedAt = ContinuousClock.now
      let pendingStop = Task {
        await runtime.shutdown()
        observation.stopped()
      }
      stopping = pendingStop
      try await fixture.waitForClosedAdmission(runtime)
      await #expect(throws: (any Error).self) {
        try await fixture.call(runtime, name: "system.time", synchronous: synchronous)
      }
      #expect(!observation.stopCompleted)
      await gate.release()
      await pendingStop.value
      let result = await calling.value
      if case .success(let value) = result {
        Issue.record("A stopped runtime completed its reserved helper call: \(value)")
      }
      #expect(shutdownStartedAt.duration(to: .now) < .seconds(10))
      fixture.expectEveryNativeAttemptExited()
      #expect(runtime.ownedWork.snapshot.isEmpty)
    } catch {
      await gate.release()
      await runtime.shutdown()
      await stopping?.value
      _ = await calling.value
      throw error
    }
  }
}

private final class RuntimeExecutionLifetimeFixture: @unchecked Sendable {
  let root: URL
  let database: GatewayDatabase
  let platform: PlatformServices
  let observation: RuntimeExecutionLifetimeObservation
  private let configuration: GatewayConfiguration
  private let blocking = BlockingOperationExecutor(
    label: "computer-mcp.runtime-lifetime-test", serial: false)

  init(
    observation: RuntimeExecutionLifetimeObservation = RuntimeExecutionLifetimeObservation(),
    gate: RuntimeExecutionStartGate? = nil
  ) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    database = try GatewayDatabase(path: root.appendingPathComponent("gateway.sqlite").path)
    _ = database.permissionStore(counter: TestAuthorizationEpochCounter())
    self.observation = observation
    let executionDirectory = root.appendingPathComponent(
      "gateway.sqlite.executions", isDirectory: true)
    let bootstrap = try nativeGatewayTestExecutable().deletingLastPathComponent()
      .appendingPathComponent("computer-mcp-execution-bootstrap")
    let launcher = ExecutionLauncher(
      platform: RuntimeReadOnlyHelperPlatform(
        directory: executionDirectory, bootstrap: bootstrap, observation: observation, gate: gate))
    var platform = MacOSPlatform.services(launcher: launcher)
    platform.permissionPolicyReader = TestManagedPolicyReader()
    self.platform = platform
    let grant = ProfileGrant(
      id: .localAdmin,
      permissions: fixturePermissions([.machineInformation: .granted(.access)]),
      allowedCallers: [.localCLI])
    configuration = GatewayConfiguration(
      runtime: .init(caller: .localCLI, profileID: grant.id), profiles: [.init(grant: grant)],
      builtin: .init(enabled: ["system.software", "system.time"]), projectDirectory: root)
    try database.bootstrapPermissionProfiles([grant], declarations: [grant])
    _ = try database.permissionRuntime(platform: platform)
  }

  func runtime(principal: String) async throws -> GatewayRuntime {
    try await GatewayRuntime.make(
      configuration: configuration,
      context: .init(
        caller: .localCLI, profileID: .localAdmin, trustedPrincipalID: principal),
      database: database, registeredProjects: [], platform: platform)
  }

  func call(_ runtime: GatewayRuntime, name: String, synchronous: Bool) async throws -> JSONValue {
    let arguments: JSONValue = .object(
      name == "system.software" ? ["timeout_ms": .number(60_000)] : [:])
    if synchronous {
      return try await blocking.perform {
        try runtime.callTool(name: name, arguments: arguments, context: .empty)
      }
    }
    return try await runtime.callToolAsync(name: name, arguments: arguments, context: .empty)
  }

  func startCall(_ runtime: GatewayRuntime, label: String, synchronous: Bool)
    -> Task<Result<JSONValue, any Error>, Never>
  {
    Task {
      let result: Result<JSONValue, any Error>
      do {
        result = .success(
          try await call(runtime, name: "system.software", synchronous: synchronous))
      } catch {
        result = .failure(error)
      }
      observation.completed(label, result: result)
      return result
    }
  }

  func waitForStart(excluding: Set<UUID>, label: String) async throws -> RuntimeExecutionStart {
    var changes = observation.changed.stream().makeAsyncIterator()
    while true {
      if let start = observation.starts.first(where: { !excluding.contains($0.executionID) }) {
        return start
      }
      if let completion = observation.completion(label) {
        throw RuntimeExecutionFixtureError.earlyCompletion(completion)
      }
      guard await changes.next() != nil else { throw CancellationError() }
    }
  }

  func waitForGate(label: String) async throws {
    var changes = observation.changed.stream().makeAsyncIterator()
    while !observation.enteredGate {
      if let completion = observation.completion(label) {
        throw RuntimeExecutionFixtureError.earlyCompletion(completion)
      }
      guard await changes.next() != nil else { throw CancellationError() }
    }
  }

  func waitForClosedAdmission(_ runtime: GatewayRuntime) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    repeat {
      do {
        let probe = try runtime.ownedWork.admitInvocation(
          projectID: nil, resourceID: "lifetime-admission-probe")
        probe.finish()
      } catch let error as GatewayToolError {
        guard case .disabled(let message) = error, message.contains("[runtime.retired]") else {
          throw error
        }
        return
      }
      await Task.yield()
    } while ContinuousClock.now < deadline
    throw RuntimeExecutionFixtureError.admissionStayedOpen
  }

  func expectEveryNativeAttemptExited() {
    for member in observation.attempts {
      #expect(
        kill(member.processID, 0) == -1 && errno == ESRCH,
        "Shutdown must join native PID \(member.processID) before returning")
    }
  }

  func removeFiles() { try? FileManager.default.removeItem(at: root) }
}

private struct RuntimeExecutionStart: Sendable {
  let executionID: UUID
  let member: ExecutionMember
}

private final class RuntimeExecutionLifetimeObservation: @unchecked Sendable {
  let changed = GatewayToolChangeBroadcaster()
  private let lock = NSLock()
  private var ready: [RuntimeExecutionStart] = []
  private var native: Set<ExecutionMember> = []
  private var completions: [String: String] = [:]
  private var gateEntered = false
  private var shutdownCompleted = false
  var starts: [RuntimeExecutionStart] { lock.withLock { ready } }
  var attempts: Set<ExecutionMember> { lock.withLock { native } }
  var enteredGate: Bool { lock.withLock { gateEntered } }
  var stopCompleted: Bool { lock.withLock { shutdownCompleted } }

  func attempted(_ member: ExecutionMember) {
    _ = lock.withLock { native.insert(member) }
  }

  func started(executionID: UUID, member: ExecutionMember) {
    lock.withLock { ready.append(.init(executionID: executionID, member: member)) }
    changed.send()
  }

  func entered() {
    lock.withLock { gateEntered = true }
    changed.send()
  }

  func stopped() { lock.withLock { shutdownCompleted = true } }

  func completed(_ label: String, result: Result<JSONValue, any Error>) {
    let description: String
    switch result {
    case .success(let value): description = "Returned \(value)"
    case .failure(let error): description = "Threw \(String(reflecting: error))"
    }
    lock.withLock { completions[label] = description }
    changed.send()
  }

  func completion(_ label: String) -> String? { lock.withLock { completions[label] } }
  func finished(_ label: String) -> Bool { completion(label) != nil }
}

private actor RuntimeExecutionStartGate {
  let observation: RuntimeExecutionLifetimeObservation
  private var released = false
  private var waiter: CheckedContinuation<Void, Never>?

  init(observation: RuntimeExecutionLifetimeObservation) { self.observation = observation }

  func wait() async {
    observation.entered()
    // A reserved start stays pending until the test permits its binding attempt.
    if !released { await withCheckedContinuation { waiter = $0 } }
  }

  func release() {
    released = true
    waiter?.resume()
    waiter = nil
  }
}

/// The only substituted program is a finite single-process read-only helper.
private struct RuntimeReadOnlyHelperPlatform: ExecutionPlatform {
  let directory: URL
  let observation: RuntimeExecutionLifetimeObservation
  let gate: RuntimeExecutionStartGate?
  private let base: DarwinExecutionPlatform

  init(
    directory: URL, bootstrap: URL, observation: RuntimeExecutionLifetimeObservation,
    gate: RuntimeExecutionStartGate?
  ) {
    self.directory = directory.resolvingSymlinksInPath()
    self.observation = observation
    self.gate = gate
    base = DarwinExecutionPlatform(bootstrapExecutable: bootstrap)
  }

  var supportsRecovery: Bool { base.supportsRecovery }
  var bootSessionID: String? { base.bootSessionID }
  var hostSystemReadPaths: [SandboxPath] { base.hostSystemReadPaths }
  func supportsDurableOwnership(sandboxed: Bool) -> Bool {
    base.supportsDurableOwnership(sandboxed: sandboxed)
  }

  func start(
    _ command: ExecutionCommand, sandbox: SandboxConfiguration?, method: ExecutionLaunchMethod,
    input: Int32, output: Int32, error: Int32,
    bindOwnership: @Sendable (any ExecutionOwnership) -> Void
  ) async throws -> any ExecutionOwnership {
    let workingDirectory = URL(fileURLWithPath: command.directory.value).resolvingSymlinksInPath()
    guard command.executable.value == "/usr/bin/sw_vers", command.arguments.isEmpty,
      let prepared = try PreparedExecutionContext.current(),
      case .sandbox(let admitted) = prepared.mode, let sandbox, sandbox.readOnly,
      admitted.readOnly, command.directory == sandbox.worktree,
      admitted.worktree == sandbox.worktree,
      workingDirectory.deletingLastPathComponent().path == directory.path,
      UUID(uuidString: workingDirectory.lastPathComponent) != nil,
      command.inheritedDescriptors.isEmpty
    else {
      throw ExecutionEnvironmentError.unavailable(
        "Only the admitted system.software helper is supported")
    }
    await gate?.wait()
    let waiting = ExecutionCommand(
      executable: try SandboxPath("/bin/sleep"), arguments: ["30"],
      directory: command.directory, environment: command.environment,
      directoryDescriptor: command.directoryDescriptor,
      inheritedDescriptors: command.inheritedDescriptors)
    let ownership = try await base.start(
      waiting, sandbox: sandbox, method: method, input: input, output: output, error: error,
      bindOwnership: { owner in
        owner.beforeStart { member in observation.attempted(member) }
        bindOwnership(owner)
      })
    observation.started(
      executionID: prepared.executionID, member: try ownership.recoveryState().root)
    return ownership
  }

  func recover(_ state: ExecutionRecoveryState) async throws -> any ExecutionOwnership {
    try await base.recover(state)
  }

  func interrupt(_ members: [ExecutionMember]) async throws { try await base.interrupt(members) }

  func releaseRecovery(_ state: ExecutionRecoveryState) throws { try base.releaseRecovery(state) }
}

private enum RuntimeExecutionFixtureError: Error {
  case earlyCompletion(String)
  case admissionStayedOpen
}
