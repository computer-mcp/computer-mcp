import ComputerMCPDownstream
import ComputerMCPTestSupport
import ComputerMCPToolKit
import ComputerMCPToolsCLI
import ComputerMCPToolsFiles
import ComputerMCPToolsGit
import ComputerMCPToolsMCP
import ComputerMCPToolsShell
import ComputerMCPToolsSystem
import ComputerMCPToolsWorkspace
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
    let registry = try toolRouter(configuration: config)
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
      try MCPToolProvider(
        environment: ToolEnvironment(configuration: config), mcpClient: RegistryDiscoveryStub()
      ).callTool(
        .init(name: "mcp.servers.list", arguments: .object([:]), context: .empty))
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
    let registry = try toolRouter(configuration: config)

    let result = try registry.callTool(
      name: "system.time", arguments: .object([:]), context: .empty)
    let textPayload = try decodeTextPayload(result)

    #expect((result.objectValue?["structuredContent"]?.objectValue?["result"]) == (textPayload))
  }

  private func toolRouter(configuration: GatewayConfiguration) throws -> GatewayProviderRouter {
    let environment = ToolEnvironment(configuration: configuration)
    return try GatewayProviderRouter(providers: [
      CLIToolProvider(environment: environment), ShellToolProvider(environment: environment),
      ProcessToolProvider(environment: environment), GitToolProvider(environment: environment),
      FilesToolProvider(environment: environment), WorkspaceToolProvider(environment: environment),
      SystemToolProvider(environment: environment), NetworkToolProvider(environment: environment),
      MCPToolProvider(environment: environment, mcpClient: RegistryDiscoveryStub()),
      ConfiguredMCPToolProvider(environment: environment, mcpClient: RegistryDiscoveryStub()),
    ])
  }

  private func decodeTextPayload(_ value: JSONValue) throws -> JSONValue {
    let text = try #require(
      value.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
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
