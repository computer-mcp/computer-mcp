import ComputerMCPPermissions
import ComputerMCPTestSupport
import Foundation
import GRDB
import Testing

@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPersistence
@testable import ComputerMCPPlugins

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

@Suite

final class GatewayDatabaseTests {
  @Test func bootstrapPreservesLiveEditsAndLeavesRecoveryForTheOwner() throws {
    let database = try GatewayDatabase(inMemory: ())
    let counter = TestAuthorizationEpochCounter()
    let store = database.permissionStore(counter: counter)
    try database.bootstrapPermissionProfiles([.operate])
    var edited = try #require(database.profiles().first)
    try edited.permissions.set(.denied, for: .screen)
    try database.saveProfile(edited, expectedRevision: edited.authorizationRevision)
    let before = try #require(database.profiles().first)
    try database.bootstrapPermissionProfiles([.operate])
    #expect(try database.profiles() == [before])
    let initialEpoch = try store.readWithDatabase { _, ledger in ledger.authorizationEpochID }
    counter.forget()
    let missing = ProfileGrant.newPrincipal(id: .chatGPTObserve, allowedCallers: [.secureTunnel])
    try database.bootstrapPermissionProfiles([.operate, missing])
    #expect(try database.profiles() == [before])
    try store.readWithDatabase { (database: Database, ledger: PermissionLedger) throws -> Void in
      #expect(ledger.authorizationEpochID != initialEpoch)
      #expect(ledger.suspendedAuthority != nil)
      #expect(
        try ProfileRecord.fetchOne(database, key: before.id.rawValue)?.authorityEpoch
          == initialEpoch?.uuidString)
    }
  }

  @Test(arguments: [false, true], [false, true])
  func projectMutationsPublishOnlyCommittedAuthorization(rollback: Bool, removing: Bool)
    async throws
  {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("state.sqlite").path
    let stream = try { () -> AsyncStream<Void> in
      let database = try GatewayDatabase(path: path)
      let store = database.permissionStore(counter: TestAuthorizationEpochCounter())
      for (id, date) in [("canonical", 1.0), ("duplicate", 2.0)] {
        try database.saveProject(
          ComputerMCPCore.RegisteredProject(
            id: id, displayName: "Shared", rootPath: root.path,
            createdAt: Date(timeIntervalSince1970: date)))
      }
      if removing {
        let plan = try database.projectDeduplicationPlan()
        _ = try database.applyProjectDeduplication(
          expectedPlanDigest: plan.planDigest, allowMetadataConflicts: false)
      }
      var profile = ProfileGrant.operate
      try profile.permissions.set(.granted(.write), for: .project("duplicate"))
      try database.saveProfile(profile)
      let service = GatewayPermissionService(store: store, policyReader: TestManagedPolicyReader())
      let subject = try GatewayPermissionSubject(
        context: .init(
          caller: .secureTunnel, profileID: profile.id, trustedPrincipalID: "fixture"))
      let requirements = try InvocationRequirements(actions: [
        .init(requirement: .init(.project("duplicate"), .read))
      ])
      guard
        case .allowed(let authorization) = try service.admit(
          subject: subject, tool: "fixture", projectID: "duplicate", argumentsDigest: "digest",
          requirements: requirements)
      else { throw GatewayDatabaseError.configurationChanged }
      let execution = try store.transactionWithDatabase { _, ledger in
        try ledger.startExecution(owner: subject.principal, authorizationIDs: [authorization.id])
      }
      let before = try database.configurationState()
      let plan = try database.projectDeduplicationPlan()
      let connection = try DatabaseQueue(path: path)
      defer { try? connection.close() }
      if rollback {
        try connection.write {
          let operation = removing ? "DELETE ON projects" : "INSERT ON projectDeduplicationReceipts"
          try $0.execute(
            sql:
              "CREATE TRIGGER refuse_mutation BEFORE \(operation) BEGIN SELECT RAISE(ABORT, 'fixture'); END"
          )
        }
      }
      let stream = database.profileChanges(for: profile.id)
      do {
        if removing {
          try database.removeProject(id: "duplicate", expectedConfiguration: before)
        } else {
          _ = try database.applyProjectDeduplication(
            expectedPlanDigest: plan.planDigest, allowMetadataConflicts: false)
        }
        #expect(!rollback)
      } catch is DatabaseError { #expect(rollback) }
      if rollback {
        #expect(try database.configurationState() == before)
      } else {
        let saved = try #require(database.profiles().first)
        #expect(saved.permissions.entries[.project("duplicate")] == nil)
        #expect(
          saved.permissions.state(for: .project("canonical"))
            == (removing ? .notGranted : .granted(.write)))
      }
      #expect(
        try store.readWithDatabase { _, ledger in
          ledger.pendingRevocations.executionsToTerminate.contains(execution.id)
        } == !rollback)
      return stream
    }()
    var notifications = 0
    for await _ in stream { notifications += 1 }
    #expect(notifications == (rollback ? 0 : 1))
  }

  @Test(arguments: [false, true], ["profile", "bookmark", "plugin"])
  func projectTransactionsRejectChangedPreparationInputs(removing: Bool, change: String) throws {
    let database = try GatewayDatabase(inMemory: ())
    for (id, date) in [("canonical", 1.0), ("duplicate", 2.0)] {
      try database.saveProject(
        ComputerMCPCore.RegisteredProject(
          id: id, displayName: "Shared", rootPath: "/tmp/shared-project",
          createdAt: Date(timeIntervalSince1970: date)))
    }
    var profile = ProfileGrant.operate
    try profile.permissions.set(.granted(.write), for: .project("duplicate"))
    try database.saveProfile(profile)
    let expected = try database.configurationState()
    let plan = try database.projectDeduplicationPlan()
    switch change {
    case "profile":
      try profile.permissions.set(.denied, for: .screen)
      try database.saveProfile(profile)
    case "bookmark":
      var project = try #require(try database.project(id: "canonical"))
      project.bookmarkData = Data([1, 2, 3])
      try database.saveProject(project)
    default:
      var plugins = expected.plugins
      plugins.revision += 1
      try database.savePluginStoreSnapshot(plugins, expectedRevision: expected.plugins.revision)
    }
    let changed = try database.configurationState()
    #expect(throws: GatewayDatabaseError.configurationChanged) {
      if removing {
        try database.removeProject(id: "duplicate", expectedConfiguration: expected)
      } else {
        _ = try database.applyProjectDeduplication(
          expectedPlanDigest: plan.planDigest, allowMetadataConflicts: false,
          expectedConfiguration: expected)
      }
    }
    #expect(try database.configurationState() == changed)
  }

  @Test
  func historicalAliasRootBindingUsesCurrentCanonicalRegistration() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("state.sqlite").path
    let database = try GatewayDatabase(path: path)
    _ = database.permissionStore(counter: TestAuthorizationEpochCounter())
    for (id, date) in [("canonical", 1.0), ("duplicate", 2.0)] {
      try database.saveProject(
        ComputerMCPCore.RegisteredProject(
          id: id, displayName: "Shared", rootPath: root.path,
          createdAt: Date(timeIntervalSince1970: date)))
    }
    let plan = try database.projectDeduplicationPlan()
    _ = try database.applyProjectDeduplication(
      expectedPlanDigest: plan.planDigest, allowMetadataConflicts: false)
    let connection = try DatabaseQueue(path: path)
    defer { try? connection.close() }
    try connection.write {
      try $0.execute(sql: "UPDATE projectCanonicalRoots SET projectID = 'duplicate'")
    }
    let existing = try database.registerProjectIdempotently(
      ComputerMCPCore.RegisteredProject(displayName: "Shared", rootPath: root.path))
    #expect(!existing.created)
    #expect(existing.project.id == "canonical")
    var moved = existing.project
    moved.rootPath = root.appendingPathComponent("moved").path
    try database.saveProject(moved)
    let replacement = try database.registerProjectIdempotently(
      ComputerMCPCore.RegisteredProject(id: "replacement", displayName: "New", rootPath: root.path))
    #expect(replacement.created)
    #expect(replacement.project.id == "replacement")
    #expect(try database.project(id: "duplicate")?.rootPath == moved.rootPath)
  }

  @Test func projectDeduplicationPreservesPermissionAndNetworkEntries() throws {
    let database = try GatewayDatabase(inMemory: ())
    for (id, date) in [("canonical", 1.0), ("duplicate", 2.0)] {
      try database.saveProject(
        ComputerMCPCore.RegisteredProject(
          id: id, displayName: "Shared", rootPath: "/tmp/shared-project",
          createdAt: Date(timeIntervalSince1970: date)))
    }
    var profile = ProfileGrant.operate
    try profile.permissions.set(.denied, for: .project("duplicate"))
    profile.projectNetworks["duplicate"] = .trusted
    try database.saveProfile(profile)
    let revision = try #require(database.profiles().first).authorizationRevision
    let plan = try database.projectDeduplicationPlan()
    _ = try database.applyProjectDeduplication(
      expectedPlanDigest: plan.planDigest, allowMetadataConflicts: false)
    let saved = try #require(database.profiles().first)
    #expect(saved.authorizationRevision == revision + 1)
    #expect(saved.permissions.entries[.project("duplicate")] == nil)
    #expect(saved.permissions.state(for: .project("canonical")) == .denied)
    #expect(saved.projectNetworks["canonical"]?.configuration == .trusted)
    #expect(saved.projectNetworks["duplicate"] == nil)
  }

  @Test
  func configurationSnapshotAllowsUnrelatedRuntimeEvidenceDuringCommit() throws {
    let database = try GatewayDatabase(inMemory: ())
    try database.saveProject(
      ComputerMCPCore.RegisteredProject(
        id: "fixture", displayName: "Fixture", rootPath: "/tmp/fixture"))
    try database.saveProfile(
      ProfileGrant(
        id: .localAdmin, allowedCallers: [.localCLI]))
    let expected = try database.configurationState()
    #expect(try expected.projects == database.projects())
    #expect(try expected.profiles == database.profiles())
    #expect(try expected.plugins == database.pluginStoreSnapshot())
    try database.saveProviderState(
      ProviderState(id: "fixture", kind: "mcp", health: "ready"))
    var next = expected.plugins
    next.revision += 1
    next.settings["candidate"] = PluginSettings(enabled: true)
    try database.savePluginStoreSnapshot(
      next, expectedRevision: expected.plugins.revision, expectedConfiguration: expected)
    #expect(try database.pluginStoreSnapshot() == next)
    #expect(try database.projects() == expected.projects)
    #expect(try database.profiles() == expected.profiles)
    #expect(try database.providerStates().count == 1)
  }

  @Test(arguments: ["unchanged", "edited", "deleted"])
  func bookmarkRefreshPreservesConcurrentRegistrationChanges(change: String) throws {
    let database = try GatewayDatabase(inMemory: ())
    try database.saveProject(
      ComputerMCPCore.RegisteredProject(
        id: "fixture", displayName: "Fixture", rootPath: "/tmp/bookmark-original",
        bookmarkData: Data([1]), bookmarkIsStale: true))
    let original = try #require(try database.project(id: "fixture"))
    var refreshed = original
    refreshed.bookmarkData = Data([2])
    refreshed.bookmarkIsStale = false
    refreshed.rootPath = "/tmp/bookmark-refreshed"
    if change == "edited" {
      var edited = original
      edited.displayName = "Owner edit"
      try database.saveProject(edited)
    } else if change == "deleted" {
      try database.deleteProject(id: original.id)
    }
    let before = try database.project(id: original.id)
    #expect(try database.saveProject(refreshed, replacing: original) == (change == "unchanged"))
    #expect(try database.project(id: original.id) == (change == "unchanged" ? refreshed : before))
    if change == "unchanged" {
      let registration = try database.registerProjectIdempotently(
        ComputerMCPCore.RegisteredProject(displayName: "Alias", rootPath: refreshed.rootPath))
      #expect(!registration.created)
      #expect(registration.project.id == original.id)
    }
  }

  @Test
  func testInMemoryTestDatabaseHasNoProductionFilePath() throws {
    let database = try GatewayDatabase(inMemory: ())
    #expect(database.fileURL == nil)
  }

  @Test
  func testPersistsProjectsProfilesProvidersAndAuditWithoutPayloadContent() throws {
    let database = try GatewayDatabase(inMemory: ())
    let timestamp = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) - 60)
    let project = ComputerMCPCore.RegisteredProject(
      id: "project-1",
      displayName: "Example",
      rootPath: "/tmp/example",
      bookmarkData: Data([1, 2, 3]),
      createdAt: timestamp,
      updatedAt: timestamp
    )
    try database.saveProject(project)

    var profile = ProfileGrant(id: .localAdmin, fullAccess: true, allowedCallers: [])
    try profile.permissions.set(.granted(.write), for: .project(project.id))
    try profile.permissions.set(.granted(.all), for: .mcpServer("sample-mcp"))
    profile.projectNetworks[project.id] = .trusted
    try database.saveProfile(profile)

    let provider = ProviderState(
      id: "codex-app-server",
      kind: "codex-app-server",
      executablePath: "/usr/local/bin/codex",
      observedVersion: "1.0",
      health: "ready",
      checkedAt: timestamp
    )
    try database.saveProviderState(provider)

    let audit = AuditEvent(
      occurredAt: timestamp,
      requestID: "request-1",
      mcpRequestID: "mcp-request-1",
      caller: .secureTunnel,
      transport: "gateway_socket",
      socketConnectionID: "socket-1",
      tunnelInstanceID: "tunnel-instance-1",
      tunnelProfileID: "computer-mcp",
      profileID: .chatGPTOperate,
      projectID: project.id,
      capabilityID: "file.write",
      decision: .allowed,
      inputDigest: "sha256:input",
      outputDigest: "sha256:output",
      outputByteCount: 12
    )
    try database.recordAudit(audit)

    #expect((try database.projects()) == ([project]))
    #expect((try database.profiles()) == ([profile]))
    #expect((try database.providerStates()) == ([provider]))
    #expect((try database.auditEvents()) == ([audit]))
  }

  @Test
  func testProjectDeduplicationPreviewIsNonMutating() throws {
    let database = try GatewayDatabase(inMemory: ())
    let canonical = ComputerMCPCore.RegisteredProject(
      id: "project-canonical",
      displayName: "Shared Project",
      rootPath: "/tmp/shared-project",
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1)
    )
    let duplicate = ComputerMCPCore.RegisteredProject(
      id: "project-duplicate",
      displayName: "Shared Project",
      rootPath: canonical.rootPath,
      createdAt: Date(timeIntervalSince1970: 2),
      updatedAt: Date(timeIntervalSince1970: 2)
    )
    try database.saveProject(canonical)
    try database.saveProject(duplicate)

    let before = try database.projects()
    let first = try database.projectDeduplicationPlan()
    let second = try database.projectDeduplicationPlan()

    #expect(first == second)
    #expect(first.groups.count == 1)
    #expect(first.duplicateCount == 1)
    #expect(first.groups.first?.canonicalProjectID == canonical.id)
    #expect(first.groups.first?.duplicateProjectIDs == [duplicate.id])
    #expect(try database.projects() == before)
    #expect(try database.project(id: duplicate.id)?.id == duplicate.id)
  }

  @Test
  func testProjectDeduplicationMigrationPreservesReferencesAndHistory() throws {
    let database = try GatewayDatabase(inMemory: ())
    let auditTime = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) - 60)
    let canonical = ComputerMCPCore.RegisteredProject(
      id: "project-canonical",
      displayName: "Shared Project",
      rootPath: "/tmp/shared-project",
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1)
    )
    let duplicate = ComputerMCPCore.RegisteredProject(
      id: "project-duplicate",
      displayName: "Shared Project",
      rootPath: canonical.rootPath,
      createdAt: Date(timeIntervalSince1970: 2),
      updatedAt: Date(timeIntervalSince1970: 2)
    )
    try database.saveProject(canonical)
    try database.saveProject(duplicate)
    var profile = ProfileGrant.operate
    try profile.permissions.set(.granted(.read), for: .project(duplicate.id))
    try database.saveProfile(profile)
    let historicalAudit = AuditEvent(
      id: "project-history",
      occurredAt: auditTime,
      requestID: "project-history",
      caller: .secureTunnel,
      profileID: .chatGPTOperate,
      projectID: duplicate.id,
      capabilityID: "file.read",
      decision: .allowed
    )
    try database.recordAudit(historicalAudit)
    let plan = try database.projectDeduplicationPlan()

    let result = try database.applyProjectDeduplication(
      expectedPlanDigest: plan.planDigest,
      allowMetadataConflicts: false,
      now: auditTime.addingTimeInterval(1)
    )

    #expect(result.canonicalProjectIDs == [canonical.id])
    #expect(result.aliasedProjectIDs == [duplicate.id])
    #expect(result.updatedProfileIDs == [GatewayProfileID.chatGPTOperate.rawValue])
    let projectIDs = try database.projects().map(\.id)
    let resolvedDuplicate = try database.project(id: duplicate.id)
    let storedProfile = try database.profiles().first
    let storedAudit = try database.auditEvent(requestID: historicalAudit.requestID)
    let postApplyPlan = try database.projectDeduplicationPlan()
    #expect(projectIDs == [canonical.id])
    #expect(resolvedDuplicate?.id == canonical.id)
    #expect(storedProfile?.permissions.state(for: .project(canonical.id)) == .granted(.read))
    #expect(storedProfile?.permissions.entries[.project(duplicate.id)] == nil)
    #expect(storedAudit == historicalAudit)
    #expect(postApplyPlan.groups.isEmpty)
  }

  @Test
  func testProjectCanonicalRootBindingTracksAnUpdatedRegistration() throws {
    let database = try GatewayDatabase(inMemory: ())
    let original = ComputerMCPCore.RegisteredProject(
      id: "project-moving",
      displayName: "Moving Project",
      rootPath: "/tmp/project-original"
    )
    try database.saveProject(original)
    var moved = original
    moved.rootPath = "/tmp/project-moved"
    moved.updatedAt = moved.updatedAt.addingTimeInterval(1)
    try database.saveProject(moved)

    let replacement = ComputerMCPCore.RegisteredProject(
      id: "project-replacement",
      displayName: "Replacement Project",
      rootPath: original.rootPath
    )
    let registration = try database.registerProjectIdempotently(replacement)

    #expect(registration.created)
    #expect(registration.project.id == replacement.id)
    #expect(try database.project(id: original.id)?.rootPath == moved.rootPath)
  }

  @Test
  func testRuntimeSettingsPersistAndReplaceValues() throws {
    let database = try GatewayDatabase(inMemory: ())

    #expect((try database.runtimeSetting(key: "active-gateway-profile")) == nil)
    try database.saveRuntimeSetting(
      key: "active-gateway-profile",
      value: GatewayProfileID.chatGPTObserve.rawValue
    )
    #expect(
      (try database.runtimeSetting(key: "active-gateway-profile"))
        == (GatewayProfileID.chatGPTObserve.rawValue))

    try database.saveRuntimeSetting(
      key: "active-gateway-profile",
      value: GatewayProfileID.chatGPTOperate.rawValue
    )
    #expect(
      (try database.runtimeSetting(key: "active-gateway-profile"))
        == (GatewayProfileID.chatGPTOperate.rawValue))
  }

  @Test
  func testFindsAuditEventByExactRequestIDBeyondBoundedRecentPage() throws {
    let database = try GatewayDatabase(inMemory: ())
    let timestamp = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) - 300)
    let target = AuditEvent(
      id: "audit-target",
      occurredAt: timestamp,
      requestID: "gateway-request-target",
      caller: .secureTunnel,
      profileID: .chatGPTOperate,
      capabilityID: "codex.app.status",
      decision: .allowed
    )
    try database.recordAudit(target)
    for index in 0..<250 {
      try database.recordAudit(
        AuditEvent(
          id: "audit-\(index)",
          occurredAt: timestamp.addingTimeInterval(TimeInterval(index + 1)),
          requestID: "gateway-request-\(index)",
          caller: .secureTunnel,
          profileID: .chatGPTOperate,
          capabilityID: "codex.app.events.read",
          decision: .allowed
        )
      )
    }

    let recent = try database.auditEvents()
    #expect(recent.count == 200)
    #expect(!recent.contains { $0.requestID == target.requestID })
    #expect((try database.auditEvent(requestID: target.requestID)) == (target))
    #expect((try database.auditEvent(requestID: "missing-request")) == nil)
  }

}
