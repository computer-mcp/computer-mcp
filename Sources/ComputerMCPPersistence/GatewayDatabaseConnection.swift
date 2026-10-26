import Foundation
import GRDB

/// One SQLite database: its connection, schema and transactions. Domain stores read and
/// write through `writer`.
package final class GatewayDatabaseConnection: @unchecked Sendable {
  package let writer: any DatabaseWriter
  package let fileURL: URL?

  /// Opens or creates the database at `path`. A database whose migration ledger names
  /// migrations this version does not have, or that holds tables without a ledger, is
  /// refused unchanged.
  package init(path: String) throws {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    fileURL = url
    var configuration = Configuration()
    // Independent management connections must acquire the write lock before checking revisions.
    configuration.busyMode = .timeout(5)
    configuration.prepareDatabase { database in
      try database.execute(sql: "PRAGMA synchronous = FULL")
      try database.execute(sql: "PRAGMA fullfsync = ON")
    }
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
    migrator.registerMigration("remote-oauth") { database in
      for statement in OAuthSchema.statements { try database.execute(sql: statement) }
    }
    migrator.registerMigration("audit-error-details") { database in
      try database.alter(table: "auditEvents") { $0.add(column: "errorDetailsJSON", .text) }
    }
    migrator.registerMigration("project-terminology", migrate: ProjectSchemaMigration.migrate)
    migrator.registerMigration("permission-ledger") { database in
      try database.execute(
        sql: """
          CREATE TABLE permissionLedger (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            codecVersion INTEGER NOT NULL,
            databaseID TEXT NOT NULL,
            epoch TEXT NOT NULL,
            counter INTEGER NOT NULL CHECK (counter > 0),
            payload BLOB NOT NULL
          )
          """)
    }
    migrator.registerMigration("permission-profiles") { database in
      try database.execute(
        sql: """
          CREATE TABLE permissionProfiles (
            id TEXT PRIMARY KEY,
            authorizationRevision INTEGER NOT NULL CHECK (authorizationRevision > 0),
            payload BLOB NOT NULL
          );
          CREATE TABLE permissionDerivedProjects (
            projectID TEXT PRIMARY KEY,
            sourceProjectID TEXT NOT NULL,
            payload BLOB NOT NULL
          );
          CREATE TABLE permissionMigration (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            version INTEGER NOT NULL,
            inputDigest TEXT NOT NULL,
            catalogDigest TEXT NOT NULL
          );
          """)
    }
    migrator.registerMigration("permission-services") { database in
      try database.alter(table: "permissionProfiles") { $0.add(column: "authorityEpoch", .text) }
      try database.execute(
        sql: """
          CREATE TABLE permissionControlRevision (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            revision INTEGER NOT NULL CHECK (revision >= 0)
          );
          INSERT INTO permissionControlRevision VALUES (1, 0);
          CREATE TABLE permissionSubjects (
            principal BLOB PRIMARY KEY,
            profileID TEXT NOT NULL,
            caller TEXT NOT NULL
          );
          CREATE TABLE permissionOwnerPolicies (
            profileID TEXT PRIMARY KEY,
            payload BLOB,
            authorityEpoch TEXT NOT NULL
          );
          CREATE TABLE permissionPolicySources (
            source TEXT PRIMARY KEY,
            payload BLOB NOT NULL
          );
          """)
    }
    migrator.registerMigration("host-call-records") { database in
      try database.execute(
        sql: """
          CREATE TABLE hostCallRecords (id TEXT PRIMARY KEY, payload BLOB NOT NULL, completedAt REAL);
          CREATE INDEX hostCallRecordsCompletion ON hostCallRecords(completedAt);
          """)
    }
    migrator.registerMigration("execution-runtime") { database in
      try database.execute(
        sql: "CREATE TABLE permissionRuntimeExecutions (id TEXT PRIMARY KEY, payload BLOB NOT NULL)"
      )
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
