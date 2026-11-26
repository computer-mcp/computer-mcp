import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPProcess
import ComputerMCPSandbox
import ComputerMCPTestSupport
import ComputerMCPWorktrees
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPlatform

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.nativeIntegration, .serialized)
struct GatewayFixedHostOperationTests {
  @Test func fileMutationInNonRepositoryDoesNotInspectOutsideTheProject() async throws {
    let fixture = try FixedHostFixture()
    try await fixture.run { fixture in
      _ = try fixture.session.approveFullAccess(expectedRevision: fixture.session.revision)
      let result = try await fixture.call(
        "file.write", ["path": .string("value.txt"), "content": .string("changed")])
      #expect(result.objectValue?["isError"] != .bool(true), "\(result)")
      #expect(
        try String(contentsOf: fixture.project.appendingPathComponent("value.txt"), encoding: .utf8)
          == "changed")
    }
  }

  @Test func admittedFileAndGitWritesUseOnlyThePinnedHelper() async throws {
    let fixture = try FixedHostFixture()
    try await fixture.run { fixture in
      try await fixture.initializeRepository()
      let write: [String: JSONValue] = [
        "path": .string("value.txt"), "content": .string("changed"),
      ]
      let noConsent = try await fixture.call("file.write", write)
      #expect(noConsent.objectValue?["isError"] == .bool(true))
      _ = try fixture.session.approveFullAccess(expectedRevision: fixture.session.revision)
      for (name, arguments) in [
        ("file.write", write),
        ("git.add", ["paths": .array([.string("value.txt")])]),
        (
          "git.commit", ["paths": .array([.string("value.txt")]), "message": .string("fixed host")]
        ),
      ] {
        let result = try await fixture.call(name, arguments)
        #expect(result.objectValue?["isError"] != .bool(true), "\(name): \(result)")
      }
      #expect(try await fixture.ownerGit(["log", "-1", "--format=%s"]) == "fixed host\n")
      #expect(
        !FileManager.default.fileExists(
          atPath: fixture.root.appendingPathComponent("configured-started").path))
      let journal = fixture.observations.ownerships
      #expect(!journal.isEmpty)
      #expect(try journal.allSatisfy { try $0.recoveryState().sandboxed })
      let audits = try fixture.database.auditEvents()
      #expect(audits.contains { $0.capabilityID == "git.commit" && $0.decision == .allowed })
      try await fixture.requireNoScratch()
      let arbitrary = try await fixture.call(
        "shell.run", ["command": .string("touch arbitrary-started"), "shell": .string("/bin/sh")])
      #expect(arbitrary.objectValue?["isError"] != .bool(true), "\(arbitrary)")
      #expect(
        arbitrary.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue?[
          "ownership"]?.objectValue?[
            "scope"] == .string("process_group_best_effort"))
      #expect(
        FileManager.default.fileExists(
          atPath: fixture.project.appendingPathComponent("arbitrary-started").path))
    }
  }

  @Test func consentDoesNotOverrideRevokedProjectOrCancelledRepositoryWait() async throws {
    let fixture = try FixedHostFixture()
    try await fixture.run { fixture in
      try await fixture.initializeRepository()
      _ = try fixture.session.approveFullAccess(expectedRevision: fixture.session.revision)
      let lock = try RepositoryLock(
        commonDirectory: fixture.project.appendingPathComponent(".git"),
        owner: .init(bootSessionID: fixture.platform.launcher.bootSessionID), timeout: .seconds(1))
      let call = Task {
        try await fixture.call("git.add", ["paths": .array([.string("value.txt")])])
      }
      // Wait for the fixed helper's read-only inspection before revoking its live authority.
      for _ in 0..<200 {
        if !fixture.observations.members.isEmpty { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      try fixture.session.limitAccess(
        to: .init(permissionCeilings: fixturePermissions([.project("fixture"): .granted(.read)])),
        expectedRevision: fixture.session.revision)
      #expect(fixture.session.revision > 0)
      let result = try await call.value
      lock.release()
      #expect(result.objectValue?["isError"] == .bool(true), "\(result)")
      let denied = try await fixture.call(
        "file.write", ["path": .string("value.txt"), "content": .string("denied")])
      #expect(denied.objectValue?["isError"] == .bool(true))
      #expect(
        try String(contentsOf: fixture.project.appendingPathComponent("value.txt"), encoding: .utf8)
          == "original")
      try await fixture.requireNoScratch()
    }
  }
}

struct FixedHostFixture {
  let root: URL
  let project: URL
  let database: GatewayDatabase
  let platform: PlatformServices
  let session: GatewayControlSession
  let runtime: GatewayRuntime
  let configuration: GatewayConfiguration
  let observations = ExecutionObservations()

