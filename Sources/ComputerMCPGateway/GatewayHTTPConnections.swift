import Foundation
@preconcurrency import NIOCore

/// Owns accepted channels and every async producer that can schedule work on their event loops.
/// Disconnected channels may still have cancelled producers finishing cleanup.
internal final class GatewayHTTPConnections: @unchecked Sendable {
  private let lock = NSLock()
  private let limit: Int
  private var count = 0
  private var channels: [ObjectIdentifier: any Channel] = [:]
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var shutdownTask: Task<Void, Never>?

  init(limit: Int) { self.limit = limit }

  func insert(_ channel: any Channel) -> Bool {
    let id = ObjectIdentifier(channel)
    let accepted = lock.withLock {
      guard shutdownTask == nil else { return false }
      channels[id] = channel
      return true
    }
    if accepted {
      channel.closeFuture.whenComplete { _ in
        _ = self.lock.withLock { self.channels.removeValue(forKey: id) }
      }
    }
    return accepted
  }

  /// Counts sockets only until MCP authentication succeeds.
  func reserve() -> Bool {
    lock.withLock {
      guard shutdownTask == nil, count < limit else { return false }
      count += 1
      return true
    }
  }

  func release() { lock.withLock { count -= 1 } }

  func start(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never>? {
    lock.withLock {
      guard shutdownTask == nil else { return nil }
      let id = UUID()
      let task = Task {
        await operation()
        _ = self.lock.withLock { self.tasks.removeValue(forKey: id) }
      }
      tasks[id] = task
      return task
    }
  }

  /// Closes admission synchronously. The caller keeps the event-loop group alive until this joins.
  func beginShutdown() -> Task<Void, Never> {
    lock.withLock {
      if let shutdownTask { return shutdownTask }
      let channels = Array(channels.values)
      let tasks = Array(tasks.values)
      let task = Task {
        for task in tasks { task.cancel() }
        for channel in channels { try? await channel.close() }
        for task in tasks { await task.value }
      }
      shutdownTask = task
      return task
    }
  }
}
