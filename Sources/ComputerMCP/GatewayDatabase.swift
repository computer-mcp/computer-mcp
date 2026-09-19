import CryptoKit
import Foundation
import GRDB

package final class GatewayDatabase: @unchecked Sendable {
  private let writer: any DatabaseWriter
  private let profileChangeLock = NSLock()
  private var profileChangeBroadcasters: [GatewayProfileID: GatewayToolChangeBroadcaster] = [:]
  let fileURL: URL?

  var mcpProcessOwnershipRoot: URL? {
    fileURL.map {
      $0.deletingLastPathComponent().appendingPathComponent(
        $0.lastPathComponent + ".mcp-processes", isDirectory: true)
    }
  }

  package init(path: String) throws {
    self.fileURL = URL(fileURLWithPath: path).standardizedFileURL
    var configuration = Configuration()
    // Independent management connections must acquire the write lock before checking revisions.
    configuration.busyMode = .timeout(5)
    self.writer = try DatabaseQueue(path: path, configuration: configuration)
    try Self.migrator.migrate(writer)
  }

  package init(inMemory: Void) throws {
    self.fileURL = nil
    self.writer = try DatabaseQueue()
    try Self.migrator.migrate(writer)
  }

  package func pluginStoreSnapshot() throws -> PluginStoreSnapshot {
    try writer.read { database in
      guard
        let row = try Row.fetchOne(
          database, sql: "SELECT revision, payloadJSON FROM pluginState WHERE id = 1")
      else {
        return PluginStoreSnapshot()
      }
      let payload: String = row["payloadJSON"]
      guard payload.utf8.count <= 4_194_304 else { throw PluginStoreError.invalidState }
      let state = try JSONDecoder().decode(PluginStoreSnapshot.self, from: Data(payload.utf8))
      let revision: Int64 = row["revision"]
      guard state.revision == revision else { throw PluginStoreError.invalidState }
      try state.validate()
      return state
    }
  }

  func savePluginStoreSnapshot(_ state: PluginStoreSnapshot, expectedRevision: Int64) throws {
    try state.validate()
    guard expectedRevision >= 0, expectedRevision < Int64.max,
      state.revision == expectedRevision + 1
    else {
      throw PluginStoreError.invalidState
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(state)
    guard data.count <= 4_194_304, let payload = String(data: data, encoding: .utf8) else {
      throw PluginStoreError.invalidState
    }
    try writer.write { database in
      let current =
        try Int64.fetchOne(database, sql: "SELECT revision FROM pluginState WHERE id = 1") ?? 0
      guard current == expectedRevision else {
        throw PluginStoreError.staleRevision(expected: expectedRevision, actual: current)
      }
      try database.execute(
        sql: """
          INSERT INTO pluginState (id, revision, payloadJSON) VALUES (1, ?, ?)
          ON CONFLICT(id) DO UPDATE SET revision = excluded.revision, payloadJSON = excluded.payloadJSON
          """, arguments: [state.revision, payload])
    }
  }

  package func saveWorkspace(_ workspace: RegisteredWorkspace) throws {
    try writer.write { database in
      try Self.saveWorkspace(workspace, in: database)
    }
  }

  /// Bookmark resolution must not overwrite a concurrent edit or recreate a removed registration.
  @discardableResult
  func saveWorkspace(_ workspace: RegisteredWorkspace, replacing expected: RegisteredWorkspace)
    throws -> Bool
  {
    try writer.write { database in
      guard workspace.id == expected.id,
        try WorkspaceRecord.fetchOne(database, key: expected.id)?.value == expected
      else { return false }
      try Self.saveWorkspace(workspace, in: database)
      return true
    }
  }

  private static func saveWorkspace(_ workspace: RegisteredWorkspace, in database: Database) throws
  {
    try WorkspaceRecord(workspace).save(database)
    let canonicalRoot = Self.canonicalWorkspaceRoot(workspace.rootPath)
    try WorkspaceCanonicalRootRecord
      .filter(Column("workspaceID") == workspace.id)
      .filter(Column("canonicalRootPath") != canonicalRoot)
      .deleteAll(database)
    try WorkspaceCanonicalRootRecord(
      canonicalRootPath: canonicalRoot,
      workspaceID: workspace.id,
      createdAt: workspace.createdAt
    ).insert(database, onConflict: .ignore)
  }

  /// Local recovery ownership is separate from exported plugin settings.
  func pluginOwnedDirectories() throws -> [PluginOwnedDirectory] {
    try writer.read { database in
      let rows = try Row.fetchAll(
        database, sql: "SELECT id, payloadJSON FROM pluginOwnedDirectories LIMIT 4097")
      guard rows.count <= 4096 else { throw PluginStoreError.invalidState }
      return try rows.map { row in
        let payload: String = row["payloadJSON"]
        guard payload.utf8.count <= 16_384 else { throw PluginStoreError.invalidState }
        let record = try JSONDecoder().decode(PluginOwnedDirectory.self, from: Data(payload.utf8))
        let id: String = row["id"]
        guard id == record.installationID else { throw PluginStoreError.invalidState }
        try record.validate()
        return record
      }
    }
  }

  func recordPluginDirectory(_ record: PluginOwnedDirectory) throws {
    try record.validate()
    let payload = try JSONEncoder().encode(record)
    guard payload.count <= 16_384 else { throw PluginStoreError.invalidState }
    try writer.write { database in
      let count =
        try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM pluginOwnedDirectories") ?? 0
      guard count < 4096 else { throw PluginStoreError.invalidState }
      try database.execute(
        sql: "INSERT INTO pluginOwnedDirectories (id, payloadJSON) VALUES (?, ?)",
        arguments: [record.installationID, String(decoding: payload, as: UTF8.self)])
    }
  }

  func forgetPluginDirectory(_ record: PluginOwnedDirectory) throws {
    try writer.write { database in
      guard
        let payload = try String.fetchOne(
          database, sql: "SELECT payloadJSON FROM pluginOwnedDirectories WHERE id = ?",
          arguments: [record.installationID])
      else { return }
      guard payload.utf8.count <= 16_384,
        try JSONDecoder().decode(PluginOwnedDirectory.self, from: Data(payload.utf8)) == record
      else { throw PluginStoreError.invalidState }
      try database.execute(
        sql: "DELETE FROM pluginOwnedDirectories WHERE id = ?", arguments: [record.installationID])
    }
  }

  package func registerWorkspaceIdempotently(
    _ proposed: RegisteredWorkspace
  ) throws -> (workspace: RegisteredWorkspace, created: Bool) {
    let canonicalRoot = Self.canonicalWorkspaceRoot(proposed.rootPath)
    return try writer.write { database in
      if let binding = try WorkspaceCanonicalRootRecord.fetchOne(
        database,
        key: canonicalRoot
      ) {
        if let existing = try WorkspaceRecord.fetchOne(database, key: binding.workspaceID) {
          return (existing.value, false)
        }
        _ = try WorkspaceCanonicalRootRecord.deleteOne(database, key: canonicalRoot)
      }
      if let existing = try WorkspaceRecord.fetchAll(database).first(where: {
        Self.canonicalWorkspaceRoot($0.rootPath) == canonicalRoot
      }) {
        try WorkspaceCanonicalRootRecord(
          canonicalRootPath: canonicalRoot,
          workspaceID: existing.id,
          createdAt: existing.createdAt
        ).insert(database, onConflict: .ignore)
        return (existing.value, false)
      }
      try WorkspaceRecord(proposed).insert(database)
      try WorkspaceCanonicalRootRecord(
        canonicalRootPath: canonicalRoot,
        workspaceID: proposed.id,
        createdAt: proposed.createdAt
      ).insert(database)
      return (proposed, true)
    }
  }

  package func workspaces() throws -> [RegisteredWorkspace] {
    try writer.read { database in
      let aliasIDs = Set(
        try WorkspaceAliasRecord.fetchAll(database).map(\.aliasWorkspaceID)
      )
      return
        try WorkspaceRecord
        .order(Column("displayName").collating(.nocase), Column("id"))
        .fetchAll(database)
        .filter { !aliasIDs.contains($0.id) }
        .map(\.value)
    }
  }

  package func workspace(id: String) throws -> RegisteredWorkspace? {
    try writer.read { database in
      let resolvedID =
        try WorkspaceAliasRecord.fetchOne(database, key: id)?.canonicalWorkspaceID ?? id
      return try WorkspaceRecord.fetchOne(database, key: resolvedID)?.value
    }
  }

  package func deleteWorkspace(id: String) throws {
    _ = try writer.write { database in
      let canonicalID =
        try WorkspaceAliasRecord.fetchOne(database, key: id)?.canonicalWorkspaceID ?? id
      let aliasIDs =
        try WorkspaceAliasRecord
        .filter(Column("canonicalWorkspaceID") == canonicalID)
        .fetchAll(database)
        .map(\.aliasWorkspaceID)
      try WorkspaceAliasRecord
        .filter(Column("canonicalWorkspaceID") == canonicalID)
        .deleteAll(database)
      try WorkspaceCanonicalRootRecord
        .filter(Column("workspaceID") == canonicalID)
        .deleteAll(database)
      for aliasID in aliasIDs {
        _ = try WorkspaceRecord.deleteOne(database, key: aliasID)
      }
      return try WorkspaceRecord.deleteOne(database, key: canonicalID)
    }
  }

  package func workspaceDeduplicationPlan() throws -> WorkspaceDeduplicationPlan {
    try writer.read { database in
      try Self.workspaceDeduplicationPlan(database)
    }
  }

  package func applyWorkspaceDeduplication(
    expectedPlanDigest: String,
    allowMetadataConflicts: Bool,
    now: Date = Date()
  ) throws -> WorkspaceDeduplicationResult {
    try writer.write { database in
      let plan = try Self.workspaceDeduplicationPlan(database)
      guard plan.planDigest == expectedPlanDigest else {
        throw WorkspaceDeduplicationError.planChanged(
          expected: expectedPlanDigest,
          actual: plan.planDigest
        )
      }
      let conflictIDs = plan.groups.filter(\.hasMetadataConflict)
        .flatMap(\.duplicateWorkspaceIDs)
        .sorted()
      if !allowMetadataConflicts, !conflictIDs.isEmpty {
        throw WorkspaceDeduplicationError.metadataConflict(workspaceIDs: conflictIDs)
      }

      var updatedProfileIDs: Set<String> = []
      for group in plan.groups {
        for duplicateID in group.duplicateWorkspaceIDs {
          try WorkspaceAliasRecord(
            aliasWorkspaceID: duplicateID,
            canonicalWorkspaceID: group.canonicalWorkspaceID,
            canonicalRootPath: group.canonicalRootPath,
            migratedAt: now
          ).save(database)
        }
        for row in try ProfileRecord.fetchAll(database) {
          var profile = try row.value()
          let duplicateReferences = profile.workspaceIDs.intersection(
            group.duplicateWorkspaceIDs
          )
          guard !duplicateReferences.isEmpty else { continue }
          profile.workspaceIDs.subtract(duplicateReferences)
          profile.workspaceIDs.insert(group.canonicalWorkspaceID)
          try ProfileRecord(profile, updatedAt: now).save(database)
          updatedProfileIDs.insert(profile.id.rawValue)
        }
      }

      let result = WorkspaceDeduplicationResult(
        receiptID: UUID().uuidString,
        planDigest: plan.planDigest,
        canonicalWorkspaceIDs: plan.groups.map(\.canonicalWorkspaceID).sorted(),
        aliasedWorkspaceIDs: plan.groups.flatMap(\.duplicateWorkspaceIDs).sorted(),
        updatedProfileIDs: updatedProfileIDs.sorted(),
        appliedAt: now
      )
      let encoder = CanonicalJSONCoding.encoder(outputFormatting: [.sortedKeys])
      try WorkspaceDeduplicationReceiptRecord(
        id: result.receiptID,
        planDigest: result.planDigest,
        appliedAt: now,
        payloadJSON: String(decoding: try encoder.encode(result), as: UTF8.self)
      ).insert(database)
      return result
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

  package func saveProfile(
    _ profile: ProfileGrant, updatedAt: Date = Date(), expectedRevision: Int64? = nil
  ) throws {
    try profile.validate()
    try writer.write { database in
      let current = try ProfileRecord.fetchOne(database, key: profile.id.rawValue)
      let revision = current?.authorizationRevision ?? 0
      guard expectedRevision == nil || expectedRevision == revision else {
        throw GatewayDatabaseError.invalidStoredValue(
          "Profile authorization changed; reload before saving.")
      }
      guard revision < Int64.max else {
        throw GatewayDatabaseError.invalidStoredValue("Profile authorization revision exhausted.")
      }
      var saved = profile
      saved.authorizationRevision = revision + 1
      try ProfileRecord(saved, updatedAt: updatedAt).save(database)
      try database.execute(
        sql: """
          UPDATE operationTickets SET state = ?, completedAt = ?, failureCode = ?
          WHERE profileID = ? AND state IN (?, ?, ?)
          """,
        arguments: [
          OperationTicketState.denied.rawValue, updatedAt,
          "operations.authorization_changed", profile.id.rawValue,
          OperationTicketState.prepared.rawValue, OperationTicketState.pendingApproval.rawValue,
          OperationTicketState.approved.rawValue,
        ])
    }
    profileChangeLock.withLock { profileChangeBroadcasters[profile.id] }?.send()
  }

  func profileChanges(for profileID: GatewayProfileID) -> AsyncStream<Void> {
    let broadcaster = profileChangeLock.withLock {
      if let existing = profileChangeBroadcasters[profileID] { return existing }
      let new = GatewayToolChangeBroadcaster()
      profileChangeBroadcasters[profileID] = new
      return new
    }
    return broadcaster.stream()
  }

  package func profiles() throws -> [ProfileGrant] {
    try writer.read { database in
      try ProfileRecord.order(Column("id")).fetchAll(database).map { try $0.value() }
    }
  }

  func reserveMCPExecution(_ proposed: MCPExecutionRecord) throws
    -> (record: MCPExecutionRecord, inserted: Bool)
  {
    try writer.write { database in
      try Self.expireMCPOutput(in: database)
      if let existing = try Self.mcpExecution(key: proposed.key, in: database) {
        guard existing.inputDigest == proposed.inputDigest else {
          throw GatewayToolError.invalidArguments(
            "[request.conflict] This request_id is already bound to different input.")
        }
        return (existing, false)
      }
      // Keep deduplication receipts even after output expires. Evicting identity would
      // silently authorize replay; capacity exhaustion instead fails before dispatch.
      guard try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM mcpExecutions") ?? 0 < 10_000
      else {
        throw GatewayToolError.executionFailed(
          "MCP execution receipt capacity reached; no request was dispatched.")
      }
      try Self.saveMCPExecution(proposed, in: database)
      return (proposed, true)
    }
  }

  func mcpExecution(scope: String, serverID: String, requestID: String) throws
    -> MCPExecutionRecord?
  {
    let key = MCPExecutionRecord.digest(
      .array([.string(scope), .string(serverID), .string(requestID)]))
    return try writer.write { database in
      try Self.expireMCPOutput(in: database)
      return try Self.mcpExecution(key: key, in: database)
    }
  }

  func updateMCPExecution(
    scope: String, serverID: String, requestID: String, instanceID: String,
    change: (inout MCPExecutionRecord) throws -> Void
  ) throws {
    let key = MCPExecutionRecord.digest(
      .array([.string(scope), .string(serverID), .string(requestID)]))
    try writer.write { database in
      guard var record = try Self.mcpExecution(key: key, in: database),
        record.instanceID == instanceID
      else {
        throw GatewayToolError.invalidArguments(
          "[request.stale_instance] Execution ownership no longer matches.")
      }
      try change(&record)
      try Self.saveMCPExecution(record, in: database)
      try Self.expireMCPOutput(in: database)
      // Output has a global bound independent of individual response sizes. Receipt
      // identity and terminal state survive eviction and remain queryable.
      var retained =
        try Int.fetchOne(
          database,
          sql: "SELECT COALESCE(SUM(length(CAST(outputJSON AS BLOB))), 0) FROM mcpExecutions") ?? 0
      if retained > 16_777_216 {
        let rows = try Row.fetchAll(
          database,
          sql:
            "SELECT id, length(CAST(outputJSON AS BLOB)) AS bytes FROM mcpExecutions WHERE outputJSON IS NOT NULL ORDER BY outputExpiresAt, id"
        )
        for row in rows where retained > 16_777_216 {
          let id: String = row["id"]
          let count: Int = row["bytes"]
          try database.execute(
            sql: "UPDATE mcpExecutions SET outputJSON = NULL WHERE id = ?", arguments: [id])
          retained -= count
        }
      }
    }
  }

  private static func expireMCPOutput(in database: Database) throws {
    try database.execute(
      sql:
        "UPDATE mcpExecutions SET outputJSON = NULL WHERE outputExpiresAt <= ? AND outputJSON IS NOT NULL",
      arguments: [Date().timeIntervalSince1970])
  }

  private static func mcpExecution(key: String, in database: Database) throws -> MCPExecutionRecord?
  {
    guard
      let row = try Row.fetchOne(
        database, sql: "SELECT metadataJSON, outputJSON FROM mcpExecutions WHERE id = ?",
        arguments: [key])
    else { return nil }
    let metadata: String = row["metadataJSON"]
    var record = try JSONDecoder().decode(MCPExecutionRecord.self, from: Data(metadata.utf8))
    record.outputJSON = row["outputJSON"]
    return record
  }

  private static func saveMCPExecution(_ record: MCPExecutionRecord, in database: Database) throws {
    var metadata = record
    metadata.outputJSON = nil
    let encoded = try JSONEncoder().encode(metadata)
    try database.execute(
      sql: """
        INSERT INTO mcpExecutions (id, metadataJSON, outputJSON, outputExpiresAt) VALUES (?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET metadataJSON = excluded.metadataJSON,
        outputJSON = excluded.outputJSON, outputExpiresAt = excluded.outputExpiresAt
        """,
      arguments: [
        record.key, String(decoding: encoded, as: UTF8.self), record.outputJSON,
        record.outputExpiresAt?.timeIntervalSince1970,
      ])
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
    try writer.write { database in
      try Self.expireOperationApprovals(in: database, at: Date())
      return try OperationTicketRecord.fetchOne(database, key: id)?.value()
    }
  }

  package func operationApprovals(limit: Int = 100) throws -> [OperationTicket] {
    try writer.write { database in
      try Self.expireOperationApprovals(in: database, at: Date())
      return
        try OperationTicketRecord
        .filter(Column("authorizationRevision") != nil)
        .order(Column("createdAt").desc, Column("id"))
        .limit(max(1, min(limit, 500))).fetchAll(database).map { try $0.value() }
    }
  }

  @discardableResult
  package func resolveOperationApproval(
    id: String, approved: Bool, resolver: GatewayCallerKind, at date: Date = Date()
  ) throws -> OperationTicket {
    guard resolver == .localApp || resolver == .localCLI else {
      throw GatewayDatabaseError.invalidOperationTicketTransition(
        "Only the local management interface may resolve host approvals.")
    }
    return try writer.write { database in
      try Self.expireOperationApprovals(in: database, at: date)
      guard var record = try OperationTicketRecord.fetchOne(database, key: id) else {
        throw GatewayDatabaseError.operationTicketUnknown(id)
      }
      guard record.state == OperationTicketState.pendingApproval.rawValue else {
        throw GatewayDatabaseError.operationTicketUnavailable(id: id, state: record.state)
      }
      if let profile = try ProfileRecord.fetchOne(database, key: record.profileID),
        record.authorizationRevision != profile.authorizationRevision
      {
        throw GatewayDatabaseError.invalidOperationTicketTransition(
          "Authorization changed after approval was requested.")
      }
      record.state =
        approved ? OperationTicketState.approved.rawValue : OperationTicketState.denied.rawValue
      record.completedAt = approved ? nil : date
      record.failureCode = approved ? nil : "operations.user_denied"
      try record.update(database)
      return try record.value()
    }
  }

  private static func expireOperationApprovals(in database: Database, at date: Date) throws {
    try database.execute(
      sql: """
        UPDATE operationTickets SET state = ?, completedAt = ?, failureCode = ?
        WHERE expiresAt <= ? AND state IN (?, ?, ?)
        """,
      arguments: [
        OperationTicketState.expired.rawValue, date, "operations.ticket_expired", date,
        OperationTicketState.prepared.rawValue, OperationTicketState.pendingApproval.rawValue,
        OperationTicketState.approved.rawValue,
      ])
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
      guard
        record.state == OperationTicketState.prepared.rawValue
          || record.state == OperationTicketState.approved.rawValue
      else {
        return .rejected(
          .operationTicketUnavailable(
            id: id,
            state: record.state
          )
        )
      }
      guard record.expiresAt > date else {
        record.state = OperationTicketState.expired.rawValue
        record.completedAt = date
        record.failureCode = "operations.ticket_expired"
        try record.update(database)
        return .rejected(.operationTicketExpired(id))
      }
      if let profile = try ProfileRecord.fetchOne(database, key: record.profileID),
        let revision = record.authorizationRevision, revision != profile.authorizationRevision
      {
        return .rejected(.operationTicketUnavailable(id: id, state: "authorization_changed"))
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
      guard
        [OperationTicketState.prepared, .pendingApproval, .approved].map(\.rawValue).contains(
          record.state)
      else {
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
    migrator.registerMigration("codex-approval-broker") { database in
      try database.create(table: "codexApprovals") { table in
        table.column("id", .text).primaryKey()
        table.column("upstreamRequestID", .text).notNull()
        table.column("kind", .text).notNull()
        table.column("risk", .text).notNull()
        table.column("state", .text).notNull()
        table.column("workspaceID", .text)
        table.column("workspacePath", .text).notNull()
        table.column("runtimeID", .text).notNull()
        table.column("threadID", .text)
        table.column("turnID", .text)
        table.column("itemID", .text)
        table.column("correlationID", .text).notNull()
        table.column("socketConnectionID", .text)
        table.column("tunnelInstanceID", .text)
        table.column("detailsJSON", .text).notNull()
        table.column("proposedActionJSON", .text).notNull()
        table.column("createdAt", .datetime).notNull()
        table.column("expiresAt", .datetime).notNull()
        table.column("resolvedAt", .datetime)
        table.column("decision", .text)
        table.column("scope", .text)
        table.column("resolutionReason", .text)
      }
      try database.create(
        index: "codexApprovals_on_workspace_state_createdAt",
        on: "codexApprovals",
        columns: ["workspaceID", "state", "createdAt"]
      )
      try database.create(
        index: "codexApprovals_on_runtimeID",
        on: "codexApprovals",
        columns: ["runtimeID"]
      )
      try database.create(
        index: "codexApprovals_on_correlationID",
        on: "codexApprovals",
        columns: ["correlationID"]
      )
    }
    migrator.registerMigration("codex-runtime-leases") { database in
      try database.create(table: "codexRuntimeLeases") { table in
        table.column("id", .text).primaryKey()
        table.column("workspaceID", .text)
        table.column("state", .text).notNull()
        table.column("updatedAt", .datetime).notNull()
        table.column("payloadJSON", .text).notNull()
      }
      try database.create(
        index: "codexRuntimeLeases_on_workspace_state_updatedAt",
        on: "codexRuntimeLeases",
        columns: ["workspaceID", "state", "updatedAt"]
      )
    }
    migrator.registerMigration("codex-orchestration-runs") { database in
      try database.create(table: "codexOrchestrationRuns") { table in
        table.column("id", .text).primaryKey()
        table.column("workspaceID", .text).notNull()
        table.column("state", .text).notNull()
        table.column("updatedAt", .datetime).notNull()
        table.column("payloadJSON", .text).notNull()
      }
      try database.create(
        index: "codexOrchestrationRuns_on_workspace_state_updatedAt",
        on: "codexOrchestrationRuns",
        columns: ["workspaceID", "state", "updatedAt"]
      )
    }
    migrator.registerMigration("codex-worktree-leases") { database in
      try database.create(table: "codexWorktreeLeases") { table in
        table.column("id", .text).primaryKey()
        table.column("workspaceID", .text).notNull()
        table.column("state", .text).notNull()
        table.column("heartbeatAt", .datetime).notNull()
        table.column("payloadJSON", .text).notNull()
      }
      try database.create(
        index: "codexWorktreeLeases_on_workspace_state_heartbeatAt",
        on: "codexWorktreeLeases",
        columns: ["workspaceID", "state", "heartbeatAt"]
      )
    }
    migrator.registerMigration("codex-managed-worktrees") { database in
      try database.create(table: "codexManagedWorktrees") { table in
        table.column("id", .text).primaryKey()
        table.column("sourceWorkspaceID", .text).notNull()
        table.column("workspaceID", .text).notNull().unique()
        table.column("state", .text).notNull()
        table.column("updatedAt", .datetime).notNull()
        table.column("payloadJSON", .text).notNull()
      }
      try database.create(
        index: "codexManagedWorktrees_on_source_state_updatedAt",
        on: "codexManagedWorktrees",
        columns: ["sourceWorkspaceID", "state", "updatedAt"]
      )
    }
    migrator.registerMigration("codex-thread-ownership") { database in
      try database.create(table: "codexThreadOwnership") { table in
        table.column("threadID", .text).primaryKey()
        table.column("workspaceID", .text)
        table.column("workspacePath", .text).notNull()
        table.column("runtimeID", .text).notNull()
        table.column("state", .text).notNull()
        table.column("createdAt", .datetime).notNull()
        table.column("updatedAt", .datetime).notNull()
      }
      try database.create(
        index: "codexThreadOwnership_on_workspace_state_updatedAt",
        on: "codexThreadOwnership",
        columns: ["workspaceID", "state", "updatedAt"]
      )
    }
    migrator.registerMigration("codex-scoped-elevation-grants") { database in
      try database.create(table: "codexElevationGrants") { table in
        table.column("id", .text).primaryKey()
        table.column("workspaceID", .text).notNull()
        table.column("profileID", .text).notNull()
        table.column("requestingCaller", .text).notNull()
        table.column("requestingConnectionID", .text)
        table.column("threadID", .text)
        table.column("state", .text).notNull()
        table.column("createdAt", .datetime).notNull()
        table.column("updatedAt", .datetime).notNull()
        table.column("payloadJSON", .text).notNull()
      }
      try database.create(
        index: "codexElevationGrants_on_workspace_profile_state_updatedAt",
        on: "codexElevationGrants",
        columns: ["workspaceID", "profileID", "state", "updatedAt"]
      )
      try database.create(
        index: "codexElevationGrants_on_thread_state",
        on: "codexElevationGrants",
        columns: ["threadID", "state"]
      )
    }
    migrator.registerMigration("workspace-canonical-roots") { database in
      try database.create(table: "workspaceCanonicalRoots") { table in
        table.column("canonicalRootPath", .text).primaryKey()
        table.column("workspaceID", .text).notNull()
        table.column("createdAt", .datetime).notNull()
      }
      try database.create(
        index: "workspaceCanonicalRoots_on_workspaceID",
        on: "workspaceCanonicalRoots",
        columns: ["workspaceID"]
      )
      let workspaces =
        try WorkspaceRecord
        .order(Column("createdAt"), Column("id"))
        .fetchAll(database)
      for workspace in workspaces {
        try WorkspaceCanonicalRootRecord(
          canonicalRootPath: GatewayDatabase.canonicalWorkspaceRoot(workspace.rootPath),
          workspaceID: workspace.id,
          createdAt: workspace.createdAt
        ).insert(database, onConflict: .ignore)
      }
    }
    migrator.registerMigration("workspace-deduplication-aliases") { database in
      try database.create(table: "workspaceAliases") { table in
        table.column("aliasWorkspaceID", .text).primaryKey()
        table.column("canonicalWorkspaceID", .text).notNull()
        table.column("canonicalRootPath", .text).notNull()
        table.column("migratedAt", .datetime).notNull()
      }
      try database.create(
        index: "workspaceAliases_on_canonicalWorkspaceID",
        on: "workspaceAliases",
        columns: ["canonicalWorkspaceID"]
      )
      try database.create(table: "workspaceDeduplicationReceipts") { table in
        table.column("id", .text).primaryKey()
        table.column("planDigest", .text).notNull()
        table.column("appliedAt", .datetime).notNull()
        table.column("payloadJSON", .text).notNull()
      }
    }
    migrator.registerMigration("codex-ownership-reconciliation-receipts") { database in
      try database.create(table: "codexOwnershipReconciliationReceipts") { table in
        table.column("id", .text).primaryKey()
        table.column("planDigest", .text).notNull()
        table.column("appliedAt", .datetime).notNull()
        table.column("payloadJSON", .text).notNull()
      }
    }
    migrator.registerMigration("profile-mcp-server-grants") { database in
      try database.alter(table: "profiles") { table in
        table.add(column: "mcpServerIDsJSON", .text).notNull().defaults(to: "[]")
      }
    }
    migrator.registerMigration("plugin-installation-state") { database in
      try database.create(table: "pluginState") { table in
        table.column("id", .integer).primaryKey()
        table.column("revision", .integer).notNull()
        table.column("payloadJSON", .text).notNull()
      }
    }
    migrator.registerMigration("plugin-owned-directories") { database in
      try database.create(table: "pluginOwnedDirectories") { table in
        table.column("id", .text).primaryKey()
        table.column("payloadJSON", .text).notNull()
      }
    }
    migrator.registerMigration("plugin-derived-workspaces") { database in
      try database.create(table: "pluginDerivedWorkspaces") { table in
        table.column("workspaceID", .text).primaryKey()
        table.column("origin", .text).notNull()
        table.column("sourceWorkspaceID", .text).notNull()
        table.column("receiptID", .text).notNull()
        table.column("payloadJSON", .text).notNull()
        table.uniqueKey(["origin", "sourceWorkspaceID", "receiptID"])
      }
    }
    migrator.registerMigration("mcp-execution-receipts") { database in
      try database.create(table: "mcpExecutions") { table in
        table.column("id", .text).primaryKey()
        table.column("metadataJSON", .text).notNull()
        table.column("outputJSON", .text)
        table.column("outputExpiresAt", .double)
      }
      try database.create(
        index: "mcpExecutions_on_outputExpiresAt", on: "mcpExecutions", columns: ["outputExpiresAt"]
      )
    }
    migrator.registerMigration("explicit-profile-permissions-and-approvals") { database in
      try database.alter(table: "profiles") { table in
        table.add(column: "mode", .text)
        table.add(column: "confirmationPolicy", .text)
        table.add(column: "authorizationRevision", .integer).notNull().defaults(to: 0)
      }
      try database.alter(table: "operationTickets") { table in
        table.add(column: "authorizationRevision", .integer)
        table.add(column: "reviewSummary", .text)
      }
    }
    migrator.registerMigration("audit-verified-principal") { database in
      try database.alter(table: "auditEvents") { table in
        table.add(column: "principalDigest", .text)
      }
      try database.create(
        index: "auditEvents_on_verified_scope", on: "auditEvents",
        columns: ["principalDigest", "profileID", "workspaceID", "occurredAt"])
    }
    return migrator
  }()

  private static func workspaceDeduplicationPlan(
    _ database: Database
  ) throws -> WorkspaceDeduplicationPlan {
    let aliasIDs = Set(try WorkspaceAliasRecord.fetchAll(database).map(\.aliasWorkspaceID))
    let workspaces = try WorkspaceRecord.fetchAll(database)
      .filter { !aliasIDs.contains($0.id) }
      .sorted {
        if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
        return $0.id < $1.id
      }
    let profiles = try ProfileRecord.fetchAll(database).map { try $0.value() }
    let grouped = Dictionary(grouping: workspaces) {
      canonicalWorkspaceRoot($0.rootPath)
    }
    let groups = grouped.keys.sorted().compactMap {
      canonicalRoot
        -> WorkspaceDeduplicationGroup? in
      guard let records = grouped[canonicalRoot], records.count > 1,
        let canonical = records.first
      else { return nil }
      let members = records.map { record in
        WorkspaceDeduplicationMember(
          workspaceID: record.id,
          displayName: record.displayName,
          rootPath: record.rootPath,
          createdAt: record.createdAt,
          referencedProfileIDs:
            profiles
            .filter { $0.workspaceIDs.contains(record.id) }
            .map { $0.id.rawValue }
            .sorted()
        )
      }
      return WorkspaceDeduplicationGroup(
        canonicalRootPath: canonicalRoot,
        canonicalWorkspaceID: canonical.id,
        duplicateWorkspaceIDs: Array(records.dropFirst().map(\.id)).sorted(),
        members: members,
        hasMetadataConflict: Set(records.map(\.displayName)).count > 1
      )
    }
    let digestInput = WorkspaceDeduplicationDigestInput(groups: groups)
    let encoder = CanonicalJSONCoding.encoder(outputFormatting: [.sortedKeys])
    let digest = SHA256.hash(data: try encoder.encode(digestInput))
      .map { String(format: "%02x", $0) }
      .joined()
    return WorkspaceDeduplicationPlan(
      planDigest: digest,
      groups: groups,
      duplicateCount: groups.reduce(0) { $0 + $1.duplicateWorkspaceIDs.count },
      affectedProfileIDs: Set(
        groups.flatMap(\.members).flatMap(\.referencedProfileIDs)
      ).sorted()
    )
  }

  private static func canonicalWorkspaceRoot(_ path: String) -> String {
    URL(fileURLWithPath: path, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath().path
  }
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

private struct WorkspaceCanonicalRootRecord: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "workspaceCanonicalRoots"

  var canonicalRootPath: String
  var workspaceID: String
  var createdAt: Date
}

private struct WorkspaceAliasRecord: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "workspaceAliases"

  var aliasWorkspaceID: String
  var canonicalWorkspaceID: String
  var canonicalRootPath: String
  var migratedAt: Date
}

private struct WorkspaceDeduplicationReceiptRecord: Codable, FetchableRecord,
  PersistableRecord
{
  static let databaseTableName = "workspaceDeduplicationReceipts"

  var id: String
  var planDigest: String
  var appliedAt: Date
  var payloadJSON: String
}

private struct WorkspaceDeduplicationDigestInput: Codable {
  var groups: [WorkspaceDeduplicationGroup]
}

private struct ProfileRecord: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "profiles"

  var id: String
  var capabilityIDsJSON: String
  var mcpServerIDsJSON: String
  var workspaceIDsJSON: String
  var allowedCallersJSON: String
  var fullShellEnabled: Bool
  var mode: String?
  var confirmationPolicy: String?
  var authorizationRevision: Int64
  var updatedAt: Date

  init(_ value: ProfileGrant, updatedAt: Date) throws {
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
  var principalDigest: String?
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
  var authorizationRevision: Int64?
  var reviewSummary: String?

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
    self.authorizationRevision = value.authorizationRevision
    self.reviewSummary = value.reviewSummary
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
      failureCode: failureCode,
      authorizationRevision: authorizationRevision,
      reviewSummary: reviewSummary
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

extension GatewayDatabase {
  func hostDiagnosticAudits(context: ExecutionContext, limit: Int) throws -> [AuditEvent] {
    guard let principal = AuditEvent.verifiedPrincipalDigest(context.trustedPrincipalID) else {
      return []
    }
    return try writer.read { database in
      let request = AuditEventRecord.filter(Column("workspaceID") == context.workspaceID)
        .filter(Column("profileID") == context.profileID.rawValue)
        .filter(Column("principalDigest") == principal)
      return try request.order(Column("occurredAt").desc, Column("id").desc)
        .limit(max(1, min(1_000, limit))).fetchAll(database).map { try $0.value() }
    }
  }

  func derivedWorkspaceRegistration(id: String) throws -> MCPDerivedWorkspaceRegistration? {
    try writer.read { try Self.derivedRegistration(id: id, database: $0) }
  }

  /// Registration and the single host-added grant are committed together.
  func registerDerivedWorkspace(
    _ registration: MCPDerivedWorkspaceRegistration, verifiedPrincipalID: String,
    caller: GatewayCallerKind
  ) throws {
    try Self.requireDerivedPrincipal(registration, verifiedPrincipalID: verifiedPrincipalID)
    let payload = try JSONEncoder().encode(registration)
    guard payload.count <= 32_768 else {
      throw MCPHostServiceError.denied("Registration exceeds its bound.")
    }
    let changed = try writer.write { database in
      guard
        let source = try WorkspaceRecord.fetchOne(database, key: registration.sourceWorkspaceID),
        Self.canonicalWorkspaceRoot(source.rootPath) == registration.sourceRoot,
        let profileRow = try ProfileRecord.fetchOne(database, key: registration.profileID.rawValue)
      else {
        throw MCPHostServiceError.denied("Source registration or profile is unavailable.")
      }
      var profile = try profileRow.value()
      try Self.requireDerivedSourceGrant(profile, registration: registration, caller: caller)
      if let old = try Self.derivedRegistration(id: registration.workspace.id, database: database) {
        try Self.requireDerivedPrincipal(old, verifiedPrincipalID: verifiedPrincipalID)
        guard old.origin == registration.origin, old.receiptDigest == registration.receiptDigest,
          old.receiptID == registration.receiptID, old.profileID == registration.profileID,
          old.sourceWorkspaceID == registration.sourceWorkspaceID,
          old.sourceRoot == registration.sourceRoot,
          Self.sameDerivedWorkspace(old.workspace, registration.workspace),
          let workspace = try WorkspaceRecord.fetchOne(database, key: old.workspace.id),
          Self.sameDerivedWorkspace(workspace.value, old.workspace)
        else { throw MCPHostServiceError.denied("Existing derived registration changed.") }
        return false
      }
      guard try WorkspaceRecord.fetchOne(database, key: registration.workspace.id) == nil,
        try WorkspaceAliasRecord.fetchOne(database, key: registration.workspace.id) == nil
      else {
        throw MCPHostServiceError.denied("Derived identity or source registration is unavailable.")
      }
      guard
        try !ProfileRecord.fetchAll(database).contains(where: {
          try $0.value().workspaceIDs.contains(registration.workspace.id)
        })
      else {
        throw MCPHostServiceError.denied(
          "The derived identity already has an independently owned grant.")
      }
      let root = Self.canonicalWorkspaceRoot(registration.workspace.rootPath)
      guard try WorkspaceCanonicalRootRecord.fetchOne(database, key: root) == nil else {
        throw MCPHostServiceError.denied(
          "The directory already belongs to an independent registration.")
      }
      try WorkspaceRecord(registration.workspace).insert(database)
      try WorkspaceCanonicalRootRecord(
        canonicalRootPath: root, workspaceID: registration.workspace.id,
        createdAt: registration.workspace.createdAt
      ).insert(database)
      profile.workspaceIDs.insert(registration.workspace.id)
      try Self.saveDerivedProfileChange(profile, database: database)
      try database.execute(
        sql:
          "INSERT INTO pluginDerivedWorkspaces (workspaceID, origin, sourceWorkspaceID, receiptID, payloadJSON) VALUES (?, ?, ?, ?, ?)",
        arguments: [
          registration.workspace.id, registration.origin, registration.sourceWorkspaceID,
          registration.receiptID, String(decoding: payload, as: UTF8.self),
        ])
      return true
    }
    if changed {
      profileChangeLock.withLock { profileChangeBroadcasters[registration.profileID] }?.send()
    }
  }

  /// Does not remove independently edited registrations, aliases, or grants.
  func unregisterDerivedWorkspace(
    _ registration: MCPDerivedWorkspaceRegistration, verifiedPrincipalID: String,
    caller: GatewayCallerKind, allowRevokedSourceForRollback: Bool = false
  ) throws {
    try Self.requireDerivedPrincipal(registration, verifiedPrincipalID: verifiedPrincipalID)
    let changedProfile = try writer.write { database -> Bool in
      guard
        let old = try Self.derivedRegistration(id: registration.workspace.id, database: database)
      else { return false }
      try Self.requireDerivedPrincipal(old, verifiedPrincipalID: verifiedPrincipalID)
      guard old == registration,
        let workspace = try WorkspaceRecord.fetchOne(database, key: old.workspace.id),
        Self.sameDerivedWorkspace(workspace.value, old.workspace),
        try WorkspaceAliasRecord.filter(Column("canonicalWorkspaceID") == old.workspace.id)
          .fetchCount(database) == 0
      else { throw MCPHostServiceError.denied("The derived registration has independent changes.") }
      let profiles = try ProfileRecord.fetchAll(database)
      if !allowRevokedSourceForRollback {
        guard let source = try WorkspaceRecord.fetchOne(database, key: old.sourceWorkspaceID),
          Self.canonicalWorkspaceRoot(source.rootPath) == old.sourceRoot,
          let profile = try profiles.first(where: { $0.id == old.profileID.rawValue })?.value()
        else {
          throw MCPHostServiceError.denied("The source profile is unavailable.")
        }
        try Self.requireDerivedSourceGrant(profile, registration: old, caller: caller)
      }
      var changed = false
      for row in profiles {
        var profile = try row.value()
        guard profile.workspaceIDs.contains(old.workspace.id) else { continue }
        guard profile.id == old.profileID else {
          throw MCPHostServiceError.denied(
            "Another profile now holds an independent workspace grant.")
        }
        profile.workspaceIDs.remove(old.workspace.id)
        try Self.saveDerivedProfileChange(profile, database: database)
        changed = true
      }
      try WorkspaceCanonicalRootRecord.filter(Column("workspaceID") == old.workspace.id).deleteAll(
        database)
      _ = try WorkspaceRecord.deleteOne(database, key: old.workspace.id)
      try database.execute(
        sql: "DELETE FROM pluginDerivedWorkspaces WHERE workspaceID = ?",
        arguments: [old.workspace.id])
      return changed
    }
    if changedProfile {
      profileChangeLock.withLock { profileChangeBroadcasters[registration.profileID] }?.send()
    }
  }

  private static func requireDerivedPrincipal(
    _ registration: MCPDerivedWorkspaceRegistration, verifiedPrincipalID: String
  ) throws {
    guard let principal = registration.principalID, !principal.isEmpty else {
      throw MCPHostServiceError.denied(
        "This historical registration has no bound principal; its data is preserved for explicit management."
      )
    }
    guard !verifiedPrincipalID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      principal == verifiedPrincipalID
    else {
      throw MCPHostServiceError.denied("The derived registration belongs to another principal.")
    }
  }

  private static func requireDerivedSourceGrant(
    _ profile: ProfileGrant, registration: MCPDerivedWorkspaceRegistration,
    caller: GatewayCallerKind
  ) throws {
    guard
      profile.workspaceIDs.contains(registration.sourceWorkspaceID)
        || profile.workspaceIDs.contains("*"),
      profile.allowedCallers.contains(caller), profile.permitsRisk(.workspaceWrite)
    else {
      throw MCPHostServiceError.denied(
        "The persisted source grant no longer permits derived registration changes.")
    }
  }

  private static func saveDerivedProfileChange(_ profile: ProfileGrant, database: Database) throws {
    guard profile.authorizationRevision < Int64.max else {
      throw GatewayDatabaseError.invalidStoredValue("Profile authorization revision exhausted.")
    }
    var saved = profile
    saved.authorizationRevision += 1
    let date = Date()
    try ProfileRecord(saved, updatedAt: date).update(database)
    try database.execute(
      sql: """
        UPDATE operationTickets SET state = ?, completedAt = ?, failureCode = ?
        WHERE profileID = ? AND state IN (?, ?, ?)
        """,
      arguments: [
        OperationTicketState.denied.rawValue, date, "operations.authorization_changed",
        profile.id.rawValue,
        OperationTicketState.prepared.rawValue, OperationTicketState.pendingApproval.rawValue,
        OperationTicketState.approved.rawValue,
      ])
  }

  private static func sameDerivedWorkspace(
    _ current: RegisteredWorkspace, _ expected: RegisteredWorkspace
  ) -> Bool {
    // Compare timestamps at the database's exact serialization precision, not a time tolerance.
    current.id == expected.id && current.displayName == expected.displayName
      && current.rootPath == expected.rootPath && current.bookmarkData == expected.bookmarkData
      && current.bookmarkIsStale == expected.bookmarkIsStale
      && current.createdAt.databaseValue == expected.createdAt.databaseValue
      && current.updatedAt.databaseValue == expected.updatedAt.databaseValue
  }

  private static func derivedRegistration(id: String, database: Database) throws
    -> MCPDerivedWorkspaceRegistration?
  {
    guard
      let row = try Row.fetchOne(
        database, sql: "SELECT * FROM pluginDerivedWorkspaces WHERE workspaceID = ?",
        arguments: [id])
    else { return nil }
    let payload: String = row["payloadJSON"]
    guard payload.utf8.count <= 32_768 else {
      throw MCPHostServiceError.denied("Invalid stored derived registration.")
    }
    let record = try JSONDecoder().decode(
      MCPDerivedWorkspaceRegistration.self, from: Data(payload.utf8))
    guard record.workspace.id == id, record.origin == row["origin"],
      record.sourceWorkspaceID == row["sourceWorkspaceID"], record.receiptID == row["receiptID"]
    else {
      throw MCPHostServiceError.denied("Stored registration identity differs from its record.")
    }
    return record
  }
}
