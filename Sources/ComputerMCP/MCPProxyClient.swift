import Foundation
import MCP

/// Proxies configured downstream servers through persistent MCP SDK sessions.
package final class MCPProxyClient: DownstreamMCPClient, @unchecked Sendable {
  private let pool: MCPConnectionPool
  private let changes: GatewayToolChangeBroadcaster
  private let secretStore: KeychainSecretStore?
  private let processOwnershipRoot: URL?
  private let journal: MCPExecutionJournal
  private let calls = BlockingOperationExecutor(label: "computer-mcp.mcp-calls", serial: false)

  package init(
    workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    hostContext: MCPHostContext? = nil,
    secretStore: KeychainSecretStore? = nil,
    processOwnershipRoot: URL? = nil,
    executionDatabase: GatewayDatabase? = nil, executionScope: String? = nil
  ) {
    let changes = GatewayToolChangeBroadcaster()
    self.changes = changes
    self.secretStore = secretStore
    self.processOwnershipRoot = processOwnershipRoot
    let scope =
      executionScope ?? hostContext.map {
        MCPExecutionRecord.digest(
          .array([
            .string($0.principalID), .string($0.profileID.rawValue), .string($0.workspace.id),
          ]))
      } ?? UUID().uuidString
    let journal = MCPExecutionJournal(
      database: executionDatabase ?? hostContext?.executionDatabase, scope: scope)
    self.journal = journal
    var hostContext = hostContext
    if hostContext?.processOwnershipRoot == nil {
      hostContext?.processOwnershipRoot = processOwnershipRoot
    }
    self.pool = MCPConnectionPool(
      workingDirectory: workingDirectory.standardizedFileURL, environment: environment,
      hostContext: hostContext, secretStore: secretStore, journal: journal,
      toolsChanged: { changes.send() })
  }

  package func makeScopedClient(
    workingDirectory: URL, environment: [String: String], hostContext: MCPHostContext?
  )
    -> any DownstreamMCPClient
  {
    MCPProxyClient(
      workingDirectory: workingDirectory, environment: environment, hostContext: hostContext,
      secretStore: secretStore, processOwnershipRoot: processOwnershipRoot)
  }

  package func toolChanges() -> AsyncStream<Void> { changes.stream() }

  package func shutdown() async {
    changes.finish()
    await pool.shutdown().value
  }

  deinit {
    changes.finish()
    _ = pool.shutdown()
  }

  package func listTools(server: MCPServerConfig) throws -> [MCPTool] {
    try run(server: server, notifyToolsOnConnect: false) { connection in
      try await connection.listTools()
    }
  }

  package func callTool(server: MCPServerConfig, name: String, arguments: JSONValue) throws
    -> JSONValue
  {
    try callTool(server: server, name: name, arguments: arguments, requestID: nil)
  }

  package func callTool(
    server: MCPServerConfig,
    name: String,
    arguments: JSONValue,
    requestID: String?
  ) throws -> JSONValue {
    try callTool(
      server: server, name: name, arguments: arguments, requestID: requestID, cancellation: nil)
  }

  package func callToolAsync(
    server: MCPServerConfig, name: String, arguments: JSONValue, requestID: String?
  ) async throws -> JSONValue {
    let cancellation = MCPCallCancellation()
    return try await withTaskCancellationHandler {
      do {
        try Task.checkCancellation()
        let result = try await calls.perform {
          try cancellation.checkCancellation()
          return try self.callTool(
            server: server, name: name, arguments: arguments, requestID: requestID,
            cancellation: cancellation)
        }
        await cancellation.finish()
        try Task.checkCancellation()
        return result
      } catch {
        await cancellation.finish()
        throw error
      }
    } onCancel: {
      cancellation.cancel()
    }
  }

  private func callTool(
    server: MCPServerConfig, name: String, arguments: JSONValue, requestID: String?,
    cancellation: MCPCallCancellation?
  ) throws -> JSONValue {
    guard let object = arguments.objectValue else {
      throw GatewayToolError.invalidArguments(
        "Downstream MCP tool arguments must be an object."
      )
    }

    let retainsResult = requestID != nil
    let requestID = requestID ?? UUID().uuidString
    if retainsResult {
      guard !requestID.isEmpty else {
        throw GatewayToolError.invalidArguments("Downstream MCP request id must not be empty.")
      }
      let reservation = try journal.reserve(
        server: server, tool: name, arguments: arguments, requestID: requestID)
      if !reservation.inserted {
        guard reservation.record.state == .succeeded || reservation.record.state == .failed,
          reservation.record.outputExpiresAt.map({ $0 > Date() }) == true,
          reservation.record.retainedByteCount == reservation.record.outputByteCount,
          let output = reservation.record.outputJSON
        else {
          throw GatewayToolError.invalidArguments(
            "[request.already_started] Query mcp.requests.read for this execution; it was not replayed."
          )
        }
        return try JSONDecoder().decode(JSONValue.self, from: Data(output.utf8))
      }
    }
    do {
      return try run(server: server) { connection in
        try await connection.callTool(
          name: name, arguments: object, gatewayRequestID: requestID, cancellation: cancellation,
          retainsResult: retainsResult,
          cancellationDeliveryFailed: {
            self.pool.invalidate(server: server, connection: connection)
          })
      }
    } catch {
      if retainsResult {
        try journal.update(serverID: server.id, requestID: requestID) {
          if !$0.isTerminal {
            $0.state = .outcomeUnknown
            $0.completedAt = Date()
          }
        }
      }
      throw error
    }
  }

  package func startToolCall(
    server: MCPServerConfig,
    name: String,
    arguments: JSONValue,
    requestID: String
  ) throws -> JSONValue {
    guard let object = arguments.objectValue else {
      throw GatewayToolError.invalidArguments(
        "Downstream MCP tool arguments must be an object."
      )
    }
    guard !requestID.isEmpty else {
      throw GatewayToolError.invalidArguments(
        "Downstream MCP request id must not be empty."
      )
    }

    let reservation = try journal.reserve(
      server: server, tool: name, arguments: arguments, requestID: requestID)
    if !reservation.inserted {
      return try reservation.record.snapshot(instance: journal.instanceID)
    }
    do {
      return try run(server: server) { connection in
        try await connection.startToolCall(
          name: name, arguments: object, gatewayRequestID: requestID)
      }
    } catch {
      try journal.update(serverID: server.id, requestID: requestID) {
        $0.state = .outcomeUnknown
        $0.completedAt = Date()
      }
      throw error
    }
  }

  package func readRequest(
    server: MCPServerConfig, requestID: String, offset: Int, maxBytes: Int
  ) throws -> JSONValue {
    try journal.read(serverID: server.id, requestID: requestID)
      .snapshot(instance: journal.instanceID, offset: offset, maxBytes: maxBytes)
  }

  package func listResources(server: MCPServerConfig, cursor: String?) throws -> JSONValue {
    try run(server: server) { connection in
      try await connection.listResources(cursor: cursor)
    }
  }

  package func listResourceTemplates(server: MCPServerConfig, cursor: String?) throws -> JSONValue {
    try run(server: server) { connection in
      try await connection.listResourceTemplates(cursor: cursor)
    }
  }

  package func readResource(server: MCPServerConfig, uri: String) throws -> JSONValue {
    try run(server: server) { connection in
      try await connection.readResource(uri: uri)
    }
  }

  package func listPrompts(server: MCPServerConfig, cursor: String?) throws -> JSONValue {
    try run(server: server) { connection in
      try await connection.listPrompts(cursor: cursor)
    }
  }

  package func getPrompt(
    server: MCPServerConfig,
    name: String,
    arguments: [String: String]?
  ) throws -> JSONValue {
    try run(server: server) { connection in
      try await connection.getPrompt(name: name, arguments: arguments)
    }
  }

  package func connectionStatus(server: MCPServerConfig) throws -> JSONValue {
    guard server.enabled else { return .object(["state": .string("disabled")]) }
    guard let connection = pool.existingConnection(for: server) else {
      return .object([
        "state": .string(pool.inactiveState(serverID: server.id)),
        "persistent_session": .bool(true),
        "active_requests": .number(0),
        "latest_event_cursor": .number(0),
      ])
    }
    return try runExisting(server: server, connection: connection) { connection in
      await connection.status()
    }
  }

  package func readEvents(
    server: MCPServerConfig,
    afterCursor: Int,
    maxResults: Int
  ) throws -> JSONValue {
    try readEvents(server: server, afterCursor: afterCursor, maxResults: maxResults, sessionID: nil)
  }

  package func readEvents(
    server: MCPServerConfig, afterCursor: Int, maxResults: Int, sessionID: String?
  ) throws -> JSONValue {
    guard afterCursor >= 0, (1...500).contains(maxResults), sessionID?.isEmpty != true else {
      throw GatewayToolError.invalidArguments(
        "after_cursor must be nonnegative, max_results must be 1...500, and session_id must not be empty."
      )
    }
    guard let connection = pool.existingConnection(for: server) else {
      guard afterCursor == 0, sessionID == nil else {
        throw GatewayToolError.invalidArguments(
          "[cursor.session_unavailable] The original MCP event session is unavailable. No connection was started and the missing event count is unknown."
        )
      }
      let state = pool.inactiveState(serverID: server.id)
      return .object([
        "server": .string(server.id), "state": .string(state),
        "session_id": .null, "session_verified": .bool(false),
        "cursor_state": .string(state == "not_started" ? "not_started" : "unavailable"),
        "reset_required": .bool(false),
        "after_cursor": .number(0), "next_cursor": .number(0),
        "oldest_available_cursor": .null, "latest_event_cursor": .null,
        "events": .array([]), "has_more": .bool(false), "missed_events": .null,
        "persistent_session": .bool(true),
      ])
    }
    return try runExisting(server: server, connection: connection) { connection in
      try await connection.readEvents(
        afterCursor: afterCursor, maxResults: maxResults, sessionID: sessionID)
    }
  }

  package func activeRequests(server: MCPServerConfig) throws -> JSONValue {
    guard let connection = pool.existingConnection(for: server) else {
      return .object([
        "server": .string(server.id),
        "requests": .array([]),
        "persistent_session": .bool(true),
      ])
    }
    return try runExisting(server: server, connection: connection) { connection in
      await connection.activeRequestsJSON()
    }
  }

  package func cancelRequest(
    server: MCPServerConfig,
    requestID: String,
    reason: String?
  ) throws -> JSONValue {
    guard let connection = pool.existingConnection(for: server) else {
      throw GatewayToolError.invalidArguments(
        "Downstream MCP server '\(server.id)' has no active session."
      )
    }
    return try runExisting(server: server, connection: connection) { connection in
      try await connection.cancelRequest(
        gatewayRequestID: requestID,
        reason: reason ?? "Cancelled by computer-mcp caller."
      )
    }
  }

  private func run<T: Sendable>(
    server: MCPServerConfig,
    notifyToolsOnConnect: Bool = true,
    operation: @escaping @Sendable (MCPProxyConnection) async throws -> T
  ) throws -> T {
    let connection = try pool.connection(for: server)
    try runExisting(
      server: server, connection: connection,
      timeoutMilliseconds: server.startupTimeoutMs ?? 30_000,
      phase: "startup"
    ) { connection in
      try await connection.ensureConnected(notifyTools: notifyToolsOnConnect)
    }
    return try runExisting(server: server, connection: connection, operation: operation)
  }

  private func runExisting<T: Sendable>(
    server: MCPServerConfig,
    connection: MCPProxyConnection,
    timeoutMilliseconds: Int? = nil,
    phase: String = "request",
    operation: @escaping @Sendable (MCPProxyConnection) async throws -> T
  ) throws -> T {
    let timeout = timeoutMilliseconds ?? server.requestTimeoutMs ?? 30_000
    let box = AsyncOperationBox<T>()
    let task = Task.detached {
      do {
        try Task.checkCancellation()
        box.complete(.success(try await operation(connection)))
      } catch {
        box.complete(.failure(error))
      }
    }

    guard box.wait(timeoutMilliseconds: timeout) else {
      // Retirement owns cancellation delivery and joins it after closing the transport.
      // Cancelling only this bridge would leave an SDK request or a startup task alive.
      pool.invalidate(server: server, connection: connection)
      task.cancel()
      throw GatewayToolError.executionFailed(
        "MCP server '\(server.id)' \(phase) timed out."
      )
    }

    do {
      return try box.get()
    } catch {
      if phase == "startup" || Self.requiresRetirement(error) {
        pool.invalidate(server: server, connection: connection)
      }
      throw error
    }
  }

  private static func requiresRetirement(_ error: any Error) -> Bool {
    // A rejected or explicitly cancelled request does not revoke other requests
    // on the same session. Startup, timeouts and transport failures still retire it.
    if error is CancellationError { return false }
    if let error = error as? GatewayToolError, case .invalidArguments = error { return false }
    if let error = error as? MCPError {
      switch error {
      case .methodNotFound, .invalidParams, .serverError, .urlElicitationRequired:
        return false
      case .parseError, .invalidRequest, .internalError, .connectionClosed, .transportError:
        // The pinned SDK also uses internalError for local disconnects. Without
        // provenance, these failures cannot establish a reusable session.
        return true
      }
    }
    return true
  }
}

