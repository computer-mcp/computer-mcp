import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPPersistence
import ComputerMCPPlatform
import Crypto
import Foundation
import GRDB

/// Captured while holding one database read snapshot. Catalog changes are compared
/// separately, under the host's configuration-publication lock at activation.
package struct PermissionMigrationState: Sendable {
  let inputDigest: String
  let configurationMarker: String
}

/// Activation is explicit; opening a database only adds empty tables.
package final class PermissionMigrationStore: @unchecked Sendable {
  private let connection: GatewayDatabaseConnection
  private let permissions: SQLitePermissionStore

  package init(connection: GatewayDatabaseConnection, counter: any AuthorizationEpochCounter) {
    self.connection = connection
    permissions = SQLitePermissionStore(connection: connection, counter: counter)
  }

  package func prepare(catalog: PermissionMigrationCatalog) throws -> (
    PermissionMigrationPlan, PermissionMigrationState
  ) {
    try connection.writer.read { database in
      let plan = try Self.plan(database, catalog: catalog)
      return (
        plan,
        PermissionMigrationState(
          inputDigest: plan.inputDigest, configurationMarker: try Self.configurationMarker(database)
        )
      )
    }
  }

  /// The caller holds configuration publication stable across this transaction.
  /// Recomputing the output prevents a stale or edited draft from becoming authority.
  @discardableResult
  package func apply(
    _ plan: PermissionMigrationPlan, expectedState: PermissionMigrationState,
    currentCatalog: PermissionMigrationCatalog
  ) throws -> Bool {
    if try permissions.readWithDatabase({ database, _ in
      _ = try Self.validate(
        plan, expectedState: expectedState, catalog: currentCatalog, database: database)
      return try Self.wasApplied(plan, database: database)
    }) {
      return false
    }
    return try permissions.transactionWithDatabase { database, _ in
      let verified = try Self.validate(
        plan, expectedState: expectedState, catalog: currentCatalog, database: database)
      if try Self.wasApplied(plan, database: database) { return false }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      for profile in verified.profiles {
        try database.execute(
          sql:
            "INSERT INTO permissionProfiles (id, authorizationRevision, payload) VALUES (?, ?, ?)",
          arguments: [
            profile.id.rawValue, profile.authorizationRevision, try encoder.encode(profile),
          ])
      }
      for derived in verified.derived {
        try database.execute(
          sql:
            "INSERT INTO permissionDerivedProjects (projectID, sourceProjectID, payload) VALUES (?, ?, ?)",
          arguments: [derived.project.id, derived.sourceProjectID, try encoder.encode(derived)])
      }
      try database.execute(sql: "DELETE FROM operationTickets")
      try database.execute(sql: "DELETE FROM clientControlTrust")
      try database.execute(
        sql:
          "INSERT INTO permissionMigration (id, version, inputDigest, catalogDigest) VALUES (1, 1, ?, ?)",
        arguments: [verified.inputDigest, verified.catalogDigest])
      return true
    }
  }

  private static func validate(
    _ plan: PermissionMigrationPlan, expectedState: PermissionMigrationState,
    catalog currentCatalog: PermissionMigrationCatalog, database: Database
  ) throws -> PermissionMigrationPlan {
    guard currentCatalog.digest == plan.catalogDigest,
      plan.inputDigest == expectedState.inputDigest,
      try Self.configurationMarker(database) == expectedState.configurationMarker
    else {
      throw PermissionMigrationError.stateChanged
    }
    let verified = try Self.plan(database, catalog: currentCatalog)
    guard verified.inputDigest == expectedState.inputDigest else {
      throw PermissionMigrationError.stateChanged
    }
    return verified
  }

  private static func wasApplied(_ plan: PermissionMigrationPlan, database: Database) throws -> Bool
  {
    if let applied = try Row.fetchOne(
      database,
      sql: "SELECT version, inputDigest, catalogDigest FROM permissionMigration WHERE id = 1")
    {
      let version: Int = applied["version"]
      let input: String = applied["inputDigest"]
      let catalog: String = applied["catalogDigest"]
      guard version == 1, input == plan.inputDigest, catalog == plan.catalogDigest else {
        throw PermissionMigrationError.stateChanged
      }
      return true
    }
    return false
  }

  package func profiles() throws -> [PermissionProfile] {
    try connection.writer.read { database in
      try Row.fetchAll(database, sql: "SELECT * FROM permissionProfiles ORDER BY id").map { row in
        let payload: Data = row["payload"]
        guard payload.count <= 4_194_304 else { throw PermissionMigrationError.invalidStoredState }
        let profile = try JSONDecoder().decode(PermissionProfile.self, from: payload)
        guard profile.id.rawValue == row["id"],
          profile.authorizationRevision == row["authorizationRevision"]
        else {
          throw PermissionMigrationError.invalidStoredState
        }
        return profile
      }
    }
  }

  private static func plan(_ database: Database, catalog: PermissionMigrationCatalog) throws
    -> PermissionMigrationPlan
  {
    let profiles = try ProfileRecord.order(Column("id")).fetchAll(database).map { try $0.value() }
    let projects = try ProjectRecord.order(Column("id")).fetchAll(database).map(\.value)
    var canonicalRoots: [String: Set<String>] = [:]
    for row in try ProjectCanonicalRootRecord.fetchAll(database) {
      canonicalRoots[row.projectID, default: []].insert(row.canonicalRootPath)
    }
    let aliases = try Dictionary(
      uniqueKeysWithValues: ProjectAliasRecord.fetchAll(database).map {
        ($0.aliasProjectID, $0.canonicalProjectID)
      })
    let derived = try Row.fetchAll(
      database, sql: "SELECT * FROM pluginDerivedProjects ORDER BY projectID"
    ).map { row in
      let payload: String = row["payloadJSON"]
      guard payload.utf8.count <= 32_768 else { throw PermissionMigrationError.invalidStoredState }
      let record = try JSONDecoder().decode(
        MCPDerivedProjectRegistration.self, from: Data(payload.utf8))
      guard record.project.id == row["projectID"], record.sourceProjectID == row["sourceProjectID"],
        record.origin == row["origin"], record.receiptID == row["receiptID"]
      else {
        throw PermissionMigrationError.invalidStoredState
      }
      return record
    }
    return try PermissionProfileMigration.plan(
      profiles: profiles, catalog: catalog,
      projects: .init(
        registered: projects, aliases: aliases, canonicalRoots: canonicalRoots, derived: derived))
  }

  private static func configurationMarker(_ database: Database) throws -> String {
    // Include the persisted plugin revision and active manifest identity, without
    // exposing manifest contents or credentials in the plan or its diagnostics.
    let plugin =
      try String.fetchOne(database, sql: "SELECT payloadJSON FROM pluginState WHERE id = 1") ?? ""
    let revision =
      try Int64.fetchOne(database, sql: "SELECT revision FROM pluginState WHERE id = 1") ?? 0
    let manifests = try Row.fetchAll(
      database,
      sql: "SELECT id, digest FROM configurationRevisions WHERE activatedAt IS NOT NULL ORDER BY id"
    )
    let values = manifests.map { row -> [String] in [row["id"], row["digest"]] }
    let data = try JSONEncoder().encode([
      plugin, String(revision), String(decoding: JSONEncoder().encode(values), as: UTF8.self),
    ])
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
