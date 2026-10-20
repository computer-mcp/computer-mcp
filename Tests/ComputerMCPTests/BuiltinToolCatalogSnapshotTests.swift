import ComputerMCPMacOS
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCP
@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore

struct BuiltinToolCatalogSnapshotTests {
  @Test
  func builtinDefinitionsDeclareMatchingCapabilityIDs() {
    let definitions = GatewayToolRegistry.gatewayDefinitions(
      shellEnabled: true,
      builtins: Set(DefaultGatewayConfiguration.enabledBuiltinCapabilities),
      skillsEnabled: true,
      hasCLIProviders: true,
      hasMCPProviders: true,
      toolMeta: nil)

    #expect(definitions.count == 239)
    #expect(Set(definitions.map(\.tool.name)).count == definitions.count)
    for definition in definitions {
      #expect(definition.capability.id == definition.tool.name)
      #expect(definition.tool.mcpReference == nil)
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
      let tools = try runtime.listTools()
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
    workingDirectory: URL, environment: [String: String], hostContext: MCPHostContext?
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
