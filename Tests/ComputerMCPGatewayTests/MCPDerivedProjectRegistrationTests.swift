import ComputerMCPDownstream
import ComputerMCPPermissions
import ComputerMCPWorktrees
import Foundation
import GRDB
import Testing

@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPersistence

@Suite(.timeLimit(.minutes(1)))
struct MCPDerivedProjectRegistrationTests {
  @Test func hostProvenanceCannotBeClaimedThroughThePluginContract() throws {
    let fixture = try DerivedFixture()
    defer { fixture.remove() }
    let source = try #require(try fixture.database.project(id: "source"))
    let record = DerivedProjectRecord(
      projectID: "host-child",
      source: .init(id: source.id, root: source.rootPath, registeredAt: source.createdAt),
      root: fixture.root.appendingPathComponent("host-child").path,
      provenance: .host(worktreeID: UUID(), storageGeneration: UUID()))
    try SQLiteDerivedProjectStore(connection: fixture.database.connection).commit(
      record, expecting: nil)
    #expect(throws: MCPHostServiceError.self) {
      try fixture.database.derivedProjectRegistration(id: record.projectID)
    }
  }

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
    let migrated = try fixturePermissionDatabase(path: path)
    #expect(try migrated.derivedProjectRegistration(id: fixture.registration.project.id) == nil)
    #expect(try migrated.profiles().isEmpty)
    let source = try #require(
      try fixture.database.project(id: fixture.registration.sourceProjectID))
    let legacy = LegacyProfileGrant(
      id: fixture.registration.profileID, capabilityIDs: ["file.write"],
      projectIDs: [source.id, fixture.registration.project.id], allowedCallers: [.secureTunnel],
      mode: .projectOperations)
    let catalog = try PermissionMigrationCatalog(
      configurationDigest: "historical-derived-fixture", availableBuiltinIDs: ["file.write"],
      serverIDs: [], manifestProfiles: [legacy],
      manifestProjects: [source, fixture.registration.project])
    let permissions = try migrated.configuredPermissionStore()
    let migration = PermissionMigrationStore(connection: migrated.connection, store: permissions)
    let (plan, state) = try migration.prepare(catalog: catalog)
    #expect(plan.derived == [fixture.registration])
    #expect(plan.profiles.first?.permissions.state(for: .project(source.id)) == .granted(.write))
    #expect(
      plan.profiles.first?.permissions.entries[.project(fixture.registration.project.id)] == nil)
    #expect(try migration.apply(plan, expectedState: state, currentCatalog: catalog))
    let registration = try #require(
      try migrated.derivedProjectRegistration(id: fixture.registration.project.id))
    #expect(registration == fixture.registration)
    #expect(registration.receiptDigest == fixture.registration.receiptDigest)
    let reader = try DatabaseQueue(path: path)
    defer { try? reader.close() }
    #expect(
      try reader.read {
        guard
          case .plugin(let receipt) = try SQLiteDerivedProjectStore.record(
            registration.project.id, in: $0)?.provenance
        else { return nil as String? }
        return String(decoding: receipt, as: UTF8.self)
      } == payload)
    let profiles = try migrated.profiles()
    let authority = try permissions.readWithDatabase { database, ledger in
      (
        ledger: ledger,
        controlRevision: try #require(
          try Int64.fetchOne(
            database, sql: "SELECT revision FROM permissionControlRevision WHERE id = 1"))
      )
    }
    let configuration = try migrated.configurationState()
    #expect(try migration.apply(plan, expectedState: state, currentCatalog: catalog) == false)
    let reopened = try fixturePermissionDatabase(path: path)
    #expect(try reopened.derivedProjectRegistration(id: registration.project.id) == registration)
    #expect(try reopened.profiles() == profiles)
    #expect(try reopened.configurationState() == configuration)
    try reopened.configuredPermissionStore().readWithDatabase { database, ledger in
      #expect(ledger == authority.ledger)
      let revision = try Int64.fetchOne(
        database, sql: "SELECT revision FROM permissionControlRevision WHERE id = 1")
      #expect(revision == authority.controlRevision)
    }
  }

  @Test
  func registrationInheritanceIsAtomicDurableAndIdempotent() throws {
    let fixture = try DerivedFixture()
    defer { fixture.remove() }
    let profile = try #require(fixture.database.profiles().first)
    try fixture.register()
    let storedProject = try #require(try fixture.database.project(id: "child"))
    try fixture.register()
    let reopened = try fixturePermissionDatabase(path: fixture.databasePath.path)
    #expect(try reopened.project(id: "child") == storedProject)
    #expect(storedProject.rootPath == fixture.registration.project.rootPath)
    #expect(try reopened.profiles().first == profile)
    #expect(try reopened.derivedProjectRegistration(id: "child") == fixture.registration)
    try reopened.unregisterDerivedProject(
      fixture.registration, verifiedPrincipalID: fixture.principal, caller: .secureTunnel)
    try reopened.unregisterDerivedProject(
      fixture.registration, verifiedPrincipalID: fixture.principal, caller: .secureTunnel)
    #expect(try fixture.database.project(id: "child") == nil)
    #expect(try fixture.database.profiles().first == profile)
    #expect(FileManager.default.fileExists(atPath: fixture.registration.project.rootPath))
  }

  @Test(arguments: ["source-grant", "existing-path", "preexisting-grant", "changed-source"])
  func failedRegistrationLeavesNoPartialRowsOrPermissionChanges(change: String) throws {
    let fixture = try DerivedFixture()
    defer { fixture.remove() }
    if change == "source-grant" || change == "preexisting-grant" {
      var grant = try #require(try fixture.database.profiles().first)
      if change == "source-grant" {
        try grant.permissions.set(.denied, for: .project("source"))
      } else {
        try grant.permissions.set(.granted(.write), for: .project("child"))
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
          id: .chatGPTObserve, permissions: try derivedPermissions(["child"]),
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
    try grant.permissions.set(.denied, for: .project("source"))
    try fixture.database.saveProfile(grant)
    #expect(throws: (any Error).self) { try fixture.unregister() }
    #expect(try fixture.database.project(id: "child") != nil)
    try fixture.unregister(rollback: true)
    #expect(try fixture.database.project(id: "child") == nil)
    #expect(
      try fixture.database.profiles().first?.permissions.state(for: .project("source")) == .denied)
  }

  @Test
  func historicalUnboundOwnershipIsReadableButCannotBeClaimedOrRemoved() throws {
    let fixture = try DerivedFixture()
    defer { fixture.remove() }
    try fixture.register()
    var historical = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.registration))
        as? [String: Any])
    #expect(historical["sourceWorkspaceID"] as? String == fixture.registration.sourceProjectID)
    #expect(historical["workspace"] != nil)
    let removedPrincipal = historical.removeValue(forKey: "principalID")
    _ = try #require(removedPrincipal)
    let payload = try JSONSerialization.data(withJSONObject: historical, options: [.sortedKeys])
    try fixture.database.connection.writer.write { database in
      let record = try DerivedProjectMigration.pluginRecord(payload: payload, in: database)
      try database.execute(
        sql: "UPDATE derivedProjects SET payload = ? WHERE projectID = ?",
        arguments: [try JSONEncoder().encode(record), "child"])
      #expect(database.changesCount == 1)
    }
    let stored = try #require(try fixture.database.derivedProjectRegistration(id: "child"))
    #expect(stored.principalID == nil)
    #expect(stored.receiptDigest == fixture.registration.receiptDigest)
    let profiles = try fixture.database.profiles()
    let configuration = try fixture.database.configurationState()
    let permissions = try fixture.database.configuredPermissionStore()
    let authority = try permissions.readWithDatabase { database, ledger in
      (
        ledger: ledger,
        controlRevision: try #require(
          try Int64.fetchOne(
            database, sql: "SELECT revision FROM permissionControlRevision WHERE id = 1"))
      )
    }
    #expect(throws: (any Error).self) { try fixture.register() }
    #expect(throws: (any Error).self) {
      try fixture.database.unregisterDerivedProject(
        stored, verifiedPrincipalID: fixture.principal, caller: .secureTunnel,
        allowRevokedSourceForRollback: true)
    }
    #expect(try fixture.database.derivedProjectRegistration(id: "child") == stored)
    #expect(try fixture.database.project(id: "child") != nil)
    #expect(try fixture.database.profiles() == profiles)
    #expect(try fixture.database.configurationState() == configuration)
    try permissions.readWithDatabase { database, ledger in
      #expect(ledger == authority.ledger)
      let revision = try Int64.fetchOne(
        database, sql: "SELECT revision FROM permissionControlRevision WHERE id = 1")
      #expect(revision == authority.controlRevision)
    }
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
    profile.permissions = try derivedPermissions(["*"])
    profile.allowedCallers = [.localCLI]
    try fixture.database.saveProfile(profile)
    #expect(throws: (any Error).self) { try fixture.register() }
    try fixture.database.registerDerivedProject(
      fixture.registration, verifiedPrincipalID: fixture.principal, caller: .localCLI)
    #expect(
      try fixture.database.profiles().first?.permissions.entries == profile.permissions.entries)
    // The creation channel is audit evidence, not the identity used to claim this resource.
    #expect(try fixture.database.derivedProjectRegistration(id: "child")?.caller == .secureTunnel)
    #expect(throws: (any Error).self) { try fixture.unregister() }
    try fixture.database.unregisterDerivedProject(
      fixture.registration, verifiedPrincipalID: fixture.principal, caller: .localCLI)
    #expect(
      try fixture.database.profiles().first?.permissions.entries == profile.permissions.entries)
  }

  @Test
  func registrationAndRemovalDoNotEditStandingPermissionsOrRevision() throws {
    let fixture = try DerivedFixture()
    defer { fixture.remove() }
    let original = try fixture.database.profiles()
    try fixture.register()
    try fixture.register()
    let reopened = try fixturePermissionDatabase(path: fixture.databasePath.path)
    #expect(try reopened.profiles() == original)
    #expect(try reopened.profiles().first?.permissions.entries[.project("child")] == nil)
    try fixture.unregister()
    #expect(try reopened.profiles() == original)
    #expect(try reopened.project(id: "child") == nil)
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
    database = try fixturePermissionDatabase(path: databasePath.path)
    try database.saveProject(.init(id: "source", displayName: "Source", rootPath: source.path))
    try database.saveProfile(
      .init(
        id: .chatGPTOperate, permissions: try derivedPermissions(["source"]),
        allowedCallers: [.secureTunnel]))
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
  func remove() { try? FileManager.default.removeItem(at: root) }
}

private func derivedPermissions(_ projects: Set<String>) throws -> Permissions {
  var permissions = Permissions()
  for project in projects { try permissions.set(.granted(.write), for: .project(project)) }
  return permissions
}
