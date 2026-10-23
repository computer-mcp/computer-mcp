import ComputerMCPCore
import Foundation

/// Durable host ownership of a plugin-derived registration, independent of domain databases.
package struct MCPDerivedProjectRegistration: Codable, Equatable, Sendable {
  package let origin: String
  package let receiptID: String
  package let sourceProjectID: String
  package let sourceRoot: String
  package let receiptDigest: String
  package let profileID: GatewayProfileID
  /// Missing on historical records; ownership must never be inferred from a caller or profile.
  package let principalID: String?
  package let caller: GatewayCallerKind
  package let project: RegisteredProject

  // These keys are the durable plugin ownership contract stored in payloadJSON.
  private enum CodingKeys: String, CodingKey {
    case origin, receiptID, sourceRoot, receiptDigest, profileID, principalID, caller
    case sourceProjectID = "sourceWorkspaceID"
    case project = "workspace"
  }

  package init(
    origin: String, receiptID: String, sourceProjectID: String, sourceRoot: String,
    receiptDigest: String, profileID: GatewayProfileID, principalID: String? = nil,
    caller: GatewayCallerKind, project: RegisteredProject
  ) {
    self.origin = origin
    self.receiptID = receiptID
    self.sourceProjectID = sourceProjectID
    self.sourceRoot = sourceRoot
    self.receiptDigest = receiptDigest
    self.profileID = profileID
    self.principalID = principalID
    self.caller = caller
    self.project = project
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
