import ComputerMCPCore
import ComputerMCPWorktrees
import Foundation
import GRDB

/// One retired plugin-registration-derived checkout. These are recorded facts, not
/// proof of current filesystem identity.
package struct PluginWorktreeRetirementNotice: Equatable, Sendable {
  package static let code = "host.plugin_worktree_retired"

  package let reportID: UUID
  package let checkoutPath: String
  package let sourceProjectID: String
  package let sourceRegisteredAt: Date?
  package let sourceRepository: String

  /// The six notice fields. JSON string encoding escapes control characters and
  /// separators in stored paths.
  package var fields: [String: JSONValue] {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return [
      "report_id": .string(reportID.uuidString.lowercased()),
      "code": .string(Self.code),
      "checkout_path": .string(checkoutPath),
      "source_project_id": .string(sourceProjectID),
      "source_registered_at": sourceRegisteredAt.map { .string(formatter.string(from: $0)) }
        ?? .null,
      "source_repository": .string(sourceRepository),
    ]
  }

  /// One complete, untruncated notice line for an output stream.
  package var rendered: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = (try? encoder.encode(JSONValue.object(fields))) ?? Data("{}".utf8)
    return "Plugin worktree retired: " + String(decoding: data, as: UTF8.self)
  }
}

/// Startup retirement of plugin-registration-derived project authority. One migration
/// transaction selects rows by their stored plugin provenance, removes each row with
/// the project registration and canonical roots it created, and persists a notice per
/// checkout. It performs no Git or filesystem change. Host worktrees, independent
/// registrations, aliases and grants are unchanged.
package enum PluginWorktreeRetirement {
  static func migrate(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE pluginWorktreeRetirements (
          sequence INTEGER PRIMARY KEY AUTOINCREMENT,
          reportID TEXT NOT NULL UNIQUE,
          checkoutPath TEXT NOT NULL,
          sourceProjectID TEXT NOT NULL,
          sourceRegisteredAt REAL,
          sourceRepository TEXT NOT NULL,
          acknowledgedAt REAL
        )
        """)
    for row in try Row.fetchAll(
      database, sql: "SELECT projectID, payload FROM derivedProjects ORDER BY projectID")
    {
      let payload: Data = row["payload"]
      guard payload.count <= 131_072 else { throw DerivedProjectStoreError.invalidRecord }
      let stored = try JSONDecoder().decode(StoredRecord.self, from: payload)
      guard stored.provenance.plugin else { continue }
      guard stored.projectID == row["projectID"] else {
        throw DerivedProjectStoreError.invalidRecord
      }
      try record(
        checkout: stored.root, sourceID: stored.source.id,
        registeredAt: stored.source.registeredAt, repository: stored.source.root, in: database)
      try database.execute(
        sql: "DELETE FROM derivedProjects WHERE projectID = ?", arguments: [stored.projectID])
      try removeRegistration(stored.projectID, root: stored.root, in: database)
    }
    // Databases that have not activated permissions still hold the pre-ledger input,
    // which activation would otherwise convert into new derived rows.
    if try database.tableExists("pluginDerivedProjects") {
      for row in try Row.fetchAll(
        database, sql: "SELECT projectID, payloadJSON FROM pluginDerivedProjects ORDER BY projectID"
      ) {
        let payload: String = row["payloadJSON"]
        let receipt = try DerivedProjectMigration.legacyReceipt(Data(payload.utf8))
        guard receipt.workspace.id == row["projectID"] else {
          throw DerivedProjectStoreError.invalidRecord
        }
        try record(
          checkout: receipt.workspace.rootPath, sourceID: receipt.sourceWorkspaceID,
          registeredAt: try ProjectRecord.fetchOne(database, key: receipt.sourceWorkspaceID)?
            .createdAt,
          repository: receipt.sourceRoot, in: database)
        try removeRegistration(receipt.workspace.id, root: receipt.workspace.rootPath, in: database)
      }
      try database.execute(sql: "DROP TABLE pluginDerivedProjects")
    }
  }

  private static func record(
    checkout: String, sourceID: String, registeredAt: Date?, repository: String,
    in database: Database
  ) throws {
    try database.execute(
      sql: """
        INSERT INTO pluginWorktreeRetirements
          (reportID, checkoutPath, sourceProjectID, sourceRegisteredAt, sourceRepository)
        VALUES (?, ?, ?, ?, ?)
        """,
      arguments: [
        UUID().uuidString.lowercased(), checkout, sourceID,
        registeredAt?.timeIntervalSince1970, repository,
      ])
  }

  /// A registration with the same ID but another root is independent and remains.
  private static func removeRegistration(_ id: String, root: String, in database: Database)
    throws
  {
    guard let project = try ProjectRecord.fetchOne(database, key: id), project.rootPath == root
    else { return }
    try ProjectCanonicalRootRecord.filter(Column("projectID") == id).deleteAll(database)
    _ = try ProjectRecord.deleteOne(database, key: id)
  }

  /// Version-1 ledger payload fields needed to identify and report a row.
  private struct StoredRecord: Decodable {
    let projectID: String
    let source: DerivedProjectSource
    let root: String
    let provenance: Provenance
  }

  /// Ownership is the encoded provenance case, never the row's ID or path.
  private struct Provenance: Decodable {
    let plugin: Bool
    private struct Key: CodingKey {
      let stringValue: String
      var intValue: Int? { nil }
      init(stringValue: String) { self.stringValue = stringValue }
      init?(intValue: Int) { nil }
    }
    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: Key.self)
      let keys = container.allKeys.map(\.stringValue)
      guard keys == ["plugin"] || keys == ["host"] else {
        throw DerivedProjectStoreError.invalidRecord
      }
      plugin = keys == ["plugin"]
    }
  }
}

/// Pending notices survive until a sink accepts them. Concurrent startups may both
/// emit a notice before either acknowledges it; a notice is never silently dropped.
package final class PluginWorktreeRetirementStore: Sendable {
  private let connection: GatewayDatabaseConnection

  package init(connection: GatewayDatabaseConnection) { self.connection = connection }

  package func pending() throws -> [PluginWorktreeRetirementNotice] {
    try connection.writer.read { database in
      try Row.fetchAll(
        database,
        sql:
          "SELECT * FROM pluginWorktreeRetirements WHERE acknowledgedAt IS NULL ORDER BY sequence"
      ).map { row in
        let id: String = row["reportID"]
        guard let reportID = UUID(uuidString: id) else {
          throw DerivedProjectStoreError.invalidRecord
        }
        return PluginWorktreeRetirementNotice(
          reportID: reportID, checkoutPath: row["checkoutPath"],
          sourceProjectID: row["sourceProjectID"],
          sourceRegisteredAt: (row["sourceRegisteredAt"] as Double?).map {
            Date(timeIntervalSince1970: $0)
          },
          sourceRepository: row["sourceRepository"])
      }
    }
  }

  package func acknowledge(_ reportID: UUID, at date: Date = Date()) throws {
    try connection.writer.write { database in
      try database.execute(
        sql:
          "UPDATE pluginWorktreeRetirements SET acknowledgedAt = ? WHERE reportID = ? AND acknowledgedAt IS NULL",
        arguments: [date.timeIntervalSince1970, reportID.uuidString.lowercased()])
    }
  }

  /// Emits pending notices in order and acknowledges each only after `emit` returns.
  /// A sink failure stops the drain and leaves that notice and later ones pending.
  @discardableResult
  package func drain(_ emit: (PluginWorktreeRetirementNotice) throws -> Void) throws -> Int {
    var emitted = 0
    for notice in try pending() {
      do { try emit(notice) } catch { return emitted }
      try acknowledge(notice.reportID)
      emitted += 1
    }
    return emitted
  }
}
