import Darwin
import Foundation
import GRDB
import MCP
import Testing

@testable import ComputerMCP

@Suite(.timeLimit(.minutes(1)))
struct MCPHostSessionTests {
  @Test
  func deletingPersistedAuthorityDoesNotRestoreConfiguredHostAccess() async throws {
    let fixture = try HostFixture(fileBacked: true)
    defer { fixture.remove() }
    let catalog = try fixture.runtime.hostToolCatalog(workspaceID: "first", origin: "plugin")
    try #require(catalog.contains { $0.name == "file.read" })
    let path = try #require(fixture.database.fileURL).path
    let writer = try DatabaseQueue(path: path)
    try await writer.write { database in
      try database.execute(sql: "DELETE FROM profiles WHERE id = ?", arguments: ["chatgpt-operate"])
    }
    #expect(try fixture.database.profiles().isEmpty)
    #expect(throws: (any Error).self) {
      try fixture.runtime.hostToolCatalog(workspaceID: "first", origin: "plugin")
    }
    let result = try await fixture.call("file.read", ["path": .string("value.txt")])
    #expect(result.objectValue?["isError"] == .bool(true))
    await fixture.runtime.shutdown()
  }

  @Test
  func ordinaryMCPCallsUseBoundWorkspaceAndOriginalAuditIdentity() async throws {
    let fixture = try HostFixture()
    defer { fixture.remove() }
    let session = try fixture.session()
    let client = MCP.Client(name: "plugin-fixture", version: "1")
    let transport = try MCPInheritedSocketTransport(takingOwnershipOf: session.childHandle)
    do {
      _ = try await client.connect(transport: transport)
      let request: RequestContext<MCP.CallTool.Result> = try await client.callTool(
        name: "file.read", arguments: ["path": .string("value.txt")])
      let result = try await request.value
      #expect(result.isError != true)
      #expect(
        result.structuredContent?.objectValue?["result"]?.objectValue?["content"]
          == .string("first"))
      let audit = try #require(
        try fixture.database.auditEvents().first { $0.capabilityID == "file.read" })
      #expect(audit.workspaceID == "first")
      #expect(audit.profileID == .chatGPTOperate)
      #expect(audit.caller == .secureTunnel)
      #expect(audit.transport == "gateway_socket")
      #expect(audit.socketConnectionID == "original-socket")
      #expect(audit.requestID.hasPrefix("host:"))
      let listed = try await fixture.call("workspace.list")
      #expect(fixture.payload(listed)["workspaces"]?.arrayValue?.count == 1)
      let rejected = try await fixture.call(
        "file.read", ["workspace_id": .string("second"), "path": .string("value.txt")])
      #expect(rejected.objectValue?["isError"] == .bool(true))
      #expect(
        try fixture.database.auditEvents().contains { $0.errorCode == "policy.workspace_denied" })
      await client.disconnect()
      await session.close()
      await fixture.runtime.shutdown()
    } catch {
      await transport.disconnect()
      await client.disconnect()
      await session.close()
      await fixture.runtime.shutdown()
      throw error
    }
  }

  @Test(arguments: [
    "alias.callback", "loop.operation", "mcp.tools.call", "policy.probe", "operations.prepare",
    "nested-workspace",
  ])
  func indirectCallsCannotReenterTheOriginOrWidenWorkspace(route: String) async throws {
    let fixture = try HostFixture()
    defer { fixture.remove() }
    var name = route
    var arguments: [String: JSONValue] = [:]
    if route == "mcp.tools.call" {
      arguments = ["server": .string("plugin"), "tool": .string("operation")]
    } else if route == "policy.probe" {
      arguments = ["capability_id": .string("alias.callback"), "arguments": .object([:])]
    } else if route == "operations.prepare" {
      arguments = ["tool": .string("alias.callback"), "arguments": .object([:])]
    } else if route == "nested-workspace" {
      name = "policy.probe"
      arguments = [
        "capability_id": .string("file.read"),
        "arguments": .object([
          "workspace_id": .string("second"), "path": .string("value.txt"),
        ]),
      ]
    }
    let result = try await fixture.call(name, arguments)
    #expect(result.objectValue?["isError"] == .bool(true))
    #expect(fixture.downstream.invocations == 0)
    #expect(try fixture.database.auditEvents().count == 1)
    await fixture.runtime.shutdown()
  }

  @Test
  func destructiveCallsKeepSingleUseTicketsAndLinkedAuditReceipts() async throws {
    let fixture = try HostFixture()
    defer { fixture.remove() }
    let target: JSONValue = .object([
      "path": .string("value.txt"), "search": .string("first"), "replacement": .string("updated"),
      "expected_replacements": .number(1), "dry_run": .bool(false),
    ])
    let direct = try await fixture.call("file.replace_text", target.objectValue!)
    #expect(direct.objectValue?["isError"] == .bool(true))
    let prepared = try await fixture.call(
      "operations.prepare", ["tool": .string("file.replace_text"), "arguments": target])
    let ticket = try #require(fixture.payload(prepared)["ticket_id"]?.stringValue)
    let arguments: [String: JSONValue] = [
      "tool": .string("file.replace_text"), "arguments": target, "ticket_id": .string(ticket),
    ]
    let committed = try await fixture.call("operations.commit", arguments)
    #expect(committed.objectValue?["isError"] == .bool(false))
    #expect(
      try String(contentsOf: fixture.first.appendingPathComponent("value.txt"), encoding: .utf8)
        == "updated")
    let repeated = try await fixture.call("operations.commit", arguments)
    #expect(repeated.objectValue?["isError"] == .bool(true))
    let record = try #require(try fixture.database.operationTicket(id: ticket))
    #expect(record.state == .succeeded)
    let audit = try #require(
      try fixture.database.auditEvents().first {
        $0.capabilityID == "file.replace_text" && $0.ticketID == ticket && $0.decision == .allowed
      })
    #expect(audit.invocationID == record.invocationID)
    #expect(audit.parentRequestID == record.parentRequestID)
    #expect(audit.socketConnectionID == "original-socket")
    await fixture.runtime.shutdown()
  }

  @Test(arguments: ["observe", "grant-revoked", "workspace-removed", "shutdown"])
  func liveScopeAndReadOnlyDenialsRemainAuthoritative(reason: String) async throws {
    let fixture = try HostFixture(observe: reason == "observe")
    defer { fixture.remove() }
    if reason == "grant-revoked" {
      var grant = fixture.grant
      grant.workspaceIDs.removeAll()
      try fixture.database.saveProfile(grant)
    } else if reason == "workspace-removed" {
      try fixture.database.deleteWorkspace(id: "first")
    } else if reason == "shutdown" {
      await fixture.runtime.shutdown()
    }
    let name = reason == "observe" ? "file.replace_text" : "file.read"
    let result = try await fixture.call(name, ["path": .string("value.txt")])
    #expect(result.objectValue?["isError"] == .bool(true))
    #expect(
      try String(contentsOf: fixture.first.appendingPathComponent("value.txt"), encoding: .utf8)
        == "first")
    await fixture.runtime.shutdown()
  }

  @Test
  func revokedWorkspaceGrantRemovesTheCallbackCatalog() async throws {
    let fixture = try HostFixture()
    defer { fixture.remove() }
    #expect(
      try fixture.runtime.hostToolCatalog(workspaceID: "first", origin: "plugin").contains {
        $0.name == "file.read"
      })
    var grant = fixture.grant
    grant.workspaceIDs.removeAll()
    try fixture.database.saveProfile(grant)
    #expect(try fixture.runtime.hostToolCatalog(workspaceID: "first", origin: "plugin").isEmpty)
    await fixture.runtime.shutdown()
  }

  @Test
  func hostDelegationIsExplicitAndSurvivesConfigurationRoundTrip() throws {
    let disabled = MCPServerConfig(id: "plugin", transport: .stdio, command: "/bin/cat")
    #expect(!disabled.hostServices)
    var enabled = disabled
    enabled.hostServices = true
    let config = GatewayConfiguration(mcp: .init(servers: [enabled]))
    let restored = try GatewayConfiguration.load(text: config.exportedTOML())
    #expect(restored.mcp.servers.first?.hostServices == true)
    let settings = PluginMCPSettings(hostServices: true)
    #expect(
      try JSONDecoder().decode(PluginMCPSettings.self, from: JSONEncoder().encode(settings))
        .hostServices)
    let environment = try MCPHostContext.launchEnvironment(
      inherited: ["COMPUTER_MCP_HOST_FD": "8"], overrides: ["COMPUTER_MCP_HOST_FD": "9"],
      context: nil)
    #expect(environment["COMPUTER_MCP_HOST_FD"] == nil)
    let remote = GatewayConfiguration(
      mcp: .init(servers: [
        .init(
          id: "remote", transport: .streamableHTTP, url: "https://example.invalid/mcp",
          hostServices: true)
      ]))
    #expect(throws: (any Error).self) { try remote.validate() }
  }

  @Test
  func inheritedDescriptorReachesOnlyTheOwnedCommandAndParentCopyCanCloseImmediately() async throws
  {
    let pair = try MCPInheritedSocketTransport.makePair()
    let transport = try MCPInheritedSocketTransport(takingOwnershipOf: pair.0)
    let source =
      "import os,socket; s=socket.socket(fileno=3); s.sendall(b'owned-child\\n'); s.close(); print('completed',flush=True)"
    let process = try ManagedLineProcess(
      configuration: .init(
        executable: "/usr/bin/python3", arguments: ["-c", source], environment: [:],
        workingDirectory: FileManager.default.temporaryDirectory, inheritedDescriptors: [3: pair.1])
    )
    try pair.1.close()
    do {
      try await transport.connect()
      var received = await transport.receive().makeAsyncIterator()
      #expect(try await received.next() == Data("owned-child".utf8))
      // EOF would not arrive here if the supervisor/watchdog retained the child endpoint.
      #expect(try await received.next() == nil)
      var lines = process.inboundLines.makeAsyncIterator()
      #expect(try await lines.next() == "completed")
      await process.close()
      #expect(await process.snapshot().hasExited)
      await transport.disconnect()
    } catch {
      await transport.disconnect()
      await process.close()
      throw error
    }
  }
}

