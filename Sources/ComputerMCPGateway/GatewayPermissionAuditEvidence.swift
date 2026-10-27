import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPPersistence
import Foundation
import GRDB

/// Captured under the admission writer; later profile or policy edits cannot
/// relabel the authority used by an already recorded call.
package struct GatewayPermissionAuditEvidence: Codable, Sendable {
  let epoch: UUID?
  let permissionRevision: UInt64
  let profileRevision: Int64?
  let policyRevisions: [String: String]

  init(database: Database, ledger: PermissionLedger, profileID: GatewayProfileID) throws {
    epoch = ledger.authorizationEpochID
    permissionRevision = ledger.revision
    profileRevision = try ProfileRecord.fetchOne(database, key: profileID.rawValue)?
      .authorizationRevision
    let decoder = JSONDecoder()
    let views = try Data.fetchAll(database, sql: "SELECT payload FROM permissionPolicySources").map
    {
      try decoder.decode(GatewayManagedPolicyView.self, from: $0)
    }
    policyRevisions = Dictionary(
      uniqueKeysWithValues: views.filter {
        $0.profileID == nil || $0.profileID == profileID
      }.map { ($0.source.rawValue, $0.revision) })
  }

  var fields: [String: JSONValue] {
    [
      "authorization_epoch": epoch.map { .string($0.uuidString) } ?? .null,
      "permission_revision": .number(Double(permissionRevision)),
      "profile_revision": profileRevision.map { .number(Double($0)) } ?? .null,
      "policy_revisions": .object(policyRevisions.mapValues(JSONValue.string)),
    ]
  }
}

struct GatewayPermissionEvaluation: Sendable {
  let decision: AuthorizationDecision
  let evidence: GatewayPermissionAuditEvidence
}

/// Lifecycle rows have their own request IDs and link to the originating call.
/// Their payload contains authority identities and revisions, never command text.
struct GatewayExecutionAuditIdentity: Codable, Sendable {
  let caller: GatewayCallerKind
  let profileID: GatewayProfileID
  let principalDigest: String?
  let transport: String?
  let socketConnectionID: String?
  let tunnelInstanceID: String?
  let tunnelProfileID: String?
  let projectID: String?
  let parentRequestID: String?
  let authorizationID: UUID
  let requestIDs: Set<UUID>
  let evidence: GatewayPermissionAuditEvidence

  init(
    database: Database, ledger: PermissionLedger, authorization: InvocationAuthorization,
    context: ExecutionContext?
  ) throws {
    let row = try Row.fetchOne(
      database,
      sql: "SELECT profileID, caller FROM permissionSubjects WHERE principal = ?",
      arguments: [try JSONEncoder().encode(authorization.invocation.principal)])
    caller =
      context?.caller ?? row.flatMap { GatewayCallerKind(rawValue: $0["caller"]) } ?? .localApp
    profileID =
      context?.profileID ?? row.flatMap { GatewayProfileID(rawValue: $0["profileID"]) }
      ?? .localAdmin
    principalDigest = context.flatMap { AuditEvent.verifiedPrincipalDigest($0.trustedPrincipalID) }
    transport = context?.transportTrace?.transport
    socketConnectionID = context?.transportTrace?.socketConnectionID
    tunnelInstanceID = context?.transportTrace?.tunnelInstanceID
    tunnelProfileID = context?.transportTrace?.tunnelProfileID
    projectID = authorization.invocation.projectID
    parentRequestID = context?.requestID
    authorizationID = authorization.id
    requestIDs = authorization.requestIDs
    evidence = try GatewayPermissionAuditEvidence(
      database: database, ledger: ledger, profileID: profileID)
  }

  func record(
    _ action: String, executionID: UUID, database: Database,
    decision: AuditDecision = .allowed, childID: UUID? = nil
  ) throws {
    var details = evidence.fields
    details["authorization_id"] = .string(authorizationID.uuidString)
    details["permission_request_ids"] = .array(
      requestIDs.map { .string($0.uuidString) }.sorted { $0.stringValue! < $1.stringValue! })
    details["execution_id"] = .string(executionID.uuidString)
    if let childID { details["child_id"] = .string(childID.uuidString) }
    try AuditEventRecord(
      AuditEvent(
        requestID: UUID().uuidString,
        invocationID: executionID.uuidString, parentRequestID: parentRequestID,
        caller: caller, principalDigest: principalDigest, transport: transport,
        socketConnectionID: socketConnectionID, tunnelInstanceID: tunnelInstanceID,
        tunnelProfileID: tunnelProfileID, profileID: profileID,
        projectID: projectID, capabilityID: "execution." + action, decision: decision,
        errorDetails: .object(details))
    ).insertRetained(database)
  }
}
