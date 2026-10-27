import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPPlatform
import ComputerMCPTestSupport
import Foundation
import GRDB
import Testing

@testable import ComputerMCPGateway

@Suite struct GatewayPermissionConnectionTests {
  @Test(arguments: [GatewayFullAccessLifetime.thisSession, .alwaysAllowClient], [false, true])
  func fullAccessLifetimeControlsDisconnectedExecutionAndReconnectedOutput(
    lifetime: GatewayFullAccessLifetime, completed: Bool
  ) throws {
    let f = try FullAccessConnectionFixture()
    let first = f.session()
    _ = try first.approveFullAccess(lifetime: lifetime, expectedRevision: 0)
    let execution = try f.start(first)
    let identity = try f.store.readWithDatabase { _, ledger in
      ledger.environment.modes[f.subject.principal]?.identity
    }
    if completed {
      try f.store.transactionWithDatabase { _, ledger in
        try ledger.finishExecution(
          execution.id, retainUntil: f.now.addingTimeInterval(60), now: f.now)
      }
    }
    first.end()
    let next = f.session()
    try next.restoreTrustedAccess()
    _ = try next.apply(to: f.profile, context: f.context)
    if lifetime == .thisSession { #expect(next.snapshot.fullAccessConsent == nil) }
    try f.store.transactionWithDatabase { _, ledger in
      let expected: PermissionDecision =
        lifetime == .alwaysAllowClient ? .allowed : .denied(.authorizationRevoked)
      #expect(
        ledger.executionAccess(
          execution.id, principal: f.subject.principal, operation: .readResult,
          connectionID: next.id, now: f.now) == expected)
      if lifetime == .alwaysAllowClient {
        #expect(ledger.environment.modes[f.subject.principal]?.identity == identity)
        #expect(ledger.environment.connections[next.id]?.consent == nil)
        if !completed {
          #expect(
            ledger.executionAccess(
              execution.id, principal: f.subject.principal,
              operation: .writeInput, connectionID: next.id, now: f.now) == .allowed)
        }
      } else {
        #expect(ledger.environment.modes[f.subject.principal] == nil)
      }
    }
    #expect(try f.database.profiles() == [f.profile])
  }

  @Test(arguments: ["trust-revoke", "trust-revision", "profile"])
  func savedConsentRetiresDisconnectedWorkInTheMetadataTransaction(change: String) throws {
    let f = try FullAccessConnectionFixture()
    let first = f.session()
    _ = try first.approveFullAccess(lifetime: .alwaysAllowClient, expectedRevision: 0)
    let execution = try f.start(first)
    first.end()
    let trust = try #require(f.database.clientTrusts().first)
    switch change {
    case "trust-revoke":
      try f.database.revokeClientTrust(id: trust.id, expectedRevision: trust.revision)
    case "trust-revision":
      _ = try f.database.recordFullAccessConsent(
        sessionID: "local-review", principalID: "client",
        profile: .init(grant: f.profile, persisted: true),
        caller: .secureTunnel, lifetime: .alwaysAllowClient, expectedTrustRevision: trust.revision)
    default:
      var profile = f.profile
      try profile.permissions.set(.granted(.access), for: .unifiedLogs)
      try f.database.saveProfile(profile, expectedRevision: profile.authorizationRevision)
    }
    // No session callback or policy refresh may be needed to retire saved work.
    try f.store.readWithDatabase { _, ledger in
      #expect(ledger.environment.modes[f.subject.principal] == nil)
      #expect(ledger.executions[execution.id]?.revoked == true)
      #expect(ledger.pendingExecutionTerminations.contains(execution.id))
    }
    try f.store.transactionWithDatabase { _, ledger in
      #expect(
        ledger.executionAccess(
          execution.id, principal: f.subject.principal,
          operation: .readResult, now: f.now) == .denied(.authorizationRevoked))
    }
  }

  @Test func policyRefreshDetectsAnExternallyChangedTrustRevision() throws {
    let f = try FullAccessConnectionFixture()
    let first = f.session()
    _ = try first.approveFullAccess(lifetime: .alwaysAllowClient, expectedRevision: 0)
    let execution = try f.start(first)
    first.end()
    try f.database.connection.writer.write {
      try $0.execute(sql: "UPDATE clientControlTrust SET revision = revision + 1")
    }
    _ = try f.service.reconcilePolicy(now: f.now)
    try f.store.readWithDatabase { _, ledger in
      #expect(ledger.environment.modes[f.subject.principal] == nil)
      #expect(ledger.executions[execution.id]?.revoked == true)
    }
  }

  @Test func savedConsentCannotRestoreAnUnconfirmedEpochOrGrantMissingPermissions() throws {
    let f = try FullAccessConnectionFixture()
    let first = f.session()
    _ = try first.approveFullAccess(lifetime: .alwaysAllowClient, expectedRevision: 0)
    let execution = try f.start(first)
    let missing = try InvocationRequirements(
      actions: [.init(requirement: .init(.project("missing"), .read))],
      mode: .fullAccess(.standing))
    guard
      case .requests = try f.service.admit(
        subject: f.subject, tool: "missing", projectID: nil,
        argumentsDigest: "missing", requirements: missing, connectionID: first.id, now: f.now)
    else { throw FullAccessConnectionFailure.unexpected }
    #expect(try f.database.profiles() == [f.profile])
    first.end()
    f.counter.forget()
    try f.store.readWithDatabase { _, ledger in
      #expect(ledger.suspendedAuthority != nil)
      #expect(ledger.environment.modes.isEmpty)
    }
    let next = f.session()
    #expect(throws: GatewayPermissionError.profileUnavailable) { try next.restoreTrustedAccess() }
    try f.store.transactionWithDatabase { _, ledger in
      #expect(
        ledger.executionAccess(
          execution.id, principal: f.subject.principal,
          operation: .readResult, now: f.now) == .denied(.authoritySuspended))
    }
  }

  @Test func standingFullAccessStillRequestsMissingScreenPermission() throws {
    let f = try FullAccessConnectionFixture(screenGranted: false)
    let session = f.session()
    _ = try session.approveFullAccess(lifetime: .alwaysAllowClient, expectedRevision: 0)
    let requirements = try InvocationRequirements(
      actions: [.init(requirement: .init(.screen, .access))],
      mode: .fullAccess(.standing))
    guard
      case .requests(let requests) = try f.service.admit(
        subject: f.subject, tool: "screen",
        projectID: nil, argumentsDigest: "screen", requirements: requirements,
        connectionID: session.id, now: f.now)
    else { throw FullAccessConnectionFailure.unexpected }
    #expect(requests.count == 1)
    guard case .permission(let permission) = try #require(requests.first).content
    else { throw FullAccessConnectionFailure.unexpected }
    #expect(permission.requirement.permission == .screen)
    #expect(try f.database.profiles().first?.permissions.state(for: .screen) == .notGranted)
  }

  @Test(arguments: ["project", "skill-library"])
  func pathChangesRequireFreshStandingReviewWithoutResurrectingOldWork(change: String) throws {
    let f = try FullAccessConnectionFixture()
    let first = f.session()
    let approved = try first.approveFullAccess(lifetime: .alwaysAllowClient, expectedRevision: 0)
    let approvedConsent = try #require(approved.fullAccessConsent)
    let oldExecution = try f.start(first)
    let oldConsent = try #require(
      f.store.readWithDatabase { _, ledger in
        ledger.environment.modes[f.subject.principal]
      })
    let oldTrust = try #require(f.database.clientTrusts().first)
    let binding = try f.bindingValue(oldTrust.id)
    let original = try f.paths()
    if change == "project" {
      try f.addProject()
    } else {
      var paths = original
      let library = f.root.appendingPathComponent("skills")
      try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
      paths.pathRules.insert(
        .init(root: try CanonicalPath(library.path), kind: .skillLibrary))
      try f.configure(paths)
    }
    let retiredTrust = try #require(f.database.clientTrusts().first)
    #expect(!retiredTrust.fullAccessAllowed)
    #expect(retiredTrust.revision > oldTrust.revision)
    #expect(try f.bindingValue(oldTrust.id) == binding)
    try f.store.readWithDatabase { _, ledger in
      #expect(!ledger.isConsentValid(oldConsent, for: f.subject.principal))
      #expect(ledger.environment.modes[f.subject.principal] == nil)
      #expect(ledger.executions[oldExecution.id]?.revoked == true)
      #expect(ledger.pendingExecutionTerminations.contains(oldExecution.id))
    }
    #expect(first.snapshot.fullAccessConsent == nil)
    #expect(try !first.apply(to: f.profile, context: f.context).fullAccess)
    #expect(try f.admit(first) == .denied(.fullAccessRequiresConsent))
    first.end()
    let next = f.session()
    try next.restoreTrustedAccess()
    #expect(next.snapshot.fullAccessConsent == nil)
    #expect(try !next.apply(to: f.profile, context: f.context).fullAccess)
    #expect(try f.admit(next) == .denied(.fullAccessRequiresConsent))
    if change == "project" {
      try f.database.deleteProject(id: "additional")
    } else {
      try f.configure(original)
    }
    try next.restoreTrustedAccess()
    #expect(next.snapshot.fullAccessConsent == nil)
    #expect(try f.admit(next) == .denied(.fullAccessRequiresConsent))
    #expect(throws: GatewayPermissionError.invalidBinding) {
      try f.service.setConnectionConsent(
        subject: f.subject, id: next.id, allowed: true,
        consent: approvedConsent)
    }
    try f.store.readWithDatabase { _, ledger in
      #expect(!ledger.isConsentValid(oldConsent, for: f.subject.principal))
      #expect(ledger.environment.modes[f.subject.principal] == nil)
      #expect(ledger.environment.connections[next.id] != nil)
    }
    let reviewed = try #require(f.database.clientTrusts().first)
    _ = try next.approveFullAccess(
      lifetime: .alwaysAllowClient, expectedRevision: next.revision,
      expectedTrustRevision: reviewed.revision)
    let freshExecution = try f.start(next)
    try f.store.transactionWithDatabase { _, ledger in
      let fresh = try #require(ledger.environment.modes[f.subject.principal])
      #expect(fresh.identity != oldConsent.identity)
      #expect(ledger.isConsentValid(fresh, for: f.subject.principal))
      #expect(!ledger.isConsentValid(oldConsent, for: f.subject.principal))
      #expect(
        ledger.executionAccess(
          oldExecution.id, principal: f.subject.principal, operation: .readResult,
          connectionID: next.id, now: f.now) == .denied(.authorizationRevoked))
      #expect(
        ledger.executionAccess(
          freshExecution.id, principal: f.subject.principal, operation: .readResult,
          connectionID: next.id, now: f.now) == .allowed)
    }
  }

  @Test func savedTrustWithoutAnIssuedBindingRestoresOnlyARestrictedConnection() throws {
    let f = try FullAccessConnectionFixture()
    _ = try f.database.recordFullAccessConsent(
      sessionID: "interrupted-owner-approval", principalID: "client",
      profile: .init(grant: f.profile, persisted: true), caller: .secureTunnel,
      lifetime: .alwaysAllowClient, expectedTrustRevision: 0)
    let saved = try #require(f.database.clientTrusts().first)
    #expect(saved.fullAccessAllowed)
    #expect(try f.bindingValue(saved.id) == nil)
    let session = f.session()
    try session.restoreTrustedAccess()
    #expect(session.snapshot.fullAccessConsent == nil)
    #expect(try !session.apply(to: f.profile, context: f.context).fullAccess)
    #expect(try f.admit(session) == .denied(.fullAccessRequiresConsent))
    try f.store.readWithDatabase { _, ledger in
      #expect(ledger.environment.connections[session.id] != nil)
      #expect(ledger.environment.modes[f.subject.principal] == nil)
    }
    #expect(try f.bindingValue(saved.id) == nil)
    _ = try session.approveFullAccess(
      lifetime: .alwaysAllowClient, expectedRevision: session.revision,
      expectedTrustRevision: saved.revision)
    #expect(try f.database.clientTrusts().first?.revision == saved.revision + 1)
    _ = try f.start(session)
  }

  @Test func restoringAnOldTrustRevisionCannotResignRetiredConsent() throws {
    let f = try FullAccessConnectionFixture()
    let first = f.session()
    let approved = try first.approveFullAccess(lifetime: .alwaysAllowClient, expectedRevision: 0)
    let approvedConsent = try #require(approved.fullAccessConsent)
    let execution = try f.start(first)
    let original = try f.paths()
    let trust = try #require(f.database.clientTrusts().first)
    let binding = try f.bindingValue(trust.id)
    let oldConsent = try #require(
      f.store.readWithDatabase { _, ledger in
        ledger.environment.modes[f.subject.principal]
      })
    try f.addProject()
    try f.database.deleteProject(id: "additional")
    #expect(try f.paths().registeredProjects == original.registeredProjects)
    try f.database.connection.writer.write {
      try $0.execute(
        sql: "UPDATE clientControlTrust SET fullAccessAllowed = 1, revision = ? WHERE id = ?",
        arguments: [trust.revision, trust.id])
    }
    #expect(throws: GatewayPermissionError.invalidBinding) {
      try f.service.setConnectionConsent(
        subject: f.subject, id: first.id, allowed: true,
        consent: approvedConsent)
    }
    #expect(try f.bindingValue(trust.id) == binding)
    first.end()
    let next = f.session()
    try next.restoreTrustedAccess()
    #expect(next.snapshot.fullAccessConsent == nil)
    #expect(try !next.apply(to: f.profile, context: f.context).fullAccess)
    #expect(try f.admit(next) == .denied(.fullAccessRequiresConsent))
    #expect(try f.database.clientTrusts().first?.fullAccessAllowed == false)
    try f.store.transactionWithDatabase { _, ledger in
      #expect(!ledger.isConsentValid(oldConsent, for: f.subject.principal))
      #expect(ledger.environment.modes[f.subject.principal] == nil)
      #expect(
        ledger.executionAccess(
          execution.id, principal: f.subject.principal, operation: .readResult,
          connectionID: next.id, now: f.now) == .denied(.authorizationRevoked))
    }
  }

  @Test func retiringSavedTrustRollsBackProjectAuthorityWhenItsWriteFails() throws {
    let f = try FullAccessConnectionFixture()
    let session = f.session()
    _ = try session.approveFullAccess(lifetime: .alwaysAllowClient, expectedRevision: 0)
    let execution = try f.start(session)
    let before = try f.store.readWithDatabase { _, ledger in ledger }
    let trust = try #require(f.database.clientTrusts().first)
    try f.database.connection.writer.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER reject_saved_trust_retirement BEFORE UPDATE ON clientControlTrust
          WHEN OLD.fullAccessAllowed = 1 AND NEW.fullAccessAllowed = 0
          BEGIN SELECT RAISE(ABORT, 'fixture rejects saved trust retirement'); END
          """)
    }
    #expect(throws: (any Error).self) { try f.addProject() }
    #expect(try !f.database.projects().contains { $0.id == "additional" })
    #expect(try f.database.clientTrusts().first == trust)
    try f.store.readWithDatabase { _, ledger in
      #expect(ledger.environment == before.environment)
      #expect(ledger.revision == before.revision)
      #expect(ledger.executions[execution.id]?.revoked == false)
    }
    #expect(session.snapshot.fullAccessConsent != nil)
    try f.store.transactionWithDatabase { _, ledger in
      #expect(
        ledger.executionAccess(
          execution.id, principal: f.subject.principal, operation: .readResult,
          connectionID: session.id, now: f.now) == .allowed)
    }
    try f.database.connection.writer.write {
      try $0.execute(sql: "DROP TRIGGER reject_saved_trust_retirement")
    }
    try f.addProject()
    #expect(try f.database.projects().contains { $0.id == "additional" })
    #expect(try f.database.clientTrusts().first?.fullAccessAllowed == false)
    #expect(session.snapshot.fullAccessConsent == nil)
    try f.store.readWithDatabase { _, ledger in
      #expect(ledger.executions[execution.id]?.revoked == true)
      #expect(ledger.pendingExecutionTerminations.contains(execution.id))
    }
  }

  @Test(arguments: ["project", "plugin", "mcp"])
  func concreteCeilingCannotWidenWildcard(domain: String) throws {
    let wildcard: Permission
    let concrete: Permission
    let lower: PermissionState
    let higher: PermissionState
    switch domain {
    case "project":
      wildcard = .project("*")
      concrete = .project("secret")
      lower = .granted(.read)
      higher = .granted(.write)
    case "plugin":
      wildcard = .plugin("*")
      concrete = .plugin("secret")
      lower = .denied
      higher = .granted(.use)
    default:
      wildcard = .mcpServer("*")
      concrete = .mcpServer("secret")
      lower = .granted(.read)
      higher = .granted(.all)
    }
    var ceilings = Permissions()
    try ceilings.set(lower, for: wildcard)
    let previous = ManagedPolicy(permissionCeilings: ceilings)
    try ceilings.set(higher, for: concrete)
    #expect(!ManagedPolicy(permissionCeilings: ceilings).narrows(previous))
    try ceilings.set(.denied, for: concrete)
    let narrowed = ManagedPolicy(permissionCeilings: ceilings)
    #expect(narrowed.narrows(previous))
    ceilings.removeEntry(for: concrete)
    #expect(ManagedPolicy(permissionCeilings: ceilings).narrows(narrowed) == (domain == "plugin"))
  }

  @Test func droppingWildcardResidualOrCeilingCannotRestoreAuthority() throws {
    var ceilings = Permissions()
    try ceilings.set(.granted(.read), for: .project("*"))
    let previous = try ManagedPolicy(
      permissionCeilings: ceilings, allowsFullAccess: false,
      executionLimits: .init(timeMilliseconds: 1000))
    ceilings.removeEntry(for: .project("*"))
    try ceilings.set(.granted(.read), for: .project("known"))
    #expect(
      try !ManagedPolicy(
        permissionCeilings: ceilings, allowsFullAccess: false,
        executionLimits: .init(timeMilliseconds: 1000)
      ).narrows(previous))
    #expect(!ManagedPolicy().narrows(previous))
  }
}

private enum FullAccessConnectionFailure: Error {
  case unexpected
  case admission(AuthorizationDecision)
}

private final class FullAccessConnectionFixture {
  let root: URL
  let database: GatewayDatabase
  let store: SQLitePermissionStore
  let service: GatewayPermissionService
  let counter = TestAuthorizationEpochCounter()
  let subject: GatewayPermissionSubject
  let profile: ProfileGrant
  let now = Date()
  var context: ExecutionContext {
    .init(caller: .secureTunnel, profileID: profile.id, trustedPrincipalID: "client")
  }
  init(screenGranted: Bool = true) throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
      "cm-full-access-\(UUID())")
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    root = try ProjectPathResolver.canonicalProject(temporary)
    database = try GatewayDatabase(inMemory: ())
    store = database.permissionStore(counter: counter)
    service = GatewayPermissionService(store: store, policyReader: TestManagedPolicyReader())
    var profile = ProfileGrant(
      id: .chatGPTOperate, fullAccess: true, allowedCallers: [.secureTunnel])
    profile.projectNetworks["*"] = .trusted
    if screenGranted { try profile.permissions.set(.granted(.access), for: .screen) }
    try profile.permissions.set(.granted(.read), for: .project("fixture"))
    try database.saveProfile(profile)
    self.profile = try #require(database.profiles().first)
    try database.saveProject(.init(id: "fixture", displayName: "Fixture", rootPath: root.path))
    subject = try GatewayPermissionSubject(
      context: .init(
        caller: .secureTunnel, profileID: profile.id, trustedPrincipalID: "client"))
    try store.transactionWithDatabase { _, ledger in
      var environment = ledger.environment
      environment.paths = try PathEnvironmentSnapshot(projects: [
        .init(id: "fixture", root: CanonicalPath(root.path))
      ])
      _ = try ledger.reconcile(environment: environment, expectedRevision: ledger.revision)
    }
  }
  deinit { try? FileManager.default.removeItem(at: root) }
  func session() -> GatewayControlSession {
    .init(
      principalID: "client", profileID: profile.id, caller: .secureTunnel,
      database: database, permissionService: service)
  }
  func paths() throws -> PathEnvironmentSnapshot {
    try #require(store.readWithDatabase { _, ledger in ledger.environment.paths })
  }
  func bindingValue(_ trustID: String) throws -> String? {
    try database.connection.writer.read {
      try String.fetchOne(
        $0, sql: "SELECT value FROM runtimeSettings WHERE key = ?",
        arguments: ["permission.full-access." + trustID])
    }
  }
  func configure(_ paths: PathEnvironmentSnapshot) throws {
    try service.configureEnvironment(
      paths, trustedHosts: [], expectedProjects: database.projects(),
      expectedConfigurationRevision: nil)
  }
  func addProject() throws {
    let additional = root.appendingPathComponent("additional")
    try FileManager.default.createDirectory(at: additional, withIntermediateDirectories: true)
    try database.saveProject(
      .init(id: "additional", displayName: "Additional", rootPath: additional.path))
  }
  func admit(_ session: GatewayControlSession) throws -> AuthorizationDecision {
    let requirements = try InvocationRequirements(
      actions: [
        .init(requirement: .init(.screen, .access)),
        .init(requirement: .init(.project("fixture"), .read)),
      ], mode: .fullAccess(.standing), sandboxProjectID: "fixture", execution: .background)
    return try service.admit(
      subject: subject, tool: "fixture",
      projectID: nil, argumentsDigest: UUID().uuidString, requirements: requirements,
      connectionID: session.id, now: now)
  }
  func start(_ session: GatewayControlSession) throws -> AuthorizedExecution {
    let decision = try admit(session)
    guard case .allowed(let authorization) = decision else {
      throw FullAccessConnectionFailure.admission(decision)
    }
    return try store.transactionWithDatabase { _, ledger in
      try ledger.startExecution(
        owner: subject.principal, authorizationIDs: [authorization.id], now: now)
    }
  }
}
