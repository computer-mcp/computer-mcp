import Darwin
import Foundation
import GRDB
import Testing

@testable import ComputerMCP

@Suite

final class GatewayDatabaseTests {
  @Test(arguments: ["unchanged", "edited", "deleted"])
  func bookmarkRefreshPreservesConcurrentRegistrationChanges(change: String) throws {
    let database = try GatewayDatabase(inMemory: ())
    try database.saveWorkspace(
      RegisteredWorkspace(
        id: "fixture", displayName: "Fixture", rootPath: "/tmp/bookmark-original",
        bookmarkData: Data([1]), bookmarkIsStale: true))
    let original = try #require(try database.workspace(id: "fixture"))
    var refreshed = original
    refreshed.bookmarkData = Data([2])
    refreshed.bookmarkIsStale = false
    refreshed.rootPath = "/tmp/bookmark-refreshed"
    if change == "edited" {
      var edited = original
      edited.displayName = "Owner edit"
      try database.saveWorkspace(edited)
    } else if change == "deleted" {
      try database.deleteWorkspace(id: original.id)
    }
    let before = try database.workspace(id: original.id)
    #expect(try database.saveWorkspace(refreshed, replacing: original) == (change == "unchanged"))
    #expect(try database.workspace(id: original.id) == (change == "unchanged" ? refreshed : before))
    if change == "unchanged" {
      let registration = try database.registerWorkspaceIdempotently(
        RegisteredWorkspace(displayName: "Alias", rootPath: refreshed.rootPath))
      #expect(!registration.created)
      #expect(registration.workspace.id == original.id)
    }
  }

  @Test
  func testInMemoryTestDatabaseHasNoProductionFilePath() throws {
    let database = try GatewayDatabase(inMemory: ())
    #expect(database.fileURL == nil)
  }

