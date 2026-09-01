import Foundation

enum CodexOperationalDiagnostics {
  static func snapshot(
    database: GatewayDatabase?,
    owner: CodexRuntimeOwner?,
    limit: Int,
    now: Date = Date()
  ) async throws -> JSONValue {
    let workspaceID = owner?.workspaceID
    let liveRuntimes = await CodexRuntimeDirectory.shared.statuses(workspaceID: workspaceID)
    let persistedRuntimes =
      try database?.codexRuntimeLeases(limit: max(limit * 4, limit))
      .filter { $0.owner?.workspaceID == workspaceID }
      .prefix(limit) ?? []
    let threadOwnership =
      try database?.codexThreadOwnerships(workspaceID: workspaceID, limit: limit) ?? []
    let approvals = try database?.codexApprovals(workspaceID: workspaceID, limit: limit) ?? []
    let runs = try database?.codexOrchestrationRuns(workspaceID: workspaceID, limit: limit) ?? []
    let leases = try database?.codexWorktreeLeases(workspaceID: workspaceID, limit: limit) ?? []
    let managedWorktrees = Array(
      try database?.codexManagedWorktrees(limit: max(limit * 4, limit))
        .filter { $0.sourceWorkspaceID == workspaceID || $0.workspaceID == workspaceID }
        .prefix(limit) ?? []
    )
    let audits = try recentWorkspaceAudits(
      database: database,
      workspaceID: workspaceID,
      limit: limit
    )
    let cleanup = try CodexRuntimeMaintenance.preview(
      database: database,
      workspaceID: workspaceID
    )
    let pendingApprovals = approvals.filter { $0.state == .pending }
    let activeRuns = runs.filter { !$0.state.isTerminal }
    let activeLeases = leases.filter { $0.state == .active && $0.expiresAt > now }
    let expiredLeaseReceipts = leases.filter { $0.state == .active && $0.expiresAt <= now }
    let activeManagedWorktrees = managedWorktrees.filter {
      [.provisioning, .active, .removalPlanned, .removing].contains($0.state)
    }
    let findings = findings(
      liveRuntimes: liveRuntimes,
      cleanup: cleanup,
      pendingApprovals: pendingApprovals,
      activeRuns: activeRuns,
      expiredLeaseReceipts: expiredLeaseReceipts,
      managedWorktrees: managedWorktrees,
      threadOwnership: threadOwnership,
      now: now
    )

    return .object([
      "generated_at": .string(timestamp(now)),
      "scope": .object([
        "workspace_id": diagnosticIdentifier(workspaceID),
        "profile_id": diagnosticIdentifier(owner?.profileID),
        "caller": diagnosticIdentifier(owner?.caller),
        "transport": diagnosticIdentifier(owner?.transport),
        "socket_connection_id": diagnosticIdentifier(owner?.socketConnectionID),
        "tunnel_instance_id": diagnosticIdentifier(owner?.tunnelInstanceID),
        "tunnel_profile_id": diagnosticIdentifier(owner?.tunnelProfileID),
      ]),
      "persistence_available": .bool(database != nil),
      "summary": .object([
        "live_runtime_count": .number(Double(liveRuntimeCount(liveRuntimes))),
        "persisted_runtime_count": .number(Double(persistedRuntimes.count)),
        "thread_ownership_receipt_count": .number(Double(threadOwnership.count)),
        "pending_approval_count": .number(Double(pendingApprovals.count)),
        "active_run_count": .number(Double(activeRuns.count)),
        "active_worktree_lease_count": .number(Double(activeLeases.count)),
        "active_managed_worktree_count": .number(Double(activeManagedWorktrees.count)),
        "finding_count": .number(Double(findings.count)),
      ]),
      "findings": .array(findings),
      "live_runtimes": liveRuntimes,
      "persisted_runtimes": .array(persistedRuntimes.map(\.json)),
      "thread_ownership_receipts": .array(threadOwnership.map(\.json)),
      "runtime_cleanup": cleanup,
      "pending_approvals": .array(pendingApprovals.map(\.json)),
      "active_runs": .array(activeRuns.map(\.json)),
      "active_worktree_leases": .array(activeLeases.map(\.json)),
      "expired_worktree_lease_receipts": .array(expiredLeaseReceipts.map(\.json)),
      "managed_worktrees": .array(managedWorktrees.map(\.json)),
      "recent_tool_audits": .array(audits.map(auditJSON)),
      "safety": .object([
        "secrets_redacted": .bool(true),
        "external_process_control": .bool(false),
        "cleanup_is_preview_only": .bool(true),
      ]),
    ])
  }

