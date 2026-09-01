import CryptoKit
import Foundation

enum CodexOrchestrationRunState: String, Codable, Equatable, Sendable {
  case active
  case paused
  case blocked
  case budgetLimited = "budget_limited"
  case completed
  case cancelled
  case failed

  var isTerminal: Bool {
    [.completed, .cancelled, .failed].contains(self)
  }
}

enum CodexAcceptanceState: String, Codable, Equatable, Sendable {
  case open
  case passed
  case failed
}

struct CodexAcceptanceCriterion: Codable, Equatable, Sendable, Identifiable {
  let id: String
  let description: String
  var state: CodexAcceptanceState
  var evidenceIDs: [String]
}

struct CodexRunEvidence: Codable, Equatable, Sendable, Identifiable {
  let id: String
  let kind: String
  let summary: String
  let requestID: String?
  let correlationID: String?
  let artifact: String?
  let repositoryDigest: String?
  let createdAt: Date
}

struct CodexRunBlocker: Codable, Equatable, Sendable, Identifiable {
  let id: String
  let code: String
  let summary: String
  let external: Bool
  let createdAt: Date
}

struct CodexRunBudget: Codable, Equatable, Sendable {
  let maxTurns: Int
  let maxDurationSeconds: Int
  let maxNoProgressSeconds: Int
  let maxRepeatedFailures: Int
}

struct CodexOrchestrationRun: Codable, Equatable, Sendable, Identifiable {
  let id: String
  let workspaceID: String
  let workspacePath: String
  let parentRunID: String?
  let threadID: String?
  let officialGoalLinked: Bool
  let objective: String
  let acceptedScope: [String]
  var currentPhase: String
  var acceptanceCriteria: [CodexAcceptanceCriterion]
  var evidence: [CodexRunEvidence]
  var state: CodexOrchestrationRunState
  var activeTurnID: String?
  var pendingApprovalID: String?
  var blockers: [CodexRunBlocker]
  var nextAction: String?
  var terminalReason: String?
  var lastMeaningfulProgressAt: Date
  var repositoryDigest: String?
  var activeCommandID: String?
  var lastCommandProgressAt: Date?
  var repeatedPlanningCount: Int
  var repeatedFailureFingerprint: String?
  var repeatedFailureCount: Int
  var turnsUsed: Int
  let requiredEvidenceKinds: [String]
  let budget: CodexRunBudget
  let createdAt: Date
  var updatedAt: Date
  var revision: Int
  var diagnostics: [String]

  var json: JSONValue {
    (try? JSONValue.encoded(self)) ?? .object([:])
  }
}

enum CodexRunEventKind: String, Sendable {
  case planning
  case turnStarted = "turn_started"
  case turnCompleted = "turn_completed"
  case repositoryChanged = "repository_changed"
  case commandStarted = "command_started"
  case commandProgress = "command_progress"
  case commandCompleted = "command_completed"
  case failure
  case acceptancePassed = "acceptance_passed"
  case acceptanceFailed = "acceptance_failed"
  case approvalPending = "approval_pending"
  case approvalResolved = "approval_resolved"
  case blocker
}

struct CodexRunEvent: Sendable {
  let kind: CodexRunEventKind
  let summary: String
  let phase: String?
  let nextAction: String?
  let turnID: String?
  let approvalID: String?
  let commandID: String?
  let criterionID: String?
  let evidenceKind: String?
  let requestID: String?
  let correlationID: String?
  let artifact: String?
  let repositoryDigest: String?
  let failureFingerprint: String?
  let externalBlocker: Bool
}

enum CodexOrchestrationError: Error, LocalizedError, Sendable {
  case unavailable
  case invalid(String)
  case unknown(String)
  case revisionConflict(expected: Int, actual: Int)
  case terminal(String)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      return "Codex orchestration persistence requires the Gateway Database."
    case .invalid(let detail):
      return "Invalid Codex orchestration request: \(detail)"
    case .unknown(let id):
      return "Unknown Codex orchestration run '\(id)'."
    case .revisionConflict(let expected, let actual):
      return "Codex orchestration revision conflict: expected \(expected), current \(actual)."
    case .terminal(let id):
      return "Codex orchestration run '\(id)' is already terminal."
    }
  }
}

