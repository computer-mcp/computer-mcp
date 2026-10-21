import ComputerMCPCore
import Foundation

/// All reads and writes in the closure share one transaction. A thrown storage error
/// rolls it back, including audit. Implementations serialize writers across connections.
package protocol OAuthStore: Sendable {
  func oauthTransaction<Result>(_ body: (any OAuthStoreTransaction) throws -> Result) throws
    -> Result
}

package protocol OAuthStoreTransaction {
  func requests(tunnelID: String) throws -> [OAuthAuthorizationRequest]
  func save(_ request: OAuthAuthorizationRequest) throws
  func grant(id: String) throws -> OAuthGrant?
  func grants(tunnelID: String) throws -> [OAuthGrant]
  func save(_ grant: OAuthGrant) throws
  func code(digest: String) throws -> OAuthAuthorizationCode?
  func save(_ code: OAuthAuthorizationCode) throws
  func token(digest: String) throws -> OAuthToken?
  func save(_ token: OAuthToken) throws
  /// End every pairing and discard unexchanged codes for this tunnel in this transaction.
  func endAuthorizations(tunnelID: String) throws
  func audit(_ event: AuditEvent) throws
  /// Remove expired pending-flow data and expired access tokens. Refresh digests that
  /// detect reuse must survive while their grant can still authorize requests.
  func prune(before: Date) throws
}

package enum OAuthLimits {
  package static let requestLifetime: TimeInterval = 10 * 60
  package static let codeLifetime: TimeInterval = 60
  package static let accessTokenLifetime: TimeInterval = 60 * 60
  package static let refreshTokenLifetime: TimeInterval = 30 * 24 * 60 * 60
  package static let metadataMaxBytes = 64 * 1_024
  package static let metadataTimeout: TimeInterval = 8
  package static let maxPendingRequests = 128
  package static let maxPendingRequestsPerAddress = 3
  package static let maxMetadataFetchesPerAddress = 1
  package static let maxMetadataFetchesPerTunnel = 4
  package static let addressCapacity: Double = 60
  package static let addressRefillPerSecond: Double = 1
  package static let grantCapacity: Double = 30
  package static let grantRefillPerSecond: Double = 0.5
  package static let failureAuditInterval: TimeInterval = 60
  package static let maxRateLimitKeys = 4_096
}

/// Caller supplies a clock; buckets bound memory as well as request rate.
package struct OAuthRateLimiter: Sendable {
  private struct Bucket: Sendable {
    var tokens: Double
    var updatedAt: Date
  }
  private var buckets: [String: Bucket] = [:]

  package init() {}

  package mutating func allow(address: String, grantID: String? = nil, now: Date) -> Bool {
    guard
      take(
        "address:" + address, capacity: OAuthLimits.addressCapacity,
        refill: OAuthLimits.addressRefillPerSecond, now: now)
    else { return false }
    return grantID.map {
      take(
        "grant:" + $0, capacity: OAuthLimits.grantCapacity,
        refill: OAuthLimits.grantRefillPerSecond, now: now)
    } ?? true
  }

  package mutating func allowGrant(_ id: String, now: Date) -> Bool {
    take(
      "grant:" + id, capacity: OAuthLimits.grantCapacity,
      refill: OAuthLimits.grantRefillPerSecond, now: now)
  }

  private mutating func take(_ key: String, capacity: Double, refill: Double, now: Date) -> Bool {
    if buckets[key] == nil, buckets.count >= OAuthLimits.maxRateLimitKeys {
      buckets = buckets.filter { now.timeIntervalSince($0.value.updatedAt) < 120 }
      guard buckets.count < OAuthLimits.maxRateLimitKeys else { return false }
    }
    var bucket = buckets[key] ?? Bucket(tokens: capacity, updatedAt: now)
    bucket.tokens = min(
      capacity, bucket.tokens + max(0, now.timeIntervalSince(bucket.updatedAt)) * refill)
    bucket.updatedAt = now
    let allowed = bucket.tokens >= 1
    if allowed { bucket.tokens -= 1 }
    buckets[key] = bucket
    return allowed
  }
}
