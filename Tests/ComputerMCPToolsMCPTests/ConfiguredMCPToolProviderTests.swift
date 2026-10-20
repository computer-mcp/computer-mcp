import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPToolsMCP

struct ConfiguredMCPToolProviderTests {
  @Test(arguments: ["", "namespace"], [false, true])
  func freshDirectCallsResolveDistinctNamesAcrossSharedPrefixes(
    prefix: String, asynchronous: Bool
  ) async throws {
    let firstName = prefix.isEmpty ? "left" : "child.read"
    let secondPrefix = prefix.isEmpty ? "" : "\(prefix).child"
    let client = ReexportNamingClient(["first": [firstName], "second": ["right"]])
    let provider = ConfiguredMCPToolProvider(
      environment: ToolEnvironment(
        configuration: .fixture(
          mcp: .init(servers: [
            Self.server("second", prefix: secondPrefix), Self.server("first", prefix: prefix),
          ]))), mcpClient: client)
    let exposed = prefix.isEmpty ? firstName : "\(prefix).\(firstName)"
    let secondName = secondPrefix.isEmpty ? "right" : "\(secondPrefix).right"
    func call(_ name: String) async throws -> JSONValue {
      if asynchronous {
        return try await provider.callToolAsync(
          .init(
            name: name, arguments: .object([:]), context: .empty))
      }
      return try provider.callTool(.init(name: name, arguments: .object([:]), context: .empty))
    }
    #expect(try await call(exposed) == .string("first:\(firstName)"))
    #expect(try await call(secondName) == .string("second:right"))
    #expect(client.discoveredServers == ["second", "first"])
    await #expect(throws: GatewayToolError.unknownTool("missing")) { try await call("missing") }
    #expect(client.discoveredServers == ["second", "first"])
  }

  @Test
  func directCallsUseTheMostRecentSuccessfulListing() throws {
    let client = ReexportNamingClient(["first": ["left"], "second": ["right"]])
    let provider = ConfiguredMCPToolProvider(
      environment: ToolEnvironment(
        configuration: .fixture(
          mcp: .init(servers: [Self.server("first", prefix: ""), Self.server("second", prefix: "")])
        )), mcpClient: client)
    _ = try provider.definitions().map(\.tool)
    client.replace("second", names: ["left"])
    #expect(throws: GatewayToolError.invalidArguments("Reexported tool name conflicts: left")) {
      try provider.definitions().map(\.tool)
    }
    let failedDiscoveries = client.discoveredServers.count
    #expect(
      try provider.callTool(.init(name: "right", arguments: .object([:]), context: .empty))
        == .string("second:right"))
    #expect(client.discoveredServers.count == failedDiscoveries)
    client.replace("first", names: [])
    client.replace("second", names: ["fresh"])
    _ = try provider.definitions()
    let successfulDiscoveries = client.discoveredServers.count
    for name in ["left", "right"] {
      #expect(throws: GatewayToolError.unknownTool(name)) {
        try provider.callTool(.init(name: name, arguments: .object([:]), context: .empty))
      }
    }
    #expect(
      try provider.callTool(.init(name: "fresh", arguments: .object([:]), context: .empty))
        == .string("second:fresh"))
    #expect(client.discoveredServers.count == successfulDiscoveries)
  }

  @Test(arguments: ["", "namespace"], ["codex.app.status", "file.read"])
  func explicitPrefixPreservesSchemaAndRegistrationIdentity(prefix: String, name: String) throws {
    let client = ReexportNamingClient(["first": [name]])
    let server = Self.server("first", prefix: prefix)
    let configuration = GatewayConfiguration(mcp: .init(servers: [server]))
    try configuration.validate()
    let decoded = try GatewayConfiguration.load(text: configuration.exportedTOML())
    #expect(decoded.mcp.servers[0].prefix == prefix)
    let provider = ConfiguredMCPToolProvider(
      environment: ToolEnvironment(
        configuration: .fixture(mcp: .init(servers: [server]))), mcpClient: client)
    let exposed = prefix.isEmpty ? name : "\(prefix).\(name)"
    let tool = try #require(provider.definitions().map(\.tool).first { $0.name == exposed })
    let original = try #require(client.listTools(server: server, context: .empty).first)
    #expect(tool.inputSchema == original.inputSchema && tool.outputSchema == original.outputSchema)
    #expect(tool.title == original.title && tool.annotations == original.annotations)
    #expect(tool.mcpReference == .init(serverID: "first", toolName: name))
    #expect(
      try provider.callTool(.init(name: exposed, arguments: .object([:]), context: .empty))
        == .string("first:\(name)"))
  }

  @Test
  func directResolutionUsesListingPermissionsAndVisibility() throws {
    var first = Self.server("first", prefix: "")
    first.allowAnyTool = false
    first.allowedTools = ["inspect"]
    first.toolRisks = ["inspect": .readOnly]
    let configuration = GatewayConfiguration.fixture(
      mcp: .init(servers: [Self.server("second", prefix: ""), first]))
    let base = ReexportNamingClient([
      "first": ["inspect", "blocked"], "second": ["inspect", "hidden"],
    ])
    let client = AuthorizedMCPClient(
      base: base,
      policy: .init(
        configuration: configuration,
        grant: .init(
          id: .chatGPTObserve, capabilityIDs: [], allowedCallers: [.secureTunnel],
          mcpServerIDs: ["first"]), derivesObserveGrant: false))
    let provider = ConfiguredMCPToolProvider(
      environment: ToolEnvironment(configuration: configuration), mcpClient: client)
    #expect(
      try provider.callTool(.init(name: "inspect", arguments: nil, context: .empty))
        == .string("first:inspect"))
    for name in ["blocked", "hidden"] {
      #expect(throws: GatewayToolError.unknownTool(name)) {
        try provider.callTool(.init(name: name, arguments: nil, context: .empty))
      }
    }
    #expect(base.discoveredServers == ["first", "first"])
    #expect(base.calls == ["first:inspect"])
  }

  @Test(arguments: [false, true])
  func directCallsRejectCatalogConflictsLikeListing(asynchronous: Bool) async throws {
    let client = ReexportNamingClient(["first": ["inspect", "mcp.tools.list"]])
    let provider = ConfiguredMCPToolProvider(
      environment: ToolEnvironment(
        configuration: .fixture(mcp: .init(servers: [Self.server("first", prefix: "")]))),
      mcpClient: client)
    let conflict = GatewayToolError.invalidArguments(
      "Reexported tool name conflicts: mcp.tools.list")
    await #expect(throws: conflict) {
      if asynchronous {
        return try await provider.callToolAsync(
          .init(name: "inspect", arguments: nil, context: .empty))
      }
      return try provider.callTool(.init(name: "inspect", arguments: nil, context: .empty))
    }
    #expect(throws: conflict) { try provider.definitions().map(\.tool) }
    #expect(client.calls.isEmpty)
    client.replace("first", names: ["inspect"])
    #expect(
      try provider.callTool(.init(name: "inspect", arguments: nil, context: .empty))
        == .string("first:inspect"))
  }

  @Test
  func asyncCallsValidateTheCatalogBeforeCallingDownstream() async throws {
    let client = ReexportNamingClient(["first": ["inspect", "mcp.tools.list"]])
    let provider = ConfiguredMCPToolProvider(
      environment: ToolEnvironment(
        configuration: .fixture(mcp: .init(servers: [Self.server("first", prefix: "")]))),
      mcpClient: client)
    await #expect(
      throws: GatewayToolError.invalidArguments("Reexported tool name conflicts: mcp.tools.list")
    ) {
      try await provider.callToolAsync(
        .init(name: "inspect", arguments: .object([:]), context: .empty))
    }
    #expect(client.discoveredServers == ["first"])
    #expect(client.calls.isEmpty)
  }

  private static func server(_ id: String, prefix: String) -> MCPServerConfig {
    .init(
      id: id, transport: .stdio, command: "/bin/cat", exposure: .reexport, prefix: prefix,
      allowAnyTool: true)
  }
}

