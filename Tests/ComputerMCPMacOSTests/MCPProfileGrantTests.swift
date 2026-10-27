import ComputerMCPDownstream
import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPTestSupport
import Foundation
import NIOConcurrencyHelpers
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPGateway

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

struct MCPProfileGrantTests {
  @Test(arguments: [false, true])
  func catalogReplacementDoesNotTransferRegistrationOrAliasAuthority(
    preserveName: Bool
  ) async throws {
    let fixture = try ProfileRuntimeFixture()
    defer { fixture.cleanup() }
    let client = ReplacedProfileCatalogClient()
    let prefix = preserveName ? "" : "shared"
    let publicName = preserveName ? "inspect" : "shared.inspect"
    var configuration = GatewayConfiguration(
      runtime: .init(caller: .secureTunnel, profileID: .chatGPTOperate),
      profiles: [
        .init(
          grant: Self.grant([
            .project("fixture"): .granted(.read), .mcpServer("alpha"): .granted(.read),
          ]))
      ],
      mcp: .init(
        servers: ["alpha", "beta"].map {
          .init(
            id: $0, transport: .stdio, command: "/bin/cat", exposure: .reexport,
            prefix: prefix, allowAnyTool: true, toolRisks: ["inspect": .readOnly])
        }),
      tools: [.init(name: "review.inspect", adapter: .mcp, source: "alpha", tool: "inspect")])
    let database = try GatewayDatabase(inMemory: ())
    var profile = configuration.profiles[0].grant
    profile.fullAccess = true
    configuration.profiles[0] = .init(grant: profile)
    try database.saveProfile(profile)
    let project = ComputerMCPCore.RegisteredProject(
      id: "fixture", displayName: "Fixture", rootPath: fixture.root.path)
    try database.saveProject(project)
    let context = try fixtureConsentedContext(
      database: database, grant: profile, caller: .secureTunnel, platform: fixtureHostedPlatform())
    let runtime = try GatewayRuntime(
      configuration: configuration, context: context, database: database,
      registeredProjects: [project],
      platform: fixtureHostedPlatform(), mcpClient: client)
    do {
      #expect(try runtime.listTools(context: .empty).contains { $0.name == publicName })
      _ = try runtime.callTool(name: publicName, arguments: .object([:]), context: .empty)
      _ = try runtime.callTool(name: "review.inspect", arguments: .object([:]), context: .empty)
      _ = try runtime.callTool(
        name: "mcp.tools.call", arguments: Self.callArguments(server: "alpha", tool: "inspect"),
        context: .empty)

      client.replace(server: "beta", revision: 2)
      try await runtime.refreshTools(context: .empty)
      #expect(try runtime.listTools(context: .empty).contains { $0.name == publicName })
      #expect(throws: (any Error).self) {
        try runtime.callTool(name: publicName, arguments: .object([:]), context: .empty)
      }
      #expect(throws: (any Error).self) {
        try runtime.callTool(
          name: "mcp.tools.call", arguments: Self.callArguments(server: "beta", tool: "inspect"),
          context: .empty)
      }
      do {
        _ = try runtime.callTool(
          name: "mcp.tools.list", arguments: .object(["server": .string("beta")]), context: .empty)
        Issue.record("A known server without its object permission should request access")
      } catch {
        #expect(GatewayRuntime.auditErrorCode(for: error) == "permission.required")
      }
      #expect(throws: (any Error).self) {
        try runtime.callTool(name: "review.inspect", arguments: .object([:]), context: .empty)
      }
      #expect(client.calledServers.allSatisfy { $0 == "alpha" })

      client.replace(server: "alpha", revision: 3)
      try await runtime.refreshTools(context: .empty)
      let restored = try #require(
        try runtime.listTools(context: .empty).first { $0.name == publicName })
      #expect(restored.description == "revision 3")
      #expect(
        restored.inputSchema.objectValue?["properties"]?.objectValue?["value"]?.objectValue?[
          "const"] == .number(3))
      _ = try runtime.callTool(
        name: publicName, arguments: .object(["value": .number(3)]), context: .empty)
      #expect(client.calledServers.allSatisfy { $0 == "alpha" })
      await runtime.shutdown()
    } catch {
      await runtime.shutdown()
      throw error
    }
  }

  @Test
  func cachedToolsStayRequestableWhileTheServerCatalogStaysPrivate() async throws {
    let database = try GatewayDatabase(inMemory: ())
    let client = ProfileCatalogClient()
    var configuration = Self.configuration()
    configuration.profiles = [.init(grant: Self.grant([:]))]
    let runtime = try GatewayRuntime(
      configuration: configuration,
      context: .init(
        caller: .secureTunnel, profileID: .chatGPTOperate, trustedPrincipalID: "verified-fixture"),
      database: database, registeredProjects: [], platform: fixtureHostedPlatform(),
      mcpClient: client)
    do {
      #expect(try runtime.listTools(context: .empty).contains { $0.name == "alpha.inspect" })
      do {
        _ = try await runtime.callToolAsync(
          name: "alpha.inspect", arguments: .object([:]), context: .empty)
        Issue.record("A requestable tool executed without its object permission")
      } catch {
        #expect(GatewayRuntime.auditErrorCode(for: error) == "permission.required")
      }
      let servers = try Self.result(
        runtime.callTool(name: "mcp.servers.list", arguments: .object([:]), context: .empty))
      #expect(servers == .array([]))
      #expect(client.calledServers.isEmpty)
      await runtime.shutdown()
    } catch {
      await runtime.shutdown()
      throw error
    }
  }

  @Test
  func missingAndDeniedObjectPermissionsKeepCatalogsPrivate() throws {
    let configuration = Self.configuration()
    let server = configuration.mcp.servers[0]
    for state in [PermissionState.notGranted, .denied] {
      let client = AuthorizedMCPClient(
        base: ProfileCatalogClient(),
        policy: .init(configuration: configuration, grant: Self.grant([.mcpServer("alpha"): state]))
      )
      #expect(!client.isServerVisible(server, context: .empty))
      #expect(try client.listTools(server: server, context: .empty).isEmpty)
      #expect(
        try client.connectionStatus(server: server, context: .empty)
          == .object(["state": .string("not_authorized")]))
      #expect(throws: (any Error).self) {
        try client.callTool(
          server: server, name: "inspect", arguments: .object([:]), context: .empty)
      }
    }
  }

  @Test
  func serverReadListsRequestableToolsAndRequiresAllForWrites() throws {
    let configuration = Self.configuration()
    let server = configuration.mcp.servers[0]
    let client = AuthorizedMCPClient(
      base: ProfileCatalogClient(),
      policy: .init(
        configuration: configuration,
        grant: Self.grant([.mcpServer("alpha"): .granted(.read)])))
    #expect(
      try client.listTools(server: server, context: .empty).map(\.name) == ["inspect", "future"])
    _ = try client.callTool(
      server: server, name: "inspect", arguments: .object([:]), context: .empty)
    #expect(throws: (any Error).self) {
      try client.callTool(server: server, name: "future", arguments: .object([:]), context: .empty)
    }
    _ = try client.readResource(server: server, uri: "fixture://one", context: .empty)
    #expect(throws: (any Error).self) {
      try client.closeConnection(server: server, context: .empty)
    }
    #expect(throws: (any Error).self) {
      try client.cancelRequest(server: server, requestID: "one", reason: nil, context: .empty)
    }
  }

  @Test
  func explicitObjectDenialOverridesWildcard() throws {
    let configuration = Self.configuration()
    let policy = MCPToolAccessPolicy(
      configuration: configuration,
      grant: Self.grant([
        .mcpServer("*"): .granted(.all), .mcpServer("beta"): .denied,
      ]))
    #expect(policy.allows(.init(serverID: "alpha", toolName: "future")))
    #expect(!policy.isVisible(configuration.mcp.servers[1]))
    #expect(!policy.allows(.init(serverID: "beta", toolName: "inspect")))
  }

  @Test
  func pluginOriginUsesPluginPermissionAndCannotGrantIndependentServers() throws {
    let configuration = Self.configuration()
    let policy = MCPToolAccessPolicy(
      configuration: configuration,
      grant: Self.grant([.plugin("package"): .granted(.use)]), pluginIDs: ["alpha": "package"])
    #expect(policy.allows(.init(serverID: "alpha", toolName: "future")))
    #expect(policy.permitsServer(configuration.mcp.servers[0], capability: "mcp.resources.read"))
    #expect(!policy.isVisible(configuration.mcp.servers[1]))
    let wrongObject = MCPToolAccessPolicy(
      configuration: configuration,
      grant: Self.grant([.mcpServer("alpha"): .granted(.all)]), pluginIDs: ["alpha": "package"])
    #expect(!wrongObject.isVisible(configuration.mcp.servers[0]))
  }

  @Test
  func fullAccessConsentDoesNotGrantObjects() throws {
    let configuration = Self.configuration()
    var grant = Self.grant([:])
    grant.fullAccess = true
    let policy = MCPToolAccessPolicy(
      configuration: configuration, grant: grant, fullAccessConsented: true)
    #expect(!policy.isVisible(configuration.mcp.servers[0]))
    #expect(!policy.allows(.init(serverID: "alpha", toolName: "inspect")))
    #expect(grant.permissions.state(for: .project("fixture")) == .notGranted)
  }

  @Test(arguments: [false, true], [false, true])
  func remoteExecutionRequiresFullAccessAndLocalConsent(enabled: Bool, consented: Bool) throws {
    var configuration = Self.configuration()
    configuration.mcp.servers[0].transport = .streamableHTTP
    configuration.mcp.servers[0].toolRisks["inspect"] = .fullShell
    var grant = Self.grant([.mcpServer("alpha"): .granted(.all)])
    grant.fullAccess = enabled
    let policy = MCPToolAccessPolicy(
      configuration: configuration, grant: grant, fullAccessConsented: consented)
    #expect(policy.allows(.init(serverID: "alpha", toolName: "inspect")) == (enabled && consented))
    #expect(policy.isToolVisible(.init(serverID: "alpha", toolName: "inspect")))
  }

  @Test
  func objectPermissionStillIntersectsHostSelection() throws {
    var configuration = Self.configuration()
    configuration.mcp.servers[0].allowAnyTool = false
    configuration.mcp.servers[0].allowedTools = ["inspect"]
    let policy = MCPToolAccessPolicy(
      configuration: configuration,
      grant: Self.grant([.mcpServer("alpha"): .granted(.all)]))
    #expect(policy.allows(.init(serverID: "alpha", toolName: "inspect")))
    #expect(!policy.allows(.init(serverID: "alpha", toolName: "future")))
    #expect(!policy.allows(.init(serverID: "unknown", toolName: "inspect")))
  }

  @Test(arguments: [false, true])
  func admittedOneTimeCallRequiresExactHostEvidence(includeAuthority: Bool) throws {
    let configuration = Self.configuration()
    let reference = MCPToolReference(serverID: "alpha", toolName: "inspect")
    let descriptor = CapabilityDescriptor(
      id: "alpha.inspect", risk: .readOnly,
      requirement: .downstream(
        serverID: "alpha", readOnly: true, remoteExecution: false, hostAction: nil),
      mcpReference: reference)
    let resolved = ResolvedToolInvocation(
      descriptor: descriptor,
      identity: .init(
        principal: .client("verified"), tool: "alpha.inspect", projectID: nil,
        argumentsDigest: "digest"),
      requirements: .init(actions: [.init(requirement: try .init(.mcpServer("alpha"), .read))]),
      pluginOrigins: [])
    let context = InvocationContext(
      resolvedInvocation: resolved, admission: .init(descriptor: descriptor),
      executionAuthority: includeAuthority ? AdmittedPermissionAuthority() : nil)
    let client = AuthorizedMCPClient(
      base: ProfileCatalogClient(),
      policy: .init(configuration: configuration, grant: Self.grant([:])))
    if includeAuthority {
      _ = try client.callTool(
        server: configuration.mcp.servers[0], name: "inspect", arguments: .object([:]),
        context: context)
    } else {
      #expect(throws: (any Error).self) {
        try client.callTool(
          server: configuration.mcp.servers[0], name: "inspect", arguments: .object([:]),
          context: context)
      }
    }
    #expect(throws: (any Error).self) {
      try client.callTool(
        server: configuration.mcp.servers[0], name: "future", arguments: .object([:]),
        context: context)
    }
  }

  @Test
  func profileAndConfigurationEncodingPreserveObjectPermissions() throws {
    let grant = Self.grant([.mcpServer("alpha"): .granted(.read), .mcpServer("beta"): .denied])
    var configuration = Self.configuration()
    configuration.profiles = [.init(grant: grant)]
    #expect(
      try GatewayConfiguration.load(text: configuration.exportedTOML()).profiles
        == configuration.profiles)
    #expect(try JSONDecoder().decode(ProfileGrant.self, from: JSONEncoder().encode(grant)) == grant)
  }

  private static func configuration() -> GatewayConfiguration {
    .init(
      runtime: .init(caller: .secureTunnel, profileID: .chatGPTOperate),
      mcp: .init(
        servers: ["alpha", "beta"].map {
          .init(
            id: $0, transport: .stdio, command: "/bin/cat", exposure: .reexport, prefix: $0,
            allowAnyTool: true, toolRisks: ["inspect": .readOnly, "future": .destructive])
        }))
  }

  private static func grant(_ entries: [Permission: PermissionState]) -> ProfileGrant {
    var permissions = Permissions()
    for (permission, state) in entries { try! permissions.set(state, for: permission) }
    return .init(id: .chatGPTOperate, permissions: permissions, allowedCallers: [.secureTunnel])
  }

  private static func result(_ value: JSONValue) throws -> JSONValue {
    try #require(value.objectValue?["structuredContent"]?.objectValue?["result"])
  }

  private static func callArguments(server: String, tool: String) -> JSONValue {
    .object(["server": .string(server), "tool": .string(tool), "arguments": .object([:])])
  }
}

