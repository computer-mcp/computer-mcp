import Foundation
import GRDB

package final class GatewayDatabase: @unchecked Sendable {
  private let writer: any DatabaseWriter

  package init(path: String) throws {
    self.writer = try DatabaseQueue(path: path)
    try Self.migrator.migrate(writer)
  }

  package init(inMemory: Void) throws {
    self.writer = try DatabaseQueue()
    try Self.migrator.migrate(writer)
  }

  package func saveWorkspace(_ workspace: RegisteredWorkspace) throws {
    try writer.write { database in
      try WorkspaceRecord(workspace).save(database)
    }
  }

  package func workspaces() throws -> [RegisteredWorkspace] {
    try writer.read { database in
      try WorkspaceRecord
        .order(Column("displayName").collating(.nocase), Column("id"))
        .fetchAll(database)
        .map(\.value)
    }
  }

  package func workspace(id: String) throws -> RegisteredWorkspace? {
    try writer.read { database in
      try WorkspaceRecord.fetchOne(database, key: id)?.value
    }
  }

  package func deleteWorkspace(id: String) throws {
    _ = try writer.write { database in
      try WorkspaceRecord.deleteOne(database, key: id)
    }
  }

  package func saveRuntimeSetting(
    key: String,
    value: String,
    updatedAt: Date = Date()
  ) throws {
    try writer.write { database in
      try RuntimeSettingRecord(
        key: key,
        value: value,
        updatedAt: updatedAt
      ).save(database)
    }
  }

  package func runtimeSetting(key: String) throws -> String? {
    try writer.read { database in
      try RuntimeSettingRecord.fetchOne(database, key: key)?.value
    }
  }

  package func saveProfile(_ profile: ProfileGrant, updatedAt: Date = Date()) throws {
    try profile.validate()
    try writer.write { database in
      try ProfileRecord(profile, updatedAt: updatedAt).save(database)
    }
  }

  package func profiles() throws -> [ProfileGrant] {
    try writer.read { database in
      try ProfileRecord.order(Column("id")).fetchAll(database).map { try $0.value() }
    }
  }

  package func saveProviderState(_ state: ProviderState) throws {
    try writer.write { database in
      try ProviderStateRecord(state).save(database)
    }
  }

  package func providerStates() throws -> [ProviderState] {
    try writer.read { database in
      try ProviderStateRecord.order(Column("id")).fetchAll(database).map(\.value)
    }
  }

  package func saveConfigurationRevision(_ revision: ConfigurationRevision) throws {
    try writer.write { database in
      try ConfigurationRevisionRecord(revision).save(database)
    }
  }

  package func configurationRevisions(limit: Int = 50) throws -> [ConfigurationRevision] {
    try writer.read { database in
      try ConfigurationRevisionRecord
        .order(Column("createdAt").desc, Column("id").desc)
        .limit(max(1, min(limit, 1_000)))
        .fetchAll(database)
        .map(\.value)
    }
  }

  package func recordAudit(_ event: AuditEvent) throws {
    try writer.write { database in
      try AuditEventRecord(event).insert(database)
    }
  }

  package func auditEvents(limit: Int = 200) throws -> [AuditEvent] {
    try writer.read { database in
      try AuditEventRecord
        .order(Column("occurredAt").desc, Column("id").desc)
        .limit(max(1, min(limit, 10_000)))
        .fetchAll(database)
        .map { try $0.value() }
    }
  }

  package func auditEvent(requestID: String) throws -> AuditEvent? {
    try writer.read { database in
      try AuditEventRecord
        .filter(Column("requestID") == requestID)
        .order(Column("occurredAt").desc, Column("id").desc)
        .fetchOne(database)
        .map { try $0.value() }
    }
  }

  package func auditEvents(requestID: String) throws -> [AuditEvent] {
    try writer.read { database in
      try AuditEventRecord
        .filter(Column("requestID") == requestID)
        .order(Column("occurredAt"), Column("id"))
        .fetchAll(database)
        .map { try $0.value() }
    }
  }

  @discardableResult
  package func bindMCPRequestID(
    _ mcpRequestID: String,
    toGatewayRequestID gatewayRequestID: String,
    socketConnectionID: String
  ) throws -> Bool {
    try writer.write { database in
      guard
        var record =
          try AuditEventRecord
          .filter(Column("requestID") == gatewayRequestID)
          .filter(Column("socketConnectionID") == socketConnectionID)
          .order(Column("occurredAt").desc, Column("id").desc)
          .fetchOne(database)
      else {
        return false
      }
      guard record.mcpRequestID == nil || record.mcpRequestID == mcpRequestID else {
        return false
      }
      record.mcpRequestID = mcpRequestID
      try record.update(database)
      try AuditEventRecord
        .filter(Column("parentRequestID") == gatewayRequestID)
        .updateAll(database, Column("mcpRequestID").set(to: mcpRequestID))
      return true
    }
  }

  package func saveOperationTicket(_ ticket: OperationTicket) throws {
    try writer.write { database in
      try OperationTicketRecord(ticket).save(database)
    }
  }

  package func operationTicket(id: String) throws -> OperationTicket? {
    try writer.read { database in
      try OperationTicketRecord.fetchOne(database, key: id)?.value()
    }
  }

  package func beginOperationTicket(
    id: String,
    principalID: String,
    invocationID: String,
    parentRequestID: String,
    at date: Date = Date()
  ) throws -> OperationTicket {
    let outcome = try writer.write { database -> OperationTicketBeginOutcome in
      guard var record = try OperationTicketRecord.fetchOne(database, key: id) else {
        return .rejected(.operationTicketUnknown(id))
      }
      guard record.principalID == principalID else {
        return .rejected(.operationTicketPrincipalMismatch(id))
      }
      guard record.state == OperationTicketState.prepared.rawValue else {
        return .rejected(
          .operationTicketUnavailable(
            id: id,
            state: record.state
          )
        )
      }
      guard record.expiresAt > date else {
        record.state = OperationTicketState.failed.rawValue
        record.completedAt = date
        record.failureCode = "operations.ticket_expired"
        try record.update(database)
        return .rejected(.operationTicketExpired(id))
      }
      record.state = OperationTicketState.executing.rawValue
      record.invocationID = invocationID
      record.parentRequestID = parentRequestID
      record.executingAt = date
      try record.update(database)
      return .began(try record.value())
    }
    switch outcome {
    case .began(let ticket):
      return ticket
    case .rejected(let error):
      throw error
    }
  }

  package func finishOperationTicket(
    id: String,
    invocationID: String,
    state: OperationTicketState,
    failureCode: String? = nil,
    at date: Date = Date()
  ) throws -> OperationTicket {
    guard state == .succeeded || state == .failed else {
      throw GatewayDatabaseError.invalidOperationTicketTransition(
        "Operation ticket completion state must be succeeded or failed."
      )
    }
    return try writer.write { database in
      guard var record = try OperationTicketRecord.fetchOne(database, key: id) else {
        throw GatewayDatabaseError.operationTicketUnknown(id)
      }
      guard record.state == OperationTicketState.executing.rawValue,
        record.invocationID == invocationID
      else {
        throw GatewayDatabaseError.operationTicketUnavailable(
          id: id,
          state: record.state
        )
      }
      record.state = state.rawValue
      record.completedAt = date
      record.failureCode = state == .failed ? failureCode : nil
      try record.update(database)
      return try record.value()
    }
  }

  @discardableResult
  package func failPreparedOperationTicket(
    id: String,
    principalID: String,
    failureCode: String,
    at date: Date = Date()
  ) throws -> OperationTicket {
    try writer.write { database in
      guard var record = try OperationTicketRecord.fetchOne(database, key: id) else {
        throw GatewayDatabaseError.operationTicketUnknown(id)
      }
      guard record.principalID == principalID else {
        throw GatewayDatabaseError.operationTicketPrincipalMismatch(id)
      }
      guard record.state == OperationTicketState.prepared.rawValue else {
        throw GatewayDatabaseError.operationTicketUnavailable(
          id: id,
          state: record.state
        )
      }
      record.state = OperationTicketState.failed.rawValue
      record.completedAt = date
      record.failureCode = failureCode
      try record.update(database)
      return try record.value()
    }
  }

  private static let migrator: DatabaseMigrator = {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("initial-schema") { database in
      try database.create(table: "workspaces") { table in
        table.column("id", .text).primaryKey()
        table.column("displayName", .text).notNull()
        table.column("rootPath", .text).notNull()
        table.column("bookmarkData", .blob)
        table.column("bookmarkIsStale", .boolean).notNull()
        table.column("createdAt", .datetime).notNull()
        table.column("updatedAt", .datetime).notNull()
      }
      try database.create(table: "profiles") { table in
        table.column("id", .text).primaryKey()
        table.column("capabilityIDsJSON", .text).notNull()
        table.column("workspaceIDsJSON", .text).notNull()
        table.column("allowedCallersJSON", .text).notNull()
        table.column("fullShellEnabled", .boolean).notNull()
        table.column("updatedAt", .datetime).notNull()
      }
      try database.create(table: "providerStates") { table in
        table.column("id", .text).primaryKey()
        table.column("kind", .text).notNull()
        table.column("executablePath", .text)
        table.column("observedVersion", .text)
        table.column("health", .text).notNull()
        table.column("detail", .text)
        table.column("checkedAt", .datetime).notNull()
      }
      try database.create(table: "configurationRevisions") { table in
        table.column("id", .text).primaryKey()
        table.column("digest", .text).notNull()
        table.column("manifest", .text).notNull()
        table.column("createdAt", .datetime).notNull()
        table.column("activatedAt", .datetime)
        table.column("activationError", .text)
      }
      try database.create(table: "auditEvents") { table in
        table.column("id", .text).primaryKey()
        table.column("occurredAt", .datetime).notNull()
        table.column("requestID", .text).notNull()
        table.column("mcpRequestID", .text)
        table.column("invocationID", .text)
        table.column("parentRequestID", .text)
        table.column("ticketID", .text)
        table.column("caller", .text).notNull()
        table.column("transport", .text)
        table.column("socketConnectionID", .text)
        table.column("tunnelInstanceID", .text)
        table.column("tunnelProfileID", .text)
        table.column("profileID", .text).notNull()
        table.column("workspaceID", .text)
        table.column("capabilityID", .text).notNull()
        table.column("decision", .text).notNull()
        table.column("errorCode", .text)
        table.column("durationMilliseconds", .integer)
        table.column("inputDigest", .text)
        table.column("outputDigest", .text)
        table.column("outputByteCount", .integer)
        table.column("outputTruncated", .boolean)
      }
      try database.create(
        index: "auditEvents_on_occurredAt",
        on: "auditEvents",
        columns: ["occurredAt"]
      )
      try database.create(
        index: "auditEvents_on_mcpRequestID",
        on: "auditEvents",
        columns: ["mcpRequestID"]
      )
      try database.create(
        index: "auditEvents_on_invocationID",
        on: "auditEvents",
        columns: ["invocationID"]
      )
      try database.create(
        index: "auditEvents_on_ticketID",
        on: "auditEvents",
        columns: ["ticketID"]
      )
      try database.create(
        index: "auditEvents_on_socketConnectionID",
        on: "auditEvents",
        columns: ["socketConnectionID"]
      )
      try database.create(
        index: "auditEvents_on_tunnelInstanceID",
        on: "auditEvents",
        columns: ["tunnelInstanceID"]
      )
      try database.create(table: "operationTickets") { table in
        table.column("id", .text).primaryKey()
        table.column("capabilityID", .text).notNull()
        table.column("caller", .text).notNull()
        table.column("profileID", .text).notNull()
        table.column("principalID", .text).notNull()
        table.column("workspaceID", .text)
        table.column("inputDigest", .text).notNull()
        table.column("stateDigest", .text)
        table.column("state", .text).notNull()
        table.column("prepareRequestID", .text).notNull()
        table.column("invocationID", .text)
        table.column("parentRequestID", .text)
        table.column("createdAt", .datetime).notNull()
        table.column("expiresAt", .datetime).notNull()
        table.column("executingAt", .datetime)
        table.column("completedAt", .datetime)
        table.column("failureCode", .text)
      }
      try database.create(table: "runtimeSettings") { table in
        table.column("key", .text).primaryKey()
        table.column("value", .text).notNull()
        table.column("updatedAt", .datetime).notNull()
      }
    }
    return migrator
  }()
}

