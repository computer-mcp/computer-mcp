import ComputerMCPDownstream
import ComputerMCPMacOS
import ComputerMCPTestSupport
import ComputerMCPToolKit
import ComputerMCPToolsCLI
import ComputerMCPToolsGit
import ComputerMCPToolsMCP
import ComputerMCPToolsShell
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPGateway

struct MCPReexportNamingTests {
  @Test(arguments: [
    "system.inspect", "network.inspect", "macos.inspect", "mcp.inspect", "git.inspect",
  ])
  func configuredRoutesKeepTheirProviderAcrossNamespaces(name: String) throws {
    let environment = ToolEnvironment(
      configuration: .fixture(mcp: .init(servers: [Self.server("first", prefix: "")])))
    let registry = MacOSToolProviders().makeProviders(
      toolEnvironment: environment, mcpClient: ReexportNamingClient(["first": [name]]))
    let snapshot = try GatewayToolCatalogSnapshot(providers: registry.providers())
    let route = try #require(snapshot.routes[name])
    #expect(route.provider.id == "configured")
    #expect(route.provider.namespaces.isEmpty)
    #expect(route.capability.mcpReference == .init(serverID: "first", toolName: name))
  }

  @Test
  func downstreamToolsListWithTheirNamespaceProvidersBeforeTreesAndComputerUse() async throws {
    let project = try ScopedTemporaryDirectory()
    let treeURL = project.url.appendingPathComponent("tree.json")
    try JSONEncoder().encode(CLITreeGatewayTests.tree(CLITreeGatewayTests.printCommand()))
      .write(to: treeURL)
    var configuration = GatewayConfiguration.fixture(
      cli: .init(commands: [
        .init(
          id: "printf", executable: "/usr/bin/printf", allowAnyArgs: false,
          tree: .init(kind: .file, path: treeURL.path))
      ]),
      mcp: .init(servers: [
        Self.server("first", prefix: "mcp"), Self.server("second", prefix: "custom"),
      ]),
      tools: [
        .init(name: "git.zulu", adapter: .mcp, source: "first", tool: "inspect"),
        .init(name: "custom.alias", adapter: .mcp, source: "first", tool: "inspect"),
        .init(name: "git.alpha", adapter: .mcp, source: "first", tool: "inspect"),
        .init(name: "mcpish.alias", adapter: .mcp, source: "first", tool: "inspect"),
        .init(name: "skills.alias", adapter: .mcp, source: "first", tool: "inspect"),
      ],
      builtin: .init(enabled: [
        "file.read", "file.stat", "git.root", "git.status", "system.time", "network.interfaces",
        "macos.screens", "macos.user_directories",
      ]),
      skills: .init(enabled: true, roots: [.init(id: "fixture", path: project.url.path)]))
    configuration.projectDirectory = project.url
    try configuration.validate()
    let environment = ToolEnvironment(configuration: configuration)
    let treeTools = try CLIToolProvider(environment: environment).treeProviders().flatMap {
      try $0.definitions().map(\.tool.name)
    }
    try #require(treeTools.count == 1)
    let client = ReexportNamingClient([
      "first": ["zeta", "inspect"], "second": ["inspect", "alpha"],
    ])
    let registry = MacOSToolProviders().makeProviders(
      toolEnvironment: environment, mcpClient: client)
    let router = try GatewayProviderRouter(registry: registry)
    do {
      let discoveries = client.discoveredServers
      let expected =
        [
          "cli.list", "cli.describe", "cli.status", "cli.help", "cli.exec",
          "process.spawn", "process.list", "process.read", "process.cancel",
          "mcp.servers.list", "mcp.servers.status", "mcp.tools.list", "mcp.tools.describe",
          "mcp.tools.find", "mcp.tools.call", "mcp.resources.list", "mcp.resources.templates.list",
          "mcp.resources.read", "mcp.prompts.list", "mcp.prompts.get", "mcp.events.read",
          "mcp.requests.list", "mcp.requests.cancel", "mcp.connections.close", "mcp.requests.read",
          "mcp.zeta", "mcp.inspect",
          "skills.roots", "skills.list", "skills.describe", "skills.validate", "skills.frontmatter",
          "skills.read", "skills.files", "skills.read_file", "skills.read_files",
          "skills.read_package", "skills.outline", "skills.section", "skills.tables",
          "skills.links", "skills.link_check", "skills.search", "skills.search_files",
          "skills.alias",
          "file.read", "file.stat", "git.root", "git.status", "git.zulu", "git.alpha",
          "system.time", "network.interfaces", "macos.screens", "macos.user_directories",
          "custom.alias", "mcpish.alias", "custom.inspect", "custom.alpha",
        ] + treeTools + [
          "computer.permissions", "computer.displays", "computer.screenshot", "computer.windows",
          "computer.pointer.position", "computer.pointer.move", "computer.pointer.click",
          "computer.keyboard.key", "computer.keyboard.text", "computer.scroll",
          "computer.accessibility.query", "computer.accessibility.action", "computer.verify",
        ]
      #expect(discoveries == ["first", "first", "first", "first", "first", "first", "second"])
      #expect(try router.listTools(context: .empty).map(\.name) == expected)
      client.replace("first", names: ["fresh"])
      #expect(try router.listTools(context: .empty).map(\.name) == expected)
      #expect(
        try router.callTool(name: "git.alpha", arguments: nil, context: .empty)
          == .string("first:inspect"))
      #expect(
        try await router.callToolAsync(name: "mcp.inspect", arguments: nil, context: .empty)
          == .string("first:inspect"))
      #expect(client.discoveredServers == discoveries)
      await router.shutdown()
    } catch {
      await router.shutdown()
      throw error
    }
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
    let registry = MacOSToolProviders().makeProviders(
      toolEnvironment: ToolEnvironment(configuration: configuration), mcpClient: client)
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
    let client = ReexportNamingClient(["first": [name]])
    #expect(throws: (any Error).self) {
      _ = try GatewayProviderRouter(providers: [
        ConfiguredMCPToolProvider(environment: environment, mcpClient: client),
        CLIToolProvider(environment: environment), GitToolProvider(environment: environment),
        ShellToolProvider(environment: environment), ProcessToolProvider(environment: environment),
      ])
    }
  }

  @Test(arguments: [
    "project.list", "project.describe", "policy.probe", "operations.prepare",
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
        registeredProjects: [.init(id: "fixture", displayName: "Fixture", rootPath: root.path)],
        platform: MacOSPlatform.services, mcpClient: ReexportNamingClient(["first": [name]]))
    }
  }

  @Test(arguments: ["profile", ""])
  func managementNamesStayReservedWithoutProvider(prefix: String) async throws {
    let root = try ScopedTemporaryDirectory()
    let name = prefix.isEmpty ? "profile.show" : "show"
    let configuration = GatewayConfiguration(
      mcp: .init(servers: [Self.server("first", prefix: prefix)]),
      projectDirectory: root.url)
    await #expect(throws: GatewayProviderRouterError.duplicateTool("profile.show")) {
      let runtime = try await GatewayRuntime.make(
        configuration: configuration,
        registeredProjects: [
          .init(id: "fixture", displayName: "Fixture", rootPath: root.url.path)
        ],
        platform: MacOSPlatform.services, mcpClient: ReexportNamingClient(["first": [name]]),
        bundledPlugins: .load(directory: nil), remoteManagement: nil)
      await runtime.shutdown()
    }
  }

  @Test
  func reservedCoreNameDuringRefreshDoesNotReplaceTheValidatedCatalog() async throws {
    let client = ReexportNamingClient(["first": ["available"]])
    let registry = MacOSToolProviders().makeProviders(
      toolEnvironment: ToolEnvironment(
        configuration: .fixture(mcp: .init(servers: [Self.server("first", prefix: "")]))),
      mcpClient: client)
    let router = try GatewayProviderRouter(
      registry: registry, reservedToolNames: ["project.list"])
    do {
      client.replace("first", names: ["project.list"])
      await #expect(throws: GatewayProviderRouterError.duplicateTool("project.list")) {
        try await router.refreshTools(context: .empty)
      }
      #expect(try router.listTools(context: .empty).contains { $0.name == "available" })
      #expect(try !router.listTools(context: .empty).contains { $0.name == "project.list" })
      #expect(
        try router.callTool(name: "available", arguments: nil, context: .empty)
          == .string("first:available"))
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
