import CryptoKit
import Darwin
import Foundation

struct CodexThreadOwnershipReconciliationCandidate: Codable, Equatable, Sendable {
  let threadID: String
  let workspaceID: String?
  let runtimeID: String
  let recordedState: String
  let reason: String

  private enum CodingKeys: String, CodingKey {
    case threadID = "thread_id"
    case workspaceID = "workspace_id"
    case runtimeID = "runtime_id"
    case recordedState = "recorded_state"
    case reason
  }
}

struct CodexThreadOwnershipReconciliationPlan: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let planDigest: String
  let candidates: [CodexThreadOwnershipReconciliationCandidate]
  let signalsSent: Bool
  let externalStateMutated: Bool

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case planDigest = "plan_digest"
    case candidates
    case signalsSent = "signals_sent"
    case externalStateMutated = "external_state_mutated"
  }

  var json: JSONValue {
    (try? JSONValue.encoded(self)) ?? .object([:])
  }
}

struct CodexThreadOwnershipReconciliationResult: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let receiptID: String
  let planDigest: String
  let releasedThreadIDs: [String]
  let appliedAt: Date
  let signalsSent: Bool
  let externalStateMutated: Bool

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case receiptID = "receipt_id"
    case planDigest = "plan_digest"
    case releasedThreadIDs = "released_thread_ids"
    case appliedAt = "applied_at"
    case signalsSent = "signals_sent"
    case externalStateMutated = "external_state_mutated"
  }

  var json: JSONValue {
    (try? JSONValue.encoded(self)) ?? .object([:])
  }
}

enum CodexThreadOwnershipReconciliationError: Error, LocalizedError {
  case planChanged(expected: String, actual: String)

  var errorDescription: String? {
    switch self {
    case .planChanged(let expected, let actual):
      return
        "Thread ownership reconciliation changed; expected plan digest \(expected), actual \(actual). Run preview again."
    }
  }
}

enum CodexThreadOwnershipReconciliation {
  static func preview(
    database: GatewayDatabase?,
    workspaceID: String? = nil,
    runtimeID: String? = nil
  ) throws -> CodexThreadOwnershipReconciliationPlan {
    guard let database else {
      return makePlan(candidates: [])
    }
    let leases = Dictionary(
      uniqueKeysWithValues: try database.codexRuntimeLeases(limit: 5_000).map { ($0.id, $0) }
    )
    let candidates = try database.codexThreadOwnerships(workspaceID: workspaceID, limit: 5_000)
      .filter { $0.state == .loaded && (runtimeID == nil || $0.runtimeID == runtimeID) }
      .compactMap { ownership -> CodexThreadOwnershipReconciliationCandidate? in
        guard CodexRuntimeDirectory.shared.runtime(id: ownership.runtimeID) == nil else {
          return nil
        }
        let lease = leases[ownership.runtimeID]
        guard isSafelyGone(lease) else { return nil }
        return CodexThreadOwnershipReconciliationCandidate(
          threadID: ownership.threadID,
          workspaceID: ownership.workspaceID,
          runtimeID: ownership.runtimeID,
          recordedState: ownership.state.rawValue,
          reason: lease == nil
            ? "ownership_receipt_without_runtime_receipt"
            : "ownership_receipt_without_live_runtime"
        )
      }
      .sorted { ($0.threadID, $0.runtimeID) < ($1.threadID, $1.runtimeID) }
    return makePlan(candidates: candidates)
  }

  static func apply(
    database: GatewayDatabase?,
    expectedPlanDigest: String,
    workspaceID: String? = nil,
    runtimeID: String? = nil,
    now: Date = Date()
  ) throws -> CodexThreadOwnershipReconciliationResult {
    guard let database else {
      throw GatewayToolError.disabled(
        "codex.app.runtime_persistence_unavailable: Ownership reconciliation requires the Gateway Database."
      )
    }
    let plan = try preview(database: database, workspaceID: workspaceID, runtimeID: runtimeID)
    guard plan.planDigest == expectedPlanDigest else {
      throw CodexThreadOwnershipReconciliationError.planChanged(
        expected: expectedPlanDigest,
        actual: plan.planDigest
      )
    }
    return try database.applyCodexThreadOwnershipReconciliation(plan: plan, now: now)
  }

  @discardableResult
  static func reconcileSafely(
    database: GatewayDatabase?,
    workspaceID: String? = nil,
    runtimeID: String? = nil,
    now: Date = Date()
  ) throws -> CodexThreadOwnershipReconciliationResult? {
    let plan = try preview(database: database, workspaceID: workspaceID, runtimeID: runtimeID)
    guard !plan.candidates.isEmpty else { return nil }
    return try apply(
      database: database,
      expectedPlanDigest: plan.planDigest,
      workspaceID: workspaceID,
      runtimeID: runtimeID,
      now: now
    )
  }

  static func hasLiveReceiptedProcess(
    database: GatewayDatabase?,
    runtimeID: String
  ) throws -> Bool {
    guard let database else { return false }
    let lease = try database.codexRuntimeLeases(limit: 5_000).first { $0.id == runtimeID }
    return processExists(lease?.process?.processID)
      || processExists(lease?.process?.supervisorProcessID)
  }

  private static func makePlan(
    candidates: [CodexThreadOwnershipReconciliationCandidate]
  ) -> CodexThreadOwnershipReconciliationPlan {
    let encoder = CanonicalJSONCoding.encoder(outputFormatting: [.sortedKeys])
    let data = (try? encoder.encode(candidates)) ?? Data()
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return CodexThreadOwnershipReconciliationPlan(
      schemaVersion: 1,
      planDigest: digest,
      candidates: candidates,
      signalsSent: false,
      externalStateMutated: false
    )
  }

  private static func isSafelyGone(_ lease: CodexRuntimeLeaseRecord?) -> Bool {
    guard let lease else { return true }
    if processExists(lease.process?.processID)
      || processExists(lease.process?.supervisorProcessID)
    {
      return false
    }
    return lease.runtimeState == "stopped"
      || ["stopped", "cleaned", "failed", "running", "starting"].contains(lease.state)
  }

  private static func processExists(_ processID: Int32?) -> Bool {
    guard let processID, processID > 1 else { return false }
    errno = 0
    return Darwin.kill(processID, 0) == 0 || errno != ESRCH
  }
}
