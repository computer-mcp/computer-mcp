import Foundation
import Testing

@testable import ComputerMCP

struct MCPReexportNamingTests {
  @Test(arguments: ["", "namespace"])
  func explicitPrefixPreservesSchemaAndRegistrationIdentity(prefix: String) throws {
    let client = ReexportNamingClient(["first": ["codex.app.status"]])
    let server = Self.server("first", prefix: prefix)
    let configuration = GatewayConfiguration(mcp: .init(servers: [server]))
    try configuration.validate()
    let decoded = try GatewayConfiguration.load(text: configuration.exportedTOML())
    #expect(decoded.mcp.servers[0].prefix == prefix)
    let registry = GatewayToolRegistry(
      configuration: .fixture(mcp: .init(servers: [server])), mcpClient: client)
    let exposed = prefix.isEmpty ? "codex.app.status" : "namespace.codex.app.status"
    let tool = try #require(registry.listTools().first { $0.name == exposed })
    let original = try #require(client.listTools(server: server).first)
    #expect(tool.inputSchema == original.inputSchema && tool.outputSchema == original.outputSchema)
    #expect(tool.title == original.title && tool.annotations == original.annotations)
    #expect(tool.mcpReference == .init(serverID: "first", toolName: "codex.app.status"))
    #expect(
      try registry.callTool(name: exposed, arguments: .object([:]))
        == .string("first:codex.app.status"))
  }

  @Test
  func explicitNativeCapabilityEnablesDiscoveryWithoutGenericPermission() throws {
    var server = Self.server("first", prefix: "")
    server.toolRisks = ["codex.app.status": .readOnly]
    let configuration = GatewayConfiguration(mcp: .init(servers: [server]))
    let policy = MCPToolAccessPolicy(
      configuration: configuration,
      grant: .init(
        id: .chatGPTOperate, capabilityIDs: ["codex.app.status"], allowedCallers: [.secureTunnel]),
      derivesObserveGrant: false)
    #expect(policy.canDiscoverTools(on: server))
    #expect(policy.allows(.init(serverID: "first", toolName: "codex.app.status")))
    #expect(!policy.allows(.init(serverID: "first", toolName: "ungranted")))
    let client = AuthorizedMCPClient(
      base: ReexportNamingClient(["first": ["codex.app.status", "ungranted"]]), policy: policy)
    #expect(try client.listTools(server: server).map(\.name) == ["codex.app.status"])
  }

  @Test
  func nativeNamesDoNotExpandSelectionRiskOrAnotherRegistrationGrant() throws {
    var first = Self.server("first", prefix: "")
    first.allowAnyTool = false
    first.allowedTools = ["read", "write"]
    first.toolRisks = ["read": .readOnly]
    let second = Self.server("second", prefix: "")
    let policy = MCPToolAccessPolicy(
      configuration: .init(mcp: .init(servers: [first, second])),
      grant: .init(
        id: .chatGPTObserve, capabilityIDs: [], allowedCallers: [.secureTunnel],
        mcpServerIDs: ["first"]), derivesObserveGrant: false)
    #expect(policy.allows(.init(serverID: "first", toolName: "read")))
    #expect(!policy.allows(.init(serverID: "first", toolName: "write")))
    #expect(!policy.allows(.init(serverID: "first", toolName: "unselected")))
    #expect(!policy.allows(.init(serverID: "second", toolName: "read")))
  }

  @Test
  func duplicateNativeNamesFailRatherThanOverwritingAndRefreshCanRecover() async throws {
    let client = ReexportNamingClient(["first": ["left"], "second": ["right"]])
    let configuration = GatewayConfiguration.fixture(
      mcp: .init(servers: [Self.server("first", prefix: ""), Self.server("second", prefix: "")]))
    try configuration.validate()
    let registry = GatewayToolRegistry(configuration: configuration, mcpClient: client)
    let router = try GatewayProviderRouter(registry: registry)
    do {
      #expect(try router.callTool(name: "left", arguments: nil) == .string("first:left"))
      client.replace("second", names: ["left"])
      await #expect(throws: (any Error).self) { try await router.refreshTools() }
      #expect(try router.callTool(name: "left", arguments: nil) == .string("first:left"))
      #expect(try router.listTools().contains { $0.name == "right" })
      client.replace("second", names: ["fresh"])
      try await router.refreshTools()
      #expect(try router.callTool(name: "fresh", arguments: nil) == .string("second:fresh"))
      #expect(try !router.listTools().contains { $0.name == "right" })
      await router.shutdown()
    } catch {
      await router.shutdown()
      throw error
    }
  }

  @Test
  func nativeNamesCannotShadowBuiltins() throws {
    let configuration = GatewayConfiguration.fixture(
      mcp: .init(servers: [Self.server("first", prefix: "")]))
    let registry = GatewayToolRegistry(
      configuration: configuration, mcpClient: ReexportNamingClient(["first": ["cli.list"]]))
    #expect(throws: (any Error).self) { _ = try registry.listTools() }
  }

  @Test(arguments: [
    "workspace.list", "workspace.describe", "policy.probe", "operations.prepare",
    "operations.commit",
  ])
  func nativeToolsCannotReplaceHostManagementTools(name: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = GatewayConfiguration(
      mcp: .init(servers: [Self.server("first", prefix: "")]))
    #expect(throws: GatewayProviderRouterError.duplicateTool(name)) {
      _ = try GatewayRuntime(
        configuration: configuration,
        registeredWorkspaces: [.init(id: "fixture", displayName: "Fixture", rootPath: root.path)],
        mcpClient: ReexportNamingClient(["first": [name]]))
    }
  }

  @Test
  func reservedCoreNameDuringRefreshDoesNotReplaceTheValidatedCatalog() async throws {
    let client = ReexportNamingClient(["first": ["available"]])
    let registry = GatewayToolRegistry(
      configuration: .fixture(mcp: .init(servers: [Self.server("first", prefix: "")])),
      mcpClient: client)
    let router = try GatewayProviderRouter(
      registry: registry, additionalProviders: [], reservedToolNames: ["workspace.list"])
    do {
      client.replace("first", names: ["workspace.list"])
      await #expect(throws: GatewayProviderRouterError.duplicateTool("workspace.list")) {
        try await router.refreshTools()
      }
      #expect(try router.listTools().contains { $0.name == "available" })
      #expect(try !router.listTools().contains { $0.name == "workspace.list" })
      client.replace("first", names: ["recovered"])
      try await router.refreshTools()
      #expect(try router.callTool(name: "recovered", arguments: nil) == .string("first:recovered"))
      await router.shutdown()
    } catch {
      await router.shutdown()
      throw error
    }
  }

  @Test
  func nativeCodexRemovalHintAgreesWithItsHostAssignedDestructiveRisk() throws {
    let entry = try #require(
      CodexEmbeddedFixture.catalog().first {
        $0.objectValue?["tool"]?.objectValue?["name"] == .string("codex.worktree.remove.perform")
      })
    #expect(
      entry.objectValue?["tool"]?.objectValue?["annotations"]?.objectValue?["destructiveHint"]
        == .bool(true))
    #expect(entry.objectValue?["capability"]?.objectValue?["risk"] == .string("destructive"))
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
  init(_ names: [String: [String]]) { self.names = names }
  func replace(_ id: String, names: [String]) { lock.withLock { self.names[id] = names } }
  func makeScopedClient(
    workingDirectory: URL, environment: [String: String], hostContext: MCPHostContext?
  ) -> any DownstreamMCPClient { self }
  func listTools(server: MCPServerConfig) throws -> [MCPTool] {
    lock.withLock { names[server.id] ?? [] }.map {
      .init(
        name: $0, title: "Original", description: "Native tool",
        inputSchema: .object(["type": .string("object")]),
        outputSchema: .object(["type": .string("object")]), annotations: .init(readOnlyHint: true))
    }
  }
  func callTool(server: MCPServerConfig, name: String, arguments: JSONValue) throws -> JSONValue {
    .string(server.id + ":" + name)
  }
  func listResources(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func listResourceTemplates(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func readResource(server: MCPServerConfig, uri: String) throws -> JSONValue { .null }
  func listPrompts(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func getPrompt(server: MCPServerConfig, name: String, arguments: [String: String]?) throws
    -> JSONValue
  { .null }
}
