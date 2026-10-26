import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPPlatform
import Foundation
import GRDB

package enum PermissionPersistenceError: Error, Equatable {
  case unsupportedCodec(Int)
  case invalidCurrentState
}

/// Complete permission state serialized under an immediate SQLite write lock.
/// No cached snapshot participates in reads or mutations. The external counter
/// advances before every durable commit, including authority-epoch recovery.
package final class SQLitePermissionStore: PermissionStore, @unchecked Sendable {
  private let connection: GatewayDatabaseConnection
  private let counter: any AuthorizationEpochCounter
  private let operations = BlockingOperationExecutor(label: "computer-mcp.permissions")
  private let commitHook: (@Sendable (CommitStage) throws -> Void)?

  enum CommitStage: Sendable {
    case beforeLock, beforeWrite, afterCounterAdvance, beforeCommit, afterCommit
  }

  package init(connection: GatewayDatabaseConnection, counter: any AuthorizationEpochCounter) {
    self.connection = connection
    self.counter = counter
    self.commitHook = nil
  }

  init(
    connection: GatewayDatabaseConnection, counter: any AuthorizationEpochCounter,
    commitHook: @escaping @Sendable (CommitStage) throws -> Void
  ) {
    self.connection = connection
    self.counter = counter
    self.commitHook = commitHook
  }

  package func read() async throws -> PermissionLedger {
    try await operations.perform { try self.access(mutation: false) { _, ledger in ledger } }
  }

  /// A consistent read of ledger and related SQL state, including epoch recovery.
  /// The callback must not mutate SQL or call another store.
  package func readWithDatabase<Result>(_ body: (Database, PermissionLedger) throws -> Result)
    throws -> Result
  {
    try access(mutation: false) { database, ledger in try body(database, ledger) }
  }

  package func transaction<Result: Sendable>(
    _ body: @escaping @Sendable (inout PermissionLedger) throws -> Result
  ) async throws -> Result {
    try await operations.perform {
      try self.transactionWithDatabase { _, ledger in try body(&ledger) }
    }
  }

  /// Shares one commit with project/profile SQL writes. The closure runs after the
  /// write lock and epoch check; caller validation errors that retire authority
  /// must be caught and returned as values so that those retirements commit.
  /// The closure performs ledger/SQL work only; dispatch and external effects
  /// occur after this method returns successfully. Never nest another store call.
  /// Values returned by the callback precede the final commit revision; obtain a
  /// fresh read for a subsequent compare-and-swap edit.
  package func transactionWithDatabase<Result>(
    _ body: (Database, inout PermissionLedger) throws -> Result
  ) throws -> Result {
    try access(mutation: true, body)
  }

  private func access<Result>(
    mutation: Bool,
    _ body: (Database, inout PermissionLedger) throws -> Result
  ) throws -> Result {
    let outcome: Swift.Result<Result, any Error> = try connection.writer.writeWithoutTransaction {
      database in
      try commitHook?(.beforeLock)
      try database.execute(sql: "BEGIN IMMEDIATE TRANSACTION")
      do {
        return try counter.withExclusiveAccess { access in
          let row = try PermissionLedgerRecord.load(database)
          let watermark = try access.read()
          let recovered =
            row == nil || watermark == nil
            || watermark?.databaseID != row?.databaseID || watermark?.revision != row?.counter
          var current = try row?.decode() ?? PermissionLedger()
          let databaseID = row?.databaseID ?? UUID()
          let epoch = recovered ? UUID() : row!.epoch
          if recovered { current.beginAuthorizationEpoch(epoch) }
          var candidate = current
          let result: Swift.Result<Result, any Error>
          // A savepoint rolls back related SQL if the user closure throws. Epoch
          // recovery itself still commits, without any partial candidate changes.
          try database.execute(sql: "SAVEPOINT permission_mutation")
          do {
            let value = try body(database, &candidate)
            if mutation { try candidate.commitTransaction(replacing: current) }
            try database.execute(sql: "RELEASE SAVEPOINT permission_mutation")
            result = .success(value)
          } catch {
            result = .failure(error)
            candidate = current
            try database.execute(sql: "ROLLBACK TO SAVEPOINT permission_mutation")
            try database.execute(sql: "RELEASE SAVEPOINT permission_mutation")
          }
          let changed: Bool
          if case .success = result { changed = mutation || recovered } else { changed = recovered }
          if changed {
            let revision = max(row?.counter ?? 0, watermark?.revision ?? 0)
            guard revision < UInt64(Int64.max) else {
              throw AuthorizationEpochCounterError.revisionExhausted
            }
            try commitHook?(.beforeWrite)
            let record = try PermissionLedgerRecord(
              ledger: candidate, databaseID: databaseID,
              epoch: epoch, counter: revision + 1)
            try record.save(database)
            try access.advance(
              to: AuthorizationEpochWatermark(databaseID: databaseID, revision: revision + 1))
            try commitHook?(.afterCounterAdvance)
          }
          try commitHook?(.beforeCommit)
          try database.execute(sql: "COMMIT")
          try commitHook?(.afterCommit)
          return result
        }
      } catch {
        if database.isInsideTransaction { try? database.execute(sql: "ROLLBACK") }
        throw error
      }
    }
    return try outcome.get()
  }
}

