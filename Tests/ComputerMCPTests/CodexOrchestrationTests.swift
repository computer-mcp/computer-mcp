import Foundation
import Testing

@testable import ComputerMCP

@Suite(.serialized)
final class CodexOrchestrationTests {
  @Test
  func testRunPersistsOfficialGoalLinkWithoutPretendingAcceptanceIsNative() throws {
    let database = try GatewayDatabase(inMemory: ())
    let run = try makeRun(database: database, officialGoalLinked: true)

    #expect(run.officialGoalLinked)
    #expect(run.threadID == "thread-1")
    #expect(run.acceptanceCriteria.map(\.state) == [.open, .open, .open])
    #expect(try database.codexOrchestrationRun(id: run.id) == run)
  }

  @Test
  func testCompletedTurnDoesNotCompleteOpenAcceptance() throws {
    let database = try GatewayDatabase(inMemory: ())
    var run = try makeRun(database: database)
    run = try CodexOrchestrationEngine.record(
      database: database,
      workspaceID: "workspace-1",
      runID: run.id,
      expectedRevision: run.revision,
      event: event(.turnStarted, turnID: "turn-1")
    )
    run = try CodexOrchestrationEngine.record(
      database: database,
      workspaceID: "workspace-1",
      runID: run.id,
      expectedRevision: run.revision,
      event: event(.turnCompleted)
    )

    #expect(run.state == .active)
    #expect(run.activeTurnID == nil)
    #expect(run.diagnostics.contains("turn_completed_with_open_acceptance"))
    #expect(run.acceptanceCriteria.allSatisfy { $0.state == .open })
  }

  @Test
  func testRepeatedPlanningAndIdenticalFailuresBecomeActionableBlockers() throws {
    let database = try GatewayDatabase(inMemory: ())
    var planning = try makeRun(database: database)
    for _ in 0..<3 {
      planning = try CodexOrchestrationEngine.record(
        database: database,
        workspaceID: "workspace-1",
        runID: planning.id,
        expectedRevision: planning.revision,
        event: event(.planning)
      )
    }
    #expect(planning.state == .blocked)
    #expect(
      planning.blockers.contains { $0.code == "repeated_planning_without_repository_change" }
    )

