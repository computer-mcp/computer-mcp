import CryptoKit
import Foundation
import MCP
import Testing

@testable import ComputerMCP

@Suite(.serialized, .timeLimit(.minutes(1)))
struct MCPBoundHostServicesTests {
  @Test
  func genericHostCallbackRequiresWorkspaceWhenSelectionIsAmbiguous() async throws {
    let fixture = try HostAuthorityFixture(additionalWorkspace: true)
    defer { fixture.remove() }
    let tool = try #require(fixture.runtime.listTools().first { $0.name == "mcp.tools.call" })
    let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
    #expect(properties["workspace_id"]?.objectValue?["type"] == .string("string"))
    do {
      _ = try await fixture.genericDiagnostics(workspaceID: nil)
      Issue.record("An ambiguous workspace must be rejected before invoking the plugin.")
    } catch {
      #expect(String(describing: error).contains("workspace_required"))
    }
    await fixture.close()
  }

  @Test(arguments: [false, true])
  func genericDiagnosticsBindTheHostWorkspace(explicitWorkspace: Bool) async throws {
    let fixture = try HostAuthorityFixture()
    defer { fixture.remove() }
    let result = try await fixture.genericDiagnostics(
      workspaceID: explicitWorkspace ? "scope" : nil)
    #expect(result.objectValue?["isError"] == .bool(false))
    #expect(fixture.payload(result)["owner"]?.objectValue?["workspace_id"] == .string("scope"))
    await fixture.close()
  }

  @Test(arguments: ["no-invocation", "wrong-method", "extra-owner", "caller-time"])
  func diagnosticCallbacksRequireAnExactLiveInvocation(attack: String) async throws {
    let fixture = try HostAuthorityFixture()
    defer { fixture.remove() }
    var arguments: [String: JSONValue] = ["limit": .number(1)]
    if attack == "extra-owner" { arguments["profile_id"] = .string("local-admin") }
    if attack == "caller-time" { arguments["now"] = .number(1) }
    let result: JSONValue
    if attack == "no-invocation" {
      result = try await fixture.direct("host.diagnostics.snapshot", arguments)
    } else {
      let args = arguments
      result = try await fixture.during(
        attack == "wrong-method" ? "codex.app.thread.start" : "codex.diagnostics.snapshot",
        ["limit": .number(1)]
      ) { service in
        try await .encoded(service.call(name: "host.diagnostics.snapshot", arguments: args))
      }
    }
    #expect(result.objectValue?["isError"] == .bool(true))
    await fixture.close()
  }