struct PermissionLedgerRecord {
  static let codecVersion = 1
  let payload: Data
  let databaseID: UUID
  let epoch: UUID
  let counter: UInt64

  init(ledger: PermissionLedger, databaseID: UUID, epoch: UUID, counter: UInt64) throws {
    try ledger.validatePersistedState()
    self.payload = try JSONEncoder().encode(ledger)
    self.databaseID = databaseID
    self.epoch = epoch
    self.counter = counter
  }

  private init(payload: Data, databaseID: UUID, epoch: UUID, counter: UInt64) {
    self.payload = payload
    self.databaseID = databaseID
    self.epoch = epoch
    self.counter = counter
  }

  static func load(_ database: Database) throws -> Self? {
    guard let row = try Row.fetchOne(database, sql: "SELECT * FROM permissionLedger WHERE id = 1")
    else { return nil }
    let version: Int
    do { version = try row.decode(Int.self, forColumn: "codecVersion") } catch {
      throw PermissionPersistenceError.invalidCurrentState
    }
    guard version == codecVersion else {
      throw PermissionPersistenceError.unsupportedCodec(version)
    }
    do {
      let revision = try row.decode(Int64.self, forColumn: "counter")
      guard revision > 0,
        let databaseID = UUID(uuidString: try row.decode(String.self, forColumn: "databaseID")),
        let epoch = UUID(uuidString: try row.decode(String.self, forColumn: "epoch"))
      else {
        throw PermissionPersistenceError.invalidCurrentState
      }
      return Self(
        payload: try row.decode(Data.self, forColumn: "payload"),
        databaseID: databaseID, epoch: epoch, counter: UInt64(revision))
    } catch { throw PermissionPersistenceError.invalidCurrentState }
  }

  func decode() throws -> PermissionLedger {
    do {
      let ledger = try JSONDecoder().decode(PermissionLedger.self, from: payload)
      try ledger.validatePersistedState()
      guard ledger.authorizationEpochID == epoch else {
        throw PermissionPersistenceError.invalidCurrentState
      }
      return ledger
    } catch { throw PermissionPersistenceError.invalidCurrentState }
  }

  func save(_ database: Database) throws {
    try database.execute(
      sql: """
        INSERT INTO permissionLedger (id, codecVersion, databaseID, epoch, counter, payload)
        VALUES (1, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET codecVersion = excluded.codecVersion,
          databaseID = excluded.databaseID, epoch = excluded.epoch,
          counter = excluded.counter, payload = excluded.payload
        """,
      arguments: [
        Self.codecVersion, databaseID.uuidString, epoch.uuidString, Int64(counter), payload,
      ])
  }
}