private final class MCPConnectionPool: @unchecked Sendable {
  private struct Entry {
    let configuration: MCPServerConfig
    let connection: MCPProxyConnection
  }

  private let lock = NSLock()
  private var entries: [String: Entry] = [:]
  private var stopped = false
  private struct Retirement {
    let id: UUID
    let task: Task<Bool, Never>
    var failed = false
  }
  private var retirements: [String: Retirement] = [:]
  private var shutdownTask: Task<Void, Never>?
  private let workingDirectory: URL
  private let environment: [String: String]
  private let hostContext: MCPHostContext?
  private let secretStore: KeychainSecretStore?
  private let journal: MCPExecutionJournal
  private let toolsChanged: @Sendable () -> Void

  init(
    workingDirectory: URL, environment: [String: String],
    hostContext: MCPHostContext?,
    secretStore: KeychainSecretStore?, journal: MCPExecutionJournal,
    toolsChanged: @escaping @Sendable () -> Void
  ) {
    self.workingDirectory = workingDirectory
    self.environment = environment
    self.hostContext = hostContext
    self.secretStore = secretStore
    self.journal = journal
    self.toolsChanged = toolsChanged
  }

  func connection(for server: MCPServerConfig) throws -> MCPProxyConnection {
    guard server.enabled else {
      throw GatewayToolError.disabled("MCP registration '\(server.id)' is disabled.")
    }
    lock.lock()
    defer { lock.unlock() }
    guard !stopped else {
      throw GatewayToolError.disabled("The downstream MCP client is stopped.")
    }
    if let entry = entries[server.id], entry.configuration == server {
      return entry.connection
    }
    if let replaced = entries.removeValue(forKey: server.id) {
      retireLocked(serverID: server.id, connection: replaced.connection)
    }
    let connection = try MCPProxyConnection(
      server: server, workingDirectory: workingDirectory, environment: environment,
      hostContext: hostContext, secretStore: secretStore, journal: journal,
      predecessor: retirements[server.id]?.task,
      onTermination: { [weak self] connection in
        self?.invalidate(server: server, connection: connection)
      },
      toolsChanged: toolsChanged)
    entries[server.id] = Entry(configuration: server, connection: connection)
    return connection
  }

