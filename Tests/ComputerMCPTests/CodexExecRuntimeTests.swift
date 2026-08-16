import CodexExec
import Foundation
import Testing

@testable import ComputerMCP

@Suite(.serialized)

final class CodexExecRuntimeTests {
  @Test
  func testStartUsesFixedWorkspaceAndPolicyWithoutUnsafeOptions() async throws {
    let workspace = URL(fileURLWithPath: "/tmp/computer-mcp-workspace")
    let adapter = FakeCodexExecClientAdapter(handles: [
      FakeCodexExecHandle(
        lines: [
          #"{"type":"thread.started","thread_id":"thread-123"}"#,
          #"{"type":"item.completed","item":{"id":"message-1","type":"agent_message","text":"done"}}"#,
          #"{"type":"turn.completed","usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1}}"#,
        ],
        termination: successfulTermination(workspace: workspace, operation: .run)
      )
    ])
    let runtime = LiveCodexExecRuntime(
      configuration: configuration(),
      workspaceURL: workspace,
      client: adapter
    )

    let started = try await runtime.start(prompt: "Implement the change.", model: "gpt-5")
    let sessionID = try requiredString("session_id", in: started)
    let runRequests = await adapter.runRequests
    let request = try #require(runRequests.first)

    #expect((request.promptInput) == (.text("Implement the change.")))
    #expect((request.outputMode) == (.jsonl))
    #expect((request.options.workingDirectory) == (workspace.standardizedFileURL))
    #expect((request.options.approvalMode) == nil)
    #expect((request.options.sandboxMode) == ("workspace-write"))
    #expect((request.options.model) == ("gpt-5"))
    #expect((request.options.additionalWritableDirectories) == ([]))
    #expect((request.options.configOverrides) == ([#"approval_policy="never""#]))
    #expect(request.options.ignoreUserConfig)
    #expect(!(request.options.dangerouslyBypassApprovalsAndSandbox))
    #expect(!(request.options.fullAuto))
    #expect(!(request.options.useOSS))
    #expect(request.options.skipGitRepoCheck)
    #expect((request.options.profile) == nil)

    let result = try await waitForResult(runtime: runtime, sessionID: sessionID)
    #expect((result.objectValue?["state"]) == (.string("completed")))
    #expect((result.objectValue?["upstream_session_id"]) == (.string("thread-123")))
    #expect((result.objectValue?["final_message"]) == (.string("done")))
    #expect(
      (result.objectValue?["termination"]?.objectValue?["working_directory"])
        == (.string(workspace.standardizedFileURL.path)))
  }

  @Test
  func testResumeUsesOpaqueSessionSelectorAndSameFixedPolicy() async throws {
    let workspace = URL(fileURLWithPath: "/tmp/resume-workspace")
    let adapter = FakeCodexExecClientAdapter(handles: [
      FakeCodexExecHandle(
        lines: [
          #"{"type":"thread.started","thread_id":"thread-resumed"}"#,
          #"{"type":"turn.completed","usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1}}"#,
        ],
        termination: successfulTermination(workspace: workspace, operation: .resume)
      )
    ])
    let runtime = LiveCodexExecRuntime(
      configuration: configuration(sandbox: .readOnly, approval: .onRequest),
      workspaceURL: workspace,
      client: adapter
    )

    _ = try await runtime.resume(
      upstreamSessionID: "thread_original-1",
      prompt: "Continue."
    )
    let resumeRequests = await adapter.resumeRequests
    let request = try #require(resumeRequests.first)

    #expect((request.selector) == (.sessionID("thread_original-1")))
    #expect((request.promptInput) == (.text("Continue.")))
    #expect((request.outputMode) == (.jsonl))
    #expect((request.options.workingDirectory) == (workspace.standardizedFileURL))
    #expect((request.options.approvalMode) == nil)
    #expect((request.options.sandboxMode) == ("read-only"))
    #expect((request.options.additionalWritableDirectories) == ([]))
    #expect((request.options.configOverrides) == ([#"approval_policy="on-request""#]))
    #expect(request.options.ignoreUserConfig)
    #expect(!(request.options.dangerouslyBypassApprovalsAndSandbox))
    #expect(request.options.skipGitRepoCheck)
  }

  @Test
  func testEventsUseBoundedCursorBufferAndReportMissedRows() async throws {
    let lines =
      (1...5).map {
        #"{"type":"experimental.event","sequence":\#($0)}"#
      } + [
        #"{"type":"turn.completed","usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1}}"#
      ]
    let adapter = FakeCodexExecClientAdapter(handles: [
      FakeCodexExecHandle(
        lines: lines,
        termination: successfulTermination(
          workspace: URL(fileURLWithPath: "/tmp/events"),
          operation: .run
        )
      )
    ])
    let runtime = LiveCodexExecRuntime(
      configuration: configuration(maxEvents: 3),
      workspaceURL: URL(fileURLWithPath: "/tmp/events"),
      client: adapter
    )

    let started = try await runtime.start(prompt: "Observe.", model: nil)
    let sessionID = try requiredString("session_id", in: started)
    _ = try await waitForResult(runtime: runtime, sessionID: sessionID)
    let events = try await runtime.events(
      sessionID: sessionID,
      afterCursor: 0,
      maxResults: 100
    )

    #expect((events.objectValue?["events"]?.arrayValue?.count) == (3))
    #expect((events.objectValue?["missed_events"]) == (.number(5)))
    #expect((events.objectValue?["next_cursor"]) == (.number(8)))
  }

  @Test
  func testActiveSessionLimitFailsThenCancelledSessionCanBeEvicted() async throws {
    let firstHandle = ControllableCodexExecHandle()
    let secondHandle = FakeCodexExecHandle(
      lines: [],
      termination: successfulTermination(
        workspace: URL(fileURLWithPath: "/tmp/limit"),
        operation: .run
      )
    )
    let adapter = FakeCodexExecClientAdapter(handles: [firstHandle, secondHandle])
    let runtime = LiveCodexExecRuntime(
      configuration: configuration(maxSessions: 1),
      workspaceURL: URL(fileURLWithPath: "/tmp/limit"),
      client: adapter
    )

    let first = try await runtime.start(prompt: "Wait.", model: nil)
    let firstID = try requiredString("session_id", in: first)
    await assertThrowsErrorAsync(
      try await runtime.start(prompt: "Blocked.", model: nil)
    ) { error in
      #expect(((error as? CodexExecRuntimeError)?.code) == ("codex.exec.session_limit"))
    }

    let cancelled = try await runtime.cancel(sessionID: firstID)
    #expect((cancelled.objectValue?["state"]) == (.string("cancelled")))
    _ = try await runtime.start(prompt: "Replacement.", model: nil)
    let runRequestCount = await adapter.runRequests.count
    #expect((runRequestCount) == (2))
  }

  @Test
  func testResultAndCancelReturnStableLifecycleErrors() async throws {
    let handle = ControllableCodexExecHandle()
    let adapter = FakeCodexExecClientAdapter(handles: [handle])
    let runtime = LiveCodexExecRuntime(
      configuration: configuration(),
      workspaceURL: URL(fileURLWithPath: "/tmp/errors"),
      client: adapter
    )
    let started = try await runtime.start(prompt: "Wait.", model: nil)
    let sessionID = try requiredString("session_id", in: started)

    await assertThrowsErrorAsync(try await runtime.result(sessionID: sessionID)) {
      error in
      #expect(((error as? CodexExecRuntimeError)?.code) == ("codex.exec.not_finished"))
    }
    await assertThrowsErrorAsync(try await runtime.result(sessionID: "missing")) {
      error in
      #expect(((error as? CodexExecRuntimeError)?.code) == ("codex.exec.session_unknown"))
    }

    _ = try await runtime.cancel(sessionID: sessionID)
    let result = try await runtime.result(sessionID: sessionID)
    #expect((result.objectValue?["state"]) == (.string("cancelled")))
    #expect(
      (result.objectValue?["error"]?.objectValue?["code"]) == (.string("codex.exec.cancelled")))
    await assertThrowsErrorAsync(try await runtime.cancel(sessionID: sessionID)) {
      error in
      #expect(((error as? CodexExecRuntimeError)?.code) == ("codex.exec.already_finished"))
    }
  }

  @Test
  func testMalformedJSONLFailureUsesStableCodeAndKeepsRawEvent() async throws {
    let workspace = URL(fileURLWithPath: "/tmp/malformed")
    let adapter = FakeCodexExecClientAdapter(handles: [
      FakeCodexExecHandle(
        lines: ["not-json"],
        error: CodexExecError.malformedJSONL(
          line: "not-json",
          partialObservation: nil
        )
      )
    ])
    let runtime = LiveCodexExecRuntime(
      configuration: configuration(),
      workspaceURL: workspace,
      client: adapter
    )

    let started = try await runtime.start(prompt: "Run.", model: nil)
    let sessionID = try requiredString("session_id", in: started)
    let result = try await waitForResult(runtime: runtime, sessionID: sessionID)
    let events = try await runtime.events(
      sessionID: sessionID,
      afterCursor: 0,
      maxResults: 10
    )

    #expect((result.objectValue?["state"]) == (.string("failed")))
    #expect(
      (result.objectValue?["error"]?.objectValue?["code"])
        == (.string("codex.exec.malformed_jsonl")))
    #expect(
      events.objectValue?["events"]?.arrayValue?.contains(where: {
        $0.objectValue?["kind"] == .string("jsonl.malformed")
      }) == true)
  }

  @Test
  func testResultBoundsFinalMessageAndCapturedStderr() async throws {
    let workspace = URL(fileURLWithPath: "/tmp/bounded-result")
    let largeText = String(repeating: "result-", count: 2_000)
    let adapter = FakeCodexExecClientAdapter(handles: [
      FakeCodexExecHandle(
        lines: [
          #"{"type":"item.completed","item":{"id":"message-1","type":"agent_message","text":"\#(largeText)"}}"#
        ],
        termination: successfulTermination(
          workspace: workspace,
          operation: .run,
          stderr: String(repeating: "stderr-", count: 2_000)
        )
      )
    ])
    let runtime = LiveCodexExecRuntime(
      configuration: configuration(),
      workspaceURL: workspace,
      maxOutputBytes: 2_048,
      client: adapter
    )

    let started = try await runtime.start(prompt: "Run.", model: nil)
    let sessionID = try requiredString("session_id", in: started)
    let result = try await waitForResult(runtime: runtime, sessionID: sessionID)
    let termination = try #require(result.objectValue?["termination"]?.objectValue)

    #expect((result.objectValue?["final_message_truncated"]) == (.bool(true)))
    #expect(
      (result.objectValue?["final_message_original_bytes"]?.intValue ?? 0)
        > (result.objectValue?["final_message"]?.stringValue?.utf8.count ?? .max))
    #expect((termination["stderr_truncated"]) == (.bool(true)))
    #expect(
      (termination["stderr_original_bytes"]?.intValue ?? 0)
        > (termination["stderr"]?.stringValue?.utf8.count ?? .max))
  }

  @Test
  func testInputValidationOccursBeforeLaunchingClient() async throws {
    let adapter = FakeCodexExecClientAdapter(handles: [])
    let runtime = LiveCodexExecRuntime(
      configuration: configuration(),
      workspaceURL: URL(fileURLWithPath: "/tmp/validation"),
      client: adapter
    )

    await assertThrowsErrorAsync(try await runtime.start(prompt: "  ", model: nil)) {
      error in
      #expect(((error as? CodexExecRuntimeError)?.code) == ("codex.exec.invalid_prompt"))
    }
    await assertThrowsErrorAsync(
      try await runtime.resume(upstreamSessionID: "../escape", prompt: nil)
    ) { error in
      #expect(
        ((error as? CodexExecRuntimeError)?.code) == ("codex.exec.invalid_upstream_session_id"))
    }
    let runRequests = await adapter.runRequests
    let resumeRequests = await adapter.resumeRequests
    #expect((runRequests) == ([]))
    #expect((resumeRequests) == ([]))
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

  private func successfulTermination(
    workspace: URL,
    operation: CodexExecOperation,
    stderr: String = ""
  ) -> CodexExecTermination {
    CodexExecTermination(
      operation: operation,
      effectiveWorkingDirectory: workspace.standardizedFileURL,
      exitInterpretation: .exited(code: 0),
      capturedStderrText: stderr
    )
  }

  private func requiredString(_ key: String, in value: JSONValue) throws -> String {
    try #require(value.objectValue?[key]?.stringValue)
  }

  private func waitForResult(
    runtime: LiveCodexExecRuntime,
    sessionID: String
  ) async throws -> JSONValue {
    for _ in 0..<100 {
      do {
        return try await runtime.result(sessionID: sessionID)
      } catch let error as CodexExecRuntimeError
        where error.code == "codex.exec.not_finished"
      {
        try await Task.sleep(for: .milliseconds(5))
      }
    }
    Issue.record("Exec session did not reach a terminal state.")
    return try await runtime.result(sessionID: sessionID)
  }
}

