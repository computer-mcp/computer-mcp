import Foundation
import Testing

@testable import ComputerMCP

@Suite(.serialized)

final class CodexGatewayProviderTests {
  @Test
  func testProviderExposesAllEnabledCodexPaths() throws {
    let provider = makeProvider()
    let names = Set(try provider.listTools().map(\.name))

    #expect(names.contains("codex.app.methods.call"))
    #expect(names.contains("codex.app.turn.start"))
    #expect(names.contains("codex.exec.start"))
    #expect(names.contains("codex.exec.result"))
    #expect(names.contains("codex.mcp.run"))
    #expect(names.contains("codex.mcp.approvals.list"))
    #expect(names.contains("codex.mcp.cancel"))
  }

  @Test
  func testProviderOmitsDisabledPaths() throws {
    let provider = CodexGatewayProvider(
      configuration: CodexConfig(enabled: true, execEnabled: false, mcpEnabled: false),
      appServer: FakeAppServerRuntime(),
      exec: nil,
      mcp: nil
    )

    let names = try provider.listTools().map(\.name)

    #expect(!(names.contains(where: { $0.hasPrefix("codex.exec.") })))
    #expect(!(names.contains(where: { $0.hasPrefix("codex.mcp.") })))
    #expect(names.contains(where: { $0.hasPrefix("codex.app.") }))
  }

  @Test
  func testCapabilitiesRequireWorkspaceAndSeparateReadFromWrite() throws {
    let provider = makeProvider()
    let tools = try provider.listTools()
    let list = try #require(tools.first { $0.name == "codex.exec.list" })
    let start = try #require(tools.first { $0.name == "codex.exec.start" })

    #expect((provider.capability(for: list).risk) == (.readOnly))
    #expect((provider.capability(for: start).risk) == (.workspaceWrite))
    #expect((provider.capability(for: list).workspaceRequirement) == (.required))
    #expect(provider.capability(for: start).usesNetwork)
  }

