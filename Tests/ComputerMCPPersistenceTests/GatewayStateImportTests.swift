import Foundation
import GRDB
import Testing

@testable import ComputerMCPPersistence

struct GatewayStateImportTests {
  @Test func importsEveryColumnUnchanged() throws {
    let directory = try TemporaryDirectory()
    let report = try Self.importState(Self.export(), into: directory.database)

    #expect(report.previousDatabase == nil)
    #expect(!report.restoredInterruptedImport)
    #expect(report.rowCounts.map(\.table) == Self.tables)
    #expect(report.rowCounts.map(\.rows) == [1, 1, 0, 1, 1, 2, 1, 1, 0, 0])
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.database.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(directory.entries() == ["gateway.sqlite"])

    let database = try DatabaseQueue(path: directory.database.path)
    try database.read { database in
      let workspace = try #require(try Row.fetchOne(database, sql: "SELECT * FROM workspaces"))
      #expect(workspace["bookmarkData"] as Data? == Data([0, 1, 2, 255]))
      #expect(workspace["bookmarkIsStale"] as Int64? == 0)
      #expect(workspace["createdAt"] as String? == "2026-10-01 08:00:00.000")
      #expect(
        try String.fetchAll(database, sql: "SELECT canonicalRootPath FROM workspaceCanonicalRoots")
          == ["/Users/example/project"])
      let profile = try #require(try Row.fetchOne(database, sql: "SELECT * FROM profiles"))
      #expect(profile["capabilityIDsJSON"] as String? == #"["file.read","git.status"]"#)
      #expect(profile["authorizationRevision"] as Int64? == 3)
      #expect(
        try String.fetchOne(database, sql: "SELECT profile FROM clientControlTrust")
          == #"{"mode":"operate","shell":false}"#)
      #expect(
        try String.fetchAll(database, sql: "SELECT value FROM runtimeSettings ORDER BY key")
          == ["chatgpt-operate", #"["chatgpt"]"#])
      let plugin = try #require(try Row.fetchOne(database, sql: "SELECT * FROM pluginState"))
      #expect(plugin["revision"] as Int64? == 4)
      #expect(
        plugin["payloadJSON"] as String?
          == #"{"installations":[{"registeredAt":782000000.25,"root":"file:///plugins/a/"}],"revision":4}"#
      )
      #expect(
        try String.fetchAll(database, sql: "SELECT identifier FROM grdb_migrations")
          == ["gateway-initial"])
    }
  }

  @Test func replacesAnEarlierDatabaseAndKeepsItWithItsSidecars() throws {
    let directory = try TemporaryDirectory()
    try Self.makeEarlierDatabase(at: directory.database)
    let before = try Self.dump(directory.database)
    FileManager.default.createFile(atPath: directory.database.path + "-journal", contents: nil)

    let report = try Self.importState(Self.export(), into: directory.database)

    #expect(report.previousDatabase == directory.previous)
    #expect(try Self.dump(directory.previous) == before)
    #expect(try Self.ledger(directory.database) == ["gateway-initial"])
    #expect(
      directory.entries() == [
        "gateway.sqlite", "gateway.sqlite.before-import", "gateway.sqlite.before-import-journal",
      ])
  }

  @Test func refusesADatabaseThatIsOpen() throws {
    let directory = try TemporaryDirectory()
    try Self.makeEarlierDatabase(at: directory.database)
    let before = try Self.dump(directory.database)
    let holder = try FileHandle(forReadingFrom: directory.database)

    #expect(
      throws: GatewayStateImportError.databaseInUse(processIDs: [
        ProcessInfo.processInfo.processIdentifier
      ])
    ) {
      try Self.importState(Self.export(), into: directory.database)
    }
    #expect(try Self.dump(directory.database) == before)
    #expect(directory.entries() == ["gateway.sqlite"])

    try holder.close()
    #expect(try Self.importState(Self.export(), into: directory.database).previousDatabase != nil)
  }

  @Test func refusesADatabaseWithThisVersionsSchema() throws {
    let directory = try TemporaryDirectory()
    _ = try GatewayDatabaseConnection(path: directory.database.path)
    let before = try Self.dump(directory.database)

    #expect(throws: GatewayStateImportError.databaseAlreadyCurrent(directory.database.path)) {
      try Self.importState(Self.export(), into: directory.database)
    }
    #expect(try Self.dump(directory.database) == before)
    #expect(directory.entries() == ["gateway.sqlite"])
  }

  @Test func refusesWhenThePreviousDatabaseNameIsTaken() throws {
    let directory = try TemporaryDirectory()
    try Self.makeEarlierDatabase(at: directory.database)
    try Data("kept".utf8).write(to: directory.previous)

    #expect(throws: GatewayStateImportError.previousDatabaseExists(directory.previous.path)) {
      try Self.importState(Self.export(), into: directory.database)
    }
    #expect(try Data(contentsOf: directory.previous) == Data("kept".utf8))
    #expect(directory.entries() == ["gateway.sqlite", "gateway.sqlite.before-import"])
  }

  @Test func failedVerificationLeavesTheEarlierDatabaseUsable() throws {
    struct Unusable: Error {}
    let directory = try TemporaryDirectory()
    try Self.makeEarlierDatabase(at: directory.database)
    let before = try Self.dump(directory.database)

    #expect(throws: Unusable.self) {
      try GatewayStateImport.run(
        exportFile: Self.write(Self.export(), to: directory.export), database: directory.database
      ) { _ in throw Unusable() }
    }
    #expect(try Self.dump(directory.database) == before)
    #expect(directory.entries() == ["gateway.sqlite"])
    #expect(throws: UnsupportedDatabaseSchema(identifiers: ["initial-schema"])) {
      try GatewayDatabaseConnection(path: directory.database.path)
    }
  }

  @Test(arguments: [
    ExportDefect.schemaVersion, .unknownColumn, .unsupportedValue, .missingTable,
  ])
  func invalidExportChangesNothing(_ defect: ExportDefect) throws {
    let directory = try TemporaryDirectory()
    try Self.makeEarlierDatabase(at: directory.database)
    let before = try Self.dump(directory.database)
    var export = Self.export()
    switch defect {
    case .schemaVersion: export["schema_version"] = 2
    case .unknownColumn: export["profiles"] = [Self.profile.merging(["extra": 1]) { $1 }]
    case .unsupportedValue:
      export["runtimeSettings"] = [["key": "a", "value": [1], "updatedAt": "x"]]
    case .missingTable: export["pluginState"] = nil
    }

    #expect(throws: GatewayStateImportError.self) {
      try Self.importState(export, into: directory.database)
    }
    #expect(try Self.dump(directory.database) == before)
    #expect(directory.entries() == ["gateway.sqlite"])
  }

  @Test(arguments: [
    InterruptedStep.recorded, .sidecarMoved, .previousMoved, .stagedMoved,
  ])
  func interruptedReplacementRollsBack(_ step: InterruptedStep) throws {
    let directory = try TemporaryDirectory()
    try Self.makeEarlierDatabase(at: directory.database)
    let before = try Self.dump(directory.database)
    let journal = Data("earlier journal".utf8)
    try journal.write(to: URL(fileURLWithPath: directory.database.path + "-journal"))
    _ = try GatewayDatabaseConnection(path: directory.staged.path)
    FileManager.default.createFile(atPath: directory.replacing.path, contents: nil)
    if step != .recorded {
      try FileManager.default.moveItem(
        atPath: directory.database.path + "-journal",
        toPath: directory.previous.path + "-journal")
    }
    if step == .previousMoved || step == .stagedMoved {
      try FileManager.default.moveItem(at: directory.database, to: directory.previous)
    }
    if step == .stagedMoved {
      try FileManager.default.moveItem(at: directory.staged, to: directory.database)
    }

    #expect(throws: InterruptedStateImport(path: directory.database.path)) {
      try GatewayDatabaseConnection(path: directory.database.path)
    }
    #expect(try GatewayStateImport.recover(.init(database: directory.database)))
    #expect(directory.entries() == ["gateway.sqlite", "gateway.sqlite-journal"])
    #expect(
      try Data(contentsOf: URL(fileURLWithPath: directory.database.path + "-journal")) == journal)
    try FileManager.default.removeItem(atPath: directory.database.path + "-journal")
    #expect(try Self.dump(directory.database) == before)
    #expect(try !GatewayStateImport.recover(.init(database: directory.database)))
  }

  @Test func importAfterAnInterruptionRestoresThenImports() throws {
    let directory = try TemporaryDirectory()
    try Self.makeEarlierDatabase(at: directory.database)
    let before = try Self.dump(directory.database)
    FileManager.default.createFile(atPath: directory.replacing.path, contents: nil)
    try FileManager.default.moveItem(at: directory.database, to: directory.previous)

    let report = try Self.importState(Self.export(), into: directory.database)

    #expect(report.restoredInterruptedImport)
    #expect(try Self.dump(directory.previous) == before)
    #expect(try Self.ledger(directory.database) == ["gateway-initial"])
    #expect(directory.entries() == ["gateway.sqlite", "gateway.sqlite.before-import"])
  }

  enum ExportDefect: Sendable { case schemaVersion, unknownColumn, unsupportedValue, missingTable }
  enum InterruptedStep: Sendable { case recorded, sidecarMoved, previousMoved, stagedMoved }

  private static let tables = [
    "workspaces", "workspaceCanonicalRoots", "workspaceAliases", "profiles",
    "clientControlTrust", "runtimeSettings", "configurationRevisions", "pluginState",
    "pluginOwnedDirectories", "pluginDerivedWorkspaces",
  ]

  private static var profile: [String: Any] {
    [
      "id": "chatgpt-operate", "capabilityIDsJSON": ["file.read", "git.status"],
      "workspaceIDsJSON": ["W1"], "allowedCallersJSON": ["secure-tunnel"], "fullShellEnabled": 0,
      "updatedAt": "2026-10-01 08:00:00.000", "mcpServerIDsJSON": [], "mode": "operate",
      "confirmationPolicy": "never", "authorizationRevision": 3,
    ]
  }

  /// A schema 1 export in the form the M3 exporter writes.
  private static func export() -> [String: Any] {
    [
      "schema_version": 1,
      "source": ["database_sha256": "0", "row_counts": [:], "grdb_migrations": ["initial-schema"]],
      "workspaces": [
        [
          "id": "W1", "displayName": "Project", "rootPath": "/Users/example/project",
          "bookmarkData": ["encoding": "base64", "data": "AAEC/w=="], "bookmarkIsStale": 0,
          "createdAt": "2026-10-01 08:00:00.000", "updatedAt": "2026-10-01 08:00:00.000",
          "workspaceCanonicalRoots": [
            [
              "canonicalRootPath": "/Users/example/project", "workspaceID": "W1",
              "createdAt": "2026-10-01 08:00:00.000",
            ]
          ],
        ]
      ],
      "workspaceAliases": [],
      "profiles": [profile],
      "clientControlTrust": [
        [
          "id": "trust-1", "principalID": "credential:a", "profileID": "chatgpt-operate",
          "caller": "secure-tunnel", "revision": 1, "profile": ["mode": "operate", "shell": false],
          "fullAccessAllowed": 0, "updatedAt": "2026-10-01 08:00:00.000",
        ]
      ],
      "runtimeSettings": [
        ["key": "active-gateway-profile", "value": "chatgpt-operate", "updatedAt": "2026-10-01"],
        ["key": "desired-running-openai-tunnels", "value": ["chatgpt"], "updatedAt": "2026-10-01"],
      ],
      "configurationRevisions": [
        [
          "id": "R1", "digest": "abc", "manifest": "schema_version = 1\n",
          "createdAt": "2026-10-01 08:00:00.000", "activatedAt": "2026-10-01 08:00:00.000",
          "activationError": NSNull(),
        ]
      ],
      "pluginState": [
        [
          "id": 1, "revision": 4,
          "payloadJSON": [
            "revision": 4,
            "installations": [["registeredAt": 782_000_000.25, "root": "file:///plugins/a/"]],
          ],
        ]
      ],
      "pluginOwnedDirectories": [],
      "pluginDerivedWorkspaces": [],
      "configuration_toml": "schema_version = 1\n",
      "secret_references": [["service": "com.example.secrets", "account": "tunnel.chatgpt"]],
      "dropped": ["auditEvents": 3],
      "exported_at": "2026-10-19T03:07:00Z",
    ]
  }

  @discardableResult
  private static func importState(_ export: [String: Any], into database: URL) throws
    -> GatewayStateImport.Report
  {
    let file = database.deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("export.json")
    return try GatewayStateImport.run(exportFile: write(export, to: file), database: database) {
      _ in
    }
  }

  private static func write(_ export: [String: Any], to url: URL) throws -> URL {
    try JSONSerialization.data(withJSONObject: export).write(to: url)
    return url
  }

  /// A database as a version before 0.1.0 left it.
  private static func makeEarlierDatabase(at url: URL) throws {
    let database = try DatabaseQueue(path: url.path)
    try database.write { database in
      try database.execute(
        sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
      try database.execute(sql: "INSERT INTO grdb_migrations VALUES ('initial-schema')")
      try database.execute(sql: "CREATE TABLE workspaces (id TEXT PRIMARY KEY, rootPath TEXT)")
      try database.execute(sql: "INSERT INTO workspaces VALUES ('W0', '/Users/example/old')")
    }
  }

  private static func ledger(_ url: URL) throws -> [String] {
    try DatabaseQueue(path: url.path).read {
      try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations")
    }
  }

  /// Schema and rows, read by a plain SQLite connection as an earlier version would open it.
  private static func dump(_ url: URL) throws -> [String] {
    try DatabaseQueue(path: url.path).read { database in
      var lines: [String] = []
      for (name, sql) in try Row.fetchAll(
        database,
        sql: "SELECT name, sql FROM sqlite_schema WHERE type = 'table' ORDER BY name"
      ).map({ ($0["name"] as String, $0["sql"] as String) }) {
        lines.append(sql)
        lines += try Row.fetchAll(database, sql: "SELECT * FROM \(name.quotedDatabaseIdentifier)")
          .map(\.description)
      }
      return lines
    }
  }
}

/// A database directory, with the export written beside it.
private struct TemporaryDirectory {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent("state", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  var export: URL { url.deletingLastPathComponent().appendingPathComponent("export.json") }
  var database: URL { url.appendingPathComponent("gateway.sqlite") }
  var staged: URL { url.appendingPathComponent("gateway.sqlite.import") }
  var previous: URL { url.appendingPathComponent("gateway.sqlite.before-import") }
  var replacing: URL { url.appendingPathComponent("gateway.sqlite.import-replacing") }

  func entries() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
  }
}
