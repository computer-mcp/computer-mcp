import ComputerMCPWorktrees
import Foundation
import GRDB

package final class SQLiteDerivedProjectStore: DerivedProjectStore, Sendable {
  private let connection: GatewayDatabaseConnection

  package init(connection: GatewayDatabaseConnection) { self.connection = connection }

  package func records() throws -> [DerivedProjectRecord] {
    try connection.writer.read(Self.records)
  }

  package func commit(
    _ record: DerivedProjectRecord, expecting revision: Int64?,
    protecting branch: ProtectedWorktreeBranch? = nil
  ) throws {
    try connection.writer.write {
      try Self.commit(record, expecting: revision, protecting: branch, in: $0)
    }
  }

  package static func records(_ database: Database) throws -> [DerivedProjectRecord] {
    try Row.fetchAll(database, sql: "SELECT * FROM derivedProjects ORDER BY projectID").map(decode)
  }

  package static func record(_ id: String, in database: Database) throws -> DerivedProjectRecord? {
    try Row.fetchOne(
      database, sql: "SELECT * FROM derivedProjects WHERE projectID = ?", arguments: [id]
    )
    .map(decode)
  }

  package static func commit(
    _ record: DerivedProjectRecord, expecting revision: Int64?,
    protecting branch: ProtectedWorktreeBranch? = nil, in database: Database
  ) throws {
    try record.validate()
    try DerivedProjectMigration.validatePluginRecord(record)
    let old = try Self.record(record.projectID, in: database)
    guard old?.revision == revision,
      record.revision == (revision.map { $0 + 1 } ?? 1)
    else { throw DerivedProjectStoreError.revisionConflict }
    if let old {
      guard old.source == record.source, old.root == record.root,
        old.provenance == record.provenance
      else {
        throw DerivedProjectStoreError.invalidRecord
      }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let payload = try encoder.encode(record)
    guard payload.count <= 131_072 else { throw DerivedProjectStoreError.invalidRecord }
    if revision == nil {
      try database.execute(
        sql:
          "INSERT INTO derivedProjects (projectID, codecVersion, sourceProjectID, revision, state, payload) VALUES (?, 1, ?, ?, ?, ?)",
        arguments: [
          record.projectID, record.source.id, record.revision, record.state.rawValue, payload,
        ])
    } else {
      try database.execute(
        sql:
          "UPDATE derivedProjects SET revision = ?, state = ?, payload = ? WHERE projectID = ? AND revision = ?",
        arguments: [record.revision, record.state.rawValue, payload, record.projectID, revision])
      guard database.changesCount == 1 else { throw DerivedProjectStoreError.revisionConflict }
    }
    if let branch {
      guard case .host(let id, _) = record.provenance, id == branch.worktreeID,
        branch.branch.hasPrefix("refs/heads/"), branch.base.hasPrefix("refs/heads/"),
        !branch.baseOID.isEmpty, !branch.publishedOID.isEmpty
      else { throw DerivedProjectStoreError.invalidRecord }
      try database.execute(
        sql:
          "INSERT INTO protectedWorktreeBranches (repositoryID, branchID, codecVersion, branchRef, payload) VALUES (?, ?, 1, ?, ?)",
        arguments: [
          branch.repositoryKey, branch.branchID.uuidString, branch.branch,
          try encoder.encode(branch),
        ])
    }
  }

  package static func remove(_ id: String, expecting revision: Int64, in database: Database) throws
  {
    try database.execute(
      sql: "DELETE FROM derivedProjects WHERE projectID = ? AND revision = ?",
      arguments: [id, revision])
    guard database.changesCount == 1 else { throw DerivedProjectStoreError.revisionConflict }
  }

  private static func decode(_ row: Row) throws -> DerivedProjectRecord {
    let payload: Data = row["payload"]
    guard payload.count <= 131_072, row["codecVersion"] as Int == 1 else {
      throw DerivedProjectStoreError.invalidRecord
    }
    let record = try JSONDecoder().decode(DerivedProjectRecord.self, from: payload)
    try record.validate()
    try DerivedProjectMigration.validatePluginRecord(record)
    guard record.projectID == row["projectID"], record.source.id == row["sourceProjectID"],
      record.revision == row["revision"], record.state.rawValue == row["state"]
    else { throw DerivedProjectStoreError.invalidRecord }
    return record
  }
}
