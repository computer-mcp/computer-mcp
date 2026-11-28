import Foundation

package struct RecoveryStoreView: Sendable {
  package let key: String
  package let generation: UUID
  package let repository: WorktreeRepositoryIdentity
  package let format: WorktreeObjectFormat
  package let records: [WorktreeRecoveryRecord]
  package let dependencies: [UUID: [Dependency]]
  package let removedWorktreeIDs: Set<UUID>
  package let activeOperation: RecoveryOperationStatus?

  package enum Dependency: Sendable, Equatable {
    case catalog(UUID)
    case lifecycle
    case protectedFinalCapture
    case expectedPublishedCommit
    case unresolvedOwner
  }
}

package struct RecoveryOperationHandle: Codable, Equatable, Sendable {
  package enum Action: String, Codable, Sendable { case release, maintenance }

  package let storeKey: String
  package let generation: UUID
  package let action: Action
  package let id: UUID
  package let requestDigest: String
}

package struct RecoveryReleaseReview: Codable, Equatable, Sendable {
  package let handle: RecoveryOperationHandle
  let release: RecoveryReleaseRequest
  package var records: [WorktreeRecoveryRecord] { release.records }
}

package struct RecoveryMaintenanceReview: Codable, Equatable, Sendable {
  package let handle: RecoveryOperationHandle
  let proof: WorktreeRecoveryMaintenanceProof
  package var packHash: String? { proof.candidate?.hash }
  package var baselineBytes: Int64 { proof.allocatedBytes }
}

package enum RecoveryMaintenancePreparation: Sendable {
  case reviewed(RecoveryMaintenanceReview)
  case deferred(String)
  case recoveryRequired(String)
}

package enum RecoveryReviewedRequest: Codable, Equatable, Sendable {
  case release(RecoveryReleaseReview)
  case maintenance(RecoveryMaintenanceReview)

  package var handle: RecoveryOperationHandle {
    switch self {
    case .release(let review): review.handle
    case .maintenance(let review): review.handle
    }
  }

  func validate(principal: String, repository: WorktreeRepositoryIdentity) throws {
    let expected: String
    let action: RecoveryOperationHandle.Action
    switch self {
    case .release(let review):
      action = .release
      expected = try Self.digest(review.release, handle: handle, principal: principal)
      try review.release.validate(handle: handle, repository: repository)
    case .maintenance(let review):
      action = .maintenance
      expected = try Self.digest(review.proof, handle: handle, principal: principal)
      try review.proof.validate(format: repository.format)
    }
    guard handle.action == action, handle.requestDigest == expected else {
      throw WorktreeRecoveryOwnerError.identityConflict
    }
  }

  private struct Binding<Payload: Encodable>: Encodable {
    let schema = 1
    let storeKey: String
    let generation: UUID
    let id: UUID
    let action: RecoveryOperationHandle.Action
    let principal: String
    let payload: Payload
  }

  static func issue(
    _ payload: some Encodable, key: String, generation: UUID,
    action: RecoveryOperationHandle.Action, principal: String
  ) throws -> RecoveryOperationHandle {
    let id = UUID()
    let identity = RecoveryOperationHandle(
      storeKey: key, generation: generation, action: action, id: id, requestDigest: "")
    return try .init(
      storeKey: key, generation: generation, action: action, id: id,
      requestDigest: digest(payload, handle: identity, principal: principal))
  }

  private static func digest(
    _ payload: some Encodable, handle: RecoveryOperationHandle, principal: String
  ) throws -> String {
    let bytes = try recoveryJSON(
      Binding(
        storeKey: handle.storeKey, generation: handle.generation, id: handle.id,
        action: handle.action, principal: principal, payload: payload))
    guard bytes.count <= RecoveryOwnerJournal.byteLimit else {
      throw WorktreeError.busy("Recovery review exceeds its byte limit.")
    }
    return WorktreeObjectSnapshot.digest(bytes)
  }

}

package struct RecoveryOperationStatus: Codable, Equatable, Sendable {
  package enum Outcome: Codable, Equatable, Sendable {
    case pending
    case released
    case busy(String)
    case stale
    case deferred(String)
    case measured(RecoveryPackAllocation)
    case recoveryRequired(String)
  }

  package enum GateCleanup: String, Codable, Equatable, Sendable {
    case pending, cleared, identityChanged
  }

  package struct Gate: Codable, Equatable, Sendable {
    package let projectID: String
    package let storageGeneration: UUID
    package let cleanup: GateCleanup
  }

  package let request: RecoveryReviewedRequest
  package let revision: Int64
  package let outcome: Outcome
  package let gates: [Gate]
}

package struct RecoveryPackAllocation: Codable, Equatable, Sendable {
  package let baselineBytes: Int64
  package let finalBytes: Int64
  package let reclaimedBytes: Int64

  init(baseline: Int64, final: Int64) throws {
    let (delta, overflow) = baseline.subtractingReportingOverflow(final)
    guard !overflow, final >= 0, delta >= 0 else { throw invalidRecoveryMetadata() }
    baselineBytes = baseline
    finalBytes = final
    reclaimedBytes = delta
  }
}

package enum RecoveryOperationLookup: Sendable {
  case unsubmitted
  case submitted(RecoveryOperationStatus)
}

package enum WorktreeRecoveryOwnerError: Error, Equatable {
  case unauthorized, unavailable, storeChanged, identityConflict, unsubmitted
}

struct RecoveryReleaseRequest: Codable, Equatable, Sendable {
  struct Gate: Codable, Equatable, Sendable {
    let record: DerivedProjectRecord
    let existing: WorktreeAdmission?
  }

  let records: [WorktreeRecoveryRecord]
  let gates: [Gate]

  func receipts(for handle: RecoveryOperationHandle) throws -> [WorktreeRecoveryReleaseReceipt] {
    try WorktreeRecoveryReleaseReceipt.batch(
      for: records, operationID: handle.id, requestDigest: handle.requestDigest)
  }

  func validate(handle: RecoveryOperationHandle, repository: WorktreeRepositoryIdentity) throws {
    guard !records.isEmpty, records.count <= WorktreeRecoveryCatalog.referenceLimit,
      gates.count <= records.count,
      records.map(\.id.uuidString) == records.map(\.id.uuidString).sorted(),
      Set(records.map(\.id)).count == records.count,
      gates.map(\.record.projectID) == gates.map(\.record.projectID).sorted(),
      Set(gates.map(\.record.projectID)).count == gates.count
    else { throw invalidRecoveryMetadata() }
    for record in records {
      try record.validate(repository: repository, generation: handle.generation)
      guard record.state == .retained, record.revision < Int64.max - 1
      else { throw invalidRecoveryMetadata() }
    }
    let owners = Set(records.map(\.owner))
    for gate in gates {
      try gate.record.validate()
      guard gate.record.state == .active, let registration = gate.record.worktree,
        registration.repository == repository,
        case .host(let worktreeID, let generation) = gate.record.provenance,
        owners.contains(
          .init(
            source: gate.record.source, branchID: registration.branchID,
            branch: registration.branch,
            worktreeID: worktreeID, storageGeneration: generation)),
        gate.existing.map({ $0.projectID == gate.record.projectID && $0.generation == generation })
          ?? true
      else { throw invalidRecoveryMetadata() }
    }
    _ = try receipts(for: handle)
  }
}
