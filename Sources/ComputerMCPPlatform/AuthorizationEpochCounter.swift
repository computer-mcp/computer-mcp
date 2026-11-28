import Foundation

/// A watermark kept outside the permission database. Its database identity binds
/// the counter to the store selected by the host, including after file replacement.
package struct AuthorizationEpochWatermark: Codable, Equatable, Sendable {
  package let databaseID: UUID
  package let revision: UInt64

  package init(databaseID: UUID, revision: UInt64) {
    self.databaseID = databaseID
    self.revision = revision
  }
}

package enum AuthorizationEpochCounterError: Error, Equatable {
  case unavailable, invalidRecord, revisionExhausted, nonMonotonicWrite
}

/// The callback owns an exclusive cross-process lock for this counter namespace.
/// Acquisition waits up to a bounded deadline, then throws if still contended.
/// Acquire it after SQLite's write lock and retain it through SQLite COMMIT.
/// No callback may await, prompt, publish a manifest, or acquire a consent lock.
package protocol AuthorizationEpochCounter: Sendable {
  func withExclusiveAccess<Result>(
    _ body: (any AuthorizationEpochCounterAccess) throws -> Result
  ) throws -> Result
}

/// Methods are valid only inside `withExclusiveAccess`. `advance` durably saves
/// the watermark before returning; failures must propagate and prevent dispatch.
package protocol AuthorizationEpochCounterAccess {
  func read() throws -> AuthorizationEpochWatermark?
  func advance(to watermark: AuthorizationEpochWatermark) throws
}

/// Platforms without a durable out-of-database counter cannot open authority
/// storage. The in-memory permission ledger remains available for isolated use.
package struct UnavailableAuthorizationEpochCounter: AuthorizationEpochCounter {
  package init() {}
  package func withExclusiveAccess<Result>(
    _ body: (any AuthorizationEpochCounterAccess) throws -> Result
  ) throws -> Result {
    throw AuthorizationEpochCounterError.unavailable
  }
}
