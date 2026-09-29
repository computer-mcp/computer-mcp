import Foundation
import GRDB
import Testing

@testable import ComputerMCP

struct GatewayFullAccessConsentTests {
  @Test(arguments: [false, true])
  func changedRestrictedProfileRejectsAnOpenFullAccessConfirmation(persisted: Bool) throws {
    let database = try GatewayDatabase(inMemory: ())
    let original = ProfileGrant(
      id: .chatGPTOperate, capabilityIDs: ["file.read"], workspaceIDs: ["fixture"],
      allowedCallers: [.secureTunnel], mode: .workspaceOperations)
    if persisted { try database.saveProfile(original) }
    let session = GatewayControlSession(
      principalID: "verified-client", profileID: original.id, caller: .secureTunnel,
      database: database, profile: .init(grant: original, persisted: persisted))
    let reviewed = session.snapshot
    var changed = original
    changed.workspaceIDs.insert("another-project")
    if persisted {
      try database.saveProfile(changed, expectedRevision: original.authorizationRevision)
    } else {
      session.updateProfile(.init(grant: changed, persisted: false))
    }
    #expect(throws: (any Error).self) {
      try session.approveFullAccess(expectedRevision: reviewed.revision)
    }
    #expect(session.snapshot.revision > reviewed.revision)
    #expect(session.snapshot.profile?.grant.workspaceIDs == changed.workspaceIDs)
    #expect(session.snapshot.fullAccessConsent == nil)
    #expect(try database.clientTrusts().isEmpty)
    #expect(try database.auditEvents().isEmpty)
    _ = try session.approveFullAccess(expectedRevision: session.snapshot.revision)
    #expect(session.snapshot.fullAccessConsent?.lifetime == .thisSession)
  }

  @Test
  func configuredProfilePublicationRevokesConsentForRetainedContexts() throws {
    let database = try GatewayDatabase(inMemory: ())
    let original = ProfileGrant(
      id: .chatGPTOperate, capabilityIDs: ["file.read"], workspaceIDs: ["fixture"],
      allowedCallers: [.secureTunnel], mode: .workspaceOperations)
    let session = GatewayControlSession(
      principalID: "verified-client", profileID: original.id, caller: .secureTunnel,
      database: database,
      profile: .init(grant: original, persisted: false, configuredGrant: original))
    let approved = try session.approveFullAccess(lifetime: .alwaysAllowClient, expectedRevision: 0)
    let context = ExecutionContext(
      caller: .secureTunnel, profileID: original.id, trustedPrincipalID: "verified-client")
    let effective = try session.apply(to: original, context: context)
    #expect(effective.mode == .localFullAccess)
    #expect(effective.id == original.id)
    #expect(effective.allowedCallers == original.allowedCallers)
    var expanded = original
    expanded.capabilityIDs.insert("new-integration.read")
    expanded.workspaceIDs.insert("new-workspace")
    session.updateProfile(.init(grant: expanded, persisted: false, configuredGrant: original))
    #expect(session.snapshot.fullAccessConsent != nil)
    try session.requireRevision(approved.revision)
    var changed = original
    changed.mode = .readOnly
    session.updateProfile(.init(grant: changed, persisted: false))
    #expect(throws: (any Error).self) { try session.requireRevision(approved.revision) }
    // An old execution generation cannot reinstate the profile captured at its creation.
    #expect(try session.apply(to: original, context: context).mode == .readOnly)
    #expect(session.snapshot.fullAccessConsent == nil)
    let next = GatewayControlSession(
      principalID: "verified-client", profileID: original.id, caller: .secureTunnel,
      database: database, profile: .init(grant: changed, persisted: false))
    try next.restoreTrustedAccess()
    #expect(next.snapshot.fullAccessConsent == nil)
    #expect(try database.profiles().isEmpty)
  }

  @Test
  func localConsentAllowsRealExecutionForOnlyTheSelectedSession() async throws {
    let fixture = try ConsentFixture()
    defer { fixture.remove() }
    let first = fixture.session()
    let sibling = fixture.session()
    do {
      await #expect(throws: (any Error).self) { try await fixture.run(first) }
      #expect(!FileManager.default.fileExists(atPath: fixture.output.path))
      #expect(throws: (any Error).self) {
        try first.limitAccess(to: .localFullAccess, expectedRevision: 0)
      }
      let approved = try first.approveFullAccess(expectedRevision: 0)
      #expect(approved.fullAccessConsent?.lifetime == .thisSession)
      #expect(try fixture.database.clientTrusts().isEmpty)
      try await fixture.run(first)
      try await fixture.run(first)
      #expect(try String(contentsOf: fixture.output, encoding: .utf8) == "approvedapproved")
      #expect(try fixture.database.operationApprovals().isEmpty)
      await #expect(throws: (any Error).self) { try await fixture.run(sibling) }
      #expect(try fixture.database.profiles().first?.mode == .workspaceOperations)
      try first.limitAccess(to: .workspaceOperations, expectedRevision: approved.revision)
      await #expect(throws: (any Error).self) { try await fixture.run(first) }
      try first.restoreTrustedAccess()
      #expect(first.snapshot.fullAccessConsent == nil)
      first.end()
      let reconnected = fixture.session()
      try reconnected.restoreTrustedAccess()
      await #expect(throws: (any Error).self) { try await fixture.run(reconnected) }
      await fixture.gateway.shutdown()
    } catch {
      await fixture.gateway.shutdown()
      throw error
    }
  }

  @Test
  func persistentTrustMatchesVerifiedIdentityAndRevocationReachesExistingSessions() throws {
    let fixture = try ConsentFixture()
    defer { fixture.remove() }
    let first = fixture.session()
    let approved = try first.approveFullAccess(lifetime: .alwaysAllowClient, expectedRevision: 0)
    first.end()
    let reopened = try GatewayDatabase(path: fixture.databasePath.path)
    let trust = try #require(reopened.clientTrusts().first)
    #expect(trust.fullAccessAllowed)
    #expect(trust.revision == approved.fullAccessConsent?.trustRevision)
    let next = fixture.session(database: reopened)
    try next.restoreTrustedAccess()
    #expect(next.snapshot.fullAccessConsent?.lifetime == .alwaysAllowClient)
    let stranger = fixture.session(principal: "different-verified-client", database: reopened)
    try stranger.restoreTrustedAccess()
    #expect(stranger.snapshot.fullAccessConsent == nil)
    let otherTransport = GatewayControlSession(
      principalID: "verified-client", profileID: .chatGPTOperate, caller: .cloudflareTunnel,
      database: reopened)
    try otherTransport.restoreTrustedAccess()
    #expect(otherTransport.snapshot.fullAccessConsent == nil)
    #expect(throws: (any Error).self) {
      try reopened.revokeClientTrust(id: trust.id, expectedRevision: trust.revision + 1)
    }
    #expect(next.snapshot.fullAccessConsent != nil)
    try reopened.revokeClientTrust(id: trust.id, expectedRevision: trust.revision)
    #expect(next.snapshot.fullAccessConsent == nil)
    #expect(next.snapshot.accessLimit == .workspaceOperations)
    let afterRevocation = fixture.session(database: reopened)
    try afterRevocation.restoreTrustedAccess()
    #expect(afterRevocation.snapshot.fullAccessConsent == nil)
    #expect(
      try reopened.auditEvents().contains { $0.capabilityID == "control.client-trust.revoke" })
  }

  @Test(arguments: [GatewayFullAccessLifetime.thisSession, .alwaysAllowClient])
  func profileRevisionChangesInvalidateBothConsentLifetimes(lifetime: GatewayFullAccessLifetime)
    throws
  {
    let fixture = try ConsentFixture()
    defer { fixture.remove() }
    let session = fixture.session()
    let approved = try session.approveFullAccess(lifetime: lifetime, expectedRevision: 0)
    var grant = try #require(fixture.database.profiles().first)
    grant.mode = .readOnly
    try fixture.database.saveProfile(grant, expectedRevision: grant.authorizationRevision)
    #expect(throws: (any Error).self) { try session.requireRevision(approved.revision) }
    #expect(throws: (any Error).self) {
      try session.approveFullAccess(
        expectedRevision: approved.revision,
        expectedTrustRevision: approved.fullAccessConsent?.trustRevision ?? 0)
    }
    #expect(session.snapshot.fullAccessConsent == nil)
    #expect(session.snapshot.accessLimit == .readOnly)
    let next = fixture.session()
    try next.restoreTrustedAccess()
    #expect(next.snapshot.fullAccessConsent == nil)
  }

  @Test(arguments: ["clientControlTrust", "auditEvents"])
  func failedTrustPersistenceDoesNotGrantOrAuditAccess(table: String) throws {
    let fixture = try ConsentFixture()
    defer { fixture.remove() }
    let connection = try DatabaseQueue(path: fixture.databasePath.path)
    try connection.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER reject_trust BEFORE INSERT ON \(table)
          BEGIN SELECT RAISE(ABORT, 'fixture rejects trust'); END
          """)
    }
    let session = fixture.session()
    #expect(throws: (any Error).self) {
      try session.approveFullAccess(lifetime: .alwaysAllowClient, expectedRevision: 0)
    }
    #expect(session.snapshot.fullAccessConsent == nil)
    #expect(session.snapshot.revision == 0)
    #expect(try fixture.database.clientTrusts().isEmpty)
    #expect(try fixture.database.auditEvents().isEmpty)
    try connection.close()
  }

  @Test
  func changingToThisSessionRevokesPersistentTrustAndRejectsStaleChoices() async throws {
    let fixture = try ConsentFixture()
    defer { fixture.remove() }
    let first = fixture.session()
    _ = try first.approveFullAccess(lifetime: .alwaysAllowClient, expectedRevision: 0)
    let trust = try #require(fixture.database.clientTrusts().first)
    let sibling = fixture.session()
    try sibling.restoreTrustedAccess()
    let siblingBefore = sibling.snapshot
    let another = fixture.session()
    #expect(throws: (any Error).self) {
      try another.approveFullAccess(expectedRevision: 0)
    }
    #expect(another.snapshot.fullAccessConsent == nil)
    let selected = try another.approveFullAccess(
      expectedRevision: 0, expectedTrustRevision: trust.revision)
    #expect(selected.fullAccessConsent?.lifetime == .thisSession)
    #expect(try fixture.database.clientTrusts().first?.fullAccessAllowed == false)
    #expect(throws: (any Error).self) { try sibling.requireRevision(siblingBefore.revision) }
    #expect(first.snapshot.fullAccessConsent == nil)
    #expect(sibling.snapshot.fullAccessConsent == nil)
    do {
      try await fixture.run(another)
      await #expect(throws: (any Error).self) { try await fixture.run(sibling) }
      let next = fixture.session()
      try next.restoreTrustedAccess()
      #expect(next.snapshot.fullAccessConsent == nil)
      await fixture.gateway.shutdown()
    } catch {
      await fixture.gateway.shutdown()
      throw error
    }
  }

  @Test(arguments: [false, true])
  func clientTrustChangesPublishOnlyCommittedRevisions(staleRevision: Bool) async throws {
    let stream = try { () -> AsyncStream<Void> in
      let database = try GatewayDatabase(inMemory: ())
      try database.saveProfile(.operate)
      let session = GatewayControlSession(
        principalID: "verified-client", profileID: .chatGPTOperate, caller: .secureTunnel,
        database: database)
      _ = try session.approveFullAccess(lifetime: .alwaysAllowClient, expectedRevision: 0)
      let trust = try #require(database.clientTrusts().first)
      let stream = database.profileChanges(for: .chatGPTOperate)
      if staleRevision {
        // A stale record revision must not publish a change or alter active consent.
        #expect(throws: (any Error).self) {
          try database.revokeClientTrust(id: trust.id, expectedRevision: trust.revision + 1)
        }
        #expect(session.snapshot.fullAccessConsent != nil)
      } else {
        _ = try session.approveFullAccess(
          expectedRevision: session.snapshot.revision, expectedTrustRevision: trust.revision)
      }
      return stream
    }()
    // Releasing the database finishes the stream, including the no-event case.
    var changes = 0
    for await _ in stream { changes += 1 }
    #expect(changes == (staleRevision ? 0 : 1))
  }

  @Test
  func sessionConsentPreservesTheDisabledShellFacilityGuard() async throws {
    let fixture = try ConsentFixture(shellEnabled: false)
    defer { fixture.remove() }
    let session = fixture.session()
    _ = try session.approveFullAccess(expectedRevision: 0)
    await #expect(throws: (any Error).self) { try await fixture.run(session) }
    #expect(!FileManager.default.fileExists(atPath: fixture.output.path))
    await fixture.gateway.shutdown()
  }
}

private struct ConsentFixture {
  let root: URL
  let databasePath: URL
  let database: GatewayDatabase
  let gateway: GatewayRuntime
  var output: URL { root.appendingPathComponent("outside-workspace.txt") }

  init(shellEnabled: Bool = true) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let workspace = root.appendingPathComponent("workspace")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    databasePath = root.appendingPathComponent("host.sqlite")
    database = try GatewayDatabase(path: databasePath.path)
    let profile = ProfileGrantConfig(
      id: .chatGPTOperate, capabilities: ["file.read", "operations.prepare", "operations.commit"],
      workspaces: ["fixture"], allowedCallers: [.secureTunnel], mode: .workspaceOperations,
      confirmationPolicy: .allWrites)
    try database.saveProfile(profile.grant)
    gateway = try GatewayRuntime(
      configuration: .init(
        runtime: .init(caller: .secureTunnel, profileID: .chatGPTOperate),
        policy: .init(shellEnabled: shellEnabled), profiles: [profile],
        workspaceDirectory: workspace),
      context: .init(
        caller: .secureTunnel, profileID: .chatGPTOperate, trustedPrincipalID: "verified-client"),
      database: database,
      registeredWorkspaces: [
        .init(id: "fixture", displayName: "Fixture", rootPath: workspace.path)
      ],
      requiresControlSession: true)
  }

  func session(principal: String = "verified-client", database: GatewayDatabase? = nil)
    -> GatewayControlSession
  {
    GatewayControlSession(
      principalID: principal, profileID: .chatGPTOperate, caller: .secureTunnel,
      database: database ?? self.database)
  }

  func run(_ session: GatewayControlSession) async throws {
    var context = ExecutionContext(
      caller: .secureTunnel, profileID: .chatGPTOperate, workspaceID: "fixture",
      trustedPrincipalID: "verified-client")
    context.controlSession = session
    let result = try await gateway.callToolAsync(
      name: "shell.run",
      arguments: .object([
        "mode": .string("argv"), "executable": .string("/bin/sh"),
        "argv": .array([
          .string("-c"), .string("printf approved >> \"$1\""), .string("fixture"),
          .string(output.path),
        ]),
        "cwd": .string(root.path),
      ]), context: context)
    #expect(result.objectValue?["isError"] != .bool(true))
    #expect(
      result.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue?["exit_code"]
        == .integer(0))
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}
