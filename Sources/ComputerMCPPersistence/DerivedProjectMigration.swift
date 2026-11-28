import ComputerMCPCore
import ComputerMCPWorktrees
import Foundation
import GRDB

/// Historical conversion of `permissionDerivedProjects` into the generic ledger. The
/// permission converter owns pre-activation grant removal. The plugin-provenance rows
/// this writes are retired by `PluginWorktreeRetirement` in the same migration pass.
package enum DerivedProjectMigration {
  static func migrate(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE TABLE derivedProjects (
          projectID TEXT PRIMARY KEY,
          codecVersion INTEGER NOT NULL CHECK (codecVersion = 1),
          sourceProjectID TEXT NOT NULL,
          revision INTEGER NOT NULL CHECK (revision > 0),
          state TEXT NOT NULL,
          payload BLOB NOT NULL
        );
        CREATE INDEX derivedProjectSources ON derivedProjects(sourceProjectID);
        CREATE TABLE protectedWorktreeBranches (
          repositoryID TEXT NOT NULL,
          branchID TEXT NOT NULL,
          codecVersion INTEGER NOT NULL CHECK (codecVersion = 1),
          branchRef TEXT NOT NULL,
          payload BLOB NOT NULL,
          PRIMARY KEY (repositoryID, branchID),
          UNIQUE (repositoryID, branchRef)
        );
        """)
    let activated = try Int.fetchOne(
      database, sql: "SELECT version FROM permissionMigration WHERE id = 1")
    guard activated == nil || activated == 1 else { throw DerivedProjectStoreError.invalidRecord }
    let legacyCount = try LegacyProfileRecord.fetchCount(database)
    let rows = try Row.fetchAll(
      database, sql: "SELECT * FROM permissionDerivedProjects ORDER BY projectID")
    guard rows.isEmpty || activated == 1 || legacyCount == 0 else {
      throw DerivedProjectStoreError.activationRequired
    }
    let derivedIDs = Set(rows.map { $0["projectID"] as String })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    for row in rows {
      let payload: Data = row["payload"]
      let record = try pluginRecord(payload: payload, in: database)
      guard !derivedIDs.contains(record.source.id), record.projectID == row["projectID"],
        record.source.id == row["sourceProjectID"],
        let profile = try ProfileRecord.fetchOne(
          database, key: legacyReceipt(payload).profileID.rawValue)
      else { throw DerivedProjectStoreError.invalidRecord }
      _ = try profile.value()
      try database.execute(
        sql:
          "INSERT INTO derivedProjects (projectID, codecVersion, sourceProjectID, revision, state, payload) VALUES (?, 1, ?, 1, 'active', ?)",
        arguments: [record.projectID, record.source.id, try encoder.encode(record)])
    }
    try database.execute(sql: "DROP TABLE permissionDerivedProjects")
    // With a saved activation receipt, the converter already consumed this input.
    if activated == 1, try database.tableExists("pluginDerivedProjects") {
      try database.execute(sql: "DROP TABLE pluginDerivedProjects")
    }
  }

  /// Codec-version-1 ledger payload of a plugin registration, validated against the
  /// registered identities it names.
  private struct PluginRecord: Encodable {
    let projectID: String
    let source: DerivedProjectSource
    let root: String
    let provenance: [String: [String: Data]]
    let state = "active"
    let revision = 1
  }

  private static func pluginRecord(payload: Data, in database: Database) throws -> PluginRecord {
    let receipt = try legacyReceipt(payload)
    guard let source = try ProjectRecord.fetchOne(database, key: receipt.sourceWorkspaceID),
      let project = try ProjectRecord.fetchOne(database, key: receipt.workspace.id),
      project.id == receipt.workspace.id, project.rootPath == receipt.workspace.rootPath,
      project.displayName == receipt.workspace.displayName,
      project.bookmarkData == receipt.workspace.bookmarkData,
      project.bookmarkIsStale == receipt.workspace.bookmarkIsStale,
      project.createdAt.databaseValue == receipt.workspace.createdAt.databaseValue,
      project.updatedAt.databaseValue == receipt.workspace.updatedAt.databaseValue,
      !receipt.origin.isEmpty, !receipt.receiptID.isEmpty, !receipt.receiptDigest.isEmpty,
      !receipt.profileID.rawValue.isEmpty, project.id != source.id,
      [project.rootPath, receipt.sourceRoot].allSatisfy({
        $0.hasPrefix("/") && !$0.contains("\0")
      }),
      try receipt.sourceRoot == source.rootPath
        || ProjectCanonicalRootRecord.filter(Column("projectID") == source.id)
          .filter(Column("canonicalRootPath") == receipt.sourceRoot).fetchCount(database) > 0
    else { throw DerivedProjectStoreError.invalidRecord }
    return PluginRecord(
      projectID: project.id,
      source: .init(id: source.id, root: receipt.sourceRoot, registeredAt: source.createdAt),
      root: project.rootPath, provenance: ["plugin": ["receipt": payload]])
  }

  static func legacyReceipt(_ payload: Data) throws -> PluginReceiptV1 {
    guard payload.count <= 32_768 else { throw DerivedProjectStoreError.invalidRecord }
    return try JSONDecoder().decode(PluginReceiptV1.self, from: payload)
  }

  /// Version-one plugin registration receipt, as stored by historical hosts.
  struct PluginReceiptV1: Decodable {
    let origin: String
    let receiptID: String
    let sourceWorkspaceID: String
    let sourceRoot: String
    let receiptDigest: String
    let profileID: GatewayProfileID
    let principalID: String?
    let caller: GatewayCallerKind
    let workspace: RegisteredProject
  }
}