  func existingConnection(for server: MCPServerConfig) -> MCPProxyConnection? {
    lock.lock()
    defer { lock.unlock() }
    guard !stopped, let entry = entries[server.id], entry.configuration == server else {
      return nil
    }
    return entry.connection
  }

  func invalidate(server: MCPServerConfig, connection: MCPProxyConnection) {
    lock.lock()
    guard let entry = entries[server.id],
      entry.configuration == server,
      entry.connection === connection
    else {
      lock.unlock()
      return
    }
    entries.removeValue(forKey: server.id)
    retireLocked(serverID: server.id, connection: connection)
    lock.unlock()
  }

  private func retireLocked(serverID: String, connection: MCPProxyConnection) {
    let id = UUID()
    let task = Task { [weak self] in
      let confirmed = await connection.disconnect()
      // A failed retirement remains a barrier: a new process must not overlap it.
      self?.finishRetirement(serverID: serverID, id: id, confirmed: confirmed)
      return confirmed
    }
    retirements[serverID] = Retirement(id: id, task: task)
  }

  private func finishRetirement(serverID: String, id: UUID, confirmed: Bool) {
    lock.withLock {
      guard retirements[serverID]?.id == id else { return }
      if confirmed {
        retirements.removeValue(forKey: serverID)
      } else {
        retirements[serverID]?.failed = true
      }
    }
  }

