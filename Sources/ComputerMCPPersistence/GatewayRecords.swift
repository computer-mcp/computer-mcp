import ComputerMCPCore
import Foundation
import GRDB

package struct RuntimeSettingRecord: Codable, FetchableRecord, PersistableRecord {
  package static let databaseTableName = "runtimeSettings"

  package var key: String
  package var value: String
  package var updatedAt: Date

  package init(key: String, value: String, updatedAt: Date) {
    self.key = key
    self.value = value
    self.updatedAt = updatedAt
  }
}

package struct ProjectRecord: Codable, FetchableRecord, PersistableRecord {
  package static let databaseTableName = "projects"

  package var id: String
  package var displayName: String
  package var rootPath: String
  package var bookmarkData: Data?
  package var bookmarkIsStale: Bool
  package var createdAt: Date
  package var updatedAt: Date

  package init(_ value: RegisteredProject) {
    self.id = value.id
    self.displayName = value.displayName
    self.rootPath = value.rootPath
    self.bookmarkData = value.bookmarkData
    self.bookmarkIsStale = value.bookmarkIsStale
    self.createdAt = value.createdAt
    self.updatedAt = value.updatedAt
  }

  package var value: RegisteredProject {
    RegisteredProject(
      id: id,
      displayName: displayName,
      rootPath: rootPath,
      bookmarkData: bookmarkData,
      bookmarkIsStale: bookmarkIsStale,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }
}

package struct ProjectCanonicalRootRecord: Codable, FetchableRecord, PersistableRecord {
  package static let databaseTableName = "projectCanonicalRoots"

  package var canonicalRootPath: String
  package var projectID: String
  package var createdAt: Date

  package init(canonicalRootPath: String, projectID: String, createdAt: Date) {
    self.canonicalRootPath = canonicalRootPath
    self.projectID = projectID
    self.createdAt = createdAt
  }
}

package struct ProjectAliasRecord: Codable, FetchableRecord, PersistableRecord {
  package static let databaseTableName = "projectAliases"

  package var aliasProjectID: String
  package var canonicalProjectID: String
  package var canonicalRootPath: String
  package var migratedAt: Date

  package init(
    aliasProjectID: String, canonicalProjectID: String, canonicalRootPath: String,
    migratedAt: Date
  ) {
    self.aliasProjectID = aliasProjectID
    self.canonicalProjectID = canonicalProjectID
    self.canonicalRootPath = canonicalRootPath
    self.migratedAt = migratedAt
  }
}

package struct ProjectDeduplicationReceiptRecord: Codable, FetchableRecord,
  PersistableRecord
{
  package static let databaseTableName = "projectDeduplicationReceipts"

  package var id: String
  package var planDigest: String
  package var appliedAt: Date
  package var payloadJSON: String

  package init(id: String, planDigest: String, appliedAt: Date, payloadJSON: String) {
    self.id = id
    self.planDigest = planDigest
    self.appliedAt = appliedAt
    self.payloadJSON = payloadJSON
  }
}

package struct ProfileRecord: Codable, FetchableRecord, PersistableRecord {
  package static let databaseTableName = "permissionProfiles"

  package let id: String
  package let authorizationRevision: Int64
  package let payload: Data
  package let authorityEpoch: String?

  package init(_ value: ProfileGrant, authorityEpoch: UUID?) throws {
    guard value.authorizationRevision > 0 else {
      throw GatewayDatabaseError.invalidStoredValue(
        "Profile authorization revision must be positive.")
    }
    try value.validate()
    id = value.id.rawValue
    authorizationRevision = value.authorizationRevision
    payload = try JSONEncoder().encode(value)
    self.authorityEpoch = authorityEpoch?.uuidString
  }

  package func value() throws -> ProfileGrant {
    guard payload.count <= 4_194_304 else { throw PermissionPersistenceError.invalidCurrentState }
    let profile = try JSONDecoder().decode(ProfileGrant.self, from: payload)
    guard profile.id.rawValue == id, profile.authorizationRevision == authorizationRevision,
      authorizationRevision > 0
    else { throw PermissionPersistenceError.invalidCurrentState }
    try profile.validate()
    return profile
  }
}

package struct ProviderStateRecord: Codable, FetchableRecord, PersistableRecord {
  package static let databaseTableName = "providerStates"

  package var id: String
  package var kind: String
  package var executablePath: String?
  package var observedVersion: String?
  package var health: String
  package var detail: String?
  package var checkedAt: Date

  package init(_ value: ProviderState) {
    self.id = value.id
    self.kind = value.kind
    self.executablePath = value.executablePath
    self.observedVersion = value.observedVersion
    self.health = value.health
    self.detail = value.detail
    self.checkedAt = value.checkedAt
  }

  package var value: ProviderState {
    ProviderState(
      id: id,
      kind: kind,
      executablePath: executablePath,
      observedVersion: observedVersion,
      health: health,
      detail: detail,
      checkedAt: checkedAt
    )
  }
}

package struct ConfigurationRevisionRecord: Codable, FetchableRecord, PersistableRecord {
  package static let databaseTableName = "configurationRevisions"

  package var id: String
  package var digest: String
  package var manifest: String
  package var createdAt: Date
  package var activatedAt: Date?
  package var activationError: String?

  package init(_ value: ConfigurationRevision) {
    self.id = value.id
    self.digest = value.digest
    self.manifest = value.manifest
    self.createdAt = value.createdAt
    self.activatedAt = value.activatedAt
    self.activationError = value.activationError
  }

  package var value: ConfigurationRevision {
    ConfigurationRevision(
      id: id,
      digest: digest,
      manifest: manifest,
      createdAt: createdAt,
      activatedAt: activatedAt,
      activationError: activationError
    )
  }
}

package struct AuditEventRecord: Codable, FetchableRecord, PersistableRecord {
  package static let databaseTableName = "auditEvents"

  package var id: String
  package var occurredAt: Date
  package var requestID: String
  package var mcpRequestID: String?
  package var invocationID: String?
  package var parentRequestID: String?
  package var ticketID: String?
  package var caller: String
  package var principalDigest: String?
  package var transport: String?
  package var socketConnectionID: String?
  package var tunnelInstanceID: String?
  package var tunnelProfileID: String?
  package var profileID: String
  package var projectID: String?
  package var capabilityID: String
  package var decision: String
  package var errorCode: String?
  package var errorDetailsJSON: String?
  package var durationMilliseconds: Int?
  package var inputDigest: String?
  package var outputDigest: String?
  package var outputByteCount: Int?
  package var outputTruncated: Bool?

  package init(_ value: AuditEvent) throws {
    self.id = value.id
    self.occurredAt = value.occurredAt
    self.requestID = value.requestID
    self.mcpRequestID = value.mcpRequestID
    self.invocationID = value.invocationID
    self.parentRequestID = value.parentRequestID
    self.ticketID = value.ticketID
    self.caller = value.caller.rawValue
    self.principalDigest = value.principalDigest
    self.transport = value.transport
    self.socketConnectionID = value.socketConnectionID
    self.tunnelInstanceID = value.tunnelInstanceID
    self.tunnelProfileID = value.tunnelProfileID
    self.profileID = value.profileID.rawValue
    self.projectID = value.projectID
    self.capabilityID = value.capabilityID
    self.decision = value.decision.rawValue
    self.errorCode = value.errorCode
    self.errorDetailsJSON = try value.errorDetails.map {
      String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
    }
    self.durationMilliseconds = value.durationMilliseconds
    self.inputDigest = value.inputDigest
    self.outputDigest = value.outputDigest
    self.outputByteCount = value.outputByteCount
    self.outputTruncated = value.outputTruncated
  }

  /// Retention affects observation only; permission and execution authority live
  /// in separate tables and are never reconstructed from these rows.
  package func insertRetained(
    _ database: Database, now: Date = Date(), maximumEntries: Int = 1_000_000
  ) throws {
    try insert(database)
    try database.execute(
      sql: "DELETE FROM auditEvents WHERE occurredAt < ?",
      arguments: [now.addingTimeInterval(-90 * 86_400)])
    try database.execute(
      sql: """
        DELETE FROM auditEvents WHERE id IN (
          SELECT id FROM auditEvents ORDER BY occurredAt DESC, id DESC LIMIT -1 OFFSET ?
        )
        """, arguments: [max(1, min(maximumEntries, 1_000_000))])
  }

  package func value() throws -> AuditEvent {
    guard let caller = GatewayCallerKind(rawValue: caller),
      let profileID = GatewayProfileID(rawValue: profileID),
      let decision = AuditDecision(rawValue: decision)
    else {
      throw GatewayDatabaseError.invalidStoredValue("Audit event contains unknown enum values.")
    }
    return AuditEvent(
      id: id,
      occurredAt: occurredAt,
      requestID: requestID,
      mcpRequestID: mcpRequestID,
      invocationID: invocationID,
      parentRequestID: parentRequestID,
      ticketID: ticketID,
      caller: caller,
      principalDigest: principalDigest,
      transport: transport,
      socketConnectionID: socketConnectionID,
      tunnelInstanceID: tunnelInstanceID,
      tunnelProfileID: tunnelProfileID,
      profileID: profileID,
      projectID: projectID,
      capabilityID: capabilityID,
      decision: decision,
      errorCode: errorCode,
      errorDetails: try errorDetailsJSON.map {
        try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
      },
      durationMilliseconds: durationMilliseconds,
      inputDigest: inputDigest,
      outputDigest: outputDigest,
      outputByteCount: outputByteCount,
      outputTruncated: outputTruncated
    )
  }
}
