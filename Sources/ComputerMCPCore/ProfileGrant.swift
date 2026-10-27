import ComputerMCPPermissions
import Foundation

/// Stored permissions and settings shared by every admitted caller of a profile.
/// Full access records the owner's setting; a connection still needs separate consent.
package struct ProfileGrant: Codable, Equatable, Sendable {
  package enum AutomationAccess: String, Codable, Sendable { case allow, deny }

  package var id: GatewayProfileID
  package var permissions: Permissions
  package var projectNetworks: [String: NetworkAccess]
  package var automation: [String: AutomationAccess]
  package var fullAccess: Bool
  package var allowedCallers: Set<GatewayCallerKind>
  package var authorizationRevision: Int64

  package init(
    id: GatewayProfileID, permissions: Permissions = .init(),
    projectNetworks: [String: NetworkAccess] = [:],
    automation: [String: AutomationAccess] = [:], fullAccess: Bool = false,
    allowedCallers: Set<GatewayCallerKind>, authorizationRevision: Int64 = 1
  ) {
    self.id = id
    self.permissions = permissions
    self.projectNetworks = projectNetworks
    self.automation = automation
    self.fullAccess = fullAccess
    self.allowedCallers = allowedCallers
    self.authorizationRevision = authorizationRevision
  }

  package static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.permissions.entries == rhs.permissions.entries
      && lhs.projectNetworks.mapValues(\.configuration)
        == rhs.projectNetworks.mapValues(\.configuration)
      && lhs.automation == rhs.automation
      && lhs.fullAccess == rhs.fullAccess && lhs.allowedCallers == rhs.allowedCallers
      && lhs.authorizationRevision == rhs.authorizationRevision
  }

  package static func newPrincipal(id: GatewayProfileID, allowedCallers: Set<GatewayCallerKind>)
    -> Self
  {
    Self(id: id, permissions: .newPrincipal, allowedCallers: allowedCallers)
  }
}

extension ProfileGrant {
  package static let observe = newPrincipal(id: .chatGPTObserve, allowedCallers: [.secureTunnel])
  package static let operate = newPrincipal(id: .chatGPTOperate, allowedCallers: [.secureTunnel])
  package static let cloudflareObserve = newPrincipal(
    id: .cloudflareObserve, allowedCallers: [.cloudflareTunnel])
  package static let cloudflareOperate = newPrincipal(
    id: .cloudflareOperate, allowedCallers: [.cloudflareTunnel])
  package static let localAdmin = newPrincipal(
    id: .localAdmin, allowedCallers: [.localApp, .localCLI, .localMCP])

  package func validate() throws {
    if id == .localAdmin && allowedCallers.contains(where: \.isRemote) {
      throw GatewayPolicyConfigurationError.localAdminCannotBeRemote
    }
  }
}
