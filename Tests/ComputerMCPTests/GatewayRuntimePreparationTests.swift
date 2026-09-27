import Foundation
import GRDB
import Testing

@testable import ComputerMCP

@Suite(.timeLimit(.minutes(1)))
struct GatewayRuntimePreparationTests {
  @Test(arguments: [false, true])
  func workspacePreviewPublishesNoGrantTicketReceiptOrNotification(removing: Bool) async throws {
    let stream = try { () -> AsyncStream<Void> in
      let fixture = try PreparationStateFixture()
      defer { fixture.cleanup() }
      var duplicate = try #require(try fixture.database.workspace(id: "fixture"))
      duplicate.id = "duplicate"
      duplicate.createdAt = duplicate.createdAt.addingTimeInterval(1)
      try fixture.database.saveWorkspace(duplicate)
      var profile = try #require(try fixture.database.profiles().first)
      profile.workspaceIDs = [removing ? "fixture" : "duplicate"]
      try fixture.database.saveProfile(profile)
      try fixture.database.saveOperationTicket(
        OperationTicket(
          id: "pending", capabilityID: "file.trash", caller: .localCLI,
          profileID: profile.id, inputDigest: "fixture", state: .approved,
          expiresAt: Date().addingTimeInterval(3_600)))
      let expected = try fixture.database.configurationState()
      let ticket = try fixture.database.operationTicket(id: "pending")
      let changes = fixture.database.profileChanges(for: profile.id)
      let plan = try fixture.database.workspaceDeduplicationPlan()
      let mutation: WorkspaceConfigurationMutation =
        removing
        ? .remove("fixture")
        : .deduplicate(expectedPlanDigest: plan.planDigest, allowMetadataConflicts: false)
      let prepared = try fixture.database.prepareWorkspaceChange(mutation, expected: expected)
      #expect(prepared.proposed != expected)
      #expect(try fixture.database.configurationState() == expected)
      #expect(try fixture.database.workspaceDeduplicationPlan() == plan)
      #expect(try fixture.database.operationTicket(id: "pending") == ticket)
      let connection = try DatabaseQueue(path: #require(fixture.database.fileURL).path)
      let receipts = try connection.read {
        try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM workspaceDeduplicationReceipts")
      }
      try connection.close()
      #expect(receipts == 0)
      return changes
    }()
    var notifications = 0
    for await _ in stream { notifications += 1 }
    #expect(notifications == 0)
  }

  @Test(arguments: ["register", "remove", "deduplicate"], [false, true])
  func workspacePreparationDefersAuthorityAndCommitsResolution(operation: String, fail: Bool)
    async throws
  {
    let fixture = try PreparationStateFixture()
    defer { fixture.cleanup() }
    let extraRoot = fixture.root.appendingPathComponent("extra")
    try FileManager.default.createDirectory(at: extraRoot, withIntermediateDirectories: true)
    let extra = RegisteredWorkspace(
      id: "extra", displayName: "Fixture",
      rootPath: operation == "deduplicate" ? fixture.root.path : extraRoot.path,
      createdAt: Date(timeIntervalSince1970: 2000))
    if operation != "register" { try fixture.database.saveWorkspace(extra) }
    let original = try fixture.database.configurationState()
    let mutation: WorkspaceConfigurationMutation
    switch operation {
    case "register": mutation = .register(extra)
    case "remove": mutation = .remove(extra.id)
    default:
      mutation = .deduplicate(
        expectedPlanDigest: try fixture.database.workspaceDeduplicationPlan().planDigest,
        allowMetadataConflicts: false)
    }
    let change = try fixture.database.prepareWorkspaceChange(mutation, expected: original)
    #expect(try fixture.database.configurationState() == original)
    let prepared = try await fixture.prepare(state: change.proposed)
    do {
      #expect(try fixture.database.configurationState() == original)
      var resolution = prepared.resolution
      if fail {
        var conflict = try #require(resolution.profiles.first)
        conflict.authorizationRevision = 1
        resolution.profiles = [conflict]
        #expect(throws: GatewayDatabaseError.configurationChanged) {
          try fixture.database.saveWorkspaceChange(change, resolution: resolution)
        }
        #expect(try fixture.database.configurationState() == original)
      } else {
        let committed = try fixture.database.saveWorkspaceChange(change, resolution: resolution)
        #expect(committed.workspaces.contains { $0.id == extra.id } == (operation == "register"))
        #expect(committed.profiles.first?.authorizationRevision == 1)
        #expect(
          committed.workspaces.first { $0.id == "fixture" }?.bookmarkData == Data("refreshed".utf8))
        #expect(committed.plugins == original.plugins)
        if operation == "deduplicate" {
          #expect(committed.workspaceAliases[extra.id] == "fixture")
        }
      }
      await prepared.runtime.shutdown()
    } catch {
      await prepared.runtime.shutdown()
      throw error
    }
    #expect(fixture.adapter.startCount == fixture.adapter.stopCount)
  }

  @Test(arguments: [false, true])
  func pluginPublicationCommitsResolutionAtomically(fail: Bool) async throws {
    let fixture = try PreparationStateFixture()
    defer { fixture.cleanup() }
    let original = try fixture.database.configurationState()
    let prepared = try await fixture.prepare(state: original)
    do {
      var proposed = original.plugins
      proposed.revision += 1
      var resolution = prepared.resolution
      if fail {
        var conflict = try #require(resolution.profiles.first)
        conflict.authorizationRevision = 1
        resolution.profiles = [conflict]
        #expect(throws: GatewayDatabaseError.configurationChanged) {
          try fixture.database.savePluginStoreSnapshot(
            proposed, expectedRevision: 0, expectedConfiguration: original, resolution: resolution)
        }
        #expect(try fixture.database.configurationState() == original)
      } else {
        let committed = try fixture.database.savePluginStoreSnapshot(
          proposed, expectedRevision: 0, expectedConfiguration: original, resolution: resolution)
        #expect(committed.plugins == proposed)
        #expect(committed.workspaces.first?.bookmarkData == Data("refreshed".utf8))
        #expect(committed.profiles.first?.authorizationRevision == 1)
        try prepared.runtime.requirePreparedPublication()
        prepared.runtime.publishPrepared()
        _ = try await prepared.runtime.callToolAsync(
          name: "workspace.list", arguments: .object([:]))
      }
      await prepared.runtime.shutdown()
    } catch {
      await prepared.runtime.shutdown()
      throw error
    }
    #expect(fixture.adapter.stopCount == 1)
  }

  @Test(arguments: [false, true])
  func preparationDefersBookmarkAndLegacyAuthorityWrites(fail: Bool) async throws {
    let fixture = try PreparationStateFixture()
    defer { fixture.cleanup() }
    let original = try fixture.database.configurationState()
    let state = GatewayDatabase.ConfigurationState(
      workspaces: fail ? original.workspaces + original.workspaces : original.workspaces,
      workspaceAliases: original.workspaceAliases, profiles: original.profiles,
      plugins: original.plugins)
    if fail {
      await #expect(throws: GatewayRuntimeError.duplicateWorkspaceID("fixture")) {
        try await fixture.prepare(state: state)
      }
    } else {
      let prepared = try await fixture.prepare(state: state)
      do {
        #expect(try fixture.database.configurationState() == original)
        let workspace = try #require(prepared.resolution.workspaces.first)
        #expect(workspace.original == original.workspaces.first)
        #expect(workspace.resolved.bookmarkData == Data("refreshed".utf8))
        #expect(workspace.resolved.createdAt == workspace.original.createdAt)
        #expect(prepared.resolution.profiles.count == 1)
        #expect(prepared.resolution.profiles.first?.authorizationRevision == 0)
        #expect(throws: GatewayToolError.self) {
          try prepared.runtime.authenticatedSession(principalID: "another", transportTrace: nil)
        }
        await #expect(throws: GatewayToolError.self) {
          try await prepared.runtime.callToolAsync(name: "workspace.list", arguments: .object([:]))
        }
        #expect(fixture.adapter.stopCount == 0)
        await prepared.runtime.shutdown()
      } catch {
        await prepared.runtime.shutdown()
        throw error
      }
    }
    #expect(try fixture.database.configurationState() == original)
    #expect(fixture.adapter.startCount == 1)
    #expect(fixture.adapter.stopCount == 1)
  }

  @Test
  func cancelledPreparationJoinsResolutionWithoutChangingAuthority() async throws {
    let fixture = try PreparationStateFixture(gated: true)
    defer { fixture.cleanup() }
    let original = try fixture.database.configurationState()
    let task = Task { try await fixture.prepare(state: original) }
    do {
      let deadline = ContinuousClock.now.advanced(by: .seconds(10))
      while !fixture.adapter.started, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      try #require(fixture.adapter.started)
      task.cancel()
      fixture.adapter.release.signal()
      await #expect(throws: CancellationError.self) { try await task.value }
      #expect(try fixture.database.configurationState() == original)
      #expect(fixture.adapter.startCount == 1)
      #expect(fixture.adapter.stopCount == 1)
    } catch {
      task.cancel()
      fixture.adapter.release.signal()
      if let prepared = try? await task.value { await prepared.runtime.shutdown() }
      throw error
    }
  }
}

