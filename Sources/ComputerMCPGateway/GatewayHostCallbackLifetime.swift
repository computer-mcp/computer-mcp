import Foundation

/// Cancellation seals callback admission, including proofs issued by an admission
/// transaction that was already running when its channel closed.
final class GatewayHostCallbackLifetime: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var finished = false
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

  func cancel() {
    let ids = lock.withLock { () -> Set<UUID> in
      guard !finished else { return [] }
      cancelled = true
      return authorizations
    }
    if !ids.isEmpty { revoke(ids) }
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
    }
  }
}
