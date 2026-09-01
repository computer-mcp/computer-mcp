import CodexMCP
import CryptoKit
import Foundation

protocol CodexMCPRuntimeProtocol: Sendable {
  func status() async -> JSONValue
  func tools() async throws -> JSONValue
  func run(prompt: String, model: String?) async throws -> JSONValue
  func reply(threadID: String, prompt: String) async throws -> JSONValue
  func calls() async -> JSONValue
  func events(callID: String, afterCursor: Int, maxResults: Int) async throws -> JSONValue
  func result(callID: String) async throws -> JSONValue
  func pendingApprovals(callID: String) async throws -> JSONValue
  func respondToApproval(
    callID: String,
    approvalID: String,
    decision: String
  ) async throws -> JSONValue
  func cancel(callID: String) async throws -> JSONValue
  func shutdown() async
}

extension CodexMCPRuntimeProtocol {
  func shutdown() async {}
}

struct CodexMCPRuntimeError: Error, LocalizedError, Equatable, Sendable {
  let code: String
  let message: String

  var errorDescription: String? {
    "\(code): \(message)"
  }
}

protocol CodexMCPCallHandleAdapter: Sendable {
  var requestID: CodexMCPRequestID { get }
  var serverMessages: AsyncStream<CodexMCPServerMessage> { get }
  var approvalRequests: AsyncStream<CodexMCPRuntimeApproval> { get }

  func value() async throws -> CodexMCPToolResult
  func cancel() async throws -> Bool
  func respond(
    to approvalRequestID: CodexMCPRequestID,
    with decision: CodexMCPApprovalDecision
  ) async throws
}

enum CodexMCPRuntimeApproval: Equatable, Sendable {
  struct Exec: Equatable, Sendable {
    let requestID: CodexMCPRequestID
    let threadID: String
    let message: String
    let command: [String]
    let cwd: String
  }

  struct Patch: Equatable, Sendable {
    let requestID: CodexMCPRequestID
    let threadID: String
    let message: String
    let reason: String?
    let grantRoot: String?
    let changes: [String: CodexMCPJSONValue]
  }

  case exec(Exec)
  case patch(Patch)

  var requestID: CodexMCPRequestID {
    switch self {
    case .exec(let request):
      request.requestID
    case .patch(let request):
      request.requestID
    }
  }
}

protocol CodexMCPClientAdapter: Sendable {
  func currentState() async -> CodexMCPClientState
  func start() async throws
  func stop() async throws
  func listTools() async throws -> [CodexMCPToolDescriptor]
  func runCodex(_ request: CodexMCPRunRequest) async throws -> any CodexMCPCallHandleAdapter
  func reply(_ request: CodexMCPReplyRequest) async throws -> any CodexMCPCallHandleAdapter
}

protocol CodexMCPClientAdapterFactory: Sendable {
  func makeClient() async -> any CodexMCPClientAdapter
}

private final class LiveCodexMCPCallHandleAdapter:
  CodexMCPCallHandleAdapter, @unchecked Sendable
{
  let requestID: CodexMCPRequestID
  let serverMessages: AsyncStream<CodexMCPServerMessage>
  let approvalRequests: AsyncStream<CodexMCPRuntimeApproval>

  private let handle: CodexMCPCallHandle

  init(handle: CodexMCPCallHandle) {
    self.handle = handle
    requestID = handle.requestID
    serverMessages = handle.serverMessages
    approvalRequests = AsyncStream { continuation in
      Task {
        for await approval in handle.approvalRequests {
          continuation.yield(Self.runtimeApproval(approval))
        }
        continuation.finish()
      }
    }
  }

  func value() async throws -> CodexMCPToolResult {
    try await handle.value()
  }

  func cancel() async throws -> Bool {
    try await handle.cancel()
  }

  func respond(
    to approvalRequestID: CodexMCPRequestID,
    with decision: CodexMCPApprovalDecision
  ) async throws {
    try await handle.respond(to: approvalRequestID, with: decision)
  }

  private static func runtimeApproval(
    _ approval: CodexMCPApprovalRequest
  ) -> CodexMCPRuntimeApproval {
    switch approval {
    case .exec(let request):
      .exec(
        .init(
          requestID: request.requestID,
          threadID: request.threadID,
          message: request.message,
          command: request.command,
          cwd: request.cwd
        )
      )
    case .patch(let request):
      .patch(
        .init(
          requestID: request.requestID,
          threadID: request.threadID,
          message: request.message,
          reason: request.reason,
          grantRoot: request.grantRoot,
          changes: request.changes
        )
      )
    }
  }
}

