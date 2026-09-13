import Foundation
import Logging
import MCP

/// HTTP stream ownership is independent of JSON-RPC request handling in the MCP SDK client.
actor MCPHTTPClientTransport: Transport {
  private struct RequestExchange {
    let identity: UUID
    let task: Task<Void, Error>
  }
  nonisolated let logger: Logger
  private let worker: MCPHTTPStreamWorker
  private let streaming: Bool
  private let incoming: AsyncThrowingStream<Data, any Error>
  private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
  private var eventTask: Task<Void, Never>?
  private var disconnectTask: Task<Void, Never>?
  private var connected = false
  private var closed = false
  private var initializeID: JSONValue?
  private var requestExchanges: [MCP.ID: RequestExchange] = [:]
  private(set) var sessionID: String?
  private var protocolVersion = Version.latest

  init(
    endpoint: URL,
    configuration: URLSessionConfiguration = .ephemeral,
    streaming: Bool = true,
    requestModifier: @escaping @Sendable (URLRequest) -> URLRequest = { $0 },
    bearerToken: @escaping @Sendable () async throws -> String? = { nil },
    logger: Logger = Logger(label: "computer-mcp.http-client")
  ) {
    self.logger = logger
    self.streaming = streaming
    self.worker = MCPHTTPStreamWorker(
      endpoint: endpoint,
      session: URLSession(
        configuration: configuration, delegate: MCPHTTPRedirectPolicy(), delegateQueue: nil),
      requestModifier: requestModifier, bearerToken: bearerToken)
    (incoming, continuation) = AsyncThrowingStream<Data, any Error>.makeStream(
      bufferingPolicy: .bufferingOldest(32))
  }

  func connect() async throws {
    guard !closed else { throw MCPError.connectionClosed }
    connected = true
  }

  func receive() -> AsyncThrowingStream<Data, any Error> { incoming }

  func send(_ data: Data) async throws {
    try Task.checkCancellation()
    guard connected, !closed else { throw MCPError.connectionClosed }
    guard data.count <= 32 * 1_024 * 1_024 else { throw MCPHTTPTransportError.messageTooLarge }
    let object = try JSONDecoder().decode(JSONValue.self, from: data).objectValue
    let requestID = object?["method"] != nil ? try Self.requestID(object?["id"]) : nil
    let cancelledID =
      object?["method"] == .string("notifications/cancelled")
      ? try Self.requestID(object?["params"]?.objectValue?["requestId"]) : nil
    let cancelledExchange = cancelledID.flatMap { requestExchanges[$0]?.task }
    if let requestID, requestExchanges[requestID] != nil {
      throw MCPError.invalidRequest("An HTTP request with this ID is already active.")
    }
    if let id = MCPInitializeNormalization.initializeRequestID(in: data) { initializeID = id }
    let context = MCPHTTPStreamWorker.Context(
      sessionID: sessionID, protocolVersion: protocolVersion)
    let identity = UUID()
    let exchange = Task { [worker, weak self] in
      try await worker.post(
        data, context: context,
        headers: { [weak self] response in try await self?.acceptHeaders(response) },
        deliver: { [weak self] message in
          guard let self else { throw MCPError.connectionClosed }
          try await self.acceptMessage(message)
        })
    }
    if let requestID { requestExchanges[requestID] = .init(identity: identity, task: exchange) }
    defer {
      if let requestID, requestExchanges[requestID]?.identity == identity {
        requestExchanges.removeValue(forKey: requestID)
      }
    }
    let result = await withTaskCancellationHandler {
      await exchange.result
    } onCancel: {
      exchange.cancel()
    }
    // MCP cancellation ends the matching POST/GET-recovery reader as well as the SDK waiter.
    // Capture before awaiting so a reused ID cannot select a newer exchange.
    cancelledExchange?.cancel()
    _ = await cancelledExchange?.result
    try result.get()
  }

  private static func requestID(_ value: JSONValue?) throws -> MCP.ID? {
    guard let value, value != .null else { return nil }
    return try JSONDecoder().decode(MCP.ID.self, from: JSONEncoder().encode(value))
  }

  func disconnect() async {
    if let disconnectTask {
      await disconnectTask.value
      return
    }
    closed = true
    connected = false
    let events = eventTask
    events?.cancel()
    eventTask = nil
    continuation.finish()
    let exchanges = requestExchanges.values.map(\.task)
    requestExchanges.removeAll()
    for exchange in exchanges { exchange.cancel() }
    let context = MCPHTTPStreamWorker.Context(
      sessionID: sessionID, protocolVersion: protocolVersion)
    // Concurrent disconnect callers join the same bounded cleanup and never duplicate DELETE.
    let task = Task { [worker] in
      await worker.endSession(context: context)
      worker.session.invalidateAndCancel()
      for exchange in exchanges { _ = await exchange.result }
      await events?.value
    }
    disconnectTask = task
    await task.value
  }

  private func acceptHeaders(_ response: HTTPURLResponse) throws {
    guard !closed else { throw MCPError.connectionClosed }
    if let id = response.value(forHTTPHeaderField: HTTPHeaderName.sessionID) {
      guard !id.isEmpty, id.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e }) else {
        throw MCPHTTPTransportError.invalidResponse
      }
      if let sessionID, sessionID != id { throw MCPHTTPTransportError.sessionChanged }
      sessionID = id
    }
  }

  private func acceptMessage(_ data: Data) throws {
    guard !closed else { throw MCPError.connectionClosed }
    if let initializeID,
      let response = MCPInitializeNormalization.successfulResponse(
        in: data, matching: initializeID),
      let version = response.objectValue?["result"]?.objectValue?["protocolVersion"]?.stringValue
    {
      guard Version.supported.contains(version) else { throw MCPHTTPTransportError.invalidResponse }
      protocolVersion = version
      self.initializeID = nil
      startEvents()
    }
    switch continuation.yield(data) {
    case .enqueued: break
    case .dropped:
      close(error: MCPHTTPTransportError.receiveQueueFull)
      throw MCPHTTPTransportError.receiveQueueFull
    case .terminated: throw MCPError.connectionClosed
    @unknown default: throw MCPError.connectionClosed
    }
  }

  private func startEvents() {
    guard streaming, eventTask == nil else { return }
    let context = MCPHTTPStreamWorker.Context(
      sessionID: sessionID, protocolVersion: protocolVersion)
    eventTask = Task { [worker, weak self] in
      do {
        try await worker.listen(
          context: context,
          deliver: { [weak self] message in
            guard let self else { throw MCPError.connectionClosed }
            try await self.acceptMessage(message)
          })
      } catch {
        if !Task.isCancelled { await self?.close(error: error) }
      }
    }
  }

  private func close(error: (any Error)?) {
    guard !closed else { return }
    closed = true
    connected = false
    eventTask?.cancel()
    for exchange in requestExchanges.values { exchange.task.cancel() }
    worker.session.invalidateAndCancel()
    continuation.finish(throwing: error)
  }

  deinit {
    eventTask?.cancel()
    for exchange in requestExchanges.values { exchange.task.cancel() }
    worker.session.invalidateAndCancel()
    continuation.finish()
  }
}

