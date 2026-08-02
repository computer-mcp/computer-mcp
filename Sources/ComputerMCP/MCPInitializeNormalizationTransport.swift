import Foundation
import Logging
import MCP

/// Adapts open-ended MCP initialize capabilities to the narrower Swift SDK 0.12 model.
internal actor MCPInitializeNormalizationTransport: Transport {
  private let underlying: any Transport
  private var initialInitializeID: JSONValue?
  private var initializeResponse: JSONValue?
  private var pendingInitializeIDs: [JSONValue] = []

  internal nonisolated let logger: Logger

  internal init(
    wrapping underlying: any Transport,
    logger: Logger = Logger(label: "computer-mcp.mcp-initialize-normalization")
  ) {
    self.underlying = underlying
    self.logger = logger
  }

  internal func connect() async throws {
    try await underlying.connect()
  }

  internal func disconnect() async {
    await underlying.disconnect()
  }

  internal func send(_ data: Data) async throws {
    try await underlying.send(data)

    guard
      let initialInitializeID,
      let response = MCPInitializeNormalization.successfulResponse(
        in: data,
        matching: initialInitializeID
      )
    else {
      return
    }

    initializeResponse = response
    self.initialInitializeID = nil

    let pendingIDs = pendingInitializeIDs
    pendingInitializeIDs.removeAll()
    for id in pendingIDs {
      try await underlying.send(
        MCPInitializeNormalization.replay(response: response, with: id)
      )
    }
  }

  internal func receive() -> AsyncThrowingStream<Data, Swift.Error> {
    return AsyncThrowingStream { continuation in
      Task {
        await self.forwardMessages(to: continuation)
      }
    }
  }

  private func forwardMessages(
    to continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
  ) async {
    let stream = await underlying.receive()
    do {
      for try await data in stream {
        try await forwardMessage(data, to: continuation)
      }
      continuation.finish()
    } catch {
      continuation.finish(throwing: error)
    }
  }

  private func forwardMessage(
    _ data: Data,
    to continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
  ) async throws {
    let normalized = MCPInitializeNormalization.normalize(data)
    guard let requestID = MCPInitializeNormalization.initializeRequestID(in: normalized) else {
      continuation.yield(normalized)
      return
    }

    if let initializeResponse {
      try await underlying.send(
        MCPInitializeNormalization.replay(response: initializeResponse, with: requestID)
      )
    } else if initialInitializeID != nil {
      pendingInitializeIDs.append(requestID)
    } else {
      initialInitializeID = requestID
      continuation.yield(normalized)
    }
  }
}

enum MCPInitializeNormalization {
  static func normalize(_ data: Data) -> Data {
    guard
      var message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      message["method"] as? String == "initialize",
      var parameters = message["params"] as? [String: Any],
      var capabilities = parameters["capabilities"] as? [String: Any],
      let experimental = capabilities["experimental"] as? [String: Any]
    else {
      return data
    }

    let supported = experimental.compactMapValues { $0 as? String }
    if supported.count == experimental.count {
      return data
    }

    if supported.isEmpty {
      capabilities.removeValue(forKey: "experimental")
    } else {
      capabilities["experimental"] = supported
    }
    parameters["capabilities"] = capabilities
    message["params"] = parameters

    return (try? JSONSerialization.data(withJSONObject: message)) ?? data
  }

  static func initializeRequestID(in data: Data) -> JSONValue? {
    guard
      let message = try? JSONDecoder().decode(JSONValue.self, from: data),
      let object = message.objectValue,
      object["method"]?.stringValue == "initialize",
      let id = object["id"],
      id != .null
    else {
      return nil
    }
    return id
  }

  static func successfulResponse(in data: Data, matching id: JSONValue) -> JSONValue? {
    guard
      let response = try? JSONDecoder().decode(JSONValue.self, from: data),
      let object = response.objectValue,
      object["id"] == id,
      object["result"] != nil
    else {
      return nil
    }
    return response
  }

  static func replay(response: JSONValue, with id: JSONValue) throws -> Data {
    guard var object = response.objectValue else {
      throw MCPError.internalError("Cached initialize response is not a JSON object")
    }
    object["id"] = id
    return try JSONEncoder().encode(JSONValue.object(object))
  }
}
