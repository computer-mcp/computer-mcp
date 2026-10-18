import Foundation

/// Host-owned credential binding. Package manifests cannot select Keychain items.
package struct MCPHTTPAuthentication: Codable, Equatable, Sendable {
  package var endpoint: String
  package var keychainAccount: String

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case endpoint
    case keychainAccount = "keychain_account"
  }

  package init(endpoint: String, keychainAccount: String) {
    self.endpoint = endpoint
    self.keychainAccount = keychainAccount
  }

  package init(from decoder: any Decoder) throws {
    let values = try decoder.pluginContainer(keyedBy: CodingKeys.self)
    endpoint = try values.decode(String.self, forKey: .endpoint)
    keychainAccount = try values.decode(String.self, forKey: .keychainAccount)
    try validate(endpoint: endpoint, transport: .streamableHTTP)
  }

  package func validate(endpoint actualEndpoint: String?, transport: MCPTransport) throws {
    guard transport != .stdio else { throw MCPHTTPAuthenticationError.invalidBinding }
    guard let url = URL(string: endpoint), endpoint == actualEndpoint,
      url.user == nil, url.password == nil, url.fragment == nil,
      let host = url.host, !host.isEmpty,
      url.scheme == "https"
        || (url.scheme == "http" && ["127.0.0.1", "[::1]", "::1", "localhost"].contains(host))
    else { throw MCPHTTPAuthenticationError.invalidBinding }
    let reference = try SecretReference(account: keychainAccount)
    guard reference.account == keychainAccount else {
      throw MCPHTTPAuthenticationError.invalidBinding
    }
  }

  func bearerToken(from store: KeychainSecretStore?) async throws -> String {
    guard let store else { throw MCPHTTPAuthenticationError.unavailable }
    let value: String?
    do {
      value = try await store.valueAsynchronously(
        for: SecretReference(account: keychainAccount), authenticationUI: .fail)
    } catch { throw MCPHTTPAuthenticationError.unavailable }
    guard let value else { throw MCPHTTPAuthenticationError.missing }
    try Self.validateToken(value)
    return value
  }

  package static func validateToken(_ value: String) throws {
    guard !value.isEmpty, value.utf8.count <= 16_384,
      value.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e })
    else { throw MCPHTTPAuthenticationError.invalidToken }
  }
}

package enum MCPHTTPAuthenticationError: Error, LocalizedError {
  case invalidBinding, unavailable, missing, invalidToken

  package var errorDescription: String? {
    switch self {
    case .invalidBinding:
      "MCP credentials require an exact endpoint binding using HTTPS or loopback HTTP, and a valid Keychain account."
    case .unavailable:
      "The host cannot access the MCP credential. Check the App's Keychain identity and unlock state."
    case .missing:
      "The MCP credential is missing. Save it through the host before connecting."
    case .invalidToken:
      "The MCP bearer token must be nonempty printable ASCII without whitespace, at most 16 KiB."
    }
  }
}
