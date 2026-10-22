import ComputerMCPCore
import Foundation
import GRDB
import Testing

@testable import ComputerMCPPersistence

final class GatewayDatabaseSchemaTests {
  private let directory: URL
  private var path: String { directory.appendingPathComponent("gateway.sqlite").path }

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  deinit { try? FileManager.default.removeItem(at: directory) }

  @Test func initialMigrationMatchesTheSchemaBaseline() throws {
    let writer = try DatabaseQueue()
    try GatewayDatabaseConnection.migrator.migrate(writer, upTo: "gateway-initial")
    let url = try #require(
      Bundle.module.url(
        forResource: "gateway-schema", withExtension: "json", subdirectory: "Fixtures"))
    let expected = try JSONDecoder().decode([SchemaEntry].self, from: Data(contentsOf: url))
    #expect(try Self.schema(writer) == expected)
    let ledger = try writer.read {
      try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations")
    }
    #expect(ledger == ["gateway-initial"])
  }

  @Test func reopeningAppliesNothing() throws {
    let first = try Self.schema(GatewayDatabaseConnection(path: path).writer)
    #expect(try Self.schema(GatewayDatabaseConnection(path: path).writer) == first)
  }

  @Test func oauthMigrationPreservesTheInitialSchemaAndRows() throws {
    let earlier = try DatabaseQueue(path: path)
    try GatewayDatabaseConnection.migrator.migrate(earlier, upTo: "gateway-initial")
    let before = try Self.schema(earlier)
    try earlier.write {
      try $0.execute(
        sql: "INSERT INTO runtimeSettings VALUES ('fixture', 'preserved', '2026-10-21')")
    }
    try earlier.close()
    let connection = try GatewayDatabaseConnection(path: path)
    let after = try Self.schema(connection.writer)
    let oldNames = Set(before.map(\.name))
    #expect(
      after.filter { oldNames.contains($0.name) && $0.name != "auditEvents" }
        == before.filter { $0.name != "auditEvents" })
    let additions = after.filter { !oldNames.contains($0.name) }
    #expect(
      Set(additions.filter { $0.type == "table" }.map(\.name)) == [
        "oauthAuthorizationRequests", "oauthGrants", "oauthAuthorizationCodes", "oauthTokens",
      ])
    try connection.writer.read { (database: Database) throws in
      #expect(
        try String.fetchAll(database, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
          == ["gateway-initial", "remote-oauth", "audit-error-details"])
      #expect(
        try String.fetchOne(
          database, sql: "SELECT value FROM runtimeSettings WHERE key = 'fixture'") == "preserved")
      #expect(
        try database.columns(in: "oauthTokens").map(\.name) == [
          "digest", "grantID", "kind", "expiresAt", "payloadJSON",
        ])
      #expect(try Row.fetchAll(database, sql: "PRAGMA foreign_key_list(oauthTokens)").count == 1)
    }
  }

  @Test func auditErrorDetailsPreserveEarlierRowsAndRoundTripStructuredValues() throws {
    let earlier = try DatabaseQueue(path: path)
    try GatewayDatabaseConnection.migrator.migrate(earlier, upTo: "remote-oauth")
    try earlier.write { database in
      try database.execute(
        sql: """
          INSERT INTO auditEvents
            (id, occurredAt, requestID, caller, profileID, capabilityID, decision, errorCode)
          VALUES ('old', '2026-10-21', 'before', ?, ?, 'plugin.register', 'failed', 'fixture')
          """,
        arguments: [GatewayCallerKind.localCLI.rawValue, GatewayProfileID.localAdmin.rawValue])
    }
    try earlier.close()
    let connection = try GatewayDatabaseConnection(path: path)
    let details = JSONValue.object([
      "plugin_id": .string("fixture"), "reason": .string("host_update_required"),
      "requirement": .object(["plugin_api": .object(["declared": .integer(2)])]),
    ])
    let event = AuditEvent(
      requestID: "after", caller: .localCLI, profileID: .localAdmin,
      capabilityID: "plugin.register", decision: .failed,
      errorCode: "plugin.host_update_required", errorDetails: details)
    try connection.writer.write { database in
      let old = try #require(try AuditEventRecord.fetchOne(database, key: "old"))
      #expect(try old.value().errorDetails == nil)
      #expect(old.errorCode == "fixture")
      try AuditEventRecord(event).insert(database)
      let stored = try #require(try AuditEventRecord.fetchOne(database, key: event.id))
      #expect(try stored.value().errorDetails == details)
    }
  }

  @Test func databaseWithEarlierMigrationsIsRefusedUnchanged() throws {
    let earlier = try DatabaseQueue(path: path)
    defer { try? earlier.close() }
    try earlier.write { database in
      try database.execute(
        sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
      try database.execute(
        sql: "INSERT INTO grdb_migrations VALUES ('initial-schema'), ('operation-review-title')")
      try database.execute(sql: "CREATE TABLE workspaces (id TEXT PRIMARY KEY)")
    }
    let before = try Self.schema(earlier)
    #expect(
      throws: UnsupportedDatabaseSchema(identifiers: ["initial-schema", "operation-review-title"])
    ) {
      try GatewayDatabaseConnection(path: path)
    }
    #expect(try Self.schema(earlier) == before)
  }

  @Test func populatedDatabaseWithoutALedgerIsRefusedUnchanged() throws {
    let unrelated = try DatabaseQueue(path: path)
    defer { try? unrelated.close() }
    try unrelated.write { try $0.execute(sql: "CREATE TABLE notes (id TEXT PRIMARY KEY)") }
    let before = try Self.schema(unrelated)
    #expect(throws: UnsupportedDatabaseSchema(identifiers: [])) {
      try GatewayDatabaseConnection(path: path)
    }
    #expect(try Self.schema(unrelated) == before)
  }

  private struct SchemaEntry: Codable, Equatable {
    let type: String
    let name: String
    let table: String
    let sql: String
  }

  private static func schema(_ writer: any DatabaseReader) throws -> [SchemaEntry] {
    try writer.read { database in
      try Row.fetchAll(
        database, sql: "SELECT type, name, tbl_name, sql FROM sqlite_schema ORDER BY name"
      ).map {
        SchemaEntry(type: $0["type"], name: $0["name"], table: $0["tbl_name"], sql: $0["sql"] ?? "")
      }
    }
  }
}
