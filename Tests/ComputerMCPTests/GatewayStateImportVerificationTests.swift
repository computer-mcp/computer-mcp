import ComputerMCPConfiguration
import Foundation
import GRDB
import Testing

@testable import ComputerMCP
@testable import ComputerMCPCore
@testable import ComputerMCPPersistence

struct GatewayStateImportVerificationTests {
  @Test func stateThisVersionWroteImportsAndVerifies() throws {
    let root = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try GatewayDatabase(path: root.appendingPathComponent("source.sqlite").path)
    try source.saveWorkspace(
      RegisteredWorkspace(
        id: "W1", displayName: "Project", rootPath: root.path, bookmarkData: Data([1, 2, 3]),
        createdAt: Date(timeIntervalSince1970: 1)))
    var profile = ProfileGrant.operate
    profile.workspaceIDs = ["W1"]
    try source.saveProfile(profile)
    try source.saveRuntimeSetting(key: "desired-running-openai-tunnels", value: #"["chatgpt"]"#)
    try source.saveRuntimeSetting(
      key: "desired-running-cloudflare-tunnels", value: #"["cloudflare"]"#)
    try source.saveRuntimeSetting(
      key: "gateway-tunnel-registration", value: "65A88D6F-49FC-4C88-984B-99E7DA08377C")
    try source.saveRuntimeSetting(key: "active-gateway-profile", value: "custom-profile")
    try source.saveConfigurationRevision(
      ConfigurationRevision(
        digest: "fixture", manifest: DefaultGatewayConfiguration.manifest, activatedAt: Date()))
    let export = try Self.export(root.appendingPathComponent("source.sqlite"), to: root)
    let target = root.appendingPathComponent("gateway.sqlite")

    try GatewayStateImport.run(exportFile: export, database: target) { connection in
      try GatewayDatabase(connection: connection).verifyImportedState(configurationDirectory: root)
    }

    let imported = try GatewayDatabase(path: target.path)
    #expect(try imported.workspaces() == source.workspaces())
    #expect(try imported.profiles() == source.profiles())
    #expect(try imported.runtimeSetting(key: "desired-running-openai-tunnels") == #"["chatgpt"]"#)
    #expect(try imported.configurationRevisions() == source.configurationRevisions())
  }

  @Test func undecodablePluginStateFailsTheImportAndKeepsTheEarlierDatabase() throws {
    let root = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.sqlite")
    _ = try GatewayDatabase(path: source.path)
    try DatabaseQueue(path: source.path).write {
      try $0.execute(
        sql:
          #"INSERT INTO pluginState (id, revision, payloadJSON) VALUES (1, 1, '{"revision": 1}')"#
      )
    }
    let export = try Self.export(source, to: root)
    let target = root.appendingPathComponent("gateway.sqlite")
    try DatabaseQueue(path: target.path).write { database in
      try database.execute(
        sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
      try database.execute(sql: "INSERT INTO grdb_migrations VALUES ('initial-schema')")
    }

    #expect(throws: DecodingError.self) {
      try GatewayStateImport.run(exportFile: export, database: target) { connection in
        try GatewayDatabase(connection: connection).verifyImportedState(
          configurationDirectory: root)
      }
    }
    #expect(throws: UnsupportedDatabaseSchema(identifiers: ["initial-schema"])) {
      try GatewayDatabase(path: target.path)
    }
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == [
        "export.json", "gateway.sqlite", "gateway.sqlite.lock", "source.sqlite",
        "source.sqlite.lock",
      ])
  }

