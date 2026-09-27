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
    guard
      let entry = try mcpRegistrations().registrations.first(where: { $0.id == id })
        ?? inactivePluginCredentialEntry(id: id)
    else {
      throw GatewayToolError.unknownMCPServer(id)
    }
    guard let authentication = entry.server.authentication else {
      throw MCPHTTPAuthenticationError.invalidBinding
    }
    try authentication.validate(endpoint: entry.server.url, transport: entry.server.transport)
    let binding = try CanonicalJSONCoding.encoder(outputFormatting: [.sortedKeys]).encode(entry)
    return (authentication, SHA256.hash(data: binding).map { String(format: "%02x", $0) }.joined())
  }

  /// Credential setup can precede activation. Resolve only the requested HTTP
  /// declaration through the same source-identity and host-settings validation.
  private func inactivePluginCredentialEntry(id: String) throws -> MCPRegistrationEntry? {
    let state = try database.pluginStoreSnapshot()
      .includingBundledDefaults(bundledPlugins.packages.map(\.manifest))
    var entries: [MCPRegistrationEntry] = []
    for (pluginID, settings) in state.settings {
      for (componentID, choice) in settings.mcp
      where PluginResolver.registrationID(
        pluginID: pluginID, componentID: componentID, override: choice.registrationID) == id
        && choice.authentication != nil
      {
        guard
          let (package, source) = try PluginStore.selectedPackage(
            pluginID, in: state, bundled: bundledPlugins.packages),
          package.manifest.mcp.contains(where: { $0.id == componentID && $0.transport == .http })
        else { continue }
        var scoped = settings
        scoped.enabled = true
        for contribution in package.manifest.mcp {
          scoped.mcp[contribution.id, default: .init()].enabled = contribution.id == componentID
        }
        for contribution in package.manifest.cli {
          scoped.cli[contribution.id, default: .init()].enabled = false
        }
        for contribution in package.manifest.skills {
          scoped.skills[contribution.id, default: .init()].enabled = false
        }
        let resolved = try PluginResolver.resolve(
          package: package, source: source, settings: scoped,
          hostVersion: PluginVersion(ComputerMCPCLI.version), architecture: PluginHost.architecture)
        if let server = resolved.mcpServers.first(where: { $0.id == id }) {
          entries.append(.init(server: server, origin: resolved.origins[.init(kind: .mcp, id: id)]))
        }
      }
    }
    guard entries.count <= 1 else { throw MCPHTTPAuthenticationError.invalidBinding }
    return entries.first
  }
}
