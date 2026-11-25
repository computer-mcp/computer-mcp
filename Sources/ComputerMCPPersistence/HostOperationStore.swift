import ComputerMCPCore
import Foundation
import GRDB

/// A durable host lifecycle operation. Reservation precedes forwarding and performs no
/// lifecycle effect; only an atomic claim of a reserved row may begin effects. Stored
/// state is reported, never replayed.
package struct HostOperationRecord: Codable, Equatable, Sendable {
  package enum State: String, Codable, Sendable {
    case reserved, running, completed, failed
    case recoveryRequired = "recovery_required"

    package var isTerminal: Bool { self == .completed || self == .failed }
  }

  package struct Failure: Codable, Equatable, Sendable {
    package let code: String
    package let message: String

    package init(code: String, message: String) {
      self.code = code
      self.message = message
    }
  }

  /// Every field a callback must match to act on, or inspect, this operation.
  package struct Binding: Codable, Equatable, Sendable {
    /// The originating invocation's complete admission record.
    package let admission: HostCallAdmission
    package let action: MCPHostServiceAction
    package let pluginID: String?
    package let contributionID: String?
    package let sourceRegisteredAt: Date
    package let projectRegisteredAt: Date
    /// The selected host worktree a removal targets; nil for creation.
    package let worktreeID: UUID?
    /// Lifecycle fields with host defaults resolved; the only inputs that select effects.
    package let arguments: [String: JSONValue]
    /// The reserving process's execution coordinator; restart recovery by a new owner
    /// reconciles operations that other owners left unfinished.
    package let owner: UUID?

    package init(
      admission: HostCallAdmission, action: MCPHostServiceAction, pluginID: String?,
      contributionID: String?, sourceRegisteredAt: Date, projectRegisteredAt: Date,
      worktreeID: UUID?, arguments: [String: JSONValue], owner: UUID? = nil
    ) {
      self.admission = admission
      self.action = action
      self.pluginID = pluginID
      self.contributionID = contributionID
      self.sourceRegisteredAt = sourceRegisteredAt
      self.projectRegisteredAt = projectRegisteredAt
      self.worktreeID = worktreeID
      self.arguments = arguments
      self.owner = owner
    }
  }

  package let id: UUID
  package let binding: Binding
  package var state: State
  package var result: JSONValue?
  package var error: Failure?
  package let createdAt: Date
  package var updatedAt: Date

  package init(id: UUID, binding: Binding, now: Date = Date()) {
    self.id = id
    self.binding = binding
    state = .reserved
    result = nil
    error = nil
    createdAt = now
    updatedAt = now
  }
}

package enum HostOperationStoreError: Error, Equatable {
  case duplicate, notFound, invalidTransition, invalidRecord
}

