import ComputerMCPPlatformPOSIX
import Foundation
import GRDB

/// One SQLite database: its connection, schema and transactions. Domain stores read and
/// write through `writer`.
package final class GatewayDatabaseConnection: @unchecked Sendable {
  package let writer: any DatabaseWriter
  package let fileURL: URL?
  private let fileLock: FileLock?

  /// Opens or creates the database at `path`. A database whose migration ledger names
  /// migrations this version does not have, or that holds tables without a ledger, is
  /// refused unchanged, as is one whose replacement by a state import was interrupted.
  package init(path: String) throws {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    do {
      fileLock = try FileLock(path: url.path + ".lock", mode: .shared)
    } catch FileLockError.held {
      throw StateImportInProgress(path: url.path)
    }
    guard !GatewayStateImport.isReplacing(url) else {
      throw InterruptedStateImport(path: url.path)
    }
    fileURL = url
    var configuration = Configuration()
    // Independent management connections must acquire the write lock before checking revisions.
    configuration.busyMode = .timeout(5)
    writer = try DatabaseQueue(path: path, configuration: configuration)
    try Self.open(writer)
  }

  package init(inMemory: Void) throws {
    fileURL = nil
    fileLock = nil
    writer = try DatabaseQueue()
    try Self.open(writer)
  }

  /// Opens an exclusively created staging file. The importer must hold the target's
  /// exclusive lock until this connection is closed and replacement is complete.
  package init(stagedPath: String) throws {
    fileURL = URL(fileURLWithPath: stagedPath).standardizedFileURL
    fileLock = nil
    writer = try DatabaseQueue(path: stagedPath)
    try Self.open(writer)
  }

  static let migrator: DatabaseMigrator = {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("gateway-initial") { database in
      for statement in GatewaySchema.statements { try database.execute(sql: statement) }
    }
    migrator.registerMigration("remote-oauth") { database in
      for statement in OAuthSchema.statements { try database.execute(sql: statement) }
    }
    return migrator
  }()

  private static func open(_ writer: any DatabaseWriter) throws {
    try writer.read(checkSchema)
    try migrator.migrate(writer)
  }

  /// Throws `UnsupportedDatabaseSchema` unless `database` is empty or has only migrations
  /// this version registers.
  static func checkSchema(_ database: Database) throws {
    let unknown = try migrator.appliedIdentifiers(database).subtracting(migrator.migrations)
    guard unknown.isEmpty else {
      throw UnsupportedDatabaseSchema(identifiers: unknown.sorted())
    }
    let tables = try Int.fetchOne(
      database,
      sql: "SELECT count(*) FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
    guard try database.tableExists("grdb_migrations") || tables == 0 else {
      throw UnsupportedDatabaseSchema(identifiers: [])
    }
  }
}
