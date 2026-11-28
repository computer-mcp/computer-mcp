import ComputerMCPMacOS
import ComputerMCPPermissions
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
    try await withUnitLaunches { launch in
      let storage = GatewayTerminalSessions()
      let scope = GatewayTerminalSessions.Scope.isolated(UUID())
      let owners = GatewayOwnedWork()
      var old: ShellSessionRuntime? = ShellSessionRuntime(
        launcher: launch.launcher,
        ownedWork: owners, projectID: "test", sessions: storage, scope: scope)
      weak let previous = old
      let id = try spawnCat(try #require(old), launch: launch)
      let current = ShellSessionRuntime(
        launcher: launch.launcher, sessions: storage, scope: scope)
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
  }

  @Test
  func processClassificationAndOriginalOutputBudgetSurviveReplacement() async throws {
    try await withUnitLaunches { launch in
      let storage = GatewayTerminalSessions()
      let scope = GatewayTerminalSessions.Scope.isolated(UUID())
      let owners = GatewayOwnedWork()
      var old: ManagedProcessRegistry? = ManagedProcessRegistry(
        launcher: launch.launcher,
        shellManager: ShellSessionRuntime(
          launcher: launch.launcher, ownedWork: owners, sessions: storage, scope: scope))
      weak let previous = old
      let id = try spawnProcess(try #require(old), launch: launch, maxOutputBytes: 4)
      old = nil
      #expect(previous == nil)
      let shell = ShellSessionRuntime(
        launcher: launch.launcher, sessions: storage, scope: scope)
      let current = ManagedProcessRegistry(launcher: launch.launcher, shellManager: shell)
      _ = try await shell.writeAsync(sessionID: id, data: Data("12345678".utf8), close: true)
      _ = try shell.wait(
        sessionID: id, timeoutMilliseconds: 2_000, maxReadBytes: 16, encoding: .utf8)
      try await drained(owners)
      let result = try current.read(processID: id)
      #expect(result.stdout == "5678")
      #expect(result.stdoutTruncated)
      #expect(try current.list().map(\.processID) == [id])
      let ordinary = try run(shell, "printf ordinary", launch: launch)
      #expect(try current.list().map(\.processID) == [id])
      #expect(throws: ProcessRegistryError.unknownProcess(ordinary.sessionID)) {
        try current.read(processID: ordinary.sessionID)
      }
      #expect(throws: ProcessRegistryError.unknownProcess(ordinary.sessionID)) {
        try current.cancel(processID: ordinary.sessionID)
      }
    }
  }

  @Test
  func countBudgetEvictsCompletedResultsWithoutEvictingRunningSessions() async throws {
    try await withUnitLaunches { launch in
      let storage = GatewayTerminalSessions(
        retention: 86_400, maximumCompletedSessions: 2, maximumCompletedOutputBytes: 1_024)
      let shell = ShellSessionRuntime(launcher: launch.launcher, sessions: storage)
      let active = try spawnCat(shell, launch: launch)
      defer { _ = try? shell.cancel(sessionID: active) }
      let first = try run(shell, "printf first", launch: launch)
      let second = try run(shell, "printf second", launch: launch)
      let third = try run(shell, "printf third", launch: launch)
      #expect(throws: ShellRuntimeError.unknownSession(first.sessionID)) {
        try read(shell, first.sessionID)
      }
      #expect(
        try shell.list().map(\.sessionID).sorted()
          == [active, second.sessionID, third.sessionID].sorted())
      #expect(try read(shell, active).isRunning)
    }
  }

  @Test
  func outputBudgetIncludesBothStreamsAndRunStillReturnsItsOwnResult() async throws {
    try await withUnitLaunches { launch in
      let storage = GatewayTerminalSessions(
        retention: 86_400, maximumCompletedSessions: 64, maximumCompletedOutputBytes: 6)
      let shell = ShellSessionRuntime(launcher: launch.launcher, sessions: storage)
      let oversized = try run(shell, "printf 1234; printf 5678 >&2", launch: launch)
      #expect(oversized.stdout.text == "1234")
      #expect(oversized.stderr.text == "5678")
      #expect(throws: ShellRuntimeError.unknownSession(oversized.sessionID)) {
        try read(shell, oversized.sessionID)
      }
      let first = try run(shell, "printf abcd", launch: launch)
      let second = try run(shell, "printf efgh", launch: launch)
      let third = try run(shell, "printf ij", launch: launch)
      #expect(throws: ShellRuntimeError.unknownSession(first.sessionID)) {
        try read(shell, first.sessionID)
      }
      #expect(
        try shell.list().map(\.sessionID).sorted() == [second.sessionID, third.sessionID].sorted())
      #expect(try read(shell, second.sessionID).stdout.text == "efgh")
      #expect(try read(shell, third.sessionID).stdout.text == "ij")
    }
  }

  @Test
  func expirationRemovesProcessRegistrationButNeverReleasesExecutingWork() async throws {
    try await withUnitLaunches { launch in
      let clock = TerminalClock()
      let storage = GatewayTerminalSessions(
        retention: 60, maximumCompletedSessions: 64, maximumCompletedOutputBytes: 1_024,
        now: { clock.now })
      let scope = GatewayTerminalSessions.Scope.isolated(UUID())
      let owners = GatewayOwnedWork()
      let shell = ShellSessionRuntime(
        launcher: launch.launcher, ownedWork: owners, sessions: storage, scope: scope)
      let process = ManagedProcessRegistry(
        launcher: launch.launcher, shellManager: shell, maxSessions: 1)
      let id = try spawnProcess(process, launch: launch)
      defer { _ = try? process.cancel(processID: id) }
      let next = ShellSessionRuntime(
        launcher: launch.launcher, sessions: storage, scope: scope)
      clock.advance(seconds: 120)
      #expect(try process.read(processID: id).isRunning)
      #expect(owners.snapshot.map(\.resourceID) == [id])
      #expect(throws: ShellRuntimeError.sessionLimitReached(1)) {
        try spawnCat(next, limit: 1, launch: launch)
      }
      _ = try await next.writeAsync(sessionID: id, data: Data(), close: true)
      // Hold no lookup after completion: expiry may remove the completed entry immediately.
      try await drained(owners)
      #expect(try process.list().isEmpty)
      #expect(throws: ProcessRegistryError.unknownProcess(id)) { try process.read(processID: id) }
      #expect(throws: ShellRuntimeError.unknownSession(id)) { try read(next, id) }
    }
  }

  @Test
  func projectScopeRequiresSameCallerPrincipalProfileRegistrationAndRoot() async throws {
    try await withUnitLaunches { launch in
      let root = launch.directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let context = ExecutionContext(
        caller: .localMCP, profileID: .localAdmin, trustedPrincipalID: "one")
      let project = RegisteredProject(id: "folder", displayName: "Folder", rootPath: root.path)
      let scope = try GatewayTerminalSessions.Scope.project(
        context: context, project: project, root: ProjectRootIdentity(root))
      let storage = GatewayTerminalSessions()
      let shell = ShellSessionRuntime(
        launcher: launch.launcher, sessions: storage, scope: scope)
      let result = try run(shell, "printf private-result", launch: launch)
      let same = ShellSessionRuntime(
        launcher: launch.launcher,
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
          launcher: launch.launcher, sessions: storage, scope: foreign)
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
        launcher: launch.launcher,
        sessions: storage,
        scope: try .project(
          context: context, project: project, root: ProjectRootIdentity(root)))
      #expect(try replaced.list().isEmpty)
      #expect(throws: ShellRuntimeError.unknownSession(result.sessionID)) {
        try read(replaced, result.sessionID)
      }
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
    var configuration = GatewayConfiguration(
      schemaVersion: 1,
      policy: PolicyConfig(shellEnabled: true),
      profiles: [
        ProfileGrantConfig(
          id: .localAdmin, permissions: fixturePermissions([.project("root"): .granted(.write)]),
          fullAccess: true, allowedCallers: [.localMCP])
      ])
    var platform = MacOSPlatform.services(
      launcher: fixtureProtocolExecutionLauncher(
        root: root, scripts: [], arguments: [], allowCat: true))
    platform.permissionPolicyReader = TestManagedPolicyReader()
    try database.saveProfile(configuration.profiles[0].grant)
    let context = try fixtureConsentedContext(
      database: database, grant: configuration.profiles[0].grant,
      caller: .localMCP, principalID: "owner", projectID: "root", platform: platform)
    let old = try await GatewayRuntime.make(
      configuration: configuration, context: context, database: database,
      registeredProjects: [project],
      platform: platform,
      bundledPlugins: BundledPlugins(packages: [], issues: []),
      terminalSessions: storage)
    var replacement: GatewayRuntime?
    do {
      let spawned = try await old.callToolAsync(
        name: "shell.spawn",
        arguments: .object([
          "project_id": .string(project.id),
          "mode": .string("argv"), "executable": .string("/bin/cat"),
        ]), context: .empty)
      let id = try #require(
        spawned.objectValue?["structuredContent"]?.objectValue?["result"]?
          .objectValue?["session_id"]?.stringValue)
      configuration.policy.maxOutputBytes = 128
      let current = try await GatewayRuntime.make(
        configuration: configuration, context: context, database: database,
        registeredProjects: [project],
        platform: platform,
        bundledPlugins: BundledPlugins(packages: [], issues: []),
        terminalSessions: storage)
      replacement = current
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
      let executionID = try #require(
        result.objectValue?["structuredContent"]?.objectValue?["result"]?
          .objectValue?["execution_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
      var grant = try #require(try database.profiles().first { $0.id == .localAdmin })
      let revision = grant.authorizationRevision
      try grant.permissions.set(.denied, for: .project(project.id))
      try database.saveProfile(grant, expectedRevision: revision)
      #expect(try database.profiles().first { $0.id == .localAdmin }?.fullAccess == true)
      let session = try #require(context.controlSession as? GatewayControlSession)
      _ = try session.approveFullAccess(expectedRevision: session.revision)
      #expect(session.snapshot.fullAccessConsent != nil)
      do {
        _ = try await current.callToolAsync(
          name: "shell.read", arguments: .object(["session_id": .string(id)]), context: .empty)
        Issue.record("A denied Project exposed retained terminal output")
      } catch let error as PermissionModelError {
        #expect(error == .invalidAuthorization)
      }
      let denied = try await current.callToolForMCPAsync(
        name: "shell.read", arguments: .object(["session_id": .string(id)]), context: .empty)
      #expect(denied.objectValue?["isError"] == .bool(true))
      #expect(
        denied.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue?["code"]
          == .string("permission.invalid_authorization"))
      #expect(!String(describing: denied).contains("retained-at-gateway"))
      grant = try #require(try database.profiles().first { $0.id == .localAdmin })
      let deniedRevision = grant.authorizationRevision
      try grant.permissions.set(.granted(.write), for: .project(project.id))
      try database.saveProfile(grant, expectedRevision: deniedRevision)
      try database.configuredPermissionStore().readWithDatabase { _, ledger in
        let execution = try #require(ledger.executions[executionID])
        #expect(execution.revoked)
        var copy = ledger
        #expect(
          copy.executionAccess(
            executionID, principal: execution.owner, operation: .readResult, now: Date())
            == .denied(.authorizationRevoked))
      }
      await current.shutdown()
    } catch {
      await old.shutdown()
      await replacement?.shutdown()
      throw error
    }
  }

  @Test
  func manifestProjectHasStableResultScopeAcrossRuntimeConstruction() async throws {
    let root = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let program = """
      #!/usr/bin/python3
      import sys
      sys.stdout.write("manifest-result")
      """
    let executable = root.appendingPathComponent("result.py")
    try program.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    var platform = MacOSPlatform.services(
      launcher: fixtureProtocolExecutionLauncher(root: root, scripts: [program], arguments: [[]]))
    platform.permissionPolicyReader = TestManagedPolicyReader()
    let storage = GatewayTerminalSessions()
    let configuration = GatewayConfiguration(
      schemaVersion: 1, policy: PolicyConfig(shellEnabled: true),
      projects: [.init(id: "manifest", path: root.path)],
      profiles: [
        ProfileGrantConfig(
          id: .localAdmin,
          permissions: fixturePermissions([.project("manifest"): .granted(.write)]),
          fullAccess: true, allowedCallers: [.localMCP])
      ], projectDirectory: root)
    let database = try GatewayDatabase(inMemory: ())
    let profile = configuration.profiles[0].grant
    try database.saveProfile(profile)
    try database.registerManifestProjectsForStartup(configuration.manifestProjects)
    let context = try fixtureConsentedContext(
      database: database, grant: profile, caller: .localMCP, projectID: "manifest",
      platform: platform)
    let first = try await GatewayRuntime.make(
      configuration: configuration, context: context, database: database,
      platform: platform,
      bundledPlugins: BundledPlugins(packages: [], issues: []),
      terminalSessions: storage)
    let id: String
    do {
      let completed = try await first.callToolAsync(
        name: "shell.run",
        arguments: .object([
          "project_id": .string("manifest"), "mode": .string("argv"),
          "executable": .string(executable.path), "argv": .array([]),
        ]), context: .empty)
      id = try #require(
        completed.objectValue?["structuredContent"]?.objectValue?["result"]?
          .objectValue?["session_id"]?.stringValue)
      await first.shutdown()
    } catch {
      await first.shutdown()
      throw error
    }
    let next = try await GatewayRuntime.make(
      configuration: configuration, context: context, database: database,
      platform: platform,
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
    var platform = MacOSPlatform.services(
      launcher: fixtureProtocolExecutionLauncher(
        root: root, scripts: [], arguments: [], allowCat: true))
    platform.permissionPolicyReader = TestManagedPolicyReader()
    let storage = GatewayTerminalSessions()
    let configuration = GatewayConfiguration(
      schemaVersion: 1, policy: PolicyConfig(shellEnabled: true),
      projects: [.init(id: "root", path: root.path)],
      profiles: [
        ProfileGrantConfig(
          id: .localAdmin, permissions: fixturePermissions([.project("root"): .granted(.write)]),
          fullAccess: true, allowedCallers: [.localMCP])
      ], projectDirectory: root)
    let database = try GatewayDatabase(inMemory: ())
    let profile = configuration.profiles[0].grant
    try database.saveProfile(profile)
    try database.registerManifestProjectsForStartup(configuration.manifestProjects)
    let context = try fixtureConsentedContext(
      database: database, grant: profile, caller: .localMCP, projectID: "root", platform: platform)
    func make() async throws -> GatewayRuntime {
      try await GatewayRuntime.make(
        configuration: configuration, context: context, database: database,
        platform: platform,
        bundledPlugins: BundledPlugins(packages: [], issues: []),
        terminalSessions: storage)
    }
    func spawn(_ gateway: GatewayRuntime) async throws -> (id: String, pid: Int32) {
      let started = try await gateway.callToolAsync(
        name: "shell.spawn",
        arguments: .object([
          "project_id": .string("root"),
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
    do {
      let first = try await spawn(old)
      let second = try await spawn(current)
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
    try await withUnitLaunches { launch in
      let storage = GatewayTerminalSessions()
      let scope = GatewayTerminalSessions.Scope.isolated(UUID())
      let oldOwners = GatewayOwnedWork()
      let currentOwners = GatewayOwnedWork()
      let old = ShellSessionRuntime(
        launcher: launch.launcher, ownedWork: oldOwners, sessions: storage, scope: scope)
      let current = ShellSessionRuntime(
        launcher: launch.launcher, ownedWork: currentOwners, sessions: storage, scope: scope)
      let process = ManagedProcessRegistry(launcher: launch.launcher, shellManager: old)
      do {
        let registered = try spawnProcess(process, launch: launch)
        let other = try spawnCat(current, launch: launch)
        await withTaskGroup(of: Void.self) { group in
          for _ in 0..<4 { group.addTask { await old.shutdown() } }
        }
        #expect(oldOwners.snapshot.isEmpty)
        #expect(try !process.read(processID: registered).isRunning)
        let result = try read(current, registered)
        #expect(result.cancelled && !result.isRunning && result.finishedAt != nil)
        #expect(try read(current, other).isRunning)
        #expect(currentOwners.snapshot.map(\.resourceID) == [other])
        #expect(throws: ShellRuntimeError.stopped) { try spawnCat(old, launch: launch) }
        #expect(throws: ShellRuntimeError.stopped) {
          try spawnProcess(process, launch: launch)
        }
        await current.shutdown()
        #expect(currentOwners.snapshot.isEmpty)
      } catch {
        await old.shutdown()
        await current.shutdown()
        throw error
      }
    }
  }

  @Test
  func shutdownJoinsAnAdmittedLaunchRacingWithItsStartupReply() async throws {
    try await withUnitLaunches { launch in
      let owners = GatewayOwnedWork()
      let shell = ShellSessionRuntime(launcher: launch.launcher, ownedWork: owners)
      let starting = Task {
        try await BlockingOperationExecutor(label: "test.shell-start-stop").perform {
          try spawnCat(shell, launch: launch)
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
  }

  private func spawnCat(
    _ shell: ShellSessionRuntime, limit: Int = 4, launch: TerminalUnitLaunchFixture
  ) throws -> String {
    try launch.perform {
      try shell.spawn(
        request: ShellLaunchRequest(
          mode: .argv, executable: "/bin/cat", inheritsEnvironment: false),
        defaultShell: "/bin/sh", defaultWorkingDirectory: launch.directory,
        timeoutMilliseconds: nil, maxOutputBytes: 1_024, maxSessions: limit)
    }
  }

  private func spawnProcess(
    _ process: ManagedProcessRegistry, launch: TerminalUnitLaunchFixture,
    maxOutputBytes: Int = 1_024
  ) throws -> String {
    try launch.perform {
      try process.spawn(
        executable: "/bin/cat", arguments: [], workingDirectory: launch.directory,
        environment: [:], maxOutputBytes: maxOutputBytes)
    }
  }

  private func run(
    _ shell: ShellSessionRuntime, _ command: String, launch: TerminalUnitLaunchFixture
  ) throws -> ShellSessionSnapshot {
    try launch.perform {
      try shell.run(
        request: ShellLaunchRequest(
          mode: .argv, executable: "/bin/sh", argv: ["-c", command], inheritsEnvironment: false),
        defaultShell: "/bin/sh", defaultWorkingDirectory: launch.directory,
        timeoutMilliseconds: 2_000, maxOutputBytes: 1_024, maxSessions: 4)
    }
  }

  private func withUnitLaunches(
    _ operation: (TerminalUnitLaunchFixture) async throws -> Void
  ) async throws {
    let launch = try TerminalUnitLaunchFixture()
    do {
      try await operation(launch)
    } catch {
      try await launch.finish()
      throw error
    }
    try await launch.finish()
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

/// Unit launches own their private environment until every observed native child is joined.
private struct TerminalUnitLaunchFixture: Sendable {
  let directory: URL
  let launcher: ExecutionLauncher
  private let observations: ExecutionObservations
  private let administration: ExecutionAdministration

  init() throws {
    directory = try ProjectPathResolver.canonicalProject(FileManager.default.temporaryDirectory)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    observations = ExecutionObservations()
    launcher = testExecutionLauncher(observations: observations)
    administration = try ExecutionAdministration(
      mode: .fullAccess,
      environment: .init(fullAccessVariables: [
        "PATH": "/usr/bin:/bin", "HOME": directory.path, "TMPDIR": directory.path + "/",
        "TMP": directory.path, "TEMP": directory.path,
      ]))
  }

  func perform<Result>(_ operation: () throws -> Result) rethrows -> Result {
    try ExecutionAdministration.$current.withValue(administration, operation: operation)
  }

  func finish() async throws {
    var firstError: (any Error)?
    for ownership in observations.ownerships {
      do {
        _ = try await ownership.cancel()
        let members = try await ownership.members()
        try #require(members.isEmpty)
      } catch {
        firstError = firstError ?? error
      }
    }
    if let firstError { throw firstError }
    try FileManager.default.removeItem(at: directory)
  }
}

private final class TerminalClock: @unchecked Sendable {
  private let lock = NSLock()
  private var offset: TimeInterval = 0
  var now: Date { lock.withLock { Date().addingTimeInterval(offset) } }
  func advance(seconds: TimeInterval) { lock.withLock { offset += seconds } }
}
