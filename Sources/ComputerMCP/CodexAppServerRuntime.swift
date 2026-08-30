import CodexAppServerClient
import CodexAppServerProtocol
import CodexAppServerStdio
import Foundation

struct CodexAppServerMethod: Equatable, Sendable {
  let method: String
  let description: String
  let takesParams: Bool
  let risk: CapabilityRisk
}

enum CodexAppServerMethodCatalog {
  static let methods: [CodexAppServerMethod] = [
    .init(
      method: "account/rateLimits/read",
      description: "Read the current Codex account rate-limit snapshot.",
      takesParams: false,
      risk: .readOnly
    ),
    .init(
      method: "account/read",
      description: "Read non-secret Codex account metadata.",
      takesParams: true,
      risk: .readOnly
    ),
    .init(
      method: "account/usage/read",
      description: "Read the current Codex account token-usage summary.",
      takesParams: false,
      risk: .readOnly
    ),
    .init(
      method: "app/list",
      description: "List Codex apps available to the installed Codex runtime.",
      takesParams: true,
      risk: .readOnly
    ),
    .init(
      method: "experimentalFeature/list",
      description: "List experimental Codex feature metadata.",
      takesParams: true,
      risk: .readOnly
    ),
    .init(
      method: "model/list",
      description: "List models exposed by the installed Codex runtime.",
      takesParams: true,
      risk: .readOnly
    ),
    .init(
      method: "plugin/list",
      description: "List installed Codex plugins without mutating them.",
      takesParams: true,
      risk: .readOnly
    ),
    .init(
      method: "plugin/read",
      description: "Read metadata for one installed Codex plugin.",
      takesParams: true,
      risk: .readOnly
    ),
    .init(
      method: "skills/list",
      description: "List Skills discovered by Codex.",
      takesParams: true,
      risk: .readOnly
    ),
    .init(
      method: "thread/list",
      description: "List Codex threads.",
      takesParams: true,
      risk: .readOnly
    ),
    .init(
      method: "thread/read",
      description: "Read one Codex thread and its persisted turns.",
      takesParams: true,
      risk: .readOnly
    ),
    .init(
      method: "thread/start",
      description: "Start a Codex thread in the bound workspace and sandbox.",
      takesParams: true,
      risk: .workspaceWrite
    ),
    .init(
      method: "thread/resume",
      description: "Resume a Codex thread in the bound workspace.",
      takesParams: true,
      risk: .workspaceWrite
    ),
    .init(
      method: "thread/fork",
      description: "Fork an existing Codex thread.",
      takesParams: true,
      risk: .workspaceWrite
    ),
    .init(
      method: "thread/compact/start",
      description: "Start compaction for one Codex thread.",
      takesParams: true,
      risk: .workspaceWrite
    ),
    .init(
      method: "thread/inject_items",
      description: "Inject protocol items into one Codex thread.",
      takesParams: true,
      risk: .workspaceWrite
    ),
    .init(
      method: "thread/metadata/update",
      description: "Update reviewed metadata for one Codex thread.",
      takesParams: true,
      risk: .workspaceWrite
    ),
    .init(
      method: "thread/name/set",
      description: "Set the display name of one Codex thread.",
      takesParams: true,
      risk: .workspaceWrite
    ),
    .init(
      method: "thread/rollback",
      description: "Roll a Codex thread back to a prior turn.",
      takesParams: true,
      risk: .workspaceWrite
    ),
    .init(
      method: "thread/archive",
      description: "Archive one Codex thread.",
      takesParams: true,
      risk: .workspaceWrite
    ),
    .init(
      method: "thread/unarchive",
      description: "Unarchive one Codex thread.",
      takesParams: true,
      risk: .workspaceWrite
    ),
    .init(
      method: "thread/unsubscribe",
      description: "Unsubscribe the App Server connection from one thread.",
      takesParams: true,
      risk: .workspaceWrite
    ),
    .init(
      method: "turn/start",
      description: "Start a turn in a Codex thread with gateway-owned policy.",
      takesParams: true,
      risk: .workspaceWrite
    ),
    .init(
      method: "turn/steer",
      description: "Steer an active Codex turn.",
      takesParams: true,
      risk: .workspaceWrite
    ),
    .init(
      method: "turn/interrupt",
      description: "Interrupt an active Codex turn.",
      takesParams: true,
      risk: .workspaceWrite
    ),
    .init(
      method: "review/start",
      description: "Start a Codex review for a thread.",
      takesParams: true,
      risk: .workspaceWrite
    ),
  ]

