import Foundation

/// Serializes effective-configuration reads through publication across service actors.
/// Acquire a tunnel mutation slot before this lock when both are needed. Publication
/// may call back into the control plane, but must never acquire a tunnel slot.
final class ConfigurationPublicationLock: @unchecked Sendable {
  // This mutex protects admission only; no thread is blocked across an actor hop.
  private let mutex = NSLock()
  private var held = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func acquire() async {
    await withCheckedContinuation { continuation in
      let admitted = mutex.withLock {
        if held {
          waiters.append(continuation)
          return false
        }
        held = true
        return true
      }
      if admitted { continuation.resume() }
    }
  }

  /// Synchronous bootstrap and manifest-store callers fail rather than block a thread.
  func tryAcquire() -> Bool {
    mutex.withLock {
      guard !held else { return false }
      held = true
      return true
    }
  }

  func release() {
    let next: CheckedContinuation<Void, Never>? = mutex.withLock {
      if !waiters.isEmpty { return waiters.removeFirst() }
      held = false
      return nil
    }
    next?.resume()
  }

  var waitingCount: Int { mutex.withLock { waiters.count } }
}