private actor LiveCodexMCPClientAdapter: CodexMCPClientAdapter {
  private let client: CodexMCPClient

  init(client: CodexMCPClient) {
    self.client = client
  }

  func currentState() async -> CodexMCPClientState {
    await client.state
  }

  func start() async throws {
    try await client.start()
  }

  func stop() async throws {
    try await client.stop()
  }

  func listTools() async throws -> [CodexMCPToolDescriptor] {
    try await client.listTools()
  }

  func runCodex(_ request: CodexMCPRunRequest) async throws
    -> any CodexMCPCallHandleAdapter
  {
    try await LiveCodexMCPCallHandleAdapter(handle: client.runCodex(request))
  }

  func reply(_ request: CodexMCPReplyRequest) async throws
    -> any CodexMCPCallHandleAdapter
  {
    try await LiveCodexMCPCallHandleAdapter(handle: client.reply(request))
  }
}

private struct LiveCodexMCPClientAdapterFactory: CodexMCPClientAdapterFactory {
  let configuration: CodexConfig
  let workspaceURL: URL

  func makeClient() async -> any CodexMCPClientAdapter {
    Self.makeClient(configuration: configuration, workspaceURL: workspaceURL)
  }

  static func makeClient(
    configuration: CodexConfig,
    workspaceURL: URL
  ) -> any CodexMCPClientAdapter {
    LiveCodexMCPClientAdapter(
      client: CodexMCPClient(
        clientInfo: .init(
          name: "computer_mcp",
          title: "Computer MCP",
          version: ComputerMCPCLI.version,
          requestedProtocolVersion: "2025-03-26"
        ),
        launchOptions: .init(
          executableURL: configuration.executableURL,
          currentDirectoryURL: workspaceURL.standardizedFileURL,
          environment: CodexProcessEnvironment.resolved()
        )
      )
    )
  }
}