private struct PreparationStateFixture: Sendable {
  let root: URL
  let database: GatewayDatabase
  let adapter: PreparationBookmarkAdapter

  init(gated: Bool = false) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    database = try GatewayDatabase(path: root.appendingPathComponent("gateway.sqlite").path)
    adapter = PreparationBookmarkAdapter(root: root, gated: gated)
    try database.saveWorkspace(
      RegisteredWorkspace(
        id: "fixture", displayName: "Fixture", rootPath: root.path,
        bookmarkData: Data("original".utf8), createdAt: Date(timeIntervalSince1970: 1000),
        updatedAt: Date(timeIntervalSince1970: 1000)))
    try database.saveProfile(
      ProfileGrant(
        id: .localAdmin, capabilityIDs: ["workspace.list"], workspaceIDs: ["fixture"],
        allowedCallers: [.localCLI]))
    // Recreate the persisted pre-migration authority shape.
    let legacy = try DatabaseQueue(path: root.appendingPathComponent("gateway.sqlite").path)
    try legacy.write { database in
      try database.execute(sql: "UPDATE profiles SET authorizationRevision = 0")
    }
    try legacy.close()
  }

  func prepare(state: GatewayDatabase.ConfigurationState) async throws -> GatewayRuntimePreparation
  {
    try await GatewayRuntime.prepare(
      configuration: GatewayConfiguration(workspaceDirectory: root),
      context: ExecutionContext(caller: .localCLI, profileID: .localAdmin, workspaceID: "fixture"),
      database: database, state: state,
      bookmarkService: WorkspaceBookmarkService(
        adapter: adapter, now: { Date(timeIntervalSince1970: 2000) }),
      bundledPlugins: BundledPlugins(packages: [], issues: []))
  }

  func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private final class PreparationBookmarkAdapter: WorkspaceBookmarkAdapter, @unchecked Sendable {
  private let lock = NSLock()
  private let root: URL
  private let gated: Bool
  let release = DispatchSemaphore(value: 0)
  private var didStart = false
  private var starts = 0
  private var stops = 0

  init(root: URL, gated: Bool) {
    self.root = root
    self.gated = gated
  }

  var started: Bool { lock.withLock { didStart } }
  var startCount: Int { lock.withLock { starts } }
  var stopCount: Int { lock.withLock { stops } }

  func createBookmark(for url: URL) throws -> Data { Data("refreshed".utf8) }

  func resolveBookmark(_ data: Data) throws -> WorkspaceBookmarkResolution {
    lock.withLock { didStart = true }
    if gated { _ = release.wait(timeout: .now() + .seconds(15)) }
    return WorkspaceBookmarkResolution(url: root, isStale: true)
  }

  func startAccessing(_ url: URL) -> Bool {
    lock.withLock { starts += 1 }
    return true
  }

  func stopAccessing(_ url: URL) { lock.withLock { stops += 1 } }
}
