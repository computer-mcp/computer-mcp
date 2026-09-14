import Foundation
import Testing

@testable import ComputerMCP

struct PluginResolverTests {
  @Test
  func hostSettingsKeepTheirPortableFormatInsideCanonicalReports() throws {
    let settings = PluginSettings(
      enabled: true,
      mcp: [
        "native_tools": .init(
          registrationID: "native_registration", exposure: .reexport, prefix: "",
          allowedTools: ["inspect_with_underscores"],
          toolRisks: ["inspect_with_underscores": .readOnly],
          args: ["", "--", "参数"], hostServices: true),
        "http_tools": .init(
          allowAnyTool: true,
          authentication: .init(
            endpoint: "http://127.0.0.1:1/mcp", keychainAccount: "fixture-credential")),
      ],
      cli: ["format_swift": .init(registrationID: "format_registration", allowAnyArgs: true)],
      skills: ["skill_guidance": .init(registrationID: "guidance_registration")],
      dependencyExecutables: ["native_vendor": "/usr/bin/printf"])
    let data = try CanonicalJSONCoding.encoder().encode(["sample_plugin": settings])
    let report = try JSONDecoder().decode(JSONValue.self, from: data)
    let document = try #require(report.objectValue?["sample_plugin"])
    #expect(document == (try JSONValue.encoded(settings)))
    #expect(
      document.objectValue?["dependencyExecutables"]?.objectValue?["native_vendor"]
        == .string("/usr/bin/printf"))
    let native = try #require(
      document.objectValue?["mcp"]?.objectValue?["native_tools"]?.objectValue)
    #expect(native["registrationID"] == .string("native_registration"))
    #expect(native["hostServices"] == .bool(true))
    #expect(native["allowedTools"] == .array([.string("inspect_with_underscores")]))
    #expect(
      document.objectValue?["mcp"]?.objectValue?["http_tools"]?.objectValue?["authentication"]?
        .objectValue?["keychain_account"] == .string("fixture-credential"))
    let restored = try JSONDecoder().decode(
      PluginSettings.self, from: JSONEncoder().encode(document))
    #expect(restored == settings)
  }

  @Test
  func httpContributionRejectsProcessArguments() throws {
    let fixture = try CompositionFixture(
      text: PluginManifestTests.header + """

        [[mcp]]
        id = 'native'
        transport = 'http'
        url = 'http://127.0.0.1:1/mcp'
        """)
    defer { fixture.cleanup() }
    var settings = fixture.settings
    settings.mcp["native"]?.args = []
    #expect(throws: ConfigurationError.self) { try fixture.resolve(settings: settings) }
  }

  @Test(arguments: [PluginSourceKind.bundled, .artifact, .development])
  func hostArgumentsOverrideDefaultsWithoutChangingPackageOrGrants(kind: PluginSourceKind) throws {
    let fixture = try CompositionFixture()
    defer { fixture.cleanup() }
    var settings = fixture.settings
    let values = ["--codex-executable", "/tmp/My Codex/执行", "", "a\nb", "--", "-1"]
    settings.mcp["native"]?.args = values
    let decoded = try JSONDecoder().decode(
      PluginSettings.self, from: JSONEncoder().encode(settings))
    let resolved = try fixture.resolve(kind: kind, settings: decoded)
    #expect(resolved.mcpServers[0].args == values)
    #expect(!resolved.mcpServers[0].allowAnyTool)
    #expect(fixture.package.manifest.mcp[0].args == ["mcp"])
    settings.mcp["native"]?.args = []
    #expect(try fixture.resolve(settings: settings).mcpServers[0].args == [])
    settings.mcp["native"]?.args = nil
    #expect(try fixture.resolve(settings: settings).mcpServers[0].args == ["mcp"])
  }

  @Test(arguments: [
    ["nul\0argument"], Array(repeating: "", count: 1_025), [String(repeating: "x", count: 262_145)],
  ])
  func invalidHostArgumentsAreRejected(args: [String]) {
    #expect(throws: ConfigurationError.self) {
      try PluginSettings(mcp: ["native": .init(args: args)]).validate()
    }
  }

  @Test
  func sparseHostSettingsDecodeWithSafeDefaultsAndRejectUnknownFields() throws {
    let settings = try JSONDecoder().decode(
      PluginSettings.self, from: Data(#"{"mcp":{"native":{"allowedTools":["inspect"]}}}"#.utf8))
    #expect(!settings.enabled)
    #expect(settings.mcp["native"]?.allowedTools == ["inspect"])
    #expect(settings.mcp["native"]?.allowAnyTool == false)
    #expect(throws: PluginManifestError.self) {
      try JSONDecoder().decode(
        PluginSettings.self, from: Data(#"{"mcp":{"native":{"allow_any_tool":true}}}"#.utf8))
    }
    #expect(throws: ConfigurationError.self) {
      try JSONDecoder().decode(
        PluginSettings.self, from: Data(#"{"dependencyExecutables":{"vendor":"../vendor"}}"#.utf8))
    }
  }
  @Test(arguments: [PluginSourceKind.bundled, .artifact, .development])
  func allSourcesResolveThroughIdenticalDescriptorsWithoutGrantingAccess(kind: PluginSourceKind)
    throws
  {
    let fixture = try CompositionFixture()
    defer { fixture.cleanup() }
    let resolved = try fixture.resolve(kind: kind)
    #expect(resolved.mcpServers.count == 1)
    #expect(resolved.cliCommands.count == 1)
    #expect(resolved.skillRoots.count == 1)
    #expect(!resolved.mcpServers[0].allowAnyTool)
    #expect(resolved.mcpServers[0].allowedTools.isEmpty)
    #expect(!resolved.cliCommands[0].allowAnyArgs)
    #expect(resolved.origins.count == 3)
    #expect(resolved.origins.values.allSatisfy { $0.source.kind == kind })
    #expect(resolved.diagnostics.isEmpty)
    let direct = MCPServerConfig(
      id: "native", transport: .stdio, command: "/usr/bin/printf", args: ["mcp"], prefix: "native")
    #expect(resolved.mcpServers[0] == direct)
  }

  @Test(arguments: [PluginSourceKind.bundled, .artifact, .development])
  func explicitEmptyPrefixPreservesNativeNamesWithoutChangingTheDefault(kind: PluginSourceKind)
    throws
  {
    let fixture = try CompositionFixture()
    defer { fixture.cleanup() }
    var settings = fixture.settings
    settings.mcp["native"]?.exposure = .reexport
    settings.mcp["native"]?.prefix = ""
    let decoded = try JSONDecoder().decode(
      PluginSettings.self, from: JSONEncoder().encode(settings))
    #expect(try fixture.resolve(kind: kind, settings: decoded).mcpServers[0].prefix == "")
    settings.mcp["native"]?.prefix = nil
    #expect(try fixture.resolve(kind: kind, settings: settings).mcpServers[0].prefix == "native")
    #expect(fixture.package.manifest.mcp[0].prefix == nil)
  }

  @Test
  func disabledPackageDoesNotAddRegistrationsOrProbeItsDependencies() throws {
    let fixture = try CompositionFixture()
    defer { fixture.cleanup() }
    let resolved = try fixture.resolve(settings: PluginSettings(enabled: false), bindings: [:])
    #expect(
      resolved.mcpServers.isEmpty && resolved.cliCommands.isEmpty && resolved.skillRoots.isEmpty)
    #expect(resolved.origins.isEmpty && resolved.diagnostics.isEmpty)
  }

  @Test
  func missingExecutableIsDiagnosedPerComponentAndDoesNotSuppressSkills() throws {
    let fixture = try CompositionFixture()
    defer { fixture.cleanup() }
    let resolved = try fixture.resolve(bindings: [:])
    #expect(resolved.mcpServers.isEmpty && resolved.cliCommands.isEmpty)
    #expect(resolved.skillRoots.count == 1)
    #expect(resolved.diagnostics.count == 2)
    #expect(
      resolved.diagnostics.allSatisfy {
        $0.code == .dependencyUnavailable && $0.dependencyID == "vendor"
      })
    #expect(
      resolved.diagnostics.allSatisfy { $0.instructions == "Install the vendor CLI separately." })
  }

  @Test
  func unavailableBoundInterpreterDoesNotFallbackOrSuppressSkills() throws {
    let fixture = try CompositionFixture()
    defer { fixture.cleanup() }
    let script = fixture.root.appendingPathComponent("broken")
    try "#!/usr/bin/env missing-runtime\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    var settings = fixture.settings
    settings.dependencyExecutables = ["vendor": script.path]
    let state = PluginStoreSnapshot(settings: [fixture.package.manifest.id: settings])
    let resolution = try PluginStore.resolve(
      snapshot: state, bundled: [fixture.package], hostVersion: PluginVersion("1.0.29"),
      architecture: "arm64", searchDirectories: [URL(fileURLWithPath: "/usr/bin")],
      environment: ["PATH": fixture.root.path])
    let plugin = try #require(resolution.plugins.first)
    #expect(plugin.mcpServers.isEmpty && plugin.cliCommands.isEmpty)
    #expect(plugin.skillRoots.count == 1)
    #expect(plugin.diagnostics.count == 2)
    #expect(
      plugin.diagnostics.allSatisfy {
        $0.code == .dependencyUnavailable && $0.executable?.path == script.path
          && $0.executable?.status == .interpreterUnavailable
      })
    #expect(
      state.settings[fixture.package.manifest.id]?.dependencyExecutables["vendor"] == script.path)
  }

  @Test
  func unverifiedInterpreterIsReportedWithoutRejectingTheRegistration() throws {
    let fixture = try CompositionFixture()
    defer { fixture.cleanup() }
    let script = fixture.root.appendingPathComponent("custom")
    try "#!/usr/bin/env -i sh\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let plugin = try fixture.resolve(bindings: ["vendor": script])
    #expect(plugin.mcpServers.count == 1 && plugin.cliCommands.count == 1)
    #expect(plugin.diagnostics.count == 2)
    #expect(plugin.diagnostics.allSatisfy { $0.code == .executableUnverified })
  }

  @Test
  func registrationIDsDoNotAliasWhenPackageIDsContainSeparators() throws {
    let first = try CompositionFixture(
      text: "id = 'a-b'\nname = 'First'\nversion = '1.0.0'\n[[skills]]\nid = 'c'\npath = 'skills'")
    defer { first.cleanup() }
    let second = try CompositionFixture(
      text: "id = 'a'\nname = 'Second'\nversion = '1.0.0'\n[[skills]]\nid = 'b-c'\npath = 'skills'")
    defer { second.cleanup() }
    let settings = PluginSettings(enabled: true)
    let a = try first.resolve(settings: settings)
    let b = try second.resolve(settings: settings)
    #expect(a.skillRoots[0].id != b.skillRoots[0].id)
    let composed = try GatewayPluginComposition(
      configuration: GatewayConfiguration(), plugins: [a, b])
    #expect(composed.origins.count == 2)
  }

  @Test
  func sourceExportAndUserRegistrationsSurviveCompositionAndWithdrawal() throws {
    let fixture = try CompositionFixture()
    defer { fixture.cleanup() }
    let source = GatewayConfiguration(
      cli: .init(commands: [.init(id: "personal", executable: "/bin/echo")]),
      skills: .init(enabled: true, roots: [.init(id: "personal", path: fixture.root.path)]))
    let before = try source.exportedTOML()
    let selected = try GatewayPluginComposition(configuration: source, plugins: [fixture.resolve()])
    #expect(selected.runtimeConfiguration.cli.commands.count == 2)
    #expect(selected.runtimeConfiguration.skills.roots.count == 2)
    #expect(selected.runtimeConfiguration.mcp.servers.count == 1)
    #expect(try selected.sourceConfiguration.exportedTOML() == before)
    let withdrawn = try GatewayPluginComposition(
      configuration: selected.sourceConfiguration, plugins: [])
    #expect(withdrawn.runtimeConfiguration == source)
    #expect(withdrawn.origins.isEmpty)
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("skills/example/SKILL.md").path))
    #expect(FileManager.default.isExecutableFile(atPath: "/usr/bin/printf"))
  }

  @Test
  func duplicateSourcesManualIDsAndExposurePrefixesFailClosed() throws {
    let fixture = try CompositionFixture()
    defer { fixture.cleanup() }
    let plugin = try fixture.resolve()
    #expect(throws: ConfigurationError.self) {
      try GatewayPluginComposition(
        configuration: GatewayConfiguration(), plugins: [plugin, plugin])
    }
    let source = GatewayConfiguration(
      mcp: .init(servers: [.init(id: "native", transport: .stdio, command: "/bin/cat")]))
    #expect(throws: ConfigurationError.self) {
      try GatewayPluginComposition(configuration: source, plugins: [plugin])
    }
    var settings = fixture.settings
    settings.mcp["native"] = .init(
      registrationID: "other", exposure: .reexport, prefix: "shared", allowAnyTool: true)
    let duplicatePrefix = try fixture.resolve(settings: settings)
    let exporting = GatewayConfiguration(
      mcp: .init(servers: [
        .init(
          id: "manual", transport: .stdio, command: "/bin/cat", exposure: .reexport,
          prefix: "shared")
      ]))
    #expect(throws: ConfigurationError.self) {
      try GatewayPluginComposition(configuration: exporting, plugins: [duplicatePrefix])
    }
  }

  @Test
  func hostSelectionsAreValidatedAndUnusedOverridesSurviveAnUpgrade() throws {
    let fixture = try CompositionFixture()
    defer { fixture.cleanup() }
    var settings = fixture.settings
    settings.mcp["native"] = .init(
      registrationID: "native", allowAnyTool: true, allowedTools: ["inspect"])
    #expect(throws: ConfigurationError.self) {
      try GatewayPluginComposition(
        configuration: GatewayConfiguration(), plugins: [fixture.resolve(settings: settings)])
    }
    settings.mcp["native"] = .init(registrationID: "native", allowedTools: ["inspect"])
    settings.mcp["previous-component"] = .init(allowAnyTool: true)
    let encoded = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(PluginSettings.self, from: encoded)
    #expect(decoded == settings)
    let plugin = try fixture.resolve(settings: decoded)
    #expect(plugin.mcpServers[0].allowedTools == ["inspect"])
    #expect(plugin.mcpServers.count == 1)
    #expect(settings.mcp["previous-component"]?.allowAnyTool == true)
  }

  @Test
  func explicitRawCLIUsesExistingArgvRunnerAndStructuredSourcesCannotBypassConstraints() throws {
    let fixture = try CompositionFixture()
    defer { fixture.cleanup() }
    var settings = fixture.settings
    settings.cli["commands"] = .init(registrationID: "commands", allowAnyArgs: true)
    let plugin = try fixture.resolve(settings: settings)
    let composition = try GatewayPluginComposition(
      configuration: GatewayConfiguration(workspaceDirectory: fixture.root), plugins: [plugin])
    let registry = GatewayToolRegistry(
      configuration: composition.runtimeConfiguration, mcpClient: CompositionCatalogClient())
    let output = try registry.callTool(
      name: "cli.exec",
      arguments: .object([
        "id": .string("commands"), "argv": .array([.string("%s"), .string("空 格;$(no-execution)")]),
      ]))
    let payload = try #require(output.objectValue?["structuredContent"]?.objectValue?["result"])
    #expect(payload.objectValue?["stdout"] == .string("空 格;$(no-execution)"))
    #expect(payload.objectValue?["exit_code"] == .number(0))
    #expect(output.objectValue?["isError"] == .bool(false))
    let structured = try CompositionFixture(text: PluginManifestTests.combined)
    defer { structured.cleanup() }
    #expect(throws: ConfigurationError.self) { try structured.resolve(settings: settings) }
  }

  @Test(arguments: [false, true])
  func pluginToolsUseTheSameProfileSelectionAndGenericCallPolicy(all: Bool) async throws {
    let fixture = try CompositionFixture()
    defer { fixture.cleanup() }
    var settings = fixture.settings
    settings.mcp["native"] = .init(
      registrationID: "native", exposure: .reexport,
      prefix: "package", allowAnyTool: all, allowedTools: all ? [] : ["inspect"],
      toolRisks: ["inspect": .readOnly])
    let plugin = try fixture.resolve(settings: settings)
    let configuration = GatewayConfiguration(
      runtime: .init(caller: .secureTunnel, profileID: .chatGPTOperate),
      profiles: [.init(id: .chatGPTOperate, mcpServers: ["native"])],
      mcp: .init(servers: [
        .init(id: "private", transport: .stdio, command: "/bin/cat", allowAnyTool: true)
      ]))
    let runtime = try GatewayRuntime(
      configuration: configuration,
      registeredWorkspaces: [
        .init(id: "fixture", displayName: "Fixture", rootPath: fixture.root.path)
      ],
      mcpClient: CompositionCatalogClient(), plugins: [plugin])
    do {
      let tools = try runtime.listTools().map(\.name)
      #expect(tools.contains("package.inspect"))
      #expect(tools.contains("package.future") == all)
      _ = try runtime.callTool(name: "package.inspect", arguments: .object([:]))
      _ = try runtime.callTool(
        name: "mcp.tools.call",
        arguments: .object([
          "server": .string("native"), "tool": .string("inspect"), "arguments": .object([:]),
        ]))
      #expect(throws: (any Error).self) {
        try runtime.callTool(
          name: "mcp.tools.call",
          arguments: .object([
            "server": .string("private"), "tool": .string("inspect"), "arguments": .object([:]),
          ]))
      }
      #expect(runtime.pluginOrigins.count == 3)
      #expect(runtime.pluginDiagnostics.isEmpty)
      await runtime.shutdown()
    } catch {
      await runtime.shutdown()
      throw error
    }
  }

  @Test
  func incompatibleHostDoesNotActivateAnyContribution() throws {
    let fixture = try CompositionFixture(
      text: PluginManifestTests.header + """
        [compatibility]
        minimum_host = '99.0.0'
        [[skills]]
        id = 'guidance'
        path = 'skills'
        """)
    defer { fixture.cleanup() }
    let resolved = try fixture.resolve()
    #expect(resolved.origins.isEmpty)
    #expect(resolved.diagnostics.map(\.code) == [.hostIncompatible])
  }
}

