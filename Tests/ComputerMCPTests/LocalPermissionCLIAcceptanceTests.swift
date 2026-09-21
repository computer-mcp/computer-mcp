import Foundation
import Testing

@testable import ComputerMCP

@Suite(
  .enabled(
    if: ProcessInfo.processInfo.environment["COMPUTER_MCP_TEST_GATEWAY_EXECUTABLE"] != nil,
    "Set COMPUTER_MCP_TEST_GATEWAY_EXECUTABLE to the exact local CLI artifact for isolated acceptance."
  ),
  .timeLimit(.minutes(2)))
struct LocalPermissionCLIAcceptanceTests {
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
          ["app", "status"], ["workspace", "list"], ["config", "validate"],
          ["config", "history"], ["providers", "list"], ["audit", "list"],
          ["tunnel", "openai", "list"], ["tunnel", "cloudflare", "list"],
        ] {
          _ = try await fixture.json(arguments)
        }
      }
      _ = try await first.json(["workspace", "remove", "fixture"])
      #expect(try first.database.workspaces().isEmpty)
      #expect(try second.database.workspaces().count == 1)
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
  func realCLIControlsExactHostApprovalsWithoutRestartingTheIsolatedGateway() async throws {
    let executable = try #require(
      ProcessInfo.processInfo.environment["COMPUTER_MCP_TEST_GATEWAY_EXECUTABLE"])
    try #require(
      executable.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: executable))
    let fixture = try PermissionCLIFixture(executable: executable)
    var session: GatewayClientSession?
    do {
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
      for id in ["app.control_socket", "gateway.running", "workspace.registered"] {
        #expect(
          checks.first { $0.objectValue?["id"] == .string(id) }?.objectValue?["status"]
            == .string("pass"), "Doctor check: \(id)")
      }

      let initial = try await fixture.json(["profile", "show", "chatgpt-operate"])
      #expect(initial.objectValue?["mode"] == .string("read-only"))
      let initialRevision = try #require(initial.objectValue?["authorization_revision"]?.intValue)
      let approvedTarget = fixture.target(path: "approved.txt", content: "approved contents")
      let deniedReadOnly = try await connected.call(
        toolName: "file.write", arguments: approvedTarget)
      #expect(deniedReadOnly.result.objectValue?["isError"] == .bool(true))
      #expect(!fixture.exists("approved.txt"))

      let edited = try await fixture.json([
        "profile", "permissions", "chatgpt-operate", "--mode", "workspace-operations",
        "--confirmation-policy", "all-writes", "--no-arbitrary-execution",
        "--capabilities",
        "operations.prepare,operations.commit,workspace.list,file.read,file.write",
        "--workspaces", "fixture", "--allowed-callers", "local-mcp",
        "--expected-revision", String(initialRevision),
      ])
      #expect(edited.objectValue?["mode"] == .string("workspace-operations"))
      #expect(edited.objectValue?["confirmation_policy"] == .string("all-writes"))
      #expect(edited.objectValue?["full_shell_enabled"] == .bool(false))
      #expect(edited.objectValue?["workspace_ids"] == .array([.string("fixture")]))
      #expect(edited.objectValue?["allowed_callers"] == .array([.string("local-mcp")]))
      let revision = try #require(edited.objectValue?["authorization_revision"]?.intValue)
      #expect(revision > initialRevision)
      #expect(
        try await fixture.json(["profile", "show", "chatgpt-operate"]).objectValue?[
          "authorization_revision"] == .number(Double(revision)))

      let stale = try await fixture.run([
        "profile", "permissions", "chatgpt-operate", "--mode", "read-only",
        "--expected-revision", String(initialRevision),
      ])
      #expect(stale.exitCode != 0)
      #expect(stale.stderr.contains("authorization changed"))
      #expect(
        try fixture.database.profiles().first { $0.id == .chatGPTOperate }?.authorizationRevision
          == Int64(revision))

      let approvedID = try await fixture.prepare(approvedTarget, session: connected)
      #expect(try fixture.database.operationTicket(id: approvedID)?.state == .pendingApproval)
      #expect(!fixture.exists("approved.txt"))
      let listed = try await fixture.json(["permissions", "approvals", "list", "--limit", "20"])
      let requests = try #require(listed.objectValue?["result"]?.arrayValue)
      #expect(
        requests.contains {
          $0.objectValue?["id"] == .string(approvedID)
            && $0.objectValue?["state"] == .string("pending_approval")
        })
      #expect(
        requests.first { $0.objectValue?["id"] == .string(approvedID) }?.objectValue?[
          "review_summary"]?.stringValue?.contains("approved contents") == true)
      let approved = try await fixture.json(["permissions", "approvals", "approve", approvedID])
      #expect(approved.objectValue?["state"] == .string("approved"))

      let substituted = try await fixture.commit(
        approvedID, target: fixture.target(path: "approved.txt", content: "unreviewed contents"),
        session: connected)
      #expect(substituted.objectValue?["isError"] == .bool(true))
      #expect(!fixture.exists("approved.txt"))
      let committed = try await fixture.commit(
        approvedID, target: approvedTarget, session: connected)
      #expect(committed.objectValue?["isError"] != .bool(true), "\(committed)")
      #expect(try fixture.contents("approved.txt") == "approved contents")
      #expect(try fixture.database.operationTicket(id: approvedID)?.state == .succeeded)
      let repeated = try await fixture.commit(
        approvedID, target: approvedTarget, session: connected)
      #expect(repeated.objectValue?["isError"] == .bool(true))
      #expect(try fixture.contents("approved.txt") == "approved contents")

      let deniedTarget = fixture.target(path: "denied.txt", content: "must not be written")
      let deniedID = try await fixture.prepare(deniedTarget, session: connected)
      let denied = try await fixture.json(["permissions", "approvals", "deny", deniedID])
      #expect(denied.objectValue?["state"] == .string("denied"))
      #expect(
        try await fixture.commit(deniedID, target: deniedTarget, session: connected).objectValue?[
          "isError"] == .bool(true))
      #expect(!fixture.exists("denied.txt"))

      let revokedTarget = fixture.target(path: "revoked.txt", content: "must remain absent")
      let revokedID = try await fixture.prepare(revokedTarget, session: connected)
      _ = try await fixture.json(["permissions", "approvals", "approve", revokedID])
      let revoked = try await fixture.json([
        "profile", "permissions", "chatgpt-operate", "--workspaces", "",
        "--expected-revision", String(revision),
      ])
      #expect(revoked.objectValue?["workspace_ids"] == .array([]))
      #expect(try fixture.database.operationTicket(id: revokedID)?.state == .denied)
      #expect(
        try await fixture.commit(revokedID, target: revokedTarget, session: connected).objectValue?[
          "isError"] == .bool(true))
      let directAfterRevocation = try await connected.call(
        toolName: "file.write", arguments: revokedTarget)
      #expect(directAfterRevocation.result.objectValue?["isError"] == .bool(true))
      #expect(!fixture.exists("revoked.txt"))
      #expect(try fixture.contents("approved.txt") == "approved contents")

      let fullAccess = try await fixture.json([
        "profile", "permissions", "chatgpt-operate", "--mode", "local-full-access",
        "--no-arbitrary-execution",
      ])
      #expect(fullAccess.objectValue?["mode"] == .string("local-full-access"))
      #expect(fullAccess.objectValue?["full_shell_enabled"] == .bool(false))
      #expect(fullAccess.objectValue?["workspace_ids"] == .array([]))
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
  let workspace: URL
  let executable: String
  let database: GatewayDatabase
  let gatewayService: AppGatewayService
  let controlSocket: ControlSocketService
  let gatewaySocket: URL
  let controlSocketURL: URL
  private let commands = BlockingOperationExecutor(label: "computer-mcp.tests.permission-cli")

  init(executable: String) throws {
    self.executable = executable
    let root = URL(fileURLWithPath: "/private/tmp/cm-cli-\(UUID().uuidString.prefix(8))")
    self.root = root
    var initialized = false
    defer {
      if !initialized { try? FileManager.default.removeItem(at: root) }
    }
    workspace = root.appendingPathComponent("workspace")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let directories = AppControlPlaneServiceDirectories(
      applicationSupport: root.appendingPathComponent("state"),
      logs: root.appendingPathComponent("logs"))
    try directories.prepare()
    database = try GatewayDatabase(path: directories.database.path)
    let profile = ProfileGrantConfig(
      id: .chatGPTOperate,
      capabilities: [
        "operations.prepare", "operations.commit", "workspace.list", "file.read", "file.write",
      ],
      workspaces: ["fixture"], allowedCallers: [.localMCP], mode: .readOnly)
    let manifest = try AtomicManifestStore(manifestURL: directories.manifest, database: database)
    _ = try manifest.activate(
      manifest: GatewayConfiguration(
        runtime: .init(caller: .localMCP, profileID: .chatGPTOperate), profiles: [profile],
        builtin: .init(enabled: ["file.read", "file.write"]), workspaceDirectory: workspace
      ).exportedTOML())
    try database.saveProfile(profile.grant)
    try database.saveWorkspace(
      .init(id: "fixture", displayName: "CLI fixture", rootPath: workspace.path))
    let secrets = try KeychainSecretStore(adapter: MemoryKeychainAdapter())
    let control = AppControlPlaneService(
      directories: directories, database: database, manifestStore: manifest, secretStore: secrets,
      openAITunnelSupervisor: OpenAITunnelSupervisor(secretStore: secrets),
      launchAtLoginController: PermissionCLILaunchAtLoginFake(),
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
      try ProcessCommandRunner(environment: ["PATH": "/usr/bin:/bin"]).run(
        executable: executable, arguments: arguments, workingDirectory: root, environment: [:],
        timeoutMilliseconds: 10_000, maxOutputBytes: 1_048_576)
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

  func target(path: String, content: String) -> JSONValue {
    .object([
      "workspace_id": .string("fixture"), "path": .string(path), "content": .string(content),
    ])
  }

  func prepare(_ target: JSONValue, session: GatewayClientSession) async throws -> String {
    let report = try await session.call(
      toolName: "operations.prepare",
      arguments: .object([
        "workspace_id": .string("fixture"), "tool": .string("file.write"), "arguments": target,
        "ttl_ms": .number(300_000),
      ]))
    try #require(report.result.objectValue?["isError"] != .bool(true), "\(report.result)")
    return try #require(
      report.result.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue?[
        "ticket_id"]?.stringValue)
  }

  func commit(_ id: String, target: JSONValue, session: GatewayClientSession) async throws
    -> JSONValue
  {
    try await session.call(
      toolName: "operations.commit",
      arguments: .object([
        "workspace_id": .string("fixture"), "ticket_id": .string(id), "tool": .string("file.write"),
        "arguments": target,
      ])
    ).result
  }

  func exists(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: workspace.appendingPathComponent(name).path)
  }
  func contents(_ name: String) throws -> String {
    try String(contentsOf: workspace.appendingPathComponent(name), encoding: .utf8)
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
