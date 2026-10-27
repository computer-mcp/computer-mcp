import ComputerMCPCore
import ComputerMCPPermissions
import Crypto
import Foundation

/// The resolved authorization shown to the owner, including manifest-derived grants.
package struct OAuthApprovalProfile: Equatable, Sendable {
  package let grant: ProfileGrant
  package let authorizationDigest: String

  /// SHA-256 of compact UTF-8 JSON with sorted keys, unescaped slashes and sorted
  /// set members. Identity and persistence revisions are not authorization fields.
  package init(grant: ProfileGrant) throws {
    self.grant = grant
    struct Entry: Encodable {
      let permission: Permission
      let state: PermissionState
    }
    struct Authorization: Encodable {
      let permissions: [Entry]
      let networks: [String: NetworkAccess.Configuration]
      let automation: [String: ProfileGrant.AutomationAccess]
      let fullAccess: Bool
      let callers: [String]
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let entries = grant.permissions.entries.map { Entry(permission: $0.key, state: $0.value) }
    let authorization = Authorization(
      permissions: entries,
      networks: grant.projectNetworks.mapValues(\.configuration), automation: grant.automation,
      fullAccess: grant.fullAccess, callers: grant.allowedCallers.map(\.rawValue))
    let object = try JSONSerialization.jsonObject(with: encoder.encode(authorization))
    func serialized(_ value: Any) throws -> Data {
      try JSONSerialization.data(
        withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
    }
    func normalized(_ value: Any) throws -> Any {
      if let values = value as? [Any] {
        return try values.map(normalized).map { (try serialized($0), $0) }
          .sorted { $0.0.lexicographicallyPrecedes($1.0) }.map(\.1)
      }
      if let values = value as? [String: Any] { return try values.mapValues(normalized) }
      return value
    }
    let data = try serialized(normalized(object))
    authorizationDigest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

extension AppControlPlaneService {
  package func oauthApprovalProfiles() async throws -> [OAuthApprovalProfile] {
    await manifestStore.publicationLock.acquire()
    defer { manifestStore.publicationLock.release() }
    try Task.checkCancellation()
    return try await profileGrants().filter {
      $0.id != .localAdmin && $0.allowedCallers.contains(.cloudflareTunnel)
    }.map { try OAuthApprovalProfile(grant: $0) }
  }
}
