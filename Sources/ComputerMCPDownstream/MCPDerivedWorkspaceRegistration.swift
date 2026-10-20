import ComputerMCPCore
import Foundation

/// Durable host ownership of a plugin-derived registration, independent of domain databases.
package struct MCPDerivedWorkspaceRegistration: Codable, Equatable, Sendable {
  package let origin: String
  package let receiptID: String
  package let sourceWorkspaceID: String
  package let sourceRoot: String
  package let receiptDigest: String
  package let profileID: GatewayProfileID
  /// Missing on historical records; ownership must never be inferred from a caller or profile.
  package let principalID: String?
  package let caller: GatewayCallerKind
  package let workspace: RegisteredWorkspace

  package init(
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

package enum MCPHostServiceError: Error, LocalizedError {
  case denied(String)
  package var errorDescription: String? {
    switch self {
    case .denied(let detail): "host.service_denied: " + detail
    }
  }
}
