import AppKit
import ComputerMCPDownstream
import ComputerMCPTestSupport
import ComputerMCPToolKit
import ComputerMCPToolsCLI
import ComputerMCPToolsFiles
import ComputerMCPToolsGit
import ComputerMCPToolsShell
import ComputerMCPToolsWorkspace
import Darwin
import Foundation
import Testing

@testable import ComputerMCP
@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPPlatform
@testable import ComputerMCPPlatformPOSIX
@testable import ComputerMCPProcess

@Suite(.nativeIntegration, .serialized)

final class GatewayToolRegistryTests {
  @Test
  func testGatewayToolsExposeCLIAndMCPTools() throws {
    let router = try toolRouter(configuration: .fixture())
    let names = try router.listTools(context: .empty).map(\.name)

    #expect(names.contains("cli.list"))
    #expect(names.contains("cli.describe"))
    #expect(names.contains("cli.status"))
    #expect(names.contains("cli.help"))
    #expect(names.contains("cli.exec"))
    #expect(names.contains("mcp.tools.call"))
    #expect(names.contains("mcp.tools.describe"))
    #expect(names.contains("mcp.tools.find"))
    #expect(names.contains("mcp.resources.list"))
    #expect(names.contains("mcp.resources.templates.list"))
    #expect(names.contains("mcp.resources.read"))
    #expect(names.contains("mcp.prompts.list"))
    #expect(names.contains("mcp.prompts.get"))
    #expect(names.contains("mcp.servers.status"))
    #expect(names.contains("process.list"))
    #expect(!(names.contains("file.read")))
    #expect(!(names.contains("shell.run")))
  }

  @Test
  func testGatewayToolsHideProviderAdaptersWhenNoProvidersAreConfigured() throws {
    let config = GatewayConfiguration.fixture(
      cli: CLISectionConfig(),
      mcp: MCPSectionConfig(),
      builtin: BuiltinConfig(enabled: ["system.time"])
    )
    let registry = GatewayToolRegistry(configuration: config)
    let tools = try registry.listTools(context: .empty)

    #expect((tools.map(\.name)) == (["system.time"]))
    #expect((tools.first?.annotations?.readOnlyHint) == (true))
    #expect((tools.first?.annotations?.destructiveHint) == (false))
    expectThrows(
      try CLIToolProvider(environment: ToolEnvironment(configuration: config)).callTool(
        .init(name: "cli.list", arguments: .object([:]), context: .empty))
    ) { error in
      #expect(error.localizedDescription.contains("at least one configured provider"))
    }
    expectThrows(
      try registry.callTool(name: "mcp.servers.list", arguments: .object([:]), context: .empty)
    ) { error in
      #expect(error.localizedDescription.contains("at least one configured server"))
    }
  }

