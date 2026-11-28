import ComputerMCPCore
import ComputerMCPWorktrees
import Foundation
import GRDB
import Testing

@testable import ComputerMCPPersistence

struct DerivedProjectMigrationTests {
  @Test(arguments: [false, true])
  func activatedPluginRowsAreRetiredWithDurableNotices(unbound: Bool) throws {
    try withDatabase { path in
      _ = try prepare(path, unbound: unbound)
      let host = try insertHostRow(path)
      let connection = try GatewayDatabaseConnection(path: path)
      #expect(try SQLiteDerivedProjectStore(connection: connection).records() == [host])
      try connection.writer.read { (database: Database) throws -> Void in
        #expect(try !database.tableExists("permissionDerivedProjects"))
        #expect(try !database.tableExists("pluginDerivedProjects"))
        #expect(try ProjectRecord.fetchOne(database, key: "child") == nil)
        #expect(
          try ProjectCanonicalRootRecord.filter(Column("projectID") == "child")
            .fetchCount(database) == 0)
        #expect(try ProjectRecord.fetchOne(database, key: "source") != nil)
        #expect(try ProfileRecord.fetchCount(database) == 1)
      }
      let notices = try PluginWorktreeRetirementStore(connection: connection).pending()
      #expect(notices.count == 1)
      let notice = try #require(notices.first)
      #expect(notice.checkoutPath == "/child")
      #expect(notice.sourceProjectID == "source")
      #expect(notice.sourceRepository == "/source")
      #expect(notice.sourceRegisteredAt == Date(timeIntervalSince1970: 1_700_000_000))
      #expect(
        Set(notice.fields.keys) == [
          "report_id", "code", "checkout_path", "source_project_id", "source_registered_at",
          "source_repository",
        ])
      #expect(notice.fields["code"] == .string("host.plugin_worktree_retired"))
      #expect(notice.fields["source_registered_at"] == .string("2023-11-14T22:13:20.000Z"))
      let reopened = try GatewayDatabaseConnection(path: path)
      #expect(try PluginWorktreeRetirementStore(connection: reopened).pending() == notices)
      #expect(try SQLiteDerivedProjectStore(connection: reopened).records() == [host])
    }
  }

  @Test func zeroPluginRowsRetireNothingAndKeepHostRows() throws {
    try withDatabase { path in
      do {
        let writer = try DatabaseQueue(path: path)
        try GatewayDatabaseConnection.migrator.migrate(writer, upTo: "provider-containers")
        try writer.close()
      }
      let host = try insertHostRow(path)
      let connection = try GatewayDatabaseConnection(path: path)
      #expect(try SQLiteDerivedProjectStore(connection: connection).records() == [host])
      #expect(try PluginWorktreeRetirementStore(connection: connection).pending().isEmpty)
    }
  }

  @Test func everyCheckoutAndSourceIsReportedAndEscaped() throws {
    try withDatabase { path in
      do {
        let writer = try DatabaseQueue(path: path)
        try GatewayDatabaseConnection.migrator.migrate(writer, upTo: "provider-containers")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try writer.write { database in
          for (id, root) in [("first", "/first"), ("second", "/second\nline")] {
            try ProjectRecord(
              RegisteredProject(
                id: id, displayName: id, rootPath: root, createdAt: date, updatedAt: date)
            ).insert(database)
          }
          for (id, source, root) in [
            ("first-child", "first", "/first-child"), ("second-child", "second", "/c\u{1}\"\\x"),
          ] {
            try ProjectRecord(
              RegisteredProject(
                id: id, displayName: id, rootPath: root, createdAt: date, updatedAt: date)
            ).insert(database)
            try database.execute(
              sql: "INSERT INTO derivedProjects VALUES (?, 1, ?, 1, 'active', ?)",
              arguments: [
                id, source,
                try Self.pluginPayload(
                  id: id, source: source,
                  sourceRoot: source == "first" ? "/first" : "/second\nline", root: root,
                  registeredAt: date),
              ])
          }
        }
        try writer.close()
      }
      let connection = try GatewayDatabaseConnection(path: path)
      #expect(try SQLiteDerivedProjectStore(connection: connection).records().isEmpty)
      let notices = try PluginWorktreeRetirementStore(connection: connection).pending()
      #expect(notices.map(\.checkoutPath) == ["/first-child", "/c\u{1}\"\\x"])
      #expect(notices.map(\.sourceProjectID) == ["first", "second"])
      #expect(notices.map(\.sourceRepository) == ["/first", "/second\nline"])
      #expect(Set(notices.map(\.reportID)).count == 2)
      for notice in notices {
        #expect(!notice.rendered.contains("\n") && !notice.rendered.contains("\u{1}"))
        let json = try #require(notice.rendered.split(separator: " ", maxSplits: 3).last)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(decoded == .object(notice.fields))
      }
    }
  }

  @Test(arguments: ["before-commit", "after-commit"])
  func retirementIsAtomicAcrossACrash(point: String) throws {
    try withDatabase { path in
      _ = try prepare(path)
      let writer = try DatabaseQueue(path: path)
      try GatewayDatabaseConnection.migrator.migrate(writer, upTo: "host-operations")
      if point == "before-commit" {
        try writer.write {
          try $0.execute(
            sql:
              "CREATE TRIGGER interrupt BEFORE DELETE ON derivedProjects BEGIN SELECT RAISE(ABORT, 'crash'); END"
          )
        }
        #expect(throws: (any Error).self) { try GatewayDatabaseConnection(path: path) }
        try writer.read { (database: Database) throws -> Void in
          #expect(try Int.fetchOne(database, sql: "SELECT count(*) FROM derivedProjects") == 1)
          #expect(try ProjectRecord.fetchOne(database, key: "child") != nil)
          #expect(try !database.tableExists("pluginWorktreeRetirements"))
          #expect(
            try !GatewayDatabaseConnection.migrator.appliedIdentifiers(database).contains(
              "plugin-worktree-retirement"))
        }
        try writer.write { try $0.execute(sql: "DROP TRIGGER interrupt") }
      }
      try writer.close()
      let connection = try GatewayDatabaseConnection(path: path)
      #expect(try SQLiteDerivedProjectStore(connection: connection).records().isEmpty)
      #expect(try PluginWorktreeRetirementStore(connection: connection).pending().count == 1)
    }
  }

  @Test func noticesStayPendingUntilASinkAcceptsThemAndMayRepeat() throws {
    try withDatabase { path in
      _ = try prepare(path)
      let connection = try GatewayDatabaseConnection(path: path)
      let store = PluginWorktreeRetirementStore(connection: connection)
      let notice = try #require(try store.pending().first)
      #expect(try store.drain { _ in throw CocoaError(.fileWriteNoPermission) } == 0)
      #expect(try store.pending() == [notice])
      // Emission succeeds but the acknowledgement does not commit, as after a crash.
      try connection.writer.write {
        try $0.execute(
          sql:
            "CREATE TRIGGER interrupt BEFORE UPDATE ON pluginWorktreeRetirements BEGIN SELECT RAISE(ABORT, 'crash'); END"
        )
      }
      var emitted: [UUID] = []
      #expect(throws: (any Error).self) { try store.drain { emitted.append($0.reportID) } }
      try connection.writer.write { try $0.execute(sql: "DROP TRIGGER interrupt") }
      #expect(try store.drain { emitted.append($0.reportID) } == 1)
      #expect(emitted == [notice.reportID, notice.reportID])
      #expect(try store.pending().isEmpty)
      #expect(try store.drain { _ in Issue.record("Acknowledged notices are not repeated.") } == 0)
    }
  }

  @Test func olderBinariesRefuseTheRetiredStore() throws {
    try withDatabase { path in
      _ = try prepare(path)
      _ = try GatewayDatabaseConnection(path: path)
      let writer = try DatabaseQueue(path: path)
      defer { try? writer.close() }
      let older = GatewayDatabaseConnection.migrator.migrations.filter {
        !["host-operations", "plugin-worktree-retirement"].contains($0)
      }
      try writer.read { (database: Database) throws -> Void in
        #expect(
          throws: UnsupportedDatabaseSchema(
            identifiers: ["host-operations", "plugin-worktree-retirement"])
        ) {
          try GatewayDatabaseConnection.checkSchema(database, known: older)
        }
        try GatewayDatabaseConnection.checkSchema(database)
      }
    }
  }

  @Test(arguments: [
    "corrupt", "missing-source", "source-root", "row-identity", "missing-profile", "caller",
  ])
  func invalidLiveStateRollsBackMigrationAndPreservesInput(failure: String) throws {
    try withDatabase { path in
      let original = try prepare(path)
      let writer = try DatabaseQueue(path: path)
      try writer.write { database in
        switch failure {
        case "corrupt":
          try database.execute(
            sql: "UPDATE permissionDerivedProjects SET payload = ?", arguments: [Data("{".utf8)])
        case "missing-source": try database.execute(sql: "DELETE FROM projects WHERE id = 'source'")
        case "source-root":
          try database.execute(
            sql: "UPDATE projects SET rootPath = '/different' WHERE id = 'source'")
        case "row-identity":
          try database.execute(
            sql: "UPDATE permissionDerivedProjects SET sourceProjectID = 'different'")
        case "caller":
          var json = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
          json["caller"] = "unsupported-caller"
          try database.execute(
            sql: "UPDATE permissionDerivedProjects SET payload = ?",
            arguments: [try JSONSerialization.data(withJSONObject: json)])
        default: try database.execute(sql: "DELETE FROM permissionProfiles")
        }
      }
      #expect(throws: (any Error).self) { try GatewayDatabaseConnection(path: path) }
      try writer.read { (database: Database) throws -> Void in
        #expect(try database.tableExists("permissionDerivedProjects"))
        #expect(try !database.tableExists("derivedProjects"))
        #expect(
          try Int.fetchOne(database, sql: "SELECT count(*) FROM permissionDerivedProjects") == 1)
        if failure != "corrupt" && failure != "caller" {
          #expect(
            try Data.fetchOne(database, sql: "SELECT payload FROM permissionDerivedProjects")
              == original)
        }
      }
      try writer.close()
    }
  }

  @Test func preActivationInputIsRetiredWithItsRegistration() throws {
    try withDatabase { path in
      _ = try prepare(path, activated: false)
      let connection = try GatewayDatabaseConnection(path: path)
      #expect(try SQLiteDerivedProjectStore(connection: connection).records().isEmpty)
      try connection.writer.read { (database: Database) throws -> Void in
        #expect(try !database.tableExists("pluginDerivedProjects"))
        #expect(try !database.tableExists("permissionDerivedProjects"))
        #expect(try ProjectRecord.fetchOne(database, key: "child") == nil)
        #expect(try ProjectRecord.fetchOne(database, key: "source") != nil)
      }
      let notices = try PluginWorktreeRetirementStore(connection: connection).pending()
      #expect(notices.map(\.checkoutPath) == ["/child"])
      #expect(notices.map(\.sourceRepository) == ["/source"])
      #expect(notices.first?.sourceRegisteredAt == Date(timeIntervalSince1970: 1_700_000_000))
    }
  }

  @Test func independentConnectionsCompareRevisionsAndRollbackAtomically() throws {
    try withDatabase { path in
      let first = try GatewayDatabaseConnection(path: path)
      let second = try GatewayDatabaseConnection(path: path)
      let store = SQLiteDerivedProjectStore(connection: first)
      let other = SQLiteDerivedProjectStore(connection: second)
      var record = DerivedProjectRecord(
        projectID: "host-child", source: .init(id: "source", root: "/source", registeredAt: Date()),
        root: "/worktrees/child/repository",
        provenance: .host(worktreeID: UUID(), storageGeneration: UUID()),
        state: .creating)
      try store.commit(record, expecting: nil)
      #expect(throws: DerivedProjectStoreError.revisionConflict) {
        try other.commit(record, expecting: nil)
      }
      record.revision = 2
      record.state = .active
      #expect(throws: DerivedProjectStoreError.invalidRecord) {
        try other.commit(record, expecting: 1)
      }
      record.state = .recoveryRequired
      #expect(throws: POSIXError.self) {
        try first.writer.write {
          try SQLiteDerivedProjectStore.commit(record, expecting: 1, in: $0)
          throw POSIXError(.EIO)
        }
      }
      #expect(try other.records().first?.revision == 1)
      try other.commit(record, expecting: 1)
      #expect(throws: DerivedProjectStoreError.revisionConflict) {
        try store.commit(record, expecting: 1)
      }
      #expect(try store.records() == [record])
    }
  }

  private func prepare(_ path: String, unbound: Bool = false, activated: Bool = true) throws -> Data
  {
    let writer = try DatabaseQueue(path: path)
    defer { try? writer.close() }
    try GatewayDatabaseConnection.migrator.migrate(writer, upTo: "permission-profile-publication")
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let source = RegisteredProject(
      id: "source", displayName: "Source", rootPath: "/source", createdAt: date, updatedAt: date)
    let child = RegisteredProject(
      id: "child", displayName: "Child", rootPath: "/child", createdAt: date, updatedAt: date)
    let wire = HistoricalReceipt(
      sourceWorkspaceID: source.id, sourceRoot: source.rootPath,
      principalID: unbound ? nil : "principal", workspace: child)
    let payload = try JSONEncoder().encode(wire)
    try writer.write { database in
      try ProjectRecord(source).insert(database)
      try ProjectRecord(child).insert(database)
      try database.execute(
        sql: "INSERT INTO pluginDerivedProjects VALUES (?, ?, ?, ?, ?)",
        arguments: [
          child.id, wire.origin, source.id, wire.receiptID,
          String(decoding: payload, as: UTF8.self),
        ])
      try ProjectCanonicalRootRecord(
        canonicalRootPath: child.rootPath, projectID: child.id, createdAt: date
      ).insert(database)
      if activated {
        let profile = ProfileGrant(id: .chatGPTOperate, allowedCallers: [.secureTunnel])
        try ProfileRecord(profile, authorityEpoch: UUID()).insert(database)
        try database.execute(
          sql:
            "INSERT INTO permissionMigration (id, version, inputDigest, catalogDigest) VALUES (1, 1, 'input', 'catalog')"
        )
        try database.execute(
          sql: "INSERT INTO permissionDerivedProjects VALUES (?, ?, ?)",
          arguments: [child.id, source.id, payload])
      }
    }
    return payload
  }

  /// The version-1 registration receipt written by historical hosts.
  private struct HistoricalReceipt: Encodable {
    let origin = "plugin:fixture"
    let receiptID = "receipt"
    let sourceWorkspaceID: String
    let sourceRoot: String
    let receiptDigest = "unchanged-digest"
    let profileID = "chatgpt-operate"
    let principalID: String?
    let caller = "secure-tunnel"
    let workspace: RegisteredProject
  }

  /// A codec-version-1 ledger row with plugin provenance, as historical hosts wrote it.
  private static func pluginPayload(
    id: String, source: String, sourceRoot: String, root: String, registeredAt: Date
  ) throws -> Data {
    struct Row: Encodable {
      let projectID: String
      let source: DerivedProjectSource
      let root: String
      let provenance: [String: [String: Data]]
      let state = "active"
      let revision = 1
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(
      Row(
        projectID: id, source: .init(id: source, root: sourceRoot, registeredAt: registeredAt),
        root: root, provenance: ["plugin": ["receipt": Data("{}".utf8)]]))
  }

  /// Writes a host row with the schema that precedes retirement.
  private func insertHostRow(_ path: String) throws -> DerivedProjectRecord {
    let writer = try DatabaseQueue(path: path)
    defer { try? writer.close() }
    try GatewayDatabaseConnection.migrator.migrate(writer, upTo: "provider-containers")
    let record = DerivedProjectRecord(
      projectID: "host-child",
      source: .init(id: "source", root: "/source", registeredAt: Date(timeIntervalSince1970: 1)),
      root: "/worktrees/host-child/repository",
      provenance: .host(worktreeID: UUID(), storageGeneration: UUID()), state: .creating)
    try writer.write { try SQLiteDerivedProjectStore.commit(record, expecting: nil, in: $0) }
    return record
  }

  private func withDatabase(_ action: (String) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try action(directory.appendingPathComponent("database.sqlite").path)
  }
}
