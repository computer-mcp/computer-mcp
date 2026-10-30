import ComputerMCPDownstream
import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPTestSupport
import ComputerMCPToolKit
import ComputerMCPToolsMCP
import Foundation
import NIOConcurrencyHelpers
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPGateway

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

struct MCPAuthorizationTests {
  @Test
  func allowedCallsExecuteDirectlyThroughGenericAndReexportedRoutes() async throws {
    let server = MCPServerConfig(
      id: "remote", transport: .stdio, command: "/bin/cat", exposure: .reexport,
      prefix: "remote", allowedTools: ["inspect"], toolRisks: ["inspect": .destructive])
    var permissions = Permissions()
    try permissions.set(.granted(.all), for: .mcpServer("remote"))
    try permissions.set(.granted(.write), for: .project("fixture"))
    let client = CatalogClient()
    let root = try ScopedTemporaryDirectory()
    let project = root.url.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
    let database = try fixturePermissionDatabase(
      path: root.url.appendingPathComponent("host.sqlite").path)
    try database.saveProject(.init(id: "fixture", displayName: "Fixture", rootPath: project.path))
    let grant = ProfileGrant(
      id: .localAdmin, permissions: permissions, fullAccess: true, allowedCallers: [.localMCP])
    try database.saveProfile(grant)
    let context = try fixtureConsentedContext(
      database: database, grant: grant, caller: .localMCP, projectID: "fixture",
      platform: fixtureHostedPlatform())
    let runtime = try GatewayRuntime(
      configuration: .init(
        runtime: .init(caller: .localMCP, profileID: .localAdmin),
        profiles: [
          .init(
            grant: grant)
        ],
        mcp: .init(servers: [server]), projectDirectory: project), context: context,
      database: database,
      registeredProjects: database.projects(), platform: fixtureHostedPlatform(), mcpClient: client)
    _ = try runtime.makeControlSession()
    try fixtureApproveLocalProvider(
      server, database: database,
      runtime: database.permissionRuntime(platform: fixtureHostedPlatform()),
      permissions: fixturePermissions([.project("fixture"): .granted(.write)]), fullAccess: true)
    let session = try #require(context.controlSession as? GatewayControlSession)
    _ = try session.approveFullAccess(expectedRevision: session.revision)
    do {
      for name in ["mcp.tools.call", "remote.inspect"] {
        let arguments: JSONValue =
          name == "mcp.tools.call"
          ? .object([
            "server": .string("remote"), "tool": .string("inspect"), "arguments": .object([:]),
          ])
          : .object([:])
        _ = try runtime.callTool(name: name, arguments: arguments, context: .empty)
        _ = try await runtime.callToolAsync(name: name, arguments: arguments, context: .empty)
      }
      #expect(client.callCount == 4)
      await runtime.shutdown()
    } catch {
      await runtime.shutdown()
      throw error
    }
  }

  @Test(arguments: [false, true])
  func defaultProfileListsCachedToolsAsRequestable(hostReadOnly: Bool) async throws {
    let server = MCPServerConfig(
      id: "remote", transport: .stdio, command: "/bin/cat", exposure: .reexport,
      prefix: "remote", allowedTools: ["inspect"],
      toolRisks: hostReadOnly ? ["inspect": .readOnly] : [:])
    let client = CatalogClient()
    let runtime = try GatewayRuntime(
      configuration: .init(
        runtime: .init(caller: .secureTunnel, profileID: .chatGPTObserve),
        mcp: .init(servers: [server])),
      context: .init(
        caller: .secureTunnel, profileID: .chatGPTObserve,
        trustedPrincipalID: "verified-requestable-client"),
      platform: fixtureHostedPlatform(), mcpClient: client)
    #expect(try runtime.listTools(context: .empty).contains { $0.name == "remote.inspect" })
    #expect(client.callCount == 0)
    await runtime.shutdown()
  }