private final class ReexportNamingClient: DownstreamMCPClient, @unchecked Sendable {
  private let lock = NSLock()
  private var names: [String: [String]]
  private var discoveries: [String] = []
  private var invocations: [String] = []
  var discoveredServers: [String] { lock.withLock { discoveries } }
  var calls: [String] { lock.withLock { invocations } }
  init(_ names: [String: [String]]) { self.names = names }
  func replace(_ id: String, names: [String]) { lock.withLock { self.names[id] = names } }
  func makeScopedClient(
    workingDirectory: URL, environment: [String: String], hostContext: (any MCPHostEnvironment)?
  ) -> any DownstreamMCPClient { self }
  func listTools(server: MCPServerConfig, context: InvocationContext) throws -> [MCPTool] {
    let names = lock.withLock {
      discoveries.append(server.id)
      return self.names[server.id] ?? []
    }
    return names.map {
      .init(
        name: $0, title: "Original", description: "Native tool",
        inputSchema: .object(["type": .string("object")]),
        outputSchema: .object(["type": .string("object")]), annotations: .init(readOnlyHint: true))
    }
  }
  func callTool(
    server: MCPServerConfig, name: String, arguments: JSONValue, context: InvocationContext
  ) throws -> JSONValue {
    lock.withLock { invocations.append(server.id + ":" + name) }
    return .string(server.id + ":" + name)
  }
  func listResources(server: MCPServerConfig, cursor: String?, context: InvocationContext) throws
    -> JSONValue
  { .null }
  func listResourceTemplates(server: MCPServerConfig, cursor: String?, context: InvocationContext)
    throws -> JSONValue
  { .null }
  func readResource(server: MCPServerConfig, uri: String, context: InvocationContext) throws
    -> JSONValue
  { .null }
  func listPrompts(server: MCPServerConfig, cursor: String?, context: InvocationContext) throws
    -> JSONValue
  { .null }
  func getPrompt(
    server: MCPServerConfig, name: String, arguments: [String: String]?, context: InvocationContext
  ) throws
    -> JSONValue
  { .null }
}
