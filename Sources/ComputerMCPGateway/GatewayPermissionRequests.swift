import ComputerMCPCore
import ComputerMCPPermissions
import Crypto
import Foundation

package enum GatewayPermissionError: Error, Equatable {
  case unauthenticated, localOwnerRequired, revisionConflict, unknownProfile, profileUnavailable
  case invalidPolicySnapshot, invalidBinding, managedLimit, subjectCapacity
}

/// Constructed from authenticated host context. Tool arguments are never an input
/// to this initializer; connections sharing verified identity share a stable subject.
package struct GatewayPermissionSubject: Equatable, Sendable {
  package let principal: Principal
  package let profileID: GatewayProfileID
  package let caller: GatewayCallerKind

  package init(context: ExecutionContext) throws {
    guard let verified = context.trustedPrincipalID, !verified.isEmpty else {
      throw GatewayPermissionError.unauthenticated
    }
    let data = try JSONEncoder().encode([
      context.profileID.rawValue, context.caller.rawValue, verified,
    ])
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    principal = .client(digest)
    profileID = context.profileID
    caller = context.caller
  }
}

/// An in-process control-plane capability. Its validator runs while the database
/// transaction owns the mutation; no Codable representation conveys this authority.
package struct GatewayPermissionOwner: Sendable {
  let auditContext: ExecutionContext
  private(set) var auditParentRequestID: String?
  private let validate: @Sendable () throws -> Void

  package init(context: ExecutionContext, validate: @escaping @Sendable () throws -> Void) throws {
    guard context.caller == .localApp || context.caller == .localCLI,
      context.profileID == .localAdmin, context.trustedPrincipalID?.isEmpty == false
    else {
      throw GatewayPermissionError.localOwnerRequired
    }
    auditContext = context
    auditParentRequestID = nil
    self.validate = validate
  }

  /// Adapter provenance is separate from the proof: its live validator is retained.
  package func recording(context: ExecutionContext) throws -> GatewayPermissionOwner {
    var owner = try GatewayPermissionOwner(context: context, validate: validate)
    owner.auditParentRequestID = context.requestID
    return owner
  }

  func authorize() throws { try validate() }
}

package struct GatewayPermissionRequestView: Sendable {
  package let request: PermissionRequest
  package let profileID: GatewayProfileID?
  package let alwaysIsShared: Bool
  package var registrationGrantRoot: CanonicalPath? = nil
  package var registrationGrantName: String? = nil
}

package struct GatewayManagedPolicyView: Equatable, Sendable, Codable {
  package var profileID: GatewayProfileID? = nil
  package var provider: PluginIdentity? = nil
  package let source: PolicySource
  package let location: String
  package let revision: String
  package let failure: String?
}

package struct GatewayPermissionView: Sendable {
  package let revision: UInt64
  package let profiles: [ProfileGrant]
  package let subjects: [GatewayPermissionSubjectView]
  package let requests: [GatewayPermissionRequestView]
  package let sources: [GatewayManagedPolicyView]
  package let epoch: UUID?
  package let suspended: Bool
  package let unconfirmedProfileIDs: Set<GatewayProfileID>
  /// Profile editing uses every allowed caller's policies, even before a client connects.
  package var profileLimits: [GatewayProfileID: [ManagedLimits]] = [:]
  package var trustedHosts: Set<String> = []
  package var providers: [GatewayProviderApproval] = []
  package var sourceProjects: [String: String] = [:]
  package var providerLimits: [PluginIdentity: ManagedLimits] = [:]
  /// Providers with usable standing consent under the current ledger and policy.
  package var providerFullAccess: Set<PluginIdentity> = []
}

package struct GatewayPermissionSubjectView: Sendable {
  package let principal: Principal
  package let profileID: GatewayProfileID
  package let caller: GatewayCallerKind
  package let limits: ManagedLimits
}
