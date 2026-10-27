import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPWorktrees
import Foundation
import GRDB
import Testing

@testable import ComputerMCPPersistence

struct DerivedProjectMigrationTests {
  @Test(arguments: [false, true])
  func activatedRowsRetainExactReceiptAndNeverInferPrincipal(unbound: Bool) throws {
    try withDatabase { path in
      let old = try prepare(path, unbound: unbound)
      let connection = try GatewayDatabaseConnection(path: path)
      let record = try #require(
        try SQLiteDerivedProjectStore(connection: connection).records().first)
      #expect(record.projectID == "child")
      #expect(record.source.id == "source")
      #expect(record.revision == 1)
      guard case .plugin(let receipt) = record.provenance else {
        Issue.record("Expected plugin provenance")
        return
      }
      #expect(receipt == old)
      let wire = try JSONDecoder().decode(MCPDerivedProjectRegistration.self, from: receipt)
      #expect(wire.principalID == (unbound ? nil : "principal"))
      #expect(wire.receiptDigest == "unchanged-digest")
      try connection.writer.read { (database: Database) throws -> Void in
        #expect(try !database.tableExists("permissionDerivedProjects"))
        #expect(try !database.tableExists("pluginDerivedProjects"))
        #expect(try ProfileRecord.fetchCount(database) == 1)
      }
      let reopened = try GatewayDatabaseConnection(path: path)
      #expect(try SQLiteDerivedProjectStore(connection: reopened).records() == [record])
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

  @Test func preActivationInputIsRetainedAndHasNoLiveAuthority() throws {
    try withDatabase { path in
      _ = try prepare(path, activated: false)
      let connection = try GatewayDatabaseConnection(path: path)
      #expect(try SQLiteDerivedProjectStore(connection: connection).records().isEmpty)
      try connection.writer.read { (database: Database) throws -> Void in
        #expect(try database.tableExists("pluginDerivedProjects"))
        #expect(try Int.fetchOne(database, sql: "SELECT count(*) FROM pluginDerivedProjects") == 1)
        #expect(try !database.tableExists("permissionDerivedProjects"))
      }
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
    let wire = MCPDerivedProjectRegistration(
      origin: "plugin:fixture", receiptID: "receipt", sourceProjectID: source.id,
      sourceRoot: source.rootPath, receiptDigest: "unchanged-digest", profileID: .chatGPTOperate,
      principalID: unbound ? nil : "principal", caller: .secureTunnel, project: child)
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

  private func withDatabase(_ action: (String) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try action(directory.appendingPathComponent("database.sqlite").path)
  }
}
