import ComputerMCPDownstream
import ComputerMCPMacOS
import ComputerMCPProcess
import ComputerMCPTestSupport
import ComputerMCPToolKit
import ComputerMCPToolsCLI
import ComputerMCPToolsFiles
import ComputerMCPToolsGit
import ComputerMCPToolsMCP
import ComputerMCPToolsShell
import ComputerMCPToolsSkills
import ComputerMCPToolsStructured
import ComputerMCPToolsSystem
import ComputerMCPToolsWorkspace
import Foundation
import Testing

@testable import ComputerMCP
@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore

struct BuiltinToolCatalogSnapshotTests {
  @Test(arguments: [(false, true), (true, true), (false, false), (true, false)])
  func shellAndProcessRoutesKeepSeparateProviderOwnership(
    shellEnabled: Bool, hasCLI: Bool
  ) async throws {
    let configuration = GatewayConfiguration.fixture(
      cli: .init(commands: hasCLI ? [.init(id: "fixture", executable: "/unused/catalog-cli")] : []),
      mcp: .init(), policy: .init(shellEnabled: shellEnabled))
    let registry = MacOSToolProviders().makeProviders(
      configuration: configuration, commandRunner: RecordingCommandRunner(),
      processManager: ManagedProcessRegistry(), shellManager: SubprocessShellRuntime(),
      mcpClient: CatalogDiscoveryStub(),
      hostContext: .init(
        runtimeID: UUID(), context: .init(caller: .localMCP, profileID: .localAdmin),
        workspaceID: "catalog", rootURL: configuration.workspaceDirectory, readOnly: false))
    do {
      let snapshot = try GatewayToolCatalogSnapshot(providers: registry.providers())
      for name in ["process.spawn", "process.list", "process.read", "process.cancel"] {
        #expect(snapshot.routes[name]?.provider.id == (hasCLI ? "process" : nil))
      }
      for name in [
        "shell.run", "shell.spawn", "shell.list", "shell.read", "shell.write", "shell.cancel",
      ] {
        #expect(snapshot.routes[name]?.provider.id == (shellEnabled ? "shell" : nil))
      }
      #expect(snapshot.routes["cli.exec"]?.provider.id == (hasCLI ? "cli" : nil))
      await registry.shutdown()
    } catch {
      await registry.shutdown()
      throw error
    }
  }

  @Test
  func builtinDefinitionsDeclareMatchingCapabilityIDs() throws {
    let environment = ToolEnvironment(
      configuration: .fixture(
        policy: .init(shellEnabled: true),
        builtin: .init(enabled: DefaultGatewayConfiguration.enabledBuiltinCapabilities),
        skills: .init(enabled: true)))
    let providers: [any GatewayToolProvider] = [
      WorkspaceToolProvider(environment: environment), FilesToolProvider(environment: environment),
      SkillsToolProvider(environment: environment),
      StructuredToolProvider(environment: environment),
      GitToolProvider(environment: environment), CLIToolProvider(environment: environment),
      ProcessToolProvider(environment: environment), ShellToolProvider(environment: environment),
      SystemToolProvider(environment: environment), NetworkToolProvider(environment: environment),
      MacOSToolProvider(environment: environment),
      MCPToolProvider(environment: environment, mcpClient: CatalogDiscoveryStub()),
    ]
    let registry = MacOSToolProviders().makeProviders(
      toolEnvironment: environment, mcpClient: CatalogDiscoveryStub())
    let snapshot = try GatewayToolCatalogSnapshot(providers: registry.providers())
    let definitions = try providers.flatMap { provider in
      try provider.definitions().map { definition in
        let route = try #require(snapshot.routes[definition.tool.name])
        #expect(route.provider.id == provider.id)
        #expect(ObjectIdentifier(type(of: route.provider)) == ObjectIdentifier(type(of: provider)))
        #expect(route.tool.json == definition.tool.json)
        #expect(route.capability == definition.capability)
        #expect(definition.tool.annotations != nil)
        return definition
      }
    }

    #expect(definitions.count == 239)
    #expect(Set(definitions.map(\.tool.name)).count == definitions.count)
    for definition in definitions {
      #expect(definition.capability.id == definition.tool.name)
      #expect(definition.tool.mcpReference == nil)
    }
  }

