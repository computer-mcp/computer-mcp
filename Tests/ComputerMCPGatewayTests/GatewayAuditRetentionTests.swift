import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPPersistence
import Foundation
import GRDB
import Testing

@testable import ComputerMCPGateway

@Suite struct GatewayAuditRetentionTests {
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