enum CodexOrchestrationEngine {
  static func create(
    database: GatewayDatabase?,
    workspaceID: String?,
    workspacePath: String?,
    parentRunID: String?,
    threadID: String?,
    officialGoalLinked: Bool,
    objective: String,
    acceptedScope: [String],
    phase: String,
    acceptanceCriteria: [String],
    requiredEvidenceKinds: [String],
    budget: CodexRunBudget
  ) throws -> CodexOrchestrationRun {
    let database = try require(database)
    guard let workspaceID, !workspaceID.isEmpty, let workspacePath, !workspacePath.isEmpty else {
      throw CodexOrchestrationError.invalid("a registered workspace is required")
    }
    let objective = try persistedText(objective, field: "objective", maximumCharacters: 32_768)
    let phase = try persistedText(phase, field: "phase", maximumCharacters: 512)
    guard !acceptedScope.isEmpty, acceptedScope.count <= 256 else {
      throw CodexOrchestrationError.invalid("accepted_scope must contain non-empty entries")
    }
    let acceptedScope = try acceptedScope.enumerated().map { index, value in
      try persistedText(
        value,
        field: "accepted_scope[\(index)]",
        maximumCharacters: 8_192
      )
    }
    guard !acceptanceCriteria.isEmpty, acceptanceCriteria.count <= 256 else {
      throw CodexOrchestrationError.invalid(
        "acceptance_criteria must contain at least one non-empty criterion"
      )
    }
    let acceptanceCriteria = try acceptanceCriteria.enumerated().map { index, value in
      try persistedText(
        value,
        field: "acceptance_criteria[\(index)]",
        maximumCharacters: 8_192
      )
    }
    guard Set(acceptanceCriteria).count == acceptanceCriteria.count else {
      throw CodexOrchestrationError.invalid("acceptance_criteria must not contain duplicates")
    }
    guard requiredEvidenceKinds.count <= 64 else {
      throw CodexOrchestrationError.invalid(
        "required_evidence_kinds must contain at most 64 entries")
    }
    let requiredEvidenceKinds = try requiredEvidenceKinds.enumerated().map { index, value in
      try persistedIdentifier(
        value,
        field: "required_evidence_kinds[\(index)]",
        maximumCharacters: 128
      )
    }
    guard budget.maxTurns > 0, budget.maxDurationSeconds > 0,
      budget.maxNoProgressSeconds > 0, budget.maxRepeatedFailures > 0
    else {
      throw CodexOrchestrationError.invalid("all execution budgets must be positive")
    }
    if officialGoalLinked, threadID == nil {
      throw CodexOrchestrationError.invalid(
        "official_goal_linked requires the official Goal's thread_id"
      )
    }
    if let parentRunID {
      guard let parent = try database.codexOrchestrationRun(id: parentRunID),
        parent.workspaceID == workspaceID
      else {
        throw CodexOrchestrationError.invalid(
          "parent_run_id must identify a run in the selected workspace"
        )
      }
    }
    let now = Date()
    let run = CodexOrchestrationRun(
      id: UUID().uuidString,
      workspaceID: workspaceID,
      workspacePath: workspacePath,
      parentRunID: parentRunID,
      threadID: threadID,
      officialGoalLinked: officialGoalLinked,
      objective: objective,
      acceptedScope: acceptedScope,
      currentPhase: phase,
      acceptanceCriteria: acceptanceCriteria.enumerated().map { index, description in
        CodexAcceptanceCriterion(
          id: "criterion-\(index + 1)",
          description: description,
          state: .open,
          evidenceIDs: []
        )
      },
      evidence: [],
      state: .active,
      activeTurnID: nil,
      pendingApprovalID: nil,
      blockers: [],
      nextAction: nil,
      terminalReason: nil,
      lastMeaningfulProgressAt: now,
      repositoryDigest: nil,
      activeCommandID: nil,
      lastCommandProgressAt: nil,
      repeatedPlanningCount: 0,
      repeatedFailureFingerprint: nil,
      repeatedFailureCount: 0,
      turnsUsed: 0,
      requiredEvidenceKinds: Array(Set(requiredEvidenceKinds)).sorted(),
      budget: budget,
      createdAt: now,
      updatedAt: now,
      revision: 1,
      diagnostics: []
    )
    try database.saveCodexOrchestrationRun(run)
    return run
  }

