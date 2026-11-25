import Foundation

/// Prepared before removal destroys metadata. The frozen private claim IDs
/// remain protected until the exact teardown receipt becomes terminal.
struct WorktreeRecoveryReconciliation: Codable, Equatable {
  struct Selection: Codable, Equatable {
    let before: WorktreeRecoveryRecord.Selection
    let pinned: WorktreeRecoveryRecord
    let claimIDs: [UUID]
  }

  struct Discharge: Codable, Equatable {
    let before: WorktreeRecoveryRecord.Selection
    let after: WorktreeRecoveryRecord
  }

  let operationID: UUID
  let removalID: UUID
  let generation: UUID
  let owner: WorktreeRecoveryRecord.Owner
  let finalCapture: WorktreeRecoveryRecord.Claim.Capture
  let selection: [Selection]
  let releaseOperationID: UUID
  private(set) var discharge: [Discharge]?
  private(set) var releases: [WorktreeRecoveryReleaseReceipt]?
  private(set) var finished = false

  init(
    operationID: UUID, final: WorktreeRecoveryRetention, catalog: WorktreeRecoveryCatalog,
    sealed: WorktreeAcknowledgementSealCheck
  ) throws {
    guard final.kind == .removal, final.generation == catalog.generation,
      operationID != final.operationID
    else { throw invalidRecoveryMetadata() }
    self.operationID = operationID
    removalID = final.operationID
    generation = catalog.generation
    owner = final.owner
    finalCapture = final.capture
    releaseOperationID = UUID()
    let roots = Set(final.roots)
    selection = try catalog.records.filter {
      $0.owner == final.owner && $0.state == .retained && !roots.contains($0.oid)
    }.sorted { $0.id.uuidString < $1.id.uuidString }.compactMap { record in
      let eligible = try Self.eligibleClaims(record, finalCapture: final.capture, sealed: sealed)
      guard !eligible.isEmpty else { return nil }
      guard record.revision < Int64.max - 4, !record.dependencies.contains(operationID)
      else { throw invalidRecoveryMetadata() }
      var pinned = record
      pinned.revision += 1
      pinned.dependencies.append(operationID)
      return Selection(
        before: record.selection, pinned: pinned,
        claimIDs: eligible.sorted { $0.uuidString < $1.uuidString })
    }
  }

  func prepare(
    in store: WorktreeRecoveryStore.Locked, verifyFinalRetention: () throws -> Void,
    sealed: WorktreeAcknowledgementSealCheck, persist: (Self) throws -> Void
  ) throws {
    guard store.generation == generation, !finished
    else { throw invalidRecoveryMetadata() }
    try verifyFinalRetention()
    try persist(self)
    guard !selection.isEmpty else { return }
    let digest = try requestDigest()
    let catalog = try store.catalog()
    let current = Dictionary(uniqueKeysWithValues: catalog.records.map { ($0.id, $0) })
    if let intent = catalog.intents.first(where: { $0.id == operationID }) {
      try requireIntent(intent, digest: digest)
      guard selection.allSatisfy({ current[$0.before.recordID] == $0.pinned })
      else { throw invalidRecoveryMetadata() }
      return
    }
    guard discharge == nil, releases == nil else { throw invalidRecoveryMetadata() }
    let completed = try selection.map { choice in
      guard let previous = current[choice.before.recordID], previous.selection == choice.before,
        previous.owner == owner, previous.state == .retained,
        choice.pinned.follows(previous),
        Set(choice.pinned.dependencies) == Set(previous.dependencies).union([operationID]),
        choice.pinned.claims == previous.claims,
        choice.pinned.acknowledgements == previous.acknowledgements,
        Set(choice.claimIDs).isSubset(
          of: try Self.eligibleClaims(
            previous, finalCapture: finalCapture, sealed: sealed))
      else { throw invalidRecoveryMetadata() }
      return removingPin(choice.pinned, claims: Set(choice.claimIDs))
    }
    try store.admit(
      operationID: operationID, kind: .reconciliation, requestDigest: digest,
      records: selection.map(\.pinned), completionSteps: [completed],
      releaseCandidates: Set(completed.filter { $0.claims.isEmpty }.map(\.id)))
  }

