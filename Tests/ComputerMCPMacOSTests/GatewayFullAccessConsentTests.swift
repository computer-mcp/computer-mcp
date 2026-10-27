import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPPlatform
import ComputerMCPTestSupport
import Foundation
import GRDB
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPProcess

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

struct GatewayFullAccessConsentTests {
  @Test(arguments: [GatewayFullAccessLifetime.thisSession, .alwaysAllowClient])
  func executionJournalUsesInvocationConsent(lifetime: GatewayFullAccessLifetime) async throws {
    let store = GatewayTerminalSessions()
    let journal = try ScopedTemporaryDirectory()
    let fixture = try ConsentFixture(terminalSessions: store)
    try store.enablePersistence(at: journal.url, launcher: fixture.launcher)
    defer { fixture.remove() }
    let session = try fixture.session()
    let approved = try session.approveFullAccess(lifetime: lifetime, expectedRevision: 0)
    do {
      let result = try await fixture.gateway.callToolAsync(
        name: "shell.run",
        arguments: fixture.arguments("journal"), context: .init(session: session))
      #expect(result.objectValue?["isError"] != .bool(true))
      await fixture.gateway.shutdown()
      let files = try FileManager.default.contentsOfDirectory(
        at: journal.url, includingPropertiesForKeys: nil
      )
      .filter { $0.pathExtension == "json" }
      let file = try #require(files.first)
      let record = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
      if lifetime == .thisSession {
        #expect(record["recoveryKey"] == nil)
      } else {
        let consent = try #require(approved.fullAccessConsent)
        #expect(
          record["recoveryKey"] as? String == "trust:" + (try #require(consent.trustID)) + ":"
            + String(try #require(consent.trustRevision)))
      }
    } catch {
      await fixture.gateway.shutdown()
      throw error
    }
    try store.discardResults()
  }

  @Test func pathChangesClearTheSessionProjectionUntilFreshOwnerApproval() async throws {
    let fixture = try ConsentFixture()
    defer { fixture.remove() }
    do {
      let first = try fixture.session()
      _ = try first.approveFullAccess(lifetime: .alwaysAllowClient, expectedRevision: 0)
      try await fixture.run(first)
      let store = fixture.permissionService.store
      let original = try #require(store.readWithDatabase { _, ledger in ledger.environment.paths })
      let oldConsent = try #require(
        store.readWithDatabase { _, ledger in
          ledger.environment.modes.values.first
        })
      let library = fixture.root.appendingPathComponent("skills")
      try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
      var paths = original
      paths.pathRules.insert(
        .init(
          root: try CanonicalPath(ProjectPathResolver.canonicalProject(library).path),
          kind: .skillLibrary))
      try fixture.permissionService.configureEnvironment(
        paths, trustedHosts: [], expectedProjects: fixture.database.projects(),
        expectedConfigurationRevision: nil)
      #expect(first.snapshot.fullAccessConsent == nil)
      await #expect(throws: (any Error).self) { try await fixture.run(first) }
      #expect(try String(contentsOf: fixture.output, encoding: .utf8) == "approved")
      first.end()
      let next = try fixture.session()
      try next.restoreTrustedAccess()
      #expect(next.snapshot.fullAccessConsent == nil)
      await #expect(throws: (any Error).self) { try await fixture.run(next) }
      let trust = try #require(fixture.database.clientTrusts().first)
      #expect(!trust.fullAccessAllowed)
      _ = try next.approveFullAccess(
        lifetime: .alwaysAllowClient, expectedRevision: next.revision,
        expectedTrustRevision: trust.revision)
      try await fixture.run(next)
      #expect(try String(contentsOf: fixture.output, encoding: .utf8) == "approvedapproved")
      try store.readWithDatabase { _, ledger in
        let principal = try #require(ledger.environment.connections[next.id]).principal
        #expect(!ledger.isConsentValid(oldConsent, for: principal))
        #expect(ledger.environment.modes[principal]?.identity != oldConsent.identity)
      }
      await fixture.gateway.shutdown()
    } catch {
      await fixture.gateway.shutdown()
      throw error
    }
  }

  @Test func changedRestrictedProfileRejectsAnOpenFullAccessConfirmation() throws {
    let database = try GatewayDatabase(inMemory: ())
    let original = ProfileGrant(
      id: .chatGPTOperate, permissions: fixturePermissions([.project("fixture"): .granted(.read)]),
      fullAccess: true, allowedCallers: [.secureTunnel])
    try database.saveProfile(original)
    let service = try GatewayPermissionService(
      store: database.configuredPermissionStore(), policyReader: TestManagedPolicyReader())
    let session = GatewayControlSession(
      principalID: "verified-client", profileID: original.id, caller: .secureTunnel,
      database: database, permissionService: service)
    let reviewed = session.snapshot
    var changed = original
    try changed.permissions.set(.granted(.read), for: .project("another-project"))
    try database.saveProfile(changed, expectedRevision: original.authorizationRevision)
    #expect(throws: (any Error).self) {
      try session.approveFullAccess(expectedRevision: reviewed.revision)
    }
    #expect(session.snapshot.revision > reviewed.revision)
    #expect(session.snapshot.profile?.grant.permissions == changed.permissions)
    #expect(session.snapshot.fullAccessConsent == nil)
    #expect(try database.clientTrusts().isEmpty)
    #expect(try database.auditEvents().isEmpty)
    _ = try session.approveFullAccess(expectedRevision: session.snapshot.revision)
    #expect(session.snapshot.fullAccessConsent?.lifetime == .thisSession)
  }