  static func record(
    database: GatewayDatabase?,
    workspaceID: String?,
    runID: String,
    expectedRevision: Int,
    event: CodexRunEvent,
    now: Date = Date()
  ) throws -> CodexOrchestrationRun {
    let database = try require(database)
    let event = try persistedEvent(event)
    return try database.updateCodexOrchestrationRun(
      id: runID,
      workspaceID: workspaceID,
      expectedRevision: expectedRevision
    ) { run in
      guard !run.state.isTerminal else { throw CodexOrchestrationError.terminal(runID) }
      if let phase = event.phase {
        run.currentPhase = phase
      }
      if let nextAction = event.nextAction {
        run.nextAction = nextAction
      }
      switch event.kind {
      case .planning:
        run.repeatedPlanningCount += 1
        if run.repeatedPlanningCount >= 3 {
          block(
            &run,
            code: "repeated_planning_without_repository_change",
            summary: "Planning repeated three times without recorded repository progress.",
            external: false,
            now: now
          )
        }
      case .turnStarted:
        let turnID = try required(event.turnID, field: "turn_id")
        run.activeTurnID = turnID
        run.turnsUsed += 1
      case .turnCompleted:
        run.activeTurnID = nil
        if run.acceptanceCriteria.contains(where: { $0.state != .passed }) {
          appendDiagnostic(
            "turn_completed_with_open_acceptance",
            to: &run
          )
        }
      case .repositoryChanged:
        let digest = try required(event.repositoryDigest, field: "repository_digest")
        run.repositoryDigest = digest
        run.repeatedPlanningCount = 0
        run.lastMeaningfulProgressAt = now
        appendEvidence(event, defaultKind: "repository_change", to: &run, now: now)
      case .commandStarted:
        run.activeCommandID = try required(event.commandID, field: "command_id")
        run.lastCommandProgressAt = now
      case .commandProgress:
        let commandID = try required(event.commandID, field: "command_id")
        guard run.activeCommandID == commandID else {
          throw CodexOrchestrationError.invalid("command_id is not the active command")
        }
        run.lastCommandProgressAt = now
        run.lastMeaningfulProgressAt = now
      case .commandCompleted:
        let commandID = try required(event.commandID, field: "command_id")
        guard run.activeCommandID == commandID else {
          throw CodexOrchestrationError.invalid("command_id is not the active command")
        }
        run.activeCommandID = nil
        run.lastCommandProgressAt = nil
        run.lastMeaningfulProgressAt = now
        appendEvidence(event, defaultKind: "command", to: &run, now: now)
      case .failure:
        let fingerprint = try required(event.failureFingerprint, field: "failure_fingerprint")
        if run.repeatedFailureFingerprint == fingerprint {
          run.repeatedFailureCount += 1
        } else {
          run.repeatedFailureFingerprint = fingerprint
          run.repeatedFailureCount = 1
        }
        if run.repeatedFailureCount >= run.budget.maxRepeatedFailures {
          block(
            &run,
            code: "repeated_identical_failure",
            summary: "The same failure reached the configured repetition limit.",
            external: event.externalBlocker,
            now: now
          )
        }
      case .acceptancePassed:
        let criterionID = try required(event.criterionID, field: "criterion_id")
        guard let index = run.acceptanceCriteria.firstIndex(where: { $0.id == criterionID }) else {
          throw CodexOrchestrationError.invalid("unknown criterion_id '\(criterionID)'")
        }
        let evidence = appendEvidence(
          event,
          defaultKind: try required(event.evidenceKind, field: "evidence_kind"),
          to: &run,
          now: now
        )
        run.acceptanceCriteria[index].state = .passed
        run.acceptanceCriteria[index].evidenceIDs.append(evidence.id)
        run.lastMeaningfulProgressAt = now
      case .acceptanceFailed:
        let criterionID = try required(event.criterionID, field: "criterion_id")
        guard let index = run.acceptanceCriteria.firstIndex(where: { $0.id == criterionID }) else {
          throw CodexOrchestrationError.invalid("unknown criterion_id '\(criterionID)'")
        }
        run.acceptanceCriteria[index].state = .failed
        block(
          &run,
          code: "acceptance_failed",
          summary: event.summary,
          external: event.externalBlocker,
          now: now
        )
      case .approvalPending:
        run.pendingApprovalID = try required(event.approvalID, field: "approval_id")
        run.state = .paused
        appendDiagnostic("paused_for_approval", to: &run)
      case .approvalResolved:
        let approvalID = try required(event.approvalID, field: "approval_id")
        guard run.pendingApprovalID == approvalID else {
          throw CodexOrchestrationError.invalid("approval_id is not pending for this run")
        }
        run.pendingApprovalID = nil
        if run.blockers.isEmpty { run.state = .active }
        run.lastMeaningfulProgressAt = now
      case .blocker:
        block(
          &run,
          code: event.failureFingerprint ?? "external_blocker",
          summary: event.summary,
          external: event.externalBlocker,
          now: now
        )
      }
      applyBudgets(to: &run, now: now)
      run.updatedAt = now
    }
  }