private struct AdmittedPermissionAuthority: InvocationExecutionAuthority {
  var pathAccess: (any HostPathAccessChecking)? { nil }
}

private struct ProfileRuntimeFixture {
  let root: URL
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private struct ProfileCatalogClient: DownstreamMCPClient {
  func cachedTools(server: MCPServerConfig, context: InvocationContext) -> [MCPTool]? {
    try? listTools(server: server, context: context)
  }

  private let calls = NIOLockedValueBox([String]())
  var calledServers: [String] { calls.withLockedValue { $0 } }

  func makeScopedClient(
    workingDirectory: URL, environment: [String: String], hostContext: (any MCPHostEnvironment)?
  )
    -> any DownstreamMCPClient
  { self }

  var names = ["inspect", "future"]

  init(names: [String] = ["inspect", "future"]) { self.names = names }

  func listTools(server: MCPServerConfig, context: InvocationContext) throws -> [MCPTool] {
    names.map {
      MCPTool(
        name: $0, description: $0 == "future" ? "secret description" : "Inspect fixture",
        inputSchema: .object(["type": .string("object")]), annotations: .init(readOnlyHint: true))
    }
  }

  func callTool(
    server: MCPServerConfig, name: String, arguments: JSONValue, context: InvocationContext
  ) throws -> JSONValue {
    calls.withLockedValue { $0.append(server.id) }
    return .object([
      "content": .array([
        .object(["type": .string("text"), "text": .string("\(server.id):\(name)")])
      ])
    ])
  }

  func listResources(server: MCPServerConfig, cursor: String?, context: InvocationContext) throws
    -> JSONValue
  { .null }
  func listResourceTemplates(server: MCPServerConfig, cursor: String?, context: InvocationContext)
    throws -> JSONValue
  { .null }
  func readResource(server: MCPServerConfig, uri: String, context: InvocationContext) throws
    -> JSONValue
  { .string(uri) }
  func listPrompts(server: MCPServerConfig, cursor: String?, context: InvocationContext) throws
    -> JSONValue
  { .null }
  func getPrompt(
    server: MCPServerConfig, name: String, arguments: [String: String]?, context: InvocationContext
  ) throws
    -> JSONValue
  { .null }
}

private final class ReplacedProfileCatalogClient: DownstreamMCPClient, Sendable {
  func cachedTools(server: MCPServerConfig, context: InvocationContext) -> [MCPTool]? {
    try? listTools(server: server, context: context)
  }

