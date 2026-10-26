import ComputerMCPMacOS
import ComputerMCPTestSupport
import Darwin
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPlatform
@testable import ComputerMCPPlugins
@testable import ComputerMCPProcess

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.nativeIntegration, .serialized)
struct GatewayTerminalSessionsTests {
  private let directory = FileManager.default.temporaryDirectory

  @Test
  func completedOutputOutlivesLaunchingGenerationWithoutRetainingIt() async throws {
    let storage = GatewayTerminalSessions()
    let scope = GatewayTerminalSessions.Scope.isolated(UUID())
    let owners = GatewayOwnedWork()
    var old: ShellSessionRuntime? = ShellSessionRuntime(
      launcher: testExecutionLauncher(),
      ownedWork: owners, projectID: "test", sessions: storage, scope: scope)
    weak let previous = old
    let id = try spawnCat(try #require(old))
    let current = ShellSessionRuntime(
      launcher: testExecutionLauncher(), sessions: storage, scope: scope)
    #expect(owners.snapshot.map(\.resourceID) == [id])
    old = nil
    #expect(previous == nil)
    _ = try await current.writeAsync(sessionID: id, data: Data("final-output".utf8), close: true)
    let result = try current.wait(
      sessionID: id, timeoutMilliseconds: 2_000, maxReadBytes: 1_024, encoding: .utf8)
    try await drained(owners)
    #expect(owners.closeAdmissionIfDrained())
    #expect(result.stdout.text == "final-output")
    #expect(try read(current, id).stdout.text == "final-output")
    let rest = try current.read(
      sessionID: id, stdoutCursor: result.stdout.nextCursor, stderrCursor: 0,
      maxReadBytes: 1_024, encoding: .utf8)
    #expect(rest.stdout.text == "")
    #expect(rest.stdout.nextCursor == result.stdout.nextCursor)
  }

  @Test
  func processClassificationAndOriginalOutputBudgetSurviveReplacement() async throws {
    let storage = GatewayTerminalSessions()
    let scope = GatewayTerminalSessions.Scope.isolated(UUID())
    let owners = GatewayOwnedWork()
    var old: ManagedProcessRegistry? = ManagedProcessRegistry(
      launcher: testExecutionLauncher(),
      shellManager: ShellSessionRuntime(
        launcher: testExecutionLauncher(), ownedWork: owners, sessions: storage, scope: scope))
    weak let previous = old
    let id = try #require(old).spawn(
      executable: "/bin/cat", arguments: [], workingDirectory: directory,
      environment: [:], maxOutputBytes: 4)
    old = nil
    #expect(previous == nil)
    let shell = ShellSessionRuntime(
      launcher: testExecutionLauncher(), sessions: storage, scope: scope)
    let current = ManagedProcessRegistry(launcher: testExecutionLauncher(), shellManager: shell)
    _ = try await shell.writeAsync(sessionID: id, data: Data("12345678".utf8), close: true)
    _ = try shell.wait(sessionID: id, timeoutMilliseconds: 2_000, maxReadBytes: 16, encoding: .utf8)
    try await drained(owners)
    let result = try current.read(processID: id)
    #expect(result.stdout == "5678")
    #expect(result.stdoutTruncated)
    #expect(try current.list().map(\.processID) == [id])
    let ordinary = try run(shell, "printf ordinary")
    #expect(try current.list().map(\.processID) == [id])
    #expect(throws: ProcessRegistryError.unknownProcess(ordinary.sessionID)) {
      try current.read(processID: ordinary.sessionID)
    }
    #expect(throws: ProcessRegistryError.unknownProcess(ordinary.sessionID)) {
      try current.cancel(processID: ordinary.sessionID)
    }
  }

  @Test
  func countBudgetEvictsCompletedResultsWithoutEvictingRunningSessions() throws {
    let storage = GatewayTerminalSessions(
      retention: 86_400, maximumCompletedSessions: 2, maximumCompletedOutputBytes: 1_024)
    let shell = ShellSessionRuntime(launcher: testExecutionLauncher(), sessions: storage)
    let active = try spawnCat(shell)
    defer { _ = try? shell.cancel(sessionID: active) }
    let first = try run(shell, "printf first")
    let second = try run(shell, "printf second")
    let third = try run(shell, "printf third")
    #expect(throws: ShellRuntimeError.unknownSession(first.sessionID)) {
      try read(shell, first.sessionID)
    }
    #expect(
      try shell.list().map(\.sessionID).sorted()
        == [active, second.sessionID, third.sessionID].sorted())
    #expect(try read(shell, active).isRunning)
  }

  @Test
  func outputBudgetIncludesBothStreamsAndRunStillReturnsItsOwnResult() throws {
    let storage = GatewayTerminalSessions(
      retention: 86_400, maximumCompletedSessions: 64, maximumCompletedOutputBytes: 6)
    let shell = ShellSessionRuntime(launcher: testExecutionLauncher(), sessions: storage)
    let oversized = try run(shell, "printf 1234; printf 5678 >&2")
    #expect(oversized.stdout.text == "1234")
    #expect(oversized.stderr.text == "5678")
    #expect(throws: ShellRuntimeError.unknownSession(oversized.sessionID)) {
      try read(shell, oversized.sessionID)
    }
    let first = try run(shell, "printf abcd")
    let second = try run(shell, "printf efgh")
    let third = try run(shell, "printf ij")
    #expect(throws: ShellRuntimeError.unknownSession(first.sessionID)) {
      try read(shell, first.sessionID)
    }
    #expect(
      try shell.list().map(\.sessionID).sorted() == [second.sessionID, third.sessionID].sorted())
    #expect(try read(shell, second.sessionID).stdout.text == "efgh")
    #expect(try read(shell, third.sessionID).stdout.text == "ij")
  }

  @Test
  func expirationRemovesProcessRegistrationButNeverReleasesExecutingWork() async throws {
    let clock = TerminalClock()
    let storage = GatewayTerminalSessions(
      retention: 60, maximumCompletedSessions: 64, maximumCompletedOutputBytes: 1_024,
      now: { clock.now })
    let scope = GatewayTerminalSessions.Scope.isolated(UUID())
    let owners = GatewayOwnedWork()
    let shell = ShellSessionRuntime(
      launcher: testExecutionLauncher(), ownedWork: owners, sessions: storage, scope: scope)
    let process = ManagedProcessRegistry(
      launcher: testExecutionLauncher(), shellManager: shell, maxSessions: 1)
    let id = try process.spawn(
      executable: "/bin/cat", arguments: [], workingDirectory: directory,
      environment: [:], maxOutputBytes: 1_024)
    defer { _ = try? process.cancel(processID: id) }
    let next = ShellSessionRuntime(
      launcher: testExecutionLauncher(), sessions: storage, scope: scope)
    clock.advance(seconds: 120)
    #expect(try process.read(processID: id).isRunning)
    #expect(owners.snapshot.map(\.resourceID) == [id])
    #expect(throws: ShellRuntimeError.sessionLimitReached(1)) { try spawnCat(next, limit: 1) }
    _ = try await next.writeAsync(sessionID: id, data: Data(), close: true)
    // Hold no lookup after completion: expiry may remove the completed entry immediately.
    try await drained(owners)
    #expect(try process.list().isEmpty)
    #expect(throws: ProcessRegistryError.unknownProcess(id)) { try process.read(processID: id) }
    #expect(throws: ShellRuntimeError.unknownSession(id)) { try read(next, id) }
  }

  @Test
  func projectScopeRequiresSameCallerPrincipalProfileRegistrationAndRoot() throws {
    let root = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let context = ExecutionContext(
      caller: .localMCP, profileID: .localAdmin, trustedPrincipalID: "one")
    let project = RegisteredProject(id: "folder", displayName: "Folder", rootPath: root.path)
    let scope = try GatewayTerminalSessions.Scope.project(
      context: context, project: project, root: ProjectRootIdentity(root))
    let storage = GatewayTerminalSessions()
    let shell = ShellSessionRuntime(
      launcher: testExecutionLauncher(), sessions: storage, scope: scope)
    let result = try run(shell, "printf private-result")
    let same = ShellSessionRuntime(
      launcher: testExecutionLauncher(),
      sessions: storage,
      scope: try .project(
        context: context, project: project, root: ProjectRootIdentity(root)))
    #expect(try read(same, result.sessionID).stdout.text == "private-result")
    var foreignPrincipal = context
    foreignPrincipal.trustedPrincipalID = "two"
    var foreignProfile = context
    foreignProfile.profileID = .chatGPTOperate
    var foreignCaller = context
    foreignCaller.caller = .secureTunnel
    var reregistered = project
    reregistered.createdAt = project.createdAt.addingTimeInterval(1)
    var otherID = project
    otherID.id = "another-folder"
    let scopes = try [
      GatewayTerminalSessions.Scope.project(
        context: foreignPrincipal, project: project, root: ProjectRootIdentity(root)),
      .project(context: foreignProfile, project: project, root: ProjectRootIdentity(root)),
      .project(context: foreignCaller, project: project, root: ProjectRootIdentity(root)),
      .project(context: context, project: reregistered, root: ProjectRootIdentity(root)),
      .project(context: context, project: otherID, root: ProjectRootIdentity(root)),
    ]
    for foreign in scopes {
      let isolated = ShellSessionRuntime(
        launcher: testExecutionLauncher(), sessions: storage, scope: foreign)
      #expect(try isolated.list().isEmpty)
      #expect(throws: ShellRuntimeError.unknownSession(result.sessionID)) {
        try read(isolated, result.sessionID)
      }
    }
    let moved = root.appendingPathExtension("old")
    try FileManager.default.moveItem(at: root, to: moved)
    defer { try? FileManager.default.removeItem(at: moved) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let replaced = ShellSessionRuntime(
      launcher: testExecutionLauncher(),
      sessions: storage,
      scope: try .project(
        context: context, project: project, root: ProjectRootIdentity(root)))
    #expect(try replaced.list().isEmpty)
    #expect(throws: ShellRuntimeError.unknownSession(result.sessionID)) {
      try read(replaced, result.sessionID)
    }
  }

  @Test
  func gatewayRetirementPreservesResultsAndCurrentGrantStillControlsAccess() async throws {
    let root = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = RegisteredProject(id: "root", displayName: "Root", rootPath: root.path)
    let database = try GatewayDatabase(inMemory: ())
    try database.saveProject(project)
    let storage = GatewayTerminalSessions()
    let context = ExecutionContext(
      caller: .localMCP, profileID: .localAdmin, projectID: "root", trustedPrincipalID: "owner")
    var configuration = GatewayConfiguration(
      schemaVersion: 1,
      policy: PolicyConfig(shellEnabled: true),
      profiles: [
        ProfileGrantConfig(
          id: .localAdmin,
          capabilities: ["shell.spawn", "shell.read", "shell.write", "shell.cancel"],
          projects: ["root"], allowedCallers: [.localMCP], fullShellEnabled: true,
          mode: .localFullAccess, confirmationPolicy: .never)
      ])
    try database.saveProfile(configuration.profiles[0].grant)
    let old = try await GatewayRuntime.make(
      configuration: configuration, context: context, database: database,
      registeredProjects: [project],
      platform: MacOSPlatform.services(launcher: testExecutionLauncher()),
      bundledPlugins: BundledPlugins(packages: [], issues: []),
      terminalSessions: storage)
    let spawned = try await old.callToolAsync(
      name: "shell.spawn",
      arguments: .object([
        "mode": .string("argv"), "executable": .string("/bin/cat"),
      ]), context: .empty)
    let id = try #require(
      spawned.objectValue?["structuredContent"]?.objectValue?["result"]?
        .objectValue?["session_id"]?.stringValue)
    configuration.policy.maxOutputBytes = 128
    let current = try await GatewayRuntime.make(
      configuration: configuration, context: context, database: database,
      registeredProjects: [project],
      platform: MacOSPlatform.services(launcher: testExecutionLauncher()),
      bundledPlugins: BundledPlugins(packages: [], issues: []),
      terminalSessions: storage)
    do {
      #expect(old.beginRetirementIfDrained() == nil)
      _ = try await current.callToolAsync(
        name: "shell.write",
        arguments: .object([
          "session_id": .string(id), "text": .string("retained-at-gateway"), "close": .bool(true),
        ]), context: .empty)
      try await drained(old.ownedWork)
      let cleanup = try #require(old.beginRetirementIfDrained())
      await cleanup.value
      let result = try await current.callToolAsync(
        name: "shell.read", arguments: .object(["session_id": .string(id)]), context: .empty)
      #expect(
        result.objectValue?["structuredContent"]?.objectValue?["result"]?
          .objectValue?["stdout"]?.objectValue?["text"] == .string("retained-at-gateway"))
      var grant = try #require(try database.profiles().first { $0.id == .localAdmin })
      let revision = grant.authorizationRevision
      grant.fullShellEnabled = false
      try database.saveProfile(grant, expectedRevision: revision)
      let denied = try await current.callToolForMCPAsync(
        name: "shell.read", arguments: .object(["session_id": .string(id)]), context: .empty)
      #expect(denied.objectValue?["isError"] == .bool(true))
      #expect(!String(describing: denied).contains("retained-at-gateway"))
      await current.shutdown()
    } catch {
      await old.shutdown()
      await current.shutdown()
      throw error
    }
  }

  @Test
  func manifestProjectHasStableResultScopeAcrossRuntimeConstruction() async throws {
    let root = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = GatewayTerminalSessions()
    let configuration = GatewayConfiguration(
      schemaVersion: 1, policy: PolicyConfig(shellEnabled: true),
      profiles: [
        ProfileGrantConfig(
          id: .localAdmin, capabilities: ["shell.run", "shell.read"], projects: ["default"],
          allowedCallers: [.localMCP], fullShellEnabled: true, mode: .localFullAccess,
          confirmationPolicy: .never)
      ], projectDirectory: root)
    let first = try await GatewayRuntime.make(
      configuration: configuration,
      platform: MacOSPlatform.services(launcher: testExecutionLauncher()),
      bundledPlugins: BundledPlugins(packages: [], issues: []),
      terminalSessions: storage)
    let completed = try await first.callToolAsync(
      name: "shell.run", arguments: .object(["command": .string("printf manifest-result")]),
      context: .empty)
    let id = try #require(
      completed.objectValue?["structuredContent"]?.objectValue?["result"]?
        .objectValue?["session_id"]?.stringValue)
    await first.shutdown()
    let next = try await GatewayRuntime.make(
      configuration: configuration,
      platform: MacOSPlatform.services(launcher: testExecutionLauncher()),
      bundledPlugins: BundledPlugins(packages: [], issues: []),
      terminalSessions: storage)
    do {
      let result = try await next.callToolAsync(
        name: "shell.read", arguments: .object(["session_id": .string(id)]), context: .empty)
      #expect(
        result.objectValue?["structuredContent"]?.objectValue?["result"]?
          .objectValue?["stdout"]?.objectValue?["text"] == .string("manifest-result"))
      await next.shutdown()
    } catch {
      await next.shutdown()
      throw error
    }
  }

  @Test
  func gatewayShutdownJoinsItsExecutingShellWithoutStoppingAnotherGeneration() async throws {
    let root = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = GatewayTerminalSessions()
    let configuration = GatewayConfiguration(
      schemaVersion: 1, policy: PolicyConfig(shellEnabled: true),
      profiles: [
        ProfileGrantConfig(
          id: .localAdmin, capabilities: ["shell.spawn", "shell.read", "shell.cancel"],
          projects: ["default"], allowedCallers: [.localMCP], fullShellEnabled: true,
          mode: .localFullAccess, confirmationPolicy: .never)
      ], projectDirectory: root)
    func make() async throws -> GatewayRuntime {
      try await GatewayRuntime.make(
        configuration: configuration,
        platform: MacOSPlatform.services(launcher: testExecutionLauncher()),
        bundledPlugins: BundledPlugins(packages: [], issues: []),
        terminalSessions: storage)
    }
    func spawn(_ gateway: GatewayRuntime) async throws -> (id: String, pid: Int32) {
      let started = try await gateway.callToolAsync(
        name: "shell.spawn",
        arguments: .object([
          "mode": .string("argv"), "executable": .string("/bin/cat"),
        ]), context: .empty)
      let id = try #require(
        started.objectValue?["structuredContent"]?.objectValue?["result"]?
          .objectValue?["session_id"]?.stringValue)
      let read = try await gateway.callToolAsync(
        name: "shell.read", arguments: .object(["session_id": .string(id)]), context: .empty)
      let rawPID = try #require(
        read.objectValue?["structuredContent"]?.objectValue?["result"]?
          .objectValue?["process_id"]?.int64Value)
      let pid = try #require(Int32(exactly: rawPID))
      return (id, pid)
    }
    let old = try await make()
    let current = try await make()
    var children: [Int32] = []
    defer { for pid in children where kill(pid, 0) == 0 { _ = kill(-pid, SIGKILL) } }
    do {
      let first = try await spawn(old)
      children.append(first.pid)
      let second = try await spawn(current)
      children.append(second.pid)
      #expect(kill(first.pid, 0) == 0 && kill(second.pid, 0) == 0)
      await old.shutdown()
      #expect(kill(first.pid, 0) == -1 && errno == ESRCH)
      #expect(old.ownedWork.snapshot.isEmpty)
      #expect(kill(second.pid, 0) == 0)
      await current.shutdown()
      #expect(kill(second.pid, 0) == -1 && errno == ESRCH)
      #expect(current.ownedWork.snapshot.isEmpty)
      await old.shutdown()
      await current.shutdown()
    } catch {
      await old.shutdown()
      await current.shutdown()
      throw error
    }
  }

  @Test
  func registeredProcessesShareResultsButNotShutdownOwnership() async throws {
    let storage = GatewayTerminalSessions()
    let scope = GatewayTerminalSessions.Scope.isolated(UUID())
    let oldOwners = GatewayOwnedWork()
    let currentOwners = GatewayOwnedWork()
    let old = ShellSessionRuntime(
      launcher: testExecutionLauncher(), ownedWork: oldOwners, sessions: storage, scope: scope)
    let current = ShellSessionRuntime(
      launcher: testExecutionLauncher(), ownedWork: currentOwners, sessions: storage, scope: scope)
    let process = ManagedProcessRegistry(launcher: testExecutionLauncher(), shellManager: old)
    do {
      let registered = try process.spawn(
        executable: "/bin/cat", arguments: [], workingDirectory: directory,
        environment: [:], maxOutputBytes: 1_024)
      let other = try spawnCat(current)
      await withTaskGroup(of: Void.self) { group in
        for _ in 0..<4 { group.addTask { await old.shutdown() } }
      }
      #expect(oldOwners.snapshot.isEmpty)
      #expect(try !process.read(processID: registered).isRunning)
      let result = try read(current, registered)
      #expect(result.cancelled && !result.isRunning && result.finishedAt != nil)
      #expect(try read(current, other).isRunning)
      #expect(currentOwners.snapshot.map(\.resourceID) == [other])
      #expect(throws: ShellRuntimeError.stopped) { try spawnCat(old) }
      #expect(throws: ShellRuntimeError.stopped) {
        try process.spawn(
          executable: "/bin/cat", arguments: [], workingDirectory: directory,
          environment: [:], maxOutputBytes: 1_024)
      }
      await current.shutdown()
      #expect(currentOwners.snapshot.isEmpty)
    } catch {
      await old.shutdown()
      await current.shutdown()
      throw error
    }
  }

  @Test
  func shutdownJoinsAnAdmittedLaunchRacingWithItsStartupReply() async throws {
    let owners = GatewayOwnedWork()
    let shell = ShellSessionRuntime(launcher: testExecutionLauncher(), ownedWork: owners)
    let starting = Task {
      try await BlockingOperationExecutor(label: "test.shell-start-stop").perform {
        try spawnCat(shell)
      }
    }
    let deadline = ContinuousClock.now + .seconds(2)
    while owners.snapshot.isEmpty && ContinuousClock.now < deadline { await Task.yield() }
    #expect(!owners.snapshot.isEmpty)
    await shell.shutdown()
    let id = try await starting.value
    #expect(owners.snapshot.isEmpty)
    let result = try read(shell, id)
    #expect(result.cancelled && !result.isRunning && result.finishedAt != nil)
  }

  private func spawnCat(_ shell: ShellSessionRuntime, limit: Int = 4) throws -> String {
    try shell.spawn(
      request: ShellLaunchRequest(mode: .argv, executable: "/bin/cat"),
      defaultShell: "/bin/sh", defaultWorkingDirectory: directory, timeoutMilliseconds: nil,
      maxOutputBytes: 1_024, maxSessions: limit)
  }

  private func run(_ shell: ShellSessionRuntime, _ command: String) throws
    -> ShellSessionSnapshot
  {
    try shell.run(
      request: ShellLaunchRequest(mode: .argv, executable: "/bin/sh", argv: ["-c", command]),
      defaultShell: "/bin/sh", defaultWorkingDirectory: directory, timeoutMilliseconds: 2_000,
      maxOutputBytes: 1_024, maxSessions: 4)
  }

  private func read(_ shell: ShellSessionRuntime, _ id: String) throws -> ShellSessionSnapshot {
    try shell.read(
      sessionID: id, stdoutCursor: 0, stderrCursor: 0, maxReadBytes: 1_024, encoding: .utf8)
  }

  private func drained(_ owners: GatewayOwnedWork) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !owners.snapshot.isEmpty && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(owners.snapshot.isEmpty)
  }
}

private final class TerminalClock: @unchecked Sendable {
  private let lock = NSLock()
  private var offset: TimeInterval = 0
  var now: Date { lock.withLock { Date().addingTimeInterval(offset) } }
  func advance(seconds: TimeInterval) { lock.withLock { offset += seconds } }
}
