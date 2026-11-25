import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPGateway
import ComputerMCPPermissions
import ComputerMCPPlugins
import Foundation

package struct ProviderEnablementReview: Sendable, Identifiable {
  enum Target: Equatable, Sendable {
    case plugin(expectedRevision: Int64, settings: PluginSettings?, manifestDigest: String)
    case registration(currentDigest: String, proposedDigest: String)
  }

  package let id = UUID()
  package let provider: ProviderPermissionOptions
  package let names: PermissionObjectNames
  package let localServer: MCPServerConfig?
  package let mcpContributionIDs: [String]
  package let trustedHosts: Set<String>
  /// The provider principal owns its persistent sandbox home, cache, and state.
  package var sandboxContainer: PluginIdentity { provider.identity }
  let target: Target

  package var requestedMode: ExecutionMode {
    provider.declarations?.sandbox?.fullAccess == true ? .fullAccess(.standing) : .sandbox
  }

  package var allowsModeSelection: Bool { localServer != nil }

  package func readExceptions(replacements: [String: CanonicalPath] = [:]) throws
    -> [GatewayReadExceptionReview]
  {
    try provider.sourceReview?.readExceptions(replacements: replacements) ?? []
  }
}

package struct ProviderEnablementSelection: Sendable {
  package var permissions: Permissions
  package var sandboxSettings: ProviderSandboxSettings
  package var fullAccess: Bool

  package init(
    permissions: Permissions = .init(), sandboxSettings: ProviderSandboxSettings = .init(),
    fullAccess: Bool = false
  ) {
    self.permissions = permissions
    self.sandboxSettings = sandboxSettings
    self.fullAccess = fullAccess
  }
}

package struct ProviderEnablementApproval: Sendable {
  let provider: ProviderPermissionOptions
  let target: ProviderEnablementReview.Target
  let selection: ProviderEnablementSelection

  package init(review: ProviderEnablementReview, selection: ProviderEnablementSelection) {
    self.init(provider: review.provider, target: review.target, selection: selection)
  }

  init(
    provider: ProviderPermissionOptions, target: ProviderEnablementReview.Target,
    selection: ProviderEnablementSelection
  ) {
    self.provider = provider
    self.target = target
    self.selection = selection
  }
}

package enum ProviderEnablementError: LocalizedError, ControlErrorClassifying, Equatable, Sendable {
  case reviewRequired

  package var controlAuditClassification: (decision: AuditDecision, code: String)? {
    (.denied, "provider.approval_required")
  }

  package var errorDescription: String? {
    "Review and approve this provider’s access on the host before enabling it."
  }
}

extension PermissionControlService {
  func prepareProviderActivation(_ approval: ProviderEnablementApproval) throws
    -> GatewayProviderActivation
  {
    let reviewed = approval.provider
    guard let epoch = reviewed.epoch, let source = reviewed.sourceReview else {
      throw GatewayPermissionError.invalidBinding
    }
    return GatewayProviderActivation(
      review: source, permissions: approval.selection.permissions,
      fullAccess: approval.selection.fullAccess,
      sandboxSettings: approval.selection.sandboxSettings,
      owner: try currentOwner(), expectedProviderRevision: reviewed.approval?.revision,
      expectedRevision: reviewed.permissionRevision, expectedEpoch: epoch, limits: reviewed.limits)
  }
}
