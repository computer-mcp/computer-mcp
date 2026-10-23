import ComputerMCPDownstream
import Foundation
import GRDB
import Testing

@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPersistence

@Suite(.timeLimit(.minutes(1)))
struct MCPDerivedProjectRegistrationTests {
  @Test
  func databaseUpgradePreservesReadablePluginOwnershipAndDigest() throws {
    let fixture = try DerivedFixture()
    defer { fixture.remove() }
    let path = fixture.root.appendingPathComponent("upgrade.sqlite").path
    let earlier = try DatabaseQueue(path: path)
    try GatewayDatabaseConnection.migrator.migrate(earlier, upTo: "audit-error-details")
    let payload = String(decoding: try JSONEncoder().encode(fixture.registration), as: UTF8.self)
    try earlier.write { database in
      try database.execute(
        sql: "INSERT INTO pluginDerivedWorkspaces VALUES (?, ?, ?, ?, ?)",
        arguments: [
          fixture.registration.project.id, fixture.registration.origin,
          fixture.registration.sourceProjectID, fixture.registration.receiptID, payload,
        ])
    }
    try earlier.close()
    let migrated = try GatewayDatabase(path: path)
    let registration = try #require(
      try migrated.derivedProjectRegistration(id: fixture.registration.project.id))
    #expect(registration == fixture.registration)
    #expect(registration.receiptDigest == fixture.registration.receiptDigest)
    let reader = try DatabaseQueue(path: path)
    defer { try? reader.close() }
    #expect(
      try reader.read {
        try String.fetchOne($0, sql: "SELECT payloadJSON FROM pluginDerivedProjects")
      } == payload)
    #expect(
      try GatewayDatabase(path: path).derivedProjectRegistration(id: registration.project.id)
        == registration)
  }

  @Test
  func registrationAndGrantAreAtomicDurableAndIdempotent() throws {
    let fixture = try DerivedFixture()
    defer { fixture.remove() }
    try fixture.register()
    let storedProject = try #require(try fixture.database.project(id: "child"))
    try fixture.register()
    let reopened = try GatewayDatabase(path: fixture.databasePath.path)
    #expect(try reopened.project(id: "child") == storedProject)
    #expect(storedProject.rootPath == fixture.registration.project.rootPath)
    #expect(try reopened.profiles().first?.projectIDs == ["source", "child"])
    #expect(try reopened.derivedProjectRegistration(id: "child") == fixture.registration)
    try reopened.unregisterDerivedProject(
      fixture.registration, verifiedPrincipalID: fixture.principal, caller: .secureTunnel)
    try reopened.unregisterDerivedProject(
      fixture.registration, verifiedPrincipalID: fixture.principal, caller: .secureTunnel)
    #expect(try fixture.database.project(id: "child") == nil)
    #expect(try fixture.database.profiles().first?.projectIDs == ["source"])
    #expect(FileManager.default.fileExists(atPath: fixture.registration.project.rootPath))
  }

  @Test(arguments: ["source-grant", "existing-path", "preexisting-grant", "changed-source"])
  func failedRegistrationLeavesNoPartialRowsOrGrant(change: String) throws {
    let fixture = try DerivedFixture()
    defer { fixture.remove() }
    if change == "source-grant" || change == "preexisting-grant" {
      var grant = try #require(try fixture.database.profiles().first)
      if change == "source-grant" {
        grant.projectIDs.remove("source")
      } else {
        grant.projectIDs.insert("child")
      }
      try fixture.database.saveProfile(grant)
    } else if change == "existing-path" {
      try fixture.database.saveProject(
        .init(
          id: "independent", displayName: "Independent",
          rootPath: fixture.registration.project.rootPath))
    } else {
      var source = try #require(try fixture.database.project(id: "source"))
      source.rootPath = fixture.root.path
      try fixture.database.saveProject(source)
    }
    let grants = try fixture.database.profiles()
    #expect(throws: (any Error).self) {
      try fixture.register()
    }
    #expect(try fixture.database.project(id: "child") == nil)
    #expect(try fixture.database.derivedProjectRegistration(id: "child") == nil)
    #expect(try fixture.database.profiles() == grants)
  }

  @Test(arguments: ["new-profile", "project-edit", "alias-identity"])
  func unregisterNeverDeletesIndependentChanges(change: String) throws {
    let fixture = try DerivedFixture()
    defer { fixture.remove() }
    try fixture.register()
    if change == "new-profile" {
      try fixture.database.saveProfile(
        .init(
          id: .chatGPTObserve, capabilityIDs: [], projectIDs: ["child"],
          allowedCallers: [.secureTunnel]))
    } else {
      var child = fixture.registration.project
      child.displayName = "Independently renamed"
      if change == "alias-identity" { child.rootPath = fixture.root.path }
      try fixture.database.saveProject(child)
    }
    let grants = try fixture.database.profiles()
    let child = try fixture.database.project(id: "child")
    #expect(throws: (any Error).self) {
      try fixture.unregister()
    }
    #expect(try fixture.database.project(id: "child") == child)
    #expect(try fixture.database.profiles() == grants)
    #expect(try fixture.database.derivedProjectRegistration(id: "child") == fixture.registration)
  }

  @Test
  func sourceRevocationOnlyPermitsExactOwnedRollback() throws {
    let fixture = try DerivedFixture()
    defer { fixture.remove() }
    try fixture.register()
    var grant = try #require(try fixture.database.profiles().first)
    grant.projectIDs.remove("source")
    try fixture.database.saveProfile(grant)
    #expect(throws: (any Error).self) { try fixture.unregister() }
    #expect(try fixture.database.project(id: "child") != nil)
    try fixture.unregister(rollback: true)
    #expect(try fixture.database.project(id: "child") == nil)
    #expect(try fixture.database.profiles().first?.projectIDs.isEmpty == true)
  }

  @Test
  func historicalUnboundOwnershipIsReadableButCannotBeClaimedOrRemoved() throws {
    let fixture = try DerivedFixture()
    defer { fixture.remove() }
    try fixture.register()
    var historical = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.registration))
        as? [String: Any])
    historical.removeValue(forKey: "principalID")
    let payload = String(
      decoding: try JSONSerialization.data(withJSONObject: historical), as: UTF8.self)
    try DatabaseQueue(path: fixture.databasePath.path).write { database in
      try database.execute(
        sql: "UPDATE pluginDerivedProjects SET payloadJSON = ? WHERE projectID = ?",
        arguments: [payload, "child"])
    }
    let stored = try #require(try fixture.database.derivedProjectRegistration(id: "child"))
    #expect(stored.principalID == nil)
    let profiles = try fixture.database.profiles()
    #expect(throws: (any Error).self) { try fixture.register() }
    #expect(throws: (any Error).self) {
      try fixture.database.unregisterDerivedProject(
        stored, verifiedPrincipalID: fixture.principal, caller: .secureTunnel,
        allowRevokedSourceForRollback: true)
    }
    #expect(try fixture.database.derivedProjectRegistration(id: "child") == stored)
    #expect(try fixture.database.project(id: "child") != nil)
    #expect(try fixture.database.profiles() == profiles)
    #expect(FileManager.default.fileExists(atPath: stored.project.rootPath))
  }

  @Test(arguments: ["", "different-principal"])
  func verifiedPrincipalCannotBeOmittedOrSubstituted(principal: String) throws {
    let fixture = try DerivedFixture()
    defer { fixture.remove() }
    #expect(throws: (any Error).self) {
      try fixture.database.registerDerivedProject(
        fixture.registration, verifiedPrincipalID: principal, caller: .secureTunnel)
    }
    #expect(try fixture.database.project(id: "child") == nil)
    try fixture.register()
    #expect(throws: (any Error).self) {
      try fixture.database.unregisterDerivedProject(
        fixture.registration, verifiedPrincipalID: principal, caller: .secureTunnel,
        allowRevokedSourceForRollback: true)
    }
    #expect(try fixture.database.project(id: "child") != nil)
  }

  @Test
  func wildcardSourceGrantAndCurrentCallerPreservePrincipalOwnership() throws {
    let fixture = try DerivedFixture()
    defer { fixture.remove() }
    var profile = try #require(try fixture.database.profiles().first)
    profile.projectIDs = ["*"]
    profile.allowedCallers = [.localCLI]
    try fixture.database.saveProfile(profile)
    #expect(throws: (any Error).self) { try fixture.register() }
    try fixture.database.registerDerivedProject(
      fixture.registration, verifiedPrincipalID: fixture.principal, caller: .localCLI)
    #expect(try fixture.database.profiles().first?.projectIDs == ["*", "child"])
    // The creation channel is audit evidence, not the identity used to claim this resource.
    #expect(try fixture.database.derivedProjectRegistration(id: "child")?.caller == .secureTunnel)
    #expect(throws: (any Error).self) { try fixture.unregister() }
    try fixture.database.unregisterDerivedProject(
      fixture.registration, verifiedPrincipalID: fixture.principal, caller: .localCLI)
    #expect(try fixture.database.profiles().first?.projectIDs == ["*"])
  }

  @Test
  func permissionMutationsInvalidateOnlyPendingTicketsAndPublishAfterCommit() async throws {
    let fixture = try DerivedFixture()
    defer { fixture.remove() }
    let initialRevision = try #require(try fixture.database.profiles().first?.authorizationRevision)
    for state in [OperationTicketState.prepared, .pendingApproval, .approved, .executing] {
      try fixture.ticket(id: state.rawValue, state: state)
    }
    try fixture.ticket(id: "other-profile", state: .pendingApproval, profileID: .chatGPTObserve)
    var changes = fixture.database.profileChanges(for: .chatGPTOperate).makeAsyncIterator()
    try fixture.register()
    #expect(await changes.next() != nil)
    let reopened = try GatewayDatabase(path: fixture.databasePath.path)
    #expect(try reopened.profiles().first?.authorizationRevision == initialRevision + 1)
    for state in [OperationTicketState.prepared, .pendingApproval, .approved] {
      let ticket = try #require(try reopened.operationTicket(id: state.rawValue))
      #expect(ticket.state == .denied)
      #expect(ticket.failureCode == "operations.authorization_changed")
    }
    #expect(try reopened.operationTicket(id: "executing")?.state == .executing)
    #expect(try reopened.operationTicket(id: "other-profile")?.state == .pendingApproval)
    try fixture.register()
    #expect(try fixture.database.profiles().first?.authorizationRevision == initialRevision + 1)
    try fixture.ticket(id: "remove-pending", state: .approved)
    try fixture.unregister()
    #expect(await changes.next() != nil)
    #expect(try reopened.profiles().first?.authorizationRevision == initialRevision + 2)
    #expect(try reopened.operationTicket(id: "remove-pending")?.state == .denied)
    #expect(try reopened.operationTicket(id: "executing")?.state == .executing)
    #expect(try reopened.operationTicket(id: "other-profile")?.state == .pendingApproval)
  }

  @Test(arguments: [false, true])
  func revisionFailureRollsBackEveryRegistrationMutation(removing: Bool) throws {
    let fixture = try DerivedFixture()
    defer { fixture.remove() }
    if removing { try fixture.register() }
    try fixture.ticket(id: "pending", state: .pendingApproval)
    try DatabaseQueue(path: fixture.databasePath.path).write { database in
      try database.execute(
        sql: "UPDATE profiles SET authorizationRevision = ? WHERE id = ?",
        arguments: [Int64.max, GatewayProfileID.chatGPTOperate.rawValue])
    }
    let profiles = try fixture.database.profiles()
    let project = try fixture.database.project(id: "child")
    let registration = try fixture.database.derivedProjectRegistration(id: "child")
    #expect(throws: (any Error).self) {
      if removing { try fixture.unregister() } else { try fixture.register() }
    }
    #expect(try fixture.database.profiles() == profiles)
    #expect(try fixture.database.project(id: "child") == project)
    #expect(try fixture.database.derivedProjectRegistration(id: "child") == registration)
    #expect(try fixture.database.operationTicket(id: "pending")?.state == .pendingApproval)
  }
}

