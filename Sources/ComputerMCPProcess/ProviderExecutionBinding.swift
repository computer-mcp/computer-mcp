import ComputerMCPPermissions
import Foundation

/// Host-resolved authority for one provider generation. Discovery has no delegator
/// and cannot borrow a project or a Full access invocation's authority.
package struct ProviderExecutionBinding: Sendable {
  package let identity: PluginIdentity
  package let registrationID: String
  package let sourceDigest: String
  package let providerAuthorization: InvocationAuthorization
  package let delegatingAuthorization: InvocationAuthorization?

  package init(
    identity: PluginIdentity, registrationID: String, sourceDigest: String,
    providerAuthorization: InvocationAuthorization,
    delegatingAuthorization: InvocationAuthorization?
  ) throws {
    guard !registrationID.isEmpty, sourceDigest.count == 64,
      providerAuthorization.invocation.principal == .plugin(identity)
    else { throw PermissionModelError.invalidAuthorization }
    if let caller = delegatingAuthorization {
      let permission: Permission =
        switch identity {
        case .package(let name): .plugin(name)
        case .localServer(let name): .mcpServer(name)
        }
      guard caller.id != providerAuthorization.id,
        caller.invocation.tool == providerAuthorization.invocation.tool,
        caller.invocation.projectID == providerAuthorization.invocation.projectID,
        caller.invocation.argumentsDigest == providerAuthorization.invocation.argumentsDigest,
        caller.requirements.execution == providerAuthorization.requirements.execution,
        caller.actions.contains(where: { $0.requirement.permission == permission })
      else { throw PermissionModelError.invalidAuthorization }
    } else {
      guard providerAuthorization.invocation.projectID == nil,
        providerAuthorization.mode == .sandbox
      else { throw PermissionModelError.invalidAuthorization }
    }
    self.identity = identity
    self.registrationID = registrationID
    self.sourceDigest = sourceDigest
    self.providerAuthorization = providerAuthorization
    self.delegatingAuthorization = delegatingAuthorization
  }

  package var authorizationIDs: Set<UUID> {
    Set([providerAuthorization.id, delegatingAuthorization?.id].compactMap { $0 })
  }

  package var owner: Principal {
    delegatingAuthorization?.invocation.principal ?? .plugin(identity)
  }
}