  init(
    fullAccess: Bool = true, lifecycle: Bool = false, callback: Bool = false,
    nestedAccess: PermissionValue? = nil, caller: GatewayCallerKind = .localMCP,
    gitExecutable: String? = nil, managed: Bool = false,
    allowedCallers: Set<GatewayCallerKind>? = nil, isolatedRoot: URL? = nil
  ) throws {
    let location = isolatedRoot ?? URL(fileURLWithPath: "/private/tmp/cm-fixed-\(UUID())")
    if isolatedRoot == nil {
      try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
    }
    root = try ProjectPathResolver.canonicalProject(location)
    project = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
    try Data("original".utf8).write(to: project.appendingPathComponent("value.txt"))
    let directories = managed ? GatewayManagedHostFixture.directories(root: root) : nil
    try directories?.prepare()
    let databasePath = directories?.database ?? root.appendingPathComponent("state.sqlite")
    database = try GatewayDatabase(
      path: databasePath.path, applicationSupportRoot: directories?.applicationSupport)
    _ = database.permissionStore(
      counter: TestAuthorizationEpochCounter.shared(forDatabasePath: databasePath.path))
    var permissions = fixturePermissions([.project("fixture"): .granted(.write)])
    if let nestedAccess { try permissions.set(.granted(nestedAccess), for: .project("nested")) }
    if callback { try permissions.set(.granted(.all), for: .mcpServer("lifecycle-callback")) }
    let grant = ProfileGrant(
      id: .chatGPTOperate,
      permissions: permissions,
      fullAccess: fullAccess, allowedCallers: allowedCallers ?? [caller])
    try database.saveProfile(grant)
    try database.bootstrapPermissionProfiles([grant])
    let registered = ComputerMCPCore.RegisteredProject(
      id: "fixture", displayName: "Fixture", rootPath: project.path)
    try database.saveProject(registered)
    var registeredProjects = [registered]
    if nestedAccess != nil {
      let nested = project.appendingPathComponent("nested")
      try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
      try Data("nested".utf8).write(to: nested.appendingPathComponent("value.txt"))
      let child = ComputerMCPCore.RegisteredProject(
        id: "nested", displayName: "Nested", rootPath: nested.path)
      try database.saveProject(child)
      registeredProjects.append(child)
    }
    var services = MacOSPlatform.services(
      launcher: testExecutionLauncher(observations: observations))
    services.permissionPolicyReader = TestManagedPolicyReader()
    if let gitExecutable { services = fixturePlatformWithGit(services, executable: gitExecutable) }
    if let directories { services.hostDataPaths.formUnion(directories.hostDataPaths) }
    platform = services
    session = GatewayControlSession(
      principalID: "fixed-client", profileID: grant.id, caller: caller, database: database,
      profile: .init(grant: grant, persisted: true),
      permissionService: try database.permissionRuntime(platform: services).service)
    var context = ExecutionContext(
      caller: caller, profileID: grant.id, projectID: registered.id,
      trustedPrincipalID: session.principalID)
    context.controlSession = session
    let configured = root.appendingPathComponent("configured-git")
    try "#!/bin/sh\ntouch '\(root.path)/configured-started'\nexit 99\n".write(
      to: configured, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: configured.path)
    configuration = GatewayConfiguration(
      runtime: .init(caller: caller, profileID: grant.id), policy: .init(shellEnabled: true),
      profiles: [.init(grant: grant)],
      cli: .init(commands: [
        .init(
          id: "git", executable: configured.path, cwd: root.path, env: ["GIT_DIR": root.path]),
        .init(id: "fixture", executable: "/bin/sh", allowAnyArgs: true),
      ]),
      mcp: .init(
        servers: callback
          ? [
            .init(
              id: "lifecycle-callback", transport: .stdio, command: "/bin/cat",
              hostServices: true)
          ] : []),
      builtin: .init(
        enabled: [
          "file.write", "git.add", "git.commit",
        ]
          + (lifecycle
            ? [
              "git.worktree_add", "git.worktree_list", "git.worktree_remove", "git.merge",
              "git.branch_delete", "git.status", "git.log", "git.show", "git.staged_file",
            ] : [])),
      projectDirectory: project)
    runtime = try GatewayRuntime(
      configuration: configuration, context: context, database: database,
      registeredProjects: registeredProjects, platform: services,
      mcpClient: CatalogDiscoveryStub(),
      bundledPlugins: .init(packages: [], issues: []))
  }

  func call(_ name: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
    try await runtime.callToolForMCPAsync(
      name: name, arguments: .object(arguments), context: .empty)
  }

  func ownerGit(_ arguments: [String]) async throws -> String {
    try await BlockingOperationExecutor(label: "fixed-host-fixture").perform {
      let administration = ExecutionAdministration(
        mode: .fullAccess,
        environment: try ExecutionEnvironment(fullAccessVariables: ["PATH": "/usr/bin:/bin"]))
      return try ExecutionAdministration.$current.withValue(administration) {
        let result = try ProcessCommandRunner(launcher: testExecutionLauncher()).runIsolated(
          executable: platform.gitExecutable, arguments: arguments, workingDirectory: project,
          environment: [
            "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
          ],
          timeoutMilliseconds: 10_000, maxOutputBytes: 65_536)
        try #require(result.exitCode == 0 && !result.timedOut, "\(result.stderr)")
        return result.stdout
      }
    }
  }

  func initializeRepository() async throws {
    for arguments in [
      ["init", "--quiet"], ["config", "user.name", "Fixture"],
      ["config", "user.email", "fixture@example.invalid"], ["add", "value.txt"],
      ["commit", "--quiet", "-m", "initial"],
    ] {
      _ = try await ownerGit(arguments)
    }
  }

  func requireNoScratch() async throws {
    for _ in 0..<200 {
      try await runtime.permissionRuntime.coordinator.reconcile()
      let entries = try FileManager.default.contentsOfDirectory(
        at: database.permissionExecutionRoot, includingPropertiesForKeys: nil)
      if entries.filter({ UUID(uuidString: $0.lastPathComponent) != nil }).isEmpty { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Completed fixed operations retained scratch")
  }

  func run(_ body: (Self) async throws -> Void) async throws {
    do { try await body(self) } catch {
      session.end()
      await runtime.shutdown()
      try? FileManager.default.removeItem(at: root)
      throw error
    }
    session.end()
    await runtime.shutdown()
    try FileManager.default.removeItem(at: root)
  }
}