  static func evaluate(
    database: GatewayDatabase?,
    workspaceID: String?,
    runID: String,
    expectedRevision: Int,
    now: Date = Date()
  ) throws -> CodexOrchestrationRun {
    let database = try require(database)
    return try database.updateCodexOrchestrationRun(
      id: runID,
      workspaceID: workspaceID,
      expectedRevision: expectedRevision
    ) { run in
      guard !run.state.isTerminal else { return }
      applyBudgets(to: &run, now: now)
      if let lastCommandProgressAt = run.lastCommandProgressAt,
        now.timeIntervalSince(lastCommandProgressAt)
          >= TimeInterval(run.budget.maxNoProgressSeconds)
      {
        block(
          &run,
          code: "command_no_progress",
          summary: "The active command produced no recorded progress within the configured bound.",
          external: false,
          now: now
        )
      }
      run.updatedAt = now
    }
  }

  static func accept(
    database: GatewayDatabase?,
    workspaceID: String?,
    runID: String,
    expectedRevision: Int,
    worktreeClean: Bool,
    now: Date = Date()
  ) throws -> CodexOrchestrationRun {
    let database = try require(database)
    return try database.updateCodexOrchestrationRun(
      id: runID,
      workspaceID: workspaceID,
      expectedRevision: expectedRevision
    ) { run in
      guard !run.state.isTerminal else { throw CodexOrchestrationError.terminal(runID) }
      run.blockers.removeAll { $0.code.hasPrefix("acceptance_") }
      let open = run.acceptanceCriteria.filter { $0.state != .passed }.map(\.id)
      if !open.isEmpty {
        block(
          &run,
          code: "acceptance_open",
          summary: "Acceptance remains open: \(open.joined(separator: ", ")).",
          external: false,
          now: now
        )
      }
      let presentKinds = Set(run.evidence.map(\.kind))
      let missingKinds = run.requiredEvidenceKinds.filter { !presentKinds.contains($0) }
      if !missingKinds.isEmpty {
        block(
          &run,
          code: "acceptance_missing_evidence",
          summary: "Required evidence is missing: \(missingKinds.joined(separator: ", ")).",
          external: false,
          now: now
        )
      }
      if !worktreeClean {
        block(
          &run,
          code: "acceptance_dirty_worktree",
          summary: "The worktree is dirty after completion was claimed.",
          external: false,
          now: now
        )
      }
      if run.activeTurnID != nil {
        block(
          &run,
          code: "acceptance_active_turn",
          summary: "A Codex turn is still active.",
          external: false,
          now: now
        )
      }
      if run.pendingApprovalID != nil {
        block(
          &run,
          code: "acceptance_pending_approval",
          summary: "A required approval is still pending.",
          external: false,
          now: now
        )
      }
      if run.blockers.isEmpty {
        run.state = .completed
        run.terminalReason =
          "All acceptance criteria and required evidence were explicitly accepted."
        run.nextAction = nil
      } else {
        run.state = .blocked
        appendDiagnostic("agent_completion_claim_contradicted_by_evidence", to: &run)
      }
      run.updatedAt = now
    }
  }

  static func transition(
    database: GatewayDatabase?,
    workspaceID: String?,
    runID: String,
    expectedRevision: Int,
    action: String,
    reason: String?,
    now: Date = Date()
  ) throws -> CodexOrchestrationRun {
    let database = try require(database)
    return try database.updateCodexOrchestrationRun(
      id: runID,
      workspaceID: workspaceID,
      expectedRevision: expectedRevision
    ) { run in
      guard !run.state.isTerminal else { throw CodexOrchestrationError.terminal(runID) }
      switch action {
      case "pause":
        run.state = .paused
        run.terminalReason = nil
      case "resume":
        guard run.pendingApprovalID == nil else {
          throw CodexOrchestrationError.invalid("resolve the pending approval before resume")
        }
        run.blockers.removeAll()
        run.state = .active
        run.terminalReason = nil
        run.lastMeaningfulProgressAt = now
      case "cancel":
        let reason = try persistedText(
          try required(reason, field: "reason"),
          field: "reason",
          maximumCharacters: 8_192
        )
        run.state = .cancelled
        run.terminalReason = reason
        run.activeTurnID = nil
        run.activeCommandID = nil
      default:
        throw CodexOrchestrationError.invalid("unsupported transition '\(action)'")
      }
      run.updatedAt = now
    }
  }

