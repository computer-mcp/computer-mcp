import CodexMCP
import Foundation
import Testing

@testable import ComputerMCP

@Suite(.serialized)

final class CodexMCPRuntimeTests {
  @Test
  func testToolsListUsesOfficialDescriptorsAndReconnectsFailedClient() async throws {
    let failed = FakeCodexMCPClient(state: .failed)
    let replacement = FakeCodexMCPClient(
      state: .running,
      tools: [
        CodexMCPToolDescriptor(
          name: "codex",
          title: "Codex",
          description: "Run Codex.",
          inputSchema: ["type": .string("object")],
          outputSchema: ["type": .string("object")]
        )
      ]
    )
    let factory = FakeCodexMCPClientFactory(clients: [replacement])
    let runtime = makeRuntime(client: failed, factory: factory)

    let result = try await runtime.tools()
    let tool = try #require(result.objectValue?["tools"]?.arrayValue?.first?.objectValue)

    #expect((tool["name"]) == (.string("codex")))
    #expect((tool["title"]) == (.string("Codex")))
    #expect((tool["input_schema"]?.objectValue?["type"]) == (.string("object")))
    #expect((tool["output_schema"]?.objectValue?["type"]) == (.string("object")))
    let factoryMakeCount = await factory.makeCount
    let replacementListToolsCount = await replacement.listToolsCount
    #expect((factoryMakeCount) == (1))
    #expect((replacementListToolsCount) == (1))
  }

  @Test
  func testRunFixesWorkspacePolicyAndRejectsUnsafeOverrides() async throws {
    let workspace = URL(fileURLWithPath: "/tmp/computer-mcp-codex-mcp")
    let handle = FakeCodexMCPCallHandle(
      requestID: .integer(7),
      serverMessages: [
        CodexMCPServerMessage(
          method: "codex/event",
          rawEvent: .object(["type": .string("turn.started")]),
          requestID: .integer(7),
          threadID: "thread-7"
        )
      ],
      serverMessageDelayNanoseconds: 10_000_000,
      result: successfulResult(threadID: "thread-7", content: "done")
    )
    let client = FakeCodexMCPClient(state: .running, handles: [handle])
    let runtime = makeRuntime(
      workspace: workspace,
      configuration: configuration(sandbox: .workspaceWrite, approval: .onRequest),
      client: client
    )

    let started = try await runtime.run(prompt: "  Do the work.  ", model: " gpt-5 ")
    let callID = try requiredString("call_id", in: started)
    let runRequests = await client.runRequests
    let request = try #require(runRequests.first)

    #expect((request.prompt) == ("Do the work."))
    #expect((request.model) == ("gpt-5"))
    #expect((request.profile) == nil)
    #expect((request.cwd) == (workspace.standardizedFileURL))
    #expect((request.approvalPolicy) == (.onRequest))
    #expect((request.sandboxMode) == (.workspaceWrite))
    #expect((request.configOverrides) == ([:]))
    #expect((request.baseInstructions) == nil)
    #expect((request.developerInstructions) == nil)
    #expect((request.compactPrompt) == nil)

    let result = try await waitForTerminalResult(runtime: runtime, callID: callID)
    #expect((result.objectValue?["call"]?.objectValue?["state"]) == (.string("completed")))
    #expect((result.objectValue?["result"]?.objectValue?["thread_id"]) == (.string("thread-7")))
    #expect((result.objectValue?["result"]?.objectValue?["content"]) == (.string("done")))

    let events = try await runtime.events(callID: callID, afterCursor: -20, maxResults: 100)
    let kinds = events.objectValue?["events"]?.arrayValue?.compactMap {
      $0.objectValue?["kind"]?.stringValue
    }
    #expect((kinds) == (["call_started", "server_message", "call_completed"]))
  }