  @Test
  func profilePublicationRevokesConsentForRetainedContexts() throws {
    let database = try GatewayDatabase(inMemory: ())
    let original = ProfileGrant(
      id: .chatGPTOperate, permissions: fixturePermissions([.project("fixture"): .granted(.read)]),
      fullAccess: true, allowedCallers: [.secureTunnel])
    try database.saveProfile(original)
    let service = try GatewayPermissionService(
      store: database.configuredPermissionStore(), policyReader: TestManagedPolicyReader())
    let session = GatewayControlSession(
      principalID: "verified-client", profileID: original.id, caller: .secureTunnel,
      database: database, permissionService: service)
    let approved = try session.approveFullAccess(lifetime: .alwaysAllowClient, expectedRevision: 0)
    let context = ExecutionContext(
      caller: .secureTunnel, profileID: original.id, trustedPrincipalID: "verified-client")
    let effective = try session.apply(to: original, context: context)
    #expect(effective.fullAccess)
    #expect(effective.id == original.id)
    #expect(effective.allowedCallers == original.allowedCallers)
    var expanded = original
    try expanded.permissions.set(.granted(.use), for: .plugin("new-integration"))
    try expanded.permissions.set(.granted(.read), for: .project("new-project"))
    try database.saveProfile(expanded, expectedRevision: original.authorizationRevision)
    #expect(session.snapshot.fullAccessConsent == nil)
    #expect(throws: (any Error).self) { try session.requireRevision(approved.revision) }
    var changed = try #require(database.profiles().first { $0.id == .chatGPTOperate })
    changed.fullAccess = false
    try database.saveProfile(changed, expectedRevision: changed.authorizationRevision)
    #expect(throws: (any Error).self) { try session.requireRevision(approved.revision) }
    // An old execution generation cannot reinstate the profile captured at its creation.
    #expect(try session.apply(to: original, context: context).fullAccess == false)
    #expect(session.snapshot.fullAccessConsent == nil)
    let next = GatewayControlSession(
      principalID: "verified-client", profileID: original.id, caller: .secureTunnel,
      database: database, permissionService: service)
    try next.restoreTrustedAccess()
    #expect(next.snapshot.fullAccessConsent == nil)
    #expect(try database.profiles().first { $0.id == .chatGPTOperate }?.fullAccess == false)
  }

