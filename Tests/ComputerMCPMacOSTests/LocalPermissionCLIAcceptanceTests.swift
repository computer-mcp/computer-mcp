import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPSandbox
import ComputerMCPTestSupport
import ComputerMCPTunnels
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPControlPlane
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPlatform
@testable import ComputerMCPPlatformDarwin
@testable import ComputerMCPProcess

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(
  .nativeIntegration,
  .enabled(
    if: ProcessInfo.processInfo.environment["COMPUTER_MCP_TEST_GATEWAY_EXECUTABLE"] != nil,
    "Set COMPUTER_MCP_TEST_GATEWAY_EXECUTABLE to the exact local CLI artifact for isolated acceptance."
  ),
  .timeLimit(.minutes(2)))
struct LocalPermissionCLIAcceptanceTests {
  @Test(arguments: [ManagedPolicySourceID.machineFile, .managedPreferences])
  func managedTighteningCapsPendingSocketAnswers(source: ManagedPolicySourceID) async throws {
    let fixture = try PermissionCLIFixture(
      executable: #require(
        ProcessInfo.processInfo.environment["COMPUTER_MCP_TEST_GATEWAY_EXECUTABLE"]))
    var client: GatewayClientSession?
    do {
      try Data("private contents".utf8).write(
        to: fixture.project.appendingPathComponent("value.txt"))
      try await fixture.controlSocket.start()
      try await fixture.gatewayService.start(profile: .chatGPTOperate)
      let connected = try await GatewayClientSession.connectSocket(socketURL: fixture.gatewaySocket)
      client = connected
      let ids = try fixture.requestIDs(await fixture.read("value.txt", session: connected))
      fixture.reader.set(source, .available(Data("[projects]\nfixture = 'deny'\n".utf8)))
      for answer in ["only_this_time", "always"] {
        let view = try await fixture.json(["permissions", "requests"])
        let revision = try #require(view.objectValue?["revision"]?.intValue)
        let result = try await fixture.run([
          "permissions", "answer", ids[0], "--answer", answer,
          "--expected-revision", String(revision),
        ])
        #expect(result.exitCode != 0)
      }
      let before = try await fixture.requestSet()
      let denied = try await fixture.read("value.txt", session: connected)
      #expect(fixture.error(denied)?["code"] == .string("permission.managed_limit"))
      #expect(fixture.error(denied)?["request_ids"] == nil)
      #expect(fixture.content(denied) == nil)
      #expect(try await fixture.requestSet() == before)
      #expect(try fixture.currentGrant().permissions.state(for: .project("fixture")) == .notGranted)
      await connected.disconnect()
      await fixture.stopAndRemove()
    } catch {
      await client?.disconnect()
      await fixture.stopAndRemove()
      throw error
    }
  }

  @Test
  func repairCommandPublishesTheSelectedFolderOnTheSameConnection() async throws {
    let fixture = try PermissionCLIFixture(
      executable: #require(
        ProcessInfo.processInfo.environment["COMPUTER_MCP_TEST_GATEWAY_EXECUTABLE"]),
      projectAccess: .granted(.read))
    var client: GatewayClientSession?
    do {
      let destination = fixture.root.appendingPathComponent("repaired")
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      try Data("new folder".utf8).write(to: destination.appendingPathComponent("value.txt"))
      try await fixture.controlSocket.start()
      try await fixture.gatewayService.start(profile: .chatGPTOperate)
      let connected = try await GatewayClientSession.connectSocket(socketURL: fixture.gatewaySocket)
      client = connected
      let original = try #require(try fixture.database.project(id: "fixture"))
      let before = await fixture.gatewayService.snapshot()
      let repaired = try await fixture.json(["project", "repair", original.id, destination.path])
      #expect(repaired.objectValue?["id"] == .string(original.id))
      let stored = try #require(try fixture.database.project(id: original.id))
      #expect(stored.createdAt == original.createdAt && stored.displayName == original.displayName)
      #expect(
        stored.rootPath == destination.resolvingSymlinksInPath().path && stored.bookmarkData != nil)
      let read = try await connected.call(
        toolName: "file.read", arguments: .object(["path": .string("value.txt")]))
      #expect(
        read.result.objectValue?["structuredContent"]?.objectValue?["result"]?
          .objectValue?["content"] == .string("new folder"))
      let failed = try await fixture.run(["project", "repair", original.id, "/missing-\(UUID())"])
      #expect(failed.exitCode != 0)
      #expect(try fixture.database.project(id: original.id) == stored)
      #expect(await fixture.gatewayService.snapshot().startedAt == before.startedAt)
      #expect(await fixture.gatewayService.snapshot().connectionCount == 1)
      await connected.disconnect()
      client = nil
      await fixture.stopAndRemove()
    } catch {
      await client?.disconnect()
      await fixture.stopAndRemove()
      throw error
    }
  }

  @Test
  func managementCommandsTargetOnlyTheSelectedApp() async throws {
    let executable = try #require(
      ProcessInfo.processInfo.environment["COMPUTER_MCP_TEST_GATEWAY_EXECUTABLE"])
    let first = try PermissionCLIFixture(executable: executable)
    let second = try PermissionCLIFixture(executable: executable)
    do {
      try await first.controlSocket.start()
      try await second.controlSocket.start()
      for fixture in [first, second] {
        let path = try await fixture.run(["config", "path"])
        #expect(path.exitCode == 0)
        #expect(path.stdout.contains(fixture.root.path))
        for arguments in [
          ["app", "status"], ["project", "list"], ["config", "validate"],
          ["config", "history"], ["providers", "list"], ["audit", "list"],
          ["tunnel", "openai", "list"], ["tunnel", "cloudflare", "list"],
        ] {
          _ = try await fixture.json(arguments)
        }
      }
      _ = try await first.json(["project", "remove", "fixture"])
      #expect(try first.database.projects().isEmpty)
      #expect(try second.database.projects().count == 1)
      _ = try await second.json(["app", "start"])
      #expect(await second.gatewayService.snapshot().state == .running)
      #expect(await first.gatewayService.snapshot().state != .running)
      _ = try await second.json(["tools", "list"])
      _ = try await second.json(["app", "stop"])
      #expect(await second.gatewayService.snapshot().state != .running)
      for arguments in [
        ["tools", "list"], ["tools", "inspect", "file.read"],
        ["tools", "call", "file.read"], ["config", "validate"],
      ] {
        let result = try await first.run(arguments + ["--config", "absent.toml"])
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("--control-socket cannot be combined with --config"))
      }
      await first.controlSocket.stop()
      let missingOwner = try await first.run(["app", "status"])
      #expect(missingOwner.exitCode != 0)
      #expect(try await second.run(["app", "status"]).exitCode == 0)
      await first.stopAndRemove()
      await second.stopAndRemove()
    } catch {
      await first.stopAndRemove()
      await second.stopAndRemove()
      throw error
    }
  }

  @Test
  func realCLIAnswersExactPermissionRequestsWithoutRestartingTheIsolatedGateway() async throws {
    let fixture = try PermissionCLIFixture(
      executable: #require(
        ProcessInfo.processInfo.environment["COMPUTER_MCP_TEST_GATEWAY_EXECUTABLE"]))
    var session: GatewayClientSession?
    do {
      try Data("reviewed contents".utf8).write(
        to: fixture.project.appendingPathComponent("reviewed.txt"))
      try Data("other contents".utf8).write(to: fixture.project.appendingPathComponent("other.txt"))
      try await fixture.controlSocket.start()
      try await fixture.gatewayService.start(profile: .chatGPTOperate)
      let gatewayBefore = await fixture.gatewayService.snapshot()
      let controlBefore = await fixture.controlSocket.snapshot()
      let connected = try await GatewayClientSession.connectSocket(socketURL: fixture.gatewaySocket)
      session = connected

      let doctor = try await fixture.doctor()
      #expect(doctor.objectValue?["schema_version"] == .number(1))
      #expect(doctor.objectValue?["journey"] == .string("local"))
      let checks = try #require(doctor.objectValue?["checks"]?.arrayValue)
      for id in ["app.control_socket", "gateway.running", "project.registered"] {
        #expect(
          checks.first { $0.objectValue?["id"] == .string(id) }?.objectValue?["status"]
            == .string("pass"), "Doctor check: \(id)")
      }

      let initial = try await fixture.json(["profile", "show", "chatgpt-operate"])
      #expect(initial.objectValue?["full_access"] == .bool(true))
      let initialRevision = try #require(initial.objectValue?["authorization_revision"]?.intValue)
      let target = fixture.readTarget("reviewed.txt")
      let pending = try await connected.call(toolName: "file.read", arguments: target)
      let requests = try fixture.requestIDs(pending.result)
      let listed = try await fixture.json(["permissions", "requests"])
      let rows = try #require(listed.objectValue?["requests"]?.arrayValue)
      for id in requests {
        #expect(
          rows.contains {
            $0.objectValue?["request"]?.objectValue?["identity"]?.objectValue?["id"] == .string(id)
          })
      }
      try await fixture.answer(requests, with: "only_this_time")
      let substituted = try await fixture.read("other.txt", retryIDs: requests, session: connected)
      #expect(substituted.objectValue?["isError"] == .bool(true))
      let retried = try await fixture.read("reviewed.txt", retryIDs: requests, session: connected)
      #expect(fixture.content(retried) == .string("reviewed contents"), "\(retried)")
      let replayed = try await fixture.read("reviewed.txt", retryIDs: requests, session: connected)
      #expect(replayed.objectValue?["isError"] == .bool(true))
      #expect(try fixture.currentGrant().permissions.state(for: .project("fixture")) == .notGranted)

      let standingRequest = try await fixture.read("other.txt", session: connected)
      try await fixture.answer(fixture.requestIDs(standingRequest), with: "always")
      #expect(
        fixture.content(try await fixture.read("other.txt", session: connected))
          == .string("other contents"))
      #expect(
        try fixture.currentGrant().permissions.state(for: .project("fixture")) == .granted(.read))
      #expect(try fixture.currentGrant().authorizationRevision > Int64(initialRevision))

      let reviewedProfile = try await fixture.json(["profile", "show", "chatgpt-operate"])
      let reviewedRevision = try #require(
        reviewedProfile.objectValue?["permission_revision"]?.intValue)
      var deniedGrant = try fixture.currentGrant()
      try deniedGrant.permissions.set(.denied, for: .project("fixture"))
      _ = try await fixture.update(deniedGrant, permissionRevision: reviewedRevision)
      let deniedRevision = try fixture.currentGrant().authorizationRevision
      let stale = try await fixture.update(
        deniedGrant, permissionRevision: reviewedRevision, requireSuccess: false)
      #expect(stale.exitCode != 0)
      #expect(try fixture.currentGrant().authorizationRevision == deniedRevision)
      let beforeDenied = try await fixture.requestSet()
      let denied = try await fixture.read("reviewed.txt", session: connected)
      #expect(denied.objectValue?["isError"] == .bool(true))
      #expect(fixture.error(denied)?["code"] == .string("permission.denied"))
      #expect(fixture.error(denied)?["request_ids"] == nil)
      #expect(try await fixture.requestSet() == beforeDenied)

      var requestable = try fixture.currentGrant()
      requestable.permissions.removeEntry(for: .project("fixture"))
      _ = try await fixture.update(requestable)
      let declinedRequest = try await fixture.read("reviewed.txt", session: connected)
      let declinedIDs = try fixture.requestIDs(declinedRequest)
      try await fixture.answer(declinedIDs, with: "deny")
      #expect(
        try await fixture.read("reviewed.txt", retryIDs: declinedIDs, session: connected)
          .objectValue?["isError"] == .bool(true))
      #expect(try fixture.currentGrant().permissions.state(for: .project("fixture")) == .notGranted)

      var writable = try fixture.currentGrant()
      try writable.permissions.set(.granted(.write), for: .project("fixture"))
      _ = try await fixture.update(writable)
      let sandboxWrite = try await connected.call(
        toolName: "file.write", arguments: fixture.writeTarget("absent.txt"))
      #expect(sandboxWrite.result.objectValue?["isError"] == .bool(true))
      #expect(fixture.error(sandboxWrite.result)?["code"] != .string("permission.required"))
      #expect(fixture.error(sandboxWrite.result)?["request_ids"] == nil)
      #expect(fixture.error(sandboxWrite.result)?["code"] == .string("permission.denied"))
      #expect(fixture.error(sandboxWrite.result)?["reason"] == .string("mainProjectWrite"))
      #expect(!fixture.exists("absent.txt"))

      let clients = try await fixture.json(["clients", "list"])
      let selected = try #require(clients.objectValue?["sessions"]?.arrayValue?.first?.objectValue)
      let clientID = try #require(selected["id"]?.stringValue)
      let clientRevision = try #require(selected["revision"]?.intValue)
      let approved = try await fixture.json([
        "clients", "allow", clientID, "--full-access", "--expected-revision",
        String(clientRevision),
        "--expected-trust-revision", "0",
      ])
      #expect(
        approved.objectValue?["full_access_consent"]?.objectValue?["lifetime"]
          == .string("this-session"))
      #expect(try await !fixture.control.activeConfiguration().policy.shellEnabled)
      #expect(try await !connected.listToolNames().contains("shell.run"))
      #expect(try fixture.database.clientTrusts().isEmpty)

      let current = try await connected.call(toolName: "profile.show")
      let currentRevision = try #require(fixture.result(current.result)?["revision"]?.int64Value)
      let limits = ManagedPolicy(
        permissionCeilings: fixturePermissions([.project("fixture"): .granted(.read)]),
        allowsFullAccess: true)
      let narrowed = try await connected.call(
        toolName: "profile.limit",
        arguments: .object([
          "limits": try ControlToolResponse.encodedPayload(limits),
          "expected_revision": .integer(currentRevision),
        ]))
      #expect(narrowed.result.objectValue?["isError"] != .bool(true), "\(narrowed.result)")
      let limited = try #require(fixture.result(narrowed.result))
      #expect(limited["full_access_consent"] != nil)
      #expect(limited["access_limit"]?.objectValue?["allows_full_access"] == .bool(true))
      let limitedRevision = try #require(limited["revision"]?.int64Value)
      #expect(limitedRevision > currentRevision)
      let limitedWrite = try await connected.call(
        toolName: "file.write", arguments: fixture.writeTarget("limited.txt"))
      #expect(fixture.error(limitedWrite.result)?["code"] == .string("permission.managed_limit"))
      #expect(fixture.error(limitedWrite.result)?["request_ids"] == nil)
      #expect(!fixture.exists("limited.txt"))

      let sandboxLimits = ManagedPolicy(
        permissionCeilings: limits.permissionCeilings, allowsFullAccess: false)
      let sandboxed = try await connected.call(
        toolName: "profile.limit",
        arguments: .object([
          "limits": try ControlToolResponse.encodedPayload(sandboxLimits),
          "expected_revision": .integer(limitedRevision),
        ]))
      #expect(sandboxed.result.objectValue?["isError"] != .bool(true), "\(sandboxed.result)")
      let sandbox = try #require(fixture.result(sandboxed.result))
      #expect(sandbox["full_access_consent"] == nil)
      #expect(sandbox["access_limit"]?.objectValue?["allows_full_access"] == .bool(false))
      let sandboxRevision = try #require(sandbox["revision"]?.int64Value)
      #expect(sandboxRevision > limitedRevision)
      let widened = try await connected.call(
        toolName: "profile.limit",
        arguments: .object([
          "limits": try ControlToolResponse.encodedPayload(ManagedPolicy()),
          "expected_revision": .integer(sandboxRevision),
        ]))
      #expect(widened.result.objectValue?["isError"] == .bool(true))
      #expect(
        fixture.content(try await fixture.read("reviewed.txt", session: connected))
          == .string("reviewed contents"))
      #expect(try fixture.currentGrant().fullAccess)
      #expect(
        try fixture.currentGrant().permissions.state(for: .project("fixture")) == .granted(.write))

      let gatewayAfter = await fixture.gatewayService.snapshot()
      let controlAfter = await fixture.controlSocket.snapshot()
      #expect(gatewayAfter.state == .running && gatewayAfter.startedAt == gatewayBefore.startedAt)
      #expect(gatewayAfter.processIdentifier == gatewayBefore.processIdentifier)
      #expect(controlAfter.state == .running && controlAfter.startedAt == controlBefore.startedAt)
      await connected.disconnect()
      session = nil
      await fixture.gatewayService.stop()
      let stoppedDoctor = try await fixture.doctor()
      #expect(
        stoppedDoctor.objectValue?["checks"]?.arrayValue?.first {
          $0.objectValue?["id"] == .string("gateway.running")
        }?.objectValue?["status"] == .string("fail"))
      await fixture.controlSocket.stop()
      let unavailableDoctor = try await fixture.doctor()
      #expect(unavailableDoctor.objectValue?["status"] == .string("blocked"))
      #expect(
        unavailableDoctor.objectValue?["checks"]?.arrayValue?.first?.objectValue?["id"]
          == .string("app.control_socket"))
      await fixture.stopAndRemove()
    } catch {
      await session?.disconnect()
      await fixture.stopAndRemove()
      throw error
    }
  }

}

