import Foundation
import Logging
import MCP

/// Keeps one catalog invalidation until the HTTP client's first GET event subscription.
/// Later stream reconnections use the underlying transport's event IDs and replay store.
package actor MCPHTTPEventSubscriptionTransport: Transport {
  package nonisolated let logger: Logger
  private let underlying: any Transport
  private var subscribed = false
  private var disconnected = false
  private var pendingCatalogChange: Data?

  package init(
    wrapping underlying: any Transport,
    logger: Logger = Logger(label: "computer-mcp.http-event-subscription")
  ) {
    self.underlying = underlying
    self.logger = logger
  }

  package func connect() async throws { try await underlying.connect() }

  package func disconnect() async {
    disconnected = true
    pendingCatalogChange = nil
    await underlying.disconnect()
  }

  package func receive() -> AsyncThrowingStream<Data, any Error> {
    let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    let forwarding = Task { [underlying] in
      do {
        for try await data in await underlying.receive() {
          try Task.checkCancellation()
          continuation.yield(data)
        }
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }
    continuation.onTermination = { _ in forwarding.cancel() }
    return stream
  }

  package func send(_ data: Data) async throws {
    guard !disconnected else { throw MCPError.connectionClosed }
    if !subscribed,
      let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      message["id"] == nil,
      message["method"] as? String == "notifications/tools/list_changed"
    {
      pendingCatalogChange = data
      return
    }
    try await underlying.send(data)
  }

  package func eventStreamOpened() async throws {
    guard !disconnected else { throw MCPError.connectionClosed }
    subscribed = true
    if let pendingCatalogChange {
      self.pendingCatalogChange = nil
      try await underlying.send(pendingCatalogChange)
    }
  }
}
