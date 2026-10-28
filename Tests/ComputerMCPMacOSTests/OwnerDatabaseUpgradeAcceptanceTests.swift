import ComputerMCPPermissions
import ComputerMCPTestSupport
import Foundation
import GRDB
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPControlPlane
@testable import ComputerMCPGateway
@testable import ComputerMCPPersistence

@Suite(.serialized, .timeLimit(.minutes(1)))
struct OwnerDatabaseUpgradeAcceptanceTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["COMPUTER_MCP_TEST_OWNER_DB_COPY"] != nil))
  func copiedOwnerDatabasePreservesIdentitiesAndReviewedAuthority() throws {
    let input = URL(
      fileURLWithPath: try #require(
        ProcessInfo.processInfo.environment["COMPUTER_MCP_TEST_OWNER_DB_COPY"]))
    let manifestBase = URL(
      fileURLWithPath: try String(
        contentsOf: input.appendingPathComponent("source-base.txt"), encoding: .utf8))
    let temporary = try ScopedTemporaryDirectory()
    let target = temporary.url.appendingPathComponent("gateway.sqlite")
    let original = try Data(contentsOf: input.appendingPathComponent("gateway.sqlite"))
    try original.write(to: target)
    let wal = input.appendingPathComponent("gateway.sqlite-wal")
    if FileManager.default.fileExists(atPath: wal.path) {
      try Data(contentsOf: wal).write(
        to: temporary.url.appendingPathComponent("gateway.sqlite-wal"))
    }
    let before: [String: [String]]
    do {
      let snapshot = try DatabaseQueue(path: target.path)
      before = try snapshot.read { try rows($0, legacy: true) }
      try snapshot.close()
    }
    let database = try GatewayDatabase(path: target.path)
    let afterSchema = try database.connection.writer.read { try rows($0, legacy: false) }
    for (table, values) in before where table != "grdb_migrations" && table != "operationTickets" {
      #expect(afterSchema[table] == values, "Schema conversion changed owned rows in \(table)")
    }
    #expect(before["operationTickets"]?.isEmpty != false)
    let counter = TestAuthorizationEpochCounter()
    let permissionStore = database.permissionStore(counter: counter)
    let manifest = try String(
      contentsOf: input.appendingPathComponent("computer-mcp.toml"), encoding: .utf8)
    let source = try PermissionManifestUpgrade.source(manifest: manifest, baseURL: manifestBase)
    let catalog = try PermissionMigrationCatalog.capture(
      configuration: source.configuration, manifestProfiles: source.profiles,
      configurationDigest: AtomicManifestStore.digest(of: Data(manifest.utf8)),
      plugins: database.pluginStoreSnapshot(), applications: TestApplicationBundleLocator(),
      bundledPlugins: .init(packages: [], issues: []),
      manifestProjects: source.configuration.manifestProjects)
    let migration = PermissionMigrationStore(
      connection: database.connection, store: permissionStore)
    let (plan, _) = try migration.prepare(catalog: catalog)
    let projects = try database.projects()
    let report = try database.activatePermissionMigration(
      manifest: manifest, baseURL: manifestBase, applications: TestApplicationBundleLocator(),
      bundledPlugins: .init(packages: [], issues: []))
    #expect(report != nil)
    #expect(try database.projects() == projects)
    #expect(
      try migration.profiles().sorted { $0.id.rawValue < $1.id.rawValue }
        == plan.profiles.sorted { $0.id.rawValue < $1.id.rawValue })
    let afterActivation = try database.connection.writer.read { try rows($0, legacy: false) }
    for (table, values) in afterSchema
    where ![
      "grdb_migrations", "clientControlTrust", "pluginDerivedProjects", "permissionControlRevision",
      "permissionLedger", "permissionProfiles", "permissionMigration",
      "permissionProfilePublication",
    ].contains(table) {
      if table == "runtimeSettings" {
        #expect(values.allSatisfy { (afterActivation[table] ?? []).contains($0) })
      } else {
        #expect(afterActivation[table] == values, "Activation changed owned rows in \(table)")
      }
    }
    #expect(try database.clientTrusts().isEmpty)
    #expect(
      try database.connection.writer.read {
        try Int.fetchOne($0, sql: "SELECT count(*) FROM derivedProjects")
      } == plan.derived.count)
    #expect(
      try database.activatePermissionMigration(
        manifest: manifest, baseURL: manifestBase, applications: TestApplicationBundleLocator(),
        bundledPlugins: .init(packages: [], issues: [])) == nil)
    let encoded = JSONEncoder()
    encoded.outputFormatting = [.sortedKeys]
    let grantsDigest = try AtomicManifestStore.digest(
      of: encoded.encode(plan.profiles.sorted { $0.id.rawValue < $1.id.rawValue }))
    print(
      "OWNER_DB_UPGRADE projects=\(projects.count) source_tables=\(before.count) preserved_row_digests=true derived=\(plan.derived.count) converted_profiles=\(plan.profiles.count) old_trusts=\(before["clientControlTrust"]?.count ?? 0) new_trusts=0 grant_digest=\(grantsDigest) input_digest=\(plan.inputDigest) catalog_digest=\(plan.catalogDigest) retry=idempotent"
    )
    #expect(
      try AtomicManifestStore.digest(
        of: Data(contentsOf: input.appendingPathComponent("gateway.sqlite")))
        == AtomicManifestStore.digest(of: original))
  }

  private func rows(_ database: Database, legacy: Bool) throws -> [String: [String]] {
    let tableRenames = [
      "workspaces": "projects", "workspaceAliases": "projectAliases",
      "workspaceCanonicalRoots": "projectCanonicalRoots",
      "workspaceDeduplicationReceipts": "projectDeduplicationReceipts",
      "pluginDerivedWorkspaces": "pluginDerivedProjects",
    ]
    let columnRenames = [
      "workspaceID": "projectID", "sourceWorkspaceID": "sourceProjectID",
      "aliasWorkspaceID": "aliasProjectID", "canonicalWorkspaceID": "canonicalProjectID",
      "workspaceIDsJSON": "projectIDsJSON",
    ]
    let tables = try String.fetchAll(
      database,
      sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
    var result: [String: [String]] = [:]
    for name in tables {
      let table = legacy ? tableRenames[name] ?? name : name
      let data = try Row.fetchAll(
        database, sql: "SELECT * FROM \"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
      )
      result[table] = try data.map { row in
        var fields: [String: String] = [:]
        for (column, value) in row {
          let ownsRenamedColumns = [
            "projectAliases", "projectCanonicalRoots", "profiles", "auditEvents",
            "operationTickets", "pluginDerivedProjects",
          ].contains(table)
          let key = legacy && ownsRenamedColumns ? columnRenames[column] ?? column : column
          switch value.storage {
          case .null: fields[key] = "null"
          case .int64(let v): fields[key] = "int:" + String(v)
          case .double(let v): fields[key] = "double:" + String(v)
          case .blob(let v): fields[key] = "blob:" + v.base64EncodedString()
          case .string(let v):
            fields[key] = "string:" + (try normalized(v, table: table, column: key, legacy: legacy))
          }
        }
        let bytes = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        return try AtomicManifestStore.digest(of: bytes)
      }.sorted()
    }
    return result
  }

  private func normalized(_ value: String, table: String, column: String, legacy: Bool) throws
    -> String
  {
    if table == "profiles" && column == "mode" && value == "workspace-operations" {
      return "project-operations"
    }
    guard ["profile", "payloadJSON", "capabilityIDsJSON"].contains(column),
      var json = try? JSONSerialization.jsonObject(with: Data(value.utf8))
    else { return value }
    func tool(_ name: String) -> String {
      name.hasPrefix("workspace.") ? "project." + name.dropFirst(10) : name
    }
    if legacy && table == "profiles", let tools = json as? [String], column == "capabilityIDsJSON" {
      json = tools.map(tool)
    }
    if legacy && table == "clientControlTrust", var object = json as? [String: Any] {
      for name in ["grant", "configuredGrant"] {
        guard var grant = object[name] as? [String: Any] else { continue }
        if let ids = grant.removeValue(forKey: "workspaceIDs") { grant["projectIDs"] = ids }
        if let tools = grant["capabilityIDs"] as? [String] {
          grant["capabilityIDs"] = tools.map(tool)
        }
        if grant["mode"] as? String == "workspace-operations" {
          grant["mode"] = "project-operations"
        }
        object[name] = grant
      }
      json = object
    }
    // Plugin declarations and arguments are opaque; only host-owned risk choices change.
    if legacy && table == "pluginState", var object = json as? [String: Any],
      var settings = object["settings"] as? [String: [String: Any]]
    {
      for (id, var setting) in settings {
        guard var components = setting["mcp"] as? [String: [String: Any]] else { continue }
        for (name, var component) in components {
          if var risks = component["toolRisks"] as? [String: String] {
            for (tool, risk) in risks where risk == "workspace-write" {
              risks[tool] = "project-write"
            }
            component["toolRisks"] = risks
          }
          components[name] = component
        }
        setting["mcp"] = components
        settings[id] = setting
      }
      object["settings"] = settings
      json = object
    }
    return String(
      decoding: try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
      as: UTF8.self)
  }
}