  @Test
  func invocationEndsOnBothSuccessAndError() async throws {
    let fixture = try HostAuthorityFixture()
    defer { fixture.remove() }
    for fails in [false, true] {
      if fails {
        await #expect(throws: (any Error).self) {
          try await fixture.during("codex.diagnostics.snapshot") { _ in
            throw MCPHostServiceError.denied("Fixture failure")
          }
        }
      } else {
        _ = try await fixture.during("codex.diagnostics.snapshot") { _ in .object([:]) }
      }
      let result = try await fixture.direct("host.diagnostics.snapshot", ["limit": .number(1)])
      #expect(result.objectValue?["isError"] == .bool(true))
    }
    await fixture.close()
  }

  @Test
  func privateServiceSurfaceIsNotExposedUpstream() async throws {
    let fixture = try HostAuthorityFixture()
    defer { fixture.remove() }
    #expect(try !fixture.runtime.listTools().contains { $0.name.hasPrefix("host.") })
    #expect(
      Set(MCPBoundHostServices.tools.map(\.name)) == [
        "host.workspaces.register", "host.workspaces.authorize_removal",
        "host.workspaces.unregister", "host.diagnostics.snapshot",
      ])
    let result = try await fixture.direct("host.unknown", [:])
    #expect(result.objectValue?["isError"] == .bool(true))
    await fixture.close()
    #expect(await fixture.service.cleanupConfirmed)
    await #expect(throws: (any Error).self) {
      try await fixture.service.call(
        name: "host.diagnostics.snapshot", arguments: ["limit": .number(1)])
    }
  }

  @Test
  func completedProvisionInvocationsDoNotExhaustTheConnection() async throws {
    let fixture = try HostAuthorityFixture(worktrees: true)
    defer { fixture.remove() }
    for index in 0..<129 {
      let receipt = try fixture.worktreeReceipt()
      let result = try await fixture.during(
        "codex.worktree.provision.perform",
        [
          "plan_id": receipt["id"]!, "expected_revision": .number(1),
          "confirm_provision": .bool(true),
        ]
      ) { service in
        try await .encoded(
          service.call(name: "host.workspaces.register", arguments: ["worktree": .object(receipt)]))
      }
      try #require(
        result.objectValue?["isError"] == .bool(false), "Provision \(index + 1): \(result)")
      let workspaceID = try #require(receipt["workspace_id"]?.stringValue)
      #expect(try fixture.database.derivedWorkspaceRegistration(id: workspaceID) != nil)
    }
    await fixture.close()
  }

  @Test(arguments: [false, true])
  func registrationRollbackRequiresItsOriginalLiveInvocation(laterInvocation: Bool) async throws {
    let fixture = try HostAuthorityFixture(worktrees: true)
    defer { fixture.remove() }
    let receipt = try fixture.worktreeReceipt()
    let args: [String: JSONValue] = [
      "plan_id": receipt["id"]!, "expected_revision": .number(1),
      "confirm_provision": .bool(true),
    ]
    let registered = try await fixture.during("codex.worktree.provision.perform", args) { service in
      let result = try await service.call(
        name: "host.workspaces.register", arguments: ["worktree": .object(receipt)])
      try #require(result.isError == false)
      if laterInvocation { return try .encoded(result) }
      return try await .encoded(
        service.call(name: "host.workspaces.unregister", arguments: ["worktree": .object(receipt)]))
    }
    #expect(registered.objectValue?["isError"] == .bool(false))
    if laterInvocation {
      let replay = try await fixture.during("codex.worktree.provision.perform", args) { service in
        try await .encoded(
          service.call(
            name: "host.workspaces.unregister", arguments: ["worktree": .object(receipt)]))
      }
      #expect(replay.objectValue?["isError"] == .bool(true))
    }
    let workspaceID = try #require(receipt["workspace_id"]?.stringValue)
    #expect((try fixture.database.workspace(id: workspaceID) != nil) == laterInvocation)
    await fixture.close()
  }

  @Test(arguments: ["missing", "other-principal"])
  func derivedReceiptMustBelongToTheVerifiedPrincipal(principal: String) async throws {
    let fixture = try HostAuthorityFixture(worktrees: true)
    defer { fixture.remove() }
    var receipt = try fixture.worktreeReceipt()
    receipt["principal_id"] = principal == "missing" ? nil : .string(principal)
    let wireReceipt = receipt
    let result = try await fixture.during(
      "codex.worktree.provision.perform",
      [
        "plan_id": receipt["id"]!, "expected_revision": .number(1),
        "confirm_provision": .bool(true),
      ]
    ) { service in
      try await .encoded(
        service.call(
          name: "host.workspaces.register", arguments: ["worktree": .object(wireReceipt)]))
    }
    #expect(result.objectValue?["isError"] == .bool(true))
    #expect(
      try fixture.database.derivedWorkspaceRegistration(id: receipt["workspace_id"]!.stringValue!)
        == nil)
    await fixture.close()
  }

  @Test
  func receiptCallerIsProvenanceRatherThanResourceOwnership() async throws {
    let fixture = try HostAuthorityFixture(worktrees: true)
    defer { fixture.remove() }
    var receipt = try fixture.worktreeReceipt()
    receipt["caller"] = .string("local-cli")
    let wireReceipt = receipt
    let result = try await fixture.during(
      "codex.worktree.provision.perform",
      [
        "plan_id": receipt["id"]!, "expected_revision": .number(1),
        "confirm_provision": .bool(true),
      ]
    ) { service in
      try await .encoded(
        service.call(
          name: "host.workspaces.register", arguments: ["worktree": .object(wireReceipt)]))
    }
    #expect(result.objectValue?["isError"] == .bool(false))
    #expect(
      try fixture.database.derivedWorkspaceRegistration(id: receipt["workspace_id"]!.stringValue!)?
        .principalID == "fixture-principal")
    await fixture.close()
  }

}