  @Test
  func localConsentAllowsRealExecutionForOnlyTheSelectedSession() async throws {
    let fixture = try ConsentFixture()
    defer { fixture.remove() }
    let first = try fixture.session()
    let sibling = try fixture.session()
    do {
      await #expect(throws: (any Error).self) { try await fixture.run(first) }
      #expect(!FileManager.default.fileExists(atPath: fixture.output.path))
      let approved = try first.approveFullAccess(expectedRevision: 0)
      #expect(approved.fullAccessConsent?.lifetime == .thisSession)
      #expect(try fixture.database.clientTrusts().isEmpty)
      try await fixture.run(first)
      try await fixture.run(first)
      #expect(try String(contentsOf: fixture.output, encoding: .utf8) == "approvedapproved")
      await #expect(throws: (any Error).self) { try await fixture.run(sibling) }
      #expect(
        try fixture.database.profiles().first { $0.id == .chatGPTOperate }?.fullAccess == true)
      try first.limitAccess(to: .init(allowsFullAccess: false), expectedRevision: approved.revision)
      await #expect(throws: (any Error).self) { try await fixture.run(first) }
      try first.restoreTrustedAccess()
      #expect(first.snapshot.fullAccessConsent == nil)
      first.end()
      let reconnected = try fixture.session()
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
    let first = try fixture.session()
    let approved = try first.approveFullAccess(lifetime: .alwaysAllowClient, expectedRevision: 0)
    first.end()
    let reopened = try fixturePermissionDatabase(path: fixture.databasePath.path)
    let trust = try #require(reopened.clientTrusts().first)
    #expect(trust.fullAccessAllowed)
    #expect(trust.revision == approved.fullAccessConsent?.trustRevision)
    let next = try fixture.session(database: reopened)
    try next.restoreTrustedAccess()
    #expect(next.snapshot.fullAccessConsent?.lifetime == .alwaysAllowClient)
    let stranger = try fixture.session(principal: "different-verified-client", database: reopened)
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
    let afterRevocation = try fixture.session(database: reopened)
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
    let session = try fixture.session()
    let approved = try session.approveFullAccess(lifetime: lifetime, expectedRevision: 0)
    var grant = try #require(fixture.database.profiles().first { $0.id == .chatGPTOperate })
    grant.fullAccess = false
    try fixture.database.saveProfile(grant, expectedRevision: grant.authorizationRevision)
    #expect(throws: (any Error).self) { try session.requireRevision(approved.revision) }
    #expect(throws: (any Error).self) {
      try session.approveFullAccess(
        expectedRevision: approved.revision,
        expectedTrustRevision: approved.fullAccessConsent?.trustRevision ?? 0)
    }
    #expect(session.snapshot.fullAccessConsent == nil)
    #expect(session.snapshot.profile?.grant.fullAccess == false)
    let next = try fixture.session()
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
    let session = try fixture.session()
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
    let first = try fixture.session()
    _ = try first.approveFullAccess(lifetime: .alwaysAllowClient, expectedRevision: 0)
    let trust = try #require(fixture.database.clientTrusts().first)
    let sibling = try fixture.session()
    try sibling.restoreTrustedAccess()
    let siblingBefore = sibling.snapshot
    let another = try fixture.session()
    let beforeStaleChoice = another.snapshot.fullAccessConsent
    #expect(beforeStaleChoice?.lifetime == .alwaysAllowClient)
    #expect(throws: (any Error).self) {
      try another.approveFullAccess(expectedRevision: 0)
    }
    #expect(another.snapshot.fullAccessConsent == beforeStaleChoice)
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
      let next = try fixture.session()
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
      var profile = ProfileGrant.operate
      profile.fullAccess = true
      try database.saveProfile(profile)
      let service = try GatewayPermissionService(
        store: database.configuredPermissionStore(), policyReader: TestManagedPolicyReader())
      let session = GatewayControlSession(
        principalID: "verified-client", profileID: .chatGPTOperate, caller: .secureTunnel,
        database: database, permissionService: service)
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
    let session = try fixture.session()
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
  let permissionService: GatewayPermissionService
  let launcher: ExecutionLauncher
  var output: URL { root.appendingPathComponent("outside-project.txt") }

  private static let program = """
    import pathlib, sys
    if sys.argv[1:] == ["journal"]:
        print("retained")
    elif len(sys.argv) == 3 and sys.argv[1] == "append":
        with pathlib.Path(sys.argv[2]).open("a") as output:
            output.write("approved")
    else:
        raise SystemExit(64)
    """

  init(
    shellEnabled: Bool = true, terminalSessions: GatewayTerminalSessions = GatewayTerminalSessions()
  ) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let project = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let executable = project.appendingPathComponent("consent-fixture.py")
    try Self.program.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let output = root.appendingPathComponent("outside-project.txt")
    launcher = fixtureProtocolExecutionLauncher(
      root: root, scripts: [Self.program], arguments: [["journal"], ["append", output.path]])
    databasePath = root.appendingPathComponent("host.sqlite")
    database = try fixturePermissionDatabase(path: databasePath.path)
    let profile = ProfileGrantConfig(
      id: .chatGPTOperate, permissions: fixturePermissions([.project("fixture"): .granted(.write)]),
      fullAccess: true, allowedCallers: [.secureTunnel])
    try database.saveProfile(profile.grant)
    let registration = ComputerMCPCore.RegisteredProject(
      id: "fixture", displayName: "Fixture", rootPath: project.path)
    try database.saveProject(registration)
    var platform = MacOSPlatform.services(launcher: launcher)
    platform.permissionPolicyReader = TestManagedPolicyReader()
    gateway = try GatewayRuntime(
      configuration: .init(
        runtime: .init(caller: .secureTunnel, profileID: .chatGPTOperate),
        policy: .init(shellEnabled: shellEnabled), profiles: [profile],
        projectDirectory: project),
      context: .init(
        caller: .secureTunnel, profileID: .chatGPTOperate, trustedPrincipalID: "verified-client"),
      database: database,
      registeredProjects: [registration], platform: platform,
      terminalSessions: terminalSessions, requiresControlSession: true)
    permissionService = try database.permissionRuntime(platform: platform).service
  }

  func session(principal: String = "verified-client", database: GatewayDatabase? = nil) throws
    -> GatewayControlSession
  {
    if principal == "verified-client", database == nil { return try gateway.makeControlSession() }
    let selected = database ?? self.database
    let service =
      database.map {
        GatewayPermissionService(
          store: $0.permissionStore(
            counter: TestAuthorizationEpochCounter.shared(forDatabasePath: databasePath.path)),
          policyReader: TestManagedPolicyReader())
      } ?? permissionService
    return GatewayControlSession(
      principalID: principal, profileID: .chatGPTOperate, caller: .secureTunnel,
      database: selected, permissionService: service)
  }

  func arguments(_ operation: String) -> JSONValue {
    let project = root.appendingPathComponent("project")
    return .object([
      "project_id": .string("fixture"), "mode": .string("argv"),
      "executable": .string(project.appendingPathComponent("consent-fixture.py").path),
      "argv": .array(
        (operation == "journal" ? ["journal"] : ["append", output.path]).map(JSONValue.string)),
      "cwd": .string(project.path),
    ])
  }

  func run(_ session: GatewayControlSession) async throws {
    let result = try await gateway.callToolAsync(
      name: "shell.run", arguments: arguments("append"), context: .init(session: session))
    #expect(result.objectValue?["isError"] != .bool(true))
    #expect(
      result.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue?["exit_code"]
        == .integer(0))
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}
