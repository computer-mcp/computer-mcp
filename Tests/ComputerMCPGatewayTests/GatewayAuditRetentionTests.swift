import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPPersistence
import Foundation
import GRDB
import Testing

@testable import ComputerMCPGateway

@Suite struct GatewayAuditRetentionTests {
  @Test func defaultRetentionIncludesTheNinetiethDayBoundary() throws {
    let database = try GatewayDatabase(inMemory: ())
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    try database.connection.writer.write { connection in
      for (id, age) in [("expired", 90.0 * 86_400 + 1), ("boundary", 90.0 * 86_400)] {
        try AuditEventRecord(
          AuditEvent(
            id: id, occurredAt: now.addingTimeInterval(-age), requestID: id,
            caller: .localApp, profileID: .localAdmin, capabilityID: "fixture.audit",
            decision: .allowed)
        ).insertRetained(connection, now: now)
      }
    }
    #expect(try database.auditEvents().map(\.id) == ["boundary"])
  }

  @Test(.timeLimit(.minutes(2))) func productionCapIsOneMillionEvenWhenLargerIsRequested() throws {
    let database = try GatewayDatabase(inMemory: ())
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    try database.connection.writer.write { connection in
      try connection.execute(
        sql: """
          WITH RECURSIVE entries(n) AS (VALUES(1) UNION ALL SELECT n + 1 FROM entries WHERE n < 1000000)
          INSERT INTO auditEvents
            (id, occurredAt, requestID, caller, profileID, capabilityID, decision)
          SELECT printf('%07d', n), ?, 'fixture', 'local-app', 'local-admin', 'fixture.audit', 'allowed'
          FROM entries
          """, arguments: [now.addingTimeInterval(-1)])
      let event = AuditEvent(
        id: "default", occurredAt: now, requestID: "default", caller: .localApp,
        profileID: .localAdmin, capabilityID: "fixture.audit", decision: .allowed)
      try AuditEventRecord(event).insertRetained(connection, now: now)
      #expect(try Int.fetchOne(connection, sql: "SELECT count(*) FROM auditEvents") == 1_000_000)
      #expect(
        try String.fetchOne(connection, sql: "SELECT id FROM auditEvents WHERE id = '0000001'")
          == nil)
      var next = event
      next.id = "oversized"
      try AuditEventRecord(next).insertRetained(connection, now: now, maximumEntries: 1_000_001)
      #expect(try Int.fetchOne(connection, sql: "SELECT count(*) FROM auditEvents") == 1_000_000)
      #expect(
        try String.fetchOne(connection, sql: "SELECT id FROM auditEvents WHERE id = '0000002'")
          == nil)
    }
  }

  @Test func ageAndCountPruningLeaveAuthorityUntouched() throws {
    let database = try GatewayDatabase(inMemory: ())
    try database.bootstrapPermissionProfiles([.localAdmin])
    let store = try database.configuredPermissionStore()
    let before = try store.readWithDatabase { _, ledger in
      (ledger.revision, ledger.authorizationEpochID)
    }
    let profile = try database.profiles()
    let now = Date()
    try database.connection.writer.write { connection in
      for offset in 0..<5 {
        try AuditEventRecord(
          AuditEvent(
            id: "event-\(offset)", occurredAt: now.addingTimeInterval(Double(offset - 100)),
            requestID: "request-\(offset)", caller: .localApp, profileID: .localAdmin,
            capabilityID: "fixture.audit", decision: .allowed)
        ).insertRetained(connection, now: now, maximumEntries: 3)
      }
      try AuditEventRecord(
        AuditEvent(
          id: "expired", occurredAt: now.addingTimeInterval(-91 * 86_400),
          requestID: "expired", caller: .localApp, profileID: .localAdmin,
          capabilityID: "fixture.audit", decision: .allowed)
      ).insertRetained(connection, now: now, maximumEntries: 3)
    }
    #expect(try database.auditEvents().map(\.id) == ["event-4", "event-3", "event-2"])
    #expect(try database.profiles() == profile)
    let after = try store.readWithDatabase { _, ledger in
      (ledger.revision, ledger.authorizationEpochID)
    }
    #expect(after.0 == before.0 && after.1 == before.1)
  }
}
