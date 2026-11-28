import ComputerMCPPermissions
import Foundation

/// Immutable facts captured by the host after admission and before provider dispatch.
/// Argument bodies and approval state are deliberately absent from durable storage.
package struct HostCallAdmission: Codable, Equatable, Sendable {
  package let id: UUID
  package let generationID: UUID
  package let verifiedClientID: String?
  package let actingPrincipal: Principal
  package let profileID: GatewayProfileID
  package let caller: GatewayCallerKind
  package let projectID: String
  package let sourceProjectID: String
  package let upstreamName: String
  package let reference: MCPToolReference
  package let action: MCPHostServiceAction?
  package let argumentsDigest: String
  /// Present when admission uses the permission ledger's authorization identity.
  package let authorizationID: UUID?
  package let authorizationRevision: Int64
  package let controlSessionID: String?
  package let controlSessionRevision: Int64?
  package let requestID: String
  package let createdAt: Date

  package init(
    id: UUID, generationID: UUID, verifiedClientID: String?, actingPrincipal: Principal,
    profileID: GatewayProfileID, caller: GatewayCallerKind, projectID: String,
    sourceProjectID: String, upstreamName: String, reference: MCPToolReference,
    action: MCPHostServiceAction?, argumentsDigest: String, authorizationID: UUID?,
    authorizationRevision: Int64, controlSessionID: String?, controlSessionRevision: Int64?,
    requestID: String, createdAt: Date = Date()
  ) {
    self.id = id
    self.generationID = generationID
    self.verifiedClientID = verifiedClientID
    self.actingPrincipal = actingPrincipal
    self.profileID = profileID
    self.caller = caller
    self.projectID = projectID
    self.sourceProjectID = sourceProjectID
    self.upstreamName = upstreamName
    self.reference = reference
    self.action = action
    self.argumentsDigest = argumentsDigest
    self.authorizationID = authorizationID
    self.authorizationRevision = authorizationRevision
    self.controlSessionID = controlSessionID
    self.controlSessionRevision = controlSessionRevision
    self.requestID = requestID
    self.createdAt = createdAt
  }
}

/// A journal entry is evidence, not a bearer credential. A callback additionally
/// needs a lease still owned by the originating process and current authorization.
package struct HostCallRecord: Codable, Equatable, Sendable {
  package enum Lifecycle: String, Codable, Sendable { case running, retained, completed }
  package let admission: HostCallAdmission
  package var requestLeaseIDs: Set<UUID>
  package var workLeaseIDs: Set<UUID>
  package var completedAt: Date?
  package var lifecycle: Lifecycle {
    if completedAt != nil { return .completed }
    return requestLeaseIDs.isEmpty ? .retained : .running
  }

  package init(admission: HostCallAdmission, requestLeaseID: UUID) {
    self.admission = admission
    requestLeaseIDs = [requestLeaseID]
    workLeaseIDs = []
    completedAt = nil
  }
}
