import Darwin
import Foundation

struct CodexRuntimeLeaseRecord: Codable, Equatable, Sendable, Identifiable {
  let id: String
  let owner: CodexRuntimeOwner?
  let workspacePath: String
  var state: String
  var process: CodexAppServerProcessSnapshot?
  let createdAt: Date
  var updatedAt: Date
  var shutdownReason: String?
  var cleanedAt: Date?

  var json: JSONValue {
    (try? JSONValue.encoded(self)) ?? .object([:])
  }
}

enum CodexRuntimeMaintenance {
  static func preview(
    database: GatewayDatabase?,
    workspaceID: String?
  ) throws -> JSONValue {
    let records = try visibleRecords(database: database, workspaceID: workspaceID)
    return .object([
      "candidates": .array(records.map(candidate)),
      "signals_sent": .bool(false),
      "safety": .string(
        "Cleanup targets only persisted Computer MCP runtime records. Live processes remain owned by their per-runtime watchdog; unrelated Codex processes are never signaled."
      ),
    ])
  }

  static func cleanup(
    database: GatewayDatabase?,
    workspaceID: String?
  ) async throws -> JSONValue {
    guard let database else {
      throw GatewayToolError.disabled(
        "codex.app.runtime_persistence_unavailable: Runtime cleanup requires the Gateway Database."
      )
    }
    var cleaned: [JSONValue] = []
    var pending: [JSONValue] = []
    for var record in try visibleRecords(database: database, workspaceID: workspaceID) {
      guard CodexRuntimeDirectory.shared.runtime(id: record.id) == nil else { continue }
      if processExists(record.process?.processID)
        || processExists(record.process?.supervisorProcessID)
      {
        pending.append(candidate(record))
        continue
      }
      record.state = "cleaned"
      record.updatedAt = Date()
      record.cleanedAt = record.updatedAt
      record.shutdownReason = record.shutdownReason ?? "stale_record_cleaned"
      try database.saveCodexRuntimeLease(record)
      cleaned.append(record.json)
    }
    return .object([
      "cleaned": .array(cleaned),
      "watchdog_pending": .array(pending),
      "signals_sent": .bool(false),
    ])
  }

  private static func visibleRecords(
    database: GatewayDatabase?,
    workspaceID: String?
  ) throws -> [CodexRuntimeLeaseRecord] {
    guard let database else { return [] }
    return try database.codexRuntimeLeases(limit: 5_000).filter {
      $0.owner?.workspaceID == workspaceID
        && ["starting", "running", "failed"].contains($0.state)
    }
  }

  private static func candidate(_ record: CodexRuntimeLeaseRecord) -> JSONValue {
    let directoryActive = CodexRuntimeDirectory.shared.runtime(id: record.id) != nil
    let processActive =
      processExists(record.process?.processID)
      || processExists(record.process?.supervisorProcessID)
    return .object([
      "runtime": record.json,
      "directory_active": .bool(directoryActive),
      "process_active": .bool(processActive),
      "classification": .string(
        directoryActive ? "active" : processActive ? "watchdog_pending" : "stale_record"
      ),
      "cleanup_ready": .bool(!directoryActive && !processActive),
    ])
  }

  private static func processExists(_ processID: Int32?) -> Bool {
    guard let processID, processID > 1 else { return false }
    errno = 0
    return Darwin.kill(processID, 0) == 0 || errno != ESRCH
  }
}