  static func reconcileChild(
    database: GatewayDatabase?,
    workspaceID: String?,
    parentRunID: String,
    expectedRevision: Int,
    childRunID: String,
    childEvidenceIDs: [String],
    criterionID: String,
    acceptCriterion: Bool,
    now: Date = Date()
  ) throws -> CodexOrchestrationRun {
    let database = try require(database)
    guard let child = try database.codexOrchestrationRun(id: childRunID),
      child.parentRunID == parentRunID
    else {
      throw CodexOrchestrationError.invalid(
        "child_run_id must identify a run whose parent_run_id is the selected parent"
      )
    }
    guard child.state == .completed else {
      throw CodexOrchestrationError.invalid(
        "child results can be reconciled only after the child run is accepted as completed"
      )
    }
    guard !childEvidenceIDs.isEmpty else {
      throw CodexOrchestrationError.invalid("child_evidence_ids must be non-empty")
    }
    let selected = child.evidence.filter { childEvidenceIDs.contains($0.id) }
    guard selected.count == Set(childEvidenceIDs).count else {
      throw CodexOrchestrationError.invalid(
        "every child_evidence_id must belong to the selected child run"
      )
    }
    return try database.updateCodexOrchestrationRun(
      id: parentRunID,
      workspaceID: workspaceID,
      expectedRevision: expectedRevision
    ) { parent in
      guard !parent.state.isTerminal else {
        throw CodexOrchestrationError.terminal(parentRunID)
      }
      guard
        let criterionIndex = parent.acceptanceCriteria.firstIndex(where: {
          $0.id == criterionID
        })
      else {
        throw CodexOrchestrationError.invalid("unknown parent criterion_id '\(criterionID)'")
      }
      let imported = selected.map { evidence in
        CodexRunEvidence(
          id: UUID().uuidString,
          kind: evidence.kind,
          summary: CodexApprovalRedactor.redactString(
            "Accepted from child run \(childRunID): \(evidence.summary)",
            maximumCharacters: 8_192
          ),
          requestID: evidence.requestID,
          correlationID: evidence.correlationID,
          artifact: evidence.artifact,
          repositoryDigest: evidence.repositoryDigest,
          createdAt: now
        )
      }
      parent.evidence.append(contentsOf: imported)
      parent.acceptanceCriteria[criterionIndex].evidenceIDs.append(
        contentsOf: imported.map(\.id)
      )
      if acceptCriterion {
        parent.acceptanceCriteria[criterionIndex].state = .passed
      }
      parent.lastMeaningfulProgressAt = now
      parent.updatedAt = now
      appendDiagnostic("child_results_reconciled", to: &parent)
    }
  }

  private static func applyBudgets(to run: inout CodexOrchestrationRun, now: Date) {
    guard !run.state.isTerminal else { return }
    if run.turnsUsed >= run.budget.maxTurns {
      run.state = .budgetLimited
      appendDiagnostic("turn_budget_exhausted", to: &run)
    }
    if now.timeIntervalSince(run.createdAt) >= TimeInterval(run.budget.maxDurationSeconds) {
      run.state = .budgetLimited
      appendDiagnostic("duration_budget_exhausted", to: &run)
    }
    if now.timeIntervalSince(run.lastMeaningfulProgressAt)
      >= TimeInterval(run.budget.maxNoProgressSeconds)
    {
      block(
        &run,
        code: "run_no_meaningful_progress",
        summary: "No meaningful progress was recorded within the configured bound.",
        external: false,
        now: now
      )
    }
  }

  @discardableResult
  private static func appendEvidence(
    _ event: CodexRunEvent,
    defaultKind: String,
    to run: inout CodexOrchestrationRun,
    now: Date
  ) -> CodexRunEvidence {
    let evidence = CodexRunEvidence(
      id: UUID().uuidString,
      kind: event.evidenceKind ?? defaultKind,
      summary: event.summary,
      requestID: event.requestID,
      correlationID: event.correlationID,
      artifact: event.artifact,
      repositoryDigest: event.repositoryDigest,
      createdAt: now
    )
    run.evidence.append(evidence)
    return evidence
  }

