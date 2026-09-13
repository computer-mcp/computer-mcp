import CryptoKit
import Foundation

package struct MCPRegistrationCredentialStatus: Codable, Equatable, Sendable {
  package let registrationID: String
  package let authentication: MCPHTTPAuthentication
  package let bindingDigest: String
  package let present: Bool
}

extension AppControlPlaneService {
  package func mcpCredentialStatus(id: String) async throws -> MCPRegistrationCredentialStatus {
    let binding = try mcpCredentialBinding(id: id)
    let present = try await secretStore.containsAsynchronously(
      SecretReference(account: binding.authentication.keychainAccount), authenticationUI: .fail)
    return .init(
      registrationID: id, authentication: binding.authentication,
      bindingDigest: binding.digest, present: present)
  }

  /// Nil explicitly removes this credential, not its registration or host grants.
  package func changeMCPCredential(id: String, expectedBindingDigest: String, token: String?)
    async throws
  {
    let binding = try mcpCredentialBinding(id: id)
    guard binding.digest == expectedBindingDigest else {
      throw AtomicManifestStoreError.staleDigest
    }
    let reference = try SecretReference(account: binding.authentication.keychainAccount)
    if let token {
      try MCPHTTPAuthentication.validateToken(token)
      try await secretStore.setAsynchronously(token, for: reference)
    } else {
      try await secretStore.deleteAsynchronously(reference)
    }
  }

  private func mcpCredentialBinding(id: String) throws
    -> (authentication: MCPHTTPAuthentication, digest: String)
  {
    guard !pluginMutationInProgress else { throw PluginHostError.changeInProgress }
    guard let entry = try mcpRegistrations().registrations.first(where: { $0.id == id }) else {
      throw GatewayToolError.unknownMCPServer(id)
    }
    guard let authentication = entry.server.authentication else {
      throw MCPHTTPAuthenticationError.invalidBinding
    }
    try authentication.validate(endpoint: entry.server.url, transport: entry.server.transport)
    let binding = try CanonicalJSONCoding.encoder(outputFormatting: [.sortedKeys]).encode(entry)
    return (authentication, SHA256.hash(data: binding).map { String(format: "%02x", $0) }.joined())
  }
}
