import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPPersistence
import Foundation
import GRDB
import Testing

@Suite struct HostCallRecordStoreTests {
  @Test func durableLifecycleRequiresExactLiveLeaseSets() throws {
    let connection = try GatewayDatabaseConnection(inMemory: ())
    let store = HostCallRecordStore(connection: connection)
    let admission = admission()
    let request = UUID()
    let work = UUID()
    try store.begin(admission, requestLeaseID: request)
    #expect(try store.record(id: admission.id)?.lifecycle == .running)
    #expect(throws: (any Error).self) {
      try store.requireLive(admission, requestLeaseIDs: [UUID()], workLeaseIDs: [])
    }
    try store.replaceLeases(
      admission, expectedRequest: [request], expectedWork: [],
      requestLeaseIDs: [request], workLeaseIDs: [work])
    try store.replaceLeases(
      admission, expectedRequest: [request], expectedWork: [work],
      requestLeaseIDs: [], workLeaseIDs: [work])
    #expect(try store.record(id: admission.id)?.lifecycle == .retained)
    let reopened = HostCallRecordStore(connection: connection)
    #expect(try reopened.record(id: admission.id)?.admission == admission)
    try store.requireLive(admission, requestLeaseIDs: [], workLeaseIDs: [work])
    try store.replaceLeases(
      admission, expectedRequest: [], expectedWork: [work],
      requestLeaseIDs: [], workLeaseIDs: [])
    #expect(try store.record(id: admission.id)?.lifecycle == .completed)
    #expect(throws: (any Error).self) {
      try store.requireLive(admission, requestLeaseIDs: [], workLeaseIDs: [work])
    }
    #expect(throws: (any Error).self) { try store.begin(admission, requestLeaseID: UUID()) }
  }

  @Test(arguments: [
    "unchanged", "verifiedClientID", "projectID", "sourceProjectID", "upstreamName",
    "argumentsDigest",
    "requestID",
  ])
  func admissionFactsCannotBeSubstituted(field: String) throws {
    let connection = try GatewayDatabaseConnection(inMemory: ())
    let store = HostCallRecordStore(connection: connection)
    let admitted = admission()
    let lease = UUID()
    try store.begin(admitted, requestLeaseID: lease)
    var payload = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(admitted)) as? [String: Any])
    if field != "unchanged" { payload[field] = "foreign" }
    let forged = try JSONDecoder().decode(
      HostCallAdmission.self, from: JSONSerialization.data(withJSONObject: payload))
    if field == "unchanged" {
      try store.requireLive(forged, requestLeaseIDs: [lease], workLeaseIDs: [])
    } else {
      #expect(throws: HostCallRecordError.mismatch) {
        try store.requireLive(forged, requestLeaseIDs: [lease], workLeaseIDs: [])
      }
    }
    try store.requireLive(admitted, requestLeaseIDs: [lease], workLeaseIDs: [])
  }

  @Test func failedWriteCannotPublishOrReplaceARecord() throws {
    let connection = try GatewayDatabaseConnection(inMemory: ())
    let store = HostCallRecordStore(connection: connection)
    let admitted = admission()
    let request = UUID()
    try connection.writer.write { database in
      try database.execute(
        sql:
          "CREATE TRIGGER reject_call BEFORE INSERT ON hostCallRecords BEGIN SELECT RAISE(ABORT, 'fixture'); END"
      )
    }
    #expect(throws: (any Error).self) { try store.begin(admitted, requestLeaseID: request) }
    #expect(try store.record(id: admitted.id) == nil)
    try connection.writer.write { try $0.execute(sql: "DROP TRIGGER reject_call") }
    try store.begin(admitted, requestLeaseID: request)
    try connection.writer.write { database in
      try database.execute(
        sql:
          "CREATE TRIGGER reject_update BEFORE UPDATE ON hostCallRecords BEGIN SELECT RAISE(ABORT, 'fixture'); END"
      )
    }
    #expect(throws: (any Error).self) {
      try store.replaceLeases(
        admitted, expectedRequest: [request], expectedWork: [],
        requestLeaseIDs: [], workLeaseIDs: [])
    }
    #expect(try store.record(id: admitted.id)?.lifecycle == .running)
  }

  @Test func ageAndCapacityPruneOnlyCompletedRecords() throws {
    let connection = try GatewayDatabaseConnection(inMemory: ())
    let store = HostCallRecordStore(connection: connection, maximumRecords: 2)
    let now = Date(timeIntervalSince1970: 10_000_000)
    let old = admission(createdAt: now.addingTimeInterval(-91 * 86_400))
    let oldLease = UUID()
    try store.begin(old, requestLeaseID: oldLease)
    try store.replaceLeases(
      old, expectedRequest: [oldLease], expectedWork: [],
      requestLeaseIDs: [], workLeaseIDs: [], now: old.createdAt)
    let a = admission(createdAt: now)
    let aLease = UUID()
    try store.begin(a, requestLeaseID: aLease)
    #expect(try store.record(id: old.id) == nil)
    let b = admission(createdAt: now)
    let bLease = UUID()
    try store.begin(b, requestLeaseID: bLease)
    #expect(throws: HostCallRecordError.capacity) {
      try store.begin(admission(createdAt: now), requestLeaseID: UUID())
    }
    try store.replaceLeases(
      a, expectedRequest: [aLease], expectedWork: [],
      requestLeaseIDs: [], workLeaseIDs: [], now: now)
    let c = admission(createdAt: now)
    try store.begin(c, requestLeaseID: UUID())
    #expect(try store.record(id: a.id) == nil)
    #expect(try store.record(id: b.id)?.lifecycle == .running)
    #expect(try store.record(id: c.id)?.lifecycle == .running)
  }

  private func admission(createdAt: Date = Date()) -> HostCallAdmission {
    .init(
      id: UUID(), generationID: UUID(), verifiedClientID: "verified-client",
      actingPrincipal: .plugin(.localServer("server")), profileID: .chatGPTOperate,
      caller: .secureTunnel, projectID: "derived", sourceProjectID: "source",
      upstreamName: "adapter.remove", reference: .init(serverID: "server", toolName: "remove"),
      action: .projectRemoval, argumentsDigest: "digest", authorizationID: UUID(),
      authorizationRevision: 1, controlSessionID: nil, controlSessionRevision: nil,
      requestID: "request", createdAt: createdAt)
  }
}