  private static func recentWorkspaceAudits(
    database: GatewayDatabase?,
    workspaceID: String?,
    limit: Int
  ) throws -> [AuditEvent] {
    guard let database else { return [] }
    return Array(
      try database.auditEvents(limit: min(10_000, max(limit * 10, limit)))
        .lazy
        .filter { $0.workspaceID == workspaceID }
        .prefix(limit)
    )
  }

  private static func findings(
    liveRuntimes: JSONValue,
    cleanup: JSONValue,
    pendingApprovals: [CodexApprovalRecord],
    activeRuns: [CodexOrchestrationRun],
    expiredLeaseReceipts: [CodexWorktreeLease],
    managedWorktrees: [CodexManagedWorktree],
    threadOwnership: [CodexThreadOwnershipRecord],
    now: Date
  ) -> [JSONValue] {
    var result: [JSONValue] = []
    let runtimeRows = liveRuntimes.objectValue?["runtimes"]?.arrayValue ?? []
    let liveRuntimeIDs = Set(
      runtimeRows.compactMap { $0.objectValue?["runtime_id"]?.stringValue }
    )
    for runtime in runtimeRows where runtime.objectValue?["last_error"] != nil {
      guard runtime.objectValue?["last_error"] != .null else { continue }
      result.append(
        finding(
          severity: "error",
          code: "runtime_last_error",
          summary: "A live Computer MCP-owned App Server runtime reports an error.",
          recovery: "Inspect that runtime and stop only its recorded runtime ID if recovery fails.",
          subjectID: runtime.objectValue?["runtime_id"]?.stringValue
        )
      )
    }
    let cleanupCandidates = cleanup.objectValue?["candidates"]?.arrayValue ?? []
    for candidate in cleanupCandidates {
      let classification = candidate.objectValue?["classification"]?.stringValue
      guard classification == "stale_record" || classification == "watchdog_pending" else {
        continue
      }
      result.append(
        finding(
          severity: classification == "stale_record" ? "warning" : "info",
          code: classification ?? "runtime_cleanup_candidate",
          summary: classification == "stale_record"
            ? "A persisted Computer MCP runtime receipt has no live runtime or owned process."
            : "A Computer MCP watchdog is still completing owned-process shutdown.",
          recovery: classification == "stale_record"
            ? "Review codex.app.runtimes.cleanup.preview, then perform reviewed receipt cleanup."
            : "Wait for the watchdog; do not signal unverified Codex processes.",
          subjectID: candidate.objectValue?["runtime"]?.objectValue?["id"]?.stringValue
        )
      )
    }
    if !pendingApprovals.isEmpty {
      result.append(
        finding(
          severity: "action_required",
          code: "pending_approvals",
          summary: "One or more Codex actions are waiting for explicit consent.",
          recovery: "Review the redacted approval record, then approve or deny it.",
          subjectID: pendingApprovals.first?.id
        )
      )
    }
    for run in activeRuns where [.blocked, .budgetLimited].contains(run.state) {
      result.append(
        finding(
          severity: "action_required",
          code: run.state == .blocked ? "run_blocked" : "run_budget_limited",
          summary: run.state == .blocked
            ? "A Computer MCP acceptance run is blocked."
            : "A Computer MCP acceptance run reached an execution budget.",
          recovery: run.nextAction
            ?? "Inspect the run's blockers, diagnostics, criteria, and evidence before continuing.",
          subjectID: run.id
        )
      )
    }
    if let lease = expiredLeaseReceipts.first {
      result.append(
        finding(
          severity: "warning",
          code: "expired_worktree_lease_receipt",
          summary: "A worktree mutation lease passed its heartbeat deadline.",
          recovery: "Review the lease cleanup preview; cleanup changes receipts only.",
          subjectID: lease.id
        )
      )
    }
    for worktree in managedWorktrees where worktree.state == .failed {
      result.append(
        finding(
          severity: "error",
          code: "managed_worktree_failed",
          summary: "A Computer MCP-managed worktree lifecycle operation failed.",
          recovery:
            "Inspect the managed worktree receipt and verify Git ownership before retrying or cleaning up.",
          subjectID: worktree.id
        )
      )
    }
    for worktree in managedWorktrees
    where [.planned, .removalPlanned].contains(worktree.state)
      && worktree.planExpiresAt.map({ $0 <= now }) == true
    {
      result.append(
        finding(
          severity: "info",
          code: "managed_worktree_plan_expired",
          summary: "A reviewed managed worktree plan expired without execution.",
          recovery: "Create a fresh plan so Git and ownership state are validated again.",
          subjectID: worktree.id
        )
      )
    }
    for ownership in threadOwnership
    where ownership.state == .loaded && !liveRuntimeIDs.contains(ownership.runtimeID) {
      result.append(
        finding(
          severity: "info",
          code: "thread_ownership_requires_reconciliation",
          summary:
            "A thread ownership receipt is still marked loaded without a live in-process runtime.",
          recovery:
            "Run the thread handoff diagnostic and reconcile the recorded runtime before deliberately reclaiming the thread.",
          subjectID: ownership.threadID
        )
      )
    }
    return result
  }