  func inactiveState(serverID: String) -> String {
    lock.withLock {
      if let retirement = retirements[serverID] {
        return retirement.failed ? "cleanup_failed" : "retiring"
      }
      return stopped ? "stopped" : "not_started"
    }
  }

  func shutdown() -> Task<Void, Never> {
    lock.withLock {
      if let shutdownTask { return shutdownTask }
      stopped = true
      for (serverID, entry) in entries {
        retireLocked(serverID: serverID, connection: entry.connection)
      }
      let retired = retirements.values.map(\.task)
      entries.removeAll()
      let task = Task {
        await withTaskGroup(of: Void.self) { group in
          for task in retired { group.addTask { _ = await task.value } }
        }
      }
      shutdownTask = task
      return task
    }
  }
}

private actor MCPProxyConnection {
  private struct Event: Sendable {
    let cursor: Int
    let kind: String
    let timestamp: Date
    let requestID: String?

    var json: JSONValue {
      .object([
        "cursor": .number(Double(cursor)),
        "kind": .string(kind),
        "timestamp": .number(timestamp.timeIntervalSince1970),
        "request_id": requestID.map(JSONValue.string) ?? .null,
      ])
    }
  }

  private struct ActiveRequest: Sendable {
    let gatewayRequestID: String
    let downstreamRequestID: MCP.ID
    let tool: String
    let startedAt: Date
    var retainsResult = false
    var cancellationRequested = false

    var json: JSONValue {
      .object([
        "request_id": .string(gatewayRequestID),
        "downstream_request_id": .string(downstreamRequestID.description),
        "tool": .string(tool),
        "started_at": .number(startedAt.timeIntervalSince1970),
        "state": .string(cancellationRequested ? "cancellation_requested" : "running"),
      ])
    }
  }

  private let server: MCPServerConfig
  private let journal: MCPExecutionJournal
  private let onTermination: @Sendable (MCPProxyConnection) -> Void
  private let client: MCP.Client
  private let transport: any MCP.Transport
  // Retain the single initialization attempt until retirement, including a failed attempt.
  private var connectTask: Task<Initialize.Result, Error>?
  private var terminationObserver: Task<Void, Never>?
  private var closeTask: Task<Bool, Never>?
  private let predecessor: Task<Bool, Never>?
  private var observers: [MCP.ID: Task<Void, Never>] = [:]
  private var reservedRequestIDs: Set<String> = []
  private var initializeResult: Initialize.Result?
  private var handlersRegistered = false
  private var connected = false
  private var lastError: String?
  private var events: [Event] = []
  private let eventSessionID = UUID().uuidString
  private var nextEventCursor = 1
  private var activeRequests: [String: ActiveRequest] = [:]
  private let toolsChanged: @Sendable () -> Void

  init(
    server: MCPServerConfig, workingDirectory: URL, environment: [String: String],
    hostContext: MCPHostContext?,
    secretStore: KeychainSecretStore?, journal: MCPExecutionJournal,
    predecessor: Task<Bool, Never>? = nil,
    onTermination: @escaping @Sendable (MCPProxyConnection) -> Void,
    toolsChanged: @escaping @Sendable () -> Void
  ) throws {
    self.server = server
    self.journal = journal
    self.predecessor = predecessor
    self.toolsChanged = toolsChanged
    self.onTermination = onTermination
    client = MCP.Client(
      name: "computer-mcp-gateway",
      version: ComputerMCPCLI.version
    )
    transport = try Self.makeTransport(
      server: server, workingDirectory: workingDirectory, environment: environment,
      hostContext: hostContext, secretStore: secretStore)
  }

  func listTools() async throws -> [MCPTool] {
    try await ensureConnected(notifyTools: false)
    let tools = try await MCPToolCatalogLoader.load { [client] cursor in
      try await client.listTools(cursor: cursor)
    }
    return tools.map { tool in
      MCPTool(
        name: tool.name,
        title: tool.title,
        description: tool.description ?? "",
        inputSchema: JSONValue(sdkValue: tool.inputSchema),
        outputSchema: tool.outputSchema.map(JSONValue.init(sdkValue:)),
        annotations: tool.annotations.isEmpty
          ? nil
          : MCPToolAnnotations(
            readOnlyHint: tool.annotations.readOnlyHint,
            destructiveHint: tool.annotations.destructiveHint,
            idempotentHint: tool.annotations.idempotentHint,
            openWorldHint: tool.annotations.openWorldHint
          ),
        meta: tool._meta.map { .object($0.fields.mapValues(JSONValue.init(sdkValue:))) }
      )
    }
  }

  func callTool(
    name: String,
    arguments: [String: JSONValue],
    gatewayRequestID: String,
    cancellation: MCPCallCancellation? = nil,
    retainsResult: Bool = false,
    cancellationDeliveryFailed: @escaping @Sendable () -> Void = {}
  ) async throws -> JSONValue {
    try await ensureConnected()
    try cancellation?.checkCancellation()
    // Reserve before crossing into the SDK actor so concurrent calls cannot
    // dispatch the same gateway identity while its native request is being created.
    guard activeRequests[gatewayRequestID] == nil,
      reservedRequestIDs.insert(gatewayRequestID).inserted
    else {
      throw GatewayToolError.invalidArguments(
        "Downstream MCP request id '\(gatewayRequestID)' is already active."
      )
    }
    defer { reservedRequestIDs.remove(gatewayRequestID) }

    let context: RequestContext<CallTool.Result> = try await client.callTool(
      name: name,
      arguments: arguments.mapValues(\.sdkValue)
    )
    guard closeTask == nil else {
      try? await client.cancelRequest(context.requestID, reason: "Downstream MCP session retired.")
      throw MCPError.connectionClosed
    }
    activeRequests[gatewayRequestID] = ActiveRequest(
      gatewayRequestID: gatewayRequestID,
      downstreamRequestID: context.requestID,
      tool: name,
      startedAt: Date(), retainsResult: retainsResult
    )
    if retainsResult {
      try journal.update(serverID: server.id, requestID: gatewayRequestID) {
        $0.state = .running
        $0.downstreamRequestID = context.requestID.description
      }
    }
    cancellation?.install(onDeliveryFailure: cancellationDeliveryFailed) {
      [client, journal, server] in
      if retainsResult {
        try journal.update(serverID: server.id, requestID: gatewayRequestID) {
          $0.cancellation = "requested"
        }
      }
      do {
        try await client.cancelRequest(context.requestID, reason: "Upstream MCP request cancelled.")
        if retainsResult {
          try journal.update(serverID: server.id, requestID: gatewayRequestID) {
            $0.cancellation = "sent"
          }
        }
      } catch {
        if retainsResult {
          try? journal.update(serverID: server.id, requestID: gatewayRequestID) {
            $0.cancellation = "failed"
          }
        }
        throw error
      }
    }
    defer {
      if activeRequests[gatewayRequestID]?.downstreamRequestID == context.requestID {
        activeRequests.removeValue(forKey: gatewayRequestID)
      }
    }

    let result = try await context.value
    let value = try JSONValue.sdkToolResult(
      content: result.content,
      structuredContent: result.structuredContent,
      isError: result.isError,
      meta: result._meta
    )
    if retainsResult {
      try journal.update(serverID: server.id, requestID: gatewayRequestID) {
        try $0.finish(result: value, failed: result.isError == true)
      }
    }
    try cancellation?.checkCancellation()
    return value
  }

  func startToolCall(
    name: String,
    arguments: [String: JSONValue],
    gatewayRequestID: String
  ) async throws -> JSONValue {
    try await ensureConnected()
    // Reserve before crossing into the SDK actor so concurrent calls cannot
    // dispatch the same gateway identity while its native request is being created.
    guard activeRequests[gatewayRequestID] == nil,
      reservedRequestIDs.insert(gatewayRequestID).inserted
    else {
      throw GatewayToolError.invalidArguments(
        "Downstream MCP request id '\(gatewayRequestID)' is already active."
      )
    }
    defer { reservedRequestIDs.remove(gatewayRequestID) }

    let context: RequestContext<CallTool.Result> = try await client.callTool(
      name: name,
      arguments: arguments.mapValues(\.sdkValue)
    )
    guard closeTask == nil else {
      try? await client.cancelRequest(context.requestID, reason: "Downstream MCP session retired.")
      throw MCPError.connectionClosed
    }
    let active = ActiveRequest(
      gatewayRequestID: gatewayRequestID,
      downstreamRequestID: context.requestID,
      tool: name,
      startedAt: Date(), retainsResult: true
    )
    activeRequests[gatewayRequestID] = active
    try journal.update(serverID: server.id, requestID: gatewayRequestID) {
      $0.state = .running
      $0.downstreamRequestID = context.requestID.description
    }
    appendEvent(kind: "request.started", requestID: gatewayRequestID)

    observers[context.requestID] = Task { [weak self] in
      do {
        let result = try await context.value
        let value = try JSONValue.sdkToolResult(
          content: result.content, structuredContent: result.structuredContent,
          isError: result.isError, meta: result._meta)
        await self?.finishStartedRequest(
          gatewayRequestID: gatewayRequestID, downstreamRequestID: context.requestID,
          kind: result.isError == true ? "request.error_result" : "request.completed",
          result: value, failed: result.isError == true
        )
      } catch is CancellationError {
        await self?.finishStartedRequest(
          gatewayRequestID: gatewayRequestID, downstreamRequestID: context.requestID,
          kind: "request.outcome_unknown"
        )
      } catch {
        await self?.finishStartedRequest(
          gatewayRequestID: gatewayRequestID, downstreamRequestID: context.requestID,
          kind: "request.outcome_unknown"
        )
      }
    }

    return .object([
      "server": .string(server.id),
      "tool": .string(name),
      "request_id": .string(gatewayRequestID),
      "downstream_request_id": .string(context.requestID.description),
      "state": .string("running"),
      "wait_for_result": .bool(false),
      "started_at": .number(active.startedAt.timeIntervalSince1970),
    ])
  }

  func listResources(cursor: String?) async throws -> JSONValue {
    try await ensureConnected()
    let result = try await client.listResources(cursor: cursor)
    return .object([
      "resources": .array(try result.resources.map { try JSONValue.encoded($0) }),
      "nextCursor": result.nextCursor.map(JSONValue.string) ?? .null,
    ])
  }

  func listResourceTemplates(cursor: String?) async throws -> JSONValue {
    try await ensureConnected()
    let result = try await client.listResourceTemplates(cursor: cursor)
    return .object([
      "resourceTemplates": .array(try result.templates.map { try JSONValue.encoded($0) }),
      "nextCursor": result.nextCursor.map(JSONValue.string) ?? .null,
    ])
  }

  func readResource(uri: String) async throws -> JSONValue {
    try await ensureConnected()
    let contents = try await client.readResource(uri: uri)
    return .object([
      "contents": .array(try contents.map { try JSONValue.encoded($0) })
    ])
  }

  func listPrompts(cursor: String?) async throws -> JSONValue {
    try await ensureConnected()
    let result = try await client.listPrompts(cursor: cursor)
    return .object([
      "prompts": .array(try result.prompts.map { try JSONValue.encoded($0) }),
      "nextCursor": result.nextCursor.map(JSONValue.string) ?? .null,
    ])
  }

  func getPrompt(name: String, arguments: [String: String]?) async throws -> JSONValue {
    try await ensureConnected()
    let result = try await client.getPrompt(name: name, arguments: arguments)
    return .object([
      "description": result.description.map(JSONValue.string) ?? .null,
      "messages": .array(try result.messages.map { try JSONValue.encoded($0) }),
    ])
  }

  func status() -> JSONValue {
    .object([
      "state": .string(
        connected ? "connected" : connectTask == nil ? "not_connected" : "connecting"
      ),
      "persistent_session": .bool(true),
      "active_requests": .number(Double(activeRequests.count)),
      "latest_event_cursor": .number(Double(nextEventCursor - 1)),
      "last_error": lastError.map(JSONValue.string) ?? .null,
      "initialize": initializeResult.flatMap { try? JSONValue.encoded($0) } ?? .null,
    ])
  }

  func readEvents(afterCursor: Int, maxResults: Int, sessionID: String?) throws -> JSONValue {
    guard afterCursor >= 0 else {
      throw GatewayToolError.invalidArguments("after_cursor must be zero or greater.")
    }
    guard (1...500).contains(maxResults) else {
      throw GatewayToolError.invalidArguments("max_results must be between 1 and 500.")
    }
    guard sessionID == nil || sessionID == eventSessionID else {
      throw GatewayToolError.invalidArguments(
        "[cursor.session_mismatch] This cursor belongs to another MCP session. Read from after_cursor 0 without session_id to obtain the current retained range."
      )
    }
    guard afterCursor < nextEventCursor else {
      throw GatewayToolError.invalidArguments(
        "[cursor.out_of_range] after_cursor exceeds the latest event in this MCP session.")
    }
    let oldestCursor = events.first?.cursor ?? nextEventCursor
    let missedEvents = max(0, oldestCursor - afterCursor - 1)
    let selected = events.filter { $0.cursor > afterCursor }.prefix(maxResults)
    let nextCursor = selected.last?.cursor ?? max(afterCursor, nextEventCursor - 1)
    return .object([
      "server": .string(server.id),
      "session_id": .string(eventSessionID),
      "session_verified": .bool(sessionID != nil),
      "cursor_state": .string(
        missedEvents > 0 ? "truncated" : (sessionID != nil ? "valid" : "unbound")),
      "reset_required": .bool(false),
      "after_cursor": .number(Double(afterCursor)),
      "next_cursor": .number(Double(nextCursor)),
      "oldest_available_cursor": .number(Double(oldestCursor)),
      "latest_event_cursor": .number(Double(nextEventCursor - 1)),
      "events": .array(selected.map(\.json)),
      "missed_events": .number(Double(missedEvents)),
      "has_more": .bool(nextCursor < nextEventCursor - 1),
      "persistent_session": .bool(true),
    ])
  }

  func activeRequestsJSON() -> JSONValue {
    .object([
      "server": .string(server.id),
      "requests": .array(
        activeRequests.values.sorted { $0.gatewayRequestID < $1.gatewayRequestID }.map(\.json)
      ),
      "persistent_session": .bool(true),
    ])
  }

  func cancelRequest(gatewayRequestID: String, reason: String) async throws -> JSONValue {
    guard var active = activeRequests[gatewayRequestID] else {
      throw GatewayToolError.invalidArguments(
        "Unknown active downstream MCP request id: \(gatewayRequestID)"
      )
    }
    if !active.cancellationRequested {
      let observesResponse = observers[active.downstreamRequestID] != nil
      active.cancellationRequested = true
      activeRequests[gatewayRequestID] = active
      appendEvent(kind: "request.cancellation_requested", requestID: gatewayRequestID)
      do {
        if active.retainsResult {
          try journal.update(serverID: server.id, requestID: gatewayRequestID) {
            $0.cancellation = "requested"
          }
        }
        if observesResponse {
          // A detached call remains observable after a stop request. A native
          // response can establish its outcome, but notification delivery cannot.
          try await client.notify(
            CancelledNotification.message(
              .init(requestId: active.downstreamRequestID, reason: reason)))
        } else {
          // End the synchronous wait without claiming that remote execution ended.
          try await client.cancelRequest(active.downstreamRequestID, reason: reason)
        }
        if active.retainsResult {
          try journal.update(serverID: server.id, requestID: gatewayRequestID) {
            $0.cancellation = "sent"
          }
        }
        appendEvent(kind: "request.cancellation_sent", requestID: gatewayRequestID)
      } catch {
        if activeRequests[gatewayRequestID]?.downstreamRequestID == active.downstreamRequestID {
          activeRequests[gatewayRequestID]?.cancellationRequested = false
        }
        appendEvent(kind: "request.cancellation_failed", requestID: gatewayRequestID)
        if active.retainsResult {
          try? journal.update(serverID: server.id, requestID: gatewayRequestID) {
            $0.cancellation = "failed"
          }
        }
        throw error
      }
    }
    return .object([
      "server": .string(server.id),
      "request_id": .string(gatewayRequestID),
      "cancellation_requested": .bool(true),
      "execution_stopped": .null,
    ])
  }

  private func finishStartedRequest(
    gatewayRequestID: String, downstreamRequestID: MCP.ID, kind: String,
    result: JSONValue? = nil, failed: Bool = false
  ) {
    observers.removeValue(forKey: downstreamRequestID)
    // Only the matching native request may end this gateway request's observation.
    guard activeRequests[gatewayRequestID]?.downstreamRequestID == downstreamRequestID else {
      return
    }
    activeRequests.removeValue(forKey: gatewayRequestID)
    do {
      try journal.update(serverID: server.id, requestID: gatewayRequestID) {
        if let result {
          try $0.finish(result: result, failed: failed)
        } else {
          $0.state = .outcomeUnknown
          $0.completedAt = Date()
        }
      }
      appendEvent(kind: kind, requestID: gatewayRequestID)
    } catch {
      lastError = "The execution outcome could not be persisted; do not replay this request."
      appendEvent(kind: "request.storage_failed", requestID: gatewayRequestID)
    }
  }

  func disconnect() async -> Bool {
    if let closeTask { return await closeTask.value }
    let startup = connectTask
    let terminationObserver = terminationObserver
    startup?.cancel()
    let requests = Array(activeRequests.values)
    let observers = Array(observers.values)
    let retainedRequests = requests.filter(\.retainsResult)
    connected = false
    for request in retainedRequests {
      do {
        try journal.update(serverID: server.id, requestID: request.gatewayRequestID) {
          $0.state = .outcomeUnknown
          $0.completedAt = Date()
          $0.cleanup = "pending"
        }
      } catch { lastError = "Execution receipt storage failed during disconnect." }
    }
    activeRequests.removeAll()
    let task = Task { [client, transport, predecessor] in
      let cancellation = Task {
        for request in requests {
          try? await client.cancelRequest(
            request.downstreamRequestID, reason: "Downstream MCP session disconnected.")
        }
      }
      // Delivery is acknowledged by the transport write, not an arbitrary delay. A
      // blocked pipe still has a finite flush budget and is unblocked by teardown.
      let deliveryObserver = await Self.waitForCancellationDelivery(cancellation)
      await client.disconnect()
      await transport.disconnect()
      await terminationObserver?.value
      _ = await startup?.result
      // SDK startup may have been suspended in transport.connect at the first close.
      await client.disconnect()
      await cancellation.value
      await deliveryObserver.value
      for observer in observers { await observer.value }
      let predecessorExited = await predecessor?.value ?? true
      let processExited: Bool
      if let child = transport as? MCPChildProcessTransport {
        processExited = await child.shutdownConfirmed()
      } else {
        processExited = true
      }
      return predecessorExited && processExited
    }
    closeTask = task
    let confirmed = await task.value
    for request in retainedRequests {
      do {
        try journal.update(serverID: server.id, requestID: request.gatewayRequestID) {
          $0.cleanup = transport is MCPChildProcessTransport && confirmed ? "confirmed" : "unknown"
        }
      } catch { lastError = "Execution cleanup could not be persisted." }
    }
    connectTask = nil
    self.terminationObserver = nil
    self.observers.removeAll()
    if !confirmed { lastError = "An owned downstream process has not confirmed exit." }
    appendEvent(kind: confirmed ? "connection.disconnected" : "connection.cleanup_failed")
    return confirmed
  }

  private static func waitForCancellationDelivery(_ delivery: Task<Void, Never>) async
    -> Task<Void, Never>
  {
    let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let delivered = Task {
      await delivery.value
      continuation.yield(())
    }
    let deadline = Task {
      do {
        try await Task.sleep(for: .milliseconds(250))
        continuation.yield(())
      } catch {}
    }
    for await _ in events { break }
    continuation.finish()
    deadline.cancel()
    await deadline.value
    return delivered
  }

  func ensureConnected(notifyTools: Bool = true) async throws {
    try Task.checkCancellation()
    guard closeTask == nil else { throw MCPError.connectionClosed }
    if let predecessor, !(await predecessor.value) {
      throw GatewayToolError.executionFailed(
        "Previous MCP process has not confirmed exit; reconnect is blocked.")
    }
    try Task.checkCancellation()
    guard closeTask == nil else { throw MCPError.connectionClosed }
    if connected {
      return
    }

    if !handlersRegistered {
      await registerNotificationHandlers()
      guard closeTask == nil else { throw MCPError.connectionClosed }
      handlersRegistered = true
    }

    let task: Task<Initialize.Result, Error>
    if let connectTask {
      task = connectTask
    } else {
      let client = client
      let transport = transport
      if let child = transport as? MCPChildProcessTransport {
        // Retiring the exact generation clears stale status and resolves SDK
        // requests after owned cleanup, outside the transport reader.
        let onTermination = onTermination
        terminationObserver = Task { [weak self] in
          for await _ in child.termination {}
          if let self { onTermination(self) }
        }
      }
      task = Task {
        try Task.checkCancellation()
        return try await client.connect(transport: transport)
      }
      connectTask = task
    }

    do {
      let result = try await task.value
      try Task.checkCancellation()
      guard closeTask == nil else { throw MCPError.connectionClosed }
      if !connected {
        initializeResult = result
        connected = true
        lastError = nil
        appendEvent(kind: "connection.connected")
        if notifyTools { toolsChanged() }
      }
    } catch {
      connected = false
      lastError = String(describing: error)
      appendEvent(kind: "connection.failed")
      throw error
    }
  }

  private func registerNotificationHandlers() async {
    await client.onNotification(ToolListChangedNotification.self) { [weak self] _ in
      await self?.receiveToolListChange()
    }
    await client.onNotification(ResourceListChangedNotification.self) { [weak self] _ in
      await self?.appendEvent(kind: ResourceListChangedNotification.name)
    }
    await client.onNotification(PromptListChangedNotification.self) { [weak self] _ in
      await self?.appendEvent(kind: PromptListChangedNotification.name)
    }
  }

  private func receiveToolListChange() {
    guard closeTask == nil else { return }
    appendEvent(kind: ToolListChangedNotification.name)
    toolsChanged()
  }

  private func appendEvent(kind: String, requestID: String? = nil) {
    events.append(
      Event(cursor: nextEventCursor, kind: kind, timestamp: Date(), requestID: requestID))
    nextEventCursor += 1
    if events.count > 512 {
      events.removeFirst(events.count - 512)
    }
  }

  private static func makeTransport(
    server: MCPServerConfig, workingDirectory: URL, environment: [String: String],
    hostContext: MCPHostContext?, secretStore: KeychainSecretStore?
  ) throws -> any MCP.Transport {
    try server.authentication?.validate(endpoint: server.url, transport: server.transport)
    switch server.transport {
    case .stdio:
      return try MCPChildProcessTransport(
        server: server, workingDirectory: workingDirectory, environment: environment,
        hostContext: hostContext)

    case .streamableHTTP, .sse, .http:
      guard let urlString = server.url, let url = URL(string: urlString) else {
        throw GatewayToolError.executionFailed(
          "MCP server '\(server.id)' has no valid url."
        )
      }
      return MCPHTTPClientTransport(
        endpoint: url, streaming: server.transport != .http,
        bearerToken: { try await server.authentication?.bearerToken(from: secretStore) })
    }
  }
}

private final class AsyncOperationBox<T: Sendable>: @unchecked Sendable {
  private let semaphore = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var result: Result<T, Error>?

  func complete(_ result: Result<T, Error>) {
    lock.lock()
    guard self.result == nil else {
      lock.unlock()
      return
    }
    self.result = result
    lock.unlock()
    semaphore.signal()
  }

  func wait(timeoutMilliseconds: Int) -> Bool {
    semaphore.wait(timeout: .now() + .milliseconds(timeoutMilliseconds)) == .success
  }

  func get() throws -> T {
    lock.lock()
    defer { lock.unlock() }
    return try result!.get()
  }
}