private struct RuntimeSettingRecord: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "runtimeSettings"

  var key: String
  var value: String
  var updatedAt: Date
}

private enum OperationTicketBeginOutcome {
  case began(OperationTicket)
  case rejected(GatewayDatabaseError)
}

private struct WorkspaceRecord: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "workspaces"

  var id: String
  var displayName: String
  var rootPath: String
  var bookmarkData: Data?
  var bookmarkIsStale: Bool
  var createdAt: Date
  var updatedAt: Date

  init(_ value: RegisteredWorkspace) {
    self.id = value.id
    self.displayName = value.displayName
    self.rootPath = value.rootPath
    self.bookmarkData = value.bookmarkData
    self.bookmarkIsStale = value.bookmarkIsStale
    self.createdAt = value.createdAt
    self.updatedAt = value.updatedAt
  }

  var value: RegisteredWorkspace {
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

private struct ProfileRecord: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "profiles"

  var id: String
  var capabilityIDsJSON: String
  var workspaceIDsJSON: String
  var allowedCallersJSON: String
  var fullShellEnabled: Bool
  var updatedAt: Date

  init(_ value: ProfileGrant, updatedAt: Date) throws {
    self.id = value.id.rawValue
    self.capabilityIDsJSON = try Self.encode(value.capabilityIDs)
    self.workspaceIDsJSON = try Self.encode(value.workspaceIDs)
    self.allowedCallersJSON = try Self.encode(Set(value.allowedCallers.map(\.rawValue)))
    self.fullShellEnabled = value.fullShellEnabled
    self.updatedAt = updatedAt
  }

  func value() throws -> ProfileGrant {
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
      fullShellEnabled: fullShellEnabled
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

private struct ProviderStateRecord: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "providerStates"

  var id: String
  var kind: String
  var executablePath: String?
  var observedVersion: String?
  var health: String
  var detail: String?
  var checkedAt: Date

  init(_ value: ProviderState) {
    self.id = value.id
    self.kind = value.kind
    self.executablePath = value.executablePath
    self.observedVersion = value.observedVersion
    self.health = value.health
    self.detail = value.detail
    self.checkedAt = value.checkedAt
  }

  var value: ProviderState {
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

private struct ConfigurationRevisionRecord: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "configurationRevisions"

  var id: String
  var digest: String
  var manifest: String
  var createdAt: Date
  var activatedAt: Date?
  var activationError: String?

  init(_ value: ConfigurationRevision) {
    self.id = value.id
    self.digest = value.digest
    self.manifest = value.manifest
    self.createdAt = value.createdAt
    self.activatedAt = value.activatedAt
    self.activationError = value.activationError
  }

  var value: ConfigurationRevision {
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

private struct AuditEventRecord: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "auditEvents"

  var id: String
  var occurredAt: Date
  var requestID: String
  var mcpRequestID: String?
  var invocationID: String?
  var parentRequestID: String?
  var ticketID: String?
  var caller: String
  var transport: String?
  var socketConnectionID: String?
  var tunnelInstanceID: String?
  var tunnelProfileID: String?
  var profileID: String
  var workspaceID: String?
  var capabilityID: String
  var decision: String
  var errorCode: String?
  var durationMilliseconds: Int?
  var inputDigest: String?
  var outputDigest: String?
  var outputByteCount: Int?
  var outputTruncated: Bool?

  init(_ value: AuditEvent) {
    self.id = value.id
    self.occurredAt = value.occurredAt
    self.requestID = value.requestID
    self.mcpRequestID = value.mcpRequestID
    self.invocationID = value.invocationID
    self.parentRequestID = value.parentRequestID
    self.ticketID = value.ticketID
    self.caller = value.caller.rawValue
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

  func value() throws -> AuditEvent {
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

private struct OperationTicketRecord: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "operationTickets"

  var id: String
  var capabilityID: String
  var caller: String
  var profileID: String
  var principalID: String
  var workspaceID: String?
  var inputDigest: String
  var stateDigest: String?
  var state: String
  var prepareRequestID: String
  var invocationID: String?
  var parentRequestID: String?
  var createdAt: Date
  var expiresAt: Date
  var executingAt: Date?
  var completedAt: Date?
  var failureCode: String?

  init(_ value: OperationTicket) {
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
  }

  func value() throws -> OperationTicket {
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
      failureCode: failureCode
    )
  }
}

package enum GatewayDatabaseError: Error, LocalizedError, Equatable {
  case invalidStoredValue(String)
  case invalidOperationTicketTransition(String)
  case operationTicketUnknown(String)
  case operationTicketPrincipalMismatch(String)
  case operationTicketExpired(String)
  case operationTicketUnavailable(id: String, state: String)

  package var errorDescription: String? {
    switch self {
    case .invalidStoredValue(let message):
      return message
    case .invalidOperationTicketTransition(let message):
      return message
    case .operationTicketUnknown(let id):
      return "Unknown operation ticket '\(id)'."
    case .operationTicketPrincipalMismatch(let id):
      return "Operation ticket '\(id)' is bound to another principal."
    case .operationTicketExpired(let id):
      return "Operation ticket '\(id)' has expired."
    case .operationTicketUnavailable(let id, let state):
      return "Operation ticket '\(id)' cannot be claimed from state '\(state)'."
    }
  }
}