  @Test
  func testAppMethodCatalogAndTypedCallReturnStructuredEnvelope() async throws {
    let provider = makeProvider()

    let methods = try await provider.callToolAsync(
      name: "codex.app.methods.list",
      arguments: .object([:])
    )
    let methodRows = methods.objectValue?["structuredContent"]?.objectValue?["result"]?
      .objectValue?["methods"]?.arrayValue
    #expect(
      methodRows?.contains(where: {
        $0.objectValue?["method"]?.stringValue == "thread/start"
      }) == true)
    #expect(
      methodRows?.contains(where: {
        $0.objectValue?["method"]?.stringValue == "account/usage/read"
      }) == true)
    #expect(
      !(methodRows?.contains(where: {
        $0.objectValue?["method"]?.stringValue == "thread/turns/list"
      }) == true))

    let call = try await provider.callToolAsync(
      name: "codex.app.thread.start",
      arguments: .object(["model": .string("gpt-test")])
    )
    let result = call.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue
    #expect((result?["method"]) == (.string("thread/start")))
    #expect((result?["params"]?.objectValue?["model"]) == (.string("gpt-test")))
  }

  @Test
  func testTypedAppToolsMapStableArgumentsWithoutRawParams() async throws {
    let provider = makeProvider()

    let list = try await provider.callToolAsync(
      name: "codex.app.thread.list",
      arguments: .object([
        "search_term": .string("gateway"),
        "source_kinds": .array([.string("cli"), .string("vscode")]),
      ])
    )
    let listParams = list.objectValue?["structuredContent"]?.objectValue?["result"]?
      .objectValue?["params"]?.objectValue
    #expect((listParams?["searchTerm"]) == (.string("gateway")))
    #expect((listParams?["sourceKinds"]) == (.array([.string("cli"), .string("vscode")])))

    let turn = try await provider.callToolAsync(
      name: "codex.app.turn.start",
      arguments: .object([
        "thread_id": .string("thread-1"),
        "prompt": .string("Review the implementation."),
        "effort": .string("high"),
      ])
    )
    let turnParams = turn.objectValue?["structuredContent"]?.objectValue?["result"]?
      .objectValue?["params"]?.objectValue
    #expect((turnParams?["threadId"]) == (.string("thread-1")))
    #expect((turnParams?["effort"]) == (.string("high")))
    #expect(
      (turnParams?["input"]?.arrayValue?.first?.objectValue)
        == (["type": .string("text"), "text": .string("Review the implementation.")]))

    let planTurn = try await provider.callToolAsync(
      name: "codex.app.turn.start",
      arguments: .object([
        "thread_id": .string("thread-1"),
        "prompt": .string("Ask one bounded question."),
        "model": .string("gpt-5.6-sol"),
        "effort": .string("xhigh"),
        "collaboration_mode": .string("plan"),
      ])
    )
    let planTurnParams = planTurn.objectValue?["structuredContent"]?.objectValue?["result"]?
      .objectValue?["params"]?.objectValue
    #expect(
      (planTurnParams?["collaborationMode"])
        == (.object([
          "mode": .string("plan"),
          "settings": .object([
            "model": .string("gpt-5.6-sol"),
            "reasoning_effort": .string("xhigh"),
          ]),
        ])))

    let review = try await provider.callToolAsync(
      name: "codex.app.review.start",
      arguments: .object([
        "thread_id": .string("thread-1"),
        "target": .object(["type": .string("uncommittedChanges")]),
        "delivery": .string("detached"),
      ])
    )
    let reviewParams = review.objectValue?["structuredContent"]?.objectValue?["result"]?
      .objectValue?["params"]?.objectValue
    #expect((reviewParams?["delivery"]) == (.string("detached")))
    #expect((reviewParams?["target"]) == (.object(["type": .string("uncommittedChanges")])))
  }

  @Test
  func testTypedAppToolsRejectRawParamsAndUnsafeOverrides() async throws {
    let provider = makeProvider()

    await assertThrowsErrorAsync(
      try await provider.callToolAsync(
        name: "codex.app.thread.start",
        arguments: .object(["params": .object([:])])
      )
    )
    await assertThrowsErrorAsync(
      try await provider.callToolAsync(
        name: "codex.app.turn.start",
        arguments: .object([
          "thread_id": .string("thread-1"),
          "prompt": .string("Do it."),
          "cwd": .string("/tmp"),
        ])
      )
    )
  }

  @Test
  func testHighFrequencyAppSchemasAreTypedAndHaveOutputSchema() throws {
    let tools = try makeProvider().listTools()
    let start = try #require(tools.first { $0.name == "codex.app.thread.start" })
    let turn = try #require(tools.first { $0.name == "codex.app.turn.start" })
    let review = try #require(tools.first { $0.name == "codex.app.review.start" })

    #expect((start.inputSchema.objectValue?["properties"]?.objectValue?["params"]) == nil)
    #expect(
      (turn.inputSchema.objectValue?["required"])
        == (.array([.string("thread_id"), .string("prompt")])))
    #expect(
      (turn.inputSchema.objectValue?["properties"]?.objectValue?["collaboration_mode"]?
        .objectValue?["enum"]) == (.array([.string("default"), .string("plan")])))
    #expect((start.outputSchema) != nil)
    #expect((turn.outputSchema) != nil)
    #expect(
      (review.inputSchema.objectValue?["properties"]?.objectValue?["delivery"]?
        .objectValue?["type"]) == (.string("string")))
    #expect(
      (review.inputSchema.objectValue?["properties"]?.objectValue?["delivery"]?
        .objectValue?["enum"]) == (.array([.string("inline"), .string("detached")])))
  }

  @Test
  func testTurnStartCollaborationModeRequiresModelAndRejectsUnknownMode() async {
    await assertThrowsErrorAsync(
      try await makeProvider().callToolAsync(
        name: "codex.app.turn.start",
        arguments: .object([
          "thread_id": .string("thread-1"),
          "prompt": .string("Ask a question."),
          "collaboration_mode": .string("plan"),
        ])
      )
    )
    await assertThrowsErrorAsync(
      try await makeProvider().callToolAsync(
        name: "codex.app.turn.start",
        arguments: .object([
          "thread_id": .string("thread-1"),
          "prompt": .string("Ask a question."),
          "model": .string("gpt-5.6-sol"),
          "collaboration_mode": .string("unsupported"),
        ])
      )
    )
  }

  @Test
  func testReviewStartRejectsUnsupportedDelivery() async {
    await assertThrowsErrorAsync(
      try await makeProvider().callToolAsync(
        name: "codex.app.review.start",
        arguments: .object([
          "thread_id": .string("thread-1"),
          "target": .object(["type": .string("uncommittedChanges")]),
          "delivery": .string("somewhere"),
        ])
      )
    )
  }

  @Test
  func testExecAndMCPCallsUseDedicatedRuntimes() async throws {
    let provider = makeProvider()

    let exec = try await provider.callToolAsync(
      name: "codex.exec.start",
      arguments: .object([
        "prompt": .string("Implement the change."),
        "model": .string("gpt-test"),
      ])
    )
    #expect(
      (exec.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue?["path"])
        == (.string("exec")))

    let mcp = try await provider.callToolAsync(
      name: "codex.mcp.run",
      arguments: .object(["prompt": .string("Review the change.")])
    )
    #expect(
      (mcp.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue?["path"])
        == (.string("mcp")))
  }

  @Test
  func testProviderRejectsMissingArgumentsAndSynchronousExecution() async {
    let provider = makeProvider()

    await assertThrowsErrorAsync(
      try await provider.callToolAsync(
        name: "codex.mcp.reply",
        arguments: .object(["prompt": .string("continue")])
      )
    )
    expectThrows(
      try provider.callTool(name: "codex.exec.list", arguments: .object([:]))
    )
  }

  private func makeProvider() -> CodexGatewayProvider {
    CodexGatewayProvider(
      configuration: CodexConfig(enabled: true),
      appServer: FakeAppServerRuntime(),
      exec: FakeExecRuntime(),
      mcp: FakeMCPRuntime()
    )
  }
}

