import ComputerMCPDownstream
import ComputerMCPMacOS
import ComputerMCPTestSupport
import ComputerMCPToolKit
import ComputerMCPToolsCLI
import ComputerMCPToolsGit
import ComputerMCPToolsShell
import Foundation
import Testing

@testable import ComputerMCP
@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore

struct MCPReexportNamingTests {
  @Test(arguments: ["", "namespace"], [false, true])
  func freshDirectCallsResolveDistinctNamesAcrossSharedPrefixes(
    prefix: String, asynchronous: Bool
  ) async throws {
    let firstName = prefix.isEmpty ? "left" : "child.read"
    let secondPrefix = prefix.isEmpty ? "" : "\(prefix).child"
    let client = ReexportNamingClient(["first": [firstName], "second": ["right"]])
    let registry = GatewayToolRegistry(
      configuration: .fixture(
        mcp: .init(servers: [
          Self.server("second", prefix: secondPrefix), Self.server("first", prefix: prefix),
        ])),
      mcpClient: client)
    let exposed = prefix.isEmpty ? firstName : "\(prefix).\(firstName)"
    let secondName = secondPrefix.isEmpty ? "right" : "\(secondPrefix).right"
    func call(_ name: String) async throws -> JSONValue {
      if asynchronous {
        return try await registry.callToolAsync(
          name: name, arguments: .object([:]), context: .empty)
      }
      return try registry.callTool(name: name, arguments: .object([:]), context: .empty)
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
    let registry = GatewayToolRegistry(
      configuration: .fixture(
        mcp: .init(servers: [Self.server("first", prefix: ""), Self.server("second", prefix: "")])),
      mcpClient: client)
    _ = try registry.listTools(context: .empty)
    client.replace("second", names: ["left"])
    #expect(throws: GatewayToolError.invalidArguments("Reexported tool name conflicts: left")) {
      try registry.listTools(context: .empty)
    }
    let failedDiscoveries = client.discoveredServers.count
    #expect(
      try registry.callTool(name: "right", arguments: .object([:]), context: .empty)
        == .string("second:right"))
    #expect(client.discoveredServers.count == failedDiscoveries)
    client.replace("first", names: [])
    client.replace("second", names: ["fresh"])
    _ = try registry.definitions(context: .empty)
    let successfulDiscoveries = client.discoveredServers.count
    for name in ["left", "right"] {
      #expect(throws: GatewayToolError.unknownTool(name)) {
        try registry.callTool(name: name, arguments: .object([:]), context: .empty)
      }
    }
    #expect(
      try registry.callTool(name: "fresh", arguments: .object([:]), context: .empty)
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
    let registry = GatewayToolRegistry(
      configuration: .fixture(mcp: .init(servers: [server])), mcpClient: client)
    let exposed = prefix.isEmpty ? name : "\(prefix).\(name)"
    let tool = try #require(registry.listTools(context: .empty).first { $0.name == exposed })
    let original = try #require(client.listTools(server: server, context: .empty).first)
    #expect(tool.inputSchema == original.inputSchema && tool.outputSchema == original.outputSchema)
    #expect(tool.title == original.title && tool.annotations == original.annotations)
    #expect(tool.mcpReference == .init(serverID: "first", toolName: name))
    #expect(
      try registry.callTool(name: exposed, arguments: .object([:]), context: .empty)
        == .string("first:\(name)"))
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
    #expect(
      try client.listTools(server: server, context: .empty).map(\.name) == ["codex.app.status"])
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
    let registry = GatewayToolRegistry(configuration: configuration, mcpClient: client)
    #expect(
      try registry.callTool(name: "inspect", arguments: nil, context: .empty)
        == .string("first:inspect"))
    for name in ["blocked", "hidden"] {
      #expect(throws: GatewayToolError.unknownTool(name)) {
        try registry.callTool(name: name, arguments: nil, context: .empty)
      }
    }
    #expect(base.discoveredServers == ["first", "first"])
    #expect(base.calls == ["first:inspect"])
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
      #expect(
        try router.callTool(name: "left", arguments: nil, context: .empty) == .string("first:left"))
      client.replace("second", names: ["left"])
      await #expect(throws: (any Error).self) { try await router.refreshTools(context: .empty) }
      #expect(
        try router.callTool(name: "left", arguments: nil, context: .empty) == .string("first:left"))
      #expect(try router.listTools(context: .empty).contains { $0.name == "right" })
      client.replace("second", names: ["fresh"])
      try await router.refreshTools(context: .empty)
      #expect(
        try router.callTool(name: "fresh", arguments: nil, context: .empty)
          == .string("second:fresh"))
      #expect(try !router.listTools(context: .empty).contains { $0.name == "right" })
      await router.shutdown()
    } catch {
      await router.shutdown()
      throw error
    }
  }

  @Test(arguments: ["cli.list", "git.status", "shell.run", "process.list"])
  func nativeNamesCannotShadowBuiltins(name: String) throws {
    let configuration = GatewayConfiguration.fixture(
      mcp: .init(servers: [Self.server("first", prefix: "")]),
      policy: .init(shellEnabled: true), builtin: .init(enabled: ["git.status"]))
    let environment = ToolEnvironment(configuration: configuration)
    let registry = GatewayToolRegistry(
      toolEnvironment: environment, mcpClient: ReexportNamingClient(["first": [name]]))
    #expect(throws: (any Error).self) {
      _ = try GatewayProviderRouter(
        registry: registry,
        additionalProviders: {
          [
            CLIToolProvider(environment: environment), GitToolProvider(environment: environment),
            ShellToolProvider(environment: environment),
            ProcessToolProvider(environment: environment),
          ]
        })
    }
  }

  @Test(arguments: [false, true])
  func directCallsRejectCatalogConflictsLikeListing(asynchronous: Bool) async throws {
    let client = ReexportNamingClient(["first": ["inspect", "mcp.tools.list"]])
    let registry = GatewayToolRegistry(
      configuration: .fixture(mcp: .init(servers: [Self.server("first", prefix: "")])),
      mcpClient: client)
    let conflict = GatewayToolError.invalidArguments(
      "Reexported tool name conflicts: mcp.tools.list")
    await #expect(throws: conflict) {
      if asynchronous {
        return try await registry.callToolAsync(name: "inspect", arguments: nil, context: .empty)
      }
      return try registry.callTool(name: "inspect", arguments: nil, context: .empty)
    }
    #expect(throws: conflict) { try registry.listTools(context: .empty) }
    #expect(client.calls.isEmpty)
    client.replace("first", names: ["inspect"])
    #expect(
      try registry.callTool(name: "inspect", arguments: nil, context: .empty)
        == .string("first:inspect"))
  }

  @Test
  func asyncGatewayFallbackValidatesTheCatalogBeforeCallingDownstream() async throws {
    let client = ReexportNamingClient(["first": ["inspect", "mcp.tools.list"]])
    let registry = GatewayToolRegistry(
      configuration: .fixture(mcp: .init(servers: [Self.server("first", prefix: "")])),
      mcpClient: client)
    await #expect(
      throws: GatewayToolError.invalidArguments("Reexported tool name conflicts: mcp.tools.list")
    ) {
      try await registry.callToolAsync(
        definition: .init(
          name: "mcp.tools.call", description: "Gateway", inputSchema: .object([:])),
        arguments: .object(["server": .string("first"), "tool": .string("inspect")]),
        context: .empty)
    }
    #expect(client.discoveredServers == ["first"])
    #expect(client.calls.isEmpty)
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
        platform: MacOSPlatform.services, mcpClient: ReexportNamingClient(["first": [name]]))
    }
  }

  @Test
  func reservedCoreNameDuringRefreshDoesNotReplaceTheValidatedCatalog() async throws {
    let client = ReexportNamingClient(["first": ["available"]])
    let registry = GatewayToolRegistry(
      configuration: .fixture(mcp: .init(servers: [Self.server("first", prefix: "")])),
      mcpClient: client)
    let router = try GatewayProviderRouter(
      registry: registry, additionalProviders: { [] }, reservedToolNames: ["workspace.list"])
    do {
      client.replace("first", names: ["workspace.list"])
      await #expect(throws: GatewayProviderRouterError.duplicateTool("workspace.list")) {
        try await router.refreshTools(context: .empty)
      }
      #expect(try router.listTools(context: .empty).contains { $0.name == "available" })
      #expect(try !router.listTools(context: .empty).contains { $0.name == "workspace.list" })
      client.replace("first", names: ["recovered"])
      try await router.refreshTools(context: .empty)
      #expect(
        try router.callTool(name: "recovered", arguments: nil, context: .empty)
          == .string("first:recovered"))
      await router.shutdown()
    } catch {
      await router.shutdown()
      throw error
    }
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
