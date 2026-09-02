import Foundation
import Testing

@testable import ComputerMCP

@Suite(.serialized)
final class CodexOperationalDiagnosticsTests {
  @Test
  func testSnapshotCorrelatesWorkspaceStateAndProducesRecoveryFindings() async throws {
    let database = try GatewayDatabase(inMemory: ())
    let now = Date(timeIntervalSince1970: 10_000)
    let owner = CodexRuntimeOwner(
      workspaceID: "workspace-1",
      profileID: "profile-1",
      caller: "local-mcp",
      transport: "gateway_socket",
      socketConnectionID: "socket-1",
      tunnelInstanceID: "tunnel-1",
      tunnelProfileID: "tunnel-profile-1"
    )
    try database.saveWorkspace(
      RegisteredWorkspace(
        id: "workspace-1",
        displayName: "Fixture",
        rootPath: "/tmp/workspace-1"
      )
    )
    try database.saveCodexRuntimeLease(
      CodexRuntimeLeaseRecord(
        id: "runtime-stale",
        owner: owner,
        workspacePath: "/tmp/workspace-1",
        state: "failed",
        process: CodexAppServerProcessSnapshot(
          state: .failed,
          processID: Int32.max - 20,
          supervisorProcessID: Int32.max - 21,
          parentProcessID: 1,
          processGroupID: Int32.max - 20,
          startedAt: now.addingTimeInterval(-120),
          stoppedAt: now.addingTimeInterval(-60),
          exitCode: nil,
          signal: 9,
          terminationEscalated: true,
          lastError: "token=[REDACTED]"
        ),
        createdAt: now.addingTimeInterval(-120),
        updatedAt: now.addingTimeInterval(-60),
        shutdownReason: "consumer_failure",
        cleanedAt: nil
      )
    )
    try database.saveCodexThreadOwnership(
      CodexThreadOwnershipRecord(
        threadID: "thread-owned",
        workspaceID: "workspace-1",
        workspacePath: "/tmp/workspace-1",
        runtimeID: "runtime-stale",
        state: .loaded,
        createdAt: now.addingTimeInterval(-120),
        updatedAt: now.addingTimeInterval(-60)
      )
    )
    try database.saveCodexApproval(
      CodexApprovalRecord(
        id: "approval-1",
        upstreamRequestID: "n:1",
        kind: .commandExecution,
        risk: .workspaceWrite,
        state: .pending,
        workspaceID: "workspace-1",
        workspacePath: "/tmp/workspace-1",
        runtimeID: "runtime-stale",
        threadID: "thread-1",
        turnID: "turn-1",
        itemID: "item-1",
        correlationID: "correlation-1",
        socketConnectionID: "socket-1",
        tunnelInstanceID: "tunnel-1",
        details: .object(["command": .string("git status")]),
        proposedAction: .object(["kind": .string("command_execution")]),
        createdAt: now.addingTimeInterval(-30),
        expiresAt: now.addingTimeInterval(300),
        resolvedAt: nil,
        decision: nil,
        scope: nil,
        resolutionReason: nil
      )
    )
    var run = try CodexOrchestrationEngine.create(
      database: database,
      workspaceID: "workspace-1",
      workspacePath: "/tmp/workspace-1",
      parentRunID: nil,
      threadID: "thread-1",
      officialGoalLinked: true,
      objective: "Ship the complete batch.",
      acceptedScope: ["runtime", "website"],
      phase: "implementation",
      acceptanceCriteria: ["All gates pass"],
      requiredEvidenceKinds: ["test"],
      budget: CodexRunBudget(
        maxTurns: 10,
        maxDurationSeconds: 3_600,
        maxNoProgressSeconds: 60,
        maxRepeatedFailures: 3
      )
    )
    for _ in 0..<3 {
      run = try CodexOrchestrationEngine.record(
        database: database,
        workspaceID: "workspace-1",
        runID: run.id,
        expectedRevision: run.revision,
        event: CodexRunEvent(
          kind: .planning,
          summary: "Planning without repository progress.",
          phase: nil,
          nextAction: "Inspect the blocker.",
          turnID: nil,
          approvalID: nil,
          commandID: nil,
          criterionID: nil,
          evidenceKind: nil,
          requestID: "request-run",
          correlationID: "correlation-run",
          artifact: nil,
          repositoryDigest: nil,
          failureFingerprint: nil,
          externalBlocker: false
        ),
        now: now
      )
    }
    try database.recordAudit(
      AuditEvent(
        occurredAt: now,
        requestID: "request-git",
        mcpRequestID: "mcp-request-git",
        invocationID: "invocation-git",
        ticketID: "ticket-git",
        caller: .localMCP,
        transport: "gateway_socket",
        socketConnectionID: "socket-1",
        tunnelInstanceID: "tunnel-1",
        tunnelProfileID: "tunnel-profile-1",
        profileID: GatewayProfileID(rawValue: "profile-1")!,
        workspaceID: "workspace-1",
        capabilityID: "git.commit",
        decision: .allowed,
        inputDigest: "sha256:input",
        outputDigest: "sha256:output"
      )
    )
    try database.recordAudit(
      AuditEvent(
        occurredAt: now.addingTimeInterval(-1),
        requestID: "token=diagnostic-secret",
        mcpRequestID: String(repeating: "m", count: 2_048),
        caller: .localMCP,
        profileID: GatewayProfileID(rawValue: "profile-1")!,
        workspaceID: "workspace-1",
        capabilityID: "tools.list",
        decision: .allowed
      )
    )

    let snapshot = try await CodexOperationalDiagnostics.snapshot(
      database: database,
      owner: owner,
      configuredSandbox: .workspaceWrite,
      limit: 100,
      now: now
    )
    let object = try #require(snapshot.objectValue)
    let summary = try #require(object["summary"]?.objectValue)
    let findings = object["findings"]?.arrayValue ?? []
    let findingCodes = Set(findings.compactMap { $0.objectValue?["code"]?.stringValue })
    let audits = object["recent_tool_audits"]?.arrayValue ?? []

    #expect(object["persistence_available"] == .bool(true))
    #expect(object["scope"]?.objectValue?["workspace_id"] == .string("workspace-1"))
    #expect(summary["persisted_runtime_count"] == .number(1))
    #expect(summary["thread_ownership_receipt_count"] == .number(1))
    #expect(summary["pending_approval_count"] == .number(1))
    #expect(summary["active_run_count"] == .number(1))
    #expect(findingCodes.contains("stale_record"))
    #expect(findingCodes.contains("pending_approvals"))
    #expect(findingCodes.contains("run_blocked"))
    #expect(findingCodes.contains("thread_ownership_requires_reconciliation"))
    #expect(object["thread_ownership_receipts"]?.arrayValue?.count == 1)
    #expect(audits.count == 2)
    let gitAudit = try #require(
      audits.first { $0.objectValue?["category"] == .string("git") }
    )
    #expect(gitAudit.objectValue?["request_id"] == .string("request-git"))
    #expect(gitAudit.objectValue?["ticket_id"] == .string("ticket-git"))
    let boundedAudit = try #require(
      audits.first { $0.objectValue?["category"] == .string("tool") }
    )
    #expect(boundedAudit.objectValue?["request_id"] == .string("token=[REDACTED]"))
    #expect(boundedAudit.objectValue?["mcp_request_id"]?.stringValue?.count == 1_024)
    #expect(object["safety"]?.objectValue?["external_process_control"] == .bool(false))
  }

  @Test
  func testHandoffDiagnosticUsesDurableReleasedOwnershipEvidence() async throws {
    let database = try GatewayDatabase(inMemory: ())
    let now = Date(timeIntervalSince1970: 20_000)
    try database.saveCodexThreadOwnership(
      CodexThreadOwnershipRecord(
        threadID: "thread-released",
        workspaceID: "workspace-1",
        workspacePath: "/tmp/workspace-1",
        runtimeID: "runtime-stopped",
        state: .released,
        createdAt: now.addingTimeInterval(-60),
        updatedAt: now
      )
    )
    try database.saveCodexRuntimeLease(
      CodexRuntimeLeaseRecord(
        id: "runtime-stopped",
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
        state: "stopped",
        process: nil,
        createdAt: now.addingTimeInterval(-60),
        updatedAt: now,
        shutdownReason: "requested",
        cleanedAt: nil
      )
    )

    let result = await CodexThreadHandoffDiagnostics.diagnose(
      threadID: "thread-released",
      observedError: nil,
      workspaceID: "workspace-1",
      database: database
    )

    #expect(result.objectValue?["classification"] == .string("released_persisted"))
    #expect(
      result.objectValue?["persisted_ownership"]?.objectValue?["state"]
        == .string("released")
    )
    #expect(
      result.objectValue?["last_runtime_receipt"]?.objectValue?["state"]
        == .string("stopped")
    )
    #expect(result.objectValue?["external_process_signals_allowed"] == .bool(false))
  }
}
