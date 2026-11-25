import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPTestSupport
import ComputerMCPToolsProject
import Foundation
import GRDB
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPersistence
@testable import ComputerMCPPlatformDarwin
@testable import ComputerMCPPlugins

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.timeLimit(.minutes(1)))
struct GatewayRuntimePreparationTests {
  @Test(arguments: [false, true])
  func projectPreviewPublishesNoPermissionReceiptOrNotification(removing: Bool) async throws {
    let stream = try { () -> AsyncStream<Void> in
      let fixture = try PreparationStateFixture()
      defer { fixture.cleanup() }
      var duplicate = try #require(try fixture.database.project(id: "fixture"))
      duplicate.id = "duplicate"
      duplicate.createdAt = duplicate.createdAt.addingTimeInterval(1)
      try fixture.database.saveProject(duplicate)
      var profile = try #require(try fixture.database.profiles().first)
      profile.permissions = fixturePermissions([
        .project(removing ? "fixture" : "duplicate"): .granted(.read)
      ])
      try fixture.database.saveProfile(profile)
      let expected = try fixture.database.configurationState()
      let changes = fixture.database.profileChanges(for: profile.id)
      let plan = try fixture.database.projectDeduplicationPlan()
      let mutation: ProjectConfigurationMutation =
        removing
        ? .remove("fixture")
        : .deduplicate(expectedPlanDigest: plan.planDigest, allowMetadataConflicts: false)
      let prepared = try fixture.database.prepareProjectChange(mutation, expected: expected)
      #expect(prepared.proposed != expected)
      #expect(try fixture.database.configurationState() == expected)
      #expect(try fixture.database.projectDeduplicationPlan() == plan)
      let connection = try DatabaseQueue(path: #require(fixture.database.fileURL).path)
      let receipts = try connection.read {
        try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM projectDeduplicationReceipts")
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
  func projectPreparationDefersAuthorityAndCommitsResolution(operation: String, fail: Bool)
    async throws
  {
    let fixture = try PreparationStateFixture()
    defer { fixture.cleanup() }
    let extraRoot = fixture.root.appendingPathComponent("extra")
    try FileManager.default.createDirectory(at: extraRoot, withIntermediateDirectories: true)
    let extra = RegisteredProject(
      id: "extra", displayName: "Fixture",
      rootPath: operation == "deduplicate" ? fixture.root.path : extraRoot.path,
      createdAt: Date(timeIntervalSince1970: 2000))
    if operation != "register" { try fixture.database.saveProject(extra) }
    let original = try fixture.database.configurationState()
    let mutation: ProjectConfigurationMutation
    switch operation {
    case "register": mutation = .register(extra)
    case "remove": mutation = .remove(extra.id)
    default:
      mutation = .deduplicate(
        expectedPlanDigest: try fixture.database.projectDeduplicationPlan().planDigest,
        allowMetadataConflicts: false)
    }
    let change = try fixture.database.prepareProjectChange(mutation, expected: original)
    #expect(try fixture.database.configurationState() == original)
    let prepared = try await fixture.prepare(state: change.proposed)
    do {
      #expect(try fixture.database.configurationState() == original)
      var resolution = prepared.resolution
      if fail {
        let conflict = try #require(resolution.projects.first)
        var stale = conflict.original
        stale.bookmarkData = Data("stale".utf8)
        resolution.projects = [.init(original: stale, resolved: conflict.resolved)]
        #expect(throws: GatewayDatabaseError.configurationChanged) {
          try fixture.database.saveProjectChange(change, resolution: resolution)
        }
        #expect(try fixture.database.configurationState() == original)
      } else {
        let committed = try fixture.database.saveProjectChange(change, resolution: resolution)
        #expect(committed.projects.contains { $0.id == extra.id } == (operation == "register"))
        #expect(committed.profiles == original.profiles)
        #expect(
          committed.projects.first { $0.id == "fixture" }?.bookmarkData == Data("refreshed".utf8))
        #expect(committed.plugins == original.plugins)
        if operation == "deduplicate" {
          #expect(committed.projectAliases[extra.id] == "fixture")
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
    var proposed = original.plugins
    proposed.revision += 1
    let prepared = try await fixture.prepare(
      state: .init(
        projects: original.projects, projectAliases: original.projectAliases,
        profiles: original.profiles, plugins: proposed, profileSource: original.profileSource,
        derivedProjects: original.derivedProjects))
    do {
      var resolution = prepared.resolution
      if fail {
        let conflict = try #require(resolution.projects.first)
        var stale = conflict.original
        stale.bookmarkData = Data("stale".utf8)
        resolution.projects = [.init(original: stale, resolved: conflict.resolved)]
        #expect(throws: GatewayDatabaseError.configurationChanged) {
          try fixture.database.savePluginStoreSnapshot(
            proposed, expectedRevision: 0, expectedConfiguration: original, resolution: resolution)
        }
        #expect(try fixture.database.configurationState() == original)
      } else {
        let committed = try fixture.database.savePluginStoreSnapshot(
          proposed, expectedRevision: 0, expectedConfiguration: original, resolution: resolution)
        #expect(committed.plugins == proposed)
        #expect(committed.projects.first?.bookmarkData == Data("refreshed".utf8))
        #expect(committed.profiles == original.profiles)
        try prepared.runtime.requirePreparedPublication()
        prepared.runtime.publishPrepared()
        _ = try await prepared.runtime.callToolAsync(
          name: "project.list", arguments: .object([:]), context: .empty)
      }
      #expect(fixture.adapter.startCount - fixture.adapter.stopCount == 1)
      await prepared.runtime.shutdown()
    } catch {
      await prepared.runtime.shutdown()
      throw error
    }
    #expect(fixture.adapter.startCount == fixture.adapter.stopCount)
  }

  @Test(arguments: [false, true])
  func preparationDefersBookmarkAndPermissionWrites(fail: Bool) async throws {
    let fixture = try PreparationStateFixture()
    defer { fixture.cleanup() }
    let original = try fixture.database.configurationState()
    let state = GatewayDatabase.ConfigurationState(
      projects: fail ? original.projects + original.projects : original.projects,
      projectAliases: original.projectAliases, profiles: original.profiles,
      plugins: original.plugins)
    if fail {
      await #expect(throws: GatewayRuntimeError.duplicateProjectID("fixture")) {
        try await fixture.prepare(state: state)
      }
    } else {
      let prepared = try await fixture.prepare(state: state)
      do {
        #expect(try fixture.database.configurationState() == original)
        let project = try #require(prepared.resolution.projects.first)
        #expect(project.original == original.projects.first)
        #expect(project.resolved.bookmarkData == Data("refreshed".utf8))
        #expect(project.resolved.createdAt == project.original.createdAt)
        #expect(throws: GatewayToolError.self) {
          try prepared.runtime.authenticatedSession(principalID: "another", transportTrace: nil)
        }
        await #expect(throws: GatewayToolError.self) {
          try await prepared.runtime.callToolAsync(
            name: "project.list", arguments: .object([:]), context: .empty)
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
    database = try fixturePermissionDatabase(
      path: root.appendingPathComponent("gateway.sqlite").path)
    adapter = PreparationBookmarkAdapter(root: root, gated: gated)
    try database.saveProject(
      RegisteredProject(
        id: "fixture", displayName: "Fixture", rootPath: root.path,
        bookmarkData: Data("original".utf8), createdAt: Date(timeIntervalSince1970: 1000),
        updatedAt: Date(timeIntervalSince1970: 1000)))
    try database.saveProfile(
      ProfileGrant(
        id: .localAdmin, permissions: fixturePermissions([.project("fixture"): .granted(.read)]),
        allowedCallers: [.localCLI]))

  }

  func prepare(state: GatewayDatabase.ConfigurationState) async throws -> GatewayRuntimePreparation
  {
    try await GatewayRuntime.prepare(
      configuration: GatewayConfiguration(projectDirectory: root),
      context: ExecutionContext(
        caller: .localCLI, profileID: .localAdmin, projectID: "fixture",
        trustedPrincipalID: "preparation-fixture"),
      database: database, state: state,
      platform: PlatformServices(
        launcher: testExecutionLauncher(),
        projectGrants: ProjectBookmarkService(
          adapter: adapter, now: { Date(timeIntervalSince1970: 2000) }),
        pluginDirectories: MacOSPlatform.services(launcher: testExecutionLauncher())
          .pluginDirectories,
        applications: MacOSPlatform.services(launcher: testExecutionLauncher()).applications,
        toolProviders: MacOSPlatform.services(launcher: testExecutionLauncher()).toolProviders,
        managementToolNames: MacOSPlatform.services(launcher: testExecutionLauncher())
          .managementToolNames,
        executableSearchDirectories: MacOSPlatform.services(launcher: testExecutionLauncher())
          .executableSearchDirectories,
        gitExecutable: MacOSPlatform.services(launcher: testExecutionLauncher()).gitExecutable,
        fileChanges: MacOSPlatform.services(launcher: testExecutionLauncher()).fileChanges,
        permissionPolicyReader: TestManagedPolicyReader()),
      bundledPlugins: BundledPlugins(packages: [], issues: []))
  }

  func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private final class PreparationBookmarkAdapter: ProjectBookmarkAdapter, @unchecked Sendable {
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

  func resolveBookmark(_ data: Data) throws -> ProjectBookmarkResolution {
    lock.withLock { didStart = true }
    if gated { _ = release.wait(timeout: .now() + .seconds(15)) }
    return ProjectBookmarkResolution(url: root, isStale: true)
  }

  func startAccessing(_ url: URL) -> Bool {
    lock.withLock { starts += 1 }
    return true
  }

  func stopAccessing(_ url: URL) { lock.withLock { stops += 1 } }
}