private final class DerivedFixture {
  let root: URL
  let databasePath: URL
  let database: GatewayDatabase
  let registration: MCPDerivedProjectRegistration
  let principal = "verified-fixture-principal"
  init() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    root = directory.resolvingSymlinksInPath()
    let source = root.appendingPathComponent("source")
    let child = root.appendingPathComponent("derived")
    for path in [source, child] {
      try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
    }
    databasePath = root.appendingPathComponent("host.sqlite")
    database = try GatewayDatabase(path: databasePath.path)
    try database.saveProject(.init(id: "source", displayName: "Source", rootPath: source.path))
    try database.saveProfile(
      .init(
        id: .chatGPTOperate, capabilityIDs: [], projectIDs: ["source"],
        allowedCallers: [.secureTunnel], mode: .projectOperations))
    registration = .init(
      origin: "fixture", receiptID: UUID().uuidString, sourceProjectID: "source",
      sourceRoot: source.path,
      receiptDigest: "fixture-digest", profileID: .chatGPTOperate, principalID: principal,
      caller: .secureTunnel,
      project: .init(id: "child", displayName: "Derived", rootPath: child.path))
  }
  func register() throws {
    try database.registerDerivedProject(
      registration, verifiedPrincipalID: principal, caller: .secureTunnel)
  }
  func unregister(rollback: Bool = false) throws {
    try database.unregisterDerivedProject(
      registration, verifiedPrincipalID: principal, caller: .secureTunnel,
      allowRevokedSourceForRollback: rollback)
  }
  func ticket(
    id: String, state: OperationTicketState, profileID: GatewayProfileID = .chatGPTOperate
  ) throws {
    try database.saveOperationTicket(
      .init(
        id: id, capabilityID: "fixture", caller: .secureTunnel, profileID: profileID,
        principalID: principal, projectID: "source", inputDigest: "fixture", state: state,
        expiresAt: Date().addingTimeInterval(3_600),
        authorizationRevision: try database.profiles().first?.authorizationRevision))
  }
  func remove() { try? FileManager.default.removeItem(at: root) }
}
