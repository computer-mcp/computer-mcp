import Foundation
import GRDB
import Testing

@testable import ComputerMCPPersistence

struct ProjectSchemaMigrationTests {
  @Test func liveStateChangesAndHistoryAndOwnershipStayIntact() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("gateway.sqlite").path
    let earlier = try DatabaseQueue(path: path)
    try GatewayDatabaseConnection.migrator.migrate(earlier, upTo: "audit-error-details")
    let ownership =
      #"{"sourceWorkspaceID":"source","workspace":{"id":"derived"},"receiptDigest":"stable-digest"}"#
    let historical =
      #"{"workspaceID":"source","capabilityID":"workspace.list","mode":"workspace-operations"}"#
    try earlier.write { db in
      try db.execute(
        sql: """
          INSERT INTO workspaces VALUES ('source','Source','/source',NULL,0,'2026-10-22','2026-10-22');
          INSERT INTO workspaceAliases VALUES ('alias','source','/source','2026-10-22');
          INSERT INTO workspaceCanonicalRoots VALUES ('/source','source','2026-10-22');
          INSERT INTO profiles (id,capabilityIDsJSON,workspaceIDsJSON,allowedCallersJSON,fullShellEnabled,updatedAt,mode)
          VALUES ('profile','["workspace.list","workspace.instructions","file.read","mcp.workspace.list"]','["source","workspace.id"]','["local-cli"]',0,'2026-10-22','workspace-operations');
          INSERT INTO auditEvents (id,occurredAt,requestID,caller,profileID,workspaceID,capabilityID,decision,errorCode)
          VALUES ('audit','2026-10-22','request','local-cli','profile','source','workspace.list','denied','policy.workspace_denied');
          INSERT INTO operationTickets (id,capabilityID,caller,profileID,principalID,workspaceID,inputDigest,state,prepareRequestID,createdAt,expiresAt)
          VALUES ('done','workspace.remove','local-cli','profile','principal','source','digest','succeeded','request','2026-10-22','2026-10-23'),
                 ('live','workspace.remove','local-cli','profile','principal','source','digest','prepared','request','2026-10-22','2026-10-23');
          """)
      try db.execute(
        sql: "INSERT INTO pluginDerivedWorkspaces VALUES ('derived','plugin','source','receipt',?)",
        arguments: [ownership])
      try db.execute(
        sql:
          "INSERT INTO workspaceDeduplicationReceipts VALUES ('receipt','digest','2026-10-22',?)",
        arguments: [historical])
      try db.execute(
        sql:
          "INSERT INTO configurationRevisions VALUES ('revision','digest',?,'2026-10-22','2026-10-22',NULL)",
        arguments: [historical])
      try db.execute(
        sql: "INSERT INTO mcpExecutions VALUES ('execution',?,NULL,NULL)", arguments: [historical])
      try db.execute(
        sql: "INSERT INTO pluginState VALUES (1,0,?)",
        arguments: [
          #"{"revision":0,"installations":[],"selectedInstallations":{},"settings":{"plugin":{"mcp":{"server":{"toolRisks":{"workspace.tool":"workspace-write","read":"read-only"},"args":["workspace-write"]}}}}}"#
        ])
      try db.execute(
        sql:
          "INSERT INTO clientControlTrust VALUES ('trust','principal','profile','local-cli',1,?,1,'2026-10-22')",
        arguments: [
          #"{"grant":{"workspaceIDs":["source"],"capabilityIDs":["workspace.list"],"mode":"workspace-operations"},"configuredGrant":{"workspaceIDs":["workspace.id"],"capabilityIDs":["workspace.instructions"],"mode":"workspace-operations"},"persisted":true}"#
        ])
    }
    let before = try snapshot(earlier)
    try earlier.close()
    let migrated = try GatewayDatabaseConnection(path: path)
    let after = try snapshot(migrated.writer)
    for (table, rows) in before where table != "grdb_migrations" {
      let renamed = table.replacingOccurrences(of: "workspace", with: "project")
        .replacingOccurrences(of: "Workspace", with: "Project")
      #expect(after[renamed]?.count == rows.count)
    }
    try migrated.writer.read { db in
      #expect(try db.tableExists("projects"))
      #expect(try !db.tableExists("workspaces"))
      #expect(try db.columns(in: "projectAliases").map(\.name).contains("canonicalProjectID"))
      #expect(try db.columns(in: "profiles").map(\.name).contains("projectIDsJSON"))
      #expect(
        try db.indexes(on: "projectAliases").contains {
          $0.name == "projectAliases_on_canonicalProjectID"
        })
      let profile = try #require(try Row.fetchOne(db, sql: "SELECT * FROM profiles"))
      #expect(profile["mode"] as String == "project-operations")
      #expect(profile["projectIDsJSON"] as String == #"["source","workspace.id"]"#)
      let tools = try JSONDecoder().decode(
        [String].self, from: Data((profile["capabilityIDsJSON"] as String).utf8))
      #expect(tools == ["project.list", "project.instructions", "file.read", "mcp.workspace.list"])
      let trust = try #require(
        try String.fetchOne(db, sql: "SELECT profile FROM clientControlTrust"))
      let object = try JSONSerialization.jsonObject(with: Data(trust.utf8)) as! [String: Any]
      for key in ["grant", "configuredGrant"] {
        let grant = try #require(object[key] as? [String: Any])
        #expect(grant["workspaceIDs"] == nil)
        #expect(grant["projectIDs"] != nil)
        #expect(grant["mode"] as? String == "project-operations")
      }
      let pluginJSON = try #require(
        try String.fetchOne(db, sql: "SELECT payloadJSON FROM pluginState"))
      let plugin = try JSONSerialization.jsonObject(with: Data(pluginJSON.utf8)) as! [String: Any]
      let settings = plugin["settings"] as! [String: [String: Any]]
      let components = settings["plugin"]!["mcp"] as! [String: [String: Any]]
      #expect(
        components["server"]!["toolRisks"] as? [String: String] == [
          "workspace.tool": "project-write", "read": "read-only",
        ])
      #expect(components["server"]!["args"] as? [String] == ["workspace-write"])
      #expect(
        try String.fetchOne(db, sql: "SELECT payloadJSON FROM pluginDerivedProjects") == ownership)
      #expect(
        try String.fetchOne(db, sql: "SELECT payloadJSON FROM projectDeduplicationReceipts")
          == historical)
      #expect(
        try String.fetchOne(db, sql: "SELECT manifest FROM configurationRevisions") == historical)
      #expect(try String.fetchOne(db, sql: "SELECT metadataJSON FROM mcpExecutions") == historical)
      #expect(
        try String.fetchOne(db, sql: "SELECT capabilityID FROM auditEvents") == "workspace.list")
      #expect(
        try String.fetchOne(db, sql: "SELECT errorCode FROM auditEvents")
          == "policy.workspace_denied")
      #expect(
        try String.fetchOne(db, sql: "SELECT capabilityID FROM operationTickets WHERE id='done'")
          == "workspace.remove")
      #expect(
        try String.fetchOne(db, sql: "SELECT capabilityID FROM operationTickets WHERE id='live'")
          == "project.remove")
    }
    #expect(try snapshot(GatewayDatabaseConnection(path: path).writer) == after)
  }

  @Test func failedMigrationRollsBackSchemaAndLiveState() throws {
    let writer = try DatabaseQueue()
    try GatewayDatabaseConnection.migrator.migrate(writer, upTo: "audit-error-details")
    try writer.write { db in
      try db.execute(
        sql:
          "INSERT INTO clientControlTrust VALUES ('trust','principal','profile','local-cli',1,'[]',1,'2026-10-22')"
      )
    }
    let before = try snapshot(writer)
    #expect(throws: (any Error).self) { try GatewayDatabaseConnection.migrator.migrate(writer) }
    #expect(try snapshot(writer) == before)
    #expect(try writer.read { try $0.tableExists("workspaces") })
  }

  private func snapshot(_ writer: any DatabaseReader) throws -> [String: [String]] {
    try writer.read { db in
      var result: [String: [String]] = [:]
      for table in try String.fetchAll(
        db, sql: "SELECT name FROM sqlite_schema WHERE type='table' ORDER BY name")
      {
        result[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid").map(
          \.description)
      }
      return result
    }
  }
}