  @Test(arguments: [
    "runtimeSettingDate", "canonicalRootDate", "openaiList", "cloudflareList", "tunnelRegistration",
    "activeProfile",
  ])
  func invalidImportedRecordsFailVerificationAndPreserveTheEarlierDatabase(_ defect: String) throws
  {
    let root = try Self.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appendingPathComponent("source.sqlite")
    let source = try GatewayDatabase(path: sourceURL.path)
    try source.saveWorkspace(
      RegisteredWorkspace(id: "W1", displayName: "Project", rootPath: root.path))
    try source.saveRuntimeSetting(key: "unknown-setting", value: "opaque")
    try DatabaseQueue(path: sourceURL.path).write { database in
      switch defect {
      case "runtimeSettingDate":
        try database.execute(sql: "UPDATE runtimeSettings SET updatedAt = 'invalid'")
      case "canonicalRootDate":
        try database.execute(sql: "UPDATE workspaceCanonicalRoots SET createdAt = 'invalid'")
      default:
        let key: String
        let value: String
        switch defect {
        case "openaiList": (key, value) = ("desired-running-openai-tunnels", "[1]")
        case "cloudflareList": (key, value) = ("desired-running-cloudflare-tunnels", "[1]")
        case "tunnelRegistration": (key, value) = ("gateway-tunnel-registration", "invalid")
        default: (key, value) = ("active-gateway-profile", "invalid profile")
        }
        try database.execute(
          sql: "INSERT INTO runtimeSettings VALUES (?, ?, ?)", arguments: [key, value, Date()])
      }
    }
    let export = try Self.export(sourceURL, to: root)
    let target = root.appendingPathComponent("gateway.sqlite")
    try DatabaseQueue(path: target.path).write {
      try $0.execute(sql: "CREATE TABLE earlier (id TEXT)")
      try $0.execute(sql: "INSERT INTO earlier VALUES ('committed')")
    }
    let before = try Data(contentsOf: target)
    var verificationFailed = false

    #expect(throws: (any Error).self) {
      try GatewayStateImport.run(exportFile: export, database: target) { connection in
        let imported = GatewayDatabase(connection: connection)
        do {
          try imported.verifyImportedState(configurationDirectory: root)
        } catch {
          verificationFailed = true
          throw error
        }
      }
    }
    #expect(verificationFailed)
    #expect(try Data(contentsOf: target) == before)
    #expect(!FileManager.default.fileExists(atPath: target.path + ".before-import"))
  }

  @Test func sharedRuntimeSettingDecodersKeepTheReadersRules() throws {
    #expect(
      try GatewayDatabase.decodeDesiredOpenAITunnelConfigurationIDs(#"[" b ","a","a",""]"#)
        == ["a", "b"])
    #expect(
      try GatewayDatabase.decodeDesiredCloudflareProfileIDs(#"[" b ","a","a",""]"#) == [
        "", " b ", "a", "a",
      ])
    #expect(
      try GatewayDatabase.decodeActiveGatewayProfile("custom-profile").rawValue
        == "custom-profile")
    #expect(
      try GatewayDatabase.decodeGatewayTunnelRegistration(
        "65A88D6F-49FC-4C88-984B-99E7DA08377C")
        == UUID(uuidString: "65A88D6F-49FC-4C88-984B-99E7DA08377C"))
  }

  private static func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Writes `database`'s preserved tables as a schema 1 export, in the form the one-time
  /// exporter writes them.
  private static func export(_ database: URL, to directory: URL) throws -> URL {
    let tables = [
      "workspaces", "workspaceCanonicalRoots", "workspaceAliases", "profiles",
      "clientControlTrust", "runtimeSettings", "configurationRevisions", "pluginState",
      "pluginOwnedDirectories", "pluginDerivedWorkspaces",
    ]
    var export: [String: Any] = ["schema_version": 1]
    try DatabaseQueue(path: database.path).read { database in
      for table in tables {
        let sql =
          table == "configurationRevisions"
          ? "SELECT * FROM configurationRevisions WHERE activatedAt IS NOT NULL "
            + "ORDER BY activatedAt DESC LIMIT 1"
          : "SELECT * FROM \(table.quotedDatabaseIdentifier)"
        export[table] = try Row.fetchAll(database, sql: sql).map { row in
          var values: [String: Any] = [:]
          for (column, value) in row {
            let isJSON =
              column.hasSuffix("JSON") || (table == "clientControlTrust" && column == "profile")
              || (table == "runtimeSettings" && column == "value"
                && (row["key"] as String).hasPrefix("desired-running-"))
            switch value.storage {
            case .null: values[column] = NSNull()
            case .int64(let integer): values[column] = integer
            case .double(let real): values[column] = real
            case .string(let text) where isJSON:
              values[column] = try JSONSerialization.jsonObject(
                with: Data(text.utf8), options: .fragmentsAllowed)
            case .string(let text): values[column] = text
            case .blob(let data):
              values[column] = ["encoding": "base64", "data": data.base64EncodedString()]
            }
          }
          return values
        }
      }
    }
    var workspaces = export["workspaces"] as! [[String: Any]]
    let roots = export.removeValue(forKey: "workspaceCanonicalRoots") as! [[String: Any]]
    for index in workspaces.indices {
      workspaces[index]["workspaceCanonicalRoots"] = roots.filter {
        $0["workspaceID"] as? String == workspaces[index]["id"] as? String
      }
    }
    export["workspaces"] = workspaces
    let url = directory.appendingPathComponent("export.json")
    try JSONSerialization.data(withJSONObject: export).write(to: url)
    return url
  }
}
