import ComputerMCPPermissions
import ComputerMCPToolsProject
import Foundation
import Testing

@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPersistence

@Suite
struct ProjectRepairTests {
  @Test
  func repairPreservesIdentityAndPermissionsAndRevisesAffectedProfiles() throws {
    let fixture = try RepairFixture()
    defer { fixture.cleanup() }
    var duplicate = fixture.original
    duplicate.id = "alias"
    duplicate.createdAt = duplicate.createdAt.addingTimeInterval(1)
    try fixture.database.saveProject(duplicate)
    _ = try fixture.database.applyProjectDeduplication(
      expectedPlanDigest: fixture.database.projectDeduplicationPlan().planDigest,
      allowMetadataConflicts: false)
    for (id, projects) in [
      (GatewayProfileID.chatGPTOperate, Set(["project"])),
      (.cloudflareOperate, Set(["*"])), (.localAdmin, Set(["unrelated"])),
    ] {
      try fixture.database.saveProfile(
        ProfileGrant(
          id: id, permissions: try repairPermissions(projects),
          allowedCallers: [.localCLI]))
    }
    let expected = try fixture.database.configurationState()
    let prepared = try fixture.database.prepareProjectChange(
      .repair(fixture.repaired, root: ProjectRootIdentity(fixture.destination)),
      expected: expected)
    #expect(try fixture.database.configurationState() == expected)
    let committed = try fixture.database.saveProjectChange(prepared, resolution: .init())
    #expect(committed.projects == [fixture.repaired])
    #expect(committed.projectAliases == ["alias": "project"])
    #expect(try fixture.database.project(id: "alias") == fixture.repaired)
    for stored in expected.profiles {
      var wanted = stored
      if stored.id != .localAdmin { wanted.authorizationRevision += 1 }
      #expect(committed.profiles.first { $0.id == stored.id } == wanted)
    }
    #expect(
      try fixture.database.registerProjectIdempotently(
        .init(displayName: "New", rootPath: fixture.repaired.rootPath)
      ).project.id == "project")
    #expect(
      try fixture.database.registerProjectIdempotently(
        .init(displayName: "Original", rootPath: fixture.original.rootPath)
      ).created)
  }

  @Test
  func canonicalCollisionAndConcurrentChangesLeaveAuthorityIntact() throws {
    let fixture = try RepairFixture()
    defer { fixture.cleanup() }
    var occupied = fixture.repaired
    occupied.id = "occupied"
    try fixture.database.saveProject(occupied)
    let expected = try fixture.database.configurationState()
    let link = fixture.root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.destination)
    var proposed = fixture.repaired
    proposed.rootPath = link.path
    #expect(throws: ProjectRepairError.rootAlreadyRegistered(projectID: occupied.id)) {
      try fixture.database.prepareProjectChange(
        .repair(proposed, root: ProjectRootIdentity(link)), expected: expected)
    }
    #expect(try fixture.database.configurationState() == expected)
    try fixture.database.deleteProject(id: occupied.id)
    let prepared = try fixture.database.prepareProjectChange(
      .repair(fixture.repaired, root: ProjectRootIdentity(fixture.destination)),
      expected: fixture.database.configurationState())
    var renamed = fixture.original
    renamed.displayName = "Concurrent edit"
    try fixture.database.saveProject(renamed)
    let concurrent = try fixture.database.configurationState()
    #expect(throws: GatewayDatabaseError.configurationChanged) {
      try fixture.database.saveProjectChange(prepared, resolution: .init())
    }
    #expect(try fixture.database.configurationState() == concurrent)
  }
}

private struct RepairFixture {
  let root: URL
  let destination: URL
  let database: GatewayDatabase
  let original: ComputerMCPCore.RegisteredProject
  let repaired: ComputerMCPCore.RegisteredProject

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    destination = root.appendingPathComponent("new")
    let source = root.appendingPathComponent("old")
    for url in [source, destination] {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    database = try GatewayDatabase(inMemory: ())
    original = ComputerMCPCore.RegisteredProject(
      id: "project", displayName: "Project", rootPath: source.path,
      bookmarkData: Data("old".utf8), createdAt: Date(timeIntervalSince1970: 1000),
      updatedAt: Date(timeIntervalSince1970: 1000))
    var renewed = original
    renewed.rootPath = destination.path
    renewed.bookmarkData = Data("renewed".utf8)
    renewed.updatedAt = Date(timeIntervalSince1970: 2000)
    repaired = renewed
    try database.saveProject(original)
  }

  func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private func repairPermissions(_ projects: Set<String>) throws -> Permissions {
  var permissions = Permissions()
  for project in projects { try permissions.set(.granted(.read), for: .project(project)) }
  return permissions
}