  private struct State {
    var server = "alpha"
    var revision = 1
    var calledServers: [String] = []
  }
  private let state = NIOLockedValueBox(State())

  var calledServers: [String] { state.withLockedValue { $0.calledServers } }

  func replace(server: String, revision: Int) {
    state.withLockedValue {
      $0.server = server
      $0.revision = revision
    }
  }

  func makeScopedClient(
    workingDirectory: URL, environment: [String: String], hostContext: (any MCPHostEnvironment)?
  ) -> any DownstreamMCPClient { self }

  func listTools(server: MCPServerConfig, context: InvocationContext) throws -> [MCPTool] {
    state.withLockedValue { state in
      guard state.server == server.id else { return [] }
      return [
        .init(
          name: "inspect", description: "revision \(state.revision)",
          inputSchema: .object([
            "type": .string("object"),
            "properties": .object(["value": .object(["const": .number(Double(state.revision))])]),
          ]))
      ]
    }
  }

  func callTool(
    server: MCPServerConfig, name: String, arguments: JSONValue, context: InvocationContext
  ) throws -> JSONValue {
    try state.withLockedValue { state in
      state.calledServers.append(server.id)
      guard state.server == server.id else { throw GatewayToolError.unknownTool(name) }
      return .object([
        "content": .array([.object(["type": .string("text"), "text": .string(server.id)])])
      ])
    }
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