  static func method(named name: String) -> CodexAppServerMethod? {
    methods.first { $0.method == name }
  }
}

protocol CodexAppServerRuntimeProtocol: Sendable {
  func status() async -> JSONValue
  func call(method: String, params: JSONValue?) async throws -> JSONValue
  func events(afterCursor: Int, maxResults: Int) async -> JSONValue
  func pendingRequests() async -> JSONValue
  func respond(requestID: String, response: JSONValue) async throws -> JSONValue
  func shutdown() async
}

extension CodexAppServerRuntimeProtocol {
  func shutdown() async {}
}

actor LiveCodexAppServerRuntime: CodexAppServerRuntimeProtocol {
  private typealias Stable = CodexAppServerProtocol.Stable
  private typealias UserInputRequestHandle = CodexAppServerServerRequestHandle<
    Stable.ToolRequestUserInputParams,
    Stable.ToolRequestUserInputResponse
  >

  private struct PendingUserInputRequest: Sendable {
    let handle: UserInputRequestHandle
    let payload: JSONValue
  }

  private enum TimedRequestResult<Value: Sendable>: Sendable {
    case value(Value)
    case timedOut
  }

  struct RequestTimeoutError: Error, LocalizedError, Sendable {
    let seconds: Int

    var errorDescription: String? {
      "Codex App Server request exceeded the \(seconds)-second deadline."
    }
  }

  private let configuration: CodexConfig
  private let workspaceURL: URL
  private let outputBounds: CodexOutputBounds
  private let eventBuffer: CodexEventBuffer
  private var connection: CodexAppServerConnection?
  private var notificationTask: Task<Void, Never>?
  private var requestTask: Task<Void, Never>?
  private var pendingUserInputRequests: [String: PendingUserInputRequest] = [:]
  private var workspaceScopedThreadIDs: Set<String> = []
  private var connectionState = "idle"
  private var lastError: String?

  init(
    configuration: CodexConfig,
    workspaceURL: URL,
    maxOutputBytes: Int = 1_048_576
  ) {
    self.configuration = configuration
    self.workspaceURL = workspaceURL.standardizedFileURL
    self.outputBounds = CodexOutputBounds(maxOutputBytes: maxOutputBytes)
    self.eventBuffer = CodexEventBuffer(
      capacity: configuration.maxEventsPerSession,
      maxOutputBytes: maxOutputBytes
    )
  }

  func status() async -> JSONValue {
    .object([
      "state": .string(connectionState),
      "experimental_api": .bool(configuration.experimentalAPI),
      "workspace": .string(workspaceURL.path),
      "last_error": lastError.map(JSONValue.string) ?? .null,
      "pending_user_input_requests": .number(Double(pendingUserInputRequests.count)),
    ])
  }

  func call(method: String, params: JSONValue?) async throws -> JSONValue {
    guard let descriptor = CodexAppServerMethodCatalog.method(named: method) else {
      throw GatewayToolError.disabled(
        "codex.app.method_not_allowed: App Server method '\(method)' is not in the reviewed allowlist."
      )
    }
    let normalized = try normalize(params: params, for: descriptor)
    let response: JSONValue
    do {
      response = try await Self.withRequestRetry(risk: descriptor.risk) { _ in
        let connection = try await self.ensureConnection()
        try await self.validateWorkspaceScope(
          method: method,
          params: normalized,
          connection: connection
        )
        return try await Self.boundedRequest(
          timeoutSeconds: self.configuration.appServerRequestTimeoutSeconds,
          onTimeout: {
            await self.closeTimedOutConnection(connection)
          },
          operation: {
            try await Self.sendReviewedRequest(
              method: method,
              params: normalized,
              connection: connection
            )
          }
        )
      }
    } catch {
      throw GatewayToolError.executionFailed(
        "codex.app.request_failed: \(Self.errorDescription(error))"
      )
    }
    try rememberWorkspaceScopedThreads(
      method: method,
      response: response
    )
    return outputBounds.json(response)
  }

  static func withRequestRetry<Value: Sendable>(
    risk: CapabilityRisk,
    operation: @escaping @Sendable (_ attempt: Int) async throws -> Value
  ) async throws -> Value {
    let maximumAttempts = risk == .readOnly ? 2 : 1
    var attempt = 0
    while true {
      do {
        return try await operation(attempt)
      } catch {
        guard
          shouldRetryRequest(
            error,
            risk: risk,
            attempt: attempt,
            maximumAttempts: maximumAttempts
          )
        else {
          throw error
        }
        attempt += 1
      }
    }
  }

  static func shouldRetryRequest(
    _ error: any Error,
    risk: CapabilityRisk,
    attempt: Int,
    maximumAttempts: Int
  ) -> Bool {
    risk == .readOnly
      && error is RequestTimeoutError
      && attempt + 1 < maximumAttempts
  }

  func events(afterCursor: Int, maxResults: Int) async -> JSONValue {
    await eventBuffer.read(afterCursor: afterCursor, maxResults: maxResults)
  }

  func pendingRequests() async -> JSONValue {
    let requests =
      pendingUserInputRequests
      .sorted { $0.key < $1.key }
      .map { id, request -> JSONValue in
        return .object([
          "request_id": .string(id),
          "request": request.payload,
          "kind": .string("user_input"),
        ])
      }
    return outputBounds.json(.object(["requests": .array(requests)]))
  }

  func respond(requestID: String, response: JSONValue) async throws -> JSONValue {
    guard let request = pendingUserInputRequests.removeValue(forKey: requestID) else {
      throw GatewayToolError.invalidArguments(
        "codex.app.request_unknown: Unknown or already resolved App Server request '\(requestID)'."
      )
    }
    let connection = try await ensureConnection()
    do {
      try await connection.resolveServerRequest(
        request.handle,
        with: try Self.decodeUserInputResponse(response)
      )
    } catch {
      pendingUserInputRequests[requestID] = request
      throw error
    }
    await eventBuffer.append(
      kind: "server_request_resolved",
      payload: .object(["request_id": .string(requestID)])
    )
    return .object(["resolved": .bool(true), "request_id": .string(requestID)])
  }

  func shutdown() async {
    notificationTask?.cancel()
    requestTask?.cancel()
    notificationTask = nil
    requestTask = nil
    let activeConnection = connection
    connection = nil
    pendingUserInputRequests.removeAll()
    workspaceScopedThreadIDs.removeAll()
    connectionState = "stopped"
    lastError = nil
    await activeConnection?.close()
  }

  private func ensureConnection() async throws -> CodexAppServerConnection {
    if let connection {
      return connection
    }
    connectionState = "starting"
    lastError = nil
    do {
      let stdioConfiguration = CodexAppServerStdioConfiguration(
        executableURL: configuration.executableURL,
        executableName: configuration.executableURL == nil ? configuration.executable : "codex",
        environment: CodexProcessEnvironment.resolved(),
        workingDirectoryURL: workspaceURL
      )
      let client = CodexAppServerClient(
        sessionConfiguration: .init(
          clientInfo: .init(
            name: "computer_mcp",
            title: "Computer MCP",
            version: ComputerMCPCLI.version
          ),
          experimentalApi: configuration.experimentalAPI,
          optOutNotificationMethods: [
            "remoteControl/status/changed"
          ]
        ),
        transportFactory: {
          try CodexAppServerStdioTransport(configuration: stdioConfiguration)
        }
      )
      let started = try await client.start()
      connection = started
      connectionState = "running"
      startConsumers(connection: started)
      await eventBuffer.append(
        kind: "connection_started",
        payload: .object(["experimental_api": .bool(configuration.experimentalAPI)])
      )
      return started
    } catch {
      connectionState = "failed"
      lastError = error.localizedDescription
      await eventBuffer.append(
        kind: "connection_failed",
        payload: .object(["message": .string(error.localizedDescription)])
      )
      throw GatewayToolError.executionFailed(
        "codex.app.start_failed: \(error.localizedDescription)"
      )
    }
  }

  private func startConsumers(connection: CodexAppServerConnection) {
    notificationTask?.cancel()
    requestTask?.cancel()
    notificationTask = Task { [weak self, connection] in
      do {
        for try await notification in connection.notifications {
          guard let self else { return }
          await self.recordNotification(notification)
        }
        await self?.connectionEnded(connection, message: nil)
      } catch {
        await self?.connectionEnded(connection, message: error.localizedDescription)
      }
    }
    requestTask = Task { [weak self, connection] in
      do {
        for try await request in connection.typedServerRequests {
          guard let self else { return }
          await self.handleServerRequest(request, connection: connection)
        }
      } catch {
        await self?.recordConsumerFailure(
          kind: "server_request_stream_failed",
          message: error.localizedDescription
        )
      }
    }
  }

  private func recordNotification(
    _ notification: CodexAppServerProtocol.Stable.ServerNotification
  ) async {
    let payload = (try? JSONValue.encoded(notification)) ?? .null
    await eventBuffer.append(kind: "notification", payload: payload)
  }

  private func handleServerRequest(
    _ request: CodexAppServerTypedServerRequest,
    connection: CodexAppServerConnection
  ) async {
    let id = Self.requestIDString(request.id)
    switch request {
    case .toolRequestUserInput(let handle):
      let payload = Self.serverRequestPayload(
        method: "item/tool/requestUserInput",
        params: handle.params
      )
      pendingUserInputRequests[id] = .init(handle: handle, payload: payload)
      await eventBuffer.append(
        kind: "user_input_requested",
        payload: .object(["request_id": .string(id), "request": payload])
      )
    case .commandExecutionApproval(let handle):
      await rejectServerRequest(
        handle, method: "item/commandExecution/requestApproval", connection: connection)
    case .fileChangeApproval(let handle):
      await rejectServerRequest(
        handle, method: "item/fileChange/requestApproval", connection: connection)
    case .mcpServerElicitation(let handle):
      await rejectServerRequest(
        handle, method: "mcpServer/elicitation/request", connection: connection)
    case .permissionsApproval(let handle):
      await rejectServerRequest(
        handle, method: "item/permissions/requestApproval", connection: connection)
    case .dynamicToolCall(let handle):
      await rejectServerRequest(handle, method: "item/tool/call", connection: connection)
    case .chatgptAuthTokensRefresh(let handle):
      await rejectServerRequest(
        handle, method: "account/chatgptAuthTokens/refresh", connection: connection)
    case .applyPatchApproval(let handle):
      await rejectServerRequest(handle, method: "applyPatchApproval", connection: connection)
    case .execCommandApproval(let handle):
      await rejectServerRequest(handle, method: "execCommandApproval", connection: connection)
    case .attestationGenerate(let handle):
      await rejectServerRequest(handle, method: "attestation/generate", connection: connection)
    }
  }

  private func rejectServerRequest<Params: Encodable & Sendable, Response: Encodable & Sendable>(
    _ handle: CodexAppServerServerRequestHandle<Params, Response>,
    method: String,
    connection: CodexAppServerConnection
  ) async {
    let id = Self.requestIDString(handle.id)
    let payload = Self.serverRequestPayload(method: method, params: handle.params)
    do {
      try await connection.rejectServerRequest(
        handle,
        code: -32_001,
        message:
          "Computer MCP does not permit App Server requests to expand permissions, refresh credentials, or invoke unregistered tools."
      )
      await eventBuffer.append(
        kind: "server_request_denied",
        payload: .object(["request_id": .string(id), "request": payload])
      )
    } catch {
      await recordConsumerFailure(
        kind: "server_request_rejection_failed",
        message: error.localizedDescription
      )
    }
  }

  private func connectionEnded(
    _ endedConnection: CodexAppServerConnection,
    message: String?
  ) async {
    guard connection === endedConnection else {
      return
    }
    connection = nil
    pendingUserInputRequests.removeAll()
    workspaceScopedThreadIDs.removeAll()
    connectionState = message == nil ? "stopped" : "failed"
    lastError = message
    await eventBuffer.append(
      kind: "connection_ended",
      payload: .object(["message": message.map(JSONValue.string) ?? .null])
    )
  }

  private func closeTimedOutConnection(
    _ timedOutConnection: CodexAppServerConnection
  ) async {
    await timedOutConnection.close()
    await connectionEnded(
      timedOutConnection,
      message: "App Server request deadline exceeded."
    )
  }

  static func boundedRequest<Value: Sendable>(
    timeoutSeconds: Int,
    onTimeout: @escaping @Sendable () async -> Void,
    operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    try await withThrowingTaskGroup(of: TimedRequestResult<Value>.self) { group in
      group.addTask {
        .value(try await operation())
      }
      group.addTask {
        try await Task.sleep(for: .seconds(timeoutSeconds))
        return .timedOut
      }
      guard let first = try await group.next() else {
        throw RequestTimeoutError(seconds: timeoutSeconds)
      }
      switch first {
      case .value(let value):
        group.cancelAll()
        return value
      case .timedOut:
        await onTimeout()
        group.cancelAll()
        throw RequestTimeoutError(seconds: timeoutSeconds)
      }
    }
  }

  private func recordConsumerFailure(kind: String, message: String) async {
    await eventBuffer.append(
      kind: kind,
      payload: .object(["message": .string(message)])
    )
  }

  func normalize(
    params: JSONValue?,
    for method: CodexAppServerMethod
  ) throws -> JSONValue? {
    guard method.takesParams else {
      return nil
    }
    var object = params?.objectValue ?? [:]
    try Self.rejectUnsafeOverrides(object)
    if let suppliedCWD = object["cwd"]?.stringValue,
      URL(fileURLWithPath: suppliedCWD).standardizedFileURL != workspaceURL
    {
      throw GatewayToolError.invalidArguments(
        "[codex.app.workspace_override_denied] cwd must match the bound workspace."
      )
    }

    switch method.method {
    case "thread/list":
      object["cwd"] = .string(workspaceURL.path)
    case "skills/list":
      object["cwds"] = .array([.string(workspaceURL.path)])
      object.removeValue(forKey: "perCwdExtraUserRoots")
    case "thread/start", "thread/resume", "thread/fork":
      object["cwd"] = .string(workspaceURL.path)
      object["approvalPolicy"] = .string(configuration.approvalPolicy.rawValue)
      object["sandbox"] = .string(configuration.sandbox.rawValue)
    case "turn/start":
      object["cwd"] = .string(workspaceURL.path)
      object["approvalPolicy"] = .string(configuration.approvalPolicy.rawValue)
      object["sandboxPolicy"] = Self.sandboxPolicy(configuration.sandbox)
    default:
      break
    }
    return .object(object)
  }

  private func validateWorkspaceScope(
    method: String,
    params: JSONValue?,
    connection: CodexAppServerConnection
  ) async throws {
    guard let threadID = try Self.workspaceScopedThreadID(method: method, params: params) else {
      return
    }
    if workspaceScopedThreadIDs.contains(threadID) {
      return
    }

    let response: JSONValue
    do {
      response = try Self.gatewayJSON(
        try await connection.threadRead(
          try Self.decodeStableParams(
            Stable.ThreadReadParams.self,
            from: .object([
              "threadId": .string(threadID),
              "includeTurns": .bool(false),
            ])
          )
        )
      )
    } catch {
      throw GatewayToolError.executionFailed(
        "codex.app.thread_scope_lookup_failed: \(Self.errorDescription(error))"
      )
    }
    try Self.validateThreadWorkspace(
      threadID: threadID,
      response: response,
      workspaceURL: workspaceURL
    )
    workspaceScopedThreadIDs.insert(threadID)
  }

  private func rememberWorkspaceScopedThreads(
    method: String,
    response: JSONValue
  ) throws {
    if ["thread/start", "thread/resume", "thread/fork"].contains(method) {
      let threadID = try Self.createdWorkspaceScopedThreadID(
        response: response,
        workspaceURL: workspaceURL
      )
      workspaceScopedThreadIDs.insert(threadID)
    }

    if method == "review/start",
      let reviewThreadID = response.objectValue?["reviewThreadId"]?.stringValue,
      !reviewThreadID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      workspaceScopedThreadIDs.insert(reviewThreadID)
    }
  }

  static func createdWorkspaceScopedThreadID(
    response: JSONValue,
    workspaceURL: URL
  ) throws -> String {
    guard let thread = response.objectValue?["thread"]?.objectValue,
      let threadID = thread["id"]?.stringValue,
      !threadID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let cwd = thread["cwd"]?.stringValue
    else {
      throw GatewayToolError.executionFailed(
        "codex.app.thread_scope_unknown: App Server did not return id and cwd for the created thread."
      )
    }
    guard Self.contains(URL(fileURLWithPath: cwd), in: workspaceURL) else {
      throw GatewayToolError.disabled(
        "codex.app.thread_outside_workspace: Created thread '\(threadID)' belongs to a different workspace."
      )
    }
    return threadID
  }

  static func workspaceScopedThreadID(
    method: String,
    params: JSONValue?
  ) throws -> String? {
    guard threadScopedMethods.contains(method) else {
      return nil
    }
    guard let threadID = params?.objectValue?["threadId"]?.stringValue,
      !threadID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw GatewayToolError.invalidArguments(
        "codex.app.thread_id_required: method '\(method)' requires a non-empty threadId."
      )
    }
    return threadID
  }

  static func validateThreadWorkspace(
    threadID: String,
    response: JSONValue,
    workspaceURL: URL
  ) throws {
    guard let cwd = response.objectValue?["thread"]?.objectValue?["cwd"]?.stringValue else {
      throw GatewayToolError.executionFailed(
        "codex.app.thread_scope_unknown: App Server did not return cwd for thread '\(threadID)'."
      )
    }
    guard Self.contains(URL(fileURLWithPath: cwd), in: workspaceURL) else {
      throw GatewayToolError.disabled(
        "codex.app.thread_outside_workspace: Thread '\(threadID)' belongs to a different workspace."
      )
    }
  }

  private static func rejectUnsafeOverrides(_ object: [String: JSONValue]) throws {
    let deniedKeys: Set<String> = [
      "config",
      "configOverrides",
      "dangerouslyBypassApprovalsAndSandbox",
      "baseInstructions",
      "developerInstructions",
    ]
    if let key = object.keys.first(where: deniedKeys.contains) {
      throw GatewayToolError.invalidArguments(
        "[codex.app.override_denied] '\(key)' is controlled by the local gateway."
      )
    }
    if containsDangerFullAccess(.object(object)) {
      throw GatewayToolError.invalidArguments(
        "[codex.app.danger_full_access_denied] danger-full-access is never accepted."
      )
    }
  }

  private static func containsDangerFullAccess(_ value: JSONValue) -> Bool {
    switch value {
    case .string(let string):
      return string == "danger-full-access" || string == "dangerFullAccess"
    case .array(let values):
      return values.contains(where: containsDangerFullAccess)
    case .object(let object):
      return object.values.contains(where: containsDangerFullAccess)
    case .number, .bool, .null:
      return false
    }
  }

  static func contains(_ candidate: URL, in root: URL) -> Bool {
    let resolvedCandidate = candidate.standardizedFileURL.resolvingSymlinksInPath()
    let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
    return resolvedCandidate == resolvedRoot
      || resolvedCandidate.path.hasPrefix(resolvedRoot.path + "/")
  }

  private static let threadScopedMethods: Set<String> = [
    "review/start",
    "thread/archive",
    "thread/compact/start",
    "thread/fork",
    "thread/inject_items",
    "thread/metadata/update",
    "thread/name/set",
    "thread/read",
    "thread/resume",
    "thread/rollback",
    "thread/unarchive",
    "thread/unsubscribe",
    "turn/interrupt",
    "turn/start",
    "turn/steer",
  ]

  private static func sandboxPolicy(_ mode: CodexSandboxMode) -> JSONValue {
    switch mode {
    case .readOnly:
      return .object([
        "type": .string("readOnly"),
        "networkAccess": .bool(false),
      ])
    case .workspaceWrite:
      return .object([
        "type": .string("workspaceWrite"),
        "networkAccess": .bool(false),
      ])
    case .dangerFullAccess:
      preconditionFailure("danger-full-access is rejected during configuration validation")
    }
  }

  private static func stableJSON(
    _ value: JSONValue
  ) throws -> CodexAppServerProtocol.Stable.JSONValue {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(
      CodexAppServerProtocol.Stable.JSONValue.self,
      from: data
    )
  }

  private static func decodeUserInputResponse(
    _ value: JSONValue
  ) throws -> Stable.ToolRequestUserInputResponse {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(Stable.ToolRequestUserInputResponse.self, from: data)
  }

  private static func serverRequestPayload<Params: Encodable>(
    method: String,
    params: Params
  ) -> JSONValue {
    .object([
      "method": .string(method),
      "params": (try? JSONValue.encoded(params)) ?? .null,
    ])
  }

  private static func gatewayJSON<Value: Encodable>(_ value: Value) throws -> JSONValue {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(JSONValue.self, from: data)
  }

  private static func decodeStableParams<Params: Decodable>(
    _ type: Params.Type,
    from value: JSONValue?
  ) throws -> Params {
    let data = try JSONEncoder().encode(value ?? .object([:]))
    return try JSONDecoder().decode(type, from: data)
  }

  private static func sendReviewedRequest(
    method: String,
    params: JSONValue?,
    connection: CodexAppServerConnection
  ) async throws -> JSONValue {
    switch method {
    case "account/rateLimits/read":
      return try gatewayJSON(try await connection.accountRateLimitsRead())
    case "account/read":
      return try gatewayJSON(
        try await connection.accountRead(
          try decodeStableParams(Stable.GetAccountParams.self, from: params)
        )
      )
    case "account/usage/read":
      return try gatewayJSON(try await connection.accountUsageRead())
    case "app/list":
      return try gatewayJSON(
        try await connection.appList(
          try decodeStableParams(Stable.AppsListParams.self, from: params)
        )
      )
    case "experimentalFeature/list":
      return try gatewayJSON(
        try await connection.experimentalFeatureList(
          try decodeStableParams(Stable.ExperimentalFeatureListParams.self, from: params)
        )
      )
    case "model/list":
      return try gatewayJSON(
        try await connection.modelList(
          try decodeStableParams(Stable.ModelListParams.self, from: params)
        )
      )
    case "plugin/list":
      return try gatewayJSON(
        try await connection.pluginList(
          try decodeStableParams(Stable.PluginListParams.self, from: params)
        )
      )
    case "plugin/read":
      return try gatewayJSON(
        try await connection.pluginRead(
          try decodeStableParams(Stable.PluginReadParams.self, from: params)
        )
      )
    case "skills/list":
      return try gatewayJSON(
        try await connection.skillsList(
          try decodeStableParams(Stable.SkillsListParams.self, from: params)
        )
      )
    case "thread/list":
      return try gatewayJSON(
        try await connection.threadList(
          try decodeStableParams(Stable.ThreadListParams.self, from: params)
        )
      )
    case "thread/read":
      return try gatewayJSON(
        try await connection.threadRead(
          try decodeStableParams(Stable.ThreadReadParams.self, from: params)
        )
      )
    case "thread/start":
      return try gatewayJSON(
        try await connection.threadStart(
          try decodeStableParams(Stable.ThreadStartParams.self, from: params)
        )
      )
    case "thread/resume":
      return try gatewayJSON(
        try await connection.threadResume(
          try decodeStableParams(Stable.ThreadResumeParams.self, from: params)
        )
      )
    case "thread/fork":
      return try gatewayJSON(
        try await connection.threadFork(
          try decodeStableParams(Stable.ThreadForkParams.self, from: params)
        )
      )
    case "thread/compact/start":
      return try gatewayJSON(
        try await connection.threadCompactStart(
          try decodeStableParams(Stable.ThreadCompactStartParams.self, from: params)
        )
      )
    case "thread/inject_items":
      return try gatewayJSON(
        try await connection.threadInjectItems(
          try decodeStableParams(Stable.ThreadInjectItemsParams.self, from: params)
        )
      )
    case "thread/metadata/update":
      return try gatewayJSON(
        try await connection.threadMetadataUpdate(
          try decodeStableParams(Stable.ThreadMetadataUpdateParams.self, from: params)
        )
      )
    case "thread/name/set":
      return try gatewayJSON(
        try await connection.threadNameSet(
          try decodeStableParams(Stable.ThreadSetNameParams.self, from: params)
        )
      )
    case "thread/rollback":
      return try gatewayJSON(
        try await connection.threadRollback(
          try decodeStableParams(Stable.ThreadRollbackParams.self, from: params)
        )
      )
    case "thread/archive":
      return try gatewayJSON(
        try await connection.threadArchive(
          try decodeStableParams(Stable.ThreadArchiveParams.self, from: params)
        )
      )
    case "thread/unarchive":
      return try gatewayJSON(
        try await connection.threadUnarchive(
          try decodeStableParams(Stable.ThreadUnarchiveParams.self, from: params)
        )
      )
    case "thread/unsubscribe":
      return try gatewayJSON(
        try await connection.threadUnsubscribe(
          try decodeStableParams(Stable.ThreadUnsubscribeParams.self, from: params)
        )
      )
    case "turn/start":
      return try gatewayJSON(
        try await connection.turnStart(
          try decodeStableParams(Stable.TurnStartParams.self, from: params)
        )
      )
    case "turn/steer":
      return try gatewayJSON(
        try await connection.turnSteer(
          try decodeStableParams(Stable.TurnSteerParams.self, from: params)
        )
      )
    case "turn/interrupt":
      return try gatewayJSON(
        try await connection.turnInterrupt(
          try decodeStableParams(Stable.TurnInterruptParams.self, from: params)
        )
      )
    case "review/start":
      return try gatewayJSON(
        try await connection.reviewStart(
          try decodeStableParams(Stable.ReviewStartParams.self, from: params)
        )
      )
    default:
      throw GatewayToolError.disabled(
        "codex.app.typed_method_unavailable: App Server method '\(method)' has no reviewed swift-codex binding."
      )
    }
  }

  private static func requestIDString(
    _ id: CodexAppServerProtocol.Stable.RequestId
  ) -> String {
    switch id {
    case .requestidoption1(let value):
      return "s:\(value)"
    case .requestidoption2(let value):
      return "n:\(value)"
    }
  }

  private static func errorDescription(_ error: Error) -> String {
    guard let error = error as? CodexAppServerClientError else {
      return error.localizedDescription
    }
    switch error {
    case .closed:
      return "The App Server connection is closed."
    case .peerClosed:
      return "The App Server process closed its protocol stream."
    case .requestCancelled:
      return "The App Server request was cancelled."
    case .malformedInbound(let message):
      return "Malformed inbound App Server message: \(message)"
    case .malformedOutbound(let message):
      return "Malformed outbound App Server message: \(message)"
    case .invalidRawMethod(let method):
      return "Invalid raw App Server method: \(method)"
    case .rawMethodNotAllowed(let method):
      return "Raw App Server method is denied by swift-codex: \(method)"
    case .jsonRPCError(let code, let message, _):
      return "App Server JSON-RPC error \(code): \(message)"
    case .unmatchedResponse(let id):
      return "App Server returned an unmatched response id: \(id)"
    case .duplicateServerRequest(let id):
      return "App Server returned a duplicate server request id: \(id)"
    case .serverRequestAlreadyCompleted(let id):
      return "App Server request was already completed: \(id)"
    case .responseDecodeFailure(let message):
      return "App Server response decode failed: \(message)"
    }
  }
}
