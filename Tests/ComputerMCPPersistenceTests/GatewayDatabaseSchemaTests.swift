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

  @Test func newDatabaseMatchesTheSchemaBaseline() throws {
    let connection = try GatewayDatabaseConnection(inMemory: ())
    let url = try #require(
      Bundle.module.url(
        forResource: "gateway-schema", withExtension: "json", subdirectory: "Fixtures"))
    let expected = try JSONDecoder().decode([SchemaEntry].self, from: Data(contentsOf: url))
    #expect(try Self.schema(connection.writer) == expected)
    let ledger = try connection.writer.read {
      try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations")
    }
    #expect(ledger == ["gateway-initial"])
  }

  @Test func reopeningAppliesNothing() throws {
    let first = try Self.schema(GatewayDatabaseConnection(path: path).writer)
    #expect(try Self.schema(GatewayDatabaseConnection(path: path).writer) == first)
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
