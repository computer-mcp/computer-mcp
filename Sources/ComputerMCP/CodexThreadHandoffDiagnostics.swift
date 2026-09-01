import Foundation

enum CodexThreadHandoffDiagnostics {
  static func diagnose(
    threadID: String,
    observedError: String?,
    workspaceID: String?,
    database: GatewayDatabase?
  ) async -> JSONValue {
    let live = await CodexRuntimeDirectory.shared.statuses(workspaceID: workspaceID)
    let runtimes = live.objectValue?["runtimes"]?.arrayValue ?? []
    let matching = runtimes.filter { runtime in
      runtime.objectValue?["threads"]?.arrayValue?.contains { thread in
        thread.objectValue?["thread_id"]?.stringValue == threadID
      } == true
    }
    let matchingThreads = matching.flatMap { runtime -> [JSONValue] in
      let runtimeObject = runtime.objectValue ?? [:]
      return (runtimeObject["threads"]?.arrayValue ?? []).compactMap { thread in
        guard thread.objectValue?["thread_id"]?.stringValue == threadID else { return nil }
        return .object([
          "runtime_id": runtimeObject["runtime_id"] ?? .null,
          "owner": runtimeObject["owner"] ?? .null,
          "process": runtimeObject["process"] ?? .null,
          "runtime_state": runtimeObject["state"] ?? .string("unknown"),
          "thread": thread,
        ])
      }
    }
    let pendingApprovals =
      ((try? database?.codexApprovals(workspaceID: workspaceID, limit: 1_000))
      ?? []).filter { $0.threadID == threadID && $0.state == .pending }
    let storedOwnership = try? database?.codexThreadOwnership(threadID: threadID)
    let ownership = storedOwnership.flatMap { record in
      workspaceID == nil || record.workspaceID == workspaceID ? record : nil
    }
    let lastRuntimeReceipt = ownership.flatMap { record in
      ((try? database?.codexRuntimeLeases(limit: 5_000)) ?? []).first {
        $0.id == record.runtimeID
      }
    }
    let activeComputerMCP = matchingThreads.contains { item in
      guard let thread = item.objectValue?["thread"]?.objectValue else { return false }
      return thread["loaded"]?.boolValue == true
        || thread["subscribed"]?.boolValue == true
        || thread["active_turn_id"] != .null && thread["active_turn_id"] != nil
    }
    let errorSuggestsWriterConflict = observedError.map(isWriterConflict) ?? false
    let safeObservedError = observedError.map {
      CodexApprovalRedactor.redactString($0, maximumCharacters: 8_192)
    }
    let classification: String
    let explanation: String
    let actions: [JSONValue]
    if activeComputerMCP {
      classification = "computer_mcp_owned"
      explanation =
        "A live Computer MCP-owned App Server has this thread loaded, subscribed, or active. Release the thread or stop that exact runtime before opening it in Codex Desktop."
      actions = matching.compactMap { runtime in
        guard let runtimeID = runtime.objectValue?["runtime_id"]?.stringValue else { return nil }
        return .object([
          "tool": .string("codex.app.runtimes.inspect"),
          "arguments": .object(["runtime_id": .string(runtimeID)]),
          "then": .object([
            "tool": .string("codex.app.thread.release"),
            "arguments": .object(["thread_id": .string(threadID)]),
          ]),
        ])
      }
    } else if errorSuggestsWriterConflict {
      classification = "external_writer_or_unfinished_watchdog"
      explanation =
        "No live Computer MCP runtime in this workspace reports ownership. The observed writer-conflict message may come from Codex Desktop, an IDE, a CLI, another gateway process, or a Computer MCP watchdog still completing shutdown. Computer MCP will not signal an unverified external process."
      actions = [
        .object([
          "tool": .string("codex.app.runtimes.cleanup.preview"),
          "arguments": .object([:]),
        ])
      ]
    } else if !matchingThreads.isEmpty
      || ownership.map({ [.released, .archived].contains($0.state) }) == true
    {
      classification = "released_persisted"
      explanation =
        "Computer MCP knows this thread but no live Computer MCP runtime reports it loaded, subscribed, or active. The persisted thread is ready for another official Codex client to claim."
      actions = []
    } else if ownership != nil {
      classification = "ownership_receipt_without_live_runtime"
      explanation =
        "Computer MCP has a durable ownership receipt for this thread, but its recorded runtime is not live in this gateway process. Reconcile the recorded runtime receipt before deliberately reclaiming the thread."
      actions = [
        .object([
          "tool": .string("codex.app.runtimes.cleanup.preview"),
          "arguments": .object([:]),
        ]),
        .object([
          "tool": .string("codex.app.thread.reclaim"),
          "arguments": .object(["thread_id": .string(threadID)]),
          "warning": .string(
            "A reclaim attempt never terminates another official Codex client; a live writer conflict remains an error."
          ),
        ]),
      ]
    } else {
      classification = "persisted_or_external"
      explanation =
        "No live Computer MCP runtime in this workspace reports the thread. It may be persisted and idle or owned by an external official Codex client; Computer MCP cannot inspect or terminate that external connection."
      actions = [
        .object([
          "tool": .string("codex.app.thread.reclaim"),
          "arguments": .object(["thread_id": .string(threadID)]),
          "warning": .string(
            "Use only when Computer MCP should deliberately become the writer. A conflict will be returned without terminating another application."
          ),
        ])
      ]
    }

    return .object([
      "thread_id": .string(threadID),
      "workspace_id": workspaceID.map(JSONValue.string) ?? .null,
      "classification": .string(classification),
      "explanation": .string(explanation),
      "computer_mcp_ownership": .array(matchingThreads),
      "persisted_ownership": ownership?.json ?? .null,
      "last_runtime_receipt": lastRuntimeReceipt?.json ?? .null,
      "pending_approvals": .array(pendingApprovals.map(\.json)),
      "observed_error": safeObservedError.map(JSONValue.string) ?? .null,
      "safe_actions": .array(actions),
      "external_owner_visible": .bool(false),
      "external_process_signals_allowed": .bool(false),
    ])
  }

  private static func isWriterConflict(_ value: String) -> Bool {
    let normalized = value.lowercased()
    return normalized.contains("another application")
      || normalized.contains("writer conflict")
      || normalized.contains("writer lease")
      || normalized.contains("opened in another")
  }
}