private struct PermissionCLIFixture: Sendable {
  let root: URL
  let project: URL
  let executable: String
  let database: GatewayDatabase
  let control: AppControlPlaneService
  let gatewayService: AppGatewayService
  let controlSocket: ControlSocketService
  let gatewaySocket: URL
  let controlSocketURL: URL
  let reader = TestManagedPolicyReader()
  private let commands = BlockingOperationExecutor(label: "computer-mcp.tests.permission-cli")

  init(executable: String, projectAccess: PermissionState = .notGranted) throws {
    try #require(
      executable.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: executable))
    self.executable = executable
    let root = URL(fileURLWithPath: "/private/tmp/cm-cli-\(UUID().uuidString.prefix(8))")
    self.root = root
    var initialized = false
    defer {
      if !initialized { try? FileManager.default.removeItem(at: root) }
    }
    project = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let directories = AppControlPlaneServiceDirectories(
      applicationSupport: root.appendingPathComponent("state"),
      logs: root.appendingPathComponent("logs"))
    try directories.prepare()
    database = try fixturePermissionDatabase(path: directories.database.path)
    var permissions = Permissions.newPrincipal
    if projectAccess != .notGranted { try permissions.set(projectAccess, for: .project("fixture")) }
    let profile = ProfileGrantConfig(
      grant: ProfileGrant(
        id: .chatGPTOperate, permissions: permissions, fullAccess: true, allowedCallers: [.localMCP]
      ))
    var platform = MacOSPlatform.services(launcher: testExecutionLauncher())
    platform.permissionPolicyReader = reader
    let configuration = GatewayConfiguration(
      runtime: .init(caller: .localMCP, profileID: .chatGPTOperate), profiles: [profile],
      builtin: .init(enabled: ["file.read", "file.write"]), projectDirectory: project)
    let permissionControl = try fixturePermissionControl(
      database: database, configuration: configuration, platform: platform)
    let manifest = try AtomicManifestStore(
      manifestURL: directories.manifest, database: database,
      loader: GatewayManifestConfigurationLoader(
        database: database, applications: platform.applications))
    _ = try manifest.activate(manifest: configuration.exportedTOML())
    try database.saveProject(
      .init(id: "fixture", displayName: "CLI fixture", rootPath: project.path))
    let secrets = try KeychainSecretStore(adapter: MemoryKeychainAdapter())
    control = AppControlPlaneService(
      directories: directories, database: database, permissionControl: permissionControl,
      manifestStore: manifest,
      defaultManifest: DefaultGatewayConfiguration.manifest, secretStore: secrets,
      openAITunnelSupervisor: OpenAITunnelSupervisor(
        launcher: testExecutionLauncher(),
        secretStore: secrets,
        executableSearchDirectories: MacOSPlatform.services(launcher: testExecutionLauncher())
          .executableSearchDirectories,
        proxyResolver: FixedOpenAITunnelHTTPProxyResolver()
      ),
      launchAtLoginController: PermissionCLILaunchAtLoginFake(),
      computerUsePermissionReader: FixedComputerUsePermissionReader(),
      platform: platform,
      bundledPlugins: .init(packages: [], issues: []))
    gatewaySocket = root.appendingPathComponent("gateway.sock")
    controlSocketURL = root.appendingPathComponent("control.sock")
    gatewayService = AppGatewayService(
      controlPlane: control, socketConfiguration: .init(socketURL: gatewaySocket))
    controlSocket = ControlSocketService(
      controlPlane: control, gatewayService: gatewayService, socketURL: controlSocketURL)
    initialized = true
  }

  func run(_ arguments: [String]) async throws -> CommandResult {
    let executable = executable
    let root = root
    let arguments = arguments + ["--control-socket", controlSocketURL.path]
    let result = try await commands.perform {
      let administration = ExecutionAdministration(
        mode: .fullAccess,
        environment: try ExecutionEnvironment(fullAccessVariables: ["PATH": "/usr/bin:/bin"]))
      return try ExecutionAdministration.$current.withValue(administration) {
        try ProcessCommandRunner(
          launcher: testExecutionLauncher(), environment: ["PATH": "/usr/bin:/bin"]
        ).run(
          executable: executable, arguments: arguments, workingDirectory: root, environment: [:],
          timeoutMilliseconds: 10_000, maxOutputBytes: 1_048_576)
      }
    }
    try #require(!result.timedOut, "CLI timed out: \(arguments)")
    try #require(
      !result.stdoutTruncated && !result.stderrTruncated, "CLI output truncated: \(arguments)")
    return result
  }

  func json(_ arguments: [String]) async throws -> JSONValue {
    let result = try await run(arguments)
    try #require(result.exitCode == 0, "CLI \(arguments): \(result.stderr)")
    return try JSONDecoder().decode(JSONValue.self, from: Data(result.stdout.utf8))
  }

  func doctor() async throws -> JSONValue {
    let result = try await run(["doctor", "--journey", "local", "--json"])
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(result.stdout.utf8))
    let status = try #require(value.objectValue?["status"]?.stringValue)
    #expect(result.exitCode == (status == "ready" || status == "verified" ? 0 : 1))
    return value
  }

  func readTarget(_ path: String, retryIDs: [String] = []) -> JSONValue {
    var arguments: [String: JSONValue] = ["project_id": .string("fixture"), "path": .string(path)]
    if !retryIDs.isEmpty {
      arguments["_permission_request_ids"] = .array(retryIDs.map(JSONValue.string))
    }
    return .object(arguments)
  }

  func writeTarget(_ path: String) -> JSONValue {
    .object([
      "project_id": .string("fixture"), "path": .string(path),
      "content": .string("must remain absent"),
    ])
  }

  func read(_ path: String, retryIDs: [String] = [], session: GatewayClientSession) async throws
    -> JSONValue
  {
    try await session.call(toolName: "file.read", arguments: readTarget(path, retryIDs: retryIDs))
      .result
  }

  func requestIDs(_ envelope: JSONValue) throws -> [String] {
    let error = try #require(error(envelope))
    try #require(error["code"] == .string("permission.required"), "\(envelope)")
    let ids = try #require(error["request_ids"]?.arrayValue).map { value in
      let id = try #require(value.stringValue)
      try #require(UUID(uuidString: id) != nil)
      return id
    }
    try #require(!ids.isEmpty)
    return ids
  }

  func answer(_ ids: [String], with answer: String) async throws {
    for id in ids {
      let view = try await json(["permissions", "requests"])
      let revision = try #require(view.objectValue?["revision"]?.intValue)
      let answered = try await json([
        "permissions", "answer", id, "--answer", answer, "--expected-revision", String(revision),
      ])
      #expect(answered.objectValue?["answered"] == .string(id))
    }
  }

  func requestSet() async throws -> Set<String> {
    let view = try await json(["permissions", "requests"])
    return Set(
      try #require(view.objectValue?["requests"]?.arrayValue).compactMap {
        $0.objectValue?["request"]?.objectValue?["identity"]?.objectValue?["id"]?.stringValue
      })
  }

  func currentGrant() throws -> ProfileGrant {
    try #require(try database.profiles().first { $0.id == .chatGPTOperate })
  }

  @discardableResult
  func update(_ grant: ProfileGrant, permissionRevision: Int? = nil, requireSuccess: Bool = true)
    async throws -> CommandResult
  {
    let shown = try await json(["profile", "show", grant.id.rawValue])
    let decoded = try CanonicalJSONCoding.decoder().decode(
      ProfileGrant.self, from: JSONEncoder().encode(shown))
    try #require(decoded == (try currentGrant()))
    let revision: Int
    if let permissionRevision {
      revision = permissionRevision
    } else {
      revision = try #require(shown.objectValue?["permission_revision"]?.intValue)
    }
    var edited = try #require(shown.objectValue)
    let replacement = try #require(ControlToolResponse.encodedPayload(grant).objectValue)
    edited.merge(replacement) { _, current in current }
    let file = root.appendingPathComponent("profile.json")
    try JSONEncoder().encode(JSONValue.object(edited)).write(to: file)
    let response = try await run([
      "profile", "permissions", "--file", file.path,
      "--expected-permission-revision", String(revision),
    ])
    if requireSuccess { try #require(response.exitCode == 0, "\(response.stderr)") }
    return response
  }

  func result(_ envelope: JSONValue) -> [String: JSONValue]? {
    envelope.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue
  }
  func error(_ envelope: JSONValue) -> [String: JSONValue]? {
    envelope.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue
  }
  func content(_ envelope: JSONValue) -> JSONValue? { result(envelope)?["content"] }

  func exists(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: project.appendingPathComponent(name).path)
  }
  func stopAndRemove() async {
    await controlSocket.stop()
    await gatewayService.stop()
    try? FileManager.default.removeItem(at: root)
    #expect(!FileManager.default.fileExists(atPath: root.path))
  }
}

private struct PermissionCLILaunchAtLoginFake: LaunchAtLoginControlling {
  func state() -> LaunchAtLoginState { .unavailable }
  func setEnabled(_ enabled: Bool) throws {}
}