private actor FakeCodexExecClientAdapter: CodexExecClientAdapter {
  private var handles: [any CodexExecProcessHandleAdapter]
  private(set) var runRequests: [CodexExecRunRequest] = []
  private(set) var resumeRequests: [CodexExecResumeRequest] = []

  init(handles: [any CodexExecProcessHandleAdapter]) {
    self.handles = handles
  }

  func run(_ request: CodexExecRunRequest) throws -> any CodexExecProcessHandleAdapter {
    runRequests.append(request)
    return try nextHandle()
  }

  func resume(
    _ request: CodexExecResumeRequest
  ) throws -> any CodexExecProcessHandleAdapter {
    resumeRequests.append(request)
    return try nextHandle()
  }

  private func nextHandle() throws -> any CodexExecProcessHandleAdapter {
    guard !handles.isEmpty else {
      throw CodexExecRuntimeError(
        code: "test.no_handle",
        message: "No fake handle was queued."
      )
    }
    return handles.removeFirst()
  }
}

private struct FakeCodexExecHandle: CodexExecProcessHandleAdapter {
  let stdoutLines: AsyncThrowingStream<String, Error>
  private let termination: CodexExecTermination?
  private let error: Error?

  init(
    lines: [String],
    termination: CodexExecTermination? = nil,
    error: Error? = nil
  ) {
    self.termination = termination
    self.error = error
    self.stdoutLines = AsyncThrowingStream { continuation in
      for line in lines {
        continuation.yield(line)
      }
      continuation.finish()
    }
  }

  func waitForTermination() async throws -> CodexExecTermination {
    if let error {
      throw error
    }
    return try #require(termination)
  }
}

private final class ControllableCodexExecHandle:
  CodexExecProcessHandleAdapter,
  @unchecked Sendable
{
  let stdoutLines: AsyncThrowingStream<String, Error>

  init() {
    self.stdoutLines = AsyncThrowingStream { _ in }
  }

  func waitForTermination() async throws -> CodexExecTermination {
    try await Task.sleep(for: .seconds(60))
    throw CodexExecRuntimeError(
      code: "test.unexpected_completion",
      message: "The controllable handle should have been cancelled."
    )
  }
}

private func assertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  _ errorHandler: (Error) -> Void,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    Issue.record("Expected expression to throw.")
  } catch {
    errorHandler(error)
  }
}
