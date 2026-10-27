import ComputerMCPCore
import ComputerMCPWorktrees
import Foundation
import GRDB

/// The permission converter owns pre-activation grant removal. This migration only
/// changes the representation of already-live derived authority, atomically.
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
    for row in rows {
      let payload: Data = row["payload"]
      let record = try pluginRecord(payload: payload, in: database)
      guard !derivedIDs.contains(record.source.id), record.projectID == row["projectID"],
        record.source.id == row["sourceProjectID"],
        let profile = try ProfileRecord.fetchOne(
          database, key: legacyReceipt(payload).profileID.rawValue)
      else { throw DerivedProjectStoreError.invalidRecord }
      _ = try profile.value()
      try SQLiteDerivedProjectStore.commit(record, expecting: nil, in: database)
    }
    try database.execute(sql: "DROP TABLE permissionDerivedProjects")
    // With a saved activation receipt, the converter already consumed this input.
    if activated == 1 { try retireLegacyInput(database) }
  }

  package static func retireLegacyInput(_ database: Database) throws {
    if try database.tableExists("pluginDerivedProjects") {
      try database.execute(sql: "DROP TABLE pluginDerivedProjects")
    }
  }

  /// The wire adapter supplies these exact bytes for new registrations too. SQL
  /// projection is validated against registered identities before it is published.
  package static func pluginRecord(payload: Data, in database: Database) throws
    -> DerivedProjectRecord
  {
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
      !receipt.profileID.rawValue.isEmpty,
      try receipt.sourceRoot == source.rootPath
        || ProjectCanonicalRootRecord.filter(Column("projectID") == source.id)
          .filter(Column("canonicalRootPath") == receipt.sourceRoot).fetchCount(database) > 0
    else { throw DerivedProjectStoreError.invalidRecord }
    let result = DerivedProjectRecord(
      projectID: project.id,
      source: .init(id: source.id, root: receipt.sourceRoot, registeredAt: source.createdAt),
      root: project.rootPath, provenance: .plugin(receipt: payload))
    try result.validate()
    return result
  }

  static func validatePluginRecord(_ record: DerivedProjectRecord) throws {
    guard case .plugin(let payload) = record.provenance else { return }
    let receipt = try legacyReceipt(payload)
    guard receipt.workspace.id == record.projectID, receipt.workspace.rootPath == record.root,
      receipt.sourceWorkspaceID == record.source.id, receipt.sourceRoot == record.source.root,
      !receipt.origin.isEmpty, !receipt.receiptID.isEmpty, !receipt.receiptDigest.isEmpty,
      !receipt.profileID.rawValue.isEmpty
    else { throw DerivedProjectStoreError.invalidRecord }
  }

  private static func legacyReceipt(_ payload: Data) throws -> PluginReceiptV1 {
    guard payload.count <= 32_768 else { throw DerivedProjectStoreError.invalidRecord }
    return try JSONDecoder().decode(PluginReceiptV1.self, from: payload)
  }

  /// Version-one receipt spelling is a durable compatibility format, independent
  /// of the gateway's current DTO. A missing principal remains missing.
  private struct PluginReceiptV1: Decodable {
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
