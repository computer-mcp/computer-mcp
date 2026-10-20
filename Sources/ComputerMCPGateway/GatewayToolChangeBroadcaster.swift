import Foundation
import NIOConcurrencyHelpers

/// Each subscriber owns a bounded invalidation stream; coalescing never drops a catalog delta.
package final class GatewayToolChangeBroadcaster: Sendable {
  package init() {}

  private struct State {
    var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
    var closed = false
  }

  private let state = NIOLockedValueBox(State())

  package func stream() -> AsyncStream<Void> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    continuation.onTermination = { [weak self] _ in
      _ = self?.state.withLockedValue { $0.subscribers.removeValue(forKey: id) }
    }
    let closed = state.withLockedValue { state in
      if state.closed { return true }
      state.subscribers[id] = continuation
      return false
    }
    if closed { continuation.finish() }
    return stream
  }

  package func send() {
    let subscribers = state.withLockedValue { Array($0.subscribers.values) }
    for subscriber in subscribers { subscriber.yield(()) }
  }

  package func finish() {
    let subscribers = state.withLockedValue { state in
      state.closed = true
      let subscribers = Array(state.subscribers.values)
      state.subscribers.removeAll()
      return subscribers
    }
    for subscriber in subscribers { subscriber.finish() }
  }

  deinit { finish() }
}
