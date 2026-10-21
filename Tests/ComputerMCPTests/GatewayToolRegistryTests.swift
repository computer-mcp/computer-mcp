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
  func testMCPStatusUsesProviderEnvironmentForScriptInterpretersWithoutStartingThem() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = directory.appendingPathComponent("script")
    try "#!/usr/bin/env sh\ntouch should-not-run\n".write(
      to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let config = GatewayConfiguration.fixture(
      mcp: .init(servers: [
        .init(
          id: "missing-runtime", transport: .stdio, command: script.path,
          env: ["PATH": directory.path, "TOKEN": "never-emit-this"], cwd: directory.path)
      ]))
    let registry = GatewayToolRegistry(configuration: config, environment: ["PATH": "/bin"])
    let mcp = try decodeTextPayload(
      registry.callTool(name: "mcp.servers.status", arguments: .object([:]), context: .empty))
    let server = try #require(mcp.objectValue?["servers"]?.arrayValue?.first?.objectValue)
    #expect(server["ready"] == .bool(false))
    #expect(server["readiness_scope"] == .string("file_and_interpreter_checks"))
    #expect(server["command_resolution"]?.objectValue?["is_executable"] == .bool(true))
    #expect(
      server["command_resolution"]?.objectValue?["status"] == .string("interpreter_unavailable"))
    #expect(
      !String(decoding: try JSONEncoder().encode(mcp), as: UTF8.self).contains("never-emit-this"))
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("should-not-run").path))
  }

  @Test
  func testConfiguredMCPBackedToolProxiesDownstreamCall() throws {
    let mcp = FakeDownstreamMCPClient()
    let config = GatewayConfiguration.fixture(
      tools: [
        ToolConfig(
          name: "fake.sample_typed",
          description: "Call sample directly.",
          adapter: .mcp,
          source: "fake",
          tool: "sample",
          inputSchema:
            #"{"type":"object","properties":{"value":{"type":"string"}},"required":["value"],"additionalProperties":false}"#
        )
      ]
    )
    let registry = GatewayToolRegistry(configuration: config, mcpClient: mcp)

    let names = try registry.listTools(context: .empty).map(\.name)
    #expect(names.contains("fake.sample_typed"))
    let configuredTool = try #require(
      try registry.listTools(context: .empty).first { $0.name == "fake.sample_typed" })
    #expect((configuredTool.outputSchema) == nil)

    let result = try registry.callTool(
      name: "fake.sample_typed",
      arguments: .object(["value": .string("typed")]), context: .empty
    )

    #expect((result.objectValue?["isError"]) == (.bool(false)))
    #expect((mcp.calls.first?.tool) == ("sample"))
    #expect((mcp.calls.first?.arguments) == (.object(["value": .string("typed")])))
  }

  @Test
  func testUnregisteredMCPServerRejectsDirectToolCalls() {
    let registry = GatewayToolRegistry(configuration: .fixture())

    expectThrows(
      try registry.callTool(
        name: "mcp.tools.list",
        arguments: .object(["server": .string("figma")]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unknown MCP server id"))
    }

    expectThrows(
      try registry.callTool(
        name: "mcp.tools.call",
        arguments: .object([
          "server": .string("figma"),
          "tool": .string("get_screenshot"),
          "arguments": .object([:]),
        ]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unknown MCP server id"))
    }

    expectThrows(
      try registry.callTool(
        name: "mcp.tools.describe",
        arguments: .object([
          "server": .string("figma"),
          "tool": .string("get_screenshot"),
        ]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unknown MCP server id"))
    }

    expectThrows(
      try registry.callTool(
        name: "mcp.resources.list",
        arguments: .object(["server": .string("figma")]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unknown MCP server id"))
    }

    expectThrows(
      try registry.callTool(
        name: "mcp.resources.read",
        arguments: .object([
          "server": .string("figma"),
          "uri": .string("file:///missing"),
        ]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unknown MCP server id"))
    }

    expectThrows(
      try registry.callTool(
        name: "mcp.prompts.list",
        arguments: .object(["server": .string("figma")]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unknown MCP server id"))
    }

    expectThrows(
      try registry.callTool(
        name: "mcp.prompts.get",
        arguments: .object([
          "server": .string("figma"),
          "name": .string("review"),
        ]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unknown MCP server id"))
    }
  }

  @Test
  func testUnexposedTopLevelToolNameRejectsDirectToolCall() {
    let registry = GatewayToolRegistry(configuration: .fixture())

    expectThrows(
      try registry.callTool(
        name: "figma.get_screenshot",
        arguments: .object([:]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unknown tool"))
    }
  }

  @Test
  func testReexportPassesArgumentsMatchingTheAdvertisedDownstreamSchema() throws {
    let mcp = FakeDownstreamMCPClient()
    let configuration = GatewayConfiguration.fixture(
      mcp: MCPSectionConfig(servers: [
        MCPServerConfig(
          id: "fake",
          transport: .stdio,
          command: "/bin/cat",
          exposure: .reexport,
          prefix: "fake",
          allowedTools: ["sample"]
        )
      ])
    )
    let registry = GatewayToolRegistry(configuration: configuration, mcpClient: mcp)

    _ = try registry.callTool(
      name: "fake.sample",
      arguments: .object(["value": .string("direct")]), context: .empty
    )

    #expect((mcp.calls.first?.tool) == ("sample"))
    #expect((mcp.calls.first?.arguments) == (.object(["value": .string("direct")])))
  }

  @Test
  func testMCPToolsListAndCallUseDownstreamClient() throws {
    let mcp = FakeDownstreamMCPClient()
    let registry = GatewayToolRegistry(configuration: .fixture(), mcpClient: mcp)

    let listResult = try registry.callTool(
      name: "mcp.tools.list",
      arguments: .object(["server": .string("fake")]), context: .empty
    )
    let listPayload = try decodeTextPayload(listResult)

    #expect((listPayload.arrayValue?.first?.objectValue?["name"]) == (.string("sample")))

    let callResult = try registry.callTool(
      name: "mcp.tools.call",
      arguments: .object([
        "server": .string("fake"),
        "tool": .string("sample"),
        "request_id": .string("request-1"),
        "arguments": .object(["value": .string("x")]),
      ]), context: .empty
    )
    let callPayload = try decodeTextPayload(callResult)

    #expect(
      (callPayload.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"])
        == (.string("called")))
    #expect((mcp.calls.first?.tool) == ("sample"))
    #expect((mcp.calls.first?.requestID) == ("request-1"))
  }

  @Test
  func testMCPToolCallCanStartWithoutWaitingForResult() throws {
    let mcp = FakeDownstreamMCPClient()
    let registry = GatewayToolRegistry(configuration: .fixture(), mcpClient: mcp)

    let result = try registry.callTool(
      name: "mcp.tools.call",
      arguments: .object([
        "server": .string("fake"),
        "tool": .string("sample"),
        "request_id": .string("request-started"),
        "wait_for_result": .bool(false),
        "arguments": .object(["value": .string("x")]),
      ]), context: .empty
    )

    #expect((try decodeTextPayload(result).objectValue?["state"]) == (.string("running")))
    #expect((mcp.startedCalls.first?.tool) == ("sample"))
    #expect((mcp.startedCalls.first?.requestID) == ("request-started"))
  }

  @Test
  func testMCPToolCallRequiresRequestIDWhenStartingWithoutWaiting() {
    let registry = GatewayToolRegistry(
      configuration: .fixture(),
      mcpClient: FakeDownstreamMCPClient()
    )

    expectThrows(
      try registry.callTool(
        name: "mcp.tools.call",
        arguments: .object([
          "server": .string("fake"),
          "tool": .string("sample"),
          "wait_for_result": .bool(false),
        ]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("request_id is required"))
    }
  }

  @Test
  func testMCPToolDiscoveryAndCallsAreLimitedToReviewedTools() throws {
    let mcp = FakeDownstreamMCPClient()
    mcp.tools = [
      MCPTool(
        name: "reviewed",
        description: "Reviewed tool.",
        inputSchema: .object(["type": .string("object")])
      ),
      MCPTool(
        name: "shell",
        description: "Unreviewed shell tool.",
        inputSchema: .object(["type": .string("object")])
      ),
    ]
    let configuration = GatewayConfiguration.fixture(
      mcp: MCPSectionConfig(servers: [
        MCPServerConfig(
          id: "fake",
          transport: .stdio,
          command: "/bin/cat",
          allowedTools: ["reviewed"]
        )
      ])
    )
    let registry = GatewayToolRegistry(configuration: configuration, mcpClient: mcp)

    let listed = try decodeTextPayload(
      registry.callTool(
        name: "mcp.tools.list",
        arguments: .object(["server": .string("fake")]), context: .empty
      )
    )
    #expect(
      (listed.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue }) == (["reviewed"]))

    expectThrows(
      try registry.callTool(
        name: "mcp.tools.call",
        arguments: .object([
          "server": .string("fake"),
          "tool": .string("shell"),
          "arguments": .object([:]),
        ]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("not approved"))
    }
    #expect(mcp.calls.isEmpty)
  }

  @Test
  func testMCPEventsRequestsAndCancellationUseDownstreamClient() throws {
    let mcp = FakeDownstreamMCPClient()
    mcp.events = .object([
      "server": .string("fake"),
      "next_cursor": .number(8),
      "events": .array([
        .object([
          "cursor": .number(8),
          "kind": .string("notifications/tools/list_changed"),
        ])
      ]),
    ])
    mcp.activeRequestPayload = .object([
      "server": .string("fake"),
      "requests": .array([
        .object(["request_id": .string("request-1")])
      ]),
    ])
    let registry = GatewayToolRegistry(configuration: .fixture(), mcpClient: mcp)

    let eventsResult = try registry.callTool(
      name: "mcp.events.read",
      arguments: .object([
        "server": .string("fake"),
        "after_cursor": .number(3),
        "max_results": .number(25),
      ]), context: .empty
    )
    #expect((try decodeTextPayload(eventsResult).objectValue?["next_cursor"]) == (.number(8)))
    #expect((mcp.eventReads) == ([.init(afterCursor: 3, maxResults: 25)]))

    let requestsResult = try registry.callTool(
      name: "mcp.requests.list",
      arguments: .object(["server": .string("fake")]), context: .empty
    )
    #expect(
      (try decodeTextPayload(requestsResult).objectValue?["requests"]?.arrayValue?.count) == (1))

    let cancelResult = try registry.callTool(
      name: "mcp.requests.cancel",
      arguments: .object([
        "server": .string("fake"),
        "request_id": .string("request-1"),
        "reason": .string("test"),
      ]), context: .empty
    )
    #expect((try decodeTextPayload(cancelResult).objectValue?["cancelled"]) == (.bool(true)))
    #expect((mcp.cancellations) == ([.init(requestID: "request-1", reason: "test")]))
  }

  @Test
  func testMCPToolsDescribeReturnsExactDownstreamToolDefinition() throws {
    let mcp = FakeDownstreamMCPClient()
    mcp.tools = [
      MCPTool(
        name: "sample",
        description: "Sample downstream tool.",
        inputSchema: .object([
          "type": .string("object"),
          "properties": .object(["value": .object(["type": .string("string")])]),
        ])
      ),
      MCPTool(
        name: "other",
        description: "Other downstream tool.",
        inputSchema: .object(["type": .string("object")])
      ),
    ]
    let registry = GatewayToolRegistry(configuration: .fixture(), mcpClient: mcp)

    let result = try registry.callTool(
      name: "mcp.tools.describe",
      arguments: .object([
        "server": .string("fake"),
        "tool": .string("sample"),
      ]), context: .empty
    )
    let payload = try decodeTextPayload(result)
    let definition = try #require(payload.objectValue?["definition"]?.objectValue)
    let callContext = try #require(payload.objectValue?["call_context"]?.objectValue)
    let callArguments = try #require(callContext["arguments"]?.objectValue)

    #expect((payload.objectValue?["server"]) == (.string("fake")))
    #expect((payload.objectValue?["tool"]) == (.string("sample")))
    #expect((payload.objectValue?["tool_count"]) == (.number(2)))
    #expect((definition["name"]) == (.string("sample")))
    #expect((definition["description"]) == (.string("Sample downstream tool.")))
    #expect(
      (definition["inputSchema"]?.objectValue?["properties"]?.objectValue?["value"]?.objectValue?[
        "type"]) == (.string("string")))
    #expect((callContext["tool"]) == (.string("mcp.tools.call")))
    #expect((callArguments["server"]) == (.string("fake")))
    #expect((callArguments["tool"]) == (.string("sample")))
    #expect((callArguments["arguments"]) == (.object([:])))
  }

  @Test
  func testMCPToolsDescribeRejectsUnknownDownstreamTool() {
    let registry = GatewayToolRegistry(
      configuration: .fixture(), mcpClient: FakeDownstreamMCPClient())

    expectThrows(
      try registry.callTool(
        name: "mcp.tools.describe",
        arguments: .object([
          "server": .string("fake"),
          "tool": .string("missing"),
        ]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unknown downstream MCP tool"))
    }
  }

  @Test
  func testMCPResourcesListTemplatesAndReadUseDownstreamClient() throws {
    let mcp = FakeDownstreamMCPClient()
    mcp.resources = [
      .object([
        "name": .string("Readme"),
        "uri": .string("file:///workspace/README.md"),
        "mimeType": .string("text/markdown"),
      ])
    ]
    mcp.resourceTemplates = [
      .object([
        "name": .string("File by path"),
        "uriTemplate": .string("file:///workspace/{path}"),
        "mimeType": .string("text/plain"),
      ])
    ]
    mcp.resourceContents = [
      "file:///workspace/README.md": [
        .object([
          "uri": .string("file:///workspace/README.md"),
          "mimeType": .string("text/markdown"),
          "text": .string("# README"),
        ])
      ]
    ]
    let registry = GatewayToolRegistry(configuration: .fixture(), mcpClient: mcp)

    let listResult = try registry.callTool(
      name: "mcp.resources.list",
      arguments: .object([
        "server": .string("fake"),
        "cursor": .string("page-1"),
      ]), context: .empty
    )
    let listPayload = try decodeTextPayload(listResult)
    let resources = try #require(listPayload.objectValue?["resources"]?.arrayValue)
    let resource = try #require(resources.first?.objectValue)
    let readContext = try #require(resource["read_context"]?.objectValue)

    #expect((listPayload.objectValue?["server"]) == (.string("fake")))
    #expect((listPayload.objectValue?["cursor"]) == (.string("page-1")))
    #expect((listPayload.objectValue?["resource_count"]) == (.number(1)))
    #expect((resource["uri"]) == (.string("file:///workspace/README.md")))
    #expect((readContext["tool"]) == (.string("mcp.resources.read")))
    #expect(
      (readContext["arguments"]?.objectValue?["uri"]) == (.string("file:///workspace/README.md")))
    #expect((mcp.resourceListCursors) == (["page-1"]))

    let templatesResult = try registry.callTool(
      name: "mcp.resources.templates.list",
      arguments: .object(["server": .string("fake")]), context: .empty
    )
    let templatesPayload = try decodeTextPayload(templatesResult)
    let templates = try #require(templatesPayload.objectValue?["resource_templates"]?.arrayValue)

    #expect((templatesPayload.objectValue?["template_count"]) == (.number(1)))
    #expect((templates.first?.objectValue?["uriTemplate"]) == (.string("file:///workspace/{path}")))

    let readResult = try registry.callTool(
      name: "mcp.resources.read",
      arguments: .object([
        "server": .string("fake"),
        "uri": .string("file:///workspace/README.md"),
      ]), context: .empty
    )
    let readPayload = try decodeTextPayload(readResult)
    let contents = try #require(readPayload.objectValue?["contents"]?.arrayValue)

    #expect((readPayload.objectValue?["server"]) == (.string("fake")))
    #expect((readPayload.objectValue?["uri"]) == (.string("file:///workspace/README.md")))
    #expect((readPayload.objectValue?["content_count"]) == (.number(1)))
    #expect((contents.first?.objectValue?["text"]) == (.string("# README")))
    #expect((mcp.resourceReadURIs) == (["file:///workspace/README.md"]))
  }

  @Test
  func testMCPPromptsListAndGetUseDownstreamClient() throws {
    let mcp = FakeDownstreamMCPClient()
    mcp.prompts = [
      .object([
        "name": .string("review"),
        "description": .string("Review selected code."),
        "arguments": .array([
          .object([
            "name": .string("path"),
            "description": .string("Workspace path."),
            "required": .bool(true),
          ])
        ]),
      ])
    ]
    mcp.promptResults = [
      "review": .object([
        "description": .string("Review prompt."),
        "messages": .array([
          .object([
            "role": .string("user"),
            "content": .object([
              "type": .string("text"),
              "text": .string("Review Sources/ComputerMCP/GatewayToolRegistry.swift"),
            ]),
          ])
        ]),
      ])
    ]
    let registry = GatewayToolRegistry(configuration: .fixture(), mcpClient: mcp)

    let listResult = try registry.callTool(
      name: "mcp.prompts.list",
      arguments: .object([
        "server": .string("fake"),
        "cursor": .string("page-1"),
      ]), context: .empty
    )
    let listPayload = try decodeTextPayload(listResult)
    let prompts = try #require(listPayload.objectValue?["prompts"]?.arrayValue)
    let prompt = try #require(prompts.first?.objectValue)
    let getContext = try #require(prompt["get_context"]?.objectValue)

    #expect((listPayload.objectValue?["server"]) == (.string("fake")))
    #expect((listPayload.objectValue?["cursor"]) == (.string("page-1")))
    #expect((listPayload.objectValue?["prompt_count"]) == (.number(1)))
    #expect((prompt["name"]) == (.string("review")))
    #expect((getContext["tool"]) == (.string("mcp.prompts.get")))
    #expect((getContext["arguments"]?.objectValue?["name"]) == (.string("review")))
    #expect((mcp.promptListCursors) == (["page-1"]))

    let getResult = try registry.callTool(
      name: "mcp.prompts.get",
      arguments: .object([
        "server": .string("fake"),
        "name": .string("review"),
        "arguments": .object(["path": .string("Sources")]),
      ]), context: .empty
    )
    let getPayload = try decodeTextPayload(getResult)
    let messages = try #require(getPayload.objectValue?["messages"]?.arrayValue)

    #expect((getPayload.objectValue?["server"]) == (.string("fake")))
    #expect((getPayload.objectValue?["name"]) == (.string("review")))
    #expect((getPayload.objectValue?["arguments"]?.objectValue?["path"]) == (.string("Sources")))
    #expect((getPayload.objectValue?["description"]) == (.string("Review prompt.")))
    #expect((getPayload.objectValue?["message_count"]) == (.number(1)))
    #expect(
      (messages.first?.objectValue?["content"]?.objectValue?["text"])
        == (.string("Review Sources/ComputerMCP/GatewayToolRegistry.swift")))
    #expect(
      (mcp.promptGetCalls)
        == ([
          FakeDownstreamMCPClient.PromptGetCall(
            name: "review", arguments: ["path": "Sources"])
        ]))
  }

  @Test
  func testMCPPromptsGetRejectsNonStringArguments() {
    let registry = GatewayToolRegistry(
      configuration: .fixture(), mcpClient: FakeDownstreamMCPClient())

    expectThrows(
      try registry.callTool(
        name: "mcp.prompts.get",
        arguments: .object([
          "server": .string("fake"),
          "name": .string("review"),
          "arguments": .object(["path": .number(1)]),
        ]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("arguments.path must be a string"))
    }
  }

  @Test
  func testMCPToolsFindFiltersDownstreamToolsDeterministically() throws {
    let mcp = FakeDownstreamMCPClient()
    mcp.tools = [
      MCPTool(
        name: "video_read",
        description: "Read video metadata.",
        inputSchema: .object(["type": .string("object")])
      ),
      MCPTool(
        name: "video_comments",
        description: "List comments.",
        inputSchema: .object(["type": .string("object")])
      ),
      MCPTool(
        name: "auth_status",
        description: "Report authenticated account.",
        inputSchema: .object(["type": .string("object")])
      ),
    ]
    let registry = GatewayToolRegistry(configuration: .fixture(), mcpClient: mcp)

    let result = try registry.callTool(
      name: "mcp.tools.find",
      arguments: .object([
        "server": .string("fake"),
        "query": .string("video_"),
        "match": .string("prefix"),
        "field": .string("name"),
      ]), context: .empty
    )
    let payload = try decodeTextPayload(result)
    let tools = try #require(payload.objectValue?["tools"]?.arrayValue)

    #expect((payload.objectValue?["tool_count"]) == (.number(3)))
    #expect((payload.objectValue?["result_count"]) == (.number(2)))
    #expect((payload.objectValue?["truncated"]) == (.bool(false)))
    #expect(
      (tools.map { $0.objectValue?["name"] })
        == ([.string("video_read"), .string("video_comments")]))
  }

  @Test
  func testMCPToolsFindCanMatchDescriptionAndReportTruncation() throws {
    let mcp = FakeDownstreamMCPClient()
    mcp.tools = [
      MCPTool(name: "one", description: "Export media.", inputSchema: .object([:])),
      MCPTool(name: "two", description: "Export subtitles.", inputSchema: .object([:])),
    ]
    let registry = GatewayToolRegistry(configuration: .fixture(), mcpClient: mcp)

    let result = try registry.callTool(
      name: "mcp.tools.find",
      arguments: .object([
        "server": .string("fake"),
        "query": .string("export"),
        "field": .string("description"),
        "max_results": .number(1),
      ]), context: .empty
    )
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["result_count"]) == (.number(1)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
  }

  @Test
  func testMCPToolsFindRejectsBadModes() {
    let registry = GatewayToolRegistry(
      configuration: .fixture(), mcpClient: FakeDownstreamMCPClient())

    expectThrows(
      try registry.callTool(
        name: "mcp.tools.find",
        arguments: .object([
          "server": .string("fake"),
          "query": .string("video"),
          "field": .string("schema"),
        ]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("field"))
    }

    expectThrows(
      try registry.callTool(
        name: "mcp.tools.find",
        arguments: .object([
          "server": .string("fake"),
          "query": .string("video"),
          "match": .string("regex"),
        ]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("match"))
    }
  }

  @Test
  func testMCPServersStatusReportsProviderReadinessWithoutLeakingEnvValues() throws {
    let directory = try temporaryDirectory()
    let executable = directory.appendingPathComponent("mcp-server")
    try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let config = GatewayConfiguration.fixture(
      mcp: MCPSectionConfig(servers: [
        MCPServerConfig(
          id: "local",
          transport: .stdio,
          command: executable.path,
          args: ["--stdio"],
          env: ["LOCAL_MCP_TOKEN": "super-secret-local"],
          cwd: "workspace"
        ),
        MCPServerConfig(
          id: "remote",
          transport: .streamableHTTP,
          url: "https://mcp.example.com/mcp",
          env: ["REMOTE_MCP_TOKEN": "super-secret-remote"],
          exposure: .reexport,
          prefix: "remote",
          allowedTools: ["sample"]
        ),
      ])
    )
    let registry = GatewayToolRegistry(configuration: config, mcpClient: FakeDownstreamMCPClient())

    let result = try registry.callTool(
      name: "mcp.servers.status", arguments: .object([:]), context: .empty)
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    let servers = try #require(payload.objectValue?["servers"]?.arrayValue)
    let local = try #require(servers.first { $0.objectValue?["id"] == .string("local") })
      .objectValue
    let remote = try #require(servers.first { $0.objectValue?["id"] == .string("remote") })
      .objectValue

    #expect(!(text.contains("super-secret-local")))
    #expect(!(text.contains("super-secret-remote")))
    #expect((local?["ready"]) == (.bool(true)))
    #expect((local?["command"]) == (.string(executable.path)))
    #expect(
      (local?["command_resolution"]?.objectValue?["resolved_path"]) == (.string(executable.path)))
    #expect((local?["env"]?.arrayValue?.first?.objectValue?["key"]) == (.string("LOCAL_MCP_TOKEN")))
    #expect((local?["env"]?.arrayValue?.first?.objectValue?["value_redacted"]) == (.bool(true)))

    #expect((remote?["ready"]) == (.bool(true)))
    #expect((remote?["url_status"]?.objectValue?["scheme"]) == (.string("https")))
    #expect((remote?["url_status"]?.objectValue?["host"]) == (.string("mcp.example.com")))
    #expect((remote?["prefix"]) == (.string("remote")))
  }

  @Test
  func testMCPServersStatusCanFilterAndRejectsUnknownServer() throws {
    let config = GatewayConfiguration.fixture(
      mcp: MCPSectionConfig(servers: [
        MCPServerConfig(
          id: "missing",
          transport: .stdio,
          command: "definitely-missing-mcp-server-for-computer-mcp-tests"
        )
      ])
    )
    let registry = GatewayToolRegistry(configuration: config)

    let result = try registry.callTool(
      name: "mcp.servers.status",
      arguments: .object(["server": .string("missing")]), context: .empty
    )
    let payload = try decodeTextPayload(result)
    let server = try #require(payload.objectValue?["servers"]?.arrayValue?.first?.objectValue)

    #expect((server["id"]) == (.string("missing")))
    #expect((server["ready"]) == (.bool(false)))
    #expect((server["command_resolution"]?.objectValue?["exists"]) == (.bool(false)))

    expectThrows(
      try registry.callTool(
        name: "mcp.servers.status",
        arguments: .object(["server": .string("unknown")]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unknown MCP server id"))
    }
  }

  @Test
  func testReexportPrefixesDownstreamTools() throws {
    let mcp = FakeDownstreamMCPClient()
    let config = GatewayConfiguration.fixture(
      mcp: MCPSectionConfig(servers: [
        MCPServerConfig(
          id: "fake",
          transport: .stdio,
          command: "/bin/cat",
          exposure: .reexport,
          prefix: "fake",
          allowedTools: ["sample"]
        )
      ])
    )
    let registry = GatewayToolRegistry(configuration: config, mcpClient: mcp)

    let names = try registry.listTools(context: .empty).map(\.name)
    #expect(names.contains("fake.sample"))

    let result = try registry.callTool(
      name: "fake.sample",
      arguments: .object(["arguments": .object(["value": .string("x")])]), context: .empty
    )

    #expect((result.objectValue?["isError"]) == (.bool(false)))
    #expect((mcp.calls.first?.tool) == ("sample"))
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
  func testSystemInfoReturnsReadOnlyMacOSSummary() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.info"])
      )
    )

    let result = try registry.callTool(
      name: "system.info", arguments: .object([:]), context: .empty)
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["operating_system"]?.objectValue?["name"]) == (.string("macOS")))
    #expect((payload.objectValue?["hardware"]?.objectValue?["processor_count"]) != nil)
    #expect((payload.objectValue?["process"]?.objectValue?["id"]) != nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testSystemKernelReturnsReadOnlyUnameSummary() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.kernel"])
      )
    )

    let result = try registry.callTool(
      name: "system.kernel", arguments: .object([:]), context: .empty)
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["operation"]) == (.string("system.kernel")))
    #expect((payload.objectValue?["source"]) == (.string("uname")))
    #expect((payload.objectValue?["operating_system"]?.objectValue?["name"]) == (.string("macOS")))
    #expect(
      !(try #require(payload.objectValue?["kernel"]?.objectValue?["name"]?.stringValue).isEmpty))
    #expect(
      !(try #require(payload.objectValue?["kernel"]?.objectValue?["release"]?.stringValue).isEmpty))
    #expect(
      !(try #require(payload.objectValue?["hardware"]?.objectValue?["machine"]?.stringValue)
        .isEmpty))
    #expect(
      (try #require(payload.objectValue?["hardware"]?.objectValue?["processor_count"]?.numberValue))
        > (0))
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testSystemSoftwareUsesSWVersFixedArgvAndParsesVersion() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = """
      ProductName:\t\tmacOS
      ProductVersion:\t\t15.6
      BuildVersion:\t\t24G84
      """
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.software"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "system.software",
      arguments: .object(["timeout_ms": .number(1234)]), context: .empty
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/usr/bin/sw_vers"))
    #expect((runner.calls.first?.arguments) == ([]))
    #expect((payload.objectValue?["operation"]) == (.string("system.software")))
    #expect((payload.objectValue?["source"]) == (.string("/usr/bin/sw_vers")))
    #expect((payload.objectValue?["product"]?.objectValue?["name"]) == (.string("macOS")))
    #expect((payload.objectValue?["product"]?.objectValue?["version"]) == (.string("15.6")))
    #expect((payload.objectValue?["product"]?.objectValue?["build_version"]) == (.string("24G84")))
    #expect(
      (try #require(
        payload.objectValue?["process_info"]?.objectValue?["major_version"]?.numberValue)) >= (0))
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testSystemLocaleReturnsReadOnlyLocaleSummary() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.locale"])
      )
    )

    let result = try registry.callTool(
      name: "system.locale", arguments: .object([:]), context: .empty)
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["operation"]) == (.string("system.locale")))
    #expect((payload.objectValue?["source"]) == (.string("Foundation.Locale")))
    #expect(
      !(try #require(payload.objectValue?["locale"]?.objectValue?["identifier"]?.stringValue)
        .isEmpty))
    #expect((payload.objectValue?["preferred_languages"]?.arrayValue) != nil)
    #expect(
      !(try #require(payload.objectValue?["calendar"]?.objectValue?["identifier"]?.stringValue)
        .isEmpty))
    #expect(
      !(try #require(payload.objectValue?["time_zone"]?.objectValue?["identifier"]?.stringValue)
        .isEmpty))
    #expect((payload.objectValue?["time_zone"]?.objectValue?["seconds_from_gmt"]) != nil)
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testSystemMemoryReturnsReadOnlyVMStats() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.memory"])
      )
    )

    let result = try registry.callTool(
      name: "system.memory", arguments: .object([:]), context: .empty)
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["operation"]) == (.string("system.memory")))
    #expect((payload.objectValue?["source"]) == (.string("host_statistics64")))
    #expect((try #require(payload.objectValue?["physical_memory_bytes"]?.numberValue)) > (0))
    #expect((try #require(payload.objectValue?["page_size_bytes"]?.numberValue)) > (0))
    #expect((try #require(payload.objectValue?["pages"]?.objectValue?["free"]?.numberValue)) >= (0))
    #expect(
      (try #require(payload.objectValue?["bytes"]?.objectValue?["wired"]?.numberValue)) >= (0))
    #expect(
      (try #require(payload.objectValue?["events"]?.objectValue?["faults"]?.numberValue)) >= (0))
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testSystemLoadReturnsReadOnlyLoadAverage() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.load"])
      )
    )

    let result = try registry.callTool(
      name: "system.load", arguments: .object([:]), context: .empty)
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["operation"]) == (.string("system.load")))
    #expect((payload.objectValue?["source"]) == (.string("getloadavg")))
    #expect((try #require(payload.objectValue?["sample_count"]?.numberValue)) >= (1))
    #expect((try #require(payload.objectValue?["active_processor_count"]?.numberValue)) > (0))
    #expect(
      (try #require(payload.objectValue?["load_average"]?.objectValue?["one_minute"]?.numberValue))
        >= (0))
    #expect(
      (try #require(
        payload.objectValue?["load_per_active_processor"]?.objectValue?["one_minute"]?
          .numberValue)) >= (0))
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testSystemCPUReturnsReadOnlyProcessorSummary() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.cpu"])
      )
    )

    let result = try registry.callTool(name: "system.cpu", arguments: .object([:]), context: .empty)
    let payload = try decodeTextPayload(result)
    let processInfo = try #require(payload.objectValue?["process_info"]?.objectValue)
    let hardware = try #require(payload.objectValue?["hardware"]?.objectValue)
    let machine = try #require(hardware["machine"]?.stringValue)

    #expect((payload.objectValue?["operation"]) == (.string("system.cpu")))
    #expect(
      (payload.objectValue?["source"])
        == (.array([.string("ProcessInfo"), .string("sysctlbyname"), .string("uname")])))
    #expect((try #require(processInfo["processor_count"]?.numberValue)) > (0))
    #expect((try #require(processInfo["active_processor_count"]?.numberValue)) > (0))
    #expect(!(machine.isEmpty))
    #expect((hardware["model_identifier"]) != nil)
    #expect((hardware["brand_string"]) != nil)
    #expect((hardware["physical_cpu_count"]) != nil)
    #expect((hardware["logical_cpu_count"]) != nil)
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testSystemThermalReturnsReadOnlyConditionSummary() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.thermal"])
      )
    )

    let result = try registry.callTool(
      name: "system.thermal", arguments: .object([:]), context: .empty)
    let payload = try decodeTextPayload(result)
    let thermalState = try #require(payload.objectValue?["thermal_state"]?.stringValue)

    #expect((payload.objectValue?["operation"]) == (.string("system.thermal")))
    #expect((payload.objectValue?["source"]) == (.string("ProcessInfo")))
    #expect(["nominal", "fair", "serious", "critical", "unknown"].contains(thermalState))
    #expect((payload.objectValue?["thermal_state_rank"]?.numberValue) != nil)
    #expect((payload.objectValue?["low_power_mode_enabled"]?.boolValue) != nil)
    #expect((try #require(payload.objectValue?["processor_count"]?.numberValue)) > (0))
    #expect((try #require(payload.objectValue?["active_processor_count"]?.numberValue)) > (0))
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testSystemTimeReturnsLocalTimeSnapshot() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.time"])
      )
    )

    let result = try registry.callTool(
      name: "system.time", arguments: .object([:]), context: .empty)
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["now"]?.objectValue?["iso8601"]?.stringValue) != nil)
    #expect((payload.objectValue?["now"]?.objectValue?["unix_time"]?.numberValue) != nil)
    #expect(
      !(try #require(payload.objectValue?["time_zone"]?.objectValue?["identifier"]?.stringValue)
        .isEmpty))
    #expect((payload.objectValue?["time_zone"]?.objectValue?["seconds_from_gmt"]) != nil)
    #expect(
      (try #require(payload.objectValue?["system"]?.objectValue?["uptime_seconds"]?.numberValue))
        > (0))
  }

  @Test
  func testSystemUptimeReturnsReadOnlyBootTimeSummary() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.uptime"])
      )
    )

    let result = try registry.callTool(
      name: "system.uptime", arguments: .object([:]), context: .empty)
    let payload = try decodeTextPayload(result)
    let uptime = try #require(payload.objectValue?["uptime_seconds"]?.numberValue)
    let bootTime = try #require(payload.objectValue?["boot_time"]?.objectValue)
    let now = try #require(payload.objectValue?["now"]?.objectValue)
    let bootUnixTime = try #require(bootTime["unix_time"]?.numberValue)
    let nowUnixTime = try #require(now["unix_time"]?.numberValue)

    #expect((payload.objectValue?["operation"]) == (.string("system.uptime")))
    #expect(
      (payload.objectValue?["source"])
        == (.array([.string("ProcessInfo.systemUptime"), .string("Date")])))
    #expect((uptime) > (0))
    #expect((bootTime["iso8601"]?.stringValue) != nil)
    #expect((now["iso8601"]?.stringValue) != nil)
    #expect((bootUnixTime) < (nowUnixTime))
    #expect((abs((nowUnixTime - bootUnixTime) - uptime)) < (1))
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testSystemUserReturnsCurrentPOSIXIdentity() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.user"])
      )
    )

    let result = try registry.callTool(
      name: "system.user", arguments: .object([:]), context: .empty)
    let payload = try decodeTextPayload(result)
    let ids = try #require(payload.objectValue?["ids"]?.objectValue)
    let user = try #require(payload.objectValue?["user"]?.objectValue)
    let effectiveUser = try #require(payload.objectValue?["effective_user"]?.objectValue)
    let group = try #require(payload.objectValue?["group"]?.objectValue)
    let effectiveGroup = try #require(payload.objectValue?["effective_group"]?.objectValue)

    #expect((payload.objectValue?["operation"]) == (.string("system.user")))
    #expect(
      (payload.objectValue?["source"])
        == (.array([
          .string("getuid"),
          .string("geteuid"),
          .string("getgid"),
          .string("getegid"),
          .string("getpwuid"),
          .string("getgrgid"),
        ])))
    #expect((ids["uid"]) == (.number(Double(getuid()))))
    #expect((ids["effective_uid"]) == (.number(Double(geteuid()))))
    #expect((ids["gid"]) == (.number(Double(getgid()))))
    #expect((ids["effective_gid"]) == (.number(Double(getegid()))))
    #expect(!(try #require(user["name"]?.stringValue).isEmpty))
    #expect(!(try #require(effectiveUser["name"]?.stringValue).isEmpty))
    #expect(!(try #require(group["name"]?.stringValue).isEmpty))
    #expect(!(try #require(effectiveGroup["name"]?.stringValue).isEmpty))
    #expect((user["home_directory"]) != nil)
    #expect((user["shell"]) != nil)
    #expect((payload.objectValue?["users"]) == nil)
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testSystemGroupsReturnsCurrentSupplementaryGroups() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.groups"])
      )
    )

    let result = try registry.callTool(
      name: "system.groups", arguments: .object([:]), context: .empty)
    let payload = try decodeTextPayload(result)
    let groupCount = getgroups(0, nil)
    let groups = try #require(payload.objectValue?["supplementary_groups"]?.arrayValue)

    #expect((payload.objectValue?["operation"]) == (.string("system.groups")))
    #expect(
      (payload.objectValue?["source"])
        == (.array([
          .string("getgroups"),
          .string("getgid"),
          .string("getegid"),
          .string("getgrgid"),
        ])))
    #expect((payload.objectValue?["primary_gid"]) == (.number(Double(getgid()))))
    #expect((payload.objectValue?["effective_gid"]) == (.number(Double(getegid()))))
    #expect(
      (payload.objectValue?["supplementary_group_count"]) == (.number(Double(max(groupCount, 0)))))
    #expect((groups.count) == (max(Int(groupCount), 0)))
    if let first = groups.first?.objectValue {
      #expect((first["gid"]?.numberValue) != nil)
      #expect((first["group"]) != nil)
    }
    #expect((payload.objectValue?["users"]) == nil)
    #expect((payload.objectValue?["groups"]) == nil)
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testSystemPowerUsesPMSetWithoutShellInterpolation() throws {
    let runner = RecordingCommandRunner()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.power"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "system.power",
      arguments: .object(["timeout_ms": .number(1234)]), context: .empty
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/usr/bin/pmset"))
    #expect((runner.calls.first?.arguments) == (["-g", "batt"]))
    #expect((payload.objectValue?["operation"]) == (.string("system.power")))
  }

  @Test
  func testSystemVolumesReturnsMountedVolumeSummary() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.volumes"])
      )
    )

    let result = try registry.callTool(
      name: "system.volumes",
      arguments: .object(["include_hidden": .bool(false)]), context: .empty
    )
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["volume_count"]) != nil)
    #expect((payload.objectValue?["volumes"]?.arrayValue) != nil)
  }

  @Test
  func testSystemProcessesUsesPSFixedArgvAndParsesSnapshot() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = """
        123     1 root     Ss     0.0  0.1 01:02:03 /sbin/launchd
        456   123 exampleuser S      12.5 1.2 00:00:05 /Applications/Terminal.app/Terminal
      broken line
      """
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.processes"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "system.processes",
      arguments: .object([
        "query": .string("terminal"),
        "max_results": .number(5),
        "timeout_ms": .number(1234),
      ]), context: .empty
    )
    let payload = try decodeTextPayload(result)
    let processes = try #require(payload.objectValue?["processes"]?.arrayValue)
    let first = try #require(processes.first?.objectValue)

    #expect((runner.calls.first?.executable) == ("/bin/ps"))
    #expect(
      (runner.calls.first?.arguments)
        == (["-axo", "pid=,ppid=,user=,stat=,pcpu=,pmem=,etime=,comm="]))
    #expect((payload.objectValue?["operation"]) == (.string("system.processes")))
    #expect((payload.objectValue?["query"]) == (.string("terminal")))
    #expect((payload.objectValue?["process_count"]) == (.number(1)))
    #expect((first["parsed"]) == (.bool(true)))
    #expect((first["pid"]) == (.number(456)))
    #expect((first["parent_pid"]) == (.number(123)))
    #expect((first["user"]) == (.string("exampleuser")))
    #expect((first["state"]) == (.string("S")))
    #expect((first["cpu_percent"]) == (.number(12.5)))
    #expect((first["memory_percent"]) == (.number(1.2)))
    #expect((first["elapsed"]) == (.string("00:00:05")))
    #expect((first["command"]) == (.string("/Applications/Terminal.app/Terminal")))
  }

  @Test
  func testSystemProcessesReportsTruncationAndRejectsBadBounds() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = """
        123     1 root     Ss     0.0  0.1 01:02:03 /sbin/launchd
        456   123 exampleuser S      12.5 1.2 00:00:05 /Applications/Terminal.app/Terminal
      """
    runner.stdoutTruncated = true
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.processes"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "system.processes",
      arguments: .object(["max_results": .number(1)]), context: .empty
    )
    let payload = try decodeTextPayload(result)
    let processes = try #require(payload.objectValue?["processes"]?.arrayValue)

    #expect((processes.count) == (1))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout_truncated"]) == (.bool(true)))

    expectThrows(
      try registry.callTool(
        name: "system.processes",
        arguments: .object(["max_results": .number(0)]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_results"))
    }
  }

  @Test
  func testSystemWhichResolvesExecutableFromPathWithoutRunningIt() throws {
    let directory = try temporaryDirectory()
    let executable = directory.appendingPathComponent("sample-tool")
    try "#!/bin/sh\nexit 7\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.which"])
      ),
      environment: ["PATH": directory.path]
    )

    let result = try registry.callTool(
      name: "system.which",
      arguments: .object([
        "name": .string("sample-tool"),
        "all_matches": .bool(true),
      ]), context: .empty
    )
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["operation"]) == (.string("system.which")))
    #expect((payload.objectValue?["name"]) == (.string("sample-tool")))
    #expect((payload.objectValue?["found"]) == (.bool(true)))
    #expect((payload.objectValue?["resolved_path"]) == (.string(executable.path)))
    #expect((payload.objectValue?["paths"]) == (.array([.string(executable.path)])))
    #expect((payload.objectValue?["match_count"]) == (.number(1)))
    #expect((payload.objectValue?["all_matches"]) == (.bool(true)))
    #expect((payload.objectValue?["path_entry_count"]) == (.number(1)))
    #expect((payload.objectValue?["environment"]) == nil)

    let missing = try registry.callTool(
      name: "system.which",
      arguments: .object(["name": .string("missing-tool")]), context: .empty
    )
    let missingPayload = try decodeTextPayload(missing)
    #expect((missingPayload.objectValue?["found"]) == (.bool(false)))
    #expect((missingPayload.objectValue?["paths"]) == (.array([])))
  }

  @Test
  func testSystemWhichRejectsBadExecutableNames() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.which"])
      )
    )

    for name in ["", "-tool", "../tool", "bad tool", "."] {
      expectThrows(
        try registry.callTool(
          name: "system.which",
          arguments: .object(["name": .string(name)]), context: .empty
        )
      ) { error in
        #expect(error.localizedDescription.contains("name"))
      }
    }
  }

  @Test
  func testSystemPathReturnsStructuredEntriesWithoutEnvironmentDump() throws {
    let directory = try temporaryDirectory()
    let missing = directory.appendingPathComponent("missing")
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.path"])
      ),
      environment: ["PATH": "\(directory.path):\(missing.path):\(directory.path)"]
    )

    let result = try registry.callTool(
      name: "system.path",
      arguments: .object([
        "include_missing": .bool(true),
        "max_entries": .number(10),
      ]), context: .empty
    )
    let payload = try decodeTextPayload(result)
    let entries = try #require(payload.objectValue?["entries"]?.arrayValue)

    #expect((payload.objectValue?["operation"]) == (.string("system.path")))
    #expect((payload.objectValue?["source"]) == (.string("process_environment")))
    #expect((payload.objectValue?["path_entry_count"]) == (.number(3)))
    #expect((payload.objectValue?["returned_count"]) == (.number(3)))
    #expect((payload.objectValue?["environment"]) == nil)
    #expect((entries[0].objectValue?["path"]) == (.string(directory.path)))
    #expect((entries[0].objectValue?["exists"]) == (.bool(true)))
    #expect((entries[0].objectValue?["is_directory"]) == (.bool(true)))
    #expect((entries[0].objectValue?["is_absolute"]) == (.bool(true)))
    #expect((entries[0].objectValue?["duplicate_of_index"]) == (.null))
    #expect((entries[1].objectValue?["path"]) == (.string(missing.path)))
    #expect((entries[1].objectValue?["exists"]) == (.bool(false)))
    #expect((entries[1].objectValue?["is_directory"]) == (.bool(false)))
    #expect((entries[2].objectValue?["duplicate_of_index"]) == (.number(0)))

    let existingOnly = try registry.callTool(
      name: "system.path",
      arguments: .object([
        "include_missing": .bool(false),
        "max_entries": .number(1),
      ]), context: .empty
    )
    let existingPayload = try decodeTextPayload(existingOnly)
    let existingEntries = try #require(existingPayload.objectValue?["entries"]?.arrayValue)
    #expect((existingPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((existingPayload.objectValue?["truncated"]) == (.bool(true)))
    #expect((existingEntries.map { $0.objectValue?["path"] }) == ([.string(directory.path)]))
  }

  @Test
  func testSystemPathRejectsBadBounds() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["system.path"])
      )
    )

    expectThrows(
      try registry.callTool(
        name: "system.path",
        arguments: .object(["max_entries": .number(0)]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_entries"))
    }
  }

  @Test
  func testLogsQueryUsesBoundedNDJSONArgvAndParsesEvents() throws {
    let runner = RecordingCommandRunner()
    runner.stdout =
      """
      {"eventMessage":"first","processImagePath":"/usr/bin/example"}
      not-json
      {"eventMessage":"third"}
      """
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["logs.query"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "logs.query",
      arguments: .object([
        "last_seconds": .number(300),
        "max_entries": .number(2),
        "predicate": .string("process == \"example\""),
        "include_info": .bool(true),
        "include_debug": .bool(true),
        "timeout_ms": .number(12_345),
        "max_output_bytes": .number(65_536),
      ]), context: .empty
    )
    let payload = try decodeTextPayload(result)
    let events = try #require(payload.objectValue?["events"]?.arrayValue)
    let unparsed = try #require(payload.objectValue?["unparsed_lines"]?.arrayValue)

    #expect((runner.calls.first?.executable) == ("/usr/bin/log"))
    #expect(
      (runner.calls.first?.arguments)
        == ([
          "show", "--style", "ndjson", "--color", "none", "--no-pager", "--last", "300s",
          "--info", "--debug", "--predicate", "process == \"example\"",
        ]))
    #expect((runner.calls.first?.timeoutMilliseconds) == (12_345))
    #expect((runner.calls.first?.maxOutputBytes) == (65_536))
    #expect((payload.objectValue?["operation"]) == (.string("logs.query")))
    #expect((payload.objectValue?["source"]) == (.string("macos_unified_log")))
    #expect((payload.objectValue?["observed_line_count"]) == (.number(3)))
    #expect((payload.objectValue?["returned_line_count"]) == (.number(2)))
    #expect((payload.objectValue?["event_count"]) == (.number(1)))
    #expect((payload.objectValue?["unparsed_line_count"]) == (.number(1)))
    #expect((payload.objectValue?["omitted_line_count"]) == (.number(1)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
    #expect((events.first?.objectValue?["eventMessage"]) == (.string("first")))
    #expect((unparsed.first?.objectValue?["line"]) == (.string("not-json")))
    #expect((payload.objectValue?["execution"]?.objectValue?["stdout"]) == nil)
  }

  @Test
  func testLogsQueryRequiresExplicitBoundsAndRejectsBadPredicate() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["logs.query"])
      )
    )

    expectThrows(
      try registry.callTool(name: "logs.query", arguments: .object([:]), context: .empty)
    ) { error in
      #expect(error.localizedDescription.contains("last_seconds"))
    }
    expectThrows(
      try registry.callTool(
        name: "logs.query",
        arguments: .object([
          "last_seconds": .number(1),
          "max_entries": .number(0),
        ]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_entries"))
    }
    expectThrows(
      try registry.callTool(
        name: "logs.query",
        arguments: .object([
          "last_seconds": .number(1),
          "max_entries": .number(1),
          "predicate": .string(""),
        ]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("predicate"))
    }
  }

  @Test
  func testServiceStatusUsesCurrentUIDAndRedactsUnsafeLaunchctlSections() throws {
    let runner = RecordingCommandRunner()
    runner.stdout =
      """
      gui/501/com.example.worker = {
      \tactive count = 1
      \tpath = /Library/LaunchAgents/com.example.worker.plist
      \ttype = LaunchAgent
      \tstate = running
      \tenvironment = {
      \t\tSECRET_TOKEN => do-not-return
      \t}
      \tpid = 123
      \truns = 4
      }
      """
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["service.status"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "service.status",
      arguments: .object([
        "domain": .string("gui"),
        "label": .string("com.example.worker"),
      ]), context: .empty
    )
    let payload = try decodeTextPayload(result)
    let fields = try #require(payload.objectValue?["fields"]?.objectValue)
    let encoded = try JSONEncoder().encode(payload)
    let text = String(decoding: encoded, as: UTF8.self)

    #expect((runner.calls.first?.executable) == ("/bin/launchctl"))
    #expect((runner.calls.first?.arguments) == (["print", "gui/\(geteuid())/com.example.worker"]))
    #expect((payload.objectValue?["operation"]) == (.string("service.status")))
    #expect((payload.objectValue?["found"]) == (.bool(true)))
    #expect((payload.objectValue?["environment_returned"]) == (.bool(false)))
    #expect((payload.objectValue?["raw_output_returned"]) == (.bool(false)))
    #expect((fields["state"]) == (.string("running")))
    #expect((fields["pid"]) == (.number(123)))
    #expect((fields["runs"]) == (.number(4)))
    #expect((fields["environment"]) == nil)
    #expect(!(text.contains("SECRET_TOKEN")))
    #expect(!(text.contains("do-not-return")))
  }

  @Test
  func testServiceStatusReportsMissingAndRejectsUnsafeTargets() throws {
    let runner = RecordingCommandRunner()
    runner.exitCode = 113
    runner.stdout = "environment = { SECRET_TOKEN => do-not-return }"
    runner.stderr = "Could not find service"
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["service.status"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "service.status",
      arguments: .object([
        "domain": .string("system"),
        "label": .string("com.example.missing"),
      ]), context: .empty
    )
    let payload = try decodeTextPayload(result)
    #expect((runner.calls.first?.arguments) == (["print", "system/com.example.missing"]))
    #expect((payload.objectValue?["found"]) == (.bool(false)))
    #expect((payload.objectValue?["fields"]) == (.object([:])))
    #expect((payload.objectValue?["execution"]?.objectValue?["stdout"]) == nil)

    expectThrows(
      try registry.callTool(
        name: "service.status",
        arguments: .object([
          "domain": .string("login"),
          "label": .string("com.example.worker"),
        ]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("domain"))
    }
    expectThrows(
      try registry.callTool(
        name: "service.status",
        arguments: .object([
          "domain": .string("gui"),
          "label": .string("../com.example.worker"),
        ]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("label"))
    }
  }

  @Test
  func testNetworkInterfacesUsesIfconfigWithFixedArgv() throws {
    let runner = RecordingCommandRunner()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.interfaces"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "network.interfaces",
      arguments: .object(["interface": .string("lo0")]), context: .empty
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/sbin/ifconfig"))
    #expect((runner.calls.first?.arguments) == (["lo0"]))
    #expect((payload.objectValue?["operation"]) == (.string("network.interfaces")))
    #expect((payload.objectValue?["interface"]) == (.string("lo0")))

    _ = try registry.callTool(name: "network.interfaces", arguments: .object([:]), context: .empty)
    #expect((runner.calls.last?.arguments) == (["-a"]))
  }

  @Test
  func testNetworkInterfacesRejectsOptionLikeInterfaceName() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.interfaces"])
      )
    )

    expectThrows(
      try registry.callTool(
        name: "network.interfaces",
        arguments: .object(["interface": .string("-a")]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("option"))
    }
  }

  @Test
  func testNetworkDNSUsesSCUtilWithFixedArgv() throws {
    let runner = RecordingCommandRunner()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.dns"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "network.dns", arguments: .object([:]), context: .empty)
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/usr/sbin/scutil"))
    #expect((runner.calls.first?.arguments) == (["--dns"]))
    #expect((payload.objectValue?["operation"]) == (.string("network.dns")))
  }

  @Test
  func testNetworkResolveUsesSystemResolverWithoutShell() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.resolve"])
      )
    )

    let result = try registry.callTool(
      name: "network.resolve",
      arguments: .object([
        "host": .string("localhost"),
        "family": .string("ipv4"),
      ]), context: .empty
    )
    let payload = try decodeTextPayload(result)
    let addresses = try #require(payload.objectValue?["addresses"]?.arrayValue)

    #expect((payload.objectValue?["operation"]) == (.string("network.resolve")))
    #expect((payload.objectValue?["source"]) == (.string("getaddrinfo")))
    #expect((payload.objectValue?["host"]) == (.string("localhost")))
    #expect((payload.objectValue?["family"]) == (.string("ipv4")))
    #expect((payload.objectValue?["resolved"]) == (.bool(true)))
    #expect((addresses.count) >= (1))
    #expect(
      addresses.contains { address in
        address.objectValue?["family"] == .string("ipv4")
          && address.objectValue?["address"] == .string("127.0.0.1")
      })
    #expect((payload.objectValue?["result"]) == nil)
  }

  @Test
  func testNetworkResolveReportsUnresolvedHostAsResult() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.resolve"])
      )
    )

    let result = try registry.callTool(
      name: "network.resolve",
      arguments: .object([
        "host": .string("::1"),
        "family": .string("ipv4"),
      ]), context: .empty
    )
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["operation"]) == (.string("network.resolve")))
    #expect((payload.objectValue?["resolved"]) == (.bool(false)))
    #expect((payload.objectValue?["error_code"]?.numberValue) != nil)
    #expect(!(try #require(payload.objectValue?["error"]?.stringValue).isEmpty))
    #expect((payload.objectValue?["addresses"]) == (.array([])))
  }

  @Test
  func testNetworkResolveRejectsBadInputs() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.resolve"])
      )
    )

    expectThrows(
      try registry.callTool(
        name: "network.resolve",
        arguments: .object(["host": .string("https://example.com")]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("URL"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.resolve",
        arguments: .object([
          "host": .string("localhost"),
          "family": .string("link"),
        ]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("family"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.resolve",
        arguments: .object([
          "host": .string("localhost"),
          "max_results": .number(0),
        ]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_results"))
    }
  }

  @Test
  func testNetworkProxyUsesSCUtilWithFixedArgv() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = """
      <dictionary> {
        HTTPEnable : 0
        HTTPSEnable : 0
      }
      """
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.proxy"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "network.proxy",
      arguments: .object(["timeout_ms": .number(1234)]), context: .empty
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/usr/sbin/scutil"))
    #expect((runner.calls.first?.arguments) == (["--proxy"]))
    #expect((runner.calls.first?.timeoutMilliseconds) == (1234))
    #expect((payload.objectValue?["operation"]) == (.string("network.proxy")))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout"]) == (.string(runner.stdout)))
  }

  @Test
  func testNetworkProxyRejectsBadTimeout() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.proxy"])
      )
    )

    expectThrows(
      try registry.callTool(
        name: "network.proxy",
        arguments: .object(["timeout_ms": .number(0)]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("timeout_ms"))
    }
  }

  @Test
  func testNetworkServicesUsesNetworkSetupWithFixedArgv() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = """
      An asterisk (*) denotes that a network service is disabled.
      Wi-Fi
      Thunderbolt Bridge
      """
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.services"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "network.services",
      arguments: .object([
        "timeout_ms": .number(1234),
        "max_output_bytes": .number(4096),
      ]), context: .empty
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/usr/sbin/networksetup"))
    #expect((runner.calls.first?.arguments) == (["-listallnetworkservices"]))
    #expect((runner.calls.first?.timeoutMilliseconds) == (1234))
    #expect((runner.calls.first?.maxOutputBytes) == (4096))
    #expect((payload.objectValue?["operation"]) == (.string("network.services")))
    #expect((payload.objectValue?["argv"]) == (.array([.string("-listallnetworkservices")])))
    #expect((payload.objectValue?["max_output_bytes"]) == (.number(4096)))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout"]) == (.string(runner.stdout)))
  }

  @Test
  func testNetworkServicesRejectsBadBounds() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.services"])
      )
    )

    expectThrows(
      try registry.callTool(
        name: "network.services",
        arguments: .object(["timeout_ms": .number(0)]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("timeout_ms"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.services",
        arguments: .object(["max_output_bytes": .number(0)]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testNetworkHardwarePortsUsesNetworkSetupWithFixedArgv() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = """
      Hardware Port: Wi-Fi
      Device: en0
      Ethernet Address: aa:bb:cc:dd:ee:ff
      """
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.hardware_ports"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "network.hardware_ports",
      arguments: .object([
        "timeout_ms": .number(1234),
        "max_output_bytes": .number(4096),
      ]), context: .empty
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/usr/sbin/networksetup"))
    #expect((runner.calls.first?.arguments) == (["-listallhardwareports"]))
    #expect((runner.calls.first?.timeoutMilliseconds) == (1234))
    #expect((runner.calls.first?.maxOutputBytes) == (4096))
    #expect((payload.objectValue?["operation"]) == (.string("network.hardware_ports")))
    #expect((payload.objectValue?["argv"]) == (.array([.string("-listallhardwareports")])))
    #expect((payload.objectValue?["max_output_bytes"]) == (.number(4096)))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout"]) == (.string(runner.stdout)))
  }

  @Test
  func testNetworkHardwarePortsRejectsBadBounds() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.hardware_ports"])
      )
    )

    expectThrows(
      try registry.callTool(
        name: "network.hardware_ports",
        arguments: .object(["timeout_ms": .number(0)]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("timeout_ms"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.hardware_ports",
        arguments: .object(["max_output_bytes": .number(0)]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testNetworkWiFiDiscoversDeviceAndUsesFixedNetworkSetupArgv() throws {
    let runner = RecordingCommandRunner()
    runner.outputs = [
      RecordingCommandRunner.Output(
        stdout: """
          Hardware Port: Thunderbolt Bridge
          Device: bridge0
          Ethernet Address: aa:bb:cc:dd:ee:00

          Hardware Port: Wi-Fi
          Device: en0
          Ethernet Address: aa:bb:cc:dd:ee:ff
          """),
      RecordingCommandRunner.Output(stdout: "Wi-Fi Power (en0): On\n"),
      RecordingCommandRunner.Output(stdout: "Current Wi-Fi Network: StudioNet\n"),
    ]
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.wifi"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "network.wifi",
      arguments: .object([
        "timeout_ms": .number(1234),
        "max_output_bytes": .number(4096),
      ]), context: .empty
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.count) == (3))
    #expect((runner.calls[0].executable) == ("/usr/sbin/networksetup"))
    #expect((runner.calls[0].arguments) == (["-listallhardwareports"]))
    #expect((runner.calls[1].arguments) == (["-getairportpower", "en0"]))
    #expect((runner.calls[2].arguments) == (["-getairportnetwork", "en0"]))
    #expect((runner.calls[0].timeoutMilliseconds) == (1234))
    #expect((runner.calls[1].maxOutputBytes) == (4096))
    #expect((payload.objectValue?["operation"]) == (.string("network.wifi")))
    #expect((payload.objectValue?["available"]) == (.bool(true)))
    #expect((payload.objectValue?["device"]) == (.string("en0")))
    #expect((payload.objectValue?["hardware_port"]) == (.string("Wi-Fi")))
    #expect((payload.objectValue?["power"]) == (.string("on")))
    #expect((payload.objectValue?["associated"]) == (.bool(true)))
    #expect((payload.objectValue?["ssid"]) == (.string("StudioNet")))
    #expect(
      (payload.objectValue?["discovery_argv"]) == (.array([.string("-listallhardwareports")])))
    #expect((payload.objectValue?["discovery"]?.objectValue?["stdout"]) == nil)
  }

  @Test
  func testNetworkWiFiReportsUnavailableWithoutRunningPowerQueries() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = """
      Hardware Port: Thunderbolt Bridge
      Device: bridge0
      Ethernet Address: aa:bb:cc:dd:ee:00
      """
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.wifi"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "network.wifi", arguments: .object([:]), context: .empty)
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.count) == (1))
    #expect((payload.objectValue?["operation"]) == (.string("network.wifi")))
    #expect((payload.objectValue?["available"]) == (.bool(false)))
    #expect((payload.objectValue?["device"]) == (.null))
    #expect((payload.objectValue?["associated"]) == (.bool(false)))
    #expect((payload.objectValue?["ssid"]) == (.null))
    #expect((payload.objectValue?["power_argv"]) == (.null))
    #expect((payload.objectValue?["network_argv"]) == (.null))
  }

  @Test
  func testNetworkWiFiRejectsBadInputs() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.wifi"])
      )
    )

    expectThrows(
      try registry.callTool(
        name: "network.wifi",
        arguments: .object(["device": .string("-bad")]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("interface"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.wifi",
        arguments: .object(["timeout_ms": .number(0)]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("timeout_ms"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.wifi",
        arguments: .object(["max_output_bytes": .number(0)]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testNetworkVPNUsesScutilNCListAndParsesServices() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = """
      Available network connection services in the current set (*=enabled):
      * (Disconnected)   53F34FF6-F7ED-4085-8674-4EACFD48520A PPP --> LG Monitor Controls "LG Monitor Controls"            [PPP:Modem]
        (Connected)      11111111-2222-3333-4444-555555555555 IKEv2 --> Work VPN "Work VPN"            [VPN:IKEv2]
      """
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.vpn"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "network.vpn",
      arguments: .object([
        "max_results": .number(1),
        "timeout_ms": .number(1234),
        "max_output_bytes": .number(4096),
      ]), context: .empty
    )
    let payload = try decodeTextPayload(result)
    let services = try #require(payload.objectValue?["services"]?.arrayValue)
    let first = try #require(services.first?.objectValue)

    #expect((runner.calls.count) == (1))
    #expect((runner.calls[0].executable) == ("/usr/sbin/scutil"))
    #expect((runner.calls[0].arguments) == (["--nc", "list"]))
    #expect((runner.calls[0].timeoutMilliseconds) == (1234))
    #expect((runner.calls[0].maxOutputBytes) == (4096))
    #expect((payload.objectValue?["operation"]) == (.string("network.vpn")))
    #expect((payload.objectValue?["argv"]) == (.array([.string("--nc"), .string("list")])))
    #expect((payload.objectValue?["service_count"]) == (.number(2)))
    #expect((payload.objectValue?["returned_count"]) == (.number(1)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
    #expect((first["enabled"]) == (.bool(true)))
    #expect((first["status"]) == (.string("Disconnected")))
    #expect((first["connected"]) == (.bool(false)))
    #expect((first["id"]) == (.string("53F34FF6-F7ED-4085-8674-4EACFD48520A")))
    #expect((first["name"]) == (.string("LG Monitor Controls")))
    #expect((first["protocol"]) == (.string("PPP")))
    #expect((first["type"]) == (.string("PPP:Modem")))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout"]) == nil)
  }

  @Test
  func testNetworkVPNRejectsBadBounds() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.vpn"])
      )
    )

    expectThrows(
      try registry.callTool(
        name: "network.vpn",
        arguments: .object(["max_results": .number(0)]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_results"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.vpn",
        arguments: .object(["timeout_ms": .number(0)]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("timeout_ms"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.vpn",
        arguments: .object(["max_output_bytes": .number(0)]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testNetworkLocationsUsesNetworkSetupWithFixedArgv() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = "Automatic\n"
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.locations"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "network.locations",
      arguments: .object([
        "timeout_ms": .number(1234),
        "max_output_bytes": .number(4096),
      ]), context: .empty
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.count) == (2))
    #expect((runner.calls[0].executable) == ("/usr/sbin/networksetup"))
    #expect((runner.calls[0].arguments) == (["-getcurrentlocation"]))
    #expect((runner.calls[0].timeoutMilliseconds) == (1234))
    #expect((runner.calls[0].maxOutputBytes) == (4096))
    #expect((runner.calls[1].executable) == ("/usr/sbin/networksetup"))
    #expect((runner.calls[1].arguments) == (["-listlocations"]))
    #expect((runner.calls[1].timeoutMilliseconds) == (1234))
    #expect((runner.calls[1].maxOutputBytes) == (4096))
    #expect((payload.objectValue?["operation"]) == (.string("network.locations")))
    #expect((payload.objectValue?["current_argv"]) == (.array([.string("-getcurrentlocation")])))
    #expect((payload.objectValue?["list_argv"]) == (.array([.string("-listlocations")])))
    #expect((payload.objectValue?["max_output_bytes"]) == (.number(4096)))
    #expect((payload.objectValue?["current"]?.objectValue?["stdout"]) == (.string("Automatic\n")))
    #expect((payload.objectValue?["locations"]?.objectValue?["stdout"]) == (.string("Automatic\n")))
  }

  @Test
  func testNetworkLocationsRejectsBadBounds() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.locations"])
      )
    )

    expectThrows(
      try registry.callTool(
        name: "network.locations",
        arguments: .object(["timeout_ms": .number(0)]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("timeout_ms"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.locations",
        arguments: .object(["max_output_bytes": .number(0)]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testNetworkRoutesUsesNetstatWithFixedArgv() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = """
      Routing tables

      Internet:
      Destination        Gateway            Flags        Netif Expire
      default            192.168.1.1        UGSc           en0
      """
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.routes"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "network.routes",
      arguments: .object([
        "family": .string("inet"),
        "timeout_ms": .number(1234),
        "max_output_bytes": .number(4096),
      ]), context: .empty
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/usr/sbin/netstat"))
    #expect((runner.calls.first?.arguments) == (["-rn", "-f", "inet"]))
    #expect((runner.calls.first?.timeoutMilliseconds) == (1234))
    #expect((runner.calls.first?.maxOutputBytes) == (4096))
    #expect((payload.objectValue?["operation"]) == (.string("network.routes")))
    #expect((payload.objectValue?["family"]) == (.string("inet")))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout"]) == (.string(runner.stdout)))

    _ = try registry.callTool(name: "network.routes", arguments: .object([:]), context: .empty)
    #expect((runner.calls.last?.arguments) == (["-rn"]))
  }

  @Test
  func testNetworkRoutesRejectsBadInputs() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.routes"])
      )
    )

    expectThrows(
      try registry.callTool(
        name: "network.routes",
        arguments: .object(["family": .string("link")]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("family"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.routes",
        arguments: .object(["timeout_ms": .number(0)]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("timeout_ms"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.routes",
        arguments: .object(["max_output_bytes": .number(0)]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testNetworkConnectionsUsesNetstatWithFixedArgv() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = """
      Active Internet connections (including servers)
      Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
      tcp4       0      0  127.0.0.1.51712       127.0.0.1.3000         ESTABLISHED
      """
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.connections"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "network.connections",
      arguments: .object([
        "family": .string("inet"),
        "timeout_ms": .number(1234),
        "max_output_bytes": .number(4096),
      ]), context: .empty
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/usr/sbin/netstat"))
    #expect((runner.calls.first?.arguments) == (["-an", "-f", "inet"]))
    #expect((runner.calls.first?.timeoutMilliseconds) == (1234))
    #expect((runner.calls.first?.maxOutputBytes) == (4096))
    #expect((payload.objectValue?["operation"]) == (.string("network.connections")))
    #expect((payload.objectValue?["family"]) == (.string("inet")))
    #expect(
      (payload.objectValue?["argv"]) == (.array([.string("-an"), .string("-f"), .string("inet")])))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout"]) == (.string(runner.stdout)))

    _ = try registry.callTool(name: "network.connections", arguments: .object([:]), context: .empty)
    #expect((runner.calls.last?.arguments) == (["-an"]))
  }

  @Test
  func testNetworkConnectionsRejectsBadInputs() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.connections"])
      )
    )

    expectThrows(
      try registry.callTool(
        name: "network.connections",
        arguments: .object(["family": .string("link")]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("family"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.connections",
        arguments: .object(["timeout_ms": .number(0)]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("timeout_ms"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.connections",
        arguments: .object(["max_output_bytes": .number(0)]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testNetworkARPUsesARPWithFixedArgv() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = """
      ? (192.168.1.1) at aa:bb:cc:dd:ee:ff on en0 ifscope [ethernet]
      """
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.arp"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "network.arp",
      arguments: .object([
        "timeout_ms": .number(1234),
        "max_output_bytes": .number(4096),
      ]), context: .empty
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/usr/sbin/arp"))
    #expect((runner.calls.first?.arguments) == (["-an"]))
    #expect((runner.calls.first?.timeoutMilliseconds) == (1234))
    #expect((runner.calls.first?.maxOutputBytes) == (4096))
    #expect((payload.objectValue?["operation"]) == (.string("network.arp")))
    #expect((payload.objectValue?["argv"]) == (.array([.string("-an")])))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout"]) == (.string(runner.stdout)))
  }

  @Test
  func testNetworkARPRejectsBadBounds() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.arp"])
      )
    )

    expectThrows(
      try registry.callTool(
        name: "network.arp",
        arguments: .object(["timeout_ms": .number(0)]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("timeout_ms"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.arp",
        arguments: .object(["max_output_bytes": .number(0)]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testNetworkPingUsesPingWithFixedArgv() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = """
      PING 127.0.0.1 (127.0.0.1): 56 data bytes
      64 bytes from 127.0.0.1: icmp_seq=0 ttl=64 time=0.044 ms
      """
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.ping"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "network.ping",
      arguments: .object([
        "host": .string("127.0.0.1"),
        "count": .number(2),
        "timeout_ms": .number(1234),
        "max_output_bytes": .number(4096),
      ]), context: .empty
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/sbin/ping"))
    #expect((runner.calls.first?.arguments) == (["-c", "2", "127.0.0.1"]))
    #expect((runner.calls.first?.timeoutMilliseconds) == (1234))
    #expect((runner.calls.first?.maxOutputBytes) == (4096))
    #expect((payload.objectValue?["operation"]) == (.string("network.ping")))
    #expect((payload.objectValue?["host"]) == (.string("127.0.0.1")))
    #expect((payload.objectValue?["count"]) == (.number(2)))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([.string("-c"), .string("2"), .string("127.0.0.1")])))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout"]) == (.string(runner.stdout)))
  }

  @Test
  func testNetworkPingRejectsBadInputs() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.ping"])
      )
    )

    expectThrows(
      try registry.callTool(
        name: "network.ping",
        arguments: .object(["host": .string("-c")]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("option"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.ping",
        arguments: .object(["host": .string("https://example.com")]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("URL"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.ping",
        arguments: .object([
          "host": .string("localhost"),
          "count": .number(0),
        ]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("count"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.ping",
        arguments: .object([
          "host": .string("localhost"),
          "max_output_bytes": .number(0),
        ]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testNetworkTCPCheckUsesNCWithFixedArgv() throws {
    let runner = RecordingCommandRunner()
    runner.stderr = "Connection to 127.0.0.1 port 443 [tcp/https] succeeded!\n"
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.tcp_check"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "network.tcp_check",
      arguments: .object([
        "host": .string("127.0.0.1"),
        "port": .number(443),
        "connect_timeout_seconds": .number(2),
        "timeout_ms": .number(3456),
        "max_output_bytes": .number(4096),
      ]), context: .empty
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/usr/bin/nc"))
    #expect((runner.calls.first?.arguments) == (["-G", "2", "-zv", "127.0.0.1", "443"]))
    #expect((runner.calls.first?.timeoutMilliseconds) == (3456))
    #expect((runner.calls.first?.maxOutputBytes) == (4096))
    #expect((payload.objectValue?["operation"]) == (.string("network.tcp_check")))
    #expect((payload.objectValue?["host"]) == (.string("127.0.0.1")))
    #expect((payload.objectValue?["port"]) == (.number(443)))
    #expect((payload.objectValue?["connect_timeout_seconds"]) == (.number(2)))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([
          .string("-G"), .string("2"), .string("-zv"), .string("127.0.0.1"), .string("443"),
        ])))
    #expect((payload.objectValue?["result"]?.objectValue?["stderr"]) == (.string(runner.stderr)))
  }

  @Test
  func testNetworkTCPCheckRejectsBadInputs() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.tcp_check"])
      )
    )

    expectThrows(
      try registry.callTool(
        name: "network.tcp_check",
        arguments: .object(["host": .string("localhost")]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("port"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.tcp_check",
        arguments: .object([
          "host": .string("-example.com"),
          "port": .number(443),
        ]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("option"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.tcp_check",
        arguments: .object([
          "host": .string("https://example.com"),
          "port": .number(443),
        ]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("URL"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.tcp_check",
        arguments: .object([
          "host": .string("localhost"),
          "port": .number(0),
        ]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("port"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.tcp_check",
        arguments: .object([
          "host": .string("localhost"),
          "port": .number(443),
          "connect_timeout_seconds": .number(0),
        ]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("connect_timeout_seconds"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.tcp_check",
        arguments: .object([
          "host": .string("localhost"),
          "port": .number(443),
          "max_output_bytes": .number(0),
        ]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testNetworkHTTPCheckUsesCurlWithFixedArgvAndParsesMetadata() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = """
      hello
      __COMPUTER_MCP_HTTP_CHECK_META__
      http_code=200
      url_effective=https://example.com/health
      content_type=text/plain
      redirect_url=
      time_total=0.125000
      size_download=5
      """
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.http_check"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "network.http_check",
      arguments: .object([
        "url": .string("https://example.com/health"),
        "method": .string("GET"),
        "include_body": .bool(true),
        "follow_redirects": .bool(true),
        "max_redirects": .number(3),
        "connect_timeout_seconds": .number(2),
        "timeout_ms": .number(3456),
        "max_body_bytes": .number(128),
        "max_output_bytes": .number(4096),
      ]), context: .empty
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/usr/bin/curl"))
    #expect((runner.calls.first?.timeoutMilliseconds) == (3456))
    #expect((runner.calls.first?.maxOutputBytes) == (4096))
    #expect(
      (runner.calls.first?.arguments)
        == ([
          "--silent", "--show-error", "--max-time", "3", "--connect-timeout", "2",
          "--location", "--max-redirs", "3", "--request", "GET", "--range", "0-127",
          "--output", "-", "--write-out",
          "\n__COMPUTER_MCP_HTTP_CHECK_META__\nhttp_code=%{http_code}\nurl_effective=%{url_effective}\ncontent_type=%{content_type}\nredirect_url=%{redirect_url}\ntime_total=%{time_total}\nsize_download=%{size_download}\n",
          "https://example.com/health",
        ]))
    #expect((payload.objectValue?["operation"]) == (.string("network.http_check")))
    #expect((payload.objectValue?["method"]) == (.string("GET")))
    #expect((payload.objectValue?["include_body"]) == (.bool(true)))
    #expect((payload.objectValue?["follow_redirects"]) == (.bool(true)))
    #expect((payload.objectValue?["http_code"]) == (.number(200)))
    #expect((payload.objectValue?["url_effective"]) == (.string("https://example.com/health")))
    #expect((payload.objectValue?["content_type"]) == (.string("text/plain")))
    #expect((payload.objectValue?["redirect_url"]) == (.null))
    #expect((payload.objectValue?["time_total_seconds"]) == (.number(0.125)))
    #expect((payload.objectValue?["size_download_bytes"]) == (.number(5)))
    #expect((payload.objectValue?["body"]) == (.string("hello")))
    #expect((payload.objectValue?["body_truncated"]) == (.bool(false)))
    #expect((payload.objectValue?["meta_found"]) == (.bool(true)))
  }

  @Test
  func testNetworkHTTPCheckDefaultsToHeadAndRejectsBadInputs() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = """

      __COMPUTER_MCP_HTTP_CHECK_META__
      http_code=404
      url_effective=http://127.0.0.1:8080/mcp
      content_type=
      redirect_url=
      time_total=0.010000
      size_download=0
      """
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.http_check"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "network.http_check",
      arguments: .object(["url": .string("http://127.0.0.1:8080/mcp")]), context: .empty
    )
    let payload = try decodeTextPayload(result)

    #expect(runner.calls.first?.arguments.contains("--head") == true)
    #expect(runner.calls.first?.arguments.contains("/dev/null") == true)
    #expect((payload.objectValue?["method"]) == (.string("HEAD")))
    #expect((payload.objectValue?["include_body"]) == (.bool(false)))
    #expect((payload.objectValue?["http_code"]) == (.number(404)))
    #expect((payload.objectValue?["body"]) == (.null))

    expectThrows(
      try registry.callTool(
        name: "network.http_check",
        arguments: .object(["url": .string("ftp://example.com")]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("http or https"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.http_check",
        arguments: .object(["url": .string("https://user:pass@example.com")]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("userinfo"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.http_check",
        arguments: .object([
          "url": .string("https://example.com"),
          "method": .string("POST"),
        ]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("HEAD or GET"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.http_check",
        arguments: .object([
          "url": .string("https://example.com"),
          "max_body_bytes": .number(0),
        ]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_body_bytes"))
    }
  }

  @Test
  func testNetworkListenersUsesLSOFWithFixedArgv() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = """
      COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
      node    12345 test   12u  IPv4 0x0000      0t0  TCP 127.0.0.1:3000 (LISTEN)
      """
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.listeners"])
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "network.listeners",
      arguments: .object([
        "timeout_ms": .number(1234),
        "max_output_bytes": .number(4096),
      ]), context: .empty
    )
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/usr/sbin/lsof"))
    #expect((runner.calls.first?.arguments) == (["-nP", "-iTCP", "-sTCP:LISTEN"]))
    #expect((runner.calls.first?.timeoutMilliseconds) == (1234))
    #expect((runner.calls.first?.maxOutputBytes) == (4096))
    #expect((payload.objectValue?["operation"]) == (.string("network.listeners")))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([.string("-nP"), .string("-iTCP"), .string("-sTCP:LISTEN")])))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout"]) == (.string(runner.stdout)))
  }

  @Test
  func testNetworkListenersRejectsBadBounds() {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["network.listeners"])
      )
    )

    expectThrows(
      try registry.callTool(
        name: "network.listeners",
        arguments: .object(["timeout_ms": .number(0)]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("timeout_ms"))
    }

    expectThrows(
      try registry.callTool(
        name: "network.listeners",
        arguments: .object(["max_output_bytes": .number(0)]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testMacOSApplicationsReturnsBoundedApplicationSummary() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["macos.applications"])
      )
    )

    let result = try registry.callTool(
      name: "macos.applications",
      arguments: .object([
        "include_system": .bool(true),
        "include_user": .bool(false),
        "max_results": .number(5),
        "max_depth": .number(2),
      ]), context: .empty
    )
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["include_system"]) == (.bool(true)))
    #expect((payload.objectValue?["include_user"]) == (.bool(false)))
    #expect((payload.objectValue?["max_depth"]) == (.number(2)))
    #expect((payload.objectValue?["application_count"]) != nil)
    #expect((payload.objectValue?["applications"]?.arrayValue) != nil)
  }

  @Test
  func testMacOSUserDirectoriesReturnsFixedDirectoryCatalog() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["macos.user_directories"])
      )
    )

    let result = try registry.callTool(
      name: "macos.user_directories",
      arguments: .object([
        "include_missing": .bool(true),
        "include_system": .bool(true),
        "include_temporary": .bool(true),
      ]), context: .empty
    )
    let payload = try decodeTextPayload(result)
    let directories = try #require(payload.objectValue?["directories"]?.arrayValue)
    let byID = Dictionary(
      uniqueKeysWithValues: directories.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let id = object["id"]?.stringValue
        else {
          return nil
        }
        return (id, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("macos.user_directories")))
    #expect((payload.objectValue?["include_missing"]) == (.bool(true)))
    #expect((payload.objectValue?["include_system"]) == (.bool(true)))
    #expect((payload.objectValue?["include_temporary"]) == (.bool(true)))
    #expect((byID["home"]?["exists"]) == (.bool(true)))
    #expect((byID["home"]?["type"]) == (.string("directory")))
    #expect((byID["home"]?["path"]?.stringValue) != nil)
    #expect((byID["local_applications"]?["path"]) == (.string("/Applications")))
    #expect((byID["temporary"]?["exists"]) == (.bool(true)))
    #expect((byID["home"]?["children"]) == nil)
    #expect((byID["home"]?["contents"]) == nil)

    let filteredResult = try registry.callTool(
      name: "macos.user_directories",
      arguments: .object([
        "include_missing": .bool(false),
        "include_system": .bool(false),
        "include_temporary": .bool(false),
      ]), context: .empty
    )
    let filteredPayload = try decodeTextPayload(filteredResult)
    let filteredDirectories = try #require(
      filteredPayload.objectValue?["directories"]?.arrayValue)
    let filteredIDs = Set(filteredDirectories.compactMap { $0.objectValue?["id"]?.stringValue })
    #expect(!(filteredIDs.contains("local_applications")))
    #expect(!(filteredIDs.contains("system_applications")))
    #expect(!(filteredIDs.contains("temporary")))
    #expect(filteredIDs.contains("home"))
    #expect((filteredPayload.objectValue?["include_missing"]) == (.bool(false)))
  }

  @Test
  func testMacOSDefaultApplicationReturnsReadOnlyHandlerInfo() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("note.txt")
    try "hello\n".write(to: file, atomically: true, encoding: .utf8)

    var config = GatewayConfiguration.fixture(
      builtin: BuiltinConfig(enabled: ["macos.default_application"])
    )
    config.workspaceDirectory = directory
    let registry = GatewayToolRegistry(configuration: config)

    let result = try registry.callTool(
      name: "macos.default_application",
      arguments: .object([
        "path": .string("note.txt"),
        "include_candidates": .bool(true),
        "max_candidates": .number(2),
      ]), context: .empty
    )
    let payload = try decodeTextPayload(result)
    let target = try #require(payload.objectValue?["target"]?.objectValue)

    #expect((payload.objectValue?["operation"]) == (.string("macos.default_application")))
    #expect((target["type"]) == (.string("path")))
    #expect((target["workspace_relative_path"]) == (.string("note.txt")))
    #expect((payload.objectValue?["include_candidates"]) == (.bool(true)))
    #expect((payload.objectValue?["max_candidates"]) == (.number(2)))
    #expect((payload.objectValue?["default_application_available"]) != nil)
    #expect((payload.objectValue?["default_application"]) != nil)
    #expect((payload.objectValue?["candidate_applications"]?.arrayValue?.count ?? 0) <= (2))

    let urlResult = try registry.callTool(
      name: "macos.default_application",
      arguments: .object(["url": .string("https://example.com")]), context: .empty
    )
    let urlPayload = try decodeTextPayload(urlResult)
    let urlTarget = try #require(urlPayload.objectValue?["target"]?.objectValue)
    #expect((urlTarget["type"]) == (.string("url")))
    #expect((urlTarget["scheme"]) == (.string("https")))

    expectThrows(
      try registry.callTool(
        name: "macos.default_application",
        arguments: .object([
          "path": .string("note.txt"),
          "url": .string("https://example.com"),
        ]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("exactly one"))
    }

    expectThrows(
      try registry.callTool(
        name: "macos.default_application",
        arguments: .object(["url": .string("file:///tmp/example.txt")]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("url scheme"))
    }
  }

  @Test
  func testMacOSScreensReturnsReadOnlyDisplaySummary() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["macos.screens"])
      )
    )

    let result = try registry.callTool(
      name: "macos.screens", arguments: .object([:]), context: .empty)
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["screen_count"]) != nil)
    #expect((payload.objectValue?["screens"]?.arrayValue) != nil)
  }

  @Test
  func testMacOSSpotlightSearchUsesMDFindWithinWorkspace() throws {
    let directory = try temporaryDirectory()
    let notes = directory.appendingPathComponent("notes", isDirectory: true)
    try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
    let file = notes.appendingPathComponent("alpha.txt")
    try "alpha".write(to: file, atomically: true, encoding: .utf8)

    let runner = RecordingCommandRunner()
    runner.stdout =
      "\(file.path)\n/tmp/outside.txt\n\(notes.appendingPathComponent("missing.txt").path)\n"
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["macos.spotlight_search"]),
        workspaceDirectory: directory
      ),
      commandRunner: runner
    )

    let result = try registry.callTool(
      name: "macos.spotlight_search",
      arguments: .object([
        "path": .string("notes"),
        "query": .string("alpha"),
        "max_results": .number(5),
        "max_output_bytes": .number(4096),
      ]), context: .empty
    )
    let payload = try decodeTextPayload(result)
    let results = try #require(payload.objectValue?["results"]?.arrayValue)

    #expect((runner.calls.first?.executable) == ("/usr/bin/mdfind"))
    #expect((runner.calls.first?.arguments) == (["-onlyin", notes.path, "alpha"]))
    #expect((payload.objectValue?["operation"]) == (.string("macos.spotlight_search")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("notes")))
    #expect((payload.objectValue?["returned_path_count"]) == (.number(3)))
    #expect((payload.objectValue?["result_count"]) == (.number(1)))
    #expect((payload.objectValue?["truncated"]) == (.bool(false)))
    #expect((payload.objectValue?["skipped_escaped_results"]) == (.number(1)))
    #expect((payload.objectValue?["skipped_missing_results"]) == (.number(1)))
    #expect(
      (results.first?.objectValue?["workspace_relative_path"]) == (.string("notes/alpha.txt")))
  }

  @Test
  func testMacOSSpotlightSearchRejectsWorkspaceEscapeAndBadBounds() throws {
    let directory = try temporaryDirectory()
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration(
        builtin: BuiltinConfig(enabled: ["macos.spotlight_search"]),
        workspaceDirectory: directory
      )
    )

    expectThrows(
      try registry.callTool(
        name: "macos.spotlight_search",
        arguments: .object([
          "path": .string("../outside"),
          "query": .string("alpha"),
        ]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("escapes workspace"))
    }

    expectThrows(
      try registry.callTool(
        name: "macos.spotlight_search",
        arguments: .object([
          "query": .string("alpha"),
          "max_results": .number(0),
        ]), context: .empty
      )
    ) { error in
      #expect(error.localizedDescription.contains("max_results"))
    }
  }

  @Test
  func testMacOSRunningApplicationsReturnsBoundedSessionSummary() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["macos.running_applications"])
      )
    )

    let result = try registry.callTool(
      name: "macos.running_applications",
      arguments: .object([
        "include_background": .bool(true),
        "max_results": .number(1),
      ]), context: .empty
    )
    let payload = try decodeTextPayload(result)
    let applications = try #require(payload.objectValue?["applications"]?.arrayValue)

    #expect((payload.objectValue?["include_background"]) == (.bool(true)))
    #expect((payload.objectValue?["max_results"]) == (.number(1)))
    #expect((applications.count) <= (1))
    #expect((payload.objectValue?["application_count"]) != nil)
    #expect((payload.objectValue?["truncated"]) != nil)
  }

  @Test
  func testMacOSFrontmostApplicationReturnsOptionalApplicationSummary() throws {
    let registry = GatewayToolRegistry(
      configuration: GatewayConfiguration.fixture(
        builtin: BuiltinConfig(enabled: ["macos.frontmost_application"])
      )
    )

    let result = try registry.callTool(
      name: "macos.frontmost_application", arguments: .object([:]), context: .empty)
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["available"]) != nil)
    #expect((payload.objectValue?["application"]) != nil)
  }

  @Test
  func testEnvironmentDescribeReportsOnlyConfiguredEnvNamesAndRedactsValues() throws {
    let config = GatewayConfiguration.fixture(
      server: ServerConfig(
        http: HTTPServerConfig(
          publicBaseURL: "https://gateway.example.com",
          accessTokenEnv: "COMPUTER_MCP_TOKEN"
        )
      ),
      cli: CLISectionConfig(commands: [
        CLICommandConfig(
          id: "secret-cli",
          executable: "/bin/echo",
          env: ["SECRET_CLI_TOKEN": "super-secret-cli-value"]
        )
      ]),
      mcp: MCPSectionConfig(servers: [
        MCPServerConfig(
          id: "secret-mcp",
          transport: .stdio,
          command: "/bin/cat",
          env: ["SECRET_MCP_TOKEN": "super-secret-mcp-value"]
        )
      ]),
      builtin: BuiltinConfig(enabled: ["env.describe"])
    )
    let registry = GatewayToolRegistry(configuration: config)

    let result = try registry.callTool(
      name: "env.describe", arguments: .object([:]), context: .empty)
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))

    #expect(!(text.contains("super-secret-cli-value")))
    #expect(!(text.contains("super-secret-mcp-value")))
    #expect((payload.objectValue?["summary"]?.objectValue?["values_redacted"]) == (.bool(true)))
    #expect((payload.objectValue?["summary"]?.objectValue?["declared_key_count"]) == (.number(3)))
    let serverKeys = payload.objectValue?["server"]?.arrayValue?
      .compactMap { $0.objectValue?["key"] }
    #expect((serverKeys) == ([.string("COMPUTER_MCP_TOKEN")]))
    #expect(
      (payload.objectValue?["cli"]?.arrayValue?.first?.objectValue?["env"]?.arrayValue?.first?
        .objectValue?["key"]) == (.string("SECRET_CLI_TOKEN")))
    #expect(
      (payload.objectValue?["mcp"]?.arrayValue?.first?.objectValue?["env"]?.arrayValue?.first?
        .objectValue?["value_origin"]) == (.string("configured_provider_env")))
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
        toolEnvironment: environment, mcpClient: FakeDownstreamMCPClient()),
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

private final class FakeDownstreamMCPClient: DownstreamMCPClient, @unchecked Sendable {
  func makeScopedClient(
    workingDirectory: URL, environment: [String: String], hostContext: (any MCPHostEnvironment)?
  )
    -> any DownstreamMCPClient
  { self }

  struct Call: Equatable {
    var server: String
    var tool: String
    var arguments: JSONValue
    var requestID: String? = nil
  }

  struct EventRead: Equatable {
    var afterCursor: Int
    var maxResults: Int
  }

  struct Cancellation: Equatable {
    var requestID: String
    var reason: String?
  }

  struct PromptGetCall: Equatable {
    var name: String
    var arguments: [String: String]?
  }

  private(set) var calls: [Call] = []
  private(set) var startedCalls: [Call] = []
  private(set) var resourceListCursors: [String?] = []
  private(set) var resourceTemplateListCursors: [String?] = []
  private(set) var resourceReadURIs: [String] = []
  private(set) var promptListCursors: [String?] = []
  private(set) var promptGetCalls: [PromptGetCall] = []
  private(set) var eventReads: [EventRead] = []
  private(set) var cancellations: [Cancellation] = []
  var tools = [
    MCPTool(
      name: "sample",
      description: "Sample downstream tool.",
      inputSchema: .object(["type": .string("object")])
    )
  ]
  var resources: [JSONValue] = []
  var resourceTemplates: [JSONValue] = []
  var resourceContents: [String: [JSONValue]] = [:]
  var prompts: [JSONValue] = []
  var promptResults: [String: JSONValue] = [:]
  var events: JSONValue = .object(["events": .array([])])
  var activeRequestPayload: JSONValue = .object(["requests": .array([])])

  func listTools(server: MCPServerConfig, context: InvocationContext) throws -> [MCPTool] {
    tools
  }

  func callTool(
    server: MCPServerConfig, name: String, arguments: JSONValue, context: InvocationContext
  ) throws -> JSONValue {
    try callTool(server: server, name: name, arguments: arguments, requestID: nil, context: context)
  }

  func callTool(
    server: MCPServerConfig,
    name: String,
    arguments: JSONValue,
    requestID: String?, context: InvocationContext
  ) throws -> JSONValue {
    calls.append(
      Call(server: server.id, tool: name, arguments: arguments, requestID: requestID)
    )
    return .object([
      "content": .array([.object(["type": .string("text"), "text": .string("called")])]),
      "isError": .bool(false),
    ])
  }

  func startToolCall(
    server: MCPServerConfig,
    name: String,
    arguments: JSONValue,
    requestID: String, context: InvocationContext
  ) throws -> JSONValue {
    startedCalls.append(
      Call(server: server.id, tool: name, arguments: arguments, requestID: requestID)
    )
    return .object([
      "server": .string(server.id),
      "tool": .string(name),
      "request_id": .string(requestID),
      "state": .string("running"),
      "wait_for_result": .bool(false),
    ])
  }

  func listResources(server: MCPServerConfig, cursor: String?, context: InvocationContext) throws
    -> JSONValue
  {
    resourceListCursors.append(cursor)
    return .object([
      "resources": .array(resources),
      "nextCursor": .null,
    ])
  }

  func listResourceTemplates(server: MCPServerConfig, cursor: String?, context: InvocationContext)
    throws -> JSONValue
  {
    resourceTemplateListCursors.append(cursor)
    return .object([
      "resourceTemplates": .array(resourceTemplates),
      "nextCursor": .null,
    ])
  }

  func readResource(server: MCPServerConfig, uri: String, context: InvocationContext) throws
    -> JSONValue
  {
    resourceReadURIs.append(uri)
    return .object([
      "contents": .array(resourceContents[uri] ?? [])
    ])
  }

  func listPrompts(server: MCPServerConfig, cursor: String?, context: InvocationContext) throws
    -> JSONValue
  {
    promptListCursors.append(cursor)
    return .object([
      "prompts": .array(prompts),
      "nextCursor": .null,
    ])
  }

  func getPrompt(
    server: MCPServerConfig,
    name: String,
    arguments: [String: String]?, context: InvocationContext
  ) throws -> JSONValue {
    promptGetCalls.append(PromptGetCall(name: name, arguments: arguments))
    return promptResults[name]
      ?? .object([
        "description": .null,
        "messages": .array([]),
      ])
  }

  func connectionStatus(server: MCPServerConfig, context: InvocationContext) throws -> JSONValue {
    .object([
      "state": .string("connected"),
      "persistent_session": .bool(true),
    ])
  }

  func readEvents(
    server: MCPServerConfig,
    afterCursor: Int,
    maxResults: Int, context: InvocationContext
  ) throws -> JSONValue {
    eventReads.append(EventRead(afterCursor: afterCursor, maxResults: maxResults))
    return events
  }

  func activeRequests(server: MCPServerConfig, context: InvocationContext) throws -> JSONValue {
    activeRequestPayload
  }

  func cancelRequest(
    server: MCPServerConfig,
    requestID: String,
    reason: String?, context: InvocationContext
  ) throws -> JSONValue {
    cancellations.append(Cancellation(requestID: requestID, reason: reason))
    return .object([
      "request_id": .string(requestID),
      "cancelled": .bool(true),
    ])
  }
}
