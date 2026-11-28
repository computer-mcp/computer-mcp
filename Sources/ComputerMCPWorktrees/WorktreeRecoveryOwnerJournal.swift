import ComputerMCPPlatformPOSIX
import Foundation

struct RecoveryOwnerJournal: Codable, Equatable {
  static let activeName = "owner-operation.json"
  static let byteLimit = WorktreeRecoveryCatalog.byteLimit

  struct Gate: Codable, Equatable {
    let admission: WorktreeAdmission
    var cleanup: RecoveryOperationStatus.GateCleanup = .pending
  }

  struct FallbackScratch: Codable, Equatable {
    static let lockName = "release-proof.lock"

    let token: UUID
    let runtime: WorktreeDirectoryIdentity
    let directory: WorktreeDirectoryIdentity
    let lock: FileLock.Identity

    static func name(operation: UUID, token: UUID) -> String {
      "release-proof-" + operation.uuidString.lowercased() + "-" + token.uuidString.lowercased()
    }
  }

  var schema = 1
  var revision: Int64 = 1
  let request: RecoveryReviewedRequest
  let principal: String
  var gates: [Gate] = []
  var outcome: RecoveryOperationStatus.Outcome = .pending
  var maintenance: WorktreeRecoveryWithdrawal?
  var fallbackScratch: FallbackScratch?

  var handle: RecoveryOperationHandle { request.handle }
  var resultName: String { Self.resultName(handle.id) }
  var hold: WorktreeAdmission.RecoveryHold {
    .init(operationID: handle.id, requestDigest: handle.requestDigest)
  }

  var status: RecoveryOperationStatus {
    .init(
      request: request, revision: revision, outcome: outcome,
      gates: gates.map {
        .init(
          projectID: $0.admission.projectID, storageGeneration: $0.admission.generation,
          cleanup: $0.cleanup)
      })
  }

  var isResult: Bool {
    switch outcome {
    case .pending, .recoveryRequired: false
    default: true
    }
  }

  static func resultName(_ id: UUID) -> String { "owner-" + id.uuidString.lowercased() + ".json" }

  func advanced(_ update: (inout Self) -> Void) throws -> Self {
    guard revision < Int64.max else { throw invalidRecoveryMetadata() }
    var next = self
    next.revision += 1
    update(&next)
    return next
  }
}

extension WorktreeRecoveryStore.Locked {
  struct OwnerEntry {
    let record: RecoveryOwnerJournal
    let bytes: Data
  }

  func requireMaintenanceIdle() throws {
    if let active = try ownerEntry(RecoveryOwnerJournal.activeName),
      active.record.handle.action == .maintenance
    {
      throw WorktreeError.busy("Recovery maintenance has exclusive use of this store.")
    }
  }