/// Redirects must not replay an MCP write or forward credentials to a different endpoint.
private final class MCPHTTPRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

private struct MCPHTTPStreamWorker: Sendable {
  struct Context: Sendable {
    let sessionID: String?
    let protocolVersion: String
  }

  private struct Cursor {
    var id: String?
    var retryMilliseconds = 1_000
  }

  private let maxMessageBytes = 32 * 1_024 * 1_024
  let endpoint: URL
  let session: URLSession
  let requestModifier: @Sendable (URLRequest) -> URLRequest
  let bearerToken: @Sendable () async throws -> String?

  private func authorized(_ request: URLRequest) async throws -> URLRequest {
    var request = requestModifier(request)
    guard request.url == endpoint else { throw MCPHTTPAuthenticationError.invalidBinding }
    if let token = try await bearerToken() {
      try MCPHTTPAuthentication.validateToken(token)
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    return request
  }

  func endSession(context: Context) async {
    guard context.sessionID != nil else { return }
    var request = request(method: "DELETE", context: context)
    request.timeoutInterval = 2
    // Session termination is best effort; servers may reject DELETE. Do not consume an
    // unbounded response body or retry an ambiguous request during local shutdown.
    do {
      let (bytes, _) = try await session.bytes(for: authorized(request))
      bytes.task.cancel()
    } catch {}
  }

  func post(
    _ data: Data,
    context: Context,
    headers: @Sendable (HTTPURLResponse) async throws -> Void,
    deliver: @Sendable (Data) async throws -> Void
  ) async throws {
    let object = try JSONDecoder().decode(JSONValue.self, from: data).objectValue
    let expectedID = object?["method"] != nil ? object?["id"] : nil
    var request = request(method: "POST", context: context)
    request.httpBody = data
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    var cursor = Cursor()
    var streamContext = context
    while true {
      try Task.checkCancellation()
      do {
        let (bytes, response) = try await session.bytes(for: authorized(request))
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else {
          throw MCPHTTPTransportError.invalidResponse
        }
        guard response.statusCode == 200 || (response.statusCode == 202 && expectedID == nil) else {
          throw MCPHTTPTransportError.httpStatus(response.statusCode)
        }
        try await headers(response)
        if let id = response.value(forHTTPHeaderField: HTTPHeaderName.sessionID) {
          streamContext = Context(sessionID: id, protocolVersion: context.protocolVersion)
        }
        if response.statusCode == 202 { return }
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if contentType.hasPrefix("application/json") {
          let body = try await readJSON(bytes)
          guard try isResponse(body, for: expectedID) else {
            throw MCPHTTPTransportError.invalidResponse
          }
          try await deliver(body)
          return
        }
        guard contentType.hasPrefix("text/event-stream") else {
          throw MCPHTTPTransportError.unsupportedContentType
        }
        if try await readEvents(bytes, cursor: &cursor, expectedID: expectedID, deliver: deliver) {
          return
        }
      } catch let error as URLError {
        // A failed POST without a cursor is ambiguous. Only GET recovery can be retried.
        guard !Task.isCancelled, cursor.id != nil, Self.isTransient(error) else { throw error }
      }
      guard let id = cursor.id else { throw MCPHTTPTransportError.incompleteResponse }
      try await pause(cursor)
      request = requestForResume(context: streamContext, id: id)
    }
  }

  func listen(context: Context, deliver: @Sendable (Data) async throws -> Void) async throws {
    var cursor = Cursor()
    while !Task.isCancelled {
      var request = request(method: "GET", context: context)
      if let id = cursor.id { request.setValue(id, forHTTPHeaderField: HTTPHeaderName.lastEventID) }
      do {
        let (bytes, response) = try await session.bytes(for: authorized(request))
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else {
          throw MCPHTTPTransportError.invalidResponse
        }
        if response.statusCode == 405 { return }
        guard response.statusCode == 200 else {
          throw MCPHTTPTransportError.httpStatus(response.statusCode)
        }
        if let id = response.value(forHTTPHeaderField: HTTPHeaderName.sessionID),
          id != context.sessionID
        {
          throw MCPHTTPTransportError.sessionChanged
        }
        guard
          response.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix(
            "text/event-stream") == true
        else {
          throw MCPHTTPTransportError.unsupportedContentType
        }
        _ = try await readEvents(bytes, cursor: &cursor, expectedID: nil, deliver: deliver)
      } catch let error as URLError {
        guard !Task.isCancelled, Self.isTransient(error) else { throw error }
      }
      try await pause(cursor)
    }
  }

  private func request(method: String, context: Context) -> URLRequest {
    var request = URLRequest(url: endpoint)
    request.httpMethod = method
    request.setValue(
      method == "GET" ? "text/event-stream" : "application/json, text/event-stream",
      forHTTPHeaderField: "Accept")
    request.setValue(context.protocolVersion, forHTTPHeaderField: HTTPHeaderName.protocolVersion)
    if let id = context.sessionID {
      request.setValue(id, forHTTPHeaderField: HTTPHeaderName.sessionID)
    }
    return request
  }

  private func requestForResume(context: Context, id: String) -> URLRequest {
    var request = request(method: "GET", context: context)
    request.setValue(id, forHTTPHeaderField: HTTPHeaderName.lastEventID)
    return request
  }

  private func readJSON(_ bytes: URLSession.AsyncBytes) async throws -> Data {
    try await withTaskCancellationHandler {
      var data = Data()
      for try await byte in bytes {
        guard data.count < maxMessageBytes else { throw MCPHTTPTransportError.messageTooLarge }
        data.append(byte)
      }
      return data
    } onCancel: {
      bytes.task.cancel()
    }
  }

  private func readEvents(
    _ bytes: URLSession.AsyncBytes,
    cursor: inout Cursor,
    expectedID: JSONValue?,
    deliver: @Sendable (Data) async throws -> Void
  ) async throws -> Bool {
    try await withTaskCancellationHandler {
      var decoder = MCPSSEDecoder(maxEventBytes: maxMessageBytes)
      for try await byte in bytes {
        guard let event = try decoder.append(byte) else { continue }
        if let id = event.id { cursor.id = id.isEmpty ? nil : id }
        if let retry = event.retryMilliseconds { cursor.retryMilliseconds = retry }
        guard let data = event.data, !data.isEmpty else { continue }
        let response = try isResponse(data, for: expectedID)
        try await deliver(data)
        if response { return true }
      }
      return false
    } onCancel: {
      bytes.task.cancel()
    }
  }

  private func isResponse(_ data: Data, for expectedID: JSONValue?) throws -> Bool {
    guard let message = try JSONDecoder().decode(JSONValue.self, from: data).objectValue,
      message["jsonrpc"] == .string("2.0")
    else { throw MCPHTTPTransportError.invalidResponse }
    return expectedID != nil && message["id"] == expectedID && message["method"] == nil
      && (message["result"] != nil || message["error"] != nil)
  }

  private func pause(_ cursor: Cursor) async throws {
    try await Task.sleep(for: .milliseconds(max(100, cursor.retryMilliseconds)))
  }

  private static func isTransient(_ error: URLError) -> Bool {
    [
      .networkConnectionLost, .timedOut, .cannotConnectToHost, .notConnectedToInternet,
      .dnsLookupFailed, .cannotFindHost,
    ].contains(error.code)
  }
}
