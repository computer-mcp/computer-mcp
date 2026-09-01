import CodexAppServerClient
import CodexAppServerProtocol
import CryptoKit
import Foundation

struct CodexAppServerMethod: Equatable, Sendable {
  let method: String
  let description: String
  let takesParams: Bool
  let risk: CapabilityRisk
}

struct CodexRuntimeOwner: Codable, Equatable, Sendable {
  let workspaceID: String?
  let profileID: String?
  let caller: String?
  let transport: String?
  let socketConnectionID: String?
  let tunnelInstanceID: String?
  let tunnelProfileID: String?

  private enum CodingKeys: String, CodingKey {
    case workspaceID = "workspace_id"
    case profileID = "profile_id"
    case caller
    case transport
    case socketConnectionID = "socket_connection_id"
    case tunnelInstanceID = "tunnel_instance_id"
    case tunnelProfileID = "tunnel_profile_id"
  }
}

private final class WeakCodexRuntimeBox: @unchecked Sendable {
  weak var runtime: LiveCodexAppServerRuntime?

  init(_ runtime: LiveCodexAppServerRuntime) {
    self.runtime = runtime
  }
}

final class CodexRuntimeDirectory: @unchecked Sendable {
  static let shared = CodexRuntimeDirectory()

  private let lock = NSLock()
  private var entries: [String: WeakCodexRuntimeBox] = [:]

  private init() {}

  func register(_ runtime: LiveCodexAppServerRuntime, id: String) {
    lock.withLock {
      entries[id] = WeakCodexRuntimeBox(runtime)
      pruneLocked()
    }
  }

  func unregister(id: String) {
    lock.withLock {
      _ = entries.removeValue(forKey: id)
    }
  }

  func runtime(id: String, workspaceID: String? = nil) -> LiveCodexAppServerRuntime? {
    lock.withLock {
      defer { pruneLocked() }
      guard let runtime = entries[id]?.runtime else { return nil }
      guard workspaceID == nil || runtime.owner?.workspaceID == workspaceID else { return nil }
      return runtime
    }
  }

  func statuses(workspaceID: String? = nil) async -> JSONValue {
    let runtimes = lock.withLock { () -> [LiveCodexAppServerRuntime] in
      pruneLocked()
      return entries.values.compactMap(\.runtime).filter {
        workspaceID == nil || $0.owner?.workspaceID == workspaceID
      }
    }
    var statuses: [JSONValue] = []
    for runtime in runtimes {
      statuses.append(await runtime.status())
    }
    statuses.sort {
      ($0.objectValue?["runtime_id"]?.stringValue ?? "")
        < ($1.objectValue?["runtime_id"]?.stringValue ?? "")
    }
    return .object(["runtimes": .array(statuses)])
  }

  private func pruneLocked() {
    entries = entries.filter { $0.value.runtime != nil }
  }
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
      method: "thread/loaded/list",
      description: "List thread IDs currently loaded by this App Server runtime.",
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
      method: "thread/goal/get",
      description: "Read the official persisted Codex Goal for one thread.",
      takesParams: true,
      risk: .readOnly
    ),
    .init(
      method: "thread/goal/set",
      description: "Create or update the official persisted Codex Goal for one thread.",
      takesParams: true,
      risk: .workspaceWrite
    ),
    .init(
      method: "thread/goal/clear",
      description: "Clear the official persisted Codex Goal for one thread.",
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
  func approvals(state: String?, limit: Int) async throws -> JSONValue
  func approval(id: String) async throws -> JSONValue
  func respondToApproval(id: String, decision: String) async throws -> JSONValue
  func shutdown() async
}

extension CodexAppServerRuntimeProtocol {
  func approvals(state: String?, limit: Int) async throws -> JSONValue {
    .object(["approvals": .array([])])
  }

  func approval(id: String) async throws -> JSONValue {
    throw CodexApprovalBrokerError.unknown(id)
  }

  func respondToApproval(id: String, decision: String) async throws -> JSONValue {
    throw CodexApprovalBrokerError.unknown(id)
  }

  func shutdown() async {}
}

private final class CodexTimedRequestCompletion<Value: Sendable>: @unchecked Sendable {
  enum Participant {
    case operation
    case timeout
    case cancellation
  }

  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, any Error>?
  private var operationTask: Task<Void, Never>?
  private var timeoutTask: Task<Void, Never>?
  private var resolved = false

  func install(_ continuation: CheckedContinuation<Value, any Error>) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !resolved else {
      return false
    }
    self.continuation = continuation
    return true
  }

  func installTasks(
    operation: Task<Void, Never>,
    timeout: Task<Void, Never>
  ) {
    lock.lock()
    operationTask = operation
    timeoutTask = timeout
    let shouldCancel = resolved
    lock.unlock()
    if shouldCancel {
      operation.cancel()
      timeout.cancel()
    }
  }

  func claim(_ participant: Participant) -> CheckedContinuation<Value, any Error>? {
    lock.lock()
    guard !resolved else {
      lock.unlock()
      return nil
    }
    resolved = true
    let continuation = continuation
    self.continuation = nil
    let operationTask = operationTask
    let timeoutTask = timeoutTask
    lock.unlock()

    switch participant {
    case .operation:
      timeoutTask?.cancel()
    case .timeout:
      operationTask?.cancel()
    case .cancellation:
      operationTask?.cancel()
      timeoutTask?.cancel()
    }
    return continuation
  }

  func resumeOperation(with result: Result<Value, any Error>) {
    claim(.operation)?.resume(with: result)
  }

  func cancel() {
    claim(.cancellation)?.resume(throwing: CancellationError())
  }
}