  private static func finding(
    severity: String,
    code: String,
    summary: String,
    recovery: String,
    subjectID: String?
  ) -> JSONValue {
    .object([
      "severity": .string(severity),
      "code": .string(code),
      "summary": .string(summary),
      "recovery": .string(
        CodexApprovalRedactor.redactString(recovery, maximumCharacters: 8_192)
      ),
      "subject_id": diagnosticIdentifier(subjectID),
    ])
  }

  private static func liveRuntimeCount(_ value: JSONValue) -> Int {
    value.objectValue?["runtimes"]?.arrayValue?.count ?? 0
  }

  private static func auditJSON(_ event: AuditEvent) -> JSONValue {
    .object([
      "id": diagnosticIdentifier(event.id),
      "occurred_at": .string(timestamp(event.occurredAt)),
      "request_id": diagnosticIdentifier(event.requestID),
      "mcp_request_id": diagnosticIdentifier(event.mcpRequestID),
      "invocation_id": diagnosticIdentifier(event.invocationID),
      "parent_request_id": diagnosticIdentifier(event.parentRequestID),
      "ticket_id": diagnosticIdentifier(event.ticketID),
      "transport": diagnosticIdentifier(event.transport),
      "socket_connection_id": diagnosticIdentifier(event.socketConnectionID),
      "tunnel_instance_id": diagnosticIdentifier(event.tunnelInstanceID),
      "tunnel_profile_id": diagnosticIdentifier(event.tunnelProfileID),
      "profile_id": diagnosticIdentifier(event.profileID.rawValue),
      "workspace_id": diagnosticIdentifier(event.workspaceID),
      "capability_id": diagnosticIdentifier(event.capabilityID),
      "category": .string(event.capabilityID.hasPrefix("git.") ? "git" : "tool"),
      "decision": .string(event.decision.rawValue),
      "error_code": diagnosticIdentifier(event.errorCode),
      "duration_milliseconds": event.durationMilliseconds.map {
        .number(Double($0))
      } ?? .null,
      "input_digest": diagnosticIdentifier(event.inputDigest),
      "output_digest": diagnosticIdentifier(event.outputDigest),
      "output_byte_count": event.outputByteCount.map { .number(Double($0)) } ?? .null,
      "output_truncated": event.outputTruncated.map(JSONValue.bool) ?? .null,
    ])
  }

  private static func diagnosticIdentifier(_ value: String?) -> JSONValue {
    guard let value else { return .null }
    return .string(
      CodexApprovalRedactor.redactString(value, maximumCharacters: 1_024)
    )
  }

  private static func timestamp(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }
}