  @Test
  func testReplyUsesOnlyOpaqueThreadIDAndPrompt() async throws {
    let handle = FakeCodexMCPCallHandle(
      requestID: .string("reply-1"),
      result: successfulResult(threadID: "thread-1", content: "continued")
    )
    let client = FakeCodexMCPClient(state: .running, handles: [handle])
    let runtime = makeRuntime(client: client)

    let started = try await runtime.reply(threadID: " thread-1 ", prompt: " Continue. ")
    let replyRequests = await client.replyRequests
    let request = try #require(replyRequests.first)

    #expect((request.threadID) == ("thread-1"))
    #expect((request.prompt) == ("Continue."))
    #expect((started.objectValue?["call_id"]) == (.string("s:reply-1")))

    await assertRuntimeError(
      try await runtime.reply(
        threadID: String(repeating: "x", count: 1_025),
        prompt: "Continue."
      ),
      code: "codex.mcp.thread_id_required"
    )
  }

  @Test
  func testCredentialLikeUpstreamRequestIDIsRepresentedByDigest() async throws {
    let handle = FakeCodexMCPCallHandle(
      requestID: .string("token=upstream-secret"),
      result: successfulResult(threadID: "thread-safe", content: "done")
    )
    let runtime = makeRuntime(
      client: FakeCodexMCPClient(state: .running, handles: [handle])
    )

    let started = try await runtime.run(prompt: "Run safely.", model: nil)
    let callID = try requiredString("call_id", in: started)
    #expect(callID.hasPrefix("s:sha256:"))
    #expect(!callID.contains("upstream-secret"))
    let result = try await waitForTerminalResult(runtime: runtime, callID: callID)
    let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
    #expect(!encoded.contains("upstream-secret"))
  }