  @Test
  func builtinProviderNamespacesAreDisjointAndCoverEveryDefinition() async throws {
    let environment = ToolEnvironment(
      configuration: .fixture(
        policy: .init(shellEnabled: true),
        builtin: .init(enabled: DefaultGatewayConfiguration.enabledBuiltinCapabilities),
        skills: .init(enabled: true)))
    let registry = MacOSToolProviders().makeProviders(
      toolEnvironment: environment, mcpClient: CatalogDiscoveryStub())
    do {
      let providers = try registry.providers().filter { $0.id != "computer-use" }
      #expect(providers.count == 12)
      var namespaces: Set<String> = []
      for provider in providers {
        #expect(!provider.namespaces.isEmpty, "Provider: \(provider.id)")
        for namespace in provider.namespaces {
          #expect(namespaces.insert(namespace).inserted, "Shared namespace: \(namespace)")
        }
        let definitions = try provider.definitions()
        #expect(!definitions.isEmpty, "Provider: \(provider.id)")
        for definition in definitions {
          #expect(
            provider.namespaces.contains { definition.tool.name.hasPrefix("\($0).") },
            "Tool \(definition.tool.name) must belong to provider \(provider.id)")
        }
      }
      await registry.shutdown()
    } catch {
      await registry.shutdown()
      throw error
    }
  }

  @Test
  func completeHostCatalogMatchesReviewedSnapshot() async throws {
    let workspace = try ScopedTemporaryDirectory()
    let configuration = GatewayConfiguration(
      runtime: .init(caller: .localMCP, profileID: .localAdmin),
      policy: .init(shellEnabled: true),
      profiles: [
        .init(
          id: .localAdmin, capabilities: ["*"], workspaces: ["catalog"],
          allowedCallers: [.localMCP], fullShellEnabled: true, mode: .localFullAccess)
      ],
      cli: .init(commands: [.init(id: "fixture", executable: "/unused/catalog-cli")]),
      mcp: .init(servers: [.init(id: "fixture", transport: .stdio, command: "/unused/catalog-mcp")]
      ),
      builtin: .init(enabled: DefaultGatewayConfiguration.enabledBuiltinCapabilities),
      skills: .init(enabled: true, roots: [.init(id: "fixture", path: workspace.url.path)]),
      workspaceDirectory: workspace.url)
    try configuration.validate()
    // Runtime composition supplies core tools, workspace schemas, Computer Use and management.
    // Discovery has no plugin sources, CLI trees or downstream tool contributions.
    let runtime = try await GatewayRuntime.make(
      configuration: configuration, database: GatewayDatabase(inMemory: ()),
      registeredWorkspaces: [
        .init(id: "catalog", displayName: "Catalog", rootPath: workspace.url.path)
      ],
      platform: MacOSPlatform.services, mcpClient: CatalogDiscoveryStub(), plugins: [],
      bundledPlugins: .init(packages: [], issues: []),
      remoteManagement: .init(call: { _, _, _ in
        throw GatewayToolError.executionFailed("Catalog discovery must not execute management.")
      }))
    let actual: [String: JSONValue]
    do {
      let tools = try runtime.listTools(context: .empty)
      try #require(Set(tools.map(\.name)).count == tools.count)
      actual = try Dictionary(
        uniqueKeysWithValues: tools.map { tool in
          let descriptor = try runtime.capabilityDescriptor(named: tool.name)
          var fields = try #require(tool.json.objectValue)
          for field in ["outputSchema", "annotations", "_meta"] where fields[field] == nil {
            fields[field] = .null
          }
          fields["capability"] = .object([
            "risk": .string(descriptor.risk.rawValue),
            "workspaceRequirement": .string(descriptor.workspaceRequirement.rawValue),
            "localOnly": .bool(descriptor.localOnly), "usesNetwork": .bool(descriptor.usesNetwork),
          ])
          return (tool.name, .object(fields))
        })
      await runtime.shutdown()
    } catch {
      await runtime.shutdown()
      throw error
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(actual) + Data("\n".utf8)
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/builtin-tool-catalog.json")
    if ProcessInfo.processInfo.environment["COMPUTER_MCP_UPDATE_CATALOG_SNAPSHOT"] == "1" {
      try data.write(to: fixture, options: .atomic)
      return
    }
    let expectedData = try Data(contentsOf: fixture)
    let expected = try JSONDecoder().decode([String: JSONValue].self, from: expectedData)
    let differences = Self.differences(expected: expected, actual: actual)
    #expect(
      differences.isEmpty, "Builtin catalog differences:\n\(differences.joined(separator: "\n"))")
    if differences.isEmpty {
      #expect(expectedData == data, "Catalog JSON must use sorted keys and canonical formatting.")
    }
  }

  private static func differences(expected: [String: JSONValue], actual: [String: JSONValue])
    -> [String]
  {
    let old = Set(expected.keys)
    let new = Set(actual.keys)
    return new.subtracting(old).sorted().map { "Added: \($0)" }
      + old.subtracting(new).sorted().map { "Removed: \($0)" }
      + old.intersection(new).sorted().compactMap { name in
        guard expected[name] != actual[name] else { return nil }
        let before = expected[name]?.objectValue ?? [:]
        let after = actual[name]?.objectValue ?? [:]
        let fields = Set(before.keys).union(after.keys).sorted().filter { before[$0] != after[$0] }
        return "Changed: \(name): \(fields.joined(separator: ", "))"
      }
  }
}

private struct CatalogDiscoveryStub: DownstreamMCPClient {
  func makeScopedClient(
    workingDirectory: URL, environment: [String: String], hostContext: (any MCPHostEnvironment)?
  ) -> any DownstreamMCPClient { self }
  func listTools(server: MCPServerConfig, context: InvocationContext) throws -> [MCPTool] { [] }
  func callTool(
    server: MCPServerConfig, name: String, arguments: JSONValue, context: InvocationContext
  ) throws -> JSONValue {
    throw GatewayToolError.executionFailed("Catalog discovery must not execute a downstream call.")
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
