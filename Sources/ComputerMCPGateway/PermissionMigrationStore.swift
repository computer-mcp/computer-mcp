import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPPlatform
import ComputerMCPWorktrees
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

  package init(connection: GatewayDatabaseConnection, store: SQLitePermissionStore) {
    self.connection = connection
    permissions = store
  }

  /// Once activated, live profile and catalog edits no longer participate in
  /// migration identity. Recovery still requires the owner's epoch confirmation.
  package func isActivated() throws -> Bool {
    try connection.writer.read { try Self.isActivated($0) }
  }

  private static func isActivated(_ database: Database) throws -> Bool {
    guard
      let version = try Int.fetchOne(
        database, sql: "SELECT version FROM permissionMigration WHERE id = 1")
    else { return false }
    guard version == 1 else { throw PermissionMigrationError.invalidStoredState }
    return true
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
    currentCatalog: PermissionMigrationCatalog, sourceManifestDigest: String? = nil
  ) throws -> Bool {
    if try isActivated() { return false }
    return try permissions.transactionWithDatabase { database, ledger in
      if try Self.isActivated(database) { return false }
      let verified = try Self.validate(
        plan, expectedState: expectedState, catalog: currentCatalog, database: database)
      guard try Int.fetchOne(database, sql: "SELECT count(*) FROM permissionProfiles") == 0 else {
        throw PermissionMigrationError.invalidStoredState
      }
      // No permission authority has been published before this first activation.
      // An existing runtime epoch with live work cannot be adopted by conversion.
      if let recovery = ledger.pendingEpochRecovery {
        guard recovery.executionsToTerminate.isEmpty else {
          throw PermissionModelError.authoritySuspended
        }
        try ledger.acknowledgeEpochRecovery(recovery.epochID)
      }
      guard let epoch = ledger.authorizationEpochID else {
        throw PermissionPersistenceError.invalidCurrentState
      }
      if let suspended = ledger.suspendedAuthority {
        guard suspended.permissions.values.allSatisfy({ $0.entries.isEmpty }),
          suspended.sandboxSettings.isEmpty
        else {
          throw PermissionModelError.authoritySuspended
        }
        try ledger.confirmSuspendedAuthority(epochID: epoch, expectedRevision: ledger.revision)
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      for project in verified.projects {
        guard try ProjectRecord.fetchOne(database, key: project.id) == nil else { continue }
        try ProjectRecord(project).insert(database)
        let root = URL(fileURLWithPath: project.rootPath).standardizedFileURL
          .resolvingSymlinksInPath().path
        try ProjectCanonicalRootRecord(
          canonicalRootPath: root, projectID: project.id,
          createdAt: project.createdAt
        ).insert(database, onConflict: .ignore)
      }
      for profile in verified.profiles {
        try database.execute(
          sql:
            "INSERT INTO permissionProfiles (id, authorizationRevision, payload, authorityEpoch) VALUES (?, ?, ?, ?)",
          arguments: [
            profile.id.rawValue, profile.authorizationRevision, try encoder.encode(profile),
            epoch.uuidString,
          ])
      }
      try GatewayDatabase.savePublishedProfileDeclarations(verified.profiles, in: database)
      for derived in verified.derived {
        guard
          let payload = try String.fetchOne(
            database, sql: "SELECT payloadJSON FROM pluginDerivedProjects WHERE projectID = ?",
            arguments: [derived.project.id])
        else { throw PermissionMigrationError.stateChanged }
        let record = try DerivedProjectMigration.pluginRecord(
          payload: Data(payload.utf8), in: database)
        try SQLiteDerivedProjectStore.commit(record, expecting: nil, in: database)
      }
      try database.execute(
        sql: "UPDATE permissionControlRevision SET revision = revision + 1 WHERE id = 1")
      try database.execute(sql: "DELETE FROM clientControlTrust")
      try database.execute(
        sql:
          "INSERT INTO permissionMigration (id, version, inputDigest, catalogDigest, manifestDigest) VALUES (1, 1, ?, ?, ?)",
        arguments: [verified.inputDigest, verified.catalogDigest, sourceManifestDigest])
      try DerivedProjectMigration.retireLegacyInput(database)
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

  package func profiles() throws -> [ProfileGrant] {
    try connection.writer.read { database in
      try Row.fetchAll(database, sql: "SELECT * FROM permissionProfiles ORDER BY id").map { row in
        let payload: Data = row["payload"]
        guard payload.count <= 4_194_304 else { throw PermissionMigrationError.invalidStoredState }
        let profile = try JSONDecoder().decode(ProfileGrant.self, from: payload)
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
    guard try !Self.isActivated(database) else { throw PermissionMigrationError.stateChanged }
    let stored = try LegacyProfileRecord.order(Column("id")).fetchAll(database).map {
      try $0.value()
    }
    let savedIDs = Set(stored.map(\.id))
    let profiles = stored + catalog.manifestProfiles.filter { !savedIDs.contains($0.id) }
    let savedProjects = try ProjectRecord.order(Column("id")).fetchAll(database).map(\.value)
    let projects = savedProjects.isEmpty ? catalog.manifestProjects : savedProjects
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
