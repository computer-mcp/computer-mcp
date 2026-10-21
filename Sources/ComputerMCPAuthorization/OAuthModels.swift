import ComputerMCPCore
import Crypto
import Foundation

package enum OAuthError: String, Error, LocalizedError, AuditErrorClassifying, Sendable {
  case invalidRequest = "invalid_request"
  case invalidClient = "invalid_client"
  case invalidGrant = "invalid_grant"
  case accessDenied = "access_denied"
  case rateLimited = "temporarily_unavailable"
  case networkUnavailable = "network_unavailable"

  package var errorDescription: String? {
    switch self {
    case .invalidRequest: "The OAuth request is invalid or no longer pending."
    case .invalidClient: "The OAuth client could not be validated."
    case .invalidGrant: "The OAuth code or token is invalid, expired, or already used."
    case .accessDenied: "OAuth client access requires the local owner and a remote profile."
    case .rateLimited: "The OAuth request limit was reached. Retry later."
    case .networkUnavailable: "CIMD networking is unavailable on this platform."
    }
  }

  package var auditClassification: (decision: AuditDecision, code: String)? {
    (
      self == .invalidRequest || self == .networkUnavailable ? .failed : .denied,
      "oauth." + rawValue
    )
  }
}

package struct OAuthServerConfiguration: Equatable, Sendable {
  package let tunnelID: String
  package let tunnelName: String
  package let hostname: String
  package let clientAllowlist: [String]
  package var issuer: String { "https://\(hostname)" }
  package var resource: String { issuer + "/mcp" }

  package init(
    tunnelID: String, tunnelName: String, hostname: String,
    clientAllowlist: [String] = ["claude.ai", "claude.com"]
  ) {
    self.tunnelID = tunnelID
    self.tunnelName = tunnelName
    self.hostname = hostname
    self.clientAllowlist = clientAllowlist
  }

  package var protectedResourceMetadata: [String: JSONValue] {
    [
      "resource": .string(resource), "authorization_servers": .array([.string(issuer)]),
      "bearer_methods_supported": .array([.string("header")]),
      "scopes_supported": .array([.string("mcp")]),
    ]
  }

  package var authorizationServerMetadata: [String: JSONValue] {
    [
      "issuer": .string(issuer), "authorization_endpoint": .string(issuer + "/oauth/authorize"),
      "token_endpoint": .string(issuer + "/oauth/token"),
      "revocation_endpoint": .string(issuer + "/oauth/revoke"),
      "response_types_supported": .array([.string("code")]),
      "grant_types_supported": .array([.string("authorization_code"), .string("refresh_token")]),
      "code_challenge_methods_supported": .array([.string("S256")]),
      "token_endpoint_auth_methods_supported": .array([.string("none")]),
      "client_id_metadata_document_supported": .bool(true),
      "authorization_response_iss_parameter_supported": .bool(true),
      "scopes_supported": .array([.string("mcp")]),
    ]
  }
}

package struct OAuthAuthorizationRequest: Codable, Equatable, Sendable, Identifiable {
  package enum Status: String, Codable, Sendable {
    case pending, approved, denied, expired, delivered
  }
  package let id: String
  package let pairingCode: String
  package let statusDigest: String
  package let tunnelID: String
  package let clientID: String
  package let redirectURI: String
  package let state: String
  package let codeChallenge: String
  package let resource: String
  package let scope: String
  package let createdAt: Date
  package let expiresAt: Date
  package var status: Status
  package var grantID: String?
  package var clientHost: String { URL(string: clientID)?.host ?? "" }
  package var redirectHost: String { URL(string: redirectURI)?.host ?? "" }
}

package struct OAuthGrant: Codable, Equatable, Sendable, Identifiable {
  package let id: String
  package let tunnelID: String
  package let clientID: String
  package let redirectHost: String
  package let profileID: GatewayProfileID
  package let resource: String
  package let scope: String
  package let createdAt: Date
  package var lastUsedAt: Date?
  package var revokedAt: Date?
  package var principalID: String { "oauth:" + id }
}

package struct OAuthAuthorizationCode: Codable, Equatable, Sendable {
  package let digest: String
  package let grantID: String
  package let clientID: String
  package let redirectURI: String
  package let codeChallenge: String
  package let resource: String
  package let scope: String
  package let expiresAt: Date
  package var usedAt: Date?
}

package struct OAuthToken: Codable, Equatable, Sendable {
  package enum Kind: String, Codable, Sendable { case access, refresh }
  package let digest: String
  package let kind: Kind
  package let grantID: String
  package let resource: String
  package let scope: String
  package let expiresAt: Date
  /// Rotated refresh digests remain recognizable until the grant is revoked.
  package var rotatedAt: Date?
  package var revokedAt: Date?
}

/// Only returned to the client; store records carry digests instead of these values.
package struct OAuthTokenResponse: Encodable, Sendable {
  package let accessToken: String
  package let refreshToken: String
  package let tokenType = "Bearer"
  package let expiresIn = Int(OAuthLimits.accessTokenLifetime)
  package let scope = "mcp"
  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
    case tokenType = "token_type"
    case expiresIn = "expires_in"
    case scope
  }
}

package struct OAuthPairing: Sendable {
  package let request: OAuthAuthorizationRequest
  package let statusToken: String
}

package enum OAuthPairingStatus: Sendable {
  case pending
  case redirect(String)
}

package enum OAuthSecret {
  package static func generate() -> String {
    var generator = SystemRandomNumberGenerator()
    return base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
  }

  package static func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  package static func challenge(_ verifier: String) -> String {
    base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
  }

  private static func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
}
