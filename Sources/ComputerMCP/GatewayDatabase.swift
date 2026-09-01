import Foundation
import GRDB

package final class GatewayDatabase: @unchecked Sendable {
  private let writer: any DatabaseWriter
  let fileURL: URL?

  package init(path: String) throws {
    self.fileURL = URL(fileURLWithPath: path).standardizedFileURL
    self.writer = try DatabaseQueue(path: path)
    try Self.migrator.migrate(writer)
  }

  package init(inMemory: Void) throws {
    self.fileURL = nil
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

  func saveCodexApproval(_ approval: CodexApprovalRecord) throws {
    try writer.write { database in
      try CodexApprovalRecordRow(approval).save(database)
    }
  }

  func codexApproval(id: String) throws -> CodexApprovalRecord? {
    try writer.read { database in
      try CodexApprovalRecordRow.fetchOne(database, key: id)?.value()
    }
  }

  func codexApprovals(
    workspaceID: String? = nil,
    limit: Int = 500
  ) throws -> [CodexApprovalRecord] {
    try writer.read { database in
      var request =
        CodexApprovalRecordRow
        .order(Column("createdAt").desc, Column("id").desc)
      if let workspaceID {
        request = request.filter(Column("workspaceID") == workspaceID)
      }
      return try request.limit(max(1, min(limit, 5_000))).fetchAll(database).map {
        try $0.value()
      }
    }
  }

  func saveCodexRuntimeLease(_ lease: CodexRuntimeLeaseRecord) throws {
    try writer.write { database in
      try CodexRuntimeLeaseRow(lease).save(database)
    }
  }

  func codexRuntimeLeases(limit: Int = 500) throws -> [CodexRuntimeLeaseRecord] {
    try writer.read { database in
      try CodexRuntimeLeaseRow
        .order(Column("updatedAt").desc, Column("id").desc)
        .limit(max(1, min(limit, 5_000)))
        .fetchAll(database)
        .map { try $0.value() }
    }
  }

  func saveCodexThreadOwnership(_ ownership: CodexThreadOwnershipRecord) throws {
    try writer.write { database in
      try CodexThreadOwnershipRow(ownership).save(database)
    }
  }

  func codexThreadOwnership(threadID: String) throws -> CodexThreadOwnershipRecord? {
    try writer.read { database in
      try CodexThreadOwnershipRow.fetchOne(database, key: threadID)?.value()
    }
  }

  func codexThreadOwnerships(
    workspaceID: String? = nil,
    limit: Int = 500
  ) throws -> [CodexThreadOwnershipRecord] {
    try writer.read { database in
      var request = CodexThreadOwnershipRow.order(
        Column("updatedAt").desc,
        Column("threadID").desc
      )
      if let workspaceID {
        request = request.filter(Column("workspaceID") == workspaceID)
      }
      return try request.limit(max(1, min(limit, 5_000))).fetchAll(database).map {
        try $0.value()
      }
    }
  }

  func saveCodexOrchestrationRun(_ run: CodexOrchestrationRun) throws {
    try writer.write { database in
      try CodexOrchestrationRunRow(run).save(database)
    }
  }

  func codexOrchestrationRun(id: String) throws -> CodexOrchestrationRun? {
    try writer.read { database in
      try CodexOrchestrationRunRow.fetchOne(database, key: id)?.value()
    }
  }

  func codexOrchestrationRuns(
    workspaceID: String? = nil,
    limit: Int = 500
  ) throws -> [CodexOrchestrationRun] {
    try writer.read { database in
      var request =
        CodexOrchestrationRunRow
        .order(Column("updatedAt").desc, Column("id").desc)
      if let workspaceID {
        request = request.filter(Column("workspaceID") == workspaceID)
      }
      return try request.limit(max(1, min(limit, 5_000))).fetchAll(database).map {
        try $0.value()
      }
    }
  }

  func updateCodexOrchestrationRun(
    id: String,
    workspaceID: String?,
    expectedRevision: Int,
    mutate: (inout CodexOrchestrationRun) throws -> Void
  ) throws -> CodexOrchestrationRun {
    try writer.write { database in
      guard let row = try CodexOrchestrationRunRow.fetchOne(database, key: id) else {
        throw CodexOrchestrationError.unknown(id)
      }
      var run = try row.value()
      guard workspaceID == nil || run.workspaceID == workspaceID else {
        throw CodexOrchestrationError.unknown(id)
      }
      guard run.revision == expectedRevision else {
        throw CodexOrchestrationError.revisionConflict(
          expected: expectedRevision,
          actual: run.revision
        )
      }
      try mutate(&run)
      run.revision += 1
      try CodexOrchestrationRunRow(run).save(database)
      return run
    }
  }

  func codexWorktreeLease(id: String) throws -> CodexWorktreeLease? {
    try writer.read { database in
      try CodexWorktreeLeaseRow.fetchOne(database, key: id)?.value()
    }
  }

  func codexWorktreeLeases(
    workspaceID: String? = nil,
    states: Set<CodexWorktreeLeaseState> = [],
    limit: Int = 500
  ) throws -> [CodexWorktreeLease] {
    try writer.read { database in
      var request =
        CodexWorktreeLeaseRow
        .order(Column("heartbeatAt").desc, Column("id").desc)
      if let workspaceID {
        request = request.filter(Column("workspaceID") == workspaceID)
      }
      if !states.isEmpty {
        request = request.filter(states.map(\.rawValue).contains(Column("state")))
      }
      return try request.limit(max(1, min(limit, 5_000))).fetchAll(database).map {
        try $0.value()
      }
    }
  }

  func acquireCodexWorktreeLease(
    workspaceID: String,
    workspacePath: String,
    mode: CodexWorktreeLeaseMode,
    agentID: String,
    threadID: String?,
    runID: String?,
    parentLeaseID: String?,
    branch: String?,
    ttlSeconds: Int,
    now: Date
  ) throws -> CodexWorktreeLease {
    try writer.write { database in
      let rows =
        try CodexWorktreeLeaseRow
        .filter(Column("workspaceID") == workspaceID)
        .filter(Column("state") == CodexWorktreeLeaseState.active.rawValue)
        .fetchAll(database)
      for row in rows {
        var existing = try row.value()
        if existing.expiresAt <= now {
          existing.state = .expired
          existing.releasedAt = now
          existing.releaseReason = "lease_ttl_expired"
          existing.revision += 1
          try CodexWorktreeLeaseRow(existing).save(database)
          continue
        }
        if existing.agentID == agentID, existing.threadID == threadID,
          existing.runID == runID
        {
          return existing
        }
        throw CodexWorktreeLeaseError.conflict(existing)
      }
      let lease = CodexWorktreeLease(
        id: UUID().uuidString,
        workspaceID: workspaceID,
        workspacePath: workspacePath,
        mode: mode,
        agentID: agentID,
        threadID: threadID,
        runID: runID,
        parentLeaseID: parentLeaseID,
        branch: branch,
        state: .active,
        createdAt: now,
        heartbeatAt: now,
        expiresAt: now.addingTimeInterval(TimeInterval(ttlSeconds)),
        releasedAt: nil,
        releaseReason: nil,
        revision: 1
      )
      try CodexWorktreeLeaseRow(lease).save(database)
      return lease
    }
  }

  func updateCodexWorktreeLease(
    id: String,
    workspaceID: String?,
    expectedRevision: Int,
    mutate: (inout CodexWorktreeLease) throws -> Void
  ) throws -> CodexWorktreeLease {
    try writer.write { database in
      guard let row = try CodexWorktreeLeaseRow.fetchOne(database, key: id) else {
        throw CodexWorktreeLeaseError.unknown(id)
      }
      var lease = try row.value()
      guard workspaceID == nil || lease.workspaceID == workspaceID else {
        throw CodexWorktreeLeaseError.unknown(id)
      }
      guard lease.revision == expectedRevision else {
        throw CodexWorktreeLeaseError.revisionConflict(
          expected: expectedRevision,
          actual: lease.revision
        )
      }
      try mutate(&lease)
      lease.revision += 1
      try CodexWorktreeLeaseRow(lease).save(database)
      return lease
    }
  }

  func saveCodexManagedWorktree(_ worktree: CodexManagedWorktree) throws {
    try writer.write { database in
      try CodexManagedWorktreeRow(worktree).save(database)
    }
  }

  func codexManagedWorktree(id: String) throws -> CodexManagedWorktree? {
    try writer.read { database in
      try CodexManagedWorktreeRow.fetchOne(database, key: id)?.value()
    }
  }

  func codexManagedWorktrees(
    sourceWorkspaceID: String? = nil,
    limit: Int = 100
  ) throws -> [CodexManagedWorktree] {
    try writer.read { database in
      var request =
        CodexManagedWorktreeRow
        .order(Column("updatedAt").desc, Column("id").desc)
      if let sourceWorkspaceID {
        request = request.filter(Column("sourceWorkspaceID") == sourceWorkspaceID)
      }
      return try request.limit(max(1, min(limit, 5_000))).fetchAll(database).map {
        try $0.value()
      }
    }
  }

  func updateCodexManagedWorktree(
    id: String,
    sourceWorkspaceID: String?,
    expectedRevision: Int,
    mutate: (inout CodexManagedWorktree) throws -> Void
  ) throws -> CodexManagedWorktree {
    try writer.write { database in
      guard let row = try CodexManagedWorktreeRow.fetchOne(database, key: id) else {
        throw CodexManagedWorktreeError.unknown(id)
      }
      var worktree = try row.value()
      guard sourceWorkspaceID == nil || worktree.sourceWorkspaceID == sourceWorkspaceID else {
        throw CodexManagedWorktreeError.unknown(id)
      }
      guard worktree.revision == expectedRevision else {
        throw CodexManagedWorktreeError.revisionConflict(
          expected: expectedRevision,
          actual: worktree.revision
        )
      }
      try mutate(&worktree)
      worktree.revision += 1
      try CodexManagedWorktreeRow(worktree).save(database)
      return worktree
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

private struct CodexApprovalRecordRow: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "codexApprovals"

  var id: String
  var upstreamRequestID: String
  var kind: String
  var risk: String
  var state: String
  var workspaceID: String?
  var workspacePath: String
  var runtimeID: String
  var threadID: String?
  var turnID: String?
  var itemID: String?
  var correlationID: String
  var socketConnectionID: String?
  var tunnelInstanceID: String?
  var detailsJSON: String
  var proposedActionJSON: String
  var createdAt: Date
  var expiresAt: Date
  var resolvedAt: Date?
  var decision: String?
  var scope: String?
  var resolutionReason: String?

  init(_ value: CodexApprovalRecord) throws {
    id = value.id
    upstreamRequestID = value.upstreamRequestID
    kind = value.kind.rawValue
    risk = value.risk.rawValue
    state = value.state.rawValue
    workspaceID = value.workspaceID
    workspacePath = value.workspacePath
    runtimeID = value.runtimeID
    threadID = value.threadID
    turnID = value.turnID
    itemID = value.itemID
    correlationID = value.correlationID
    socketConnectionID = value.socketConnectionID
    tunnelInstanceID = value.tunnelInstanceID
    detailsJSON = try Self.encode(value.details)
    proposedActionJSON = try Self.encode(value.proposedAction)
    createdAt = value.createdAt
    expiresAt = value.expiresAt
    resolvedAt = value.resolvedAt
    decision = value.decision?.rawValue
    scope = value.scope
    resolutionReason = value.resolutionReason
  }

  func value() throws -> CodexApprovalRecord {
    guard let kind = CodexApprovalKind(rawValue: kind),
      let risk = CapabilityRisk(rawValue: risk),
      let state = CodexApprovalState(rawValue: state)
    else {
      throw GatewayDatabaseError.invalidStoredValue(
        "Codex approval contains unknown enum values."
      )
    }
    let decision = try decision.map { rawValue in
      guard let value = CodexApprovalDecision(rawValue: rawValue) else {
        throw GatewayDatabaseError.invalidStoredValue(
          "Codex approval contains an unknown decision."
        )
      }
      return value
    }
    return CodexApprovalRecord(
      id: id,
      upstreamRequestID: upstreamRequestID,
      kind: kind,
      risk: risk,
      state: state,
      workspaceID: workspaceID,
      workspacePath: workspacePath,
      runtimeID: runtimeID,
      threadID: threadID,
      turnID: turnID,
      itemID: itemID,
      correlationID: correlationID,
      socketConnectionID: socketConnectionID,
      tunnelInstanceID: tunnelInstanceID,
      details: try Self.decode(detailsJSON),
      proposedAction: try Self.decode(proposedActionJSON),
      createdAt: createdAt,
      expiresAt: expiresAt,
      resolvedAt: resolvedAt,
      decision: decision,
      scope: scope,
      resolutionReason: resolutionReason
    )
  }

  private static func encode(_ value: JSONValue) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    guard let result = String(data: data, encoding: .utf8) else {
      throw GatewayDatabaseError.invalidStoredValue("Could not encode Codex approval JSON.")
    }
    return result
  }

  private static func decode(_ value: String) throws -> JSONValue {
    guard let data = value.data(using: .utf8) else {
      throw GatewayDatabaseError.invalidStoredValue("Codex approval JSON is not UTF-8.")
    }
    return try JSONDecoder().decode(JSONValue.self, from: data)
  }
}

private struct CodexRuntimeLeaseRow: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "codexRuntimeLeases"

  var id: String
  var workspaceID: String?
  var state: String
  var updatedAt: Date
  var payloadJSON: String

  init(_ value: CodexRuntimeLeaseRecord) throws {
    id = value.id
    workspaceID = value.owner?.workspaceID
    state = value.state
    updatedAt = value.updatedAt
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    payloadJSON = String(decoding: data, as: UTF8.self)
  }

  func value() throws -> CodexRuntimeLeaseRecord {
    guard let data = payloadJSON.data(using: .utf8) else {
      throw GatewayDatabaseError.invalidStoredValue("Codex runtime lease is not UTF-8.")
    }
    return try JSONDecoder().decode(CodexRuntimeLeaseRecord.self, from: data)
  }
}

private struct CodexThreadOwnershipRow: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "codexThreadOwnership"

  var threadID: String
  var workspaceID: String?
  var workspacePath: String
  var runtimeID: String
  var state: String
  var createdAt: Date
  var updatedAt: Date

  init(_ value: CodexThreadOwnershipRecord) {
    threadID = value.threadID
    workspaceID = value.workspaceID
    workspacePath = value.workspacePath
    runtimeID = value.runtimeID
    state = value.state.rawValue
    createdAt = value.createdAt
    updatedAt = value.updatedAt
  }

  func value() throws -> CodexThreadOwnershipRecord {
    guard let state = CodexThreadOwnershipState(rawValue: state) else {
      throw GatewayDatabaseError.invalidStoredValue(
        "Codex thread ownership contains an unknown state."
      )
    }
    return CodexThreadOwnershipRecord(
      threadID: threadID,
      workspaceID: workspaceID,
      workspacePath: workspacePath,
      runtimeID: runtimeID,
      state: state,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }
}

private struct CodexOrchestrationRunRow: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "codexOrchestrationRuns"

  var id: String
  var workspaceID: String
  var state: String
  var updatedAt: Date
  var payloadJSON: String

  init(_ value: CodexOrchestrationRun) throws {
    id = value.id
    workspaceID = value.workspaceID
    state = value.state.rawValue
    updatedAt = value.updatedAt
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    payloadJSON = String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  func value() throws -> CodexOrchestrationRun {
    guard let data = payloadJSON.data(using: .utf8) else {
      throw GatewayDatabaseError.invalidStoredValue("Codex orchestration run is not UTF-8.")
    }
    return try JSONDecoder().decode(CodexOrchestrationRun.self, from: data)
  }
}

private struct CodexWorktreeLeaseRow: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "codexWorktreeLeases"

  var id: String
  var workspaceID: String
  var state: String
  var heartbeatAt: Date
  var payloadJSON: String

  init(_ value: CodexWorktreeLease) throws {
    id = value.id
    workspaceID = value.workspaceID
    state = value.state.rawValue
    heartbeatAt = value.heartbeatAt
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    payloadJSON = String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  func value() throws -> CodexWorktreeLease {
    guard let data = payloadJSON.data(using: .utf8) else {
      throw GatewayDatabaseError.invalidStoredValue("Codex worktree lease is not UTF-8.")
    }
    return try JSONDecoder().decode(CodexWorktreeLease.self, from: data)
  }
}

private struct CodexManagedWorktreeRow: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "codexManagedWorktrees"

  var id: String
  var sourceWorkspaceID: String
  var workspaceID: String
  var state: String
  var updatedAt: Date
  var payloadJSON: String

  init(_ value: CodexManagedWorktree) throws {
    id = value.id
    sourceWorkspaceID = value.sourceWorkspaceID
    workspaceID = value.workspaceID
    state = value.state.rawValue
    updatedAt = value.updatedAt
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    payloadJSON = String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  func value() throws -> CodexManagedWorktree {
    guard let data = payloadJSON.data(using: .utf8) else {
      throw GatewayDatabaseError.invalidStoredValue("Codex managed worktree is not UTF-8.")
    }
    return try JSONDecoder().decode(CodexManagedWorktree.self, from: data)
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
