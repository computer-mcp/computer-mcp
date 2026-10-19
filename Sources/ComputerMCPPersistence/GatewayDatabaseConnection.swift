import Foundation
import GRDB

/// One SQLite database: its connection, schema and transactions. Domain stores read and
/// write through `writer`.
package final class GatewayDatabaseConnection: @unchecked Sendable {
  package let writer: any DatabaseWriter
  package let fileURL: URL?

  /// Opens or creates the database at `path`. A database whose migration ledger names
  /// migrations this version does not have is refused unchanged.
  package init(path: String) throws {
    fileURL = URL(fileURLWithPath: path).standardizedFileURL
    var configuration = Configuration()
    // Independent management connections must acquire the write lock before checking revisions.
    configuration.busyMode = .timeout(5)
    writer = try DatabaseQueue(path: path, configuration: configuration)
    try Self.open(writer)
  }

  package init(inMemory: Void) throws {
    fileURL = nil
    writer = try DatabaseQueue()
    try Self.open(writer)
  }

  static let migrator: DatabaseMigrator = {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("gateway-initial") { database in
      for statement in GatewaySchema.statements { try database.execute(sql: statement) }
    }
    return migrator
  }()

  private static func open(_ writer: any DatabaseWriter) throws {
    let unknown = try writer.read { database in
      try migrator.appliedIdentifiers(database).subtracting(migrator.migrations).sorted()
    }
    guard unknown.isEmpty else { throw UnsupportedDatabaseSchema(identifiers: unknown) }
    try migrator.migrate(writer)
  }
}
