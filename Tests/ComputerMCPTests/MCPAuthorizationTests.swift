import Foundation
import Testing
import os

@testable import ComputerMCP

struct MCPAuthorizationTests {
  @Test
  func genericCallsUseTheSameHostRiskAndOperationTickets() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let server = MCPServerConfig(
      id: "remote", transport: .stdio, command: "/bin/cat", exposure: .reexport,
      prefix: "remote", allowedTools: ["inspect"], toolRisks: ["inspect": .destructive])
    let database = try GatewayDatabase(inMemory: ())
    let client = CatalogClient()
    let runtime = try GatewayRuntime(
      configuration: GatewayConfiguration(
        runtime: .init(caller: .localMCP, profileID: .localAdmin),
        mcp: .init(servers: [server])), database: database,
      registeredWorkspaces: [.init(id: "fixture", displayName: "Fixture", rootPath: root.path)],
      mcpClient: client)
    let arguments: JSONValue = .object([
      "server": .string("remote"), "tool": .string("inspect"), "arguments": .object([:]),
    ])
    expectThrows(try runtime.callTool(name: "mcp.tools.call", arguments: arguments)) { error in
      #expect(error.localizedDescription.contains("operations.approval_required"))
    }
    expectThrows(try runtime.callTool(name: "remote.inspect", arguments: .object([:]))) { error in
      #expect(error.localizedDescription.contains("operations.approval_required"))
    }
    for name in ["mcp.tools.call", "remote.inspect"] {
      await #expect(throws: (any Error).self) {
        try await runtime.callToolAsync(
          name: name, arguments: name == "mcp.tools.call" ? arguments : .object([:]))
      }
    }
    let prepared = try runtime.callTool(
      name: "operations.prepare",
      arguments: .object(["tool": .string("mcp.tools.call"), "arguments": arguments]))
    let ticket = try #require(
      prepared.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue?["ticket_id"]?
        .stringValue)
    #expect(try database.operationTicket(id: ticket)?.state == .pendingApproval)
    #expect(throws: (any Error).self) {
      try runtime.callTool(
        name: "operations.commit",
        arguments: .object([
          "ticket_id": .string(ticket), "tool": .string("mcp.tools.call"), "arguments": arguments,
        ]))
    }
    #expect(client.callCount == 0)
    try database.resolveOperationApproval(id: ticket, approved: true, resolver: .localCLI)
    _ = try runtime.callTool(
      name: "operations.commit",
      arguments: .object([
        "ticket_id": .string(ticket), "tool": .string("mcp.tools.call"), "arguments": arguments,
      ]))
    #expect(client.callCount == 1)
    await runtime.shutdown()
  }

  @Test(arguments: [false, true])
  func defaultObserveGrantUsesHostClassification(hostReadOnly: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let server = MCPServerConfig(
      id: "remote", transport: .stdio, command: "/bin/cat", exposure: .reexport,
      prefix: "remote", allowedTools: ["inspect"],
      toolRisks: hostReadOnly ? ["inspect": .readOnly] : [:])
    let runtime = try GatewayRuntime(
      configuration: GatewayConfiguration(
        runtime: .init(caller: .secureTunnel, profileID: .chatGPTObserve),
        mcp: .init(servers: [server])),
      registeredWorkspaces: [.init(id: "fixture", displayName: "Fixture", rootPath: root.path)],
      mcpClient: CatalogClient())
    #expect(try runtime.listTools().contains { $0.name == "remote.inspect" } == hostReadOnly)
    if !hostReadOnly {
      #expect(throws: (any Error).self) {
        try runtime.callTool(name: "remote.inspect", arguments: .object([:]))
      }
      await #expect(throws: (any Error).self) {
        try await runtime.callToolAsync(name: "remote.inspect", arguments: .object([:]))
      }
    } else {
      _ = try await runtime.callToolAsync(name: "remote.inspect", arguments: .object([:]))
    }
    await runtime.shutdown()
  }

  @Test
  func reexportRiskComesFromHostRatherThanAnnotationsOrName() throws {
    let client = CatalogClient()
    let server = MCPServerConfig(
      id: "remote", transport: .stdio, command: "/bin/cat",
      exposure: .reexport, prefix: "mcp", allowedTools: ["inspect"])
    let registry = GatewayToolRegistry(
      configuration: .fixture(mcp: .init(servers: [server])), mcpClient: client)
    let router = try GatewayProviderRouter(registry: registry)
    let definition = try #require(router.listTools().first { $0.name == "mcp.inspect" })
    #expect(definition.annotations?.readOnlyHint == true)
    #expect(definition.json.objectValue?["mcpReference"] == nil)
    let capability = try router.capability(named: "mcp.inspect")
    #expect(capability.risk == .externalWrite)
    #expect(capability.mcpReference == .init(serverID: "remote", toolName: "inspect"))
  }

  @Test
  func hostRiskAppliesToAliasesAndReexports() throws {
    let server = MCPServerConfig(
      id: "remote", transport: .stdio, command: "/bin/cat", exposure: .reexport,
      prefix: "remote", allowedTools: ["inspect"], toolRisks: ["inspect": .readOnly])
    let registry = GatewayToolRegistry(
      configuration: .fixture(
        mcp: .init(servers: [server]),
        tools: [.init(name: "alias.inspect", adapter: .mcp, source: "remote", tool: "inspect")]),
      mcpClient: CatalogClient())
    let router = try GatewayProviderRouter(registry: registry)
    #expect(try router.capability(named: "remote.inspect").risk == .readOnly)
    #expect(try router.capability(named: "alias.inspect").risk == .readOnly)
  }

  @Test
  func emptySelectionDeniesAliasesAndGenericCalls() throws {
    let registry = GatewayToolRegistry(
      configuration: .fixture(
        mcp: .init(servers: [MCPServerConfig(id: "remote", transport: .stdio, command: "/bin/cat")]
        ),
        tools: [.init(name: "alias.inspect", adapter: .mcp, source: "remote", tool: "inspect")]),
      mcpClient: CatalogClient())
    #expect(try !registry.listTools().contains { $0.name == "alias.inspect" })
    #expect(throws: (any Error).self) {
      try registry.callTool(name: "alias.inspect", arguments: .object([:]))
    }
    #expect(throws: (any Error).self) {
      try registry.callTool(
        name: "mcp.tools.call",
        arguments: .object(["server": .string("remote"), "tool": .string("inspect")]))
    }
  }

  @Test
  func overlappingPrefixesRouteToTheDiscoveredServer() throws {
    let client = CatalogClient()
    let servers = [
      MCPServerConfig(
        id: "first", transport: .stdio, command: "/bin/cat",
        exposure: .reexport, prefix: "shared", allowAnyTool: true),
      MCPServerConfig(
        id: "second", transport: .stdio, command: "/bin/cat",
        exposure: .reexport, prefix: "shared.nested", allowAnyTool: true),
    ]
    let registry = GatewayToolRegistry(
      configuration: .fixture(mcp: .init(servers: servers)), mcpClient: client)
    let router = try GatewayProviderRouter(registry: registry)
    for serving in [registry.callTool(name:arguments:), router.callTool(name:arguments:)] {
      let result = try serving("shared.nested.inspect", .object([:]))
      #expect(result == .string("second:inspect"))
    }
  }

  @Test(arguments: [GatewayProfileID.chatGPTObserve, .cloudflareObserve, .chatGPTOperate])
  func readOnlyModeRejectsWriteRiskEvenWithWildcardGrant(profileID: GatewayProfileID) {
    let caller: GatewayCallerKind = profileID == .chatGPTObserve ? .secureTunnel : .cloudflareTunnel
    let grant = ProfileGrant(
      id: profileID, capabilityIDs: ["*"], allowedCallers: [caller], mode: .readOnly)
    let decision = GatewayPolicyEvaluator().evaluate(
      capability: .init(id: "remote.inspect", risk: .externalWrite),
      context: .init(caller: caller, profileID: profileID), grant: grant,
      registeredWorkspaceIDs: [])
    #expect(
      decision
        == .deny(
          code: .readOnlyProfile,
          message: "Read-only mode requires a host-classified read-only capability."))
  }

  @Test
  func decodesImplicitMappingApprovalAndExportsAnExplicitSelection() throws {
    let configuration = try GatewayConfiguration.load(
      text: Self.mappingConfiguration(selection: ""))
    #expect(configuration.mcp.servers.first?.allowedTools == ["inspect"])
    let exported = try configuration.exportedTOML()
    let reloaded = try GatewayConfiguration.load(text: exported)
    #expect(reloaded == configuration)
  }

  @Test
  func explicitEmptySelectionIsNotExpandedByAMapping() throws {
    let configuration = try GatewayConfiguration.load(
      text: Self.mappingConfiguration(selection: "allowed_tools = []"))
    #expect(configuration.mcp.servers.first?.allowedTools == [])
  }

  @Test
  func rejectsConflictingHostRiskDeclarations() throws {
    var configuration = try GatewayConfiguration.load(
      text: Self.mappingConfiguration(selection: ""))
    configuration.mcp.servers[0].toolRisks = ["inspect": .readOnly]
    configuration.tools[0].risk = "destructive"
    #expect(throws: (any Error).self) { try configuration.validate() }
  }

  @Test
  func rejectsAllWithANonemptyAllowlist() {
    let configuration = GatewayConfiguration(
      mcp: .init(servers: [
        .init(
          id: "remote", transport: .stdio, command: "/bin/cat", allowedTools: ["inspect"],
          allowAnyTool: true)
      ]))
    #expect(throws: (any Error).self) { try configuration.validate() }
  }

  private static func mappingConfiguration(selection: String) -> String {
    """
    schema_version = 1
    [[mcp.servers]]
    id = "remote"
    transport = "stdio"
    command = "/bin/cat"
    \(selection)
    [[tools]]
    name = "alias.inspect"
    adapter = "mcp"
    source = "remote"
    tool = "inspect"
    """
  }
}

private struct CatalogClient: DownstreamMCPClient {
  private let calls = OSAllocatedUnfairLock(initialState: 0)
  var callCount: Int { calls.withLock { $0 } }
  func makeScopedClient(
    workingDirectory: URL, environment: [String: String], hostContext: MCPHostContext?
  )
    -> any DownstreamMCPClient
  { self }

  func listTools(server: MCPServerConfig) throws -> [MCPTool] {
    [
      MCPTool(
        name: "inspect", description: "Claims read-only", inputSchema: .object([:]),
        annotations: .init(readOnlyHint: true, destructiveHint: false))
    ]
  }

  func callTool(server: MCPServerConfig, name: String, arguments: JSONValue) throws -> JSONValue {
    calls.withLock { $0 += 1 }
    return .string("\(server.id):\(name)")
  }

  func listResources(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func listResourceTemplates(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func readResource(server: MCPServerConfig, uri: String) throws -> JSONValue { .null }
  func listPrompts(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func getPrompt(server: MCPServerConfig, name: String, arguments: [String: String]?) throws
    -> JSONValue
  { .null }
}