  func ownerEntry(_ name: String, account: (Int) throws -> Void = { _ in }) throws -> OwnerEntry? {
    try checkIdentity()
    guard let bytes = try journalIO.read(name, in: directory, limit: RecoveryOwnerJournal.byteLimit)
    else { return nil }
    try account(bytes.count)
    let record = try JSONDecoder().decode(RecoveryOwnerJournal.self, from: bytes)
    guard record.schema == 1, record.revision > 0, record.handle.generation == generation,
      record.handle.storeKey == (try WorktreeRecoveryStore.key(for: repository)),
      !record.principal.isEmpty, record.principal.utf8.count <= 1024,
      name == RecoveryOwnerJournal.activeName || (name == record.resultName && record.isResult),
      (try recoveryJSON(record)) == bytes
    else { throw invalidRecoveryMetadata() }
    try record.request.validate(principal: record.principal, repository: repository)
    switch record.request {
    case .release(let review):
      let reviewed = review.release.gates.map(\.record.projectID)
      let recorded = record.gates.map(\.admission.projectID)
      guard record.maintenance == nil, recorded.isEmpty || recorded == reviewed,
        recorded.isEmpty || record.revision > 1
      else { throw invalidRecoveryMetadata() }
      switch record.outcome {
      case .measured, .deferred: throw invalidRecoveryMetadata()
      default: break
      }
      for (intended, actual) in zip(review.release.gates, record.gates) {
        guard case .host(_, let generation) = intended.record.provenance,
          actual.admission.generation == generation,
          intended.existing.map({ $0 == actual.admission }) ?? true
        else { throw invalidRecoveryMetadata() }
      }
      if let scratch = record.fallbackScratch {
        let name = RecoveryOwnerJournal.FallbackScratch.name(
          operation: record.handle.id, token: scratch.token)
        let path = URL(fileURLWithPath: scratch.runtime.path).appendingPathComponent(name).path
        guard !record.isResult, !record.gates.isEmpty,
          let gate = review.release.gates.first(where: {
            $0.record.worktree?.runtime == scratch.runtime
          }),
          let expected = gate.record.worktree?.lastPublishedOID,
          review.records.contains(where: {
            $0.owner.projectID == gate.record.projectID && $0.oid == expected
              && $0.objectType == .commit
          }), scratch.directory.path.utf8.elementsEqual(path.utf8)
        else { throw invalidRecoveryMetadata() }
      }
    case .maintenance(let review):
      guard record.gates.isEmpty, record.fallbackScratch == nil else {
        throw invalidRecoveryMetadata()
      }
      try record.maintenance?.validate(review: review)
      switch record.outcome {
      case .pending:
        guard record.maintenance != nil else { throw invalidRecoveryMetadata() }
      case .measured(let allocation):
        let expected: RecoveryPackAllocation
        if let pair = review.proof.candidate {
          guard record.maintenance?.phase == .disposing else { throw invalidRecoveryMetadata() }
          let removed = try checkedAllocation(pair.pack.allocatedBytes, pair.index.allocatedBytes)
          expected = try .init(
            baseline: review.baselineBytes, final: review.baselineBytes - removed)
        } else {
          expected = try .init(baseline: review.baselineBytes, final: review.baselineBytes)
        }
        guard expected == allocation else { throw invalidRecoveryMetadata() }
      case .stale:
        guard record.maintenance == nil else { throw invalidRecoveryMetadata() }
      case .deferred:
        guard record.maintenance == nil || record.maintenance?.phase == .restoringDeferred
        else { throw invalidRecoveryMetadata() }
      case .recoveryRequired: break
      case .busy, .released: throw invalidRecoveryMetadata()
      }
    }
    return OwnerEntry(record: record, bytes: bytes)
  }

  func observeOwnerOperation(
    _ handle: RecoveryOperationHandle, principal: String, request: RecoveryReviewedRequest? = nil,
    synchronizing: Bool
  ) throws -> (result: OwnerEntry?, active: OwnerEntry?) {
    let activeName = RecoveryOwnerJournal.activeName
    let resultName = RecoveryOwnerJournal.resultName(handle.id)
    let result = try ownerEntry(resultName)
    let active = try ownerEntry(activeName)
    let matching = active.flatMap { $0.record.handle.id == handle.id ? $0 : nil }
    for entry in [result, matching].compactMap({ $0 }) {
      guard entry.record.handle == handle, entry.record.principal == principal,
        request.map({ $0 == entry.record.request }) ?? true
      else { throw WorktreeRecoveryOwnerError.identityConflict }
    }
    if let result {
      if let matching, matching.bytes != result.bytes { throw invalidRecoveryMetadata() }
      if synchronizing {
        try journalIO.synchronize(resultName, in: directory, expecting: result.bytes)
        if let matching {
          try journalIO.remove(activeName, in: directory, expecting: matching.bytes)
        }
      }
      return (result, synchronizing && matching != nil ? nil : active)
    }
    if synchronizing, let matching {
      try journalIO.synchronize(activeName, in: directory, expecting: matching.bytes)
    }
    return (nil, active)
  }

  @discardableResult
  func saveOwnerOperation(_ record: RecoveryOwnerJournal, replacing entry: OwnerEntry?) throws
    -> OwnerEntry
  {
    let bytes = try recoveryJSON(record)
    guard bytes.count <= RecoveryOwnerJournal.byteLimit else {
      throw WorktreeError.busy("Recovery operation exceeds its journal byte limit.")
    }
    try journalIO.write(
      bytes, name: RecoveryOwnerJournal.activeName, in: directory, replacing: entry?.bytes)
    return .init(record: record, bytes: bytes)
  }

  func publishOwnerResult(_ entry: OwnerEntry) throws {
    guard entry.record.isResult else { throw invalidRecoveryMetadata() }
    try journalIO.write(entry.bytes, name: entry.record.resultName, in: directory, replacing: nil)
    try journalIO.remove(RecoveryOwnerJournal.activeName, in: directory, expecting: entry.bytes)
  }

  func updateOwnerCleanup(_ next: RecoveryOwnerJournal, replacing entry: OwnerEntry) throws {
    let bytes = try recoveryJSON(next)
    guard bytes.count <= RecoveryOwnerJournal.byteLimit else { throw invalidRecoveryMetadata() }
    try journalIO.write(bytes, name: next.resultName, in: directory, replacing: entry.bytes)
  }
}
