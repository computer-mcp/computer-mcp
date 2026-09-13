import Foundation
import Testing
import os

@testable import ComputerMCP

struct MCPProfileGrantTests {
  @Test(arguments: [false, true], [false, true])
  func catalogReplacementDoesNotTransferRegistrationOrAliasAuthority(
    preserveName: Bool, grantAlias: Bool
  ) async throws {
    let fixture = try ProfileRuntimeFixture()
    defer { fixture.cleanup() }
    let client = ReplacedProfileCatalogClient()
    let prefix = preserveName ? "" : "shared"
    let publicName = preserveName ? "inspect" : "shared.inspect"
    let configuration = GatewayConfiguration(
      runtime: .init(caller: .secureTunnel, profileID: .chatGPTOperate),
      profiles: [
        .init(
          id: .chatGPTOperate,
          capabilities: grantAlias ? ["review.inspect", "mcp.tools.list"] : [],
          workspaces: ["fixture"], mcpServers: grantAlias ? [] : ["alpha"])
      ],
      mcp: .init(
        servers: ["alpha", "beta"].map {
          .init(
            id: $0, transport: .stdio, command: "/bin/cat", exposure: .reexport,
            prefix: prefix, allowAnyTool: true, toolRisks: ["inspect": .readOnly])
        }),
      tools: [.init(name: "review.inspect", adapter: .mcp, source: "alpha", tool: "inspect")])
    let runtime = try GatewayRuntime(
      configuration: configuration,
      registeredWorkspaces: [
        .init(id: "fixture", displayName: "Fixture", rootPath: fixture.root.path)
      ],
      mcpClient: client)
    do {
      #expect(try runtime.listTools().contains { $0.name == publicName })
      _ = try runtime.callTool(name: publicName, arguments: .object([:]))
      _ = try runtime.callTool(name: "review.inspect", arguments: .object([:]))
      _ = try runtime.callTool(
        name: "mcp.tools.call", arguments: Self.callArguments(server: "alpha", tool: "inspect"))

      client.replace(server: "beta", revision: 2)
      try await runtime.refreshTools()
      #expect(try !runtime.listTools().contains { $0.name == publicName })
      #expect(throws: (any Error).self) {
        try runtime.callTool(name: publicName, arguments: .object([:]))
      }
      #expect(throws: (any Error).self) {
        try runtime.callTool(
          name: "mcp.tools.call", arguments: Self.callArguments(server: "beta", tool: "inspect"))
      }
      do {
        let listed = try Self.result(
          runtime.callTool(
            name: "mcp.tools.list", arguments: .object(["server": .string("beta")])))
        #expect(listed == .array([]))
      } catch {
        #expect(error.localizedDescription == "Unknown MCP server id: beta")
      }
      #expect(throws: (any Error).self) {
        try runtime.callTool(name: "review.inspect", arguments: .object([:]))
      }
      #expect(client.calledServers.allSatisfy { $0 == "alpha" })

      client.replace(server: "alpha", revision: 3)
      try await runtime.refreshTools()
      let restored = try #require(try runtime.listTools().first { $0.name == publicName })
      #expect(restored.description == "revision 3")
      #expect(
        restored.inputSchema.objectValue?["properties"]?.objectValue?["value"]?.objectValue?[
          "const"] == .number(3))
      _ = try runtime.callTool(name: publicName, arguments: .object(["value": .number(3)]))
      #expect(client.calledServers.allSatisfy { $0 == "alpha" })
      await runtime.shutdown()
    } catch {
      await runtime.shutdown()
      throw error
    }
  }

  @Test
  func registrationGrantFollowsFutureToolsWithoutCopyingNames() throws {
    let configuration = Self.configuration()
    let grant = Self.grant(servers: ["alpha"])
    let policy = MCPToolAccessPolicy(
      configuration: configuration, grant: grant, derivesObserveGrant: false)
    let client = AuthorizedMCPClient(
      base: ProfileCatalogClient(names: ["inspect", "future"]), policy: policy)
    #expect(
      try client.listTools(server: configuration.mcp.servers[0]).map(\.name) == [
        "inspect", "future",
      ])
    #expect(try client.listTools(server: configuration.mcp.servers[1]).isEmpty)
    #expect(grant.capabilityIDs.isEmpty)
    #expect(policy.allows(.init(serverID: "alpha", toolName: "another_future_tool")))
    #expect(!policy.allows(.init(serverID: "beta", toolName: "another_future_tool")))
  }

  @Test
  func profileCatalogAndGenericCallsAreScopedToRegistration() async throws {
    let fixture = try ProfileRuntimeFixture()
    defer { fixture.cleanup() }
    var configuration = Self.configuration()
    configuration.profiles = [
      .init(id: .chatGPTOperate, workspaces: ["fixture"], mcpServers: ["alpha"])
    ]
    let runtime = try fixture.runtime(configuration: configuration)
    let names = Set(try runtime.listTools().map(\.name))
    #expect(names.contains("alpha.future"))
    #expect(names.contains("alpha_alias.inspect"))
    #expect(!names.contains("beta.inspect"))
    #expect(!names.contains("beta_alias.inspect"))
    let servers = try Self.result(
      runtime.callTool(name: "mcp.servers.list", arguments: .object([:])))
    #expect(servers.arrayValue?.compactMap { $0.objectValue?["id"]?.stringValue } == ["alpha"])
    let listed = try Self.result(
      runtime.callTool(name: "mcp.tools.list", arguments: .object(["server": .string("alpha")])))
    #expect(
      listed.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue } == [
        "inspect", "future",
      ])
    _ = try runtime.callTool(name: "alpha.future", arguments: .object([:]))
    _ = try runtime.callTool(
      name: "mcp.tools.call", arguments: Self.callArguments(server: "alpha", tool: "future"))
    #expect(throws: (any Error).self) {
      try runtime.callTool(
        name: "mcp.tools.call", arguments: Self.callArguments(server: "beta", tool: "inspect"))
    }
    #expect(throws: (any Error).self) {
      try runtime.callTool(name: "mcp.tools.list", arguments: .object(["server": .string("beta")]))
    }
    #expect(throws: (any Error).self) {
      try runtime.callTool(name: "beta_alias.inspect", arguments: .object([:]))
    }
    await runtime.shutdown()
  }

  @Test
  func aliasGrantFiltersGenericDiscoveryBeforeCountsAndDescriptions() async throws {
    let fixture = try ProfileRuntimeFixture()
    defer { fixture.cleanup() }
    var configuration = Self.configuration()
    configuration.profiles = [
      .init(
        id: .chatGPTOperate,
        capabilities: [
          "alpha_alias.inspect", "mcp.tools.list", "mcp.tools.find", "mcp.tools.describe",
        ], workspaces: ["fixture"])
    ]
    let runtime = try fixture.runtime(configuration: configuration)
    let names = Set(try runtime.listTools().map(\.name))
    #expect(names.contains("alpha.inspect"))
    #expect(!names.contains("alpha.future"))
    #expect(!names.contains("beta_alias.inspect"))
    let found = try Self.result(
      runtime.callTool(
        name: "mcp.tools.find",
        arguments: .object([
          "server": .string("alpha"), "query": .string("secret"),
        ])))
    #expect(found.objectValue?["tool_count"] == .number(1))
    #expect(found.objectValue?["result_count"] == .number(0))
    #expect(found.objectValue?["tools"] == .array([]))
    let described = try Self.result(
      runtime.callTool(
        name: "mcp.tools.describe",
        arguments: .object([
          "server": .string("alpha"), "tool": .string("inspect"),
        ])))
    #expect(described.objectValue?["tool_count"] == .number(1))
    #expect(throws: (any Error).self) {
      try runtime.callTool(
        name: "mcp.tools.describe",
        arguments: .object([
          "server": .string("alpha"), "tool": .string("future"),
        ]))
    }
    _ = try runtime.callTool(name: "alpha_alias.inspect", arguments: .object([:]))
    _ = try runtime.callTool(name: "alpha.inspect", arguments: .object([:]))
    _ = try runtime.callTool(
      name: "mcp.tools.call", arguments: Self.callArguments(server: "alpha", tool: "inspect"))
    #expect(throws: (any Error).self) {
      try runtime.callTool(
        name: "mcp.tools.call", arguments: Self.callArguments(server: "alpha", tool: "future"))
    }
    await runtime.shutdown()
  }

  @Test
  func deniedGenericTargetsDoNotRevealRegistrationOrSelection() async throws {
    let fixture = try ProfileRuntimeFixture()
    defer { fixture.cleanup() }
    var configuration = Self.configuration()
    configuration.profiles = [.init(id: .chatGPTOperate, mcpServers: ["alpha"])]
    configuration.mcp.servers[1].allowAnyTool = false
    configuration.mcp.servers[1].allowedTools = ["inspect"]
    let runtime = try fixture.runtime(configuration: configuration)
    var errors: [String] = []
    for (server, tool) in [("beta", "inspect"), ("beta", "future"), ("missing", "inspect")] {
      expectThrows(
        try runtime.callTool(
          name: "mcp.tools.call", arguments: Self.callArguments(server: server, tool: tool))
      ) { error in
        errors.append(error.localizedDescription)
        #expect(error.localizedDescription.contains("policy.capability_denied"))
      }
    }
    #expect(errors.count == 3)
    #expect(Set(errors).count == 1)
    await runtime.shutdown()
  }

  @Test
  func discoveryCapabilityAloneDoesNotGrantDownstreamTools() throws {
    let configuration = Self.configuration()
    let client = AuthorizedMCPClient(
      base: ProfileCatalogClient(),
      policy: .init(
        configuration: configuration,
        grant: Self.grant(capabilities: ["mcp.tools.list", "mcp.tools.find", "mcp.tools.describe"]),
        derivesObserveGrant: false))
    #expect(try client.listTools(server: configuration.mcp.servers[0]).isEmpty)
    #expect(throws: (any Error).self) {
      try client.callTool(
        server: configuration.mcp.servers[0], name: "inspect", arguments: .object([:]))
    }
  }

  @Test
  func explicitGenericCallGrantPreservesHostSelectedToolAuthority() throws {
    var configuration = Self.configuration()
    configuration.mcp.servers[1].allowAnyTool = false
    configuration.mcp.servers[1].allowedTools = ["inspect"]
    let policy = MCPToolAccessPolicy(
      configuration: configuration,
      grant: Self.grant(capabilities: ["mcp.tools.call"]), derivesObserveGrant: false)
    #expect(policy.allows(.init(serverID: "alpha", toolName: "future")))
    #expect(policy.allows(.init(serverID: "beta", toolName: "inspect")))
    #expect(!policy.allows(.init(serverID: "beta", toolName: "future")))
    #expect(!policy.permitsServer(configuration.mcp.servers[0], capability: "mcp.resources.read"))
  }

  @Test(arguments: [GatewayProfileID.chatGPTObserve, .cloudflareObserve])
  func registrationGrantCannotExpandObserveRisk(profile: GatewayProfileID) throws {
    var configuration = Self.configuration()
    configuration.mcp.servers[0].toolRisks = ["inspect": .readOnly]
    let client = AuthorizedMCPClient(
      base: ProfileCatalogClient(),
      policy: .init(
        configuration: configuration,
        grant: .init(id: profile, capabilityIDs: [], allowedCallers: [], mcpServerIDs: ["alpha"]),
        derivesObserveGrant: false))
    #expect(try client.listTools(server: configuration.mcp.servers[0]).map(\.name) == ["inspect"])
    #expect(throws: (any Error).self) {
      try client.callTool(
        server: configuration.mcp.servers[0], name: "future", arguments: .object([:]))
    }
  }

  @Test
  func registrationGrantStillIntersectsHostSelectionAndFullShellSetting() throws {
    var configuration = Self.configuration()
    configuration.mcp.servers[0].allowAnyTool = false
    configuration.mcp.servers[0].allowedTools = ["inspect"]
    configuration.mcp.servers[0].toolRisks = ["inspect": .fullShell]
    let grant = Self.grant(servers: ["alpha"])
    let policy = MCPToolAccessPolicy(
      configuration: configuration, grant: grant, derivesObserveGrant: false)
    #expect(!policy.allows(.init(serverID: "alpha", toolName: "inspect")))
    var enabled = grant
    enabled.fullShellEnabled = true
    let enabledPolicy = MCPToolAccessPolicy(
      configuration: configuration, grant: enabled, derivesObserveGrant: false)
    #expect(enabledPolicy.allows(.init(serverID: "alpha", toolName: "inspect")))
    #expect(!enabledPolicy.allows(.init(serverID: "alpha", toolName: "future")))
  }

  @Test
  func persistedFullShellSettingAppliesToCatalogAndExecution() async throws {
    let fixture = try ProfileRuntimeFixture()
    defer { fixture.cleanup() }
    let database = try GatewayDatabase(inMemory: ())
    var persisted = Self.grant(servers: ["beta"])
    persisted.workspaceIDs = ["fixture"]
    persisted.fullShellEnabled = true
    try database.saveProfile(persisted)
    var configuration = Self.configuration()
    configuration.policy.shellEnabled = true
    configuration.profiles = [.init(id: .chatGPTOperate, mcpServers: ["alpha"])]
    configuration.mcp.servers[0].toolRisks = ["inspect": .fullShell]
    let runtime = try GatewayRuntime(
      configuration: configuration, database: database,
      registeredWorkspaces: [
        .init(id: "fixture", displayName: "Fixture", rootPath: fixture.root.path)
      ],
      mcpClient: ProfileCatalogClient())
    #expect(try runtime.listTools().contains { $0.name == "alpha.inspect" })
    #expect(try !runtime.listTools().contains { $0.name == "beta.inspect" })
    _ = try runtime.callTool(name: "alpha.inspect", arguments: .object([:]))
    _ = try runtime.callTool(
      name: "mcp.tools.call", arguments: Self.callArguments(server: "alpha", tool: "inspect"))
    await runtime.shutdown()
  }

  @Test
  func configurationAndProfileEncodingPreserveRegistrationGrants() throws {
    var configuration = Self.configuration()
    configuration.profiles = [.init(id: .chatGPTOperate, mcpServers: ["alpha"])]
    let decoded = try GatewayConfiguration.load(text: configuration.exportedTOML())
    #expect(decoded.profiles == configuration.profiles)
    let grant = decoded.profiles[0].grant
    #expect(try JSONDecoder().decode(ProfileGrant.self, from: JSONEncoder().encode(grant)) == grant)
    var persisted = Self.grant(servers: ["beta"])
    persisted.workspaceIDs = ["fixture"]
    let effective = grant.applyingPersistedRuntimeState(persisted)
    #expect(effective.mcpServerIDs == ["alpha"])
    #expect(effective.workspaceIDs == ["fixture"])
  }

  @Test
  func olderProfileRecordsDecodeWithNoImplicitRegistrationGrant() throws {
    let data = Data(
      """
      {"id":"chatgpt-operate","capabilityIDs":["mcp.tools.call"],"workspaceIDs":[],
       "allowedCallers":["secure-tunnel"],"fullShellEnabled":false}
      """.utf8)
    let grant = try JSONDecoder().decode(ProfileGrant.self, from: data)
    #expect(grant.mcpServerIDs.isEmpty)
    #expect(grant.capabilityIDs == ["mcp.tools.call"])
  }

  @Test(arguments: [["missing"], ["alpha", "alpha"]])
  func rejectsInvalidRegistrationGrantReferences(servers: [String]) {
    var configuration = Self.configuration()
    configuration.profiles = [.init(id: .chatGPTOperate, mcpServers: servers)]
    #expect(throws: (any Error).self) { try configuration.validate() }
  }

  @Test
  func otherMCPSurfacesRequireTheirOwnExplicitGrant() throws {
    let configuration = Self.configuration()
    let alpha = configuration.mcp.servers[0]
    let groupClient = AuthorizedMCPClient(
      base: ProfileCatalogClient(),
      policy: .init(
        configuration: configuration, grant: Self.grant(servers: ["alpha"]),
        derivesObserveGrant: false))
    #expect(
      try groupClient.readResource(server: alpha, uri: "fixture://one") == .string("fixture://one"))
    let toolClient = AuthorizedMCPClient(
      base: ProfileCatalogClient(),
      policy: .init(
        configuration: configuration, grant: Self.grant(capabilities: ["alpha_alias.inspect"]),
        derivesObserveGrant: false))
    #expect(throws: (any Error).self) {
      try toolClient.readResource(server: alpha, uri: "fixture://one")
    }
    #expect(throws: (any Error).self) {
      try toolClient.readEvents(server: alpha, afterCursor: 0, maxResults: 1)
    }
    let resourceClient = AuthorizedMCPClient(
      base: ProfileCatalogClient(),
      policy: .init(
        configuration: configuration,
        grant: Self.grant(capabilities: ["mcp.resources.read", "mcp.events.read"]),
        derivesObserveGrant: false))
    #expect(
      try resourceClient.readResource(server: alpha, uri: "fixture://one")
        == .string("fixture://one"))
    _ = try resourceClient.readEvents(server: alpha, afterCursor: 0, maxResults: 1)
    #expect(try resourceClient.listTools(server: alpha).isEmpty)
  }

  private static func configuration() -> GatewayConfiguration {
    GatewayConfiguration(
      runtime: .init(caller: .secureTunnel, profileID: .chatGPTOperate),
      mcp: .init(
        servers: ["alpha", "beta"].map {
          .init(
            id: $0, transport: .stdio, command: "/bin/cat", exposure: .reexport, prefix: $0,
            allowAnyTool: true)
        }),
      tools: ["alpha", "beta"].map {
        .init(name: "\($0)_alias.inspect", adapter: .mcp, source: $0, tool: "inspect")
      })
  }

  private static func grant(capabilities: Set<String> = [], servers: Set<String> = [])
    -> ProfileGrant
  {
    .init(
      id: .chatGPTOperate, capabilityIDs: capabilities, allowedCallers: [.secureTunnel],
      mcpServerIDs: servers)
  }

  private static func callArguments(server: String, tool: String) -> JSONValue {
    .object(["server": .string(server), "tool": .string(tool), "arguments": .object([:])])
  }

  private static func result(_ value: JSONValue) throws -> JSONValue {
    try #require(value.objectValue?["structuredContent"]?.objectValue?["result"])
  }
}

