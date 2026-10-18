import Foundation
import Testing

@testable import ComputerMCP

@Suite(.nativeIntegration, .serialized, .timeLimit(.minutes(2)))
struct GatewayHTTPClientControlTests {
  @Test
  func localOwnerApprovesOnlyTheReviewedSessionAndRemoteCannotEscalate() async throws {
    let fixture = try HTTPClientControlFixture()
    try await fixture.runtime.startListening()
    do {
      let first = try await fixture.connect()
      let original = try #require(await fixture.runtime.controlSessions().first)
      let second = try await fixture.connect()
      let owner = fixture.owner
      let tools = try await first.listToolNames()
      #expect(!tools.contains("shell.run") && !tools.contains("clients.allow"))
      #expect(
        try await first.call(toolName: "clients.allow", arguments: fixture.approval(original))
          .result.objectValue?["isError"] == .bool(true))
      await #expect(throws: (any Error).self) {
        let invalid = try await GatewayClientSession.connectSocket(socketURL: fixture.socket)
        await invalid.disconnect()
      }
      await #expect(throws: ControlSocketCallError.self) {
        try await owner.call(
          "clients.allow", arguments: fixture.approval(original, explicit: false))
      }
      await #expect(throws: ControlSocketCallError.self) {
        try await owner.call(
          "clients.allow", arguments: fixture.approval(original, extra: ["unknown": .bool(true)]))
      }
      let approved = try await owner.call("clients.allow", arguments: fixture.approval(original))
      #expect(
        approved.objectValue?["full_access_consent"]?.objectValue?["lifetime"]
          == .string("this-session"))
      #expect(try fixture.database.clientTrusts().isEmpty)
      #expect(try await first.listToolNames().contains("shell.run"))
      #expect(try await !second.listToolNames().contains("shell.run"))
      #expect(
        try await first.call(toolName: "shell.run", arguments: fixture.shell).result.objectValue?[
          "isError"] == .bool(false))
      #expect(
        try String(contentsOf: fixture.root.appendingPathComponent("consent.txt"), encoding: .utf8)
          == "approved")
      await #expect(throws: ControlSocketCallError.self) {
        try await owner.call(
          "clients.end",
          arguments: .object([
            "id": .string(original.id), "expected_revision": .integer(original.revision),
          ]))
      }
      let limited = try await owner.call(
        "clients.limit",
        arguments: .object([
          "id": .string(original.id), "expected_revision": .integer(original.revision + 1),
          "mode": .string("observe"),
        ]))
      #expect(limited.objectValue?["access_limit"] == .string("read-only"))
      #expect(try await !first.listToolNames().contains("shell.run"))
      #expect(
        try await first.call(toolName: "shell.run", arguments: fixture.shell).result.objectValue?[
          "isError"] == .bool(true))
      _ = try await owner.call(
        "clients.end",
        arguments: .object([
          "id": .string(original.id), "expected_revision": .integer(original.revision + 2),
        ]))
      #expect(try await first.listToolNames().isEmpty)
      #expect(try await second.listToolNames().contains("system.time"))
      #expect(await fixture.runtime.boundPort() != nil)
      await first.disconnect()
      await second.disconnect()
      await fixture.stopAndRemove()
    } catch {
      await fixture.stopAndRemove()
      throw error
    }
  }

  @Test(arguments: [(false, true), (true, false)])
  func persistentApprovalRequiresDurableStorageAndAuthenticatedIdentity(
    persistent: Bool, authenticated: Bool
  ) async throws {
    let fixture = try HTTPClientControlFixture(persistent: persistent, authenticated: authenticated)
    try await fixture.runtime.startListening()
    do {
      let session = try await fixture.connect()
      let original = try #require(await fixture.runtime.controlSessions().first)
      await #expect(throws: ControlSocketCallError.self) {
        try await fixture.owner.call(
          "clients.allow",
          arguments: fixture.approval(original, extra: ["always_allow_client": .bool(true)]))
      }
      #expect(await fixture.runtime.controlSessions().first?.revision == original.revision)
      #expect(try fixture.database.clientTrusts().isEmpty)
      _ = try await fixture.owner.call("clients.allow", arguments: fixture.approval(original))
      #expect(try await session.listToolNames().contains("shell.run"))
      await session.disconnect()
      let next = try await fixture.connect()
      #expect(try await !next.listToolNames().contains("shell.run"))
      await next.disconnect()
      await fixture.stopAndRemove()
    } catch {
      await fixture.stopAndRemove()
      throw error
    }
  }

  @Test
  func actualCLIUsesExactRevisionsFromAnotherDirectoryAndRevokesSavedTrust() async throws {
    let fixture = try HTTPClientControlFixture(persistent: true)
    try await fixture.runtime.startListening()
    do {
      let session = try await fixture.connect()
      let original = try #require(await fixture.runtime.controlSessions().first)
      let listed = try await fixture.json(["list", "--limit", "1"])
      #expect(
        listed.objectValue?["sessions"]?.arrayValue?.first?.objectValue?["id"]
          == .string(original.id))
      #expect(try await fixture.command(["allow", original.id]).exitCode != 0)
      let stale = try await fixture.command([
        "allow", original.id, "--full-access", "--expected-revision", "9007199254740993",
        "--expected-trust-revision", "0",
      ])
      #expect(stale.exitCode != 0)
      let staleJSON = try JSONDecoder().decode(JSONValue.self, from: Data(stale.stdout.utf8))
      #expect(
        staleJSON.objectValue?["error"]?.objectValue?["code"]
          == .string("control.invalid_arguments"))
      #expect(try await !session.listToolNames().contains("shell.run"))
      let approved = try await fixture.json([
        "allow", original.id, "--full-access", "--always-allow-client",
      ])
      #expect(
        approved.objectValue?["full_access_consent"]?.objectValue?["lifetime"]
          == .string("always-allow-client"))
      #expect(try await session.listToolNames().contains("shell.run"))
      let trust = try #require(try fixture.database.clientTrusts().first)
      await session.disconnect()
      let next = try await fixture.connect()
      #expect(try await next.listToolNames().contains("shell.run"))
      _ = try await fixture.json(["trusts", "--id", trust.id])
      #expect(
        try await fixture.command(["revoke", trust.id, "--expected-revision", "0"]).exitCode != 0)
      _ = try await fixture.json(["revoke", trust.id])
      #expect(try await !next.listToolNames().contains("shell.run"))
      let nextScope = try #require(await fixture.runtime.controlSessions().first)
      _ = try await fixture.json(["limit", nextScope.id, "--mode", "observe"])
      _ = try await fixture.json(["end", nextScope.id])
      #expect(try await next.listToolNames().isEmpty)
      #expect(try fixture.database.clientTrusts().first?.fullAccessAllowed == false)
      let consentEvents = try fixture.database.auditEvents().filter {
        $0.capabilityID == "control.full-access.always-allow"
          || $0.capabilityID == "control.client-trust.revoke"
      }
      #expect(consentEvents.count == 2 && consentEvents.allSatisfy { $0.caller == .localCLI })
      await next.disconnect()
      await fixture.stopAndRemove()
    } catch {
      await fixture.stopAndRemove()
      throw error
    }
  }

  @Test
  func listsAreBoundedAndControlSocketIsClosedWithItsListener() async throws {
    let fixture = try HTTPClientControlFixture()
    try await fixture.runtime.startListening()
    do {
      let first = try await fixture.connect()
      let second = try await fixture.connect()
      let control = try await GatewayClientSession.connectSocket(
        configuration: .init(socketURL: fixture.socket, clientIdentity: .localCLI))
      #expect(
        Set(try await control.listToolNames()) == Set(GatewayClientControl.contracts.map(\.name)))
      let page = try await fixture.owner.call(
        "clients.list", arguments: .object(["limit": .integer(1)]))
      let cursor = try #require(page.objectValue?["next_after_id"]?.stringValue)
      let next = try await fixture.owner.call(
        "clients.list", arguments: .object(["limit": .integer(1), "after_id": .string(cursor)]))
      #expect(page.objectValue?["sessions"]?.arrayValue?.count == 1)
      #expect(next.objectValue?["sessions"]?.arrayValue?.count == 1)
      #expect(next.objectValue?["next_after_id"] == .null)
      await #expect(throws: ControlSocketCallError.self) {
        try await fixture.owner.call("clients.list", arguments: .object(["limit": .integer(201)]))
      }
      async let firstStop: Void = fixture.runtime.stop()
      async let secondStop: Void = fixture.runtime.stop()
      _ = await (firstStop, secondStop)
      #expect(await fixture.runtime.boundPort() == nil)
      #expect(await fixture.runtime.controlSessions().isEmpty)
      #expect(!FileManager.default.fileExists(atPath: fixture.socket.path))
      await #expect(throws: (any Error).self) {
        try await control.call(toolName: "clients.list", arguments: .object([:]))
      }
      try await fixture.runtime.startListening()
      #expect(try await fixture.owner.call("clients.list").objectValue?["sessions"] == .array([]))
      await #expect(throws: (any Error).self) {
        try await control.call(toolName: "clients.list", arguments: .object([:]))
      }
      await control.disconnect()
      await first.disconnect()
      await second.disconnect()
      await fixture.stopAndRemove()
    } catch {
      await fixture.stopAndRemove()
      throw error
    }
  }

  @Test
  func httpBindFailureClosesItsPreparedOwnerSocket() async throws {
    let running = try HTTPClientControlFixture()
    try await running.runtime.startListening()
    do {
      let candidate = try HTTPClientControlFixture(
        port: #require(await running.runtime.boundPort()))
      await #expect(throws: (any Error).self) { try await candidate.runtime.startListening() }
      #expect(await candidate.runtime.boundPort() == nil)
      #expect(!FileManager.default.fileExists(atPath: candidate.socket.path))
      #expect(try await running.owner.call("clients.list").objectValue?["sessions"] == .array([]))
      await candidate.stopAndRemove()
      await running.stopAndRemove()
    } catch {
      await running.stopAndRemove()
      throw error
    }
  }

  @Test
  func ownerSocketFailureDoesNotOpenHTTPOrRemoveAnUnrelatedFile() async throws {
    let fixture = try HTTPClientControlFixture()
    try Data("unrelated".utf8).write(to: fixture.socket)
    await #expect(throws: (any Error).self) { try await fixture.runtime.startListening() }
    #expect(await fixture.runtime.boundPort() == nil)
    await fixture.runtime.stop()
    #expect(try String(contentsOf: fixture.socket, encoding: .utf8) == "unrelated")
    await fixture.stopAndRemove()
  }
}

