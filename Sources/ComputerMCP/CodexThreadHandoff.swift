import Foundation

enum CodexThreadHandoffMode: String, Codable, Sendable {
  case graceful
  case forceComputerMCPOwnedRuntimeOnly = "force-computer-mcp-owned-runtime-only"
}

enum CodexThreadHandoffState: String, Codable, Sendable {
  case active
  case idleLoaded = "idle-loaded"
  case releaseRequested = "release-requested"
  case released
  case externallyClaimable = "externally-claimable"
  case stopped
  case staleReceipt = "stale-receipt"
  case inconsistent
}

struct CodexRuntimeThreadReleaseResult: Codable, Sendable {
  let runtimeID: String
  let priorState: CodexThreadHandoffState
  let activeTurnHandling: String
  let pendingRequestHandling: String
  let subscriptionRelease: String
  let loadedState: String
  let runtimeAction: String

  private enum CodingKeys: String, CodingKey {
    case runtimeID = "runtime_id"
    case priorState = "prior_state"
    case activeTurnHandling = "active_turn_handling"
    case pendingRequestHandling = "pending_request_handling"
    case subscriptionRelease = "subscription_release"
    case loadedState = "loaded_state"
    case runtimeAction = "runtime_action"
  }

  var json: JSONValue {
    (try? JSONValue.encoded(self)) ?? .object([:])
  }
}

enum CodexThreadHandoffError: Error, LocalizedError, Sendable {
  case activeTurn(runtimeID: String, turnID: String)
  case pendingLifecycle(runtimeID: String, approvals: Int, userInput: Int)
  case stillLoaded(runtimeID: String)
  case unknownThread(String)
  case postconditionFailed([String])

  var errorDescription: String? {
    switch self {
    case .activeTurn(let runtimeID, let turnID):
      return
        "Thread has active turn '\(turnID)' in Computer MCP runtime '\(runtimeID)'. Retry with interrupt_active_turn=true or wait for the turn to complete."
    case .pendingLifecycle(let runtimeID, let approvals, let userInput):
      return
        "Runtime '\(runtimeID)' has \(approvals) pending approval(s) and \(userInput) pending user-input request(s) for this thread. Resolve them or use force-computer-mcp-owned-runtime-only."
    case .stillLoaded(let runtimeID):
      return
        "Runtime '\(runtimeID)' still reports the thread loaded after unsubscribe and also owns other useful work. Retry with force-computer-mcp-owned-runtime-only only after reviewing that runtime."
    case .unknownThread(let threadID):
      return "Thread '\(threadID)' has no Computer MCP runtime or persisted ownership receipt."
    case .postconditionFailed(let runtimeIDs):
      return
        "Handoff postcondition failed because Computer MCP runtime(s) still own the thread: \(runtimeIDs.sorted().joined(separator: ", "))."
    }
  }
}