  @Test
  func testMCPGrantMigrationPreservesExistingProfileAuthority() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("gateway.sqlite").path
    let original = ProfileGrant(
      id: .chatGPTOperate, capabilityIDs: ["mcp.tools.call"], workspaceIDs: ["fixture"],
      allowedCallers: [.secureTunnel], mode: .workspaceOperations,
      confirmationPolicy: .allWrites)
    try GatewayDatabase(path: path).saveProfile(original)
    // Recreate the stored shape immediately preceding the registration-grant migration.
    let previous = try DatabaseQueue(path: path)
    try previous.write { database in
      try database.execute(sql: "ALTER TABLE profiles DROP COLUMN mcpServerIDsJSON")
      try database.execute(
        sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
        arguments: ["profile-mcp-server-grants"])
    }
    try previous.close()
    let migrated = try GatewayDatabase(path: path)
    #expect(try migrated.profiles() == [original])
    var granted = original
    granted.mcpServerIDs = ["fixture-mcp"]
    try migrated.saveProfile(granted)
    granted.authorizationRevision = original.authorizationRevision + 1
    #expect(try migrated.profiles() == [granted])
    #expect(try GatewayDatabase(path: path).profiles() == [granted])
  }

  @Test
  func testPersistsWorkspacesProfilesProvidersAndAuditWithoutPayloadContent() throws {
    let database = try GatewayDatabase(inMemory: ())
    let timestamp = Date(timeIntervalSince1970: 1_000)
    let workspace = RegisteredWorkspace(
      id: "workspace-1",
      displayName: "Example",
      rootPath: "/tmp/example",
      bookmarkData: Data([1, 2, 3]),
      createdAt: timestamp,
      updatedAt: timestamp
    )
    try database.saveWorkspace(workspace)

    let profile = ProfileGrant(
      id: .localAdmin,
      capabilityIDs: ["file.write", "shell.run"],
      workspaceIDs: [workspace.id],
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
      workspaceID: workspace.id,
      capabilityID: "file.write",
      decision: .allowed,
      inputDigest: "sha256:input",
      outputDigest: "sha256:output",
      outputByteCount: 12
    )
    try database.recordAudit(audit)

    #expect((try database.workspaces()) == ([workspace]))
    #expect((try database.profiles()) == ([profile]))
    #expect((try database.providerStates()) == ([provider]))
    #expect((try database.auditEvents()) == ([audit]))
  }

  @Test
  func testWorkspaceDeduplicationPreviewIsNonMutating() throws {
    let database = try GatewayDatabase(inMemory: ())
    let canonical = RegisteredWorkspace(
      id: "workspace-canonical",
      displayName: "Shared Workspace",
      rootPath: "/tmp/shared-workspace",
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1)
    )
    let duplicate = RegisteredWorkspace(
      id: "workspace-duplicate",
      displayName: "Shared Workspace",
      rootPath: canonical.rootPath,
      createdAt: Date(timeIntervalSince1970: 2),
      updatedAt: Date(timeIntervalSince1970: 2)
    )
    try database.saveWorkspace(canonical)
    try database.saveWorkspace(duplicate)

    let before = try database.workspaces()
    let first = try database.workspaceDeduplicationPlan()
    let second = try database.workspaceDeduplicationPlan()

    #expect(first == second)
    #expect(first.groups.count == 1)
    #expect(first.duplicateCount == 1)
    #expect(first.groups.first?.canonicalWorkspaceID == canonical.id)
    #expect(first.groups.first?.duplicateWorkspaceIDs == [duplicate.id])
    #expect(try database.workspaces() == before)
    #expect(try database.workspace(id: duplicate.id)?.id == duplicate.id)
  }

  @Test
  func testWorkspaceDeduplicationMigrationPreservesReferencesAndHistory() throws {
    let database = try GatewayDatabase(inMemory: ())
    let canonical = RegisteredWorkspace(
      id: "workspace-canonical",
      displayName: "Shared Workspace",
      rootPath: "/tmp/shared-workspace",
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1)
    )
    let duplicate = RegisteredWorkspace(
      id: "workspace-duplicate",
      displayName: "Shared Workspace",
      rootPath: canonical.rootPath,
      createdAt: Date(timeIntervalSince1970: 2),
      updatedAt: Date(timeIntervalSince1970: 2)
    )
    try database.saveWorkspace(canonical)
    try database.saveWorkspace(duplicate)
    var profile = ProfileGrant.operate
    profile.workspaceIDs = [duplicate.id]
    try database.saveProfile(profile)
    let historicalAudit = AuditEvent(
      id: "workspace-history",
      occurredAt: Date(timeIntervalSince1970: 3),
      requestID: "workspace-history",
      caller: .secureTunnel,
      profileID: .chatGPTOperate,
      workspaceID: duplicate.id,
      capabilityID: "file.read",
      decision: .allowed
    )
    try database.recordAudit(historicalAudit)
    let plan = try database.workspaceDeduplicationPlan()

    let result = try database.applyWorkspaceDeduplication(
      expectedPlanDigest: plan.planDigest,
      allowMetadataConflicts: false,
      now: Date(timeIntervalSince1970: 4)
    )

    #expect(result.canonicalWorkspaceIDs == [canonical.id])
    #expect(result.aliasedWorkspaceIDs == [duplicate.id])
    #expect(result.updatedProfileIDs == [GatewayProfileID.chatGPTOperate.rawValue])
    let workspaceIDs = try database.workspaces().map(\.id)
    let resolvedDuplicate = try database.workspace(id: duplicate.id)
    let storedProfile = try database.profiles().first
    let storedAudit = try database.auditEvent(requestID: historicalAudit.requestID)
    let postApplyPlan = try database.workspaceDeduplicationPlan()
    #expect(workspaceIDs == [canonical.id])
    #expect(resolvedDuplicate?.id == canonical.id)
    #expect(storedProfile?.workspaceIDs == [canonical.id])
    #expect(storedAudit == historicalAudit)
    #expect(postApplyPlan.groups.isEmpty)
  }

  @Test
  func testWorkspaceCanonicalRootBindingTracksAnUpdatedRegistration() throws {
    let database = try GatewayDatabase(inMemory: ())
    let original = RegisteredWorkspace(
      id: "workspace-moving",
      displayName: "Moving Workspace",
      rootPath: "/tmp/workspace-original"
    )
    try database.saveWorkspace(original)
    var moved = original
    moved.rootPath = "/tmp/workspace-moved"
    moved.updatedAt = moved.updatedAt.addingTimeInterval(1)
    try database.saveWorkspace(moved)

    let replacement = RegisteredWorkspace(
      id: "workspace-replacement",
      displayName: "Replacement Workspace",
      rootPath: original.rootPath
    )
    let registration = try database.registerWorkspaceIdempotently(replacement)

    #expect(registration.created)
    #expect(registration.workspace.id == replacement.id)
    #expect(try database.workspace(id: original.id)?.rootPath == moved.rootPath)
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
      workspaceID: "workspace-1",
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