private final class HostFixture: Sendable {
  let root: URL
  let first: URL
  let database: GatewayDatabase
  let runtime: GatewayRuntime
  let grant: ProfileGrant
  let downstream = HostCatalogClient()
  let context: ExecutionContext
  let registration: MCPServerConfig

  init(observe: Bool = false, fileBacked: Bool = false) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "host-fixture-" + UUID().uuidString)
    first = root.appendingPathComponent("first")
    let second = root.appendingPathComponent("second")
    for directory in [first, second] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try directory.lastPathComponent.write(
        to: directory.appendingPathComponent("value.txt"), atomically: true, encoding: .utf8)
    }
    database =
      try fileBacked
      ? GatewayDatabase(path: root.appendingPathComponent("gateway.sqlite").path)
      : GatewayDatabase(inMemory: ())
    let workspaces = [first, second].map {
      RegisteredWorkspace(
        id: $0.lastPathComponent, displayName: $0.lastPathComponent, rootPath: $0.path)
    }
    for workspace in workspaces { try database.saveWorkspace(workspace) }
    let profile: GatewayProfileID = observe ? .chatGPTObserve : .chatGPTOperate
    let capabilities = [
      "workspace.list", "workspace.describe", "policy.probe", "operations.prepare",
      "operations.commit", "file.read", "file.replace_text", "mcp.tools.call", "alias.callback",
      "loop.operation",
    ]
    grant = ProfileGrant(
      id: profile, capabilityIDs: Set(capabilities), workspaceIDs: ["first", "second"],
      allowedCallers: [.secureTunnel])
    try database.saveProfile(grant)
    context = ExecutionContext(
      caller: .secureTunnel, profileID: profile,
      transportTrace: .init(transport: "gateway_socket", socketConnectionID: "original-socket"))
    registration = MCPServerConfig(
      id: "plugin", transport: .stdio, command: "/bin/cat", exposure: .reexport,
      prefix: "loop", allowedTools: ["operation"], toolRisks: ["operation": .readOnly],
      hostServices: true)
    runtime = try GatewayRuntime(
      configuration: .init(
        runtime: .init(caller: .secureTunnel, profileID: profile),
        profiles: [
          .init(
            id: profile, capabilities: capabilities, workspaces: ["first", "second"],
            allowedCallers: [.secureTunnel])
        ],
        mcp: .init(servers: [registration]),
        tools: [.init(name: "alias.callback", adapter: .mcp, source: "plugin", tool: "operation")],
        builtin: .init(enabled: ["file.read", "file.replace_text"])),
      context: context, database: database, registeredWorkspaces: workspaces, mcpClient: downstream)
  }

  func session() throws -> MCPHostSession {
    let directory = MCPHostToolDirectory()
    directory.attach(runtime)
    return try MCPHostSession(
      context: .init(
        runtimeID: UUID(), context: context, workspaceID: "first", rootURL: first,
        readOnly: false, tools: directory), server: registration)
  }
  func call(_ name: String, _ arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
    try await runtime.callHostTool(
      name: name, arguments: arguments, workspaceID: "first", origin: "plugin",
      requestID: UUID().uuidString)
  }
  func payload(_ value: JSONValue) -> [String: JSONValue] {
    value.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue ?? [:]
  }
  func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class HostCatalogClient: DownstreamMCPClient, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var invocations: Int { lock.withLock { count } }
  func makeScopedClient(
    workingDirectory: URL, environment: [String: String], hostContext: MCPHostContext?
  ) -> any DownstreamMCPClient { self }
  func listTools(server: MCPServerConfig) throws -> [MCPTool] {
    [.init(name: "operation", description: "Fixture", inputSchema: .object([:]))]
  }
  func callTool(server: MCPServerConfig, name: String, arguments: JSONValue) throws -> JSONValue {
    lock.withLock { count += 1 }
    return .null
  }
  func listResources(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func listResourceTemplates(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func readResource(server: MCPServerConfig, uri: String) throws -> JSONValue { .null }
  func listPrompts(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func getPrompt(server: MCPServerConfig, name: String, arguments: [String: String]?) throws
    -> JSONValue
  { .null }
}
