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

package struct WorkspaceRecord: Codable, FetchableRecord, PersistableRecord {
  package static let databaseTableName = "workspaces"

  package var id: String
  package var displayName: String
  package var rootPath: String
  package var bookmarkData: Data?
  package var bookmarkIsStale: Bool
  package var createdAt: Date
  package var updatedAt: Date

  package init(_ value: RegisteredWorkspace) {
    self.id = value.id
    self.displayName = value.displayName
    self.rootPath = value.rootPath
    self.bookmarkData = value.bookmarkData
    self.bookmarkIsStale = value.bookmarkIsStale
    self.createdAt = value.createdAt
    self.updatedAt = value.updatedAt
  }

  package var value: RegisteredWorkspace {
    RegisteredWorkspace(
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

package struct WorkspaceCanonicalRootRecord: Codable, FetchableRecord, PersistableRecord {
  package static let databaseTableName = "workspaceCanonicalRoots"

  package var canonicalRootPath: String
  package var workspaceID: String
  package var createdAt: Date

  package init(canonicalRootPath: String, workspaceID: String, createdAt: Date) {
    self.canonicalRootPath = canonicalRootPath
    self.workspaceID = workspaceID
    self.createdAt = createdAt
  }
}

package struct WorkspaceAliasRecord: Codable, FetchableRecord, PersistableRecord {
  package static let databaseTableName = "workspaceAliases"

  package var aliasWorkspaceID: String
  package var canonicalWorkspaceID: String
  package var canonicalRootPath: String
  package var migratedAt: Date

  package init(
    aliasWorkspaceID: String, canonicalWorkspaceID: String, canonicalRootPath: String,
    migratedAt: Date
  ) {
    self.aliasWorkspaceID = aliasWorkspaceID
    self.canonicalWorkspaceID = canonicalWorkspaceID
    self.canonicalRootPath = canonicalRootPath
    self.migratedAt = migratedAt
  }
}

package struct WorkspaceDeduplicationReceiptRecord: Codable, FetchableRecord,
  PersistableRecord
{
  package static let databaseTableName = "workspaceDeduplicationReceipts"

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
  package static let databaseTableName = "profiles"

  package var id: String
  package var capabilityIDsJSON: String
  package var mcpServerIDsJSON: String
  package var workspaceIDsJSON: String
  package var allowedCallersJSON: String
  package var fullShellEnabled: Bool
  package var mode: String?
  package var confirmationPolicy: String?
  package var authorizationRevision: Int64
  package var updatedAt: Date

  package init(_ value: ProfileGrant, updatedAt: Date) throws {
    self.id = value.id.rawValue
    self.capabilityIDsJSON = try Self.encode(value.capabilityIDs)
    self.mcpServerIDsJSON = try Self.encode(value.mcpServerIDs)
    self.workspaceIDsJSON = try Self.encode(value.workspaceIDs)
    self.allowedCallersJSON = try Self.encode(Set(value.allowedCallers.map(\.rawValue)))
    self.fullShellEnabled = value.fullShellEnabled
    self.mode = value.mode.rawValue
    self.confirmationPolicy = value.confirmationPolicy.rawValue
    self.authorizationRevision = value.authorizationRevision
    self.updatedAt = updatedAt
  }

  package func value() throws -> ProfileGrant {
    guard let profileID = GatewayProfileID(rawValue: id) else {
      throw GatewayDatabaseError.invalidStoredValue("Unknown profile id '\(id)'.")
    }
    let callerValues: Set<String> = try Self.decode(allowedCallersJSON)
    let callers = try Set(
      callerValues.map { value in
        guard let caller = GatewayCallerKind(rawValue: value) else {
          throw GatewayDatabaseError.invalidStoredValue("Unknown caller '\(value)'.")
        }
        return caller
      })
    return ProfileGrant(
      id: profileID,
      capabilityIDs: try Self.decode(capabilityIDsJSON),
      workspaceIDs: try Self.decode(workspaceIDsJSON),
      allowedCallers: callers,
      fullShellEnabled: fullShellEnabled,
      mcpServerIDs: try Self.decode(mcpServerIDsJSON),
      mode: try mode.map {
        guard let value = GatewayPermissionMode(rawValue: $0) else {
          throw GatewayDatabaseError.invalidStoredValue("Invalid profile permission mode.")
        }
        return value
      } ?? .legacy(profileID: profileID, fullShellEnabled: fullShellEnabled),
      confirmationPolicy: try confirmationPolicy.map {
        guard let value = GatewayConfirmationPolicy(rawValue: $0) else {
          throw GatewayDatabaseError.invalidStoredValue("Invalid profile confirmation policy.")
        }
        return value
      } ?? .riskBased,
      authorizationRevision: authorizationRevision
    )
  }

  private static func encode(_ value: Set<String>) throws -> String {
    let data = try JSONEncoder().encode(value.sorted())
    guard let result = String(data: data, encoding: .utf8) else {
      throw GatewayDatabaseError.invalidStoredValue("Could not encode profile string set.")
    }
    return result
  }

  private static func decode(_ value: String) throws -> Set<String> {
    guard let data = value.data(using: .utf8) else {
      throw GatewayDatabaseError.invalidStoredValue("Profile string set is not UTF-8.")
    }
    return Set(try JSONDecoder().decode([String].self, from: data))
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
  package var workspaceID: String?
  package var capabilityID: String
  package var decision: String
  package var errorCode: String?
  package var durationMilliseconds: Int?
  package var inputDigest: String?
  package var outputDigest: String?
  package var outputByteCount: Int?
  package var outputTruncated: Bool?

  package init(_ value: AuditEvent) {
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
    self.workspaceID = value.workspaceID
    self.capabilityID = value.capabilityID
    self.decision = value.decision.rawValue
    self.errorCode = value.errorCode
    self.durationMilliseconds = value.durationMilliseconds
    self.inputDigest = value.inputDigest
    self.outputDigest = value.outputDigest
    self.outputByteCount = value.outputByteCount
    self.outputTruncated = value.outputTruncated
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
      workspaceID: workspaceID,
      capabilityID: capabilityID,
      decision: decision,
      errorCode: errorCode,
      durationMilliseconds: durationMilliseconds,
      inputDigest: inputDigest,
      outputDigest: outputDigest,
      outputByteCount: outputByteCount,
      outputTruncated: outputTruncated
    )
  }
}

package struct OperationTicketRecord: Codable, FetchableRecord, PersistableRecord {
  package static let databaseTableName = "operationTickets"

  package var id: String
  package var capabilityID: String
  package var caller: String
  package var profileID: String
  package var principalID: String
  package var workspaceID: String?
  package var inputDigest: String
  package var stateDigest: String?
  package var state: String
  package var prepareRequestID: String
  package var invocationID: String?
  package var parentRequestID: String?
  package var createdAt: Date
  package var expiresAt: Date
  package var executingAt: Date?
  package var completedAt: Date?
  package var failureCode: String?
  package var authorizationRevision: Int64?
  package var controlSessionID: String?
  package var controlSessionRevision: Int64?
  package var reviewSummary: String?
  package var reviewTitle: String?

  package init(_ value: OperationTicket) {
    self.id = value.id
    self.capabilityID = value.capabilityID
    self.caller = value.caller.rawValue
    self.profileID = value.profileID.rawValue
    self.principalID = value.principalID
    self.workspaceID = value.workspaceID
    self.inputDigest = value.inputDigest
    self.stateDigest = value.stateDigest
    self.state = value.state.rawValue
    self.prepareRequestID = value.prepareRequestID
    self.invocationID = value.invocationID
    self.parentRequestID = value.parentRequestID
    self.createdAt = value.createdAt
    self.expiresAt = value.expiresAt
    self.executingAt = value.executingAt
    self.completedAt = value.completedAt
    self.failureCode = value.failureCode
    self.authorizationRevision = value.authorizationRevision
    self.controlSessionID = value.controlSessionID
    self.controlSessionRevision = value.controlSessionRevision
    self.reviewSummary = value.reviewSummary
    self.reviewTitle = value.reviewTitle
  }

  package func value() throws -> OperationTicket {
    guard let caller = GatewayCallerKind(rawValue: caller),
      let profileID = GatewayProfileID(rawValue: profileID),
      let state = OperationTicketState(rawValue: state)
    else {
      throw GatewayDatabaseError.invalidStoredValue(
        "Operation ticket contains unknown enum values."
      )
    }
    return OperationTicket(
      id: id,
      capabilityID: capabilityID,
      caller: caller,
      profileID: profileID,
      principalID: principalID,
      workspaceID: workspaceID,
      inputDigest: inputDigest,
      stateDigest: stateDigest,
      state: state,
      prepareRequestID: prepareRequestID,
      invocationID: invocationID,
      parentRequestID: parentRequestID,
      createdAt: createdAt,
      expiresAt: expiresAt,
      executingAt: executingAt,
      completedAt: completedAt,
      failureCode: failureCode,
      authorizationRevision: authorizationRevision,
      controlSessionID: controlSessionID, controlSessionRevision: controlSessionRevision,
      reviewSummary: reviewSummary, reviewTitle: reviewTitle
    )
  }
}
