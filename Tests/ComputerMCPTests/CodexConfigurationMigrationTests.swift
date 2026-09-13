import Foundation
import Testing

@testable import ComputerMCP

struct CodexConfigurationMigrationTests {
  @Test func hostConfigurationDoesNotSynthesizeExecutionSettings() throws {
    let base = URL(fileURLWithPath: "/tmp/codex-migration-config")
    let configuration = try GatewayConfiguration.load(text: "schema_version = 1\n", baseURL: base)
    #expect(configuration.codex == nil)
    #expect(try !configuration.exportedTOML().contains("[codex]"))
    #expect(
      throws: ConfigurationError.invalid("The source has no [codex] configuration to migrate.")
    ) {
      try export(configuration.exportedTOML(), base: base)
    }
  }

  @Test func embeddedExecutionRequiresExplicitMigrationBeforeRuntimeCreation() throws {
    #expect(throws: ConfigurationError.self) {
      try GatewayRuntime(
        configuration: .init(codex: .init(enabled: true, executable: "/nonexistent/codex")))
    }
  }
  @Test(arguments: [false, true], [CodexSandboxMode.readOnly, .workspaceWrite])
  func preservesConfigurationAndHostAuthority(enabled: Bool, sandbox: CodexSandboxMode) throws {
    let base = URL(fileURLWithPath: "/tmp/codex-migration-config")
    let original = GatewayConfiguration(
      profiles: [
        .init(
          id: .chatGPTOperate,
          capabilities: ["codex.app.thread.start", "codex.app.elevation.request"],
          workspaces: ["fixture"], allowedCallers: [.secureTunnel])
      ],
      codex: .init(
        enabled: enabled, executable: "/private/Fixture Tools/codex", experimentalAPI: false,
        appServerRequestTimeoutSeconds: 42, appServerAppListTimeoutSeconds: 43,
        appServerTerminationGraceMilliseconds: 123, appServerKillGraceMilliseconds: 456,
        appServerApprovalTimeoutSeconds: 87, appServerAutoApproveWorkspaceWrites: true,
        sandbox: sandbox, approvalPolicy: .onRequest, maxSessions: 3, maxEventsPerSession: 256),
      workspaceDirectory: base)
    let text = try original.exportedTOML()
    let migration = try export(text, base: base)
    var expectedHost = original
    expectedHost.codex = nil
    #expect(try GatewayConfiguration.load(text: migration.hostTOML, baseURL: base) == expectedHost)
    #expect(!migration.hostTOML.contains("[codex]"))
    #expect(try GatewayConfiguration.load(text: text, baseURL: base) == original)
    #expect(migration.adapterConfiguration == original.codex)
    #expect(migration.pluginSettings.enabled == enabled)
    #expect(migration.configurationDirectory == base.path)
    #expect(migration.sourceSHA256.count == 64)
    #expect(try export(text, base: base).sourceSHA256 == migration.sourceSHA256)
    #expect(try export(text + "\n", base: base).sourceSHA256 != migration.sourceSHA256)
    let settings = try #require(migration.pluginSettings.mcp["app-server"])
    #expect(settings.prefix == "")
    #expect(settings.exposure == .reexport)
    #expect(!settings.allowAnyTool)
    #expect(settings.allowedTools.count == 76)
    #expect(settings.hostServices)
    #expect(
      settings.args == [
        "--config", "/tmp/adapter config.json", "--state-directory", "/tmp/adapter-state",
      ])
    #expect(settings.toolRisks["codex.worktree.remove.perform"] == .destructive)
    #expect(settings.toolRisks["codex.app.methods.call"] == .workspaceWrite)
    #expect(settings.toolRisks["codex.app.thread.read"] == .readOnly)
    #expect(!settings.allowedTools.contains { $0.hasPrefix("codex.app.elevation.") })
    let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(migration))
    #expect(json.objectValue?["adapterConfiguration"]?.objectValue?["max_sessions"] == .number(3))
    #expect(json.objectValue?["pluginID"] == .string("codex"))
  }

  @Test(arguments: [
    (true, false, false, 60), (false, true, false, 6), (false, false, true, 10),
    (true, true, false, 66), (true, false, true, 70), (false, true, true, 16),
    (true, true, true, 76), (false, false, false, 0),
  ])
  func migrationContractMatchesEmbeddedProvider(
    appServer: Bool, exec: Bool, mcp: Bool, count: Int
  ) async throws {
    let configuration = GatewayConfiguration(
      codex: .init(
        enabled: false, executable: "/nonexistent/codex-migration-vendor",
        appServerEnabled: appServer, execEnabled: exec, mcpEnabled: mcp))
    let migration = try export(configuration.exportedTOML())
    let settings = try #require(migration.pluginSettings.mcp["app-server"])
    let entries = try CodexEmbeddedFixture.catalog()
    let descriptors = try entries.compactMap { entry -> CapabilityDescriptor? in
      let capability = try #require(entry.objectValue?["capability"])
      let value = try JSONDecoder().decode(
        CapabilityDescriptor.self, from: JSONEncoder().encode(capability))
      let enabled =
        value.id.hasPrefix("codex.exec.")
        ? exec : value.id.hasPrefix("codex.mcp.") ? mcp : appServer
      return enabled ? value : nil
    }
    #expect(settings.allowedTools.count == count)
    #expect(settings.allowedTools == descriptors.map(\.id).sorted())
    #expect(
      settings.toolRisks == Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0.risk) }))
    #expect(settings.hostServices == appServer)
    #expect(!migration.pluginSettings.enabled)
  }

  @Test(arguments: [
    ("relative.json", "/tmp/state"), ("/tmp/config", "state"),
    ("/tmp/state", "/tmp/state"), ("/tmp/state/codex.sqlite", "/tmp/state"),
    ("/tmp/config\0", "/tmp/state"),
  ])
  func rejectsAmbiguousDestinations(config: String, state: String) {
    #expect(throws: ConfigurationError.self) {
      try CodexConfigurationMigration(
        text: "", baseURL: URL(fileURLWithPath: "/tmp"),
        adapterConfigurationPath: config, stateDirectory: state)
    }
  }

  @Test func rejectsRelativeExecutableAndUnknownFields() {
    #expect(throws: ConfigurationError.self) {
      try export("schema_version = 1\n[codex]\nexecutable = './bin/codex'\n")
    }
    #expect(throws: ConfigurationError.self) {
      try export("schema_version = 1\n[codex]\nmisspelled_timeout = 3\n")
    }
  }

  @Test func existingPluginIdentityMustBeReconciled() {
    #expect(throws: ConfigurationError.self) {
      try CodexConfigurationMigration(
        text: "schema_version = 1\n[codex]\n", baseURL: URL(fileURLWithPath: "/tmp"),
        adapterConfigurationPath: "/tmp/config.json", stateDirectory: "/tmp/state",
        knownPluginMCPServerIDs: ["plugin-5-codex-app-server"])
    }
  }

  @Test func exactProfileGrantsAuthorizeTheSameNamesAfterComposition() throws {
    let migration = try export("schema_version = 1\n[codex]\nenabled = true\n")
    let settings = try #require(migration.pluginSettings.mcp["app-server"])
    var host = try GatewayConfiguration.load(text: migration.hostTOML)
    host.mcp.servers = [
      .init(
        id: "plugin-5-codex-app-server", transport: .stdio, command: "/nonexistent/adapter",
        exposure: settings.exposure, prefix: settings.prefix, allowedTools: settings.allowedTools,
        toolRisks: settings.toolRisks)
    ]
    let grant = ProfileGrant(
      id: .chatGPTOperate, capabilityIDs: ["codex.app.thread.read"],
      workspaceIDs: ["fixture"], allowedCallers: [.secureTunnel])
    let access = MCPToolAccessPolicy(configuration: host, grant: grant, derivesObserveGrant: false)
    #expect(
      access.allows(.init(serverID: "plugin-5-codex-app-server", toolName: "codex.app.thread.read"))
    )
    #expect(
      !access.allows(
        .init(serverID: "plugin-5-codex-app-server", toolName: "codex.app.thread.start")))
    #expect(
      !access.allows(
        .init(serverID: "plugin-5-codex-app-server", toolName: "codex.protocol.methods.list")))
    #expect(!access.allows(.init(serverID: "other-provider", toolName: "codex.app.thread.read")))
    #expect(
      !access.allows(
        .init(serverID: "plugin-5-codex-app-server", toolName: "codex.app.elevation.approve")))
  }

  private func export(_ text: String, base: URL = URL(fileURLWithPath: "/tmp")) throws
    -> CodexConfigurationMigration
  {
    try CodexConfigurationMigration(
      text: text, baseURL: base,
      adapterConfigurationPath: "/tmp/adapter config.json", stateDirectory: "/tmp/adapter-state")
  }
}
