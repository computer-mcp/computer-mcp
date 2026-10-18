import Foundation
import os

/// Each subscriber owns a bounded invalidation stream; coalescing never drops a catalog delta.
final class GatewayToolChangeBroadcaster: Sendable {
  private struct State {
    var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
    var closed = false
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  func stream() -> AsyncStream<Void> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    continuation.onTermination = { [weak self] _ in
      _ = self?.state.withLock { $0.subscribers.removeValue(forKey: id) }
    }
    let closed = state.withLock { state in
      if state.closed { return true }
      state.subscribers[id] = continuation
      return false
    }
    if closed { continuation.finish() }
    return stream
  }

  func send() {
    let subscribers = state.withLock { Array($0.subscribers.values) }
    for subscriber in subscribers { subscriber.yield(()) }
  }

  func finish() {
    let subscribers = state.withLock { state in
      state.closed = true
      let subscribers = Array(state.subscribers.values)
      state.subscribers.removeAll()
      return subscribers
    }
    for subscriber in subscribers { subscriber.finish() }
  }

  deinit { finish() }
}