  @Test
  func testGatewayToolsAdvertiseOperationalAnnotations() throws {
    let config = GatewayConfiguration.fixture(
      builtin: BuiltinConfig(
        enabled: ["system.time", "file.write", "file.mkdir", "git.commit"])
    )
    let router = try toolRouter(configuration: config)
    let tools = try router.listTools(context: .empty)
    let cliList = try #require(tools.first { $0.name == "cli.list" })
    let cliExec = try #require(tools.first { $0.name == "cli.exec" })
    let systemTime = try #require(tools.first { $0.name == "system.time" })
    let fileWrite = try #require(tools.first { $0.name == "file.write" })
    let fileMkdir = try #require(tools.first { $0.name == "file.mkdir" })
    let gitCommit = try #require(tools.first { $0.name == "git.commit" })

    #expect((cliList.annotations?.readOnlyHint) == (true))
    #expect((cliList.annotations?.destructiveHint) == (false))
    #expect((cliExec.annotations?.readOnlyHint) == (false))
    #expect((cliExec.annotations?.destructiveHint) == (true))
    #expect((systemTime.annotations?.readOnlyHint) == (true))
    #expect((systemTime.annotations?.openWorldHint) == (false))
    #expect((fileWrite.annotations?.readOnlyHint) == (false))
    #expect((fileWrite.annotations?.destructiveHint) == (true))
    #expect((fileMkdir.annotations?.readOnlyHint) == (false))
    #expect((fileMkdir.annotations?.destructiveHint) == (false))
    #expect((gitCommit.annotations?.readOnlyHint) == (false))
    #expect((gitCommit.annotations?.destructiveHint) == (false))
    #expect((systemTime.title) == ("System Time"))
    #expect((systemTime.outputSchema) == (MCPTool.resultEnvelopeSchema))
    #expect(
      (systemTime.json.objectValue?["annotations"]?.objectValue?["readOnlyHint"]) == (.bool(true)))
    #expect((systemTime.json.objectValue?["title"]) == (.string("System Time")))
    #expect((systemTime.json.objectValue?["outputSchema"]) == (MCPTool.resultEnvelopeSchema))
  }

  @Test
  func testGatewayToolResultsExposeMatchingStructuredContent() throws {
    let config = GatewayConfiguration.fixture(
      cli: CLISectionConfig(),
      mcp: MCPSectionConfig(),
      builtin: BuiltinConfig(enabled: ["system.time"])
    )
    let registry = GatewayToolRegistry(configuration: config)

    let result = try registry.callTool(
      name: "system.time", arguments: .object([:]), context: .empty)
    let textPayload = try decodeTextPayload(result)

    #expect((result.objectValue?["structuredContent"]?.objectValue?["result"]) == (textPayload))
  }

  @Test
  func testWorkspacePathResolverAcceptsEquivalentCanonicalAbsolutePath() throws {
    let workspace = try temporaryDirectory()
    let canonicalWorkspace = try WorkspacePathResolver.canonicalWorkspace(workspace)
    let canonicalTarget = canonicalWorkspace.appendingPathComponent("future/file.txt")

    let resolved = try WorkspacePathResolver.resolve(
      canonicalTarget.path,
      relativeTo: workspace
    )

    #expect(resolved.path == workspace.appendingPathComponent("future/file.txt").path)
  }

  @Test
  func testRecursiveReadOnlyScansPreserveSymlinksWithoutFollowingThem() throws {
    let container = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: container) }
    let workspace = container.appendingPathComponent("workspace", isDirectory: true)
    let outside = container.appendingPathComponent("outside", isDirectory: true)
    let links = workspace.appendingPathComponent("Links", isDirectory: true)
    try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try "LOCAL_KEY=local-value\n".write(
      to: workspace.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    try "# TODO local\n".write(
      to: workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try "OUTSIDE_SCAN_SECRET=must-not-be-read\n".write(
      to: outside.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    try "OUTSIDE_SCAN_SECRET\n".write(
      to: outside.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      atPath: links.appendingPathComponent("missing").path,
      withDestinationPath: "../missing.txt"
    )
    try FileManager.default.createSymbolicLink(
      atPath: links.appendingPathComponent("readme.md").path,
      withDestinationPath: "../README.md"
    )
    try FileManager.default.createSymbolicLink(
      at: links.appendingPathComponent("outside.env"),
      withDestinationURL: outside.appendingPathComponent(".env")
    )
    try FileManager.default.createSymbolicLink(
      at: links.appendingPathComponent("outside.txt"),
      withDestinationURL: outside.appendingPathComponent("outside.txt")
    )

    let registry = try toolRouter(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: [
          "file.find", "file.list", "file.search", "file.tree", "workspace.env_files",
          "workspace.todos",
        ]),
        workspaceDirectory: workspace
      )
    )

    let listResult = try registry.callTool(
      name: "file.list",
      arguments: .object([
        "path": .string("."),
        "include_hidden": .bool(true),
        "recursive_depth": .number(2),
        "max_entries": .number(100),
      ]), context: .empty
    )
    let listPayload = try decodeTextPayload(listResult)
    let entries = try #require(listPayload.objectValue?["entries"]?.arrayValue)
    func entry(at path: String) -> [String: JSONValue]? {
      entries.first {
        $0.objectValue?["workspace_relative_path"] == .string(path)
      }?.objectValue
    }
    #expect((entry(at: "Links/missing")?["type"]) == (.string("symlink")))
    #expect((entry(at: "Links/readme.md")?["type"]) == (.string("symlink")))
    #expect((entry(at: "Links/outside.env")?["type"]) == (.string("symlink")))
    #expect((entry(at: "Links/outside.txt")?["type"]) == (.string("symlink")))

    let treeResult = try registry.callTool(
      name: "file.tree",
      arguments: .object([
        "path": .string("."),
        "include_hidden": .bool(true),
        "max_depth": .number(3),
        "max_entries": .number(100),
      ]), context: .empty
    )
    let treePayload = try decodeTextPayload(treeResult)
    #expect((treePayload.objectValue?["truncated"]) == (.bool(false)))
    #expect((treePayload.objectValue?["entry_count"]?.numberValue ?? 0) >= 7)

    let findResult = try registry.callTool(
      name: "file.find",
      arguments: .object([
        "path": .string("."),
        "query": .string("missing"),
        "include_hidden": .bool(true),
      ]), context: .empty
    )
    let findPayload = try decodeTextPayload(findResult)
    let findResults = try #require(findPayload.objectValue?["results"]?.arrayValue)
    #expect(
      findResults.contains {
        $0.objectValue?["workspace_relative_path"] == .string("Links/missing")
          && $0.objectValue?["type"] == .string("symlink")
      })

    let searchResult = try registry.callTool(
      name: "file.search",
      arguments: .object([
        "path": .string("."),
        "query": .string("OUTSIDE_SCAN_SECRET"),
        "include_hidden": .bool(true),
      ]), context: .empty
    )
    let searchPayload = try decodeTextPayload(searchResult)
    #expect((searchPayload.objectValue?["match_count"]) == (.number(0)))

    let todosResult = try registry.callTool(
      name: "workspace.todos",
      arguments: .object([
        "path": .string("."),
        "markers": .array([.string("OUTSIDE_SCAN_SECRET")]),
        "include_hidden": .bool(true),
      ]), context: .empty
    )
    let todosPayload = try decodeTextPayload(todosResult)
    #expect((todosPayload.objectValue?["match_count"]) == (.number(0)))

    let envResult = try registry.callTool(
      name: "workspace.env_files",
      arguments: .object([
        "path": .string("."),
        "include_hidden_directories": .bool(true),
      ]), context: .empty
    )
    let envPayload = try decodeTextPayload(envResult)
    let envFiles = try #require(envPayload.objectValue?["env_files"]?.arrayValue)
    #expect((envPayload.objectValue?["env_file_count"]) == (.number(1)))
    #expect(
      envFiles.first?.objectValue?["workspace_relative_path"] == .string(".env"))
    let keys = try #require(envFiles.first?.objectValue?["keys"]?.arrayValue)
    #expect((keys.map { $0.objectValue?["name"] }) == [.string("LOCAL_KEY")])
  }

  private func toolRouter(configuration: GatewayConfiguration) throws -> GatewayProviderRouter {
    let environment = ToolEnvironment(configuration: configuration)
    return try GatewayProviderRouter(
      registry: GatewayToolRegistry(
        toolEnvironment: environment, mcpClient: RegistryDiscoveryStub()),
      additionalProviders: {
        [
          CLIToolProvider(environment: environment), ShellToolProvider(environment: environment),
          ProcessToolProvider(environment: environment), GitToolProvider(environment: environment),
          FilesToolProvider(environment: environment),
          WorkspaceToolProvider(environment: environment),
        ]
      })
  }

  private func decodeTextPayload(_ value: JSONValue) throws -> JSONValue {
    let text = try #require(
      value.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

}

private struct RegistryDiscoveryStub: DownstreamMCPClient {
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
