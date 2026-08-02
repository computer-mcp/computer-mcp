import Foundation

public enum ValidationSocketCatalogConfigurationError: Error, LocalizedError, Equatable, Sendable {
  case missingOpenAITunnelProvenance

  public var errorDescription: String? {
    switch self {
    case .missingOpenAITunnelProvenance:
      "OpenAI Secure MCP Tunnel catalog validation requires Tunnel instance and profile identifiers."
    }
  }
}

public enum ValidationSocketCatalogConfiguration {
  public static func resolve(
    socketURL: URL,
    provenance: ValidationTransportProvenance
  ) throws -> GatewaySocketConfiguration {
    var configuration = GatewaySocketConfiguration(socketURL: socketURL)
    switch provenance.transport {
    case .gatewaySocket:
      break
    case .controlSocket:
      configuration.clientIdentity = .localCLI
    case .openAISecureMCPTunnel:
      guard let tunnelInstanceID = nonempty(provenance.tunnelInstanceID),
        let tunnelProfileID = nonempty(provenance.tunnelProfileID)
      else {
        throw ValidationSocketCatalogConfigurationError.missingOpenAITunnelProvenance
      }
      configuration.clientIdentity = .secureTunnel(
        credentialFile: URL(
          fileURLWithPath: socketURL.path + ".openai-tunnel-auth",
          isDirectory: false
        ),
        tunnelInstanceID: tunnelInstanceID,
        tunnelProfileID: tunnelProfileID
      )
    case .cloudflareTunnel, .cloudflareQuickTunnel:
      break
    }
    return configuration
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }
}