  /// Project the actual terminal payload while the final and reconciliation
  /// pins are both live. The removal journal can reserve its full after-image
  /// before unlinking any private content.
  func planning(
    in catalog: WorktreeRecoveryCatalog, afterRetiring final: [WorktreeRecoveryRecord] = [],
    sealed: WorktreeAcknowledgementSealCheck
  ) throws -> Self {
    guard catalog.generation == generation, !finished else { throw invalidRecoveryMetadata() }
    if selection.isEmpty { return self }
    let digest = try requestDigest()
    guard let intent = catalog.intents.first(where: { $0.id == operationID })
    else { throw invalidRecoveryMetadata() }
    try requireIntent(intent, digest: digest)
    var current = Dictionary(uniqueKeysWithValues: catalog.records.map { ($0.id, $0) })
    for record in final { current[record.id] = record }
    let updates: [Discharge] = try selection.map { choice in
      guard let record = current[choice.before.recordID], record.owner == owner,
        record.oid == choice.before.oid, record.state == .retained,
        record.revision >= choice.pinned.revision, record.revision < Int64.max - 1,
        record.dependencies.contains(operationID), !record.dependencies.contains(removalID)
      else { throw invalidRecoveryMetadata() }
      let remaining = Set(record.claims.map(\.id)).intersection(choice.claimIDs)
      guard
        remaining.isSubset(
          of: try Self.eligibleClaims(record, finalCapture: finalCapture, sealed: sealed))
      else { throw invalidRecoveryMetadata() }
      return .init(before: record.selection, after: removingPin(record, claims: remaining))
    }
    var next = self
    next.discharge = updates
    next.releases = try releaseBatch(for: updates)
    return next
  }

  /// Resumes only the frozen claim discharge and its exact resulting release.
  /// The final-capture pin must have ended from the recorded teardown before
  /// this call. A newer revision can be compared without selecting new claims.
  mutating func complete(
    in store: WorktreeRecoveryStore.Locked, verifyTeardown: () throws -> Void,
    sealed: WorktreeAcknowledgementSealCheck, persist: (Self) throws -> Void
  ) throws {
    guard store.generation == generation else { throw invalidRecoveryMetadata() }
    try verifyTeardown()
    try persist(self)
    if finished { return }
    if !selection.isEmpty {
      let catalog = try store.catalog()
      let current = Dictionary(uniqueKeysWithValues: catalog.records.map { ($0.id, $0) })
      if catalog.intents.contains(where: { $0.id == operationID }) {
        let next = try planning(in: catalog, sealed: sealed)
        guard let updates = next.discharge, let receipts = next.releases
        else { throw invalidRecoveryMetadata() }
        try persist(next)
        self = next
        try withoutActuallyEscaping(verifyTeardown) { verify in
          try store.advance(
            operationID: operationID, records: updates.map(\.after), verifyTerminalOutcome: verify,
            releasing: receipts)
        }
      } else {
        let releasing = Set((releases ?? []).map(\.selection.recordID))
        guard let recorded = discharge, recorded.count == selection.count,
          zip(recorded, selection).allSatisfy({ update, choice in
            update.before.recordID == choice.before.recordID
              && (releasing.contains(choice.before.recordID)
                || current[choice.before.recordID] == update.after)
          })
        else { throw invalidRecoveryMetadata() }
        if releases == nil {
          let receipts = try releaseBatch(for: recorded)
          try save(persist) { $0.releases = receipts }
        }
      }
    }
    if let releases, !releases.isEmpty {
      var allowed: [UUID: WorktreeRecoveryRecord.Selection] = [:]
      for update in discharge ?? []
      where update.after.claims.isEmpty && update.after.dependencies.isEmpty {
        let record = update.after
        guard allowed.updateValue(record.selection, forKey: record.id) == nil
        else { throw invalidRecoveryMetadata() }
      }
      let digest = try requestDigest()
      guard
        releases.allSatisfy({
          $0.storeGeneration == generation && $0.owner == owner
            && $0.operationID == releaseOperationID && $0.requestDigest == digest
            && allowed[$0.selection.recordID] == $0.selection
        })
      else { throw invalidRecoveryMetadata() }
      try store.releaseAnchors(releases, verifyAuthority: verifyTeardown)
    }
    try save(persist) { $0.finished = true }
  }