private struct CompositionCatalogClient: DownstreamMCPClient {
  func makeScopedClient(
    workingDirectory: URL, environment: [String: String], hostContext: MCPHostContext?
  )
    -> any DownstreamMCPClient
  { self }

  func listTools(server: MCPServerConfig) throws -> [MCPTool] {
    ["inspect", "future"].map {
      MCPTool(name: $0, description: $0, inputSchema: .object(["type": .string("object")]))
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
  func readResource(server: MCPServerConfig, uri: String) throws -> JSONValue { .null }
  func listPrompts(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func getPrompt(server: MCPServerConfig, name: String, arguments: [String: String]?) throws
    -> JSONValue
  { .null }
}

private struct CompositionFixture {
  let root: URL
  let package: PluginPackage
  let settings = PluginSettings(
    enabled: true,
    mcp: ["native": .init(registrationID: "native")],
    cli: ["commands": .init(registrationID: "commands")],
    skills: ["guidance": .init(registrationID: "guidance")])

  init(text: String? = nil) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "plugin-composition-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("skills/example"), withIntermediateDirectories: true)
    let content =
      text
      ?? PluginManifestTests.combined.replacingOccurrences(
        of: "tree = { kind = 'introspection', args = ['schema', '--json'] }\n", with: "")
    try content.write(
      to: root.appendingPathComponent(PluginManifest.filename), atomically: true, encoding: .utf8)
    try "---\nname: example\ndescription: Example guidance.\n---\nRead without executing scripts.\n"
      .write(
        to: root.appendingPathComponent("skills/example/SKILL.md"), atomically: true,
        encoding: .utf8)
    package = try PluginPackage.load(at: root)
  }

  func resolve(
    kind: PluginSourceKind = .development, settings: PluginSettings? = nil,
    bindings: [String: URL] = ["vendor": URL(fileURLWithPath: "/usr/bin/printf")]
  ) throws -> ResolvedPlugin {
    try PluginResolver.resolve(
      package: package, source: .init(kind: kind, root: package.root),
      settings: settings ?? self.settings, dependencyExecutables: bindings,
      hostVersion: PluginVersion("1.0.29"), architecture: "arm64")
  }

  func cleanup() { try? FileManager.default.removeItem(at: root) }
}
