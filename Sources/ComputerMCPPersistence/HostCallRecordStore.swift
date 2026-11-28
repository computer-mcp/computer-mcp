import ComputerMCPCore
import Foundation
import GRDB

package enum HostCallRecordError: Error, LocalizedError {
  case unavailable, mismatch, capacity
  package var code: String {
    switch self {
    case .unavailable: "host.call_record_unavailable"
    case .mismatch: "host.call_record_mismatch"
    case .capacity: "host.call_record_capacity"
    }
  }
  package var errorDescription: String? {
    switch self {
    case .unavailable: "The host call record is unavailable."
    case .mismatch: "The host call record no longer matches its live invocation."
    case .capacity: "Host call record capacity is exhausted."
    }
  }
}

/// Serializes record changes on the host database. It never reconstructs live
/// leases from saved rows, including unfinished records left by a crashed host.
package final class HostCallRecordStore: Sendable {
  private let connection: GatewayDatabaseConnection
  private let maximumRecords: Int

  package init(connection: GatewayDatabaseConnection, maximumRecords: Int = 1_000_000) {
    precondition(maximumRecords > 0)
    self.connection = connection
    self.maximumRecords = maximumRecords
  }

  package func begin(_ admission: HostCallAdmission, requestLeaseID: UUID) throws {
    try connection.writer.write { database in
      try database.execute(
        sql: "DELETE FROM hostCallRecords WHERE completedAt < ?",
        arguments: [admission.createdAt.addingTimeInterval(-90 * 86_400).timeIntervalSince1970])
      var count = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM hostCallRecords") ?? 0
      if count >= maximumRecords {
        try database.execute(
          sql: """
            DELETE FROM hostCallRecords WHERE id IN (
              SELECT id FROM hostCallRecords WHERE completedAt IS NOT NULL
              ORDER BY completedAt LIMIT ?
            )
            """, arguments: [count - maximumRecords + 1])
        count -= database.changesCount
      }
      try HostOperationStore.prune(in: database)
      guard count < maximumRecords else {
        throw HostCallRecordError.capacity
      }
      let record = HostCallRecord(admission: admission, requestLeaseID: requestLeaseID)
      try database.execute(
        sql: "INSERT INTO hostCallRecords (id, payload, completedAt) VALUES (?, ?, NULL)",
        arguments: [admission.id.uuidString, try Self.encode(record)])
    }
  }

  package func record(id: UUID) throws -> HostCallRecord? {
    try connection.writer.read { try Self.record(id: id, database: $0) }
  }

  /// Expected lease sets are the in-process directory's state, never callback input.
  package func requireLive(
    _ admission: HostCallAdmission, requestLeaseIDs: Set<UUID>, workLeaseIDs: Set<UUID>
  ) throws {
    try connection.writer.read { database in
      _ = try Self.requireLive(
        admission, requestLeaseIDs: requestLeaseIDs,
        workLeaseIDs: workLeaseIDs, database: database)
    }
  }

  package func replaceLeases(
    _ admission: HostCallAdmission, expectedRequest: Set<UUID>, expectedWork: Set<UUID>,
    requestLeaseIDs: Set<UUID>, workLeaseIDs: Set<UUID>, now: Date = Date()
  ) throws {
    try connection.writer.write { database in
      var record = try Self.requireLive(
        admission, requestLeaseIDs: expectedRequest,
        workLeaseIDs: expectedWork, database: database)
      record.requestLeaseIDs = requestLeaseIDs
      record.workLeaseIDs = workLeaseIDs
      if requestLeaseIDs.isEmpty && workLeaseIDs.isEmpty { record.completedAt = now }
      try database.execute(
        sql: "UPDATE hostCallRecords SET payload = ?, completedAt = ? WHERE id = ?",
        arguments: [
          try Self.encode(record), record.completedAt?.timeIntervalSince1970,
          admission.id.uuidString,
        ])
    }
  }

  private static func requireLive(
    _ admission: HostCallAdmission, requestLeaseIDs: Set<UUID>, workLeaseIDs: Set<UUID>,
    database: Database
  ) throws -> HostCallRecord {
    guard !requestLeaseIDs.isEmpty || !workLeaseIDs.isEmpty,
      let record = try record(id: admission.id, database: database),
      record.admission == admission, record.completedAt == nil,
      record.requestLeaseIDs == requestLeaseIDs, record.workLeaseIDs == workLeaseIDs
    else { throw HostCallRecordError.mismatch }
    return record
  }

  private static func encode(_ record: HostCallRecord) throws -> Data {
    let bytes = try JSONEncoder().encode(record)
    guard bytes.count <= 131_072 else { throw HostCallRecordError.unavailable }
    return bytes
  }

  private static func record(id: UUID, database: Database) throws -> HostCallRecord? {
    guard
      let row = try Row.fetchOne(
        database, sql: "SELECT payload FROM hostCallRecords WHERE id = ?",
        arguments: [id.uuidString])
    else { return nil }
    let bytes: Data = row["payload"]
    guard bytes.count <= 131_072 else { throw HostCallRecordError.unavailable }
    let record = try JSONDecoder().decode(HostCallRecord.self, from: bytes)
    guard record.admission.id == id else { throw HostCallRecordError.mismatch }
    return record
  }
}
