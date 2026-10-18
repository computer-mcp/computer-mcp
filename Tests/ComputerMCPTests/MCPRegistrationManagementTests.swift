import Foundation
import Testing

@testable import ComputerMCP

struct MCPRegistrationManagementTests {
  @Test
  func omittedEnabledPreservesExistingConfigurationAndUnknownFieldsFail() throws {
    let json = Data(#"{"id":"manual","transport":"stdio","command":"/bin/cat"}"#.utf8)
    let server = try JSONDecoder().decode(MCPServerConfig.self, from: json)
    #expect(server.enabled)
    #expect(!server.allowAnyTool && server.allowedTools.isEmpty)
    #expect(!server.permitsTool("inspect"))
    let misspelled = Data(
      #"{"id":"manual","transport":"stdio","command":"/bin/cat","allow_all_tools":true}"#.utf8)
    #expect(throws: ConfigurationError.self) {
      try JSONDecoder().decode(MCPServerConfig.self, from: misspelled)
    }
  }

  @Test
  func disableRetainsSettingsAndProfileReferencesWhileRemovalRejectsThem() throws {
    let server = MCPServerConfig(
      id: "manual", transport: .stdio, command: "/bin/cat", args: ["", "中 文", "--"],
      env: ["FIXTURE": "fixture-value"], exposure: .reexport, prefix: "manual",
      allowedTools: ["inspect"], requestTimeoutMs: 1234, toolRisks: ["inspect": .readOnly])
    let configuration = GatewayConfiguration(
      profiles: [.init(id: .chatGPTObserve, mcpServers: [server.id])],
      mcp: .init(servers: [server]))
    let disabled = try MCPRegistrationChange.enabled(id: server.id, false).applying(
      to: configuration)
    var expected = server
    expected.enabled = false
    #expect(disabled.mcp.servers == [expected])
    #expect(disabled.profiles == configuration.profiles)
    #expect(!disabled.mcp.servers[0].permitsTool("inspect"))
    #expect(throws: ConfigurationError.self) {
      try MCPRegistrationChange.remove(id: server.id).applying(to: disabled)
    }
    let restored = try MCPRegistrationChange.enabled(id: server.id, true).applying(to: disabled)
    #expect(restored == configuration)
    #expect(try GatewayConfiguration.load(text: disabled.exportedTOML()).mcp.servers == [expected])
  }

  @Test
  func disabledRegistrationNeverConnectsOrExposesTools() async throws {
    let server = MCPServerConfig(
      id: "manual", transport: .stdio, command: "/nonexistent/mcp-registration-fixture",
      exposure: .reexport, prefix: "manual", allowAnyTool: true, enabled: false)
    let client = MCPProxyClient()
    #expect(
      try client.connectionStatus(server: server).objectValue?["state"] == .string("disabled"))
    #expect(throws: (any Error).self) { try client.listTools(server: server) }
    let registry = GatewayToolRegistry(
      configuration: .fixture(mcp: .init(servers: [server])), mcpClient: client)
    let router = try GatewayProviderRouter(registry: registry)
    #expect(try !router.listTools().contains { $0.name.hasPrefix("manual.") })
    await client.shutdown()
    let validation = try await ComputerMCPProductContracts.validateMCPConnections(
      configuration: .init(mcp: .init(servers: [server])))
    #expect(
      validation
        == .array([
          .object([
            "id": .string(server.id), "state": .string("disabled"),
            "checked": .bool(false), "tools": .array([]),
          ])
        ]))
  }

  @Test
  func addsRejectDuplicatesAndConfigureDoesNotCreate() throws {
    let server = MCPServerConfig(id: "manual", transport: .stdio, command: "/bin/cat")
    let configuration = try MCPRegistrationChange.add(server).applying(to: .init())
    #expect(throws: ConfigurationError.self) {
      try MCPRegistrationChange.add(server).applying(to: configuration)
    }
    #expect(throws: (any Error).self) {
      try MCPRegistrationChange.configure(server).applying(to: .init())
    }
    #expect(
      try MCPRegistrationChange.remove(id: server.id).applying(to: configuration).mcp.servers
        .isEmpty)
  }

  @Test(arguments: [false, true])
  func disabledPolicyRejectsBothWildcardAndRegistrationGrants(wildcard: Bool) {
    let server = MCPServerConfig(
      id: "manual", transport: .stdio, command: "/bin/cat", allowAnyTool: true,
      toolRisks: ["inspect": .readOnly], enabled: false)
    let grant = ProfileGrant(
      id: .localAdmin, capabilityIDs: wildcard ? ["*"] : [], allowedCallers: [.localMCP],
      fullShellEnabled: true, mcpServerIDs: wildcard ? [] : [server.id])
    let policy = MCPToolAccessPolicy(
      configuration: .init(mcp: .init(servers: [server])), grant: grant, derivesObserveGrant: true)
    #expect(!policy.allows(.init(serverID: server.id, toolName: "inspect")))
    #expect(!policy.canDiscoverTools(on: server))
    #expect(!policy.permitsServer(server, capability: "mcp.resources.read"))
    #expect(!policy.isVisible(server))
  }
}
