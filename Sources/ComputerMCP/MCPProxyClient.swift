import Foundation
import MCP

/// Proxies configured downstream servers through persistent MCP SDK sessions.
package final class MCPProxyClient: DownstreamMCPClient, @unchecked Sendable {
  private let pool = MCPConnectionPool()

  package init() {}

  deinit {
    pool.disconnectAll()
  }

  package func listTools(server: MCPServerConfig) throws -> [MCPTool] {
    try run(server: server) { connection in
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
    guard let object = arguments.objectValue else {
      throw GatewayToolError.invalidArguments(
        "Downstream MCP tool arguments must be an object."
      )
    }

    let requestID = requestID ?? UUID().uuidString
    return try run(server: server) { connection in
      try await connection.callTool(
        name: name,
        arguments: object,
        gatewayRequestID: requestID
      )
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

    return try run(server: server) { connection in
      try await connection.startToolCall(
        name: name,
        arguments: object,
        gatewayRequestID: requestID
      )
    }
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
    guard let connection = pool.existingConnection(for: server) else {
      return .object([
        "state": .string("not_started"),
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
    try run(server: server) { connection in
      try await connection.readEvents(afterCursor: afterCursor, maxResults: maxResults)
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
    operation: @escaping @Sendable (MCPProxyConnection) async throws -> T
  ) throws -> T {
    let connection = try pool.connection(for: server)
    return try runExisting(server: server, connection: connection, operation: operation)
  }

  private func runExisting<T: Sendable>(
    server: MCPServerConfig,
    connection: MCPProxyConnection,
    operation: @escaping @Sendable (MCPProxyConnection) async throws -> T
  ) throws -> T {
    let timeout = server.requestTimeoutMs ?? server.startupTimeoutMs ?? 30_000
    let box = AsyncOperationBox<T>()
    let task = Task.detached {
      do {
        box.complete(.success(try await operation(connection)))
      } catch {
        box.complete(.failure(error))
      }
    }

    guard box.wait(timeoutMilliseconds: timeout) else {
      task.cancel()
      pool.invalidate(server: server, connection: connection)
      throw GatewayToolError.executionFailed(
        "MCP server '\(server.id)' request timed out."
      )
    }

    do {
      return try box.get()
    } catch {
      pool.invalidate(server: server, connection: connection)
      throw error
    }
  }
}

private final class MCPConnectionPool: @unchecked Sendable {
  private struct Entry {
    let configuration: MCPServerConfig
    let connection: MCPProxyConnection
  }

  private let lock = NSLock()
  private var entries: [String: Entry] = [:]

  func connection(for server: MCPServerConfig) throws -> MCPProxyConnection {
    lock.lock()
    if let entry = entries[server.id], entry.configuration == server {
      lock.unlock()
      return entry.connection
    }

    do {
      let connection = try MCPProxyConnection(server: server)
      let replaced = entries.updateValue(
        Entry(configuration: server, connection: connection),
        forKey: server.id
      )
      lock.unlock()
      if let replaced {
        Task {
          await replaced.connection.disconnect()
        }
      }
      return connection
    } catch {
      lock.unlock()
      throw error
    }
  }

  func existingConnection(for server: MCPServerConfig) -> MCPProxyConnection? {
    lock.lock()
    defer { lock.unlock() }
    guard let entry = entries[server.id], entry.configuration == server else {
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
    lock.unlock()
    Task {
      // Let an in-flight SDK cancellation handler flush notifications/cancelled
      // before the stale transport is torn down.
      try? await Task.sleep(for: .milliseconds(50))
      await connection.disconnect()
    }
  }

  func disconnectAll() {
    lock.lock()
    let connections = entries.values.map(\.connection)
    entries.removeAll()
    lock.unlock()
    for connection in connections {
      Task {
        await connection.disconnect()
      }
    }
  }
}

private actor MCPProxyConnection {
  private struct Event: Sendable {
    let cursor: Int
    let kind: String
    let timestamp: Date

    var json: JSONValue {
      .object([
        "cursor": .number(Double(cursor)),
        "kind": .string(kind),
        "timestamp": .number(timestamp.timeIntervalSince1970),
      ])
    }
  }

  private struct ActiveRequest: Sendable {
    let gatewayRequestID: String
    let downstreamRequestID: MCP.ID
    let tool: String
    let startedAt: Date

    var json: JSONValue {
      .object([
        "request_id": .string(gatewayRequestID),
        "downstream_request_id": .string(downstreamRequestID.description),
        "tool": .string(tool),
        "started_at": .number(startedAt.timeIntervalSince1970),
      ])
    }
  }

  private let server: MCPServerConfig
  private let client: MCP.Client
  private let transport: any MCP.Transport
  private var connectTask: Task<Initialize.Result, Error>?
  private var initializeResult: Initialize.Result?
  private var handlersRegistered = false
  private var connected = false
  private var lastError: String?
  private var events: [Event] = []
  private var nextEventCursor = 1
  private var activeRequests: [String: ActiveRequest] = [:]

  init(server: MCPServerConfig) throws {
    self.server = server
    client = MCP.Client(
      name: "computer-mcp-gateway",
      version: ComputerMCPCLI.version
    )
    transport = try Self.makeTransport(server: server)
  }

  func listTools() async throws -> [MCPTool] {
    try await ensureConnected()
    let result = try await client.listTools()
    return result.tools.map { tool in
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
    gatewayRequestID: String
  ) async throws -> JSONValue {
    try await ensureConnected()
    guard activeRequests[gatewayRequestID] == nil else {
      throw GatewayToolError.invalidArguments(
        "Downstream MCP request id '\(gatewayRequestID)' is already active."
      )
    }

    let context: RequestContext<CallTool.Result> = try await client.callTool(
      name: name,
      arguments: arguments.mapValues(\.sdkValue)
    )
    activeRequests[gatewayRequestID] = ActiveRequest(
      gatewayRequestID: gatewayRequestID,
      downstreamRequestID: context.requestID,
      tool: name,
      startedAt: Date()
    )

    do {
      let result = try await withTaskCancellationHandler {
        try await context.value
      } onCancel: {
        Task {
          try? await self.cancelRequest(
            gatewayRequestID: gatewayRequestID,
            reason: "Gateway request cancelled."
          )
        }
      }
      activeRequests.removeValue(forKey: gatewayRequestID)
      return try JSONValue.sdkToolResult(
        content: result.content,
        structuredContent: result.structuredContent,
        isError: result.isError,
        meta: result._meta
      )
    } catch {
      activeRequests.removeValue(forKey: gatewayRequestID)
      throw error
    }
  }

  func startToolCall(
    name: String,
    arguments: [String: JSONValue],
    gatewayRequestID: String
  ) async throws -> JSONValue {
    try await ensureConnected()
    guard activeRequests[gatewayRequestID] == nil else {
      throw GatewayToolError.invalidArguments(
        "Downstream MCP request id '\(gatewayRequestID)' is already active."
      )
    }

    let context: RequestContext<CallTool.Result> = try await client.callTool(
      name: name,
      arguments: arguments.mapValues(\.sdkValue)
    )
    let active = ActiveRequest(
      gatewayRequestID: gatewayRequestID,
      downstreamRequestID: context.requestID,
      tool: name,
      startedAt: Date()
    )
    activeRequests[gatewayRequestID] = active
    appendEvent(kind: "request.started")

    Task { [weak self] in
      do {
        let result = try await context.value
        await self?.finishStartedRequest(
          gatewayRequestID: gatewayRequestID,
          kind: result.isError == true ? "request.error_result" : "request.completed"
        )
      } catch is CancellationError {
        await self?.finishStartedRequest(
          gatewayRequestID: gatewayRequestID,
          kind: "request.cancelled"
        )
      } catch {
        await self?.finishStartedRequest(
          gatewayRequestID: gatewayRequestID,
          kind: "request.failed"
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

  func readEvents(afterCursor: Int, maxResults: Int) async throws -> JSONValue {
    guard afterCursor >= 0 else {
      throw GatewayToolError.invalidArguments("after_cursor must be zero or greater.")
    }
    guard (1...500).contains(maxResults) else {
      throw GatewayToolError.invalidArguments("max_results must be between 1 and 500.")
    }
    try await ensureConnected()

    let oldestCursor = events.first?.cursor ?? nextEventCursor
    let missedEvents = max(0, oldestCursor - afterCursor - 1)
    let selected = events.filter { $0.cursor > afterCursor }.prefix(maxResults)
    let nextCursor = selected.last?.cursor ?? max(afterCursor, nextEventCursor - 1)
    return .object([
      "server": .string(server.id),
      "after_cursor": .number(Double(afterCursor)),
      "next_cursor": .number(Double(nextCursor)),
      "events": .array(selected.map(\.json)),
      "missed_events": .number(Double(missedEvents)),
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
    guard let active = activeRequests.removeValue(forKey: gatewayRequestID) else {
      throw GatewayToolError.invalidArguments(
        "Unknown active downstream MCP request id: \(gatewayRequestID)"
      )
    }
    try await client.cancelRequest(active.downstreamRequestID, reason: reason)
    appendEvent(kind: "request.cancelled")
    return .object([
      "server": .string(server.id),
      "request_id": .string(gatewayRequestID),
      "cancelled": .bool(true),
      "reason": .string(reason),
    ])
  }

  private func finishStartedRequest(gatewayRequestID: String, kind: String) {
    guard activeRequests.removeValue(forKey: gatewayRequestID) != nil else {
      return
    }
    appendEvent(kind: kind)
  }

  func disconnect() async {
    connectTask?.cancel()
    connectTask = nil
    for request in activeRequests.values {
      try? await client.cancelRequest(
        request.downstreamRequestID,
        reason: "Downstream MCP session disconnected."
      )
    }
    activeRequests.removeAll()
    await client.disconnect()
    await transport.disconnect()
    connected = false
    appendEvent(kind: "connection.disconnected")
  }

  private func ensureConnected() async throws {
    if connected {
      return
    }

    if !handlersRegistered {
      await registerNotificationHandlers()
      handlersRegistered = true
    }

    let task: Task<Initialize.Result, Error>
    if let connectTask {
      task = connectTask
    } else {
      let client = client
      let transport = transport
      task = Task {
        try await client.connect(transport: transport)
      }
      connectTask = task
    }

    do {
      let result = try await task.value
      if !connected {
        initializeResult = result
        connected = true
        lastError = nil
        appendEvent(kind: "connection.connected")
      }
      connectTask = nil
    } catch {
      connectTask = nil
      connected = false
      lastError = String(describing: error)
      appendEvent(kind: "connection.failed")
      throw error
    }
  }

  private func registerNotificationHandlers() async {
    await client.onNotification(ToolListChangedNotification.self) { [weak self] _ in
      await self?.appendEvent(kind: ToolListChangedNotification.name)
    }
    await client.onNotification(ResourceListChangedNotification.self) { [weak self] _ in
      await self?.appendEvent(kind: ResourceListChangedNotification.name)
    }
    await client.onNotification(PromptListChangedNotification.self) { [weak self] _ in
      await self?.appendEvent(kind: PromptListChangedNotification.name)
    }
  }

  private func appendEvent(kind: String) {
    events.append(Event(cursor: nextEventCursor, kind: kind, timestamp: Date()))
    nextEventCursor += 1
    if events.count > 512 {
      events.removeFirst(events.count - 512)
    }
  }

  private static func makeTransport(server: MCPServerConfig) throws -> any MCP.Transport {
    switch server.transport {
    case .stdio:
      return try MCPChildProcessTransport(server: server)

    case .streamableHTTP, .sse:
      guard let urlString = server.url, let url = URL(string: urlString) else {
        throw GatewayToolError.executionFailed(
          "MCP server '\(server.id)' has no valid url."
        )
      }
      return MCP.HTTPClientTransport(endpoint: url, streaming: true)

    case .http:
      guard let urlString = server.url, let url = URL(string: urlString) else {
        throw GatewayToolError.executionFailed(
          "MCP server '\(server.id)' has no valid url."
        )
      }
      return MCP.HTTPClientTransport(endpoint: url, streaming: false)
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