private struct FakeAppServerRuntime: CodexAppServerRuntimeProtocol {
  func status() async -> JSONValue {
    .object(["path": .string("app")])
  }

  func call(method: String, params: JSONValue?) async throws -> JSONValue {
    .object([
      "path": .string("app"),
      "method": .string(method),
      "params": params ?? .null,
    ])
  }

  func events(afterCursor: Int, maxResults: Int) async -> JSONValue {
    .object([
      "after_cursor": .number(Double(afterCursor)),
      "max_results": .number(Double(maxResults)),
    ])
  }

  func pendingRequests() async -> JSONValue {
    .object(["requests": .array([])])
  }

  func respond(requestID: String, response: JSONValue) async throws -> JSONValue {
    .object(["request_id": .string(requestID), "response": response])
  }
}

private struct FakeExecRuntime: CodexExecRuntimeProtocol {
  func start(prompt: String, model: String?) async throws -> JSONValue {
    .object([
      "path": .string("exec"),
      "prompt": .string(prompt),
      "model": model.map(JSONValue.string) ?? .null,
    ])
  }

  func resume(upstreamSessionID: String, prompt: String?) async throws -> JSONValue {
    .object([
      "path": .string("exec"),
      "upstream_session_id": .string(upstreamSessionID),
      "prompt": prompt.map(JSONValue.string) ?? .null,
    ])
  }

  func list() async -> JSONValue {
    .object(["sessions": .array([])])
  }

  func events(
    sessionID: String,
    afterCursor: Int,
    maxResults: Int
  ) async throws -> JSONValue {
    .object(["session_id": .string(sessionID)])
  }

  func result(sessionID: String) async throws -> JSONValue {
    .object(["session_id": .string(sessionID)])
  }

  func cancel(sessionID: String) async throws -> JSONValue {
    .object(["session_id": .string(sessionID), "cancelled": .bool(true)])
  }
}

private struct FakeMCPRuntime: CodexMCPRuntimeProtocol {
  func status() async -> JSONValue {
    .object(["path": .string("mcp")])
  }

  func tools() async throws -> JSONValue {
    .object(["tools": .array([])])
  }

  func run(prompt: String, model: String?) async throws -> JSONValue {
    .object([
      "path": .string("mcp"),
      "prompt": .string(prompt),
      "model": model.map(JSONValue.string) ?? .null,
    ])
  }

  func reply(threadID: String, prompt: String) async throws -> JSONValue {
    .object(["thread_id": .string(threadID), "prompt": .string(prompt)])
  }

  func calls() async -> JSONValue {
    .object(["calls": .array([])])
  }

  func events(
    callID: String,
    afterCursor: Int,
    maxResults: Int
  ) async throws -> JSONValue {
    .object(["call_id": .string(callID)])
  }

  func result(callID: String) async throws -> JSONValue {
    .object(["call_id": .string(callID)])
  }

  func pendingApprovals(callID: String) async throws -> JSONValue {
    .object(["call_id": .string(callID), "approvals": .array([])])
  }

  func respondToApproval(
    callID: String,
    approvalID: String,
    decision: String
  ) async throws -> JSONValue {
    .object([
      "call_id": .string(callID),
      "approval_id": .string(approvalID),
      "decision": .string(decision),
    ])
  }

  func cancel(callID: String) async throws -> JSONValue {
    .object(["call_id": .string(callID), "cancelled": .bool(true)])
  }
}

private func assertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    Issue.record("Expected expression to throw.")
  } catch {
    // Expected.
  }
}