/// Terminal operations are pruned with the host call record of the invocation that
/// reserved them. Reserved, running and recovery-required operations are retained.
package final class HostOperationStore: Sendable {
  private let connection: GatewayDatabaseConnection

  package init(connection: GatewayDatabaseConnection) { self.connection = connection }

  package func reserve(_ record: HostOperationRecord) throws {
    guard record.state == .reserved, record.binding.admission.action == record.binding.action
    else { throw HostOperationStoreError.invalidRecord }
    try connection.writer.write { database in
      guard
        try Self.record(sql: "id = ?", record.id.uuidString, database) == nil,
        try Self.record(
          sql: "invocationID = ?", record.binding.admission.id.uuidString, database) == nil
      else { throw HostOperationStoreError.duplicate }
      try database.execute(
        sql: "INSERT INTO hostOperations (id, invocationID, state, payload) VALUES (?, ?, ?, ?)",
        arguments: [
          record.id.uuidString, record.binding.admission.id.uuidString, record.state.rawValue,
          try Self.encode(record),
        ])
    }
  }

  package func operation(id: UUID) throws -> HostOperationRecord? {
    try connection.writer.read { try Self.record(sql: "id = ?", id.uuidString, $0) }
  }

  package func operation(invocationID: UUID) throws -> HostOperationRecord? {
    try connection.writer.read {
      try Self.record(sql: "invocationID = ?", invocationID.uuidString, $0)
    }
  }

  package func unfinished() throws -> [HostOperationRecord] {
    try connection.writer.read { try Self.unfinished(in: $0) }
  }

  package static func unfinished(in database: Database, byteLimit: Int = Int.max)
    throws -> [HostOperationRecord]
  {
    let rows = try Row.fetchCursor(
      database,
      sql:
        "SELECT id, state, payload FROM hostOperations WHERE state NOT IN ('completed', 'failed') ORDER BY id"
    )
    var records: [HostOperationRecord] = []
    var remaining = byteLimit
    while let row = try rows.next() {
      let payload: Data = row["payload"]
      let record = try decode(payload)
      guard payload.count <= remaining, row["id"] == record.id.uuidString,
        row["state"] == record.state.rawValue, !record.state.isTerminal
      else { throw HostOperationStoreError.invalidRecord }
      remaining -= payload.count
      records.append(record)
    }
    return records
  }

  /// Moves a reserved operation to running inside the caller's transaction. Returns
  /// the current record unchanged when it is no longer reserved.
  package static func claim(_ id: UUID, now: Date = Date(), in database: Database) throws
    -> (record: HostOperationRecord, claimed: Bool)
  {
    guard var record = try record(sql: "id = ?", id.uuidString, database) else {
      throw HostOperationStoreError.notFound
    }
    guard record.state == .reserved else { return (record, false) }
    record.state = .running
    record.updatedAt = now
    try save(record, expecting: .reserved, in: database)
    return (record, true)
  }

  /// Records an outcome. Terminal state never changes again.
  @discardableResult
  package func finish(
    _ id: UUID, from allowed: Set<HostOperationRecord.State>, to state: HostOperationRecord.State,
    result: JSONValue? = nil, error: HostOperationRecord.Failure? = nil, now: Date = Date()
  ) throws -> HostOperationRecord {
    try connection.writer.write { database in
      guard var record = try Self.record(sql: "id = ?", id.uuidString, database) else {
        throw HostOperationStoreError.notFound
      }
      guard allowed.contains(record.state), !record.state.isTerminal, state != .reserved
      else { throw HostOperationStoreError.invalidTransition }
      let previous = record.state
      record.state = state
      record.result = state == .completed ? result : nil
      record.error = state == .completed ? nil : error
      record.updatedAt = now
      try Self.save(record, expecting: previous, in: database)
      return record
    }
  }

  static func prune(in database: Database) throws {
    try database.execute(
      sql: """
        DELETE FROM hostOperations WHERE state IN ('completed', 'failed')
          AND invocationID NOT IN (SELECT id FROM hostCallRecords)
        """)
  }

  private static func save(
    _ record: HostOperationRecord, expecting previous: HostOperationRecord.State,
    in database: Database
  ) throws {
    try database.execute(
      sql: "UPDATE hostOperations SET state = ?, payload = ? WHERE id = ? AND state = ?",
      arguments: [
        record.state.rawValue, try encode(record), record.id.uuidString, previous.rawValue,
      ])
    guard database.changesCount == 1 else { throw HostOperationStoreError.invalidTransition }
  }

  private static func record(sql filter: String, _ value: String, _ database: Database) throws
    -> HostOperationRecord?
  {
    try Row.fetchOne(
      database, sql: "SELECT payload FROM hostOperations WHERE " + filter, arguments: [value]
    ).map { try decode($0["payload"]) }
  }

  private static func encode(_ record: HostOperationRecord) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(record)
    guard data.count <= 262_144 else { throw HostOperationStoreError.invalidRecord }
    return data
  }

  private static func decode(_ data: Data) throws -> HostOperationRecord {
    guard data.count <= 262_144 else { throw HostOperationStoreError.invalidRecord }
    return try JSONDecoder().decode(HostOperationRecord.self, from: data)
  }
}