actor LiveCodexAppServerRuntime: CodexAppServerRuntimeProtocol {
  private typealias Stable = CodexAppServerProtocol.Stable
  private typealias UserInputRequestHandle = CodexAppServerServerRequestHandle<
    Stable.ToolRequestUserInputParams,
    Stable.ToolRequestUserInputResponse
  >

  private typealias ElicitationRequestHandle = CodexAppServerServerRequestHandle<
    Stable.McpServerElicitationRequestParams,
    Stable.McpServerElicitationRequestResponse
  >

  private enum PendingInteractiveRequestHandle: Sendable {
    case userInput(UserInputRequestHandle)
    case elicitation(ElicitationRequestHandle)

    var kind: String {
      switch self {
      case .userInput: "user_input"
      case .elicitation: "mcp_elicitation"
      }
    }
  }

  private struct PendingUserInputRequest: Sendable {
    let handle: PendingInteractiveRequestHandle
    let payload: JSONValue
  }

  private enum PendingApprovalHandle: Sendable {
    case command(
      CodexAppServerServerRequestHandle<
        Stable.CommandExecutionRequestApprovalParams,
        Stable.CommandExecutionRequestApprovalResponse
      >
    )
    case fileChange(
      CodexAppServerServerRequestHandle<
        Stable.FileChangeRequestApprovalParams,
        Stable.FileChangeRequestApprovalResponse
      >
    )
    case permissions(
      CodexAppServerServerRequestHandle<
        Stable.PermissionsRequestApprovalParams,
        Stable.PermissionsRequestApprovalResponse
      >
    )
    case applyPatch(
      CodexAppServerServerRequestHandle<
        Stable.ApplyPatchApprovalParams,
        Stable.ApplyPatchApprovalResponse
      >
    )
    case execCommand(
      CodexAppServerServerRequestHandle<
        Stable.ExecCommandApprovalParams,
        Stable.ExecCommandApprovalResponse
      >
    )
    case registeredTool(
      CodexAppServerServerRequestHandle<
        Stable.DynamicToolCallParams,
        Stable.DynamicToolCallResponse
      >
    )
  }

  private struct ConnectionStartup: Sendable {
    let id: UUID
    let transport: ManagedCodexAppServerTransport
    let task: Task<CodexAppServerConnection, Error>
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
  nonisolated let runtimeID = UUID().uuidString
  private let createdAt = Date()
  nonisolated let owner: CodexRuntimeOwner?
  private let database: GatewayDatabase?
  private let dynamicToolDispatcher: CodexDynamicToolDispatcher?
  private var connection: CodexAppServerConnection?
  private var processTransport: ManagedCodexAppServerTransport?
  private var connectionStartup: ConnectionStartup?
  private var lastProcessSnapshot: CodexAppServerProcessSnapshot?
  private var notificationTask: Task<Void, Never>?
  private var requestTask: Task<Void, Never>?
  private var pendingUserInputRequests: [String: PendingUserInputRequest] = [:]
  private var approvalRecords: [String: CodexApprovalRecord] = [:]
  private var pendingApprovalHandles: [String: PendingApprovalHandle] = [:]
  private var approvalTimeoutTasks: [String: Task<Void, Never>] = [:]
  private var workspaceScopedThreadIDs: Set<String> = []
  private var loadedThreadIDs: Set<String> = []
  private var subscribedThreadIDs: Set<String> = []
  private var threadStates: [String: JSONValue] = [:]
  private var activeTurnIDs: [String: String] = [:]
  private var connectionState = "idle"
  private var connectionID: String?
  private var connectionGeneration = 0
  private var shutdownReason: String?
  private var isShutdown = false
  private var lastError: String?

  init(
    configuration: CodexConfig,
    workspaceURL: URL,
    owner: CodexRuntimeOwner? = nil,
    database: GatewayDatabase? = nil,
    dynamicToolDispatcher: CodexDynamicToolDispatcher? = nil,
    maxOutputBytes: Int = 1_048_576
  ) {
    self.configuration = configuration
    self.workspaceURL = workspaceURL.standardizedFileURL
    self.owner = owner
    self.database = database
    self.dynamicToolDispatcher = dynamicToolDispatcher
    self.outputBounds = CodexOutputBounds(maxOutputBytes: maxOutputBytes)
    self.eventBuffer = CodexEventBuffer(
      capacity: configuration.maxEventsPerSession,
      maxOutputBytes: maxOutputBytes
    )
    for var record in (try? database?.codexApprovals(limit: 5_000)) ?? []
    where Self.isApprovalVisible(record, to: owner) {
      if record.state == .pending,
        CodexRuntimeDirectory.shared.runtime(id: record.runtimeID) == nil
      {
        record.state = .interrupted
        record.resolvedAt = Date()
        record.resolutionReason = "The owning runtime is no longer active."
        try? database?.saveCodexApproval(record)
      }
      approvalRecords[record.id] = record
    }
    CodexRuntimeDirectory.shared.register(self, id: runtimeID)
  }

  func status() async -> JSONValue {
    let processSnapshot =
      await (processTransport ?? connectionStartup?.transport)?.snapshot()
      ?? lastProcessSnapshot
    let pendingApprovals = approvalRecords.values.filter { $0.state == .pending }
    let pendingApprovalIDs = pendingApprovals.map(\.id).sorted().map(JSONValue.string)
    let threads = workspaceScopedThreadIDs.sorted().map { threadID -> JSONValue in
      let threadPendingApprovalIDs = pendingApprovals.filter {
        $0.threadID == threadID
      }.map(\.id).sorted().map(JSONValue.string)
      let fields: [String: JSONValue] = [
        "thread_id": .string(threadID),
        "loaded": .bool(loadedThreadIDs.contains(threadID)),
        "subscribed": .bool(subscribedThreadIDs.contains(threadID)),
        "state": threadStates[threadID] ?? .string("unknown"),
        "active_turn_id": activeTurnIDs[threadID].map(JSONValue.string) ?? .null,
        "pending_approval_ids": .array(threadPendingApprovalIDs),
      ]
      return .object(fields)
    }
    let fields: [String: JSONValue] = [
      "runtime_id": .string(runtimeID),
      "created_at": (try? JSONValue.encoded(createdAt)) ?? .null,
      "owner": owner.flatMap { try? JSONValue.encoded($0) } ?? .null,
      "state": .string(connectionState),
      "connection_id": connectionID.map(JSONValue.string) ?? .null,
      "connection_generation": .number(Double(connectionGeneration)),
      "experimental_api": .bool(configuration.experimentalAPI),
      "workspace": .string(workspaceURL.path),
      "last_error": lastError.map(JSONValue.string) ?? .null,
      "shutdown_reason": shutdownReason.map(JSONValue.string) ?? .null,
      "pending_user_input_requests": .number(Double(pendingUserInputRequests.count)),
      "pending_approvals": .number(Double(pendingApprovals.count)),
      "pending_approval_ids": .array(pendingApprovalIDs),
      "threads": .array(threads),
      "process": processSnapshot?.json ?? .null,
    ]
    return .object(fields)
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
            await self.retireTimedOutConnection(connection)
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
      params: normalized,
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
          "kind": .string(request.handle.kind),
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
      switch request.handle {
      case .userInput(let handle):
        try await connection.resolveServerRequest(
          handle,
          with: try Self.decodeUserInputResponse(response)
        )
      case .elicitation(let handle):
        try await connection.resolveServerRequest(
          handle,
          with: try Self.decodeElicitationResponse(response)
        )
      }
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

  func approvals(state: String?, limit: Int) async throws -> JSONValue {
    try await reconcileApprovalRecords()
    let requestedState: CodexApprovalState?
    if let state {
      guard let parsed = CodexApprovalState(rawValue: state) else {
        throw GatewayToolError.invalidArguments(
          "codex.app.approval_state_invalid: Unknown approval state '\(state)'."
        )
      }
      requestedState = parsed
    } else {
      requestedState = nil
    }
    let records = approvalRecords.values
      .filter { requestedState == nil || $0.state == requestedState }
      .sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
      .prefix(max(1, min(limit, 1_000)))
      .map(\.json)
    return outputBounds.json(.object(["approvals": .array(records)]))
  }

  func approval(id: String) async throws -> JSONValue {
    try await reconcileApprovalRecords()
    let storedRecord: CodexApprovalRecord?
    if let cached = approvalRecords[id] {
      storedRecord = cached
    } else {
      storedRecord = try database?.codexApproval(id: id)
    }
    guard let record = storedRecord, Self.isApprovalVisible(record, to: owner) else {
      throw GatewayToolError.invalidArguments(
        "codex.app.approval_unknown: Unknown Codex approval '\(id)'."
      )
    }
    return outputBounds.json(.object(["approval": record.json]))
  }

  func respondToApproval(id: String, decision: String) async throws -> JSONValue {
    guard let parsedDecision = CodexApprovalDecision(rawValue: decision) else {
      throw GatewayToolError.invalidArguments(
        "codex.app.approval_decision_invalid: Use approve_once, approve_session, or deny."
      )
    }
    do {
      try await reconcileApprovalRecords()
      let storedRecord: CodexApprovalRecord?
      if let cached = approvalRecords[id] {
        storedRecord = cached
      } else {
        storedRecord = try database?.codexApproval(id: id)
      }
      guard let storedRecord, Self.isApprovalVisible(storedRecord, to: owner) else {
        throw CodexApprovalBrokerError.unknown(id)
      }
      if storedRecord.runtimeID != runtimeID,
        let owningRuntime = CodexRuntimeDirectory.shared.runtime(id: storedRecord.runtimeID)
      {
        return try await owningRuntime.respondToApproval(id: id, decision: decision)
      }
      let resolvedRecord = try await resolveApproval(id: id, decision: parsedDecision)
      return .object(["approval": resolvedRecord.json])
    } catch let error as CodexApprovalBrokerError {
      throw GatewayToolError.invalidArguments(
        "codex.app.approval_response_invalid: \(Self.errorDescription(error))"
      )
    }
  }

  func shutdown() async {
    if isShutdown {
      return
    }
    isShutdown = true
    shutdownReason = "requested"
    notificationTask?.cancel()
    requestTask?.cancel()
    notificationTask = nil
    requestTask = nil
    let activeConnection = connection
    let activeTransport = processTransport
    let startup = connectionStartup
    if let activeConnection {
      await releaseAllThreads(connection: activeConnection)
      await interruptPendingApprovals(connection: activeConnection, reason: "Runtime stopped.")
    }
    connection = nil
    connectionID = nil
    processTransport = nil
    connectionStartup = nil
    pendingUserInputRequests.removeAll()
    for task in approvalTimeoutTasks.values {
      task.cancel()
    }
    approvalTimeoutTasks.removeAll()
    pendingApprovalHandles.removeAll()
    workspaceScopedThreadIDs.removeAll()
    loadedThreadIDs.removeAll()
    subscribedThreadIDs.removeAll()
    threadStates.removeAll()
    activeTurnIDs.removeAll()
    connectionState = "stopped"
    lastError = nil
    startup?.task.cancel()
    await startup?.transport.close()
    await activeConnection?.close()
    await activeTransport?.close()
    if let startup {
      _ = try? await startup.task.value
      lastProcessSnapshot = await startup.transport.snapshot()
    } else if let activeTransport {
      lastProcessSnapshot = await activeTransport.snapshot()
    }
    persistRuntimeLease(state: "stopped", reason: shutdownReason)
    CodexRuntimeDirectory.shared.unregister(id: runtimeID)
  }

  private func ensureConnection() async throws -> CodexAppServerConnection {
    guard !isShutdown else {
      throw GatewayToolError.disabled(
        "codex.app.runtime_stopped: Runtime '\(runtimeID)' has been stopped. Create a new gateway session to start a new generation."
      )
    }
    if let connection {
      return connection
    }
    connectionState = "starting"
    lastError = nil
    let startup: ConnectionStartup
    if let connectionStartup {
      startup = connectionStartup
    } else {
      let transport = ManagedCodexAppServerTransport(
        configuration: .init(
          executable: configuration.executable,
          environment: CodexProcessEnvironment.resolved(),
          workingDirectory: workspaceURL,
          terminationGraceMilliseconds: configuration.appServerTerminationGraceMilliseconds,
          killGraceMilliseconds: configuration.appServerKillGraceMilliseconds
        )
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
        transportFactory: { transport }
      )
      let task = Task {
        do {
          let connection = try await client.start()
          if Task.isCancelled {
            await connection.close()
            throw CancellationError()
          }
          return connection
        } catch {
          await transport.close()
          throw error
        }
      }
      startup = .init(id: UUID(), transport: transport, task: task)
      connectionStartup = startup
    }
    do {
      let started = try await startup.task.value
      if let connection {
        return connection
      }
      guard connectionStartup?.id == startup.id else {
        await started.close()
        throw CancellationError()
      }
      connectionStartup = nil
      connection = started
      processTransport = startup.transport
      connectionGeneration += 1
      connectionID = UUID().uuidString
      connectionState = "running"
      let processSnapshot = await startup.transport.snapshot()
      lastProcessSnapshot = processSnapshot
      persistRuntimeLease(state: "running", process: processSnapshot)
      startConsumers(connection: started)
      await eventBuffer.append(
        kind: "connection_started",
        payload: .object([
          "experimental_api": .bool(configuration.experimentalAPI),
          "runtime_id": .string(runtimeID),
          "connection_id": connectionID.map(JSONValue.string) ?? .null,
          "connection_generation": .number(Double(connectionGeneration)),
          "process": processSnapshot.json,
        ])
      )
      return started
    } catch {
      if connectionStartup?.id == startup.id {
        connectionStartup = nil
      }
      await startup.transport.close()
      lastProcessSnapshot = await startup.transport.snapshot()
      connectionState = "failed"
      let message = Self.errorDescription(error)
      lastError = message
      persistRuntimeLease(
        state: "failed",
        process: lastProcessSnapshot,
        reason: "connection_start_failed"
      )
      await eventBuffer.append(
        kind: "connection_failed",
        payload: .object(["message": .string(message)])
      )
      throw GatewayToolError.executionFailed(
        "codex.app.start_failed: \(message)"
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
        await self?.connectionEnded(connection, message: Self.errorDescription(error))
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
    let payload = CodexApprovalRedactor.redact(
      (try? JSONValue.encoded(notification)) ?? .null
    )
    switch notification {
    case .threadStartedNotification(let value):
      guard let threadID = try? Self.validatedThreadID(value.params.thread.id) else { break }
      workspaceScopedThreadIDs.insert(threadID)
      loadedThreadIDs.insert(threadID)
      subscribedThreadIDs.insert(threadID)
    case .threadStatusChangedNotification(let value):
      guard let threadID = try? Self.validatedThreadID(value.params.threadId) else { break }
      workspaceScopedThreadIDs.insert(threadID)
      threadStates[threadID] =
        (try? JSONValue.encoded(value.params.status)) ?? .string("unknown")
    case .threadClosedNotification(let value):
      guard let threadID = try? Self.validatedThreadID(value.params.threadId) else { break }
      loadedThreadIDs.remove(threadID)
      subscribedThreadIDs.remove(threadID)
      activeTurnIDs.removeValue(forKey: threadID)
      threadStates[threadID] = .string("closed")
    case .turnStartedNotification(let value):
      guard let threadID = try? Self.validatedThreadID(value.params.threadId),
        let turnID = Self.safeStoredIdentifier(value.params.turn.id)
      else { break }
      workspaceScopedThreadIDs.insert(threadID)
      activeTurnIDs[threadID] = turnID
      threadStates[threadID] = .string("active")
    case .turnCompletedNotification(let value):
      guard let threadID = try? Self.validatedThreadID(value.params.threadId) else { break }
      activeTurnIDs.removeValue(forKey: threadID)
      threadStates[threadID] = .string("idle")
    default:
      break
    }
    await eventBuffer.append(kind: "notification", payload: payload)
  }

  private func handleServerRequest(
    _ request: CodexAppServerTypedServerRequest,
    connection: CodexAppServerConnection
  ) async {
    let id = Self.requestIDString(request.id)
    switch request {
    case .toolRequestUserInput(let handle):
      let payload = CodexApprovalRedactor.redact(
        Self.serverRequestPayload(
          method: "item/tool/requestUserInput",
          params: handle.params
        )
      )
      pendingUserInputRequests[id] = .init(handle: .userInput(handle), payload: payload)
      await eventBuffer.append(
        kind: "user_input_requested",
        payload: .object(["request_id": .string(id), "request": payload])
      )
    case .commandExecutionApproval(let handle):
      await enqueueApproval(
        handle: .command(handle),
        kind: .commandExecution,
        method: "item/commandExecution/requestApproval",
        params: handle.params,
        connection: connection
      )
    case .fileChangeApproval(let handle):
      await enqueueApproval(
        handle: .fileChange(handle),
        kind: .fileChange,
        method: "item/fileChange/requestApproval",
        params: handle.params,
        connection: connection
      )
    case .mcpServerElicitation(let handle):
      let payload = CodexApprovalRedactor.redact(
        Self.serverRequestPayload(
          method: "mcpServer/elicitation/request",
          params: handle.params
        )
      )
      pendingUserInputRequests[id] = .init(handle: .elicitation(handle), payload: payload)
      await eventBuffer.append(
        kind: "mcp_elicitation_requested",
        payload: .object(["request_id": .string(id), "request": payload])
      )
    case .permissionsApproval(let handle):
      await enqueueApproval(
        handle: .permissions(handle),
        kind: .permissions,
        method: "item/permissions/requestApproval",
        params: handle.params,
        connection: connection
      )
    case .dynamicToolCall(let handle):
      await handleDynamicToolCall(handle, connection: connection)
    case .chatgptAuthTokensRefresh(let handle):
      await rejectServerRequest(
        handle, method: "account/chatgptAuthTokens/refresh", connection: connection)
    case .applyPatchApproval(let handle):
      await enqueueApproval(
        handle: .applyPatch(handle),
        kind: .applyPatch,
        method: "applyPatchApproval",
        params: handle.params,
        connection: connection
      )
    case .execCommandApproval(let handle):
      await enqueueApproval(
        handle: .execCommand(handle),
        kind: .execCommand,
        method: "execCommandApproval",
        params: handle.params,
        connection: connection
      )
    case .attestationGenerate(let handle):
      await rejectServerRequest(handle, method: "attestation/generate", connection: connection)
    }
  }

  private func enqueueApproval<Params: Encodable & Sendable>(
    handle: PendingApprovalHandle,
    kind: CodexApprovalKind,
    method: String,
    params: Params,
    connection: CodexAppServerConnection,
    risk explicitRisk: CapabilityRisk? = nil
  ) async {
    let upstreamRequestID = Self.requestIDString(Self.requestID(for: handle))
    let rawDetails = (try? JSONValue.encoded(params)) ?? .object([:])
    let details = CodexApprovalRedactor.redact(rawDetails)
    let object = rawDetails.objectValue ?? [:]
    let rawThreadID = object["threadId"]?.stringValue ?? object["conversationId"]?.stringValue
    let rawTurnID = object["turnId"]?.stringValue
    let rawItemID = object["itemId"]?.stringValue ?? object["callId"]?.stringValue
    let rawCorrelationID = object["callId"]?.stringValue
    let threadID = rawThreadID.flatMap { try? Self.validatedThreadID($0) }
    let turnID = Self.safeStoredIdentifier(rawTurnID)
    let itemID = Self.safeStoredIdentifier(rawItemID)
    let correlationID = Self.safeStoredIdentifier(rawCorrelationID) ?? UUID().uuidString
    let createdAt = Date()
    let id = UUID().uuidString
    let record = CodexApprovalRecord(
      id: id,
      upstreamRequestID: upstreamRequestID,
      kind: kind,
      risk: explicitRisk ?? Self.approvalRisk(kind: kind, details: rawDetails),
      state: .pending,
      workspaceID: owner?.workspaceID,
      workspacePath: workspaceURL.path,
      runtimeID: runtimeID,
      threadID: threadID,
      turnID: turnID,
      itemID: itemID,
      correlationID: correlationID,
      socketConnectionID: owner?.socketConnectionID,
      tunnelInstanceID: owner?.tunnelInstanceID,
      details: details,
      proposedAction: .object(
        [
          "kind": .string(kind.rawValue),
          "method": .string(method),
        ].merging(
          object["tool"].map { ["tool": $0] } ?? [:],
          uniquingKeysWith: { current, _ in current }
        )
      ),
      createdAt: createdAt,
      expiresAt: createdAt.addingTimeInterval(
        TimeInterval(configuration.appServerApprovalTimeoutSeconds)
      ),
      resolvedAt: nil,
      decision: nil,
      scope: nil,
      resolutionReason: nil
    )

    do {
      guard rawThreadID == nil || threadID != nil,
        rawTurnID == nil || turnID != nil,
        rawItemID == nil || itemID != nil,
        rawCorrelationID == nil || Self.safeStoredIdentifier(rawCorrelationID) != nil
      else {
        throw GatewayToolError.invalidArguments(
          "codex.app.approval_identifier_invalid: Approval identifiers must be bounded opaque values."
        )
      }
      try Self.validateApprovalScope(kind: kind, details: rawDetails, workspaceURL: workspaceURL)
      try persistApproval(record)
    } catch {
      var denied = record
      denied.state = .denied
      denied.resolvedAt = Date()
      denied.decision = .deny
      denied.resolutionReason = Self.errorDescription(error)
      try? persistApproval(denied)
      await rejectApprovalHandle(
        handle,
        connection: connection,
        message: "Computer MCP policy denied this out-of-scope approval request."
      )
      await eventBuffer.append(kind: "approval_denied", payload: denied.json)
      return
    }

    pendingApprovalHandles[id] = handle
    await eventBuffer.append(kind: "approval_requested", payload: record.json)

    if configuration.appServerAutoApproveWorkspaceWrites,
      Self.canAutomaticallyApprove(kind: kind, risk: record.risk)
    {
      do {
        _ = try await resolveApproval(id: id, decision: .approveOnce)
      } catch {
        await recordConsumerFailure(
          kind: "approval_auto_response_failed",
          message: error.localizedDescription
        )
      }
      return
    }

    approvalTimeoutTasks[id] = Task { [weak self] in
      do {
        try await Task.sleep(
          for: .seconds(self?.configuration.appServerApprovalTimeoutSeconds ?? 0))
      } catch {
        return
      }
      await self?.timeoutApproval(id: id)
    }
  }

  private func handleDynamicToolCall(
    _ handle: CodexAppServerServerRequestHandle<
      Stable.DynamicToolCallParams,
      Stable.DynamicToolCallResponse
    >,
    connection: CodexAppServerConnection
  ) async {
    guard handle.params.namespace == nil || handle.params.namespace == "computer-mcp" else {
      await rejectServerRequest(handle, method: "item/tool/call", connection: connection)
      return
    }
    guard let dynamicToolDispatcher else {
      await rejectServerRequest(handle, method: "item/tool/call", connection: connection)
      return
    }
    let descriptor: CapabilityDescriptor
    do {
      descriptor = try dynamicToolDispatcher.descriptor(
        named: handle.params.tool,
        arguments: try Self.gatewayJSON(handle.params.arguments),
        requestID: handle.params.callId,
        workspaceID: owner?.workspaceID
      )
    } catch {
      await rejectServerRequest(handle, method: "item/tool/call", connection: connection)
      return
    }

    if descriptor.risk == .readOnly {
      do {
        try await resolveDynamicTool(
          handle,
          execute: true,
          connection: connection
        )
        await eventBuffer.append(
          kind: "registered_tool_completed",
          payload: .object([
            "call_id": .string(handle.params.callId),
            "tool": .string(handle.params.tool),
          ])
        )
      } catch {
        await recordConsumerFailure(
          kind: "registered_tool_failed",
          message: error.localizedDescription
        )
      }
      return
    }

    await enqueueApproval(
      handle: .registeredTool(handle),
      kind: .registeredTool,
      method: "item/tool/call",
      params: handle.params,
      connection: connection,
      risk: descriptor.risk
    )
  }

  private func resolveApproval(
    id: String,
    decision: CodexApprovalDecision
  ) async throws -> CodexApprovalRecord {
    let storedRecord: CodexApprovalRecord?
    if let cached = approvalRecords[id] {
      storedRecord = cached
    } else {
      storedRecord = try database?.codexApproval(id: id)
    }
    guard var record = storedRecord, Self.isApprovalVisible(record, to: owner) else {
      throw CodexApprovalBrokerError.unknown(id)
    }
    guard record.state == .pending else {
      throw CodexApprovalBrokerError.alreadyResolved(id)
    }
    guard let handle = pendingApprovalHandles[id], let connection else {
      record.state = .interrupted
      record.resolvedAt = Date()
      record.resolutionReason = "The live App Server request is no longer available."
      try persistApproval(record)
      throw CodexApprovalBrokerError.unavailableAfterRestart(id)
    }
    if decision != .deny {
      try Self.validateApprovalScope(
        kind: record.kind,
        details: Self.rawDetails(for: handle),
        workspaceURL: workspaceURL
      )
      if decision == .approveSession,
        !Self.supportsBoundedSessionApproval(record.kind)
      {
        throw CodexApprovalBrokerError.unsupportedScope(
          "\(record.kind.rawValue) is limited to approve_once."
        )
      }
    }

    do {
      try await resolve(
        handle: handle,
        decision: decision,
        timedOut: false,
        connection: connection
      )
      record.state = decision == .deny ? .denied : .approved
      record.resolvedAt = Date()
      record.decision = decision
      record.scope = decision == .approveSession ? "session" : "once"
      record.resolutionReason = decision == .deny ? "Denied by the gateway caller." : nil
      try persistApproval(record)
      pendingApprovalHandles.removeValue(forKey: id)
      approvalTimeoutTasks.removeValue(forKey: id)?.cancel()
      await eventBuffer.append(kind: "approval_resolved", payload: record.json)
      return record
    } catch {
      record.state = .failed
      record.resolvedAt = Date()
      record.resolutionReason = Self.errorDescription(error)
      try? persistApproval(record)
      pendingApprovalHandles.removeValue(forKey: id)
      approvalTimeoutTasks.removeValue(forKey: id)?.cancel()
      await eventBuffer.append(kind: "approval_response_failed", payload: record.json)
      throw error
    }
  }

  private func timeoutApproval(id: String) async {
    guard var record = approvalRecords[id], record.state == .pending,
      let handle = pendingApprovalHandles[id], let connection
    else {
      return
    }
    do {
      try await resolve(
        handle: handle,
        decision: .deny,
        timedOut: true,
        connection: connection
      )
      record.state = .timedOut
      record.resolvedAt = Date()
      record.decision = .deny
      record.scope = "once"
      record.resolutionReason = "Approval deadline expired."
      try persistApproval(record)
      pendingApprovalHandles.removeValue(forKey: id)
      approvalTimeoutTasks.removeValue(forKey: id)?.cancel()
      await eventBuffer.append(kind: "approval_timed_out", payload: record.json)
    } catch {
      record.state = .failed
      record.resolvedAt = Date()
      record.decision = .deny
      record.scope = "once"
      record.resolutionReason =
        "Approval deadline expired, but the App Server response could not be delivered: "
        + Self.errorDescription(error)
      try? persistApproval(record)
      pendingApprovalHandles.removeValue(forKey: id)
      approvalTimeoutTasks.removeValue(forKey: id)?.cancel()
      await eventBuffer.append(kind: "approval_timeout_response_failed", payload: record.json)
      await recordConsumerFailure(
        kind: "approval_timeout_response_failed",
        message: error.localizedDescription
      )
    }
  }

  private func reconcileApprovalRecords() async throws {
    if let database {
      for record in try database.codexApprovals(limit: 5_000)
      where Self.isApprovalVisible(record, to: owner) {
        approvalRecords[record.id] = record
      }
    }
    let now = Date()
    for id in approvalRecords.keys.sorted() {
      guard var record = approvalRecords[id], record.state == .pending else { continue }
      if let task = approvalTimeoutTasks[id], !task.isCancelled {
        continue
      }
      if record.runtimeID == runtimeID, pendingApprovalHandles[id] != nil {
        if record.expiresAt <= now {
          await timeoutApproval(id: id)
        }
        continue
      }
      if CodexRuntimeDirectory.shared.runtime(id: record.runtimeID) == nil {
        record.state = .interrupted
        record.resolvedAt = now
        record.resolutionReason = "The owning runtime is no longer active."
        try persistApproval(record)
      }
    }
  }

  private func interruptPendingApprovals(
    connection: CodexAppServerConnection,
    reason: String
  ) async {
    for id in pendingApprovalHandles.keys.sorted() {
      guard var record = approvalRecords[id], let handle = pendingApprovalHandles[id] else {
        continue
      }
      try? await resolve(
        handle: handle,
        decision: .deny,
        timedOut: false,
        connection: connection
      )
      record.state = .interrupted
      record.resolvedAt = Date()
      record.decision = .deny
      record.resolutionReason = reason
      try? persistApproval(record)
      approvalTimeoutTasks.removeValue(forKey: id)?.cancel()
    }
    pendingApprovalHandles.removeAll()
  }

  private func persistApproval(_ record: CodexApprovalRecord) throws {
    try database?.saveCodexApproval(record)
    approvalRecords[record.id] = record
  }

  private nonisolated static func isApprovalVisible(
    _ record: CodexApprovalRecord,
    to owner: CodexRuntimeOwner?
  ) -> Bool {
    record.workspaceID == owner?.workspaceID
  }

  private func rejectServerRequest<Params: Encodable & Sendable, Response: Encodable & Sendable>(
    _ handle: CodexAppServerServerRequestHandle<Params, Response>,
    method: String,
    connection: CodexAppServerConnection
  ) async {
    let id = Self.requestIDString(handle.id)
    let payload = CodexApprovalRedactor.redact(
      Self.serverRequestPayload(method: method, params: handle.params)
    )
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

  private func rejectApprovalHandle(
    _ handle: PendingApprovalHandle,
    connection: CodexAppServerConnection,
    message: String
  ) async {
    do {
      switch handle {
      case .command(let value):
        try await connection.rejectServerRequest(value, code: -32_001, message: message)
      case .fileChange(let value):
        try await connection.rejectServerRequest(value, code: -32_001, message: message)
      case .permissions(let value):
        try await connection.rejectServerRequest(value, code: -32_001, message: message)
      case .applyPatch(let value):
        try await connection.rejectServerRequest(value, code: -32_001, message: message)
      case .execCommand(let value):
        try await connection.rejectServerRequest(value, code: -32_001, message: message)
      case .registeredTool(let value):
        try await connection.rejectServerRequest(value, code: -32_001, message: message)
      }
    } catch {
      await recordConsumerFailure(
        kind: "approval_policy_rejection_failed",
        message: error.localizedDescription
      )
    }
  }

  private static func requestID(
    for handle: PendingApprovalHandle
  ) -> CodexAppServerProtocol.Stable.RequestId {
    switch handle {
    case .command(let value): value.id
    case .fileChange(let value): value.id
    case .permissions(let value): value.id
    case .applyPatch(let value): value.id
    case .execCommand(let value): value.id
    case .registeredTool(let value): value.id
    }
  }

  private static func rawDetails(for handle: PendingApprovalHandle) -> JSONValue {
    switch handle {
    case .command(let value):
      return (try? JSONValue.encoded(value.params)) ?? .object([:])
    case .fileChange(let value):
      return (try? JSONValue.encoded(value.params)) ?? .object([:])
    case .permissions(let value):
      return (try? JSONValue.encoded(value.params)) ?? .object([:])
    case .applyPatch(let value):
      return (try? JSONValue.encoded(value.params)) ?? .object([:])
    case .execCommand(let value):
      return (try? JSONValue.encoded(value.params)) ?? .object([:])
    case .registeredTool(let value):
      return (try? JSONValue.encoded(value.params)) ?? .object([:])
    }
  }

  private static func approvalRisk(
    kind: CodexApprovalKind,
    details: JSONValue
  ) -> CapabilityRisk {
    let object = details.objectValue ?? [:]
    if object["networkApprovalContext"] != nil
      || !(object["proposedNetworkPolicyAmendments"]?.arrayValue ?? []).isEmpty
      || object["permissions"]?.objectValue?["network"]?.objectValue?["enabled"]?.boolValue == true
    {
      return .externalWrite
    }
    return kind == .permissions ? .destructive : .workspaceWrite
  }

  private static func canAutomaticallyApprove(
    kind: CodexApprovalKind,
    risk: CapabilityRisk
  ) -> Bool {
    risk == .workspaceWrite && (kind == .fileChange || kind == .applyPatch)
  }

  private static func supportsBoundedSessionApproval(_ kind: CodexApprovalKind) -> Bool {
    kind == .fileChange || kind == .applyPatch || kind == .permissions
  }

  private static func validateApprovalScope(
    kind: CodexApprovalKind,
    details: JSONValue,
    workspaceURL: URL
  ) throws {
    let object = details.objectValue ?? [:]
    if object["networkApprovalContext"] != nil
      || !(object["proposedNetworkPolicyAmendments"]?.arrayValue ?? []).isEmpty
      || object["permissions"]?.objectValue?["network"]?.objectValue?["enabled"]?.boolValue == true
    {
      throw CodexApprovalBrokerError.outsideWorkspace(
        "network permission expansion is not registered for the Codex provider"
      )
    }

    var paths: [String] = []
    for key in ["cwd", "grantRoot"] {
      if let path = object[key]?.stringValue {
        paths.append(path)
      }
    }
    if let fileChanges = object["fileChanges"]?.objectValue {
      paths.append(contentsOf: fileChanges.keys)
    }
    if let fileSystem = object["permissions"]?.objectValue?["fileSystem"]?.objectValue {
      paths.append(contentsOf: fileSystem["read"]?.arrayValue?.compactMap(\.stringValue) ?? [])
      paths.append(contentsOf: fileSystem["write"]?.arrayValue?.compactMap(\.stringValue) ?? [])
      for entry in fileSystem["entries"]?.arrayValue ?? [] {
        guard let pathObject = entry.objectValue?["path"]?.objectValue,
          pathObject["type"]?.stringValue == "path",
          let path = pathObject["path"]?.stringValue
        else {
          throw CodexApprovalBrokerError.outsideWorkspace(
            "glob and special filesystem grants are not eligible for gateway approval"
          )
        }
        paths.append(path)
      }
    }

    for path in paths {
      let candidate =
        path.hasPrefix("/")
        ? URL(fileURLWithPath: path)
        : workspaceURL.appendingPathComponent(path)
      guard contains(candidate, in: workspaceURL) else {
        throw CodexApprovalBrokerError.outsideWorkspace(path)
      }
    }
    if kind == .permissions, paths.isEmpty {
      throw CodexApprovalBrokerError.unsupportedScope(
        "an empty or unrecognized permission grant cannot be approved"
      )
    }
  }

  private func resolve(
    handle: PendingApprovalHandle,
    decision: CodexApprovalDecision,
    timedOut: Bool,
    connection: CodexAppServerConnection
  ) async throws {
    switch handle {
    case .command(let value):
      let responseDecision: Stable.CommandExecutionApprovalDecision =
        timedOut
        ? .cancel
        : decision == .deny
          ? .decline
          : decision == .approveSession ? .acceptforsession : .accept
      try await connection.resolveServerRequest(
        value,
        with: Stable.CommandExecutionRequestApprovalResponse(decision: responseDecision)
      )
    case .fileChange(let value):
      let responseDecision: Stable.FileChangeApprovalDecision =
        timedOut
        ? .cancel
        : decision == .deny
          ? .decline
          : decision == .approveSession ? .acceptforsession : .accept
      try await connection.resolveServerRequest(
        value,
        with: Stable.FileChangeRequestApprovalResponse(decision: responseDecision)
      )
    case .permissions(let value):
      let permissions: Stable.GrantedPermissionProfile
      if timedOut || decision == .deny {
        permissions = .init()
      } else {
        let data = try JSONEncoder().encode(value.params.permissions)
        permissions = try JSONDecoder().decode(Stable.GrantedPermissionProfile.self, from: data)
      }
      try await connection.resolveServerRequest(
        value,
        with: Stable.PermissionsRequestApprovalResponse(
          permissions: permissions,
          scope: decision == .approveSession ? .session : .turn,
          strictAutoReview: true
        )
      )
    case .applyPatch(let value):
      try await connection.resolveServerRequest(
        value,
        with: Stable.ApplyPatchApprovalResponse(
          decision: Self.reviewDecision(
            decision: decision,
            timedOut: timedOut,
            rejection: "Denied by Computer MCP approval policy."
          )
        )
      )
    case .execCommand(let value):
      try await connection.resolveServerRequest(
        value,
        with: Stable.ExecCommandApprovalResponse(
          decision: Self.reviewDecision(
            decision: decision,
            timedOut: timedOut,
            rejection: "Denied by Computer MCP approval policy."
          )
        )
      )
    case .registeredTool(let value):
      try await resolveDynamicTool(
        value,
        execute: !timedOut && decision != .deny,
        connection: connection
      )
    }
  }

  private func resolveDynamicTool(
    _ handle: CodexAppServerServerRequestHandle<
      Stable.DynamicToolCallParams,
      Stable.DynamicToolCallResponse
    >,
    execute: Bool,
    connection: CodexAppServerConnection
  ) async throws {
    guard execute else {
      try await connection.resolveServerRequest(
        handle,
        with: Self.dynamicToolResponse(
          success: false,
          value: .object([
            "error": .string("The registered Computer MCP tool call was denied or timed out.")
          ])
        )
      )
      return
    }
    guard let dynamicToolDispatcher else {
      throw GatewayToolError.disabled(
        "codex.app.dynamic_tool_unavailable: The owning gateway runtime is unavailable."
      )
    }
    do {
      let result = try await dynamicToolDispatcher.execute(
        name: handle.params.tool,
        arguments: try Self.gatewayJSON(handle.params.arguments),
        requestID: handle.params.callId,
        workspaceID: owner?.workspaceID
      )
      try await connection.resolveServerRequest(
        handle,
        with: Self.dynamicToolResponse(success: true, value: result)
      )
    } catch {
      let redacted = CodexApprovalRedactor.redact(
        .object(["error": .string(error.localizedDescription)])
      )
      try? await connection.resolveServerRequest(
        handle,
        with: Self.dynamicToolResponse(success: false, value: redacted)
      )
      throw error
    }
  }

  private static func dynamicToolResponse(
    success: Bool,
    value: JSONValue
  ) -> Stable.DynamicToolCallResponse {
    let text: String
    if let data = try? CanonicalJSONCoding.encoder(outputFormatting: [.sortedKeys]).encode(value) {
      text = String(decoding: data.prefix(1_048_576), as: UTF8.self)
    } else {
      text = "{\"error\":\"Computer MCP could not encode the tool result.\"}"
    }
    return Stable.DynamicToolCallResponse(
      contentItems: [
        .inputtext(.init(text: text, type: .inputtext))
      ],
      success: success
    )
  }

  private static func reviewDecision(
    decision: CodexApprovalDecision,
    timedOut: Bool,
    rejection: String
  ) -> Stable.ReviewDecision {
    if timedOut {
      return .timedOut
    }
    switch decision {
    case .approveOnce:
      return .approved
    case .approveSession:
      return .approvedForSession
    case .deny:
      return .deniedreviewdecision(
        .init(denied: .init(rejection: rejection))
      )
    }
  }

  private func connectionEnded(
    _ endedConnection: CodexAppServerConnection,
    message: String?
  ) async {
    guard connection === endedConnection else {
      await endedConnection.close()
      return
    }
    await interruptPendingApprovals(
      connection: endedConnection,
      reason: message == nil ? "App Server connection ended." : "App Server connection failed."
    )
    let endedTransport = processTransport
    connection = nil
    connectionID = nil
    processTransport = nil
    pendingUserInputRequests.removeAll()
    workspaceScopedThreadIDs.removeAll()
    connectionState = message == nil ? "stopped" : "failed"
    shutdownReason = message == nil ? "peer_closed" : "consumer_failure"
    let redactedMessage = message.map(Self.redactedMessage)
    lastError = redactedMessage
    await eventBuffer.append(
      kind: "connection_ended",
      payload: .object(["message": redactedMessage.map(JSONValue.string) ?? .null])
    )
    await endedConnection.close()
    await endedTransport?.close()
    if let endedTransport {
      lastProcessSnapshot = await endedTransport.snapshot()
    }
    persistRuntimeLease(
      state: connectionState,
      process: lastProcessSnapshot,
      reason: shutdownReason
    )
  }

  private func retireTimedOutConnection(
    _ timedOutConnection: CodexAppServerConnection
  ) async {
    if connection === timedOutConnection {
      let timedOutTransport = processTransport
      await interruptPendingApprovals(
        connection: timedOutConnection,
        reason: "App Server request deadline exceeded."
      )
      connection = nil
      connectionID = nil
      processTransport = nil
      notificationTask?.cancel()
      notificationTask = nil
      requestTask?.cancel()
      requestTask = nil
      pendingUserInputRequests.removeAll()
      workspaceScopedThreadIDs.removeAll()
      connectionState = "failed"
      shutdownReason = "request_timeout"
      lastError = "App Server request deadline exceeded."
      await eventBuffer.append(
        kind: "connection_ended",
        payload: .object(["message": .string("App Server request deadline exceeded.")])
      )
      await timedOutConnection.close()
      await timedOutTransport?.close()
      if let timedOutTransport {
        lastProcessSnapshot = await timedOutTransport.snapshot()
      }
      persistRuntimeLease(
        state: "failed",
        process: lastProcessSnapshot,
        reason: shutdownReason
      )
      return
    }
    await timedOutConnection.close()
  }

  static func boundedRequest<Value: Sendable>(
    timeoutSeconds: Int,
    onTimeout: @escaping @Sendable () async -> Void,
    operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    let completion = CodexTimedRequestCompletion<Value>()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard completion.install(continuation) else {
          continuation.resume(throwing: CancellationError())
          return
        }
        let operationTask = Task {
          do {
            completion.resumeOperation(with: .success(try await operation()))
          } catch {
            completion.resumeOperation(with: .failure(error))
          }
        }
        let timeoutTask = Task {
          do {
            try await Task.sleep(for: .seconds(timeoutSeconds))
          } catch {
            return
          }
          guard let continuation = completion.claim(.timeout) else {
            return
          }
          await onTimeout()
          continuation.resume(throwing: RequestTimeoutError(seconds: timeoutSeconds))
        }
        completion.installTasks(operation: operationTask, timeout: timeoutTask)
      }
    } onCancel: {
      completion.cancel()
    }
  }

  private func recordConsumerFailure(kind: String, message: String) async {
    await eventBuffer.append(
      kind: kind,
      payload: .object(["message": .string(Self.redactedMessage(message))])
    )
  }

  private func persistRuntimeLease(
    state: String,
    process: CodexAppServerProcessSnapshot? = nil,
    reason: String? = nil
  ) {
    guard let database else { return }
    let now = Date()
    let previous = try? database.codexRuntimeLeases(limit: 5_000)
      .first(where: { $0.id == runtimeID })
    let record = CodexRuntimeLeaseRecord(
      id: runtimeID,
      owner: owner,
      workspacePath: workspaceURL.path,
      state: state,
      process: process ?? lastProcessSnapshot ?? previous?.process,
      createdAt: previous?.createdAt ?? createdAt,
      updatedAt: now,
      shutdownReason: reason ?? previous?.shutdownReason,
      cleanedAt: previous?.cleanedAt
    )
    try? database.saveCodexRuntimeLease(record)
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

    if method == "thread/resume" {
      do {
        try await validatePersistedWorkspaceThread(
          threadID: threadID,
          connection: connection
        )
        workspaceScopedThreadIDs.insert(threadID)
        return
      } catch {
        throw GatewayToolError.executionFailed(
          "codex.app.thread_scope_lookup_failed: \(Self.errorDescription(error))"
        )
      }
    }

    let response: JSONValue
    do {
      response = try Self.gatewayJSON(
        try await Self.boundedRequest(
          timeoutSeconds: configuration.appServerRequestTimeoutSeconds,
          onTimeout: {
            await self.retireTimedOutConnection(connection)
          },
          operation: {
            try await connection.threadRead(
              try Self.decodeStableParams(
                Stable.ThreadReadParams.self,
                from: .object([
                  "threadId": .string(threadID),
                  "includeTurns": .bool(false),
                ])
              )
            )
          }
        )
      )
    } catch  where Self.isThreadNotLoaded(error) {
      do {
        try await validatePersistedWorkspaceThread(
          threadID: threadID,
          connection: connection
        )
        workspaceScopedThreadIDs.insert(threadID)
        return
      } catch {
        throw GatewayToolError.executionFailed(
          "codex.app.thread_scope_lookup_failed: \(Self.errorDescription(error))"
        )
      }
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

  private func validatePersistedWorkspaceThread(
    threadID: String,
    connection: CodexAppServerConnection
  ) async throws {
    if let ownership = try database?.codexThreadOwnership(threadID: threadID) {
      try validatePersistedOwnership(ownership)
      return
    }

    let cwdFilters: [Stable.ThreadListCwdFilter?] = [
      .threadlistcwdfilteroption1(workspaceURL.path), nil,
    ]
    for cwdFilter in cwdFilters {
      for archived in [false, true] {
        var cursor: String?
        var visitedCursors: Set<String> = []
        for pageIndex in 0..<100 {
          let currentCursor = cursor
          let page: Stable.ThreadListResponse
          do {
            page = try await Self.boundedRequest(
              timeoutSeconds: configuration.appServerRequestTimeoutSeconds,
              onTimeout: {
                await self.retireTimedOutConnection(connection)
              },
              operation: {
                try await connection.threadList(
                  Stable.ThreadListParams(
                    archived: archived,
                    cursor: currentCursor,
                    cwd: cwdFilter,
                    limit: 1_000,
                    sourceKinds: Self.persistedThreadSourceKinds,
                    useStateDbOnly: true
                  )
                )
              }
            )
          } catch {
            throw GatewayToolError.executionFailed(
              "codex.app.thread_scope_list_failed: \(Self.errorDescription(error))"
            )
          }
          if let thread = page.data.first(where: { $0.id == threadID }) {
            try Self.validatePersistedThreadWorkspace(
              threadID: threadID,
              threadCWD: thread.cwd,
              workspaceURL: workspaceURL
            )
            return
          }
          guard let nextCursor = page.nextCursor, !nextCursor.isEmpty else {
            break
          }
          guard visitedCursors.insert(nextCursor).inserted else {
            throw GatewayToolError.executionFailed(
              "codex.app.thread_scope_pagination_invalid: App Server repeated a thread-list cursor."
            )
          }
          guard pageIndex < 99 else {
            throw GatewayToolError.executionFailed(
              "codex.app.thread_scope_pagination_limit: Thread ownership lookup exceeded 100 pages."
            )
          }
          cursor = nextCursor
        }
      }
    }
    throw GatewayToolError.disabled(
      "codex.app.thread_outside_workspace_or_unknown: The thread is not available in the bound workspace."
    )
  }

  private func validatePersistedOwnership(_ ownership: CodexThreadOwnershipRecord) throws {
    if let workspaceID = owner?.workspaceID {
      guard ownership.workspaceID == workspaceID else {
        throw GatewayToolError.disabled(
          "codex.app.thread_outside_workspace: The thread belongs to a different registered workspace."
        )
      }
    }
    let recordedWorkspace = URL(fileURLWithPath: ownership.workspacePath)
      .standardizedFileURL.resolvingSymlinksInPath()
    let currentWorkspace = workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
    guard recordedWorkspace == currentWorkspace else {
      throw GatewayToolError.disabled(
        "codex.app.thread_outside_workspace: The thread belongs to a different workspace root."
      )
    }
  }

  private func rememberWorkspaceScopedThreads(
    method: String,
    params: JSONValue?,
    response: JSONValue
  ) throws {
    if ["thread/start", "thread/resume", "thread/fork"].contains(method) {
      let threadID = try Self.createdWorkspaceScopedThreadID(
        response: response,
        workspaceURL: workspaceURL
      )
      try persistThreadOwnership(threadID: threadID, state: .loaded)
      workspaceScopedThreadIDs.insert(threadID)
      loadedThreadIDs.insert(threadID)
      subscribedThreadIDs.insert(threadID)
    }

    if method == "thread/loaded/list" {
      let loaded = Set(
        response.objectValue?["data"]?.arrayValue?.compactMap(\.stringValue) ?? []
      )
      workspaceScopedThreadIDs.formUnion(loaded)
      loadedThreadIDs.formUnion(loaded)
      subscribedThreadIDs.formUnion(loaded)
    }

    if method == "thread/unsubscribe",
      let threadID = params?.objectValue?["threadId"]?.stringValue
    {
      loadedThreadIDs.remove(threadID)
      subscribedThreadIDs.remove(threadID)
      activeTurnIDs.removeValue(forKey: threadID)
      threadStates[threadID] = .string("released")
      try persistThreadOwnership(threadID: threadID, state: .released)
    }

    if method == "thread/archive",
      let threadID = params?.objectValue?["threadId"]?.stringValue
    {
      try persistThreadOwnership(threadID: threadID, state: .archived)
    }

    if method == "thread/unarchive",
      let threadID = params?.objectValue?["threadId"]?.stringValue
    {
      try persistThreadOwnership(threadID: threadID, state: .released)
    }

    if method == "review/start",
      let reviewThreadID = response.objectValue?["reviewThreadId"]?.stringValue,
      !reviewThreadID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      workspaceScopedThreadIDs.insert(reviewThreadID)
    }
  }

  private func releaseAllThreads(connection: CodexAppServerConnection) async {
    for threadID in subscribedThreadIDs.sorted() {
      do {
        _ = try await Self.boundedRequest(
          timeoutSeconds: min(2, configuration.appServerRequestTimeoutSeconds),
          onTimeout: {},
          operation: {
            try await connection.threadUnsubscribe(
              try Self.decodeStableParams(
                Stable.ThreadUnsubscribeParams.self,
                from: .object(["threadId": .string(threadID)])
              )
            )
          }
        )
        loadedThreadIDs.remove(threadID)
        subscribedThreadIDs.remove(threadID)
        threadStates[threadID] = .string("released")
        try persistThreadOwnership(threadID: threadID, state: .released)
      } catch {
        await eventBuffer.append(
          kind: "thread_release_failed",
          payload: .object([
            "thread_id": .string(threadID),
            "message": .string(Self.errorDescription(error)),
          ])
        )
      }
    }
  }

  private func persistThreadOwnership(
    threadID: String,
    state: CodexThreadOwnershipState
  ) throws {
    guard let database else { return }
    let now = Date()
    let previous = try database.codexThreadOwnership(threadID: threadID)
    if let previous {
      try validatePersistedOwnership(previous)
    }
    try database.saveCodexThreadOwnership(
      CodexThreadOwnershipRecord(
        threadID: threadID,
        workspaceID: owner?.workspaceID,
        workspacePath: workspaceURL.path,
        runtimeID: runtimeID,
        state: state,
        createdAt: previous?.createdAt ?? now,
        updatedAt: now
      )
    )
  }

  static func createdWorkspaceScopedThreadID(
    response: JSONValue,
    workspaceURL: URL
  ) throws -> String {
    guard let thread = response.objectValue?["thread"]?.objectValue,
      let rawThreadID = thread["id"]?.stringValue,
      let cwd = thread["cwd"]?.stringValue
    else {
      throw GatewayToolError.executionFailed(
        "codex.app.thread_scope_unknown: App Server did not return id and cwd for the created thread."
      )
    }
    let threadID = try validatedThreadID(rawThreadID)
    guard Self.contains(URL(fileURLWithPath: cwd), in: workspaceURL) else {
      throw GatewayToolError.disabled(
        "codex.app.thread_outside_workspace: The created thread belongs to a different workspace."
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
    guard let rawThreadID = params?.objectValue?["threadId"]?.stringValue else {
      throw GatewayToolError.invalidArguments(
        "codex.app.thread_id_required: method '\(method)' requires a non-empty threadId."
      )
    }
    return try validatedThreadID(rawThreadID)
  }

  static func validateThreadWorkspace(
    threadID: String,
    response: JSONValue,
    workspaceURL: URL
  ) throws {
    guard let cwd = response.objectValue?["thread"]?.objectValue?["cwd"]?.stringValue else {
      throw GatewayToolError.executionFailed(
        "codex.app.thread_scope_unknown: App Server did not return a thread cwd."
      )
    }
    guard Self.contains(URL(fileURLWithPath: cwd), in: workspaceURL) else {
      throw GatewayToolError.disabled(
        "codex.app.thread_outside_workspace: The thread belongs to a different workspace."
      )
    }
  }

  static func validatePersistedThreadWorkspace(
    threadID: String,
    threadCWD: String,
    workspaceURL: URL
  ) throws {
    guard Self.contains(URL(fileURLWithPath: threadCWD), in: workspaceURL) else {
      throw GatewayToolError.disabled(
        "codex.app.thread_outside_workspace: The thread belongs to a different workspace."
      )
    }
  }

  static func validatedThreadID(_ value: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= 1_024,
      trimmed.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw GatewayToolError.invalidArguments(
        "codex.app.thread_id_invalid: threadId must be a bounded opaque identifier."
      )
    }
    return trimmed
  }

  private static func safeStoredIdentifier(
    _ value: String?,
    maximumBytes: Int = 1_024
  ) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= maximumBytes,
      trimmed.rangeOfCharacter(from: .controlCharacters) == nil,
      CodexApprovalRedactor.redactString(trimmed, maximumCharacters: 8_192) == trimmed
    else {
      return nil
    }
    return trimmed
  }

  static func isThreadNotLoaded(_ error: Error) -> Bool {
    guard let clientError = error as? CodexAppServerClientError,
      case .jsonRPCError(let code, let message, _) = clientError
    else {
      return false
    }
    return code == -32_600
      && message.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        .hasPrefix("thread not loaded")
  }

  private static let persistedThreadSourceKinds: [Stable.ThreadSourceKind] = [
    .cli,
    .vscode,
    .exec,
    .appserver,
    .subagent,
    .subagentreview,
    .subagentcompact,
    .subagentthreadspawn,
    .subagentother,
    .unknown,
  ]

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
    "thread/goal/clear",
    "thread/goal/get",
    "thread/goal/set",
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

  private static func decodeElicitationResponse(
    _ value: JSONValue
  ) throws -> Stable.McpServerElicitationRequestResponse {
    guard let action = value.objectValue?["action"]?.stringValue,
      ["accept", "decline", "cancel"].contains(action)
    else {
      throw GatewayToolError.invalidArguments(
        "codex.app.elicitation_response_invalid: action must be accept, decline, or cancel."
      )
    }
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(Stable.McpServerElicitationRequestResponse.self, from: data)
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
    case "thread/loaded/list":
      return try gatewayJSON(
        try await connection.threadLoadedList(
          try decodeStableParams(Stable.ThreadLoadedListParams.self, from: params)
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
    case "thread/goal/get":
      return try gatewayJSON(
        try await connection.threadGoalGet(
          try decodeStableParams(Stable.ThreadGoalGetParams.self, from: params)
        )
      )
    case "thread/goal/set":
      return try gatewayJSON(
        try await connection.threadGoalSet(
          try decodeStableParams(Stable.ThreadGoalSetParams.self, from: params)
        )
      )
    case "thread/goal/clear":
      return try gatewayJSON(
        try await connection.threadGoalClear(
          try decodeStableParams(Stable.ThreadGoalClearParams.self, from: params)
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
      return opaqueProtocolID(prefix: "s", value: value)
    case .requestidoption2(let value):
      return "n:\(value)"
    }
  }

  private static func opaqueProtocolID(prefix: String, value: String) -> String {
    if safeStoredIdentifier(value) != nil {
      return "\(prefix):\(value)"
    }
    let digest = SHA256.hash(data: Data(value.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return "\(prefix):sha256:\(digest)"
  }

  private static func errorDescription(_ error: Error) -> String {
    redactedMessage(unredactedErrorDescription(error))
  }

  private static func unredactedErrorDescription(_ error: Error) -> String {
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

  private static func redactedMessage(_ message: String) -> String {
    CodexApprovalRedactor.redact(.string(message)).stringValue
      ?? "The App Server operation failed."
  }
}
