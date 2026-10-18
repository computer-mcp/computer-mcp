import Foundation

/// Durable host ownership of a plugin-derived registration, independent of domain databases.
struct MCPDerivedWorkspaceRegistration: Codable, Equatable, Sendable {
  let origin: String
  let receiptID: String
  let sourceWorkspaceID: String
  let sourceRoot: String
  let receiptDigest: String
  let profileID: GatewayProfileID
  /// Missing on historical records; ownership must never be inferred from a caller or profile.
  let principalID: String?
  let caller: GatewayCallerKind
  let workspace: RegisteredWorkspace

  init(
    origin: String, receiptID: String, sourceWorkspaceID: String, sourceRoot: String,
    receiptDigest: String, profileID: GatewayProfileID, principalID: String? = nil,
    caller: GatewayCallerKind, workspace: RegisteredWorkspace
  ) {
    self.origin = origin
    self.receiptID = receiptID
    self.sourceWorkspaceID = sourceWorkspaceID
    self.sourceRoot = sourceRoot
    self.receiptDigest = receiptDigest
    self.profileID = profileID
    self.principalID = principalID
    self.caller = caller
    self.workspace = workspace
  }
}

enum MCPHostServiceError: Error, LocalizedError {
  case denied(String)
  var errorDescription: String? {
    switch self {
    case .denied(let detail): "host.service_denied: " + detail
    }
  }
}