  @Test
  func testResultBoundsContentAndRawPayloads() async throws {
    let largeText = String(repeating: "payload-", count: 2_000)
    let handle = FakeCodexMCPCallHandle(
      requestID: .integer(71),
      result: successfulResult(threadID: "thread-71", content: largeText)
    )
    let client = FakeCodexMCPClient(state: .running, handles: [handle])
    let runtime = LiveCodexMCPRuntime(
      configuration: configuration(),
      workspaceURL: URL(fileURLWithPath: "/tmp/codex-mcp-bounds"),
      maxOutputBytes: 2_048,
      client: client,
      clientFactory: FakeCodexMCPClientFactory(clients: [client])
    )

    let started = try await runtime.run(prompt: "Bound output.", model: nil)
    let callID = try requiredString("call_id", in: started)
    let result = try await waitForTerminalResult(runtime: runtime, callID: callID)
    let payload = try #require(result.objectValue?["result"]?.objectValue)

    #expect((payload["content_truncated"]) == (.bool(true)))
    #expect(
      (payload["content_original_bytes"]?.intValue ?? 0)
        > (payload["content"]?.stringValue?.utf8.count ?? .max))
    #expect((payload["content_blocks"]?.objectValue?["truncated"]) == (.bool(true)))
    #expect((payload["structured_content"]?.objectValue?["truncated"]) == (.bool(true)))
  }

  @Test
  func testApprovalAllowAndDenyUseOfficialHandleResponse() async throws {
    let workspace = URL(fileURLWithPath: "/tmp/mcp-approval-workspace")
    let allowed = execApproval(
      id: .string("allow-1"),
      cwd: workspace.appendingPathComponent("Sources").path
    )
    let denied = patchApproval(
      id: .string("deny-1"),
      grantRoot: "/tmp/outside",
      changes: ["/tmp/outside/file.swift": .object([:])]
    )
    let allowHandle = FakeCodexMCPCallHandle(
      requestID: .integer(1),
      approvalRequests: [allowed]
    )
    let denyHandle = FakeCodexMCPCallHandle(
      requestID: .integer(2),
      approvalRequests: [denied]
    )
    let client = FakeCodexMCPClient(state: .running, handles: [allowHandle, denyHandle])
    let runtime = makeRuntime(workspace: workspace, client: client)

    let first = try await runtime.run(prompt: "First.", model: nil)
    let firstID = try requiredString("call_id", in: first)
    try await waitForApproval(runtime: runtime, callID: firstID, approvalID: "s:allow-1")
    let allowedResult = try await runtime.respondToApproval(
      callID: firstID,
      approvalID: "s:allow-1",
      decision: "allow"
    )

    #expect((allowedResult.objectValue?["resolved"]) == (.bool(true)))
    let allowResponses = await allowHandle.recordedResponses
    #expect((allowResponses) == ([RecordedApproval(id: .string("allow-1"), decision: .allow)]))

    let second = try await runtime.run(prompt: "Second.", model: nil)
    let secondID = try requiredString("call_id", in: second)
    try await waitForApproval(runtime: runtime, callID: secondID, approvalID: "s:deny-1")
    let deniedResult = try await runtime.respondToApproval(
      callID: secondID,
      approvalID: "s:deny-1",
      decision: "deny"
    )

    #expect((deniedResult.objectValue?["decision"]) == (.string("deny")))
    let denyResponses = await denyHandle.recordedResponses
    #expect((denyResponses) == ([RecordedApproval(id: .string("deny-1"), decision: .deny)]))

    allowHandle.finish(with: successfulResult(threadID: "thread-1", content: "allowed"))
    denyHandle.finish(with: successfulResult(threadID: "thread-2", content: "denied"))
  }

  @Test
  func testApprovalAllowRejectsWorkspaceEscapeAndKeepsRequestPending() async throws {
    let approval = execApproval(id: .integer(99), cwd: "/tmp/not-the-workspace")
    let handle = FakeCodexMCPCallHandle(
      requestID: .integer(3),
      approvalRequests: [approval]
    )
    let client = FakeCodexMCPClient(state: .running, handles: [handle])
    let runtime = makeRuntime(
      workspace: URL(fileURLWithPath: "/tmp/bound-workspace"),
      client: client
    )
    let started = try await runtime.run(prompt: "Escape.", model: nil)
    let callID = try requiredString("call_id", in: started)
    try await waitForApproval(runtime: runtime, callID: callID, approvalID: "n:99")

    await assertRuntimeError(
      try await runtime.respondToApproval(
        callID: callID,
        approvalID: "n:99",
        decision: "allow"
      ),
      code: "codex.mcp.approval_outside_workspace"
    )

    let responses = await handle.recordedResponses
    #expect((responses) == ([]))
    let pending = try await runtime.pendingApprovals(callID: callID)
    #expect((pending.objectValue?["approvals"]?.arrayValue?.count) == (1))
    handle.finish(with: successfulResult(threadID: "thread-3", content: "finished"))
  }

  @Test
  func testPendingApprovalAndEventRedactCredentialText() async throws {
    let workspace = URL(fileURLWithPath: "/tmp/mcp-redaction-workspace")
    let approval = CodexMCPRuntimeApproval.exec(
      .init(
        requestID: .integer(101),
        threadID: "thread-redaction",
        message: "Use token=approval-secret",
        command: ["/usr/bin/env", "token=approval-secret"],
        cwd: workspace.path
      )
    )
    let handle = FakeCodexMCPCallHandle(
      requestID: .integer(102),
      approvalRequests: [approval]
    )
    let runtime = makeRuntime(
      workspace: workspace,
      client: FakeCodexMCPClient(state: .running, handles: [handle])
    )
    let started = try await runtime.run(prompt: "Redact approval.", model: nil)
    let callID = try requiredString("call_id", in: started)
    try await waitForApproval(runtime: runtime, callID: callID, approvalID: "n:101")

    let approvals = try await runtime.pendingApprovals(callID: callID)
    let events = try await runtime.events(callID: callID, afterCursor: 0, maxResults: 100)
    let encoded = String(
      decoding: try JSONEncoder().encode(.array([approvals, events]) as JSONValue),
      as: UTF8.self
    )
    #expect(encoded.contains("[REDACTED]"))
    #expect(!encoded.contains("approval-secret"))

    handle.finish(with: successfulResult(threadID: "thread-redaction", content: "done"))
  }

  @Test
  func testCancelUsesHandleAndRejectsFinishedCall() async throws {
    let handle = FakeCodexMCPCallHandle(requestID: .integer(4), cancelResult: true)
    let client = FakeCodexMCPClient(state: .running, handles: [handle])
    let runtime = makeRuntime(client: client)
    let started = try await runtime.run(prompt: "Wait.", model: nil)
    let callID = try requiredString("call_id", in: started)

    let cancelled = try await runtime.cancel(callID: callID)
    #expect((cancelled.objectValue?["cancellation_requested"]) == (.bool(true)))
    #expect((cancelled.objectValue?["state"]) == (.string("cancelled")))
    let cancelCount = await handle.cancelCount
    #expect((cancelCount) == (1))

    let cancelledResult = try await runtime.result(callID: callID)
    #expect((cancelledResult.objectValue?["call"]?.objectValue?["state"]) == (.string("cancelled")))
    #expect(
      (cancelledResult.objectValue?["error"]?.objectValue?["code"])
        == (.string("codex.mcp.cancelled")))
    handle.finish(with: successfulResult(threadID: "thread-4", content: "stopped"))
    try await Task.sleep(for: .milliseconds(20))
    let lateResult = try await runtime.result(callID: callID)
    #expect((lateResult.objectValue?["call"]?.objectValue?["state"]) == (.string("cancelled")))
    await assertRuntimeError(
      try await runtime.cancel(callID: callID),
      code: "codex.mcp.call_finished"
    )
  }

  @Test
  func testCancellationRestartsProviderWhenUpstreamDoesNotSettle() async throws {
    let handle = FakeCodexMCPCallHandle(requestID: .integer(44), cancelResult: true)
    let stale = FakeCodexMCPClient(state: .running, handles: [handle])
    let replacementHandle = FakeCodexMCPCallHandle(requestID: .integer(44))
    let replacement = FakeCodexMCPClient(
      state: .running,
      tools: [
        CodexMCPToolDescriptor(
          name: "codex",
          title: "Codex",
          description: "Run Codex.",
          inputSchema: ["type": .string("object")],
          outputSchema: nil
        )
      ],
      handles: [replacementHandle]
    )
    let factory = FakeCodexMCPClientFactory(clients: [replacement])
    let runtime = LiveCodexMCPRuntime(
      configuration: configuration(),
      workspaceURL: URL(fileURLWithPath: "/tmp/cancel-cleanup"),
      cancellationGrace: .milliseconds(10),
      client: stale,
      clientFactory: factory
    )

    let started = try await runtime.run(prompt: "Wait.", model: nil)
    let callID = try requiredString("call_id", in: started)
    _ = try await runtime.cancel(callID: callID)

    for _ in 0..<100 {
      if await stale.stopCount > 0 {
        break
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    let staleStopCount = await stale.stopCount
    #expect((staleStopCount) == (1))

    let tools = try await runtime.tools()
    #expect((tools.objectValue?["tools"]?.arrayValue?.count) == (1))
    let factoryMakeCount = await factory.makeCount
    let replacementListToolsCount = await replacement.listToolsCount
    #expect((factoryMakeCount) == (1))
    #expect((replacementListToolsCount) == (1))

    let recovered = try await runtime.run(prompt: "Recovered.", model: nil)
    let recoveredID = try requiredString("call_id", in: recovered)
    #expect((recoveredID) == ("g2:n:44"))
    replacementHandle.finish(
      with: successfulResult(threadID: "thread-recovered", content: "recovered")
    )
    let recoveredResult = try await waitForTerminalResult(
      runtime: runtime,
      callID: recoveredID
    )
    #expect((recoveredResult.objectValue?["call"]?.objectValue?["state"]) == (.string("completed")))
    #expect(
      (recoveredResult.objectValue?["call"]?.objectValue?["upstream_request_id"])
        == (.string("n:44")))

    let retainedCancellation = try await runtime.result(callID: callID)
    #expect(
      (retainedCancellation.objectValue?["call"]?.objectValue?["state"]) == (.string("cancelled")))

    let events = try await runtime.events(callID: callID, afterCursor: 0, maxResults: 20)
    let kinds = events.objectValue?["events"]?.arrayValue?.compactMap {
      $0.objectValue?["kind"]?.stringValue
    }
    #expect(
      (kinds)
        == ([
          "call_started",
          "cancellation_requested",
          "call_cancelled",
          "cancellation_cleanup_completed",
        ]))
  }

  @Test
  func testDuplicateRequestIDFromSameClientStillFailsClosed() async throws {
    let first = FakeCodexMCPCallHandle(requestID: .integer(7))
    let duplicate = FakeCodexMCPCallHandle(requestID: .integer(7), cancelResult: true)
    let client = FakeCodexMCPClient(state: .running, handles: [first, duplicate])
    let runtime = makeRuntime(client: client)

    let started = try await runtime.run(prompt: "First.", model: nil)
    #expect((started.objectValue?["call_id"]) == (.string("n:7")))
    await assertRuntimeError(
      try await runtime.run(prompt: "Duplicate.", model: nil),
      code: "codex.mcp.call_conflict"
    )
    let duplicateCancelCount = await duplicate.cancelCount
    #expect((duplicateCancelCount) == (1))
  }

  @Test
  func testSessionLimitPreventsOrphanCallAndEvictsCompletedCall() async throws {
    let firstHandle = FakeCodexMCPCallHandle(requestID: .integer(1))
    let secondHandle = FakeCodexMCPCallHandle(
      requestID: .integer(2),
      result: successfulResult(threadID: "thread-2", content: "replacement")
    )
    let client = FakeCodexMCPClient(
      state: .running,
      handles: [firstHandle, secondHandle]
    )
    let runtime = makeRuntime(
      configuration: configuration(maxSessions: 1),
      client: client
    )

    let first = try await runtime.run(prompt: "First.", model: nil)
    await assertRuntimeError(
      try await runtime.run(prompt: "Blocked.", model: nil),
      code: "codex.mcp.session_limit"
    )
    let blockedRunRequestCount = await client.runRequests.count
    #expect((blockedRunRequestCount) == (1))

    let firstID = try requiredString("call_id", in: first)
    firstHandle.finish(with: successfulResult(threadID: "thread-1", content: "done"))
    _ = try await waitForTerminalResult(runtime: runtime, callID: firstID)

    let replacement = try await runtime.run(prompt: "Replacement.", model: nil)
    #expect((replacement.objectValue?["call_id"]) == (.string("n:2")))
    let replacementRunRequestCount = await client.runRequests.count
    #expect((replacementRunRequestCount) == (2))
  }

  @Test
  func testTransportFailureSetsStableCodeAndReconnectsNextOperation() async throws {
    let failing = FakeCodexMCPClient(
      state: .running,
      listToolsError: CodexMCPError.transportFailure
    )
    let replacement = FakeCodexMCPClient(state: .running, tools: [])
    let factory = FakeCodexMCPClientFactory(clients: [replacement])
    let runtime = makeRuntime(client: failing, factory: factory)

    await assertRuntimeError(
      try await runtime.tools(),
      code: "codex.mcp.transport_failed"
    )
    let failedStatus = await runtime.status()
    #expect((failedStatus.objectValue?["reconnect_required"]) == (.bool(true)))
    #expect(
      (failedStatus.objectValue?["last_error"]?.objectValue?["code"])
        == (.string("codex.mcp.transport_failed")))

    _ = try await runtime.tools()
    let factoryMakeCount = await factory.makeCount
    #expect((factoryMakeCount) == (1))
    let recoveredStatus = await runtime.status()
    #expect((recoveredStatus.objectValue?["reconnect_required"]) == (.bool(false)))
    #expect((recoveredStatus.objectValue?["last_error"]) == (.null))
  }

  @Test
  func testStartupAndProtocolFailuresHaveStableCodes() async throws {
    let startFailure = FakeCodexMCPClient(
      state: .idle,
      startError: CodexMCPError.startupFailure
    )
    let startRuntime = makeRuntime(client: startFailure)
    await assertRuntimeError(
      try await startRuntime.tools(),
      code: "codex.mcp.start_failed"
    )

    let protocolHandle = FakeCodexMCPCallHandle(
      requestID: .integer(8),
      resultError: CodexMCPError.protocolFailure
    )
    let protocolClient = FakeCodexMCPClient(state: .running, handles: [protocolHandle])
    let protocolRuntime = makeRuntime(client: protocolClient)
    let started = try await protocolRuntime.run(prompt: "Fail.", model: nil)
    let callID = try requiredString("call_id", in: started)
    let result = try await waitForTerminalResult(runtime: protocolRuntime, callID: callID)

    #expect(
      (result.objectValue?["error"]?.objectValue?["code"]) == (.string("codex.mcp.protocol_failed"))
    )
    let protocolStatus = await protocolRuntime.status()
    #expect((protocolStatus.objectValue?["reconnect_required"]) == (.bool(true)))
  }

  @Test
  func testInputAndLookupErrorsAreStableAndDoNotReachClient() async throws {
    let client = FakeCodexMCPClient(state: .running)
    let runtime = makeRuntime(client: client)

    await assertRuntimeError(
      try await runtime.run(prompt: " \n ", model: nil),
      code: "codex.mcp.prompt_required"
    )
    await assertRuntimeError(
      try await runtime.reply(threadID: "", prompt: "Continue."),
      code: "codex.mcp.thread_id_required"
    )
    await assertRuntimeError(
      try await runtime.result(callID: "missing"),
      code: "codex.mcp.call_unknown"
    )
    let runRequests = await client.runRequests
    let replyRequests = await client.replyRequests
    #expect((runRequests) == ([]))
    #expect((replyRequests) == ([]))
  }

  private func makeRuntime(
    workspace: URL = URL(fileURLWithPath: "/tmp/codex-mcp-workspace"),
    configuration: CodexConfig? = nil,
    client: FakeCodexMCPClient,
    factory: FakeCodexMCPClientFactory? = nil
  ) -> LiveCodexMCPRuntime {
    LiveCodexMCPRuntime(
      configuration: configuration ?? self.configuration(),
      workspaceURL: workspace,
      client: client,
      clientFactory: factory ?? FakeCodexMCPClientFactory(clients: [client])
    )
  }

  private func configuration(
    sandbox: CodexSandboxMode = .workspaceWrite,
    approval: CodexApprovalPolicy = .never,
    maxSessions: Int = 8,
    maxEvents: Int = 1_024
  ) -> CodexConfig {
    CodexConfig(
      enabled: true,
      sandbox: sandbox,
      approvalPolicy: approval,
      maxSessions: maxSessions,
      maxEventsPerSession: maxEvents
    )
  }

  private func successfulResult(threadID: String, content: String) -> CodexMCPToolResult {
    CodexMCPToolResult(
      threadID: threadID,
      content: content,
      rawContentBlocks: [
        .object([
          "type": .string("text"),
          "text": .string(content),
        ])
      ],
      rawStructuredContent: .object([
        "threadId": .string(threadID),
        "content": .string(content),
      ]),
      isError: false
    )
  }

  private func execApproval(id: CodexMCPRequestID, cwd: String) -> CodexMCPRuntimeApproval {
    .exec(
      .init(
        requestID: id,
        threadID: "thread-approval",
        message: "Allow command?",
        command: ["git", "status"],
        cwd: cwd
      )
    )
  }

  private func patchApproval(
    id: CodexMCPRequestID,
    grantRoot: String?,
    changes: [String: CodexMCPJSONValue]
  ) -> CodexMCPRuntimeApproval {
    .patch(
      .init(
        requestID: id,
        threadID: "thread-patch",
        message: "Allow patch?",
        reason: "test",
        grantRoot: grantRoot,
        changes: changes
      )
    )
  }

  private func requiredString(_ key: String, in value: JSONValue) throws -> String {
    try #require(value.objectValue?[key]?.stringValue)
  }

  private func waitForTerminalResult(
    runtime: LiveCodexMCPRuntime,
    callID: String
  ) async throws -> JSONValue {
    for _ in 0..<200 {
      let result = try await runtime.result(callID: callID)
      let state = result.objectValue?["call"]?.objectValue?["state"]?.stringValue
      if state == "cancelled" || state == "completed" || state == "failed" {
        return result
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Codex MCP call did not reach a terminal state.")
    return try await runtime.result(callID: callID)
  }

  private func waitForApproval(
    runtime: LiveCodexMCPRuntime,
    callID: String,
    approvalID: String
  ) async throws {
    for _ in 0..<200 {
      let pending = try await runtime.pendingApprovals(callID: callID)
      if pending.objectValue?["approvals"]?.arrayValue?.contains(where: {
        $0.objectValue?["approval_id"] == .string(approvalID)
      }) == true {
        return
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Codex MCP approval was not observed.")
  }

  private func assertRuntimeError<T>(
    _ expression: @autoclosure () async throws -> T,
    code: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      _ = try await expression()
      Issue.record("Expected CodexMCPRuntimeError.")
    } catch let error as CodexMCPRuntimeError {
      #expect((error.code) == (code))
      #expect(error.localizedDescription.hasPrefix(code))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }
}

private actor FakeCodexMCPClient: CodexMCPClientAdapter {
  private var state: CodexMCPClientState
  private let startError: Error?
  private let tools: [CodexMCPToolDescriptor]
  private let listToolsError: Error?
  private var handles: [any CodexMCPCallHandleAdapter]
  private(set) var listToolsCount = 0
  private(set) var stopCount = 0
  private(set) var runRequests: [CodexMCPRunRequest] = []
  private(set) var replyRequests: [CodexMCPReplyRequest] = []

  init(
    state: CodexMCPClientState,
    startError: Error? = nil,
    tools: [CodexMCPToolDescriptor] = [],
    listToolsError: Error? = nil,
    handles: [any CodexMCPCallHandleAdapter] = []
  ) {
    self.state = state
    self.startError = startError
    self.tools = tools
    self.listToolsError = listToolsError
    self.handles = handles
  }

  func currentState() -> CodexMCPClientState {
    state
  }

  func start() throws {
    if let startError {
      state = .failed
      throw startError
    }
    state = .running
  }

  func stop() {
    stopCount += 1
    state = .stopped
  }

  func listTools() throws -> [CodexMCPToolDescriptor] {
    listToolsCount += 1
    if let listToolsError {
      throw listToolsError
    }
    return tools
  }

  func runCodex(_ request: CodexMCPRunRequest) throws
    -> any CodexMCPCallHandleAdapter
  {
    runRequests.append(request)
    return try nextHandle()
  }

  func reply(_ request: CodexMCPReplyRequest) throws
    -> any CodexMCPCallHandleAdapter
  {
    replyRequests.append(request)
    return try nextHandle()
  }

  private func nextHandle() throws -> any CodexMCPCallHandleAdapter {
    guard !handles.isEmpty else {
      throw CodexMCPRuntimeError(
        code: "test.no_handle",
        message: "No fake Codex MCP call handle was queued."
      )
    }
    return handles.removeFirst()
  }
}

private actor FakeCodexMCPClientFactory: CodexMCPClientAdapterFactory {
  private var clients: [any CodexMCPClientAdapter]
  private(set) var makeCount = 0

  init(clients: [any CodexMCPClientAdapter]) {
    self.clients = clients
  }

  func makeClient() -> any CodexMCPClientAdapter {
    makeCount += 1
    if clients.count > 1 {
      return clients.removeFirst()
    }
    return clients[0]
  }
}

private struct RecordedApproval: Equatable, Sendable {
  let id: CodexMCPRequestID
  let decision: CodexMCPApprovalDecision
}

private actor FakeCodexMCPCallRecorder {
  private(set) var cancelCount = 0
  private(set) var responses: [RecordedApproval] = []
  let cancelResult: Bool
  let cancelError: Error?
  let responseError: Error?

  init(
    cancelResult: Bool,
    cancelError: Error?,
    responseError: Error?
  ) {
    self.cancelResult = cancelResult
    self.cancelError = cancelError
    self.responseError = responseError
  }

  func cancel() throws -> Bool {
    cancelCount += 1
    if let cancelError {
      throw cancelError
    }
    return cancelResult
  }

  func respond(
    id: CodexMCPRequestID,
    decision: CodexMCPApprovalDecision
  ) throws {
    if let responseError {
      throw responseError
    }
    responses.append(RecordedApproval(id: id, decision: decision))
  }
}

private final class FakeCodexMCPCallHandle: CodexMCPCallHandleAdapter, @unchecked Sendable {
  let requestID: CodexMCPRequestID
  let serverMessages: AsyncStream<CodexMCPServerMessage>
  let approvalRequests: AsyncStream<CodexMCPRuntimeApproval>

  private let resultStream: AsyncThrowingStream<CodexMCPToolResult, Error>
  private let resultContinuation: AsyncThrowingStream<CodexMCPToolResult, Error>.Continuation
  private let recorder: FakeCodexMCPCallRecorder

  init(
    requestID: CodexMCPRequestID,
    serverMessages: [CodexMCPServerMessage] = [],
    serverMessageDelayNanoseconds: UInt64 = 0,
    approvalRequests: [CodexMCPRuntimeApproval] = [],
    result: CodexMCPToolResult? = nil,
    resultError: Error? = nil,
    cancelResult: Bool = false,
    cancelError: Error? = nil,
    responseError: Error? = nil
  ) {
    self.requestID = requestID
    self.serverMessages = Self.stream(
      serverMessages,
      delayNanoseconds: serverMessageDelayNanoseconds
    )
    self.approvalRequests = Self.stream(approvalRequests)
    let pair = AsyncThrowingStream<CodexMCPToolResult, Error>.makeStream()
    resultStream = pair.stream
    resultContinuation = pair.continuation
    recorder = FakeCodexMCPCallRecorder(
      cancelResult: cancelResult,
      cancelError: cancelError,
      responseError: responseError
    )
    if let result {
      pair.continuation.yield(result)
      pair.continuation.finish()
    } else if let resultError {
      pair.continuation.finish(throwing: resultError)
    }
  }

  var cancelCount: Int {
    get async {
      await recorder.cancelCount
    }
  }

  var recordedResponses: [RecordedApproval] {
    get async {
      await recorder.responses
    }
  }

  func value() async throws -> CodexMCPToolResult {
    for try await result in resultStream {
      return result
    }
    throw CodexMCPRuntimeError(
      code: "test.result_missing",
      message: "Fake result stream ended without a value."
    )
  }

  func cancel() async throws -> Bool {
    try await recorder.cancel()
  }

  func respond(
    to approvalRequestID: CodexMCPRequestID,
    with decision: CodexMCPApprovalDecision
  ) async throws {
    try await recorder.respond(id: approvalRequestID, decision: decision)
  }

  func finish(with result: CodexMCPToolResult) {
    resultContinuation.yield(result)
    resultContinuation.finish()
  }

  private static func stream<Element: Sendable>(
    _ values: [Element],
    delayNanoseconds: UInt64 = 0
  ) -> AsyncStream<Element> {
    AsyncStream { continuation in
      Task {
        if delayNanoseconds > 0 {
          try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        for value in values {
          continuation.yield(value)
        }
        continuation.finish()
      }
    }
  }
}