private struct HTTPClientControlFixture: Sendable {
  let root: URL
  let socket: URL
  let database: GatewayDatabase
  let runtime: GatewayHTTPRuntime
  let token: String?
  let commands = BlockingOperationExecutor(label: "computer-mcp.tests.http-client-cli")
  var owner: AppControlPlaneServiceClient { .init(socketURL: socket) }

  init(persistent: Bool = false, authenticated: Bool = true, port: Int = 0) throws {
    root = URL(
      fileURLWithPath: "/tmp/cm-http-owner-" + UUID().uuidString.prefix(8), isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    socket = root.appendingPathComponent("control.sock")
    database =
      try persistent
      ? GatewayDatabase(path: root.appendingPathComponent("state.sqlite").path)
      : GatewayDatabase(inMemory: ())
    token = authenticated ? "isolated-http-owner-test" : nil
    let profile = ProfileGrantConfig(
      id: .chatGPTOperate, capabilities: ["system.time", "file.read"],
      workspaces: ["fixture"], allowedCallers: [.secureTunnel], mode: .workspaceOperations)
    var configuration = GatewayConfiguration(
      runtime: .init(caller: .secureTunnel, profileID: .chatGPTOperate), profiles: [profile],
      builtin: .init(enabled: ["system.time", "file.read"]))
    configuration.policy.shellEnabled = true
    let gateway = try GatewayRuntime(
      configuration: configuration, database: database,
      registeredWorkspaces: [.init(id: "fixture", displayName: "Fixture", rootPath: root.path)])
    runtime = GatewayHTTPRuntime(
      configuration: configuration, registry: gateway,
      host: "127.0.0.1", port: port, publicBaseURL: nil, accessToken: token,
      control: .init(socketURL: socket, database: database))
  }

  func connect() async throws -> GatewayClientSession {
    let port = try #require(await runtime.boundPort())
    return try await GatewayClientSession.connectHTTP(
      endpoint: #require(URL(string: "http://127.0.0.1:\(port)/mcp")), accessToken: token)
  }

  func approval(
    _ snapshot: GatewayControlSessionSnapshot, explicit: Bool = true,
    extra: [String: JSONValue] = [:]
  ) -> JSONValue {
    .object(
      [
        "id": .string(snapshot.id), "full_access": .bool(explicit),
        "expected_revision": .integer(snapshot.revision), "expected_trust_revision": .integer(0),
      ].merging(extra) { _, new in new })
  }

  var shell: JSONValue {
    .object([
      "workspace_id": .string("fixture"), "mode": .string("argv"),
      "executable": .string("/bin/sh"),
      "argv": .array([.string("-c"), .string("printf approved >> consent.txt")]),
      "cwd": .string(root.path),
    ])
  }

  func command(_ arguments: [String]) async throws -> CommandResult {
    let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
        ".build/debug/computer-mcp")
    let result = try await commands.perform {
      try ProcessCommandRunner(environment: ["PATH": "/usr/bin:/bin"]).run(
        executable: executable.path,
        arguments: ["clients"] + arguments + ["--control-socket", socket.path],
        workingDirectory: root, environment: [:], timeoutMilliseconds: 10_000,
        maxOutputBytes: 1_048_576)
    }
    try #require(!result.timedOut && !result.stdoutTruncated && !result.stderrTruncated)
    return result
  }

  func json(_ arguments: [String]) async throws -> JSONValue {
    let result = try await command(arguments)
    try #require(result.exitCode == 0, "\(arguments): \(result.stderr)")
    return try JSONDecoder().decode(JSONValue.self, from: Data(result.stdout.utf8))
  }

  func stopAndRemove() async {
    await runtime.stop()
    try? FileManager.default.removeItem(at: root)
  }
}