  private func releaseBatch(for updates: [Discharge]) throws -> [WorktreeRecoveryReleaseReceipt] {
    let releasable = updates.map(\.after).filter { $0.claims.isEmpty && $0.dependencies.isEmpty }
    return try WorktreeRecoveryReleaseReceipt.batch(
      for: releasable, operationID: releaseOperationID, requestDigest: requestDigest())
  }

  /// Abandoning teardown retires its preparation pin without discharging
  /// historical claims. The owning removal journal records abandonment.
  func discardPreparation(
    in store: WorktreeRecoveryStore.Locked, verifyAbandoned: () throws -> Void
  ) throws {
    guard store.generation == generation, !finished
    else { throw invalidRecoveryMetadata() }
    try verifyAbandoned()
    let catalog = try store.catalog()
    guard let intent = catalog.intents.first(where: { $0.id == operationID }) else { return }
    try requireIntent(intent, digest: requestDigest())
    let records = Dictionary(uniqueKeysWithValues: catalog.records.map { ($0.id, $0) })
    let updates = try selection.map { choice in
      guard let current = records[choice.before.recordID], current.owner == owner,
        current.oid == choice.before.oid, current.state == .retained,
        current.dependencies.contains(operationID), current.revision < Int64.max - 1
      else { throw invalidRecoveryMetadata() }
      var retained = current
      retained.revision += 1
      retained.dependencies.removeAll { $0 == operationID }
      return retained
    }
    try withoutActuallyEscaping(verifyAbandoned) { verify in
      try store.advance(operationID: operationID, records: updates, verifyTerminalOutcome: verify)
    }
  }

  private func requireIntent(_ intent: WorktreeRecoveryIntent, digest: String) throws {
    guard intent.kind == .reconciliation, intent.requestDigest == digest,
      intent.selections == selection.map(\.pinned.selection)
    else { throw invalidRecoveryMetadata() }
  }

  private func removingPin(_ record: WorktreeRecoveryRecord, claims: Set<UUID>)
    -> WorktreeRecoveryRecord
  {
    var next = record
    next.revision += 1
    next.dependencies.removeAll { $0 == operationID }
    next.claims.removeAll { claims.contains($0.id) }
    let live = Set(next.claims.map(\.id))
    next.acknowledgements.removeAll {
      !claims.isDisjoint(with: $0.claimIDs) && live.isDisjoint(with: $0.claimIDs)
    }
    return next
  }

  private static func eligibleClaims(
    _ record: WorktreeRecoveryRecord, finalCapture: WorktreeRecoveryRecord.Claim.Capture,
    sealed: WorktreeAcknowledgementSealCheck
  ) throws -> Set<UUID> {
    var eligible: Set<UUID> = []
    for acknowledgement in record.acknowledgements {
      if try sealed(record.id, acknowledgement) { eligible.formUnion(acknowledgement.claimIDs) }
    }
    return Set(
      record.claims.compactMap { claim in
        guard let capture = claim.capture, capture.id != finalCapture.id,
          capture.storageGeneration == finalCapture.storageGeneration, eligible.contains(claim.id)
        else { return nil }
        return claim.id
      })
  }

  private func requestDigest() throws -> String {
    var request = self
    request.discharge = nil
    request.releases = nil
    request.finished = false
    let bytes = try recoveryJSON(request)
    guard bytes.count <= WorktreeRecoveryCatalog.byteLimit else {
      throw WorktreeError.busy("Recovery reconciliation selection exceeds its journal bound.")
    }
    return WorktreeObjectSnapshot.digest(bytes)
  }

  private mutating func save(_ persist: (Self) throws -> Void, change: (inout Self) -> Void) throws
  {
    var next = self
    change(&next)
    try persist(next)
    self = next
  }
}