  @Test
  func reexportRiskComesFromHostRatherThanAnnotationsOrName() throws {
    let client = CatalogClient()
    let server = MCPServerConfig(
      id: "remote", transport: .stdio, command: "/bin/cat",
      exposure: .reexport, prefix: "mcp", allowedTools: ["inspect"])
    let registry = MacOSToolProviders().makeProviders(
      toolEnvironment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: .fixture(mcp: .init(servers: [server]))), mcpClient: client)
    let router = try GatewayProviderRouter(registry: registry)
    let definition = try #require(
      router.listTools(context: .empty).first { $0.name == "mcp.inspect" })
    #expect(definition.annotations?.readOnlyHint == true)
    #expect(definition.json.objectValue?["mcpReference"] == nil)
    let capability = try router.capability(named: "mcp.inspect", context: .empty)
    #expect(capability.risk == .externalWrite)
    #expect(capability.mcpReference == .init(serverID: "remote", toolName: "inspect"))
  }

  @Test
  func hostRiskAppliesToAliasesAndReexports() throws {
    let server = MCPServerConfig(
      id: "remote", transport: .stdio, command: "/bin/cat", exposure: .reexport,
      prefix: "remote", allowedTools: ["inspect"], toolRisks: ["inspect": .readOnly])
    let registry = MacOSToolProviders().makeProviders(
      toolEnvironment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: .fixture(
          mcp: .init(servers: [server]),
          tools: [.init(name: "alias.inspect", adapter: .mcp, source: "remote", tool: "inspect")])),
      mcpClient: CatalogClient())
    let router = try GatewayProviderRouter(registry: registry)
    #expect(try router.capability(named: "remote.inspect", context: .empty).risk == .readOnly)
    #expect(try router.capability(named: "alias.inspect", context: .empty).risk == .readOnly)
  }

  @Test
  func emptySelectionDeniesAliasesAndGenericCalls() throws {
    let registryEnvironment = ToolEnvironment(
      launcher: testExecutionLauncher(),
      configuration: .fixture(
        mcp: .init(servers: [MCPServerConfig(id: "remote", transport: .stdio, command: "/bin/cat")]
        ),
        tools: [.init(name: "alias.inspect", adapter: .mcp, source: "remote", tool: "inspect")]))
    let registry = ConfiguredMCPToolProvider(
      environment: registryEnvironment, mcpClient: CatalogClient())
    #expect(try !registry.definitions().map(\.tool).contains { $0.name == "alias.inspect" })
    #expect(throws: (any Error).self) {
      try registry.callTool(.init(name: "alias.inspect", arguments: .object([:]), context: .empty))
    }
    #expect(throws: (any Error).self) {
      try MCPToolProvider(environment: registryEnvironment, mcpClient: CatalogClient()).callTool(
        .init(
          name: "mcp.tools.call",
          arguments: .object(["server": .string("remote"), "tool": .string("inspect")]),
          context: .empty))
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
    let registry = MacOSToolProviders().makeProviders(
      toolEnvironment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: .fixture(mcp: .init(servers: servers))), mcpClient: client)
    let router = try GatewayProviderRouter(registry: registry)
    let direct = ConfiguredMCPToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(), configuration: .fixture(mcp: .init(servers: servers))),
      mcpClient: client)
    let invocation = ToolInvocation(
      name: "shared.nested.inspect", arguments: .object([:]), context: .empty)
    #expect(try direct.callTool(invocation) == .string("second:inspect"))
    #expect(
      try router.callTool(
        name: invocation.name, arguments: invocation.arguments, context: invocation.context)
        == .string("second:inspect"))
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
  func cachedTools(server: MCPServerConfig, context: InvocationContext) -> [MCPTool]? {
    try? listTools(server: server, context: context)
  }

  private let calls = NIOLockedValueBox(0)
  var callCount: Int { calls.withLockedValue { $0 } }
  func makeScopedClient(
    workingDirectory: URL, environment: [String: String], hostContext: (any MCPHostEnvironment)?
  )
    -> any DownstreamMCPClient
  { self }

  func listTools(server: MCPServerConfig, context: InvocationContext) throws -> [MCPTool] {
    [
      MCPTool(
        name: "inspect", description: "Claims read-only", inputSchema: .object([:]),
        annotations: .init(readOnlyHint: true, destructiveHint: false))
    ]
  }

  func callTool(
    server: MCPServerConfig, name: String, arguments: JSONValue, context: InvocationContext
  ) throws -> JSONValue {
    calls.withLockedValue { $0 += 1 }
    return .string("\(server.id):\(name)")
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
