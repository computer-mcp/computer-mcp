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
      for (id, date) in [("canonical", 1.0), ("duplicate", 2.0)] {
        try database.saveProject(
          RegisteredProject(
            id: id, displayName: "Shared", rootPath: root.path,
            createdAt: Date(timeIntervalSince1970: date)))
      }
      if removing {
        let plan = try database.projectDeduplicationPlan()
        _ = try database.applyProjectDeduplication(
          expectedPlanDigest: plan.planDigest, allowMetadataConflicts: false)
      }
      var profile = ProfileGrant.operate
      profile.projectIDs = ["duplicate"]
      try database.saveProfile(profile)
      let before = try database.configurationState()
      let plan = try database.projectDeduplicationPlan()
      let pending = OperationTicket(
        id: "pending", capabilityID: "file.trash", caller: .secureTunnel,
        profileID: profile.id, inputDigest: "fixture", state: .approved,
        expiresAt: Date().addingTimeInterval(3_600))
      try database.saveOperationTicket(pending)
      let ticket = try #require(try database.operationTicket(id: pending.id))
      let connection = try DatabaseQueue(path: path)
      defer { try? connection.close() }
      if rollback {
        try connection.write {
          let operation =
            removing ? "DELETE ON projects" : "INSERT ON projectDeduplicationReceipts"
          try $0.execute(
            sql: """
              CREATE TRIGGER refuse_mutation BEFORE \(operation)
              BEGIN SELECT RAISE(ABORT, 'fixture receipt failure'); END
              """)
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
      } catch is DatabaseError {
        #expect(rollback)
      }
      if rollback {
        #expect(try database.configurationState() == before)
        #expect(try database.operationTicket(id: "pending") == ticket)
      } else {
        #expect(try database.profiles().first?.projectIDs == (removing ? [] : ["canonical"]))
        #expect(try database.operationTicket(id: "pending")?.state == .denied)
        #expect(try database.projects().map(\.id) == (removing ? [] : ["canonical"]))
      }
      let receipts = try connection.read {
        try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM projectDeduplicationReceipts")
      }
      #expect(receipts == (rollback && !removing ? 0 : 1))
      return stream
    }()
    // Database destruction finishes the stream, making absence of a rollback event deterministic.
    var notifications = 0
    for await _ in stream { notifications += 1 }
    #expect(notifications == (rollback ? 0 : 1))
  }

  @Test(arguments: [false, true], ["profile", "bookmark", "plugin"])
  func projectTransactionsRejectChangedPreparationInputs(removing: Bool, change: String) throws {
    let database = try GatewayDatabase(inMemory: ())
    for (id, date) in [("canonical", 1.0), ("duplicate", 2.0)] {
      try database.saveProject(
        RegisteredProject(
          id: id, displayName: "Shared", rootPath: "/tmp/shared-project",
          createdAt: Date(timeIntervalSince1970: date)))
    }
    var profile = ProfileGrant.operate
    profile.projectIDs = ["duplicate"]
    try database.saveProfile(profile)
    let expected = try database.configurationState()
    let plan = try database.projectDeduplicationPlan()
    switch change {
    case "profile":
      profile.capabilityIDs = ["project.list"]
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
    for (id, date) in [("canonical", 1.0), ("duplicate", 2.0)] {
      try database.saveProject(
        RegisteredProject(
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
      RegisteredProject(displayName: "Shared", rootPath: root.path))
    #expect(!existing.created)
    #expect(existing.project.id == "canonical")
    var moved = existing.project
    moved.rootPath = root.appendingPathComponent("moved").path
    try database.saveProject(moved)
    let replacement = try database.registerProjectIdempotently(
      RegisteredProject(id: "replacement", displayName: "New", rootPath: root.path))
    #expect(replacement.created)
    #expect(replacement.project.id == "replacement")
    #expect(try database.project(id: "duplicate")?.rootPath == moved.rootPath)
  }

  @Test
  func projectDeduplicationRevokesTicketsOnceAndPreservesCanonicalRegistration() throws {
    let database = try GatewayDatabase(inMemory: ())
    for id in ["a", "b"] {
      for (suffix, date) in [("duplicate", 2.0), ("canonical", 1.0)] {
        try database.saveProject(
          RegisteredProject(
            id: "\(id)-\(suffix)", displayName: id, rootPath: "/tmp/dedup-\(id)",
            createdAt: Date(timeIntervalSince1970: date)))
      }
    }
    var profile = ProfileGrant.operate
    profile.projectIDs = ["a-duplicate", "b-duplicate", "unrelated"]
    try database.saveProfile(profile)
    let before = try #require(try database.profiles().first)
    let states: [OperationTicketState] = [
      .prepared, .pendingApproval, .approved, .executing, .succeeded,
    ]
    for state in states {
      try database.saveOperationTicket(
        OperationTicket(
          id: state.rawValue, capabilityID: "file.trash", caller: .secureTunnel,
          profileID: profile.id, projectID: "a-duplicate", inputDigest: "fixture",
          state: state, expiresAt: Date().addingTimeInterval(60),
          authorizationRevision: before.authorizationRevision))
    }
    try database.saveOperationTicket(
      OperationTicket(
        id: "other-profile", capabilityID: "file.trash", caller: .secureTunnel,
        profileID: .chatGPTObserve, inputDigest: "fixture", state: .approved,
        expiresAt: Date().addingTimeInterval(60)))
    let plan = try database.projectDeduplicationPlan()
    let result = try database.applyProjectDeduplication(
      expectedPlanDigest: plan.planDigest, allowMetadataConflicts: false)
    let saved = try #require(try database.profiles().first)
    #expect(saved.authorizationRevision == before.authorizationRevision + 1)
    #expect(saved.projectIDs == ["a-canonical", "b-canonical", "unrelated"])
    #expect(result.updatedProfileIDs == [profile.id.rawValue])
    for state in states {
      let ticket = try #require(try database.operationTicket(id: state.rawValue))
      if [.prepared, .pendingApproval, .approved].contains(state) {
        #expect(ticket.state == .denied)
        #expect(ticket.failureCode == "operations.authorization_changed")
      } else {
        #expect(ticket.state == state)
      }
    }
    #expect(try database.operationTicket(id: "other-profile")?.state == .approved)
    for id in ["a", "b"] {
      let registration = try database.registerProjectIdempotently(
        RegisteredProject(displayName: id, rootPath: "/tmp/dedup-\(id)"))
      #expect(!registration.created)
      #expect(registration.project.id == "\(id)-canonical")
    }
  }

  @Test
  func configurationSnapshotAllowsUnrelatedRuntimeEvidenceDuringCommit() throws {
    let database = try GatewayDatabase(inMemory: ())
    try database.saveProject(
      RegisteredProject(id: "fixture", displayName: "Fixture", rootPath: "/tmp/fixture"))
    try database.saveProfile(
      ProfileGrant(
        id: .localAdmin, capabilityIDs: ["project.list"], projectIDs: ["fixture"],
        allowedCallers: [.localCLI]))
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
      RegisteredProject(
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
        RegisteredProject(displayName: "Alias", rootPath: refreshed.rootPath))
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
    let timestamp = Date(timeIntervalSince1970: 1_000)
    let project = RegisteredProject(
      id: "project-1",
      displayName: "Example",
      rootPath: "/tmp/example",
      bookmarkData: Data([1, 2, 3]),
      createdAt: timestamp,
      updatedAt: timestamp
    )
    try database.saveProject(project)

    let profile = ProfileGrant(
      id: .localAdmin,
      capabilityIDs: ["file.write", "shell.run"],
      projectIDs: [project.id],
      allowedCallers: [],
      fullShellEnabled: true,
      mcpServerIDs: ["sample-mcp"],
      mode: .localFullAccess
    )
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
    let canonical = RegisteredProject(
      id: "project-canonical",
      displayName: "Shared Project",
      rootPath: "/tmp/shared-project",
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1)
    )
    let duplicate = RegisteredProject(
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
    let canonical = RegisteredProject(
      id: "project-canonical",
      displayName: "Shared Project",
      rootPath: "/tmp/shared-project",
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1)
    )
    let duplicate = RegisteredProject(
      id: "project-duplicate",
      displayName: "Shared Project",
      rootPath: canonical.rootPath,
      createdAt: Date(timeIntervalSince1970: 2),
      updatedAt: Date(timeIntervalSince1970: 2)
    )
    try database.saveProject(canonical)
    try database.saveProject(duplicate)
    var profile = ProfileGrant.operate
    profile.projectIDs = [duplicate.id]
    try database.saveProfile(profile)
    let historicalAudit = AuditEvent(
      id: "project-history",
      occurredAt: Date(timeIntervalSince1970: 3),
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
      now: Date(timeIntervalSince1970: 4)
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
    #expect(storedProfile?.projectIDs == [canonical.id])
    #expect(storedAudit == historicalAudit)
    #expect(postApplyPlan.groups.isEmpty)
  }

  @Test
  func testProjectCanonicalRootBindingTracksAnUpdatedRegistration() throws {
    let database = try GatewayDatabase(inMemory: ())
    let original = RegisteredProject(
      id: "project-moving",
      displayName: "Moving Project",
      rootPath: "/tmp/project-original"
    )
    try database.saveProject(original)
    var moved = original
    moved.rootPath = "/tmp/project-moved"
    moved.updatedAt = moved.updatedAt.addingTimeInterval(1)
    try database.saveProject(moved)

    let replacement = RegisteredProject(
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
  func testOperationTicketLifecycleIsSingleUseAndRecordsSuccess() throws {
    let database = try GatewayDatabase(inMemory: ())
    let now = Date(timeIntervalSince1970: 1_000)
    let ticket = OperationTicket(
      id: "ticket-1",
      capabilityID: "file.trash",
      caller: .secureTunnel,
      profileID: .chatGPTOperate,
      projectID: "project-1",
      inputDigest: "sha256:input",
      expiresAt: now.addingTimeInterval(30)
    )
    try database.saveOperationTicket(ticket)

    let executing = try database.beginOperationTicket(
      id: ticket.id,
      principalID: ticket.principalID,
      invocationID: "invocation-1",
      parentRequestID: "commit-request-1",
      at: now
    )
    #expect((executing.state) == (.executing))
    #expect((executing.invocationID) == ("invocation-1"))
    #expect((executing.parentRequestID) == ("commit-request-1"))
    #expect((executing.executingAt) == (now))

    let succeeded = try database.finishOperationTicket(
      id: ticket.id,
      invocationID: "invocation-1",
      state: .succeeded,
      at: now.addingTimeInterval(1)
    )
    #expect((succeeded.state) == (.succeeded))
    #expect((succeeded.completedAt) == (now.addingTimeInterval(1)))
    #expect((succeeded.failureCode) == nil)

    expectThrows(
      try database.beginOperationTicket(
        id: ticket.id,
        principalID: ticket.principalID,
        invocationID: "invocation-2",
        parentRequestID: "commit-request-2",
        at: now
      )
    ) { error in
      guard case GatewayDatabaseError.operationTicketUnavailable = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
    }
  }

  @Test
  func testOperationTicketExpiryRecordsExpiredState() throws {
    let database = try GatewayDatabase(inMemory: ())
    let now = Date(timeIntervalSince1970: 1_000)
    let expired = OperationTicket(
      id: "ticket-2",
      capabilityID: "file.trash",
      caller: .secureTunnel,
      profileID: .chatGPTOperate,
      inputDigest: "sha256:expired",
      expiresAt: now.addingTimeInterval(-1)
    )
    try database.saveOperationTicket(expired)
    expectThrows(
      try database.beginOperationTicket(
        id: expired.id,
        principalID: expired.principalID,
        invocationID: "expired-invocation",
        parentRequestID: "expired-request",
        at: now
      )
    ) { error in
      #expect((error as? GatewayDatabaseError) == (.operationTicketExpired(expired.id)))
    }
    let stored = try #require(try database.operationTicket(id: expired.id))
    #expect((stored.state) == (.expired))
    #expect((stored.completedAt) == (now))
    #expect((stored.failureCode) == ("operations.ticket_expired"))
    #expect(stored.invocationID == nil)
    #expect(stored.executingAt == nil)
  }

  @Test
  func testConcurrentOperationTicketClaimAllowsExactlyOneInvocation() throws {
    let database = try GatewayDatabase(inMemory: ())
    let now = Date(timeIntervalSince1970: 1_000)
    let ticket = OperationTicket(
      id: "ticket-concurrent",
      capabilityID: "file.trash",
      caller: .secureTunnel,
      profileID: .chatGPTOperate,
      inputDigest: "sha256:concurrent",
      expiresAt: now.addingTimeInterval(30)
    )
    try database.saveOperationTicket(ticket)
    let claims = ConcurrentTicketClaims()

    DispatchQueue.concurrentPerform(iterations: 2) { index in
      let invocationID = "invocation-\(index)"
      do {
        _ = try database.beginOperationTicket(
          id: ticket.id,
          principalID: ticket.principalID,
          invocationID: invocationID,
          parentRequestID: "request-\(index)",
          at: now
        )
        claims.recordSuccess(invocationID)
      } catch {
        claims.recordFailure(error)
      }
    }

    #expect((claims.successes.count) == (1))
    #expect((claims.failures.count) == (1))
    guard let failure = claims.failures.first as? GatewayDatabaseError,
      case .operationTicketUnavailable = failure
    else {
      Issue.record("Expected the losing claim to observe an unavailable ticket.")
      return
    }
    #expect((try database.operationTicket(id: ticket.id)?.invocationID) == (claims.successes.first))
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
    let target = AuditEvent(
      id: "audit-target",
      occurredAt: Date(timeIntervalSince1970: 1),
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
          occurredAt: Date(timeIntervalSince1970: TimeInterval(index + 2)),
          requestID: "gateway-request-\(index)",
          caller: .secureTunnel,
          profileID: .chatGPTOperate,
          capabilityID: "codex.app.events.read",
          decision: .allowed
        )
      )
    }

    #expect((try database.auditEvent(requestID: target.requestID)) == (target))
    #expect((try database.auditEvent(requestID: "missing-request")) == nil)
  }

}

private final class ConcurrentTicketClaims: @unchecked Sendable {
  private let lock = NSLock()
  private var storedSuccesses: [String] = []
  private var storedFailures: [Error] = []

  var successes: [String] {
    lock.withLock { storedSuccesses }
  }

  var failures: [Error] {
    lock.withLock { storedFailures }
  }

  func recordSuccess(_ invocationID: String) {
    lock.withLock {
      storedSuccesses.append(invocationID)
    }
  }

  func recordFailure(_ error: Error) {
    lock.withLock {
      storedFailures.append(error)
    }
  }
}
