import ComputerMCPCore
import ComputerMCPGateway
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPTestSupport
import Foundation
import GRDB
import Testing

@testable import ComputerMCPControlPlane

@Suite struct PermissionControlServiceTests {
  @Test func localOwnerValidationRemainsRequiredForDiagnostics() throws {
    enum Failure: Error { case revoked }
    let connection = try GatewayDatabaseConnection(inMemory: ())
    let gateway = GatewayPermissionService(
      store: SQLitePermissionStore(
        connection: connection, counter: TestAuthorizationEpochCounter()),
      policyReader: TestManagedPolicyReader())
    let owner = try GatewayPermissionOwner(
      context: .init(caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "owner"),
      validate: { throw Failure.revoked })
    let control = PermissionControlService(service: gateway, owner: { owner })
    #expect(throws: Failure.revoked) { try control.view() }
  }
  @Test(arguments: OwnerAuditAction.allCases)
  func successfulOwnerChangesHaveDurableSecretFreeEvidence(action: OwnerAuditAction) throws {
    let fixture = try OwnerAuditFixture()
    let requestID = try fixture.prepare(action)
    let review = try fixture.control.view(now: fixture.now)
    let beforeIDs = Set(try fixture.events().map(\.id))
    try fixture.perform(action, requestID: requestID, review: review)
    let event = try #require(fixture.events().first { !beforeIDs.contains($0.id) })
    let details = try #require(event.errorDetails?.objectValue)
    #expect(event.caller == .localApp)
    #expect(event.profileID == .localAdmin)
    #expect(event.parentRequestID == nil)
    #expect(event.principalDigest == AuditEvent.verifiedPrincipalDigest("app-owner"))
    #expect(details["owner_action"] == .string(action.rawValue))
    #expect(details["authorization_epoch"] == review.epoch.map { .string($0.uuidString) })
    #expect(details["reviewed_permission_revision"]?.int64Value == Int64(review.revision))
    let profile = try #require(fixture.control.view(now: fixture.now).profiles.first)
    #expect(
      details["profile_revisions"]?.objectValue?[profile.id.rawValue]?.int64Value
        == profile.authorizationRevision)
    if let requestID {
      #expect(details["permission_request_ids"] == .array([.string(requestID.uuidString)]))
      #expect(details["requested_permission"]?.objectValue?["value"] == .string("access"))
    }
    let serialized = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
    #expect(!serialized.contains("secret-plugin-purpose"))
    #expect(!serialized.contains("private.example.com"))
    #expect(!serialized.contains("time_ms"))
    #expect(!serialized.contains("app-owner"))
  }

  @Test(arguments: OwnerAuditAction.allCases)
  func failedAuditRollsBackTheCompleteOwnerChange(action: OwnerAuditAction) throws {
    let fixture = try OwnerAuditFixture()
    let requestID = try fixture.prepare(action)
    let review = try fixture.control.view(now: fixture.now)
    let before = try fixture.snapshot()
    try fixture.connection.writer.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER failOwnerAudit BEFORE INSERT ON auditEvents
          BEGIN SELECT RAISE(ABORT, 'owner-audit-unavailable'); END
          """)
    }
    #expect(throws: DatabaseError.self) {
      try fixture.perform(action, requestID: requestID, review: review)
    }
    #expect(try fixture.snapshot() == before)
  }

  @Test func trustedSocketScopePreservesOwnerValidationAndCorrelation() throws {
    let fixture = try OwnerAuditFixture()
    let requestID = try #require(try fixture.prepare(.always))
    let review = try fixture.control.view(now: fixture.now)
    let context = ExecutionContext(
      requestID: "outer-control-request", caller: .localCLI, profileID: .localAdmin,
      transportTrace: .init(transport: "control_socket", socketConnectionID: "connection"),
      trustedPrincipalID: "socket-owner")
    try PermissionOwnerAuditScope.$context.withValue(context) {
      _ = try fixture.control.answerRequest(
        requestID, answer: .always, expectedRevision: review.revision, now: fixture.now)
    }
    let event = try #require(fixture.events().first { $0.parentRequestID == context.requestID })
    #expect(event.requestID != context.requestID)
    #expect(event.caller == .localCLI)
    #expect(event.transport == "control_socket")
    #expect(event.socketConnectionID == "connection")
    #expect(event.principalDigest == AuditEvent.verifiedPrincipalDigest("socket-owner"))
    #expect(try fixture.events().filter { $0.requestID == context.requestID }.isEmpty)

    enum Failure: Error { case revoked }
    let proof = try GatewayPermissionOwner(
      context: .init(caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "app-owner"),
      validate: { throw Failure.revoked })
    let revoked = PermissionControlService(service: fixture.gateway, owner: { proof })
    #expect(throws: Failure.revoked) {
      try PermissionOwnerAuditScope.$context.withValue(context) {
        try revoked.view(now: fixture.now)
      }
    }
  }
}

enum OwnerAuditAction: String, CaseIterable, Sendable {
  case onlyThisTime = "only_this_time"
  case always, deny
  case updateProfile = "update_profile"
  case revokePermission = "revoke_permission"
  case setOwnerPolicy = "set_owner_policy"
  case clearOwnerPolicy = "clear_owner_policy"
  case confirmAuthority = "confirm_authority"
}

struct OwnerAuditFixture {
  let connection: GatewayDatabaseConnection
  let store: SQLitePermissionStore
  let counter: TestAuthorizationEpochCounter
  let gateway: GatewayPermissionService
  let policyReader = TestManagedPolicyReader()
  let control: PermissionControlService
  let client: GatewayPermissionSubject
  let now = Date(timeIntervalSince1970: 1_750_000_000)

  init() throws {
    connection = try GatewayDatabaseConnection(inMemory: ())
    counter = TestAuthorizationEpochCounter()
    store = SQLitePermissionStore(connection: connection, counter: counter)
    gateway = GatewayPermissionService(store: store, policyReader: policyReader)
    let proof = try GatewayPermissionOwner(
      context: .init(caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "app-owner"),
      validate: {})
    control = PermissionControlService(service: gateway, owner: { proof })
    client = try GatewayPermissionSubject(
      context: .init(
        caller: .secureTunnel, profileID: .chatGPTOperate, trustedPrincipalID: "client"))
    try store.transactionWithDatabase { _, ledger in
      try ledger.acknowledgeEpochRecovery(#require(ledger.authorizationEpochID))
    }
    let review = try control.view(now: now)
    try control.confirmAuthority(
      epoch: #require(review.epoch), expectedRevision: review.revision,
      profileEdits: review.profiles, now: now)
    try control.updateProfile(
      ProfileGrant(id: .chatGPTOperate, allowedCallers: [.secureTunnel]),
      expectedProfileRevision: nil, expectedRevision: control.view(now: now).revision, now: now)
  }

  func prepare(_ action: OwnerAuditAction) throws -> UUID? {
    switch action {
    case .always, .onlyThisTime, .deny:
      let requirements = try InvocationRequirements(actions: [
        .init(requirement: .init(.screen, .access), pluginPurpose: "secret-plugin-purpose")
      ])
      guard
        case .requests(let requests) = try gateway.admit(
          subject: client, tool: "fixture", projectID: nil, argumentsDigest: "input-digest",
          requirements: requirements, now: now)
      else { throw OwnerAuditFixtureError.requestRequired }
      return try #require(requests.first).id
    case .revokePermission:
      let review = try control.view(now: now)
      var profile = try #require(review.profiles.first)
      try profile.permissions.set(.granted(.access), for: .screen)
      try control.updateProfile(
        profile, expectedProfileRevision: profile.authorizationRevision,
        expectedRevision: review.revision, now: now)
    case .clearOwnerPolicy:
      _ = try control.setOwnerPolicy(
        Data("[execution]\ntime_ms = 3000".utf8), profileID: .chatGPTOperate,
        expectedRevision: control.view(now: now).revision, now: now)
    case .confirmAuthority:
      counter.forget()
      let review = try control.view(now: now)
      try store.transactionWithDatabase { _, ledger in
        try ledger.acknowledgeEpochRecovery(#require(review.epoch))
      }
    default: break
    }
    return nil
  }

  func perform(_ action: OwnerAuditAction, requestID: UUID?, review: GatewayPermissionView) throws {
    switch action {
    case .onlyThisTime, .always:
      _ = try control.answerRequest(
        #require(requestID), answer: action == .always ? .always : .onlyThisTime,
        expectedRevision: review.revision, now: now)
    case .deny:
      _ = try control.declineRequest(
        #require(requestID), expectedRevision: review.revision, now: now)
    case .updateProfile:
      var profile = try #require(review.profiles.first)
      try profile.permissions.set(.granted(.access), for: .screen)
      profile.projectNetworks["project"] = .custom(
        hosts: ["private.example.com"], includesTrusted: false)
      try control.updateProfile(
        profile, expectedProfileRevision: profile.authorizationRevision,
        expectedRevision: review.revision, now: now)
    case .revokePermission:
      _ = try control.revokePermission(
        .screen, profileID: .chatGPTOperate, expectedRevision: review.revision, now: now)
    case .setOwnerPolicy, .clearOwnerPolicy:
      _ = try control.setOwnerPolicy(
        action == .setOwnerPolicy ? Data("[execution]\ntime_ms = 3000".utf8) : nil,
        profileID: .chatGPTOperate, expectedRevision: review.revision, now: now)
    case .confirmAuthority:
      try control.confirmAuthority(
        epoch: #require(review.epoch), expectedRevision: review.revision,
        profileEdits: review.profiles, now: now)
    }
  }

  func events() throws -> [AuditEvent] {
    try connection.writer.read { try AuditEventRecord.fetchAll($0).map { try $0.value() } }
  }

  struct Snapshot: Equatable {
    let ledger: Data?
    let profiles: [String]
    let policies: [String]
    let controlRevision: Int64?
    let auditIDs: [String]
  }

  func snapshot() throws -> Snapshot {
    try connection.writer.read { database in
      try Snapshot(
        ledger: Data.fetchOne(database, sql: "SELECT payload FROM permissionLedger"),
        profiles: String.fetchAll(
          database,
          sql:
            "SELECT hex(payload) || ':' || COALESCE(authorityEpoch, '') FROM permissionProfiles ORDER BY id"
        ),
        policies: String.fetchAll(
          database,
          sql:
            "SELECT hex(payload) || ':' || COALESCE(authorityEpoch, '') FROM permissionOwnerPolicies ORDER BY profileID"
        ),
        controlRevision: Int64.fetchOne(
          database, sql: "SELECT revision FROM permissionControlRevision"),
        auditIDs: String.fetchAll(database, sql: "SELECT id FROM auditEvents ORDER BY id"))
    }
  }
}

private enum OwnerAuditFixtureError: Error { case requestRequired }
