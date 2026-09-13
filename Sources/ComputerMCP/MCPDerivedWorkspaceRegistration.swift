import Foundation

/// Durable host ownership of a plugin-derived registration, independent of domain databases.
struct MCPDerivedWorkspaceRegistration: Codable, Equatable, Sendable {
  let origin: String
  let receiptID: String
  let sourceWorkspaceID: String
  let sourceRoot: String
  let receiptDigest: String
  let profileID: GatewayProfileID
  let caller: GatewayCallerKind
  let workspace: RegisteredWorkspace
}

enum MCPHostServiceError: Error, LocalizedError {
  case denied(String)
  var errorDescription: String? {
    switch self {
    case .denied(let detail): "host.service_denied: " + detail
    }
  }
}