    var failure = try makeRun(database: database)
    for _ in 0..<3 {
      failure = try CodexOrchestrationEngine.record(
        database: database,
        workspaceID: "workspace-1",
        runID: failure.id,
        expectedRevision: failure.revision,
        event: event(.failure, failureFingerprint: "git:index-lock")
      )
    }
    #expect(failure.state == .blocked)
    #expect(failure.blockers.contains { $0.code == "repeated_identical_failure" })
  }

  @Test
  func testApprovalPauseAndNoProgressCommandAreDistinct() throws {
    let database = try GatewayDatabase(inMemory: ())
    var run = try makeRun(database: database)
    run = try CodexOrchestrationEngine.record(
      database: database,
      workspaceID: "workspace-1",
      runID: run.id,
      expectedRevision: run.revision,
      event: event(.approvalPending, approvalID: "approval-1")
    )
    #expect(run.state == .paused)
    #expect(run.pendingApprovalID == "approval-1")

    run = try CodexOrchestrationEngine.record(
      database: database,
      workspaceID: "workspace-1",
      runID: run.id,
      expectedRevision: run.revision,
      event: event(.approvalResolved, approvalID: "approval-1")
    )
    #expect(run.state == .active)

    let commandStartedAt = Date()
    run = try CodexOrchestrationEngine.record(
      database: database,
      workspaceID: "workspace-1",
      runID: run.id,
      expectedRevision: run.revision,
      event: event(.commandStarted, commandID: "command-1"),
      now: commandStartedAt
    )
    run = try CodexOrchestrationEngine.evaluate(
      database: database,
      workspaceID: "workspace-1",
      runID: run.id,
      expectedRevision: run.revision,
      now: commandStartedAt.addingTimeInterval(61)
    )
    #expect(run.state == .blocked)
    #expect(run.blockers.contains { $0.code == "command_no_progress" })
  }

  @Test
  func testBudgetLimitAndHardExternalBlockerRemainDistinct() throws {
    let database = try GatewayDatabase(inMemory: ())
    var budgetLimited = try CodexOrchestrationEngine.create(
      database: database,
      workspaceID: "workspace-1",
      workspacePath: "/tmp/workspace-1",
      parentRunID: nil,
      threadID: nil,
      officialGoalLinked: false,
      objective: "Use one bounded turn.",
      acceptedScope: ["verification"],
      phase: "verification",
      acceptanceCriteria: ["The bounded turn completes."],
      requiredEvidenceKinds: ["test"],
      budget: CodexRunBudget(
        maxTurns: 1,
        maxDurationSeconds: 3_600,
        maxNoProgressSeconds: 60,
        maxRepeatedFailures: 3
      )
    )
    budgetLimited = try CodexOrchestrationEngine.record(
      database: database,
      workspaceID: "workspace-1",
      runID: budgetLimited.id,
      expectedRevision: budgetLimited.revision,
      event: event(.turnStarted, turnID: "turn-1")
    )

    var externallyBlocked = try makeRun(database: database)
    externallyBlocked = try CodexOrchestrationEngine.record(
      database: database,
      workspaceID: "workspace-1",
      runID: externallyBlocked.id,
      expectedRevision: externallyBlocked.revision,
      event: CodexRunEvent(
        kind: .blocker,
        summary: "A required external service is unavailable.",
        phase: nil,
        nextAction: "Wait for the external service owner.",
        turnID: nil,
        approvalID: nil,
        commandID: nil,
        criterionID: nil,
        evidenceKind: nil,
        requestID: "request-fixture",
        correlationID: "correlation-fixture",
        artifact: nil,
        repositoryDigest: nil,
        failureFingerprint: "external_service_unavailable",
        externalBlocker: true
      )
    )

    #expect(budgetLimited.state == .budgetLimited)
    #expect(budgetLimited.diagnostics.contains("turn_budget_exhausted"))
    #expect(externallyBlocked.state == .blocked)
    #expect(externallyBlocked.blockers.contains { $0.external })
    #expect(externallyBlocked.state != budgetLimited.state)
  }

  @Test
  func testAcceptanceRejectsContradictionsThenCompletesWithAllEvidence() throws {
    let database = try GatewayDatabase(inMemory: ())
    var run = try makeRun(database: database)

    run = try CodexOrchestrationEngine.accept(
      database: database,
      workspaceID: "workspace-1",
      runID: run.id,
      expectedRevision: run.revision,
      worktreeClean: false
    )
    #expect(run.state == .blocked)
    #expect(run.blockers.contains { $0.code == "acceptance_open" })
    #expect(run.blockers.contains { $0.code == "acceptance_missing_evidence" })
    #expect(run.blockers.contains { $0.code == "acceptance_dirty_worktree" })
    #expect(run.diagnostics.contains("agent_completion_claim_contradicted_by_evidence"))

    run = try CodexOrchestrationEngine.transition(
      database: database,
      workspaceID: "workspace-1",
      runID: run.id,
      expectedRevision: run.revision,
      action: "resume",
      reason: nil
    )
    let evidenceKinds = ["build", "test", "git_status"]
    for (criterion, evidenceKind) in zip(run.acceptanceCriteria, evidenceKinds) {
      run = try CodexOrchestrationEngine.record(
        database: database,
        workspaceID: "workspace-1",
        runID: run.id,
        expectedRevision: run.revision,
        event: event(
          .acceptancePassed,
          criterionID: criterion.id,
          evidenceKind: evidenceKind,
          repositoryDigest: "digest-\(criterion.id)"
        )
      )
    }
    run = try CodexOrchestrationEngine.accept(
      database: database,
      workspaceID: "workspace-1",
      runID: run.id,
      expectedRevision: run.revision,
      worktreeClean: true
    )

    #expect(run.state == .completed)
    #expect(run.terminalReason?.contains("explicitly accepted") == true)
    #expect(run.acceptanceCriteria.allSatisfy { $0.state == .passed })
  }

  @Test
  func testOptimisticRevisionPreventsConcurrentOverwrite() throws {
    let database = try GatewayDatabase(inMemory: ())
    let run = try makeRun(database: database)
    _ = try CodexOrchestrationEngine.record(
      database: database,
      workspaceID: "workspace-1",
      runID: run.id,
      expectedRevision: run.revision,
      event: event(.planning)
    )

    #expect(throws: CodexOrchestrationError.self) {
      try CodexOrchestrationEngine.record(
        database: database,
        workspaceID: "workspace-1",
        runID: run.id,
        expectedRevision: run.revision,
        event: event(.planning)
      )
    }
  }

  @Test
  func testPersistedNarrativeIsRedactedAndFailureIdentityIsHashed() throws {
    let database = try GatewayDatabase(inMemory: ())
    var run = try CodexOrchestrationEngine.create(
      database: database,
      workspaceID: "workspace-1",
      workspacePath: "/tmp/workspace-1",
      parentRunID: nil,
      threadID: nil,
      officialGoalLinked: false,
      objective: "Deliver with token=objective-secret",
      acceptedScope: ["Inspect password=scope-secret"],
      phase: "implementation",
      acceptanceCriteria: ["Verify api_key=criterion-secret is absent"],
      requiredEvidenceKinds: ["test"],
      budget: CodexRunBudget(
        maxTurns: 10,
        maxDurationSeconds: 3_600,
        maxNoProgressSeconds: 60,
        maxRepeatedFailures: 3
      )
    )

    #expect(run.objective.contains("[REDACTED]"))
    #expect(!run.objective.contains("objective-secret"))
    #expect(!run.acceptedScope.joined().contains("scope-secret"))
    #expect(!run.acceptanceCriteria.map(\.description).joined().contains("criterion-secret"))

    run = try CodexOrchestrationEngine.record(
      database: database,
      workspaceID: "workspace-1",
      runID: run.id,
      expectedRevision: run.revision,
      event: CodexRunEvent(
        kind: .failure,
        summary: "Command failed with Authorization: Bearer event-secret",
        phase: nil,
        nextAction: "Retry without token=next-secret",
        turnID: nil,
        approvalID: nil,
        commandID: nil,
        criterionID: nil,
        evidenceKind: nil,
        requestID: "request-1",
        correlationID: "correlation-1",
        artifact: "https://example.invalid/log?token=artifact-secret",
        repositoryDigest: nil,
        failureFingerprint: "password=fingerprint-secret",
        externalBlocker: false
      )
    )

    #expect(run.repeatedFailureFingerprint?.hasPrefix("sha256:") == true)
    #expect(run.repeatedFailureFingerprint?.contains("fingerprint-secret") == false)
    #expect(run.nextAction?.contains("next-secret") == false)
    let persisted = try #require(try database.codexOrchestrationRun(id: run.id))
    let encoded = try String(
      decoding: JSONEncoder().encode(persisted),
      as: UTF8.self
    )
    #expect(!encoded.contains("objective-secret"))
    #expect(!encoded.contains("scope-secret"))
    #expect(!encoded.contains("criterion-secret"))
    #expect(!encoded.contains("event-secret"))
    #expect(!encoded.contains("next-secret"))
    #expect(!encoded.contains("artifact-secret"))
    #expect(!encoded.contains("fingerprint-secret"))
  }

  @Test
  func testCompletedChildImportsOnlyExplicitlySelectedEvidence() throws {
    let database = try GatewayDatabase(inMemory: ())
    var parent = try makeRun(database: database)
    var child = try CodexOrchestrationEngine.create(
      database: database,
      workspaceID: "workspace-1",
      workspacePath: "/tmp/workspace-1",
      parentRunID: parent.id,
      threadID: nil,
      officialGoalLinked: false,
      objective: "Verify the child scope.",
      acceptedScope: ["child-tests"],
      phase: "verification",
      acceptanceCriteria: ["Child tests pass"],
      requiredEvidenceKinds: ["test"],
      budget: CodexRunBudget(
        maxTurns: 10,
        maxDurationSeconds: 3_600,
        maxNoProgressSeconds: 60,
        maxRepeatedFailures: 3
      )
    )
    child = try CodexOrchestrationEngine.record(
      database: database,
      workspaceID: "workspace-1",
      runID: child.id,
      expectedRevision: child.revision,
      event: event(
        .repositoryChanged,
        repositoryDigest: "unselected-repository-digest"
      )
    )
    child = try CodexOrchestrationEngine.record(
      database: database,
      workspaceID: "workspace-1",
      runID: child.id,
      expectedRevision: child.revision,
      event: event(
        .acceptancePassed,
        criterionID: "criterion-1",
        evidenceKind: "test",
        repositoryDigest: "selected-test-digest"
      )
    )
    child = try CodexOrchestrationEngine.accept(
      database: database,
      workspaceID: "workspace-1",
      runID: child.id,
      expectedRevision: child.revision,
      worktreeClean: true
    )
    let selectedEvidence = try #require(
      child.evidence.first { $0.repositoryDigest == "selected-test-digest" }
    )

    parent = try CodexOrchestrationEngine.reconcileChild(
      database: database,
      workspaceID: "workspace-1",
      parentRunID: parent.id,
      expectedRevision: parent.revision,
      childRunID: child.id,
      childEvidenceIDs: [selectedEvidence.id],
      criterionID: "criterion-1",
      acceptCriterion: true
    )

    #expect(parent.acceptanceCriteria[0].state == .passed)
    #expect(parent.acceptanceCriteria[0].evidenceIDs.count == 1)
    #expect(parent.evidence.count == 1)
    #expect(parent.evidence[0].repositoryDigest == "selected-test-digest")
    #expect(parent.evidence[0].summary.contains("Accepted from child run"))
    #expect(!parent.evidence.contains { $0.repositoryDigest == "unselected-repository-digest" })
    #expect(parent.diagnostics.contains("child_results_reconciled"))
  }

  private func makeRun(
    database: GatewayDatabase,
    officialGoalLinked: Bool = false
  ) throws -> CodexOrchestrationRun {
    try CodexOrchestrationEngine.create(
      database: database,
      workspaceID: "workspace-1",
      workspacePath: "/tmp/workspace-1",
      parentRunID: nil,
      threadID: officialGoalLinked ? "thread-1" : nil,
      officialGoalLinked: officialGoalLinked,
      objective: "Deliver the complete product batch.",
      acceptedScope: ["runtime", "website"],
      phase: "implementation",
      acceptanceCriteria: ["Build passes", "Tests pass", "Worktree is clean"],
      requiredEvidenceKinds: ["build", "test", "git_status"],
      budget: CodexRunBudget(
        maxTurns: 100,
        maxDurationSeconds: 86_400,
        maxNoProgressSeconds: 60,
        maxRepeatedFailures: 3
      )
    )
  }

  private func event(
    _ kind: CodexRunEventKind,
    turnID: String? = nil,
    approvalID: String? = nil,
    commandID: String? = nil,
    criterionID: String? = nil,
    evidenceKind: String? = nil,
    repositoryDigest: String? = nil,
    failureFingerprint: String? = nil
  ) -> CodexRunEvent {
    CodexRunEvent(
      kind: kind,
      summary: "Fixture event \(kind.rawValue)",
      phase: nil,
      nextAction: "Continue with the next acceptance criterion.",
      turnID: turnID,
      approvalID: approvalID,
      commandID: commandID,
      criterionID: criterionID,
      evidenceKind: evidenceKind,
      requestID: "request-fixture",
      correlationID: "correlation-fixture",
      artifact: nil,
      repositoryDigest: repositoryDigest,
      failureFingerprint: failureFingerprint,
      externalBlocker: false
    )
  }
}
