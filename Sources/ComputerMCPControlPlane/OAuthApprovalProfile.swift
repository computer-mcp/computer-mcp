import ComputerMCPCore
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
    let authorization: JSONValue = .object([
      "mode": .string(grant.mode.rawValue),
      "capabilities": .array(grant.capabilityIDs.sorted().map(JSONValue.string)),
      "projects": .array(grant.projectIDs.sorted().map(JSONValue.string)),
      "callers": .array(grant.allowedCallers.map(\.rawValue).sorted().map(JSONValue.string)),
      "full_shell_enabled": .bool(grant.fullShellEnabled),
      "mcp_servers": .array(grant.mcpServerIDs.sorted().map(JSONValue.string)),
      "confirmation_policy": .string(grant.confirmationPolicy.rawValue),
    ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(authorization)
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
