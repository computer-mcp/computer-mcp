import Crypto
import Foundation

/// A service-owned credential shared across listener lifetimes. Only its digest is
/// retained; the lock makes replacement and request authentication synchronous.
package final class HTTPAccessTokenCredential: @unchecked Sendable {
  private let lock = NSLock()
  private var expectedDigest: [UInt8]?

  package init(token: String?) {
    expectedDigest = token.flatMap { $0.isEmpty ? nil : Self.digest($0) }
  }

  package func replace(with token: String?) {
    lock.withLock { expectedDigest = token.flatMap { $0.isEmpty ? nil : Self.digest($0) } }
  }

  func principalID(for token: String?) -> String? {
    let candidate = Self.digest(token ?? "")
    return lock.withLock {
      guard let expectedDigest,
        HTTPBearerAuthenticator.constantTimeEqual(candidate, expectedDigest)
      else { return nil }
      return "credential:sha256:" + expectedDigest.map { String(format: "%02x", $0) }.joined()
    }
  }

  private static func digest(_ value: String) -> [UInt8] {
    Array(SHA256.hash(data: Data(value.utf8)))
  }
}
