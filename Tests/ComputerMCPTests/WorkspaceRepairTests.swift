import Foundation
import Testing

@testable import ComputerMCP

@Suite
struct WorkspaceRepairTests {
  @Test
  func repairPreservesIdentityAndGrantsWhileInvalidatingUnusedScopeApprovals() throws {
    let fixture = try RepairFixture()
    defer { fixture.cleanup() }
    var duplicate = fixture.original
    duplicate.id = "alias"
    duplicate.createdAt = duplicate.createdAt.addingTimeInterval(1)
    try fixture.database.saveWorkspace(duplicate)
    _ = try fixture.database.applyWorkspaceDeduplication(
      expectedPlanDigest: fixture.database.workspaceDeduplicationPlan().planDigest,
      allowMetadataConflicts: false)
    for (id, workspaces) in [
      (GatewayProfileID.chatGPTOperate, Set(["project"])),
      (.cloudflareOperate, Set(["*"])), (.localAdmin, Set(["unrelated"])),
    ] {
      try fixture.database.saveProfile(
        ProfileGrant(
          id: id, capabilityIDs: ["file.read"], workspaceIDs: workspaces,
          allowedCallers: [.localCLI]))
    }
    let states: [OperationTicketState] = [
      .prepared, .pendingApproval, .approved, .executing, .succeeded,
    ]
    for (index, state) in states.enumerated() {
      try fixture.database.saveOperationTicket(
        OperationTicket(
          id: "ticket-\(index)", capabilityID: "file.write", caller: .localCLI,
          profileID: .chatGPTOperate, workspaceID: "project", inputDigest: "original",
          state: state, expiresAt: Date().addingTimeInterval(300)))
    }
    let unstored = try #require(GatewayProfileID(rawValue: "unstored"))
    for (id, workspace) in [("alias-ticket", "alias"), ("unrelated-ticket", "unrelated")] {
      try fixture.database.saveOperationTicket(
        OperationTicket(
          id: id, capabilityID: "file.write", caller: .localCLI, profileID: unstored,
          workspaceID: workspace, inputDigest: "original", state: .approved,
          expiresAt: Date().addingTimeInterval(300)))
    }
    let expected = try fixture.database.configurationState()
    let ticketIDs = states.indices.map { "ticket-\($0)" } + ["alias-ticket", "unrelated-ticket"]
    let tickets = try ticketIDs.map { try fixture.database.operationTicket(id: $0) }
    let prepared = try fixture.database.prepareWorkspaceChange(
      .repair(fixture.repaired, root: WorkspaceRootIdentity(fixture.destination)),
      expected: expected)
    #expect(try fixture.database.configurationState() == expected)
    #expect(try ticketIDs.map { try fixture.database.operationTicket(id: $0) } == tickets)
    let committed = try fixture.database.saveWorkspaceChange(prepared, resolution: .init())
    #expect(committed.workspaces == [fixture.repaired])
    #expect(committed.workspaceAliases == ["alias": "project"])
    #expect(try fixture.database.workspace(id: "alias") == fixture.repaired)
    for stored in expected.profiles {
      var wanted = stored
      if stored.id != .localAdmin { wanted.authorizationRevision += 1 }
      #expect(committed.profiles.first { $0.id == stored.id } == wanted)
    }
    for (index, state) in states.enumerated() {
      #expect(
        try fixture.database.operationTicket(id: "ticket-\(index)")?.state
          == (index < 3 ? .denied : state))
    }
    #expect(try fixture.database.operationTicket(id: "alias-ticket")?.state == .denied)
    #expect(try fixture.database.operationTicket(id: "unrelated-ticket")?.state == .approved)
    #expect(
      try fixture.database.registerWorkspaceIdempotently(
        .init(displayName: "New", rootPath: fixture.repaired.rootPath)
      ).workspace.id == "project")
    #expect(
      try fixture.database.registerWorkspaceIdempotently(
        .init(displayName: "Original", rootPath: fixture.original.rootPath)
      ).created)
  }

  @Test
  func canonicalCollisionAndConcurrentChangesLeaveAuthorityIntact() throws {
    let fixture = try RepairFixture()
    defer { fixture.cleanup() }
    var occupied = fixture.repaired
    occupied.id = "occupied"
    try fixture.database.saveWorkspace(occupied)
    let expected = try fixture.database.configurationState()
    let link = fixture.root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.destination)
    var proposed = fixture.repaired
    proposed.rootPath = link.path
    #expect(throws: WorkspaceRepairError.rootAlreadyRegistered(workspaceID: occupied.id)) {
      try fixture.database.prepareWorkspaceChange(
        .repair(proposed, root: WorkspaceRootIdentity(link)), expected: expected)
    }
    #expect(try fixture.database.configurationState() == expected)
    try fixture.database.deleteWorkspace(id: occupied.id)
    let prepared = try fixture.database.prepareWorkspaceChange(
      .repair(fixture.repaired, root: WorkspaceRootIdentity(fixture.destination)),
      expected: fixture.database.configurationState())
    var renamed = fixture.original
    renamed.displayName = "Concurrent edit"
    try fixture.database.saveWorkspace(renamed)
    let concurrent = try fixture.database.configurationState()
    #expect(throws: GatewayDatabaseError.configurationChanged) {
      try fixture.database.saveWorkspaceChange(prepared, resolution: .init())
    }
    #expect(try fixture.database.configurationState() == concurrent)
  }
}

private struct RepairFixture {
  let root: URL
  let destination: URL
  let database: GatewayDatabase
  let original: RegisteredWorkspace
  let repaired: RegisteredWorkspace

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    destination = root.appendingPathComponent("new")
    let source = root.appendingPathComponent("old")
    for url in [source, destination] {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    database = try GatewayDatabase(inMemory: ())
    original = RegisteredWorkspace(
      id: "project", displayName: "Project", rootPath: source.path,
      bookmarkData: Data("old".utf8), createdAt: Date(timeIntervalSince1970: 1000),
      updatedAt: Date(timeIntervalSince1970: 1000))
    var renewed = original
    renewed.rootPath = destination.path
    renewed.bookmarkData = Data("renewed".utf8)
    renewed.updatedAt = Date(timeIntervalSince1970: 2000)
    repaired = renewed
    try database.saveWorkspace(original)
  }

  func cleanup() { try? FileManager.default.removeItem(at: root) }
}
