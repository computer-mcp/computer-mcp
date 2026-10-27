import ComputerMCPDelivery
import ComputerMCPDownstream
import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPProcess
import ComputerMCPTestSupport
import ComputerMCPToolKit
import ComputerMCPToolsCLI
import ComputerMCPToolsFiles
import ComputerMCPToolsGit
import ComputerMCPToolsMCP
import ComputerMCPToolsProject
import ComputerMCPToolsShell
import ComputerMCPToolsSkills
import ComputerMCPToolsStructured
import ComputerMCPToolsSystem
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPControlPlane
@testable import ComputerMCPCore
@testable import ComputerMCPGateway

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

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
      processManager: ManagedProcessRegistry(launcher: testExecutionLauncher()),
      shellManager: ShellSessionRuntime(launcher: testExecutionLauncher()),
      mcpClient: CatalogDiscoveryStub(),
      hostContext: .init(
        runtimeID: UUID(), context: .init(caller: .localMCP, profileID: .localAdmin),
        projectID: "catalog", rootURL: configuration.projectDirectory, readOnly: false))
    do {
      let snapshot = try GatewayToolCatalogSnapshot(providers: registry.providers())
      for name in [
        "process.spawn", "process.list", "process.read", "process.write", "process.cancel",
      ] {
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
      launcher: testExecutionLauncher(),
      configuration: .fixture(
        policy: .init(shellEnabled: true),
        builtin: .init(enabled: DefaultGatewayConfiguration.enabledBuiltinCapabilities),
        skills: .init(enabled: true)))
    let providers: [any GatewayToolProvider] = [
      DeliveryToolProvider(environment: environment),
      ProjectToolProvider(environment: environment), FilesToolProvider(environment: environment),
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

    #expect(definitions.count == 242)
    #expect(Set(definitions.map(\.tool.name)).count == definitions.count)
    for definition in definitions {
      #expect(definition.capability.id == definition.tool.name)
      #expect(definition.tool.mcpReference == nil)
    }
  }

  @Test
  func builtinProviderNamespacesAreDisjointAndCoverEveryDefinition() async throws {
    let environment = ToolEnvironment(
      launcher: testExecutionLauncher(),
      configuration: .fixture(
        policy: .init(shellEnabled: true),
        builtin: .init(enabled: DefaultGatewayConfiguration.enabledBuiltinCapabilities),
        skills: .init(enabled: true)))
    let registry = MacOSToolProviders().makeProviders(
      toolEnvironment: environment, mcpClient: CatalogDiscoveryStub())
    do {
      let providers = try registry.providers().filter { $0.id != "computer-use" }
      #expect(providers.count == 13)
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
    let project = try ScopedTemporaryDirectory()
    let configuration = GatewayConfiguration(
      runtime: .init(caller: .localMCP, profileID: .localAdmin),
      policy: .init(shellEnabled: true),
      profiles: [
        .init(
          id: .localAdmin,
          permissions: fixturePermissions([
            .machineInformation: .granted(.access), .skills: .granted(.access),
            .screen: .granted(.access), .desktopControl: .granted(.access),
            .unifiedLogs: .granted(.access), .localNetwork: .granted(.access),
            .project("catalog"): .granted(.write), .mcpServer("*"): .granted(.all),
            .plugin("*"): .granted(.use),
          ]), fullAccess: true, allowedCallers: [.localMCP])
      ],
      cli: .init(commands: [.init(id: "fixture", executable: "/unused/catalog-cli")]),
      mcp: .init(servers: [.init(id: "fixture", transport: .stdio, command: "/unused/catalog-mcp")]
      ),
      builtin: .init(enabled: DefaultGatewayConfiguration.enabledBuiltinCapabilities),
      skills: .init(enabled: true, roots: [.init(id: "fixture", path: project.url.path)]),
      projectDirectory: project.url)
    try configuration.validate()
    // Runtime composition supplies core tools, project schemas, Computer Use and management.
    // Discovery has no plugin sources, CLI trees or downstream tool contributions.
    let runtime = try await GatewayRuntime.make(
      configuration: configuration,
      context: .init(
        caller: .localMCP, profileID: .localAdmin, trustedPrincipalID: "catalog-fixture"),
      database: GatewayDatabase(inMemory: ()),
      registeredProjects: [
        .init(id: "catalog", displayName: "Catalog", rootPath: project.url.path)
      ],
      platform: MacOSPlatform.services(launcher: testExecutionLauncher()),
      mcpClient: CatalogDiscoveryStub(), plugins: [],
      bundledPlugins: .init(packages: [], issues: []),
      remoteManagement: GatewayRemoteManagement(call: { _, _, _ in
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
            "requirement": try .encoded(descriptor.requirement),
            "hostServiceAction": descriptor.hostServiceAction.map { .string($0.rawValue) } ?? .null,
            "projectRequirement": .string(descriptor.projectRequirement.rawValue),
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

  @Test func documentedToolRequirementsMatchCatalogSnapshot() throws {
    let (document, expected) = try Self.requirementReference()
    let differences = Self.requirementDifferences(document: document, expected: expected)
    #expect(
      differences.isEmpty,
      "Tool requirement reference drift:\n\(differences.joined(separator: "\n"))")
  }

  @Test(arguments: [
    "missing", "duplicate", "permission", "value", "fullAccess", "forwarding", "continuation",
  ])
  func requirementReferenceRejectsDrift(change: String) throws {
    let (document, expected) = try Self.requirementReference()
    let name =
      change == "forwarding"
      ? "mcp.tools.call" : change == "continuation" ? "shell.read" : "file.write"
    let row = try #require(expected[name])
    let replacement: String
    switch change {
    case "missing": replacement = ""
    case "duplicate": replacement = row + "\n" + row
    case "permission":
      replacement = row.replacingOccurrences(of: "Project `write`", with: "Skills `allow`")
    case "value":
      replacement = row.replacingOccurrences(of: "Project `write`", with: "Project `read`")
    case "fullAccess": replacement = row.replacingOccurrences(of: "| No |", with: "| Yes |")
    case "forwarding", "continuation":
      var cells = row.components(separatedBy: " | ")
      cells[3] = "None |"
      replacement = cells.joined(separator: " | ")
    default: throw RequirementReferenceError.invalidFixture
    }
    try #require(replacement != row)
    let changed = document.replacingOccurrences(of: row, with: replacement)
    #expect(!Self.requirementDifferences(document: changed, expected: expected).isEmpty)
  }

  private static let requirementStart = "<!-- tool-requirements:start -->"
  private static let requirementEnd = "<!-- tool-requirements:end -->"
  private static let requirementHeader =
    "| Tool | Declared permissions | Full access required | Conditions |"
  private enum RequirementReferenceError: Error { case invalidFixture }

  private static func requirementReference() throws -> (String, [String: String]) {
    let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let snapshot = try JSONDecoder().decode(
      [String: JSONValue].self,
      from: Data(contentsOf: tests.appendingPathComponent("Fixtures/builtin-tool-catalog.json")))
    let document = try String(
      contentsOf: tests.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Documentation/Reference/Tools.md"), encoding: .utf8)
    let expected = try snapshot.mapValues { tool in
      let value = try #require(tool.objectValue?["capability"]?.objectValue?["requirement"])
      return try JSONDecoder().decode(ToolRequirement.self, from: JSONEncoder().encode(value))
    }.map { name, requirement in (name, requirementRow(name, requirement)) }
    return (document, Dictionary(uniqueKeysWithValues: expected))
  }

  private static func requirementDifferences(document: String, expected: [String: String])
    -> [String]
  {
    let sections = document.components(separatedBy: requirementStart)
    guard sections.count == 2 else { return ["Expected exactly one requirement table"] }
    let end = sections[1].components(separatedBy: requirementEnd)
    guard end.count == 2 else { return ["Expected exactly one requirement table end"] }
    let lines = end[0].split(separator: "\n").map(String.init)
    guard lines.first == requirementHeader, lines.dropFirst().first == "| --- | --- | --- | --- |"
    else {
      return ["Invalid requirement table header"]
    }
    var seen: Set<String> = []
    var differences: [String] = []
    for line in lines.dropFirst(2) {
      let cells = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
      guard cells.count == 6, cells.first == "", cells.last == "",
        cells[1].hasPrefix("`"), cells[1].hasSuffix("`")
      else {
        differences.append("Malformed requirement row: \(line)")
        continue
      }
      let name = String(cells[1].dropFirst().dropLast())
      if !seen.insert(name).inserted { differences.append("Duplicate: \(name)") }
      if expected[name] != line { differences.append("Changed or unknown: \(name)") }
    }
    differences += Set(expected.keys).subtracting(seen).sorted().map { "Missing: \($0)" }
    let outside = sections[0] + end[1]
    if outside.contains("Required permission:")
      || outside.contains("| Tool | Required permission |")
    {
      differences.append("Duplicate permission declarations outside the canonical table")
    }
    return differences
  }

  private static func requirementRow(_ name: String, _ requirement: ToolRequirement) -> String {
    var permissions: [String] = []
    switch requirement.access {
    case .none: break
    case .read: permissions.append("Project `read`")
    case .projectWrite: permissions.append("Project `write`")
    case .sourceProjectWrite: permissions.append("Source Project `write`")
    }
    if let value = requirement.namedProjectAccess {
      permissions.append("Named Project `\(value.rawValue)`")
    }
    permissions += requirement.permissions.map { entry in
      let value = entry.value == .access ? "allow" : entry.value.rawValue
      return "\(permissionName(entry.permission)) `\(value)`"
    }.sorted()
    if !requirement.paths.isEmpty {
      let operations = Set(
        requirement.paths.map { path in
          switch path.operation {
          case .read: "read"
          case .write: "write"
          case .openDirectory: "openDirectory"
          case .listDirectory: "listDirectory"
          }
        }
      ).sorted().joined(separator: ", ")
      permissions.append("Resolved paths (\(operations))")
    }
    var conditions: [String] = []
    switch requirement.target {
    case .none: break
    case .mcp(let server, let value):
      permissions.append("MCP server `\(value.rawValue)` (\(objectName(server)))")
    case .forwarded(let tool, let arguments, let server):
      conditions.append(
        "Forward \(tool)(\(arguments))" + (server.map { " on \($0)" } ?? "")
          + "; check target requirements")
    }
    switch requirement.execution {
    case .none: break
    case .start: conditions.append("Start execution")
    case .list: conditions.append("Retained execution list")
    case .read(let argument): conditions.append("Retained execution read (\(argument))")
    case .input(let argument): conditions.append("Retained execution input (\(argument))")
    case .cancel(let argument): conditions.append("Retained execution cancel (\(argument))")
    }
    if let contribution = requirement.contribution {
      let kind: String
      let object: ToolRequirement.Object
      switch contribution {
      case .cli(let selection):
        kind = "CLI"
        object = selection
      case .skills(let selection):
        kind = "Skills"
        object = selection
      case .mcp(let selection):
        kind = "MCP"
        object = selection
      }
      conditions.append("Plugin `use` if contributed: \(kind) \(objectName(object))")
    }
    if let url = requirement.networkURL { conditions.append("Network URL: \(url)") }
    return "| `\(name)` | \(permissions.isEmpty ? "None" : permissions.joined(separator: "; ")) | "
      + "\(requirement.requiresFullAccess ? "Yes" : "No") | \(conditions.isEmpty ? "None" : conditions.joined(separator: "; ")) |"
  }

  private static func objectName(_ object: ToolRequirement.Object) -> String {
    switch object {
    case .argument(let name): "argument \(name)"
    case .registered(let id): "registered \(id)"
    case .catalog: "catalog"
    case .skill(let name, let root): "skill \(name) in \(root)"
    }
  }

  private static func permissionName(_ permission: Permission) -> String {
    switch permission {
    case .project(let id): "Project \(id)"
    case .plugin(let id): "Plugin \(id)"
    case .mcpServer(let id): "MCP server \(id)"
    case .filesAndFolders(let category): "Files and Folders \(category.rawValue)"
    case .screen: "Screen"
    case .desktopControl: "Desktop control"
    case .localNetwork: "Local network"
    case .machineInformation: "Machine information"
    case .unifiedLogs: "Unified logs"
    case .skills: "Skills"
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
  func cachedTools(server: MCPServerConfig, context: InvocationContext) -> [MCPTool]? {
    try? listTools(server: server, context: context)
  }

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
