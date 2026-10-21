import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPToolsMCP

@Suite(.nativeIntegration, .serialized)
final class MCPToolProviderTests {
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
    let provider = MCPToolProvider(
      environment: ToolEnvironment(configuration: config, environment: ["PATH": "/bin"]),
      mcpClient: FakeDownstreamMCPClient())
    let mcp = try decodeTextPayload(
      provider.callTool(.init(name: "mcp.servers.status", arguments: .object([:]), context: .empty))
    )
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
    let provider = ConfiguredMCPToolProvider(
      environment: ToolEnvironment(configuration: config), mcpClient: mcp)

    let names = try provider.definitions().map(\.tool).map(\.name)
    #expect(names.contains("fake.sample_typed"))
    let configuredTool = try #require(
      try provider.definitions().map(\.tool).first { $0.name == "fake.sample_typed" })
    #expect((configuredTool.outputSchema) == nil)

    let result = try provider.callTool(
      .init(
        name: "fake.sample_typed",
        arguments: .object(["value": .string("typed")]), context: .empty
      ))

    #expect((result.objectValue?["isError"]) == (.bool(false)))
    #expect((mcp.calls.first?.tool) == ("sample"))
    #expect((mcp.calls.first?.arguments) == (.object(["value": .string("typed")])))
  }

  @Test
  func testUnregisteredMCPServerRejectsDirectToolCalls() {
    let provider = MCPToolProvider(
      environment: ToolEnvironment(configuration: .fixture()), mcpClient: FakeDownstreamMCPClient())

    expectThrows(
      try provider.callTool(
        .init(
          name: "mcp.tools.list",
          arguments: .object(["server": .string("figma")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Unknown MCP server id"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "mcp.tools.call",
          arguments: .object([
            "server": .string("figma"),
            "tool": .string("get_screenshot"),
            "arguments": .object([:]),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Unknown MCP server id"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "mcp.tools.describe",
          arguments: .object([
            "server": .string("figma"),
            "tool": .string("get_screenshot"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Unknown MCP server id"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "mcp.resources.list",
          arguments: .object(["server": .string("figma")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Unknown MCP server id"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "mcp.resources.read",
          arguments: .object([
            "server": .string("figma"),
            "uri": .string("file:///missing"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Unknown MCP server id"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "mcp.prompts.list",
          arguments: .object(["server": .string("figma")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Unknown MCP server id"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "mcp.prompts.get",
          arguments: .object([
            "server": .string("figma"),
            "name": .string("review"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Unknown MCP server id"))
    }
  }

  @Test
  func testUnexposedTopLevelToolNameRejectsDirectToolCall() {
    let provider = ConfiguredMCPToolProvider(
      environment: ToolEnvironment(configuration: .fixture()), mcpClient: FakeDownstreamMCPClient())

    expectThrows(
      try provider.callTool(
        .init(
          name: "figma.get_screenshot",
          arguments: .object([:]), context: .empty
        ))
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
    let provider = ConfiguredMCPToolProvider(
      environment: ToolEnvironment(configuration: configuration), mcpClient: mcp)

    _ = try provider.callTool(
      .init(
        name: "fake.sample",
        arguments: .object(["value": .string("direct")]), context: .empty
      ))

    #expect((mcp.calls.first?.tool) == ("sample"))
    #expect((mcp.calls.first?.arguments) == (.object(["value": .string("direct")])))
  }

  @Test
  func testMCPToolsListAndCallUseDownstreamClient() throws {
    let mcp = FakeDownstreamMCPClient()
    let provider = MCPToolProvider(
      environment: ToolEnvironment(configuration: .fixture()), mcpClient: mcp)

    let listResult = try provider.callTool(
      .init(
        name: "mcp.tools.list",
        arguments: .object(["server": .string("fake")]), context: .empty
      ))
    let listPayload = try decodeTextPayload(listResult)

    #expect((listPayload.arrayValue?.first?.objectValue?["name"]) == (.string("sample")))

    let callResult = try provider.callTool(
      .init(
        name: "mcp.tools.call",
        arguments: .object([
          "server": .string("fake"),
          "tool": .string("sample"),
          "request_id": .string("request-1"),
          "arguments": .object(["value": .string("x")]),
        ]), context: .empty
      ))
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
    let provider = MCPToolProvider(
      environment: ToolEnvironment(configuration: .fixture()), mcpClient: mcp)

    let result = try provider.callTool(
      .init(
        name: "mcp.tools.call",
        arguments: .object([
          "server": .string("fake"),
          "tool": .string("sample"),
          "request_id": .string("request-started"),
          "wait_for_result": .bool(false),
          "arguments": .object(["value": .string("x")]),
        ]), context: .empty
      ))

    #expect((try decodeTextPayload(result).objectValue?["state"]) == (.string("running")))
    #expect((mcp.startedCalls.first?.tool) == ("sample"))
    #expect((mcp.startedCalls.first?.requestID) == ("request-started"))
  }

  @Test
  func testMCPToolCallRequiresRequestIDWhenStartingWithoutWaiting() {
    let provider = MCPToolProvider(
      environment: ToolEnvironment(
        configuration: .fixture()), mcpClient: FakeDownstreamMCPClient())

    expectThrows(
      try provider.callTool(
        .init(
          name: "mcp.tools.call",
          arguments: .object([
            "server": .string("fake"),
            "tool": .string("sample"),
            "wait_for_result": .bool(false),
          ]), context: .empty
        ))
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
    let provider = MCPToolProvider(
      environment: ToolEnvironment(configuration: configuration), mcpClient: mcp)

    let listed = try decodeTextPayload(
      provider.callTool(
        .init(
          name: "mcp.tools.list",
          arguments: .object(["server": .string("fake")]), context: .empty
        ))
    )
    #expect(
      (listed.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue }) == (["reviewed"]))

    expectThrows(
      try provider.callTool(
        .init(
          name: "mcp.tools.call",
          arguments: .object([
            "server": .string("fake"),
            "tool": .string("shell"),
            "arguments": .object([:]),
          ]), context: .empty
        ))
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
    let provider = MCPToolProvider(
      environment: ToolEnvironment(configuration: .fixture()), mcpClient: mcp)

    let eventsResult = try provider.callTool(
      .init(
        name: "mcp.events.read",
        arguments: .object([
          "server": .string("fake"),
          "after_cursor": .number(3),
          "max_results": .number(25),
        ]), context: .empty
      ))
    #expect((try decodeTextPayload(eventsResult).objectValue?["next_cursor"]) == (.number(8)))
    #expect((mcp.eventReads) == ([.init(afterCursor: 3, maxResults: 25)]))

    let requestsResult = try provider.callTool(
      .init(
        name: "mcp.requests.list",
        arguments: .object(["server": .string("fake")]), context: .empty
      ))
    #expect(
      (try decodeTextPayload(requestsResult).objectValue?["requests"]?.arrayValue?.count) == (1))

    let cancelResult = try provider.callTool(
      .init(
        name: "mcp.requests.cancel",
        arguments: .object([
          "server": .string("fake"),
          "request_id": .string("request-1"),
          "reason": .string("test"),
        ]), context: .empty
      ))
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
    let provider = MCPToolProvider(
      environment: ToolEnvironment(configuration: .fixture()), mcpClient: mcp)

    let result = try provider.callTool(
      .init(
        name: "mcp.tools.describe",
        arguments: .object([
          "server": .string("fake"),
          "tool": .string("sample"),
        ]), context: .empty
      ))
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
    let provider = MCPToolProvider(
      environment: ToolEnvironment(
        configuration: .fixture()), mcpClient: FakeDownstreamMCPClient())

    expectThrows(
      try provider.callTool(
        .init(
          name: "mcp.tools.describe",
          arguments: .object([
            "server": .string("fake"),
            "tool": .string("missing"),
          ]), context: .empty
        ))
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
    let provider = MCPToolProvider(
      environment: ToolEnvironment(configuration: .fixture()), mcpClient: mcp)

    let listResult = try provider.callTool(
      .init(
        name: "mcp.resources.list",
        arguments: .object([
          "server": .string("fake"),
          "cursor": .string("page-1"),
        ]), context: .empty
      ))
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

    let templatesResult = try provider.callTool(
      .init(
        name: "mcp.resources.templates.list",
        arguments: .object(["server": .string("fake")]), context: .empty
      ))
    let templatesPayload = try decodeTextPayload(templatesResult)
    let templates = try #require(templatesPayload.objectValue?["resource_templates"]?.arrayValue)

    #expect((templatesPayload.objectValue?["template_count"]) == (.number(1)))
    #expect((templates.first?.objectValue?["uriTemplate"]) == (.string("file:///workspace/{path}")))

    let readResult = try provider.callTool(
      .init(
        name: "mcp.resources.read",
        arguments: .object([
          "server": .string("fake"),
          "uri": .string("file:///workspace/README.md"),
        ]), context: .empty
      ))
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
    let provider = MCPToolProvider(
      environment: ToolEnvironment(configuration: .fixture()), mcpClient: mcp)

    let listResult = try provider.callTool(
      .init(
        name: "mcp.prompts.list",
        arguments: .object([
          "server": .string("fake"),
          "cursor": .string("page-1"),
        ]), context: .empty
      ))
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

    let getResult = try provider.callTool(
      .init(
        name: "mcp.prompts.get",
        arguments: .object([
          "server": .string("fake"),
          "name": .string("review"),
          "arguments": .object(["path": .string("Sources")]),
        ]), context: .empty
      ))
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
    let provider = MCPToolProvider(
      environment: ToolEnvironment(
        configuration: .fixture()), mcpClient: FakeDownstreamMCPClient())

    expectThrows(
      try provider.callTool(
        .init(
          name: "mcp.prompts.get",
          arguments: .object([
            "server": .string("fake"),
            "name": .string("review"),
            "arguments": .object(["path": .number(1)]),
          ]), context: .empty
        ))
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
    let provider = MCPToolProvider(
      environment: ToolEnvironment(configuration: .fixture()), mcpClient: mcp)

    let result = try provider.callTool(
      .init(
        name: "mcp.tools.find",
        arguments: .object([
          "server": .string("fake"),
          "query": .string("video_"),
          "match": .string("prefix"),
          "field": .string("name"),
        ]), context: .empty
      ))
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
    let provider = MCPToolProvider(
      environment: ToolEnvironment(configuration: .fixture()), mcpClient: mcp)

    let result = try provider.callTool(
      .init(
        name: "mcp.tools.find",
        arguments: .object([
          "server": .string("fake"),
          "query": .string("export"),
          "field": .string("description"),
          "max_results": .number(1),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["result_count"]) == (.number(1)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
  }

  @Test
  func testMCPToolsFindRejectsBadModes() {
    let provider = MCPToolProvider(
      environment: ToolEnvironment(
        configuration: .fixture()), mcpClient: FakeDownstreamMCPClient())

    expectThrows(
      try provider.callTool(
        .init(
          name: "mcp.tools.find",
          arguments: .object([
            "server": .string("fake"),
            "query": .string("video"),
            "field": .string("schema"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("field"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "mcp.tools.find",
          arguments: .object([
            "server": .string("fake"),
            "query": .string("video"),
            "match": .string("regex"),
          ]), context: .empty
        ))
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
    let provider = MCPToolProvider(
      environment: ToolEnvironment(configuration: config), mcpClient: FakeDownstreamMCPClient())

    let result = try provider.callTool(
      .init(
        name: "mcp.servers.status", arguments: .object([:]), context: .empty))
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
    let provider = MCPToolProvider(
      environment: ToolEnvironment(configuration: config), mcpClient: FakeDownstreamMCPClient())

    let result = try provider.callTool(
      .init(
        name: "mcp.servers.status",
        arguments: .object(["server": .string("missing")]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let server = try #require(payload.objectValue?["servers"]?.arrayValue?.first?.objectValue)

    #expect((server["id"]) == (.string("missing")))
    #expect((server["ready"]) == (.bool(false)))
    #expect((server["command_resolution"]?.objectValue?["exists"]) == (.bool(false)))

    expectThrows(
      try provider.callTool(
        .init(
          name: "mcp.servers.status",
          arguments: .object(["server": .string("unknown")]), context: .empty
        ))
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
    let provider = ConfiguredMCPToolProvider(
      environment: ToolEnvironment(configuration: config), mcpClient: mcp)

    let names = try provider.definitions().map(\.tool).map(\.name)
    #expect(names.contains("fake.sample"))

    let result = try provider.callTool(
      .init(
        name: "fake.sample",
        arguments: .object(["arguments": .object(["value": .string("x")])]), context: .empty
      ))

    #expect((result.objectValue?["isError"]) == (.bool(false)))
    #expect((mcp.calls.first?.tool) == ("sample"))
  }

  private func decodeTextPayload(_ value: JSONValue) throws -> JSONValue {
    let text = try #require(
      value.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
  }

  private var directories: [ScopedTemporaryDirectory] = []

  private func temporaryDirectory() throws -> URL {
    let directory = try ScopedTemporaryDirectory()
    directories.append(directory)
    return directory.url
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
