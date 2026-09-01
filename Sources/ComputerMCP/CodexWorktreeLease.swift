import Foundation

enum CodexWorktreeLeaseMode: String, Codable, Equatable, Sendable {
  case exclusive
  case isolatedWorktree = "isolated_worktree"
}

enum CodexWorktreeLeaseState: String, Codable, Equatable, Sendable {
  case active
  case released
  case expired
  case conflicted
}

struct CodexWorktreeLease: Codable, Equatable, Sendable, Identifiable {
  let id: String
  let workspaceID: String
  let workspacePath: String
  let mode: CodexWorktreeLeaseMode
  let agentID: String
  let threadID: String?
  let runID: String?
  let parentLeaseID: String?
  let branch: String?
  var state: CodexWorktreeLeaseState
  let createdAt: Date
  var heartbeatAt: Date
  var expiresAt: Date
  var releasedAt: Date?
  var releaseReason: String?
  var revision: Int

  var json: JSONValue {
    (try? JSONValue.encoded(self)) ?? .object([:])
  }
}

enum CodexWorktreeLeaseError: Error, LocalizedError, Sendable {
  case unavailable
  case invalid(String)
  case unknown(String)
  case conflict(CodexWorktreeLease)
  case revisionConflict(expected: Int, actual: Int)
  case inactive(String)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      return "Codex worktree leases require the Gateway Database."
    case .invalid(let detail):
      return "Invalid Codex worktree lease request: \(detail)"
    case .unknown(let id):
      return "Unknown Codex worktree lease '\(id)'."
    case .conflict(let lease):
      return
        "Worktree '\(lease.workspacePath)' is already leased to agent '\(lease.agentID)' by lease '\(lease.id)'."
    case .revisionConflict(let expected, let actual):
      return "Codex worktree lease revision conflict: expected \(expected), current \(actual)."
    case .inactive(let id):
      return "Codex worktree lease '\(id)' is not active."
    }
  }
}

enum CodexWorktreeLeaseManager {
  static func acquire(
    database: GatewayDatabase?,
    workspaceID: String?,
    agentID: String,
    threadID: String?,
    runID: String?,
    parentLeaseID: String?,
    branch: String?,
    mode: CodexWorktreeLeaseMode,
    ttlSeconds: Int,
    liveRuntimeStatus: JSONValue,
    now: Date = Date()
  ) throws -> CodexWorktreeLease {
    guard let database else { throw CodexWorktreeLeaseError.unavailable }
    guard let workspaceID, let workspace = try database.workspace(id: workspaceID) else {
      throw CodexWorktreeLeaseError.invalid("the selected workspace is not registered")
    }
    let safeAgentID = try persistedIdentifier(agentID, name: "agent_id", maximum: 256)
    let safeThreadID = try threadID.map {
      try boundedIdentifier($0, name: "thread_id", maximum: 1_024)
    }
    let safeBranch = try branch.map {
      try persistedIdentifier($0, name: "branch", maximum: 256)
    }
    guard (30...86_400).contains(ttlSeconds) else {
      throw CodexWorktreeLeaseError.invalid("ttl_seconds must be between 30 and 86400")
    }
    if let runID {
      guard let run = try database.codexOrchestrationRun(id: runID),
        run.workspaceID == workspaceID
      else {
        throw CodexWorktreeLeaseError.invalid(
          "run_id must identify a run in the selected workspace"
        )
      }
    }
    if let parentLeaseID {
      guard let parent = try database.codexWorktreeLease(id: parentLeaseID),
        parent.state == .active, parent.expiresAt > now
      else {
        throw CodexWorktreeLeaseError.invalid("parent_lease_id must identify an active lease")
      }
      guard parent.workspaceID != workspaceID || parent.mode == .exclusive else {
        throw CodexWorktreeLeaseError.invalid(
          "an isolated child must use a separately registered worktree workspace"
        )
      }
    }
    if mode == .isolatedWorktree, parentLeaseID == nil {
      throw CodexWorktreeLeaseError.invalid(
        "isolated_worktree requires parent_lease_id to preserve task lineage"
      )
    }
    let activeTurns = activeTurnIDs(in: liveRuntimeStatus)
    if !activeTurns.isEmpty, threadID.map({ !activeTurns.contains($0) }) ?? true {
      throw CodexWorktreeLeaseError.invalid(
        "the workspace already has an active turn; acquire a lease before starting mutation"
      )
    }
    return try database.acquireCodexWorktreeLease(
      workspaceID: workspaceID,
      workspacePath: workspace.rootPath,
      mode: mode,
      agentID: safeAgentID,
      threadID: safeThreadID,
      runID: runID,
      parentLeaseID: parentLeaseID,
      branch: safeBranch,
      ttlSeconds: ttlSeconds,
      now: now
    )
  }