  private static func block(
    _ run: inout CodexOrchestrationRun,
    code: String,
    summary: String,
    external: Bool,
    now: Date
  ) {
    guard !run.blockers.contains(where: { $0.code == code && $0.summary == summary }) else {
      run.state = .blocked
      return
    }
    run.blockers.append(
      CodexRunBlocker(
        id: UUID().uuidString,
        code: code,
        summary: summary,
        external: external,
        createdAt: now
      )
    )
    run.state = .blocked
  }

  private static func appendDiagnostic(_ value: String, to run: inout CodexOrchestrationRun) {
    if !run.diagnostics.contains(value) { run.diagnostics.append(value) }
  }

  private static func require(_ database: GatewayDatabase?) throws -> GatewayDatabase {
    guard let database else { throw CodexOrchestrationError.unavailable }
    return database
  }

  private static func requireText(_ value: String, field: String) throws {
    guard hasText(value) else {
      throw CodexOrchestrationError.invalid("\(field) must be non-empty")
    }
  }

  private static func required(_ value: String?, field: String) throws -> String {
    guard let value, hasText(value) else {
      throw CodexOrchestrationError.invalid("\(field) must be non-empty")
    }
    return value
  }

  private static func hasText(_ value: String) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private static func persistedText(
    _ value: String,
    field: String,
    maximumCharacters: Int
  ) throws -> String {
    try requireText(value, field: field)
    guard value.count <= maximumCharacters else {
      throw CodexOrchestrationError.invalid(
        "\(field) must contain at most \(maximumCharacters) characters"
      )
    }
    return CodexApprovalRedactor.redactString(
      value,
      maximumCharacters: maximumCharacters
    )
  }

  private static func persistedIdentifier(
    _ value: String,
    field: String,
    maximumCharacters: Int = 1_024
  ) throws -> String {
    try requireText(value, field: field)
    guard value.count <= maximumCharacters,
      value.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw CodexOrchestrationError.invalid(
        "\(field) must contain at most \(maximumCharacters) characters without control characters"
      )
    }
    guard
      CodexApprovalRedactor.redactString(value, maximumCharacters: maximumCharacters) == value
    else {
      throw CodexOrchestrationError.invalid(
        "\(field) must not contain credential-like text"
      )
    }
    return value
  }

  private static func persistedEvent(_ event: CodexRunEvent) throws -> CodexRunEvent {
    let failureFingerprint: String?
    if let value = event.failureFingerprint {
      try requireText(value, field: "failure_fingerprint")
      guard value.count <= 32_768 else {
        throw CodexOrchestrationError.invalid(
          "failure_fingerprint must contain at most 32768 characters"
        )
      }
      switch event.kind {
      case .failure:
        failureFingerprint = fingerprint(value)
      default:
        failureFingerprint = try persistedText(
          value,
          field: "failure_fingerprint",
          maximumCharacters: 256
        )
      }
    } else {
      failureFingerprint = nil
    }
    return CodexRunEvent(
      kind: event.kind,
      summary: try persistedText(event.summary, field: "summary", maximumCharacters: 8_192),
      phase: try event.phase.map {
        try persistedText($0, field: "phase", maximumCharacters: 512)
      },
      nextAction: try event.nextAction.map {
        try persistedText($0, field: "next_action", maximumCharacters: 8_192)
      },
      turnID: try event.turnID.map { try persistedIdentifier($0, field: "turn_id") },
      approvalID: try event.approvalID.map {
        try persistedIdentifier($0, field: "approval_id")
      },
      commandID: try event.commandID.map { try persistedIdentifier($0, field: "command_id") },
      criterionID: try event.criterionID.map {
        try persistedIdentifier($0, field: "criterion_id")
      },
      evidenceKind: try event.evidenceKind.map {
        try persistedIdentifier($0, field: "evidence_kind", maximumCharacters: 128)
      },
      requestID: try event.requestID.map { try persistedIdentifier($0, field: "request_id") },
      correlationID: try event.correlationID.map {
        try persistedIdentifier($0, field: "correlation_id")
      },
      artifact: try event.artifact.map {
        try persistedText($0, field: "artifact", maximumCharacters: 8_192)
      },
      repositoryDigest: try event.repositoryDigest.map {
        try persistedIdentifier($0, field: "repository_digest")
      },
      failureFingerprint: failureFingerprint,
      externalBlocker: event.externalBlocker
    )
  }

  private static func fingerprint(_ value: String) -> String {
    let digest = SHA256.hash(data: Data(value.utf8))
    return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
  }
}