actor LiveCodexMCPRuntime: CodexMCPRuntimeProtocol {
  private enum CallLifecycle: String, Sendable {
    case running
    case cancelled
    case completed
    case failed

    var isTerminal: Bool {
      self == .cancelled || self == .completed || self == .failed
    }
  }

  private struct CallState: Sendable {
    let id: String
    let upstreamRequestID: String
    let clientGeneration: Int
    let handle: any CodexMCPCallHandleAdapter
    let buffer: CodexEventBuffer
    let startedAt: Date
    var state: CallLifecycle
    var result: JSONValue?
    var error: CodexMCPRuntimeError?
    var pendingApprovals: [String: CodexMCPRuntimeApproval]
    var upstreamSettled: Bool
  }

  private let configuration: CodexConfig
  private let workspaceURL: URL
  private let outputBounds: CodexOutputBounds
  private let cancellationGrace: Duration
  private let clientFactory: any CodexMCPClientAdapterFactory
  private var client: any CodexMCPClientAdapter
  private var callsByID: [String: CallState] = [:]
  private var pendingLaunches = 0
  private var reconnectRequired = false
  private var lastError: CodexMCPRuntimeError?
  private var clientGeneration = 1

  init(
    configuration: CodexConfig,
    workspaceURL: URL,
    maxOutputBytes: Int = 1_048_576,
    cancellationGrace: Duration = .seconds(2)
  ) {
    let standardizedWorkspace = workspaceURL.standardizedFileURL
    let factory = LiveCodexMCPClientAdapterFactory(
      configuration: configuration,
      workspaceURL: standardizedWorkspace
    )
    self.configuration = configuration
    self.workspaceURL = standardizedWorkspace
    self.outputBounds = CodexOutputBounds(maxOutputBytes: maxOutputBytes)
    self.cancellationGrace = cancellationGrace
    clientFactory = factory
    client = LiveCodexMCPClientAdapterFactory.makeClient(
      configuration: configuration,
      workspaceURL: standardizedWorkspace
    )
  }

  init(
    configuration: CodexConfig,
    workspaceURL: URL,
    maxOutputBytes: Int = 1_048_576,
    cancellationGrace: Duration = .seconds(2),
    client: any CodexMCPClientAdapter,
    clientFactory: any CodexMCPClientAdapterFactory
  ) {
    self.configuration = configuration
    self.workspaceURL = workspaceURL.standardizedFileURL
    self.outputBounds = CodexOutputBounds(maxOutputBytes: maxOutputBytes)
    self.cancellationGrace = cancellationGrace
    self.client = client
    self.clientFactory = clientFactory
  }

  func status() async -> JSONValue {
    let state = await client.currentState()
    return .object([
      "state": .string(Self.stateName(state)),
      "workspace": .string(workspaceURL.path),
      "active_calls": .number(
        Double(callsByID.values.filter { !$0.state.isTerminal }.count + pendingLaunches)
      ),
      "retained_calls": .number(Double(callsByID.count)),
      "max_sessions": .number(Double(configuration.maxSessions)),
      "reconnect_required": .bool(reconnectRequired),
      "last_error": lastError.map(Self.errorJSON) ?? .null,
    ])
  }

  func tools() async throws -> JSONValue {
    let activeClient = try await ensureClient()
    let descriptors: [CodexMCPToolDescriptor]
    do {
      descriptors = try await activeClient.listTools()
      lastError = nil
    } catch {
      throw recordClientFailure(error, operation: "tools_list")
    }

    return .object([
      "tools": .array(
        try descriptors.map { descriptor in
          .object([
            "name": .string(descriptor.name),
            "title": descriptor.title.map(JSONValue.string) ?? .null,
            "description": descriptor.description.map(JSONValue.string) ?? .null,
            "input_schema": outputBounds.json(
              try Self.gatewayJSON(.object(descriptor.inputSchema)),
              maxBytes: outputBounds.maxFieldBytes
            ),
            "output_schema": try descriptor.outputSchema
              .map {
                outputBounds.json(
                  try Self.gatewayJSON(.object($0)),
                  maxBytes: outputBounds.maxFieldBytes
                )
              } ?? .null,
          ])
        }
      )
    ])
  }

  func run(prompt: String, model: String?) async throws -> JSONValue {
    let validatedPrompt = try Self.validatedPrompt(prompt)
    let validatedModel = try Self.validatedModel(model)
    try reserveCallSlot()

    do {
      let activeClient = try await ensureClient()
      let handle = try await activeClient.runCodex(
        CodexMCPRunRequest(
          prompt: validatedPrompt,
          model: validatedModel,
          profile: nil,
          cwd: workspaceURL,
          approvalPolicy: Self.approvalPolicy(configuration.approvalPolicy),
          sandboxMode: Self.sandboxMode(configuration.sandbox),
          configOverrides: [:],
          baseInstructions: nil,
          developerInstructions: nil,
          compactPrompt: nil
        )
      )
      pendingLaunches -= 1
      lastError = nil
      return try await register(handle: handle)
    } catch {
      pendingLaunches -= 1
      if let runtimeError = error as? CodexMCPRuntimeError {
        throw runtimeError
      }
      throw recordClientFailure(error, operation: "run")
    }
  }

  func reply(threadID: String, prompt: String) async throws -> JSONValue {
    let validatedThreadID = try Self.validatedThreadID(threadID)
    let validatedPrompt = try Self.validatedPrompt(prompt)
    try reserveCallSlot()

    do {
      let activeClient = try await ensureClient()
      let handle = try await activeClient.reply(
        .init(threadID: validatedThreadID, prompt: validatedPrompt)
      )
      pendingLaunches -= 1
      lastError = nil
      return try await register(handle: handle)
    } catch {
      pendingLaunches -= 1
      if let runtimeError = error as? CodexMCPRuntimeError {
        throw runtimeError
      }
      throw recordClientFailure(error, operation: "reply")
    }
  }

  func calls() async -> JSONValue {
    .object([
      "calls": .array(
        callsByID.values
          .sorted {
            if $0.startedAt == $1.startedAt {
              return $0.id < $1.id
            }
            return $0.startedAt > $1.startedAt
          }
          .map(Self.callSummary)
      ),
      "max_sessions": .number(Double(configuration.maxSessions)),
      "pending_launches": .number(Double(pendingLaunches)),
    ])
  }

  func events(callID: String, afterCursor: Int, maxResults: Int) async throws -> JSONValue {
    let state = try callState(callID)
    return await state.buffer.read(
      afterCursor: max(afterCursor, 0),
      maxResults: maxResults
    )
  }

  func result(callID: String) async throws -> JSONValue {
    let state = try callState(callID)
    return .object([
      "call": Self.callSummary(state),
      "result": state.result ?? .null,
      "error": state.error.map(Self.errorJSON) ?? .null,
    ])
  }

  func pendingApprovals(callID: String) async throws -> JSONValue {
    let state = try callState(callID)
    return outputBounds.json(
      .object([
        "call_id": .string(callID),
        "approvals": .array(
          state.pendingApprovals
            .sorted { $0.key < $1.key }
            .map { approvalID, approval in
              Self.approvalJSON(approvalID: approvalID, approval: approval)
            }
        ),
      ]))
  }

  func respondToApproval(
    callID: String,
    approvalID: String,
    decision: String
  ) async throws -> JSONValue {
    guard var state = callsByID[callID] else {
      throw Self.unknownCall(callID)
    }
    guard !state.state.isTerminal else {
      throw CodexMCPRuntimeError(
        code: "codex.mcp.call_finished",
        message: "Call '\(callID)' is already \(state.state.rawValue)."
      )
    }
    guard let approval = state.pendingApprovals[approvalID] else {
      throw CodexMCPRuntimeError(
        code: "codex.mcp.approval_unknown",
        message: "Unknown or already resolved approval '\(approvalID)'."
      )
    }

    let resolvedDecision: CodexMCPApprovalDecision
    switch decision {
    case "allow":
      try validateApprovalGrant(approval)
      resolvedDecision = .allow
    case "deny":
      resolvedDecision = .deny
    default:
      throw CodexMCPRuntimeError(
        code: "codex.mcp.approval_decision_invalid",
        message: "decision must be 'allow' or 'deny'."
      )
    }

    do {
      try await state.handle.respond(to: approval.requestID, with: resolvedDecision)
    } catch {
      throw recordClientFailure(error, operation: "approval_response")
    }

    state.pendingApprovals.removeValue(forKey: approvalID)
    callsByID[callID] = state
    await state.buffer.append(
      kind: "approval_resolved",
      payload: .object([
        "approval_id": .string(approvalID),
        "decision": .string(decision),
      ])
    )
    return .object([
      "call_id": .string(callID),
      "approval_id": .string(approvalID),
      "decision": .string(decision),
      "resolved": .bool(true),
    ])
  }

  func cancel(callID: String) async throws -> JSONValue {
    guard var state = callsByID[callID] else {
      throw Self.unknownCall(callID)
    }
    guard !state.state.isTerminal else {
      throw CodexMCPRuntimeError(
        code: "codex.mcp.call_finished",
        message: "Call '\(callID)' is already \(state.state.rawValue)."
      )
    }

    let requested: Bool
    do {
      requested = try await state.handle.cancel()
    } catch {
      throw recordClientFailure(error, operation: "cancel")
    }
    if requested {
      state.state = .cancelled
      state.error = CodexMCPRuntimeError(
        code: "codex.mcp.cancelled",
        message: "Call '\(callID)' was cancelled by the caller."
      )
      state.pendingApprovals.removeAll()
      callsByID[callID] = state
      await state.buffer.append(kind: "cancellation_requested", payload: .object([:]))
      await state.buffer.append(
        kind: "call_cancelled",
        payload: Self.errorJSON(state.error!)
      )
      scheduleCancellationCleanup(callID: callID)
    }
    return .object([
      "call_id": .string(callID),
      "state": .string(state.state.rawValue),
      "cancellation_requested": .bool(requested),
    ])
  }

  func shutdown() async {
    for id in callsByID.keys.sorted() {
      guard var state = callsByID[id] else { continue }
      if !state.state.isTerminal {
        _ = try? await state.handle.cancel()
        state.state = .cancelled
        state.error = CodexMCPRuntimeError(
          code: "codex.mcp.shutdown",
          message: "Call was cancelled because the gateway connection closed."
        )
        state.pendingApprovals.removeAll()
        callsByID[id] = state
      }
    }
    try? await client.stop()
    pendingLaunches = 0
    reconnectRequired = true
  }

  private func ensureClient() async throws -> any CodexMCPClientAdapter {
    var state = await client.currentState()
    if reconnectRequired || state == .stopping || state == .stopped || state == .failed {
      client = await clientFactory.makeClient()
      clientGeneration += 1
      reconnectRequired = false
      state = await client.currentState()
    }

    switch state {
    case .running:
      return client
    case .idle, .starting:
      break
    case .stopping, .stopped, .failed:
      let error = CodexMCPRuntimeError(
        code: "codex.mcp.reconnect_failed",
        message: "The replacement Codex MCP client is \(Self.stateName(state))."
      )
      reconnectRequired = true
      lastError = error
      throw error
    }

    do {
      try await client.start()
      guard await client.currentState() == .running else {
        throw CodexMCPRuntimeError(
          code: "codex.mcp.start_failed",
          message: "Codex MCP client did not enter the running state."
        )
      }
      lastError = nil
      return client
    } catch {
      reconnectRequired = true
      let mapped = Self.runtimeError(for: error, operation: "start")
      lastError = mapped
      throw mapped
    }
  }

  private func reserveCallSlot() throws {
    pruneCompletedCallsIfNeeded()
    guard callsByID.count + pendingLaunches < configuration.maxSessions else {
      throw CodexMCPRuntimeError(
        code: "codex.mcp.session_limit",
        message: "The configured maximum of \(configuration.maxSessions) sessions is active."
      )
    }
    pendingLaunches += 1
  }

  private func register(handle: any CodexMCPCallHandleAdapter) async throws -> JSONValue {
    let upstreamRequestID = Self.requestIDString(handle.requestID)
    let callID: String
    if let existing = callsByID[upstreamRequestID] {
      guard existing.clientGeneration != clientGeneration else {
        _ = try? await handle.cancel()
        throw CodexMCPRuntimeError(
          code: "codex.mcp.call_conflict",
          message: "Duplicate upstream request id '\(upstreamRequestID)'."
        )
      }
      callID = "g\(clientGeneration):\(upstreamRequestID)"
    } else {
      callID = upstreamRequestID
    }
    guard callsByID[callID] == nil else {
      _ = try? await handle.cancel()
      throw CodexMCPRuntimeError(
        code: "codex.mcp.call_conflict",
        message: "Duplicate upstream request id '\(upstreamRequestID)'."
      )
    }

    let buffer = CodexEventBuffer(
      capacity: configuration.maxEventsPerSession,
      maxOutputBytes: outputBounds.maxOutputBytes
    )
    callsByID[callID] = CallState(
      id: callID,
      upstreamRequestID: upstreamRequestID,
      clientGeneration: clientGeneration,
      handle: handle,
      buffer: buffer,
      startedAt: Date(),
      state: .running,
      result: nil,
      error: nil,
      pendingApprovals: [:],
      upstreamSettled: false
    )
    await buffer.append(
      kind: "call_started",
      payload: .object(["request_id": .string(callID)])
    )
    startConsumers(callID: callID, handle: handle)
    return .object([
      "call_id": .string(callID),
      "state": .string(CallLifecycle.running.rawValue),
      "events_cursor": .number(0),
    ])
  }

  private func startConsumers(
    callID: String,
    handle: any CodexMCPCallHandleAdapter
  ) {
    let serverMessageTask = Task { [weak self, handle] in
      for await message in handle.serverMessages {
        await self?.record(message: message, callID: callID)
      }
    }
    let approvalRequestTask = Task { [weak self, handle] in
      for await approval in handle.approvalRequests {
        await self?.record(approval: approval, callID: callID)
      }
    }
    Task { [weak self, handle] in
      do {
        let result = try await handle.value()
        await serverMessageTask.value
        await approvalRequestTask.value
        await self?.complete(callID: callID, result: result)
      } catch {
        await serverMessageTask.value
        await approvalRequestTask.value
        await self?.fail(callID: callID, error: error)
      }
    }
  }

  private func record(message: CodexMCPServerMessage, callID: String) async {
    guard let state = callsByID[callID], !state.state.isTerminal else { return }
    let rawEvent = (try? Self.gatewayJSON(message.rawEvent)) ?? .null
    await state.buffer.append(
      kind: "server_message",
      payload: .object([
        "method": .string(message.method),
        "thread_id": message.threadID.map(JSONValue.string) ?? .null,
        "request_id": message.requestID.map(Self.requestIDString).map(JSONValue.string) ?? .null,
        "event": rawEvent,
      ])
    )
  }

  private func record(approval: CodexMCPRuntimeApproval, callID: String) async {
    guard var state = callsByID[callID], !state.state.isTerminal else { return }
    let approvalID = Self.requestIDString(approval.requestID)
    state.pendingApprovals[approvalID] = approval
    callsByID[callID] = state
    await state.buffer.append(
      kind: "approval_requested",
      payload: Self.approvalJSON(approvalID: approvalID, approval: approval)
    )
  }

  private func complete(callID: String, result: CodexMCPToolResult) async {
    guard var state = callsByID[callID] else { return }
    if state.state == .cancelled {
      state.upstreamSettled = true
      callsByID[callID] = state
      return
    }
    guard !state.state.isTerminal else { return }
    state.result = toolResultJSON(result)
    if result.isError {
      state.state = .failed
      let message = outputBounds.text(result.content)
      state.error = CodexMCPRuntimeError(
        code: "codex.mcp.upstream_tool_error",
        message: message.value
      )
    } else {
      state.state = .completed
      state.error = nil
    }
    state.pendingApprovals.removeAll()
    await state.buffer.append(
      kind: result.isError ? "call_failed" : "call_completed",
      payload: result.isError ? Self.errorJSON(state.error!) : (state.result ?? .null)
    )
    callsByID[callID] = state
  }

  private func fail(callID: String, error: Error) async {
    guard var state = callsByID[callID] else { return }
    if state.state == .cancelled {
      state.upstreamSettled = true
      callsByID[callID] = state
      return
    }
    guard !state.state.isTerminal else { return }
    let mapped = Self.runtimeError(for: error, operation: "call")
    state.state = .failed
    state.error = mapped
    state.pendingApprovals.removeAll()
    if Self.requiresReconnect(error) {
      reconnectRequired = true
      lastError = mapped
    }
    await state.buffer.append(kind: "call_failed", payload: Self.errorJSON(mapped))
    callsByID[callID] = state
  }

  private func scheduleCancellationCleanup(callID: String) {
    let grace = cancellationGrace
    Task { [weak self] in
      try? await Task.sleep(for: grace)
      guard !Task.isCancelled else { return }
      await self?.cleanupCancelledCallIfNeeded(callID: callID)
    }
  }

  private func cleanupCancelledCallIfNeeded(callID: String) async {
    guard var cancelled = callsByID[callID],
      cancelled.state == .cancelled,
      !cancelled.upstreamSettled
    else {
      return
    }

    let restartError = CodexMCPRuntimeError(
      code: "codex.mcp.cancel_cleanup_restart",
      message:
        "The Codex MCP provider was restarted because a cancelled upstream request did not settle."
    )
    for id in callsByID.keys.sorted() where id != callID {
      guard var state = callsByID[id], !state.state.isTerminal else { continue }
      state.state = .failed
      state.error = restartError
      state.pendingApprovals.removeAll()
      callsByID[id] = state
      await state.buffer.append(
        kind: "call_failed",
        payload: Self.errorJSON(restartError)
      )
    }

    reconnectRequired = true
    do {
      try await client.stop()
    } catch {
      lastError = Self.runtimeError(for: error, operation: "cancel_cleanup")
    }
    cancelled.upstreamSettled = true
    callsByID[callID] = cancelled
    await cancelled.buffer.append(
      kind: "cancellation_cleanup_completed",
      payload: .object(["provider_restarted": .bool(true)])
    )
  }

  private func callState(_ callID: String) throws -> CallState {
    guard let state = callsByID[callID] else {
      throw Self.unknownCall(callID)
    }
    return state
  }

  private func pruneCompletedCallsIfNeeded() {
    guard callsByID.count + pendingLaunches >= configuration.maxSessions else { return }
    let removable = callsByID.values
      .filter { $0.state.isTerminal }
      .sorted {
        if $0.startedAt == $1.startedAt {
          return $0.id < $1.id
        }
        return $0.startedAt < $1.startedAt
      }
    for state in removable
    where callsByID.count + pendingLaunches >= configuration.maxSessions {
      callsByID.removeValue(forKey: state.id)
    }
  }

  private func recordClientFailure(_ error: Error, operation: String) -> CodexMCPRuntimeError {
    let mapped = Self.runtimeError(for: error, operation: operation)
    lastError = mapped
    if Self.requiresReconnect(error) {
      reconnectRequired = true
    }
    return mapped
  }

  private func validateApprovalGrant(_ approval: CodexMCPRuntimeApproval) throws {
    switch approval {
    case .exec(let request):
      let cwd = URL(fileURLWithPath: request.cwd).standardizedFileURL
      guard cwd.path.hasPrefix("/"), Self.contains(cwd, in: workspaceURL) else {
        throw CodexMCPRuntimeError(
          code: "codex.mcp.approval_outside_workspace",
          message: "Command cwd is outside the bound workspace."
        )
      }
    case .patch(let request):
      if let grantRoot = request.grantRoot {
        let root = URL(fileURLWithPath: grantRoot).standardizedFileURL
        guard root.path.hasPrefix("/"), Self.contains(root, in: workspaceURL) else {
          throw CodexMCPRuntimeError(
            code: "codex.mcp.approval_outside_workspace",
            message: "Patch grant root is outside the bound workspace."
          )
        }
      }
      for path in request.changes.keys {
        let url = URL(fileURLWithPath: path, relativeTo: workspaceURL).standardizedFileURL
        guard Self.contains(url, in: workspaceURL) else {
          throw CodexMCPRuntimeError(
            code: "codex.mcp.approval_outside_workspace",
            message: "Patch path is outside the bound workspace."
          )
        }
      }
    }
  }

  private static func validatedPrompt(_ prompt: String) throws -> String {
    let value = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else {
      throw CodexMCPRuntimeError(
        code: "codex.mcp.prompt_required",
        message: "prompt must not be empty."
      )
    }
    guard !value.contains("\0") else {
      throw CodexMCPRuntimeError(
        code: "codex.mcp.prompt_invalid",
        message: "prompt must not contain NUL."
      )
    }
    guard value.utf8.count <= 1_048_576 else {
      throw CodexMCPRuntimeError(
        code: "codex.mcp.prompt_invalid",
        message: "prompt must not exceed 1048576 UTF-8 bytes."
      )
    }
    return value
  }

  private static func validatedThreadID(_ threadID: String) throws -> String {
    let value = threadID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.utf8.count <= 1_024,
      value.rangeOfCharacter(from: .controlCharacters) == nil,
      CodexApprovalRedactor.redactString(value, maximumCharacters: 8_192) == value
    else {
      throw CodexMCPRuntimeError(
        code: "codex.mcp.thread_id_required",
        message: "thread_id must be a bounded opaque identifier."
      )
    }
    return value
  }

  private static func validatedModel(_ model: String?) throws -> String? {
    guard let model else { return nil }
    let value = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.utf8.count <= 256,
      value.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw CodexMCPRuntimeError(
        code: "codex.mcp.model_invalid",
        message: "model must contain at most 256 UTF-8 bytes without control characters."
      )
    }
    return value
  }

  private static func approvalPolicy(
    _ policy: CodexApprovalPolicy
  ) -> CodexMCPRunRequest.ApprovalPolicy {
    switch policy {
    case .untrusted: .untrusted
    case .onFailure: .onFailure
    case .onRequest: .onRequest
    case .never: .never
    }
  }

  private static func sandboxMode(
    _ mode: CodexSandboxMode
  ) -> CodexMCPRunRequest.SandboxMode {
    switch mode {
    case .readOnly: .readOnly
    case .workspaceWrite: .workspaceWrite
    case .dangerFullAccess:
      preconditionFailure("danger-full-access is rejected during configuration validation")
    }
  }

  private static func stateName(_ state: CodexMCPClientState) -> String {
    switch state {
    case .idle: "idle"
    case .starting: "starting"
    case .running: "running"
    case .stopping: "stopping"
    case .stopped: "stopped"
    case .failed: "failed"
    }
  }

  private static func callSummary(_ state: CallState) -> JSONValue {
    .object([
      "call_id": .string(state.id),
      "upstream_request_id": .string(state.upstreamRequestID),
      "client_generation": .number(Double(state.clientGeneration)),
      "state": .string(state.state.rawValue),
      "started_at": .string(
        state.startedAt.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
      ),
      "pending_approvals": .number(Double(state.pendingApprovals.count)),
      "has_result": .bool(state.result != nil),
      "error": state.error.map(errorJSON) ?? .null,
    ])
  }

  private func toolResultJSON(_ result: CodexMCPToolResult) -> JSONValue {
    let content = outputBounds.text(result.content)
    return .object([
      "thread_id": result.threadID.map(JSONValue.string) ?? .null,
      "content": .string(content.value),
      "content_original_bytes": .number(Double(content.originalBytes)),
      "content_truncated": .bool(content.truncated),
      "content_blocks": outputBounds.json(
        .array(result.rawContentBlocks.map { (try? Self.gatewayJSON($0)) ?? .null }),
        maxBytes: outputBounds.maxFieldBytes
      ),
      "structured_content": result.rawStructuredContent
        .flatMap { try? Self.gatewayJSON($0) }
        .map {
          outputBounds.json($0, maxBytes: outputBounds.maxFieldBytes)
        } ?? .null,
      "is_error": .bool(result.isError),
    ])
  }

  private static func approvalJSON(
    approvalID: String,
    approval: CodexMCPRuntimeApproval
  ) -> JSONValue {
    let value: JSONValue
    switch approval {
    case .exec(let request):
      value = .object([
        "approval_id": .string(approvalID),
        "kind": .string("exec"),
        "thread_id": .string(request.threadID),
        "message": .string(request.message),
        "command": .array(request.command.map(JSONValue.string)),
        "cwd": .string(request.cwd),
      ])
    case .patch(let request):
      value = .object([
        "approval_id": .string(approvalID),
        "kind": .string("patch"),
        "thread_id": .string(request.threadID),
        "message": .string(request.message),
        "reason": request.reason.map(JSONValue.string) ?? .null,
        "grant_root": request.grantRoot.map(JSONValue.string) ?? .null,
        "paths": .array(request.changes.keys.sorted().map(JSONValue.string)),
      ])
    }
    return CodexApprovalRedactor.redact(value)
  }

  private static func errorJSON(_ error: CodexMCPRuntimeError) -> JSONValue {
    .object([
      "code": .string(error.code),
      "message": .string(error.message),
    ])
  }

  private static func contains(_ candidate: URL, in workspace: URL) -> Bool {
    let root = workspace.standardizedFileURL.resolvingSymlinksInPath()
    let value = candidate.standardizedFileURL.resolvingSymlinksInPath()
    return value == root || value.path.hasPrefix(root.path + "/")
  }

  private static func requestIDString(_ id: CodexMCPRequestID) -> String {
    switch id {
    case .integer(let value): "n:\(value)"
    case .string(let value): opaqueProtocolID(prefix: "s", value: value)
    }
  }

  private static func opaqueProtocolID(prefix: String, value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty, trimmed == value, value.utf8.count <= 1_024,
      value.rangeOfCharacter(from: .controlCharacters) == nil,
      CodexApprovalRedactor.redactString(value, maximumCharacters: 8_192) == value
    {
      return "\(prefix):\(value)"
    }
    let digest = SHA256.hash(data: Data(value.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return "\(prefix):sha256:\(digest)"
  }

  private static func gatewayJSON(_ value: CodexMCPJSONValue) throws -> JSONValue {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(JSONValue.self, from: data)
  }

  private static func unknownCall(_ callID: String) -> CodexMCPRuntimeError {
    CodexMCPRuntimeError(
      code: "codex.mcp.call_unknown",
      message: "Unknown call '\(callID)'."
    )
  }

  private static func runtimeError(
    for error: Error,
    operation: String
  ) -> CodexMCPRuntimeError {
    let mapped = unredactedRuntimeError(for: error, operation: operation)
    return CodexMCPRuntimeError(
      code: mapped.code,
      message: CodexApprovalRedactor.redactString(mapped.message)
    )
  }

  private static func unredactedRuntimeError(
    for error: Error,
    operation: String
  ) -> CodexMCPRuntimeError {
    if let runtimeError = error as? CodexMCPRuntimeError {
      return runtimeError
    }
    guard let mcpError = error as? CodexMCPError else {
      return CodexMCPRuntimeError(
        code: "codex.mcp.\(operation)_failed",
        message: error.localizedDescription
      )
    }

    switch mcpError {
    case .invalidStateTransition:
      return CodexMCPRuntimeError(
        code: "codex.mcp.invalid_state",
        message: "The official Codex MCP client rejected the \(operation) lifecycle transition."
      )
    case .startupFailure:
      return CodexMCPRuntimeError(
        code: "codex.mcp.start_failed",
        message: "The Codex MCP process did not complete its MCP startup handshake."
      )
    case .transportFailure:
      return CodexMCPRuntimeError(
        code: "codex.mcp.transport_failed",
        message: "The Codex MCP transport failed during \(operation)."
      )
    case .protocolFailure:
      return CodexMCPRuntimeError(
        code: "codex.mcp.protocol_failed",
        message: "The Codex MCP server returned an invalid protocol payload during \(operation)."
      )
    case .jsonrpcFailure(let failure):
      return CodexMCPRuntimeError(
        code: "codex.mcp.upstream_error",
        message:
          "The Codex MCP server returned JSON-RPC error \(failure.code) during \(operation): \(failure.message)"
      )
    case .processFailure(let stage, let context):
      let detail = context.message.map { ": \($0)" } ?? ""
      return CodexMCPRuntimeError(
        code: "codex.mcp.\(stage.rawValue)_failed",
        message: "The Codex MCP process failed during \(stage.rawValue)\(detail)"
      )
    case .approvalFlowFailure:
      return CodexMCPRuntimeError(
        code: "codex.mcp.approval_failed",
        message: "The Codex MCP approval flow failed during \(operation)."
      )
    }
  }

  private static func requiresReconnect(_ error: Error) -> Bool {
    guard let error = error as? CodexMCPError else {
      return !(error is CodexMCPRuntimeError)
    }
    switch error {
    case .startupFailure, .transportFailure, .protocolFailure, .processFailure,
      .invalidStateTransition:
      return true
    case .jsonrpcFailure, .approvalFlowFailure:
      return false
    }
  }
}