/// Explicit protocol peer substitute for negative host authorization tests.
/// The separate opt-in integration suite uses the real compiled adapter.
private final class HostAuthorityFixture: @unchecked Sendable {
  let root: URL
  let database: GatewayDatabase
  let runtime: GatewayRuntime
  let service: MCPBoundHostServices
  let peer = HostServiceProbe()
  init(
    worktrees: Bool = false, persistedProfile: Bool = true, additionalWorkspace: Bool = false
  ) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    database = try GatewayDatabase(inMemory: ())
    let workspace = RegisteredWorkspace(id: "scope", displayName: "Fixture", rootPath: root.path)
    try database.saveWorkspace(workspace)
    var workspaces = [workspace]
    if additionalWorkspace {
      let other = RegisteredWorkspace(id: "other", displayName: "Other", rootPath: root.path)
      try database.saveWorkspace(other)
      workspaces.append(other)
    }
    let caps = ["mcp.tools.call", "operations.prepare", "operations.commit"]
    if persistedProfile {
      try database.saveProfile(
        .init(
          id: .chatGPTOperate, capabilityIDs: Set(caps), workspaceIDs: ["scope"],
          allowedCallers: [.secureTunnel], mode: .workspaceOperations))
    }
    runtime = try GatewayRuntime(
      configuration: .init(
        runtime: .init(caller: .secureTunnel, profileID: .chatGPTOperate),
        profiles: [
          .init(
            id: .chatGPTOperate, capabilities: caps, workspaces: ["scope"],
            allowedCallers: [.secureTunnel], mode: .workspaceOperations)
        ],
        mcp: .init(servers: [
          .init(
            id: "probe", transport: .stdio, command: "/bin/cat", exposure: .reexport,
            prefix: "adapter", allowedTools: HostServiceProbe.methods,
            toolRisks: Dictionary(
              uniqueKeysWithValues: HostServiceProbe.methods.map { ($0, .workspaceWrite) }),
            hostServices: true)
        ])),
      context: .init(
        caller: .secureTunnel, profileID: .chatGPTOperate,
        transportTrace: .init(transport: "gateway_socket", socketConnectionID: "connection"),
        trustedPrincipalID: "fixture-principal"),
      database: database, registeredWorkspaces: workspaces, mcpClient: peer)
    let captured = try #require(peer.context)
    if worktrees {
      let managed = root.resolvingSymlinksInPath().appendingPathComponent("managed")
      try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: false)
      let scoped = MCPHostContext(
        runtimeID: captured.runtimeID,
        context: .init(
          caller: captured.caller, profileID: captured.profileID,
          transportTrace: captured.transportTrace, trustedPrincipalID: captured.principalID),
        workspaceID: captured.workspace.id,
        rootURL: URL(fileURLWithPath: captured.workspace.rootPath),
        readOnly: captured.readOnly, tools: captured.tools, managedWorkspaceRoot: managed)
      service = MCPBoundHostServices(
        database: database, directory: try #require(captured.tools), context: scoped,
        origin: "probe",
        commandRunner: HostWorktreeGitStub(source: captured.workspace.rootPath))
    } else {
      service = try #require(try runtime.makeHostServices(context: captured, origin: "probe"))
    }
  }
  func worktreeReceipt() throws -> [String: JSONValue] {
    let id = UUID().uuidString.lowercased()
    let source = root.resolvingSymlinksInPath()
    let component = SHA256.hash(data: Data("scope".utf8)).prefix(12).map {
      String(format: "%02x", $0)
    }.joined()
    let path = source.appendingPathComponent("managed").appendingPathComponent(component)
      .appendingPathComponent(id)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    return [
      "id": .string(id), "workspace_id": .string("codex-worktree-" + id),
      "source_workspace_id": .string("scope"), "source_repository_root": .string(source.path),
      "git_common_directory": .string(source.appendingPathComponent(".git").path),
      "path": .string(path.path), "branch": .string("fixture-" + id),
      "parent_lease_id": .string("fixture-parent"), "profile_id": .string("chatgpt-operate"),
      "principal_id": .string("fixture-principal"),
      "caller": .string("secure-tunnel"), "state": .string("provisioning"), "revision": .number(2),
    ]
  }
  func during(
    _ method: String, _ arguments: [String: JSONValue] = [:],
    _ body: @escaping @Sendable (MCPBoundHostServices) async throws -> JSONValue
  ) async throws -> JSONValue {
    let service = service
    peer.setHandler { try await body(service) }
    defer { peer.setHandler(nil) }
    var args = arguments
    args["workspace_id"] = .string("scope")
    return try await runtime.callToolAsync(name: "adapter." + method, arguments: .object(args))
  }
  func direct(_ name: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
    try await .encoded(service.call(name: name, arguments: arguments))
  }
  func genericDiagnostics(workspaceID: String?) async throws -> JSONValue {
    let service = service
    peer.setHandler {
      try await .encoded(
        service.call(
          name: "host.diagnostics.snapshot",
          arguments: ["limit": .number(1)]))
    }
    defer { peer.setHandler(nil) }
    var arguments: [String: JSONValue] = [
      "server": .string("probe"), "tool": .string("codex.diagnostics.snapshot"),
      "arguments": .object(["limit": .number(1)]),
    ]
    if let workspaceID { arguments["workspace_id"] = .string(workspaceID) }
    return try await runtime.callToolAsync(name: "mcp.tools.call", arguments: .object(arguments))
  }
  func payload(_ value: JSONValue) -> [String: JSONValue] {
    let downstream = value.objectValue?["structuredContent"]?.objectValue?["result"]
    return downstream?.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue ?? [:]
  }
  func close() async {
    await service.close()
    await runtime.shutdown()
  }
  func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class HostServiceProbe: DownstreamMCPClient, @unchecked Sendable {
  static let methods = [
    "codex.app.thread.start", "codex.app.turn.start", "codex.diagnostics.snapshot",
    "codex.app.thread.release",
    "codex.worktree.provision.perform",
  ]
  private let lock = NSLock()
  private var captured: MCPHostContext?
  private var handler: (@Sendable () async throws -> JSONValue)?
  var context: MCPHostContext? { lock.withLock { captured } }
  func setHandler(_ value: (@Sendable () async throws -> JSONValue)?) {
    lock.withLock { handler = value }
  }
  func makeScopedClient(
    workingDirectory: URL, environment: [String: String], hostContext: MCPHostContext?
  ) -> any DownstreamMCPClient {
    lock.withLock { captured = hostContext }
    return self
  }
  func listTools(server: MCPServerConfig) throws -> [MCPTool] {
    Self.methods.map { .init(name: $0, description: "Fixture", inputSchema: .object([:])) }
  }
  func callTool(server: MCPServerConfig, name: String, arguments: JSONValue) throws -> JSONValue {
    guard let handler = lock.withLock({ handler }) else {
      throw MCPHostServiceError.denied("Fixture handler absent.")
    }
    let box = HostProbeResult()
    let ready = DispatchSemaphore(value: 0)
    let task = Task {
      do { box.set(.success(try await handler())) } catch { box.set(.failure(error)) }
      ready.signal()
    }
    guard ready.wait(timeout: .now() + 10) == .success else {
      task.cancel()
      throw MCPHostServiceError.denied("Fixture callback timed out.")
    }
    return try box.get()
  }
  func listResources(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func listResourceTemplates(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func readResource(server: MCPServerConfig, uri: String) throws -> JSONValue { .null }
  func listPrompts(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func getPrompt(server: MCPServerConfig, name: String, arguments: [String: String]?) throws
    -> JSONValue
  { .null }
}

/// Isolates host invocation lifetime from Git execution; packaged integration tests use real Git.
private struct HostWorktreeGitStub: CommandRunning {
  let source: String
  func run(
    executable: String, arguments: [String], workingDirectory: URL?, environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult {
    let output: String
    switch arguments {
    case ["rev-parse", "--show-toplevel"]: output = try #require(workingDirectory).path
    case ["rev-parse", "--git-common-dir"]: output = source + "/.git"
    default: throw MCPHostServiceError.denied("Unexpected fixture Git command.")
    }
    return .init(
      executable: executable, arguments: arguments, exitCode: 0, timedOut: false,
      stdout: output + "\n", stderr: "", stdoutTruncated: false, stderrTruncated: false)
  }
  func runData(
    executable: String, arguments: [String], workingDirectory: URL?, environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandDataResult {
    throw MCPHostServiceError.denied("Unexpected fixture binary command.")
  }
}
private final class HostProbeResult: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Result<JSONValue, any Error>?
  func set(_ value: Result<JSONValue, any Error>) { lock.withLock { self.value = value } }
  func get() throws -> JSONValue { try lock.withLock { try value!.get() } }
}
