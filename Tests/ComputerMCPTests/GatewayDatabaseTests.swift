import Darwin
import Foundation
import Testing

@testable import ComputerMCP

@Suite

final class GatewayDatabaseTests {
  @Test
  func testInMemoryTestDatabaseHasNoProductionFilePath() throws {
    let database = try GatewayDatabase(inMemory: ())
    #expect(database.fileURL == nil)
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
      fullShellEnabled: true
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
  func testOperationTicketExpiryFailsPreparedTicket() throws {
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
    #expect((stored.state) == (.failed))
    #expect((stored.completedAt) == (now))
    #expect((stored.failureCode) == ("operations.ticket_expired"))
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

  @Test
  func testPersistsCodexApprovalAndRuntimeOwnershipReceipts() throws {
    let database = try GatewayDatabase(inMemory: ())
    let timestamp = Date(timeIntervalSince1970: 2_000)
    let owner = CodexRuntimeOwner(
      workspaceID: "workspace-1",
      profileID: "local-admin",
      caller: "local-mcp",
      transport: "gateway_socket",
      socketConnectionID: "socket-1",
      tunnelInstanceID: nil,
      tunnelProfileID: nil
    )
    let approval = CodexApprovalRecord(
      id: "approval-1",
      upstreamRequestID: "n:1",
      kind: .fileChange,
      risk: .workspaceWrite,
      state: .pending,
      workspaceID: "workspace-1",
      workspacePath: "/tmp/workspace-1",
      runtimeID: "runtime-1",
      threadID: "thread-1",
      turnID: "turn-1",
      itemID: "item-1",
      correlationID: "correlation-1",
      socketConnectionID: "socket-1",
      tunnelInstanceID: nil,
      details: .object(["reason": .string("credential=[REDACTED]")]),
      proposedAction: .object(["kind": .string("file_change")]),
      createdAt: timestamp,
      expiresAt: timestamp.addingTimeInterval(300),
      resolvedAt: nil,
      decision: nil,
      scope: nil,
      resolutionReason: nil
    )
    try database.saveCodexApproval(approval)

    let lease = CodexRuntimeLeaseRecord(
      id: "runtime-1",
      owner: owner,
      workspacePath: "/tmp/workspace-1",
      state: "stopped",
      process: CodexAppServerProcessSnapshot(
        state: .stopped,
        processID: 123,
        supervisorProcessID: 122,
        parentProcessID: 121,
        processGroupID: 123,
        startedAt: timestamp,
        stoppedAt: timestamp.addingTimeInterval(1),
        exitCode: 0,
        signal: nil,
        terminationEscalated: false,
        lastError: nil
      ),
      createdAt: timestamp,
      updatedAt: timestamp.addingTimeInterval(1),
      shutdownReason: "requested",
      cleanedAt: nil
    )
    try database.saveCodexRuntimeLease(lease)

    let ownership = CodexThreadOwnershipRecord(
      threadID: "thread-1",
      workspaceID: "workspace-1",
      workspacePath: "/tmp/workspace-1",
      runtimeID: "runtime-1",
      state: .released,
      createdAt: timestamp,
      updatedAt: timestamp.addingTimeInterval(1)
    )
    try database.saveCodexThreadOwnership(ownership)

    #expect(try database.codexApproval(id: approval.id) == approval)
    #expect(try database.codexApprovals(workspaceID: "workspace-1") == [approval])
    #expect(try database.codexRuntimeLeases() == [lease])
    #expect(try database.codexThreadOwnership(threadID: ownership.threadID) == ownership)
    #expect(try database.codexThreadOwnerships(workspaceID: "workspace-1") == [ownership])
  }

  @Test
  func testStaleOwnershipReconciliationIsReviewedAndNeverSignalsAProcess() throws {
    let database = try GatewayDatabase(inMemory: ())
    let now = Date(timeIntervalSince1970: 5_000)
    let stale = CodexThreadOwnershipRecord(
      threadID: "thread-stale",
      workspaceID: "workspace-1",
      workspacePath: "/tmp/workspace-1",
      runtimeID: "runtime-gone",
      state: .loaded,
      createdAt: now,
      updatedAt: now
    )
    try database.saveCodexThreadOwnership(stale)

    let plan = try CodexThreadOwnershipReconciliation.preview(
      database: database,
      workspaceID: "workspace-1"
    )
    #expect(plan.candidates.map(\.threadID) == [stale.threadID])
    #expect(!plan.signalsSent)
    #expect(!plan.externalStateMutated)
    #expect(try database.codexThreadOwnership(threadID: stale.threadID)?.state == .loaded)

    let result = try CodexThreadOwnershipReconciliation.apply(
      database: database,
      expectedPlanDigest: plan.planDigest,
      workspaceID: "workspace-1",
      now: now.addingTimeInterval(1)
    )
    #expect(result.releasedThreadIDs == [stale.threadID])
    #expect(!result.signalsSent)
    #expect(!result.externalStateMutated)
    #expect(try database.codexThreadOwnership(threadID: stale.threadID)?.state == .released)
  }

  @Test
  func testOwnershipReconciliationPreservesReceiptWhileRecordedProcessIsAlive() throws {
    let database = try GatewayDatabase(inMemory: ())
    let now = Date()
    let runtimeID = "runtime-live-process"
    try database.saveCodexRuntimeLease(
      CodexRuntimeLeaseRecord(
        id: runtimeID,
        owner: CodexRuntimeOwner(
          workspaceID: "workspace-1",
          profileID: "profile-1",
          caller: "local-mcp",
          transport: "fixture",
          socketConnectionID: nil,
          tunnelInstanceID: nil,
          tunnelProfileID: nil
        ),
        workspacePath: "/tmp/workspace-1",
        state: "running",
        process: CodexAppServerProcessSnapshot(
          state: .running,
          processID: getpid(),
          supervisorProcessID: nil,
          parentProcessID: getppid(),
          processGroupID: getpgrp(),
          startedAt: now,
          stoppedAt: nil,
          exitCode: nil,
          signal: nil,
          terminationEscalated: false,
          lastError: nil
        ),
        createdAt: now,
        updatedAt: now,
        shutdownReason: nil,
        cleanedAt: nil
      )
    )
    try database.saveCodexThreadOwnership(
      CodexThreadOwnershipRecord(
        threadID: "thread-live-process",
        workspaceID: "workspace-1",
        workspacePath: "/tmp/workspace-1",
        runtimeID: runtimeID,
        state: .loaded,
        createdAt: now,
        updatedAt: now
      )
    )

    let plan = try CodexThreadOwnershipReconciliation.preview(
      database: database,
      workspaceID: "workspace-1"
    )
    #expect(plan.candidates.isEmpty)
    #expect(!plan.signalsSent)
  }

  @Test
  func testPreSplitRequestTimeoutIsReconciledWithoutTerminalRuntimeReason() throws {
    let database = try GatewayDatabase(inMemory: ())
    let now = Date(timeIntervalSince1970: 6_000)
    try database.saveCodexRuntimeLease(
      CodexRuntimeLeaseRecord(
        id: "pre-split-runtime",
        owner: nil,
        workspacePath: "/tmp/workspace-1",
        state: "running",
        process: nil,
        createdAt: now,
        updatedAt: now,
        shutdownReason: "request_timeout",
        cleanedAt: nil
      )
    )

    let reconciled = try #require(try database.codexRuntimeLeases().first)
    #expect(reconciled.runtimeState == "running")
    #expect(reconciled.shutdownReason == nil)
    #expect(reconciled.lastRequestFailure?.kind == "request_timeout")
    #expect(reconciled.lastRequestFailure?.recoverable == true)
  }

  @Test
  func testReviewedRuntimeCleanupOnlyTransitionsDeadStaleReceipts() async throws {
    let database = try GatewayDatabase(inMemory: ())
    let now = Date()
    let owner = CodexRuntimeOwner(
      workspaceID: "workspace-cleanup",
      profileID: "local-admin",
      caller: "local-mcp",
      transport: "fixture",
      socketConnectionID: nil,
      tunnelInstanceID: nil,
      tunnelProfileID: nil
    )
    let process = CodexAppServerProcessSnapshot(
      state: .running,
      processID: Int32.max - 1,
      supervisorProcessID: Int32.max - 2,
      parentProcessID: Int32.max - 3,
      processGroupID: Int32.max - 1,
      startedAt: now,
      stoppedAt: nil,
      exitCode: nil,
      signal: nil,
      terminationEscalated: false,
      lastError: nil
    )
    try database.saveCodexRuntimeLease(
      CodexRuntimeLeaseRecord(
        id: "stale-runtime",
        owner: owner,
        workspacePath: "/tmp/workspace-cleanup",
        state: "running",
        process: process,
        createdAt: now,
        updatedAt: now,
        shutdownReason: nil,
        cleanedAt: nil
      )
    )

    let preview = try CodexRuntimeMaintenance.preview(
      database: database,
      workspaceID: owner.workspaceID
    )
    #expect(
      preview.objectValue?["candidates"]?.arrayValue?.first?.objectValue?["cleanup_ready"]
        == .bool(true))
    let result = try await CodexRuntimeMaintenance.cleanup(
      database: database,
      workspaceID: owner.workspaceID
    )
    #expect(result.objectValue?["cleaned"]?.arrayValue?.count == 1)
    #expect(try database.codexRuntimeLeases().first?.state == "cleaned")
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