enum CodexThreadHandoffService {
  static func release(
    threadID: String,
    workspaceID: String?,
    mode: CodexThreadHandoffMode,
    interruptActiveTurn: Bool,
    database: GatewayDatabase?
  ) async throws -> JSONValue {
    let correlationID = UUID().uuidString
    let priorDiagnosis = await CodexThreadHandoffDiagnostics.diagnose(
      threadID: threadID,
      observedError: nil,
      workspaceID: workspaceID,
      database: database
    )
    let priorClassification =
      priorDiagnosis.objectValue?["classification"]?.stringValue ?? "unknown"

    var runtimeResults: [CodexRuntimeThreadReleaseResult] = []
    let matchingRuntimes = await CodexRuntimeDirectory.shared.runtimes(
      owning: threadID,
      workspaceID: workspaceID
    )
    var ownership = try database?.codexThreadOwnership(threadID: threadID)
    if matchingRuntimes.isEmpty, ownership == nil {
      throw GatewayToolError.invalidArguments(
        "codex.app.handoff_thread_unknown: \(CodexThreadHandoffError.unknownThread(threadID).localizedDescription)"
      )
    }
    if let ownership, workspaceID != nil, ownership.workspaceID != workspaceID {
      throw GatewayToolError.disabled(
        "codex.app.thread_outside_workspace: The thread belongs to a different registered workspace."
      )
    }
    let receiptedRuntimeIsCoordinated =
      ownership.flatMap { record in
        CodexRuntimeDirectory.shared.runtime(id: record.runtimeID, workspaceID: workspaceID)
      } != nil
    if matchingRuntimes.isEmpty, !receiptedRuntimeIsCoordinated, let record = ownership,
      try CodexThreadOwnershipReconciliation.hasLiveReceiptedProcess(
        database: database,
        runtimeID: record.runtimeID
      )
    {
      throw GatewayToolError.disabled(
        "codex.app.handoff_owned_process_still_running: The exact receipted Computer MCP process is still alive, so external claimability cannot yet be established."
      )
    }
    if matchingRuntimes.isEmpty, let record = ownership, record.state == .loaded {
      let plan = try CodexThreadOwnershipReconciliation.preview(
        database: database,
        workspaceID: workspaceID,
        runtimeID: record.runtimeID
      )
      guard plan.candidates.contains(where: { $0.threadID == threadID }) else {
        throw GatewayToolError.disabled(
          "codex.app.handoff_stale_ownership_unverified: The loaded ownership receipt cannot yet be safely reconciled."
        )
      }
      _ = try CodexThreadOwnershipReconciliation.apply(
        database: database,
        expectedPlanDigest: plan.planDigest,
        workspaceID: workspaceID,
        runtimeID: record.runtimeID
      )
      ownership = try database?.codexThreadOwnership(threadID: threadID)
    }

    var preparations: [(runtime: LiveCodexAppServerRuntime, id: UUID)] = []
    do {
      for runtime in matchingRuntimes {
        let preparationID = try await runtime.prepareForHandoff(
          threadID: threadID,
          mode: mode,
          interruptActiveTurn: interruptActiveTurn
        )
        preparations.append((runtime, preparationID))
      }
    } catch {
      for preparation in preparations {
        await preparation.runtime.cancelHandoffPreparation(
          threadID: threadID,
          preparationID: preparation.id
        )
      }
      throw error
    }
    do {
      for preparation in preparations {
        runtimeResults.append(
          try await preparation.runtime.releaseForHandoff(
            threadID: threadID,
            mode: mode,
            interruptActiveTurn: interruptActiveTurn,
            preparationID: preparation.id
          )
        )
      }
    } catch {
      for preparation in preparations {
        await preparation.runtime.cancelHandoffPreparation(
          threadID: threadID,
          preparationID: preparation.id
        )
      }
      throw error
    }
    try database?.invalidateCodexElevationGrants(
      workspaceID: workspaceID,
      threadID: threadID,
      consumedRuntimeIDs: Set(runtimeResults.map(\.runtimeID)),
      reason: "The bound thread was released for handoff."
    )

    if var record = ownership {
      record.state = .released
      record.updatedAt = Date()
      try database?.saveCodexThreadOwnership(record)
      ownership = record
    }

    let remaining = await CodexRuntimeDirectory.shared.runtimeIDs(
      owning: threadID,
      workspaceID: workspaceID
    )
    guard remaining.isEmpty else {
      throw GatewayToolError.executionFailed(
        "codex.app.handoff_postcondition_failed: \(CodexThreadHandoffError.postconditionFailed(remaining).localizedDescription)"
      )
    }

    let finalDiagnosis = await CodexThreadHandoffDiagnostics.diagnose(
      threadID: threadID,
      observedError: nil,
      workspaceID: workspaceID,
      database: database
    )
    let finalClassification =
      finalDiagnosis.objectValue?["classification"]?.stringValue ?? "unknown"
    guard finalClassification == "released_persisted" else {
      throw GatewayToolError.executionFailed(
        "codex.app.handoff_classification_inconsistent: Expected released_persisted, received '\(finalClassification)'."
      )
    }

    return .object([
      "thread_id": .string(threadID),
      "workspace_id": workspaceID.map(JSONValue.string) ?? .null,
      "mode": .string(mode.rawValue),
      "correlation_id": .string(correlationID),
      "prior_classification": .string(priorClassification),
      "runtime_results": .array(runtimeResults.map(\.json)),
      "final_classification": .string(finalClassification),
      "goal_preservation": .string("persisted-and-unchanged"),
      "persisted_ownership": ownership?.json ?? .null,
      "computer_mcp_writer_ownership_remaining": .bool(false),
      "externally_claimable": .bool(true),
      "already_released": .bool(matchingRuntimes.isEmpty),
    ])
  }
}