private struct ProfileRuntimeFixture {
  let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func runtime(configuration: GatewayConfiguration) throws -> GatewayRuntime {
    try GatewayRuntime(
      configuration: configuration,
      registeredWorkspaces: [.init(id: "fixture", displayName: "Fixture", rootPath: root.path)],
      mcpClient: ProfileCatalogClient())
  }

  func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private struct ProfileCatalogClient: DownstreamMCPClient {
  func makeScopedClient(
    workingDirectory: URL, environment: [String: String], hostContext: MCPHostContext?
  )
    -> any DownstreamMCPClient
  { self }

  var names = ["inspect", "future"]

  func listTools(server: MCPServerConfig) throws -> [MCPTool] {
    names.map {
      MCPTool(
        name: $0, description: $0 == "future" ? "secret description" : "Inspect fixture",
        inputSchema: .object(["type": .string("object")]), annotations: .init(readOnlyHint: true))
    }
  }

  func callTool(server: MCPServerConfig, name: String, arguments: JSONValue) throws -> JSONValue {
    .object([
      "content": .array([
        .object(["type": .string("text"), "text": .string("\(server.id):\(name)")])
      ])
    ])
  }

  func listResources(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func listResourceTemplates(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func readResource(server: MCPServerConfig, uri: String) throws -> JSONValue { .string(uri) }
  func listPrompts(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func getPrompt(server: MCPServerConfig, name: String, arguments: [String: String]?) throws
    -> JSONValue
  { .null }
}

private final class ReplacedProfileCatalogClient: DownstreamMCPClient, Sendable {
  private struct State {
    var server = "alpha"
    var revision = 1
    var calledServers: [String] = []
  }
  private let state = OSAllocatedUnfairLock(initialState: State())

  var calledServers: [String] { state.withLock { $0.calledServers } }

  func replace(server: String, revision: Int) {
    state.withLock {
      $0.server = server
      $0.revision = revision
    }
  }

  func makeScopedClient(
    workingDirectory: URL, environment: [String: String], hostContext: MCPHostContext?
  ) -> any DownstreamMCPClient { self }

  func listTools(server: MCPServerConfig) throws -> [MCPTool] {
    state.withLock { state in
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

  func callTool(server: MCPServerConfig, name: String, arguments: JSONValue) throws -> JSONValue {
    try state.withLock { state in
      state.calledServers.append(server.id)
      guard state.server == server.id else { throw GatewayToolError.unknownTool(name) }
      return .object([
        "content": .array([.object(["type": .string("text"), "text": .string(server.id)])])
      ])
    }
  }

  func listResources(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func listResourceTemplates(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func readResource(server: MCPServerConfig, uri: String) throws -> JSONValue { .null }
  func listPrompts(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func getPrompt(server: MCPServerConfig, name: String, arguments: [String: String]?) throws
    -> JSONValue
  { .null }
}
