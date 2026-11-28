import Foundation

/// Cancellation seals callback admission, including proofs issued by an admission
/// transaction that was already running when its channel closed.
final class GatewayHostCallbackLifetime: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var finished = false
  private var claimed = false
  private var cancelWorker: (@Sendable () -> Void)?
  private var authorizations: Set<UUID> = []
  private let revoke: @Sendable (Set<UUID>) -> Void

  init(revoke: @escaping @Sendable (Set<UUID>) -> Void) { self.revoke = revoke }

  func register(_ ids: Set<UUID>) throws {
    let accepted = lock.withLock {
      guard !cancelled, !finished else { return false }
      authorizations.formUnion(ids)
      return true
    }
    if !accepted {
      revoke(ids)
      throw CancellationError()
    }
  }

  /// Admission and transfer share the cancellation gate. The synchronous preparation
  /// transaction never calls back into this lifetime while the gate is held.
  func claim<Value>(_ ids: Set<UUID>, prepare: () throws -> Value) throws -> Value {
    try lock.withLock {
      guard !cancelled, !finished, !claimed, !ids.isEmpty,
        ids.isSubset(of: authorizations)
      else { throw CancellationError() }
      let value = try prepare()
      authorizations.subtract(ids)
      claimed = true
      return value
    }
  }

  /// A durable operation borrows the live call's proofs. Only the worker that moves
  /// the reservation to running may outlive the channel.
  func claimOperation<Record>(
    _ prepare: () throws -> (record: Record, claimed: Bool)
  ) throws -> (record: Record, claimed: Bool) {
    try lock.withLock {
      guard !cancelled, !finished, !claimed, authorizations.isEmpty else {
        throw CancellationError()
      }
      let result = try prepare()
      claimed = result.claimed
      return result
    }
  }

  /// Returns whether the receiver may leave host-owned work running. Unclaimed
  /// callbacks still cancel and join their worker before returning to the channel.
  @discardableResult
  func cancel() -> Bool {
    let state = lock.withLock { () -> (Set<UUID>, (@Sendable () -> Void)?, Bool) in
      guard !finished else { return ([], nil, false) }
      cancelled = true
      return (authorizations, claimed ? nil : cancelWorker, claimed)
    }
    if !state.0.isEmpty { revoke(state.0) }
    state.1?()
    return state.2
  }

  /// The independently owned worker starts before admission. The channel waits on
  /// a one-shot result, while the worker retains invocation ownership through audit.
  func run<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    let result = GatewayHostCallbackResult<Value>()
    return try await withTaskCancellationHandler {
      try check()
      let worker = Task.detached {
        let outcome: Result<Value, any Error>
        do {
          try Task.checkCancellation()
          outcome = .success(try await operation())
        } catch { outcome = .failure(error) }
        self.finish()
        result.complete(outcome)
      }
      let cancelImmediately = lock.withLock {
        guard !finished else { return false }
        cancelWorker = { worker.cancel() }
        return cancelled && !claimed
      }
      if cancelImmediately { worker.cancel() }
      let value = try await result.wait()
      try check()
      return value
    } onCancel: {
      if self.cancel() { result.complete(.failure(CancellationError())) }
    }
  }

  func check() throws {
    if lock.withLock({ cancelled }) { throw CancellationError() }
  }

  func validateActive(_ validate: () throws -> Void) throws {
    let active = try lock.withLock {
      if cancelled { throw CancellationError() }
      return !finished
    }
    if active { try validate() }
  }

  func finish() {
    lock.withLock {
      finished = true
      authorizations.removeAll()
      cancelWorker = nil
    }
  }
}

/// The result and its sole waiter are protected by the same lock; completion and
/// claimed-channel cancellation race to resume it exactly once.
private final class GatewayHostCallbackResult<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Result<Value, any Error>?
  private var waiter: CheckedContinuation<Value, any Error>?

  func complete(_ result: Result<Value, any Error>) {
    let continuation = lock.withLock { () -> CheckedContinuation<Value, any Error>? in
      guard value == nil else { return nil }
      value = result
      defer { waiter = nil }
      return waiter
    }
    continuation?.resume(with: result)
  }

  func wait() async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      let completed = lock.withLock { () -> Result<Value, any Error>? in
        if let value { return value }
        waiter = continuation
        return nil
      }
      if let completed { continuation.resume(with: completed) }
    }
  }
}
