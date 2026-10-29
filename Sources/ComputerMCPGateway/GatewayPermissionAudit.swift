import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPPersistence
import Foundation
import GRDB

/// Owner evidence is inserted by the same writer that publishes the authority change.
/// Identifiers and revisions describe the change without retaining policy or call contents.
enum GatewayPermissionAudit {
  static func record(
    _ action: String, capabilityID: String, owner: GatewayPermissionOwner,
    database: Database, ledger: PermissionLedger, profileIDs: [GatewayProfileID],
    permissions: Set<Permission> = [], request: PermissionRequest? = nil,
    provider: PluginIdentity? = nil,
    expectedRevision: UInt64, now: Date
  ) throws {
    let ids = Set(profileIDs).sorted { $0.rawValue < $1.rawValue }
    var details = try GatewayPermissionAuditEvidence(
      database: database, ledger: ledger, profileID: ids.first ?? .localAdmin
    ).fields
    details["owner_action"] = .string(action)
    details["reviewed_permission_revision"] = try .integer(exactly: expectedRevision)
    details["owner_control_revision"] =
      try Int64.fetchOne(
        database, sql: "SELECT revision FROM permissionControlRevision WHERE id = 1"
      ).map(JSONValue.integer) ?? .null
    details["profile_ids"] = .array(ids.map { .string($0.rawValue) })
    if let provider { details["provider"] = try .encoded(provider) }
    var revisions: [String: JSONValue] = [:]
    for id in ids {
      if let profile = try ProfileRecord.fetchOne(database, key: id.rawValue) {
        revisions[id.rawValue] = .integer(profile.authorizationRevision)
      }
    }
    details["profile_revisions"] = .object(revisions)
    details["permissions"] = .array(
      permissions.map(descriptor).sorted { sortKey($0) < sortKey($1) }.map(JSONValue.object))
    details["permission_request_ids"] = .array(
      request.map { [.string($0.id.uuidString)] } ?? [])
    if let request {
      switch request.content {
      case .permission(let content):
        var requested = descriptor(content.requirement.permission)
        requested["value"] = .string(content.requirement.value.rawValue)
        details["requested_permission"] = .object(requested)
      case .network:
        details["requested_permission"] = .object(["permission": .string("network")])
      case .projectRegistration(let content):
        var requested = descriptor(.project(content.projectID))
        requested["value"] = .string(content.access.rawValue)
        details["requested_permission"] = .object(requested)
      }
    }
    let context = owner.auditContext
    let trace = context.transportTrace
    let event = AuditEvent(
      occurredAt: now, requestID: UUID().uuidString,
      parentRequestID: owner.auditParentRequestID, caller: context.caller,
      principalDigest: AuditEvent.verifiedPrincipalDigest(context.trustedPrincipalID),
      transport: trace?.transport, socketConnectionID: trace?.socketConnectionID,
      tunnelInstanceID: trace?.tunnelInstanceID, tunnelProfileID: trace?.tunnelProfileID,
      profileID: context.profileID, capabilityID: capabilityID, decision: .allowed,
      errorDetails: .object(details))
    try AuditEventRecord(event).insertRetained(database, now: now)
  }

  private static func descriptor(_ permission: Permission) -> [String: JSONValue] {
    let name: String
    let object: String?
    switch permission {
    case .project(let id): (name, object) = ("project", id)
    case .filesAndFolders(let category): (name, object) = ("files_and_folders", category.rawValue)
    case .plugin(let id): (name, object) = ("plugin", id)
    case .mcpServer(let id): (name, object) = ("mcp_server", id)
    case .screen: (name, object) = ("screen", nil)
    case .desktopControl: (name, object) = ("desktop_control", nil)
    case .localNetwork: (name, object) = ("local_network", nil)
    case .machineInformation: (name, object) = ("machine_information", nil)
    case .unifiedLogs: (name, object) = ("unified_logs", nil)
    case .skills: (name, object) = ("skills", nil)
    }
    return ["permission": .string(name), "object": object.map(JSONValue.string) ?? .null]
  }

  private static func sortKey(_ object: [String: JSONValue]) -> String {
    return (object["permission"]?.stringValue ?? "") + ":" + (object["object"]?.stringValue ?? "")
  }
}