  static func validate(
    database: GatewayDatabase?,
    workspaceID: String?,
    leaseID: String?,
    threadID: String,
    now: Date = Date()
  ) throws {
    guard let database else { return }
    let active = try database.codexWorktreeLeases(
      workspaceID: workspaceID,
      states: [.active],
      limit: 100
    ).filter { $0.expiresAt > now }
    guard !active.isEmpty else { return }
    guard let leaseID,
      let lease = active.first(where: { $0.id == leaseID }),
      lease.threadID == nil || lease.threadID == threadID
    else {
      throw CodexWorktreeLeaseError.conflict(active[0])
    }
  }

  static func heartbeat(
    database: GatewayDatabase?,
    workspaceID: String?,
    leaseID: String,
    expectedRevision: Int,
    ttlSeconds: Int,
    now: Date = Date()
  ) throws -> CodexWorktreeLease {
    guard let database else { throw CodexWorktreeLeaseError.unavailable }
    guard (30...86_400).contains(ttlSeconds) else {
      throw CodexWorktreeLeaseError.invalid("ttl_seconds must be between 30 and 86400")
    }
    return try database.updateCodexWorktreeLease(
      id: leaseID,
      workspaceID: workspaceID,
      expectedRevision: expectedRevision
    ) { lease in
      guard lease.state == .active, lease.expiresAt > now else {
        throw CodexWorktreeLeaseError.inactive(leaseID)
      }
      lease.heartbeatAt = now
      lease.expiresAt = now.addingTimeInterval(TimeInterval(ttlSeconds))
    }
  }

  static func release(
    database: GatewayDatabase?,
    workspaceID: String?,
    leaseID: String,
    expectedRevision: Int,
    reason: String,
    now: Date = Date()
  ) throws -> CodexWorktreeLease {
    guard let database else { throw CodexWorktreeLeaseError.unavailable }
    let safeReason = CodexApprovalRedactor.redactString(reason, maximumCharacters: 4_096)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !safeReason.isEmpty else {
      throw CodexWorktreeLeaseError.invalid("reason must be non-empty")
    }
    return try database.updateCodexWorktreeLease(
      id: leaseID,
      workspaceID: workspaceID,
      expectedRevision: expectedRevision
    ) { lease in
      guard lease.state == .active else { throw CodexWorktreeLeaseError.inactive(leaseID) }
      lease.state = .released
      lease.releasedAt = now
      lease.releaseReason = safeReason
    }
  }

  static func cleanupExpired(
    database: GatewayDatabase?,
    workspaceID: String?,
    perform: Bool,
    now: Date = Date()
  ) throws -> JSONValue {
    guard let database else { throw CodexWorktreeLeaseError.unavailable }
    let expired = try database.codexWorktreeLeases(
      workspaceID: workspaceID,
      states: [.active],
      limit: 5_000
    ).filter { $0.expiresAt <= now }
    var results: [CodexWorktreeLease] = []
    for lease in expired {
      if perform {
        let updated = try database.updateCodexWorktreeLease(
          id: lease.id,
          workspaceID: workspaceID,
          expectedRevision: lease.revision
        ) { value in
          value.state = .expired
          value.releasedAt = now
          value.releaseReason = "lease_ttl_expired"
        }
        results.append(updated)
      } else {
        results.append(lease)
      }
    }
    return .object([
      perform ? "expired" : "candidates": .array(results.map(\.json)),
      "filesystem_changes": .bool(false),
      "process_signals_sent": .bool(false),
    ])
  }

  private static func activeTurnIDs(in status: JSONValue) -> Set<String> {
    Set(
      (status.objectValue?["runtimes"]?.arrayValue ?? []).flatMap { runtime in
        (runtime.objectValue?["threads"]?.arrayValue ?? []).compactMap {
          $0.objectValue?["active_turn_id"]?.stringValue
        }
      }
    )
  }

  private static func persistedIdentifier(
    _ value: String,
    name: String,
    maximum: Int
  ) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed == value, value.utf8.count <= maximum else {
      throw CodexWorktreeLeaseError.invalid(
        "\(name) must contain 1...\(maximum) bytes without surrounding whitespace"
      )
    }
    guard CodexApprovalRedactor.redactString(value, maximumCharacters: maximum) == value else {
      throw CodexWorktreeLeaseError.invalid("\(name) must not contain credential-like text")
    }
    return value
  }

  private static func boundedIdentifier(
    _ value: String,
    name: String,
    maximum: Int
  ) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed == value, value.utf8.count <= maximum else {
      throw CodexWorktreeLeaseError.invalid(
        "\(name) must contain 1...\(maximum) bytes without surrounding whitespace"
      )
    }
    return value
  }
}
