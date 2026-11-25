import Foundation

typealias WorktreeAcknowledgementSealCheck =
  (UUID, WorktreeRecoveryRecord.Acknowledgement) throws -> Bool

/// The acknowledgement journal retains the exact request and revisions after a
/// newer publication replaces the project's current publication journal.
struct WorktreeRecoveryAcknowledgement: Codable, Equatable {
  enum Phase: String, Codable { case prepared, eligible, sealed, finished }

  struct Transition: Codable, Equatable {
    let before: WorktreeRecoveryRecord.Selection
    let replacements: [UUID]
    let historicalPrivate: [UUID]
    let pinned: WorktreeRecoveryRecord
    let eligible: WorktreeRecoveryRecord
  }

  let operationID: UUID
  let publicationID: UUID
  let generation: UUID
  let owner: WorktreeRecoveryRecord.Owner
  let replacedOID: String
  let expectedPublishedOID: String
  let transitions: [Transition]
  let releaseOperationID: UUID
  private(set) var phase: Phase = .prepared
  private(set) var releases: [WorktreeRecoveryReleaseReceipt]?

  /// The caller verifies every supplied lineage operation against its durable
  /// finished publication outcome for this exact owner and original OID.
  init(
    operationID: UUID, publicationID: UUID, owner: WorktreeRecoveryRecord.Owner,
    replacedOID: String, expectedPublishedOID: String, lineage: Set<UUID>,
    catalog: WorktreeRecoveryCatalog
  ) throws {
    guard replacedOID != expectedPublishedOID, !lineage.isEmpty else {
      throw invalidRecoveryMetadata()
    }
    self.operationID = operationID
    self.publicationID = publicationID
    generation = catalog.generation
    self.owner = owner
    self.replacedOID = replacedOID
    self.expectedPublishedOID = expectedPublishedOID
    releaseOperationID = UUID()
    var foundReplacement = false
    transitions = try catalog.records.filter {
      $0.owner == owner && $0.state == .retained && $0.oid == replacedOID
    }.sorted { $0.id.uuidString < $1.id.uuidString }.compactMap { record in
      let replacements = record.claims.filter {
        $0.reason == .publishedReplacement && lineage.contains($0.operationID)
      }.map(\.id)
      foundReplacement = foundReplacement || !replacements.isEmpty
      let historical = record.claims.filter {
        $0.capture?.storageGeneration == owner.storageGeneration
      }.map(\.id)
      guard !replacements.isEmpty || !historical.isEmpty else { return nil }
      guard record.objectType == .commit, record.revision < Int64.max - 3,
        !record.dependencies.contains(operationID)
      else { throw invalidRecoveryMetadata() }
      var pinned = record
      pinned.revision += 1
      pinned.dependencies.append(operationID)
      var eligible = pinned
      eligible.revision += 1
      let removed = Set(replacements)
      eligible.claims.removeAll { removed.contains($0.id) }
      eligible.acknowledgements.append(
        .init(
          operationID: operationID, selectedRevision: record.revision,
          claimIDs: replacements + historical))
      return .init(
        before: record.selection, replacements: replacements, historicalPrivate: historical,
        pinned: pinned, eligible: eligible)
    }
    guard foundReplacement, transitions.count <= WorktreeRecoveryCatalog.referenceLimit else {
      throw WorktreeError.recoveryRequired(
        "No attributable published replacement for this generation.")
    }
  }

  /// The caller holds R/S/G while eligibility is unsealed. Its live check
  /// verifies publication lineage, branch value, exact registration and authority.
  mutating func complete(
    store: WorktreeRecoveryStore.Locked, verifyLive: () throws -> Void,
    verifySealed: () throws -> Void, persist: (Self) throws -> Void
  ) throws {
    guard store.generation == generation, !transitions.isEmpty,
      transitions.contains(where: { !$0.replacements.isEmpty })
    else { throw invalidRecoveryMetadata() }
    let operationID = operationID
    let digest = try requestDigest()
    try persist(self)
    if phase == .prepared || phase == .eligible {
      try verifyLive()
      let catalog = try store.catalog()
      let pinned = transitions.map(\.pinned)
      let eligible = transitions.map(\.eligible)
      if let intent = catalog.intents.first(where: { $0.id == operationID }) {
        guard intent.kind == .acknowledgement, intent.requestDigest == digest,
          intent.selections == pinned.map(\.selection)
        else { throw invalidRecoveryMetadata() }
        let current = Dictionary(uniqueKeysWithValues: catalog.records.map { ($0.id, $0) })
        for change in transitions {
          guard
            current[change.pinned.id] == change.pinned
              || current[change.pinned.id] == change.eligible
          else { throw invalidRecoveryMetadata() }
        }
      } else {
        guard phase == .prepared else { throw invalidRecoveryMetadata() }
        let current = Dictionary(uniqueKeysWithValues: catalog.records.map { ($0.id, $0) })
        for change in transitions {
          guard let before = current[change.before.recordID], before.selection == change.before
          else { throw invalidRecoveryMetadata() }
          try validate(change, before: before)
        }
        try store.admit(
          operationID: operationID, kind: .acknowledgement, requestDigest: digest,
          records: pinned, completionSteps: [eligible, eligible.map(removingPin)])
      }
      try verifyLive()
      try store.advance(operationID: operationID, records: eligible)
      if phase == .prepared { try save(persist) { $0.phase = .eligible } }
      try verifyLive()
      try save(persist) { $0.phase = .sealed }
    }
    if phase == .finished { return }
    guard phase == .sealed else { throw invalidRecoveryMetadata() }
    try verifySealed()
    if releases == nil {
      let current = try store.catalog()
      let byID = Dictionary(uniqueKeysWithValues: current.records.map { ($0.id, $0) })
      var records = try transitions.map { change in
        guard let record = byID[change.before.recordID], record.owner == owner,
          record.oid == replacedOID, record.state == .retained,
          record.revision >= change.eligible.revision,
          Set(record.claims.map(\.id)).isDisjoint(with: change.replacements),
          record.acknowledgements.contains(where: {
            $0.operationID == operationID
              && $0.claimIDs == change.replacements + change.historicalPrivate
              && $0.selectedRevision == change.before.revision
          })
        else { throw invalidRecoveryMetadata() }
        return record
      }
      if let intent = current.intents.first(where: { $0.id == operationID }) {
        guard intent.kind == .acknowledgement, intent.requestDigest == digest,
          intent.selections == transitions.map(\.pinned.selection),
          records.allSatisfy({
            $0.dependencies.contains(operationID) && $0.revision < Int64.max - 1
          })
        else { throw invalidRecoveryMetadata() }
        records = records.map(removingPin)
        try withoutActuallyEscaping(verifySealed) { verify in
          try store.advance(
            operationID: operationID, records: records, verifyTerminalOutcome: verify)
        }
      } else if records.contains(where: { $0.dependencies.contains(operationID) }) {
        throw invalidRecoveryMetadata()
      }
      let unowned = records.filter { $0.claims.isEmpty && $0.dependencies.isEmpty }
      let selection = try WorktreeRecoveryReleaseReceipt.digest(of: unowned.map(\.selection))
      let receipts = unowned.map {
        WorktreeRecoveryReleaseReceipt(
          storeGeneration: generation, owner: owner, selection: $0.selection,
          operationID: releaseOperationID, requestDigest: digest, selectionDigest: selection)
      }
      try save(persist) { $0.releases = receipts }
    }
    if let releases, !releases.isEmpty {
      let ids = Set(transitions.map(\.before.recordID))
      guard
        releases.allSatisfy({
          $0.storeGeneration == generation && $0.owner == owner
            && $0.operationID == releaseOperationID && $0.requestDigest == digest
            && $0.selection.oid == replacedOID && ids.contains($0.selection.recordID)
        })
      else { throw invalidRecoveryMetadata() }
      try store.releaseAnchors(releases, verifyAuthority: verifySealed)
    }
    try save(persist) { $0.phase = .finished }
  }

  private func validate(_ change: Transition, before: WorktreeRecoveryRecord) throws {
    let replacements = Set(change.replacements)
    let historical = Set(change.historicalPrivate)
    guard before.owner == owner, before.oid == replacedOID, before.state == .retained,
      before.revision < Int64.max - 3,
      replacements.count == change.replacements.count,
      historical.count == change.historicalPrivate.count,
      replacements.isSubset(
        of: before.claims.filter { $0.reason == .publishedReplacement }.map(\.id)),
      historical
        == Set(
          before.claims.filter {
            $0.capture?.storageGeneration == owner.storageGeneration
          }.map(\.id))
    else { throw invalidRecoveryMetadata() }
    var pinned = before
    pinned.revision += 1
    pinned.dependencies.append(operationID)
    var eligible = pinned
    eligible.revision += 1
    eligible.claims.removeAll { replacements.contains($0.id) }
    eligible.acknowledgements.append(
      .init(
        operationID: operationID, selectedRevision: before.revision,
        claimIDs: change.replacements + change.historicalPrivate))
    guard pinned == change.pinned, eligible == change.eligible else {
      throw invalidRecoveryMetadata()
    }
  }

  private func removingPin(_ record: WorktreeRecoveryRecord) -> WorktreeRecoveryRecord {
    var next = record
    next.revision += 1
    next.dependencies.removeAll { $0 == operationID }
    return next
  }

  private func requestDigest() throws -> String {
    var request = self
    request.phase = .prepared
    request.releases = nil
    let bytes = try recoveryJSON(request)
    guard bytes.count <= WorktreeRecoveryCatalog.byteLimit else {
      throw WorktreeError.busy("Recovery acknowledgement selection exceeds its journal bound.")
    }
    return WorktreeObjectSnapshot.digest(bytes)
  }

  func authorizes(
    recordID: UUID, eligibility: WorktreeRecoveryRecord.Acknowledgement
  ) -> Bool {
    guard [.sealed, .finished].contains(phase), eligibility.operationID == operationID,
      let change = transitions.first(where: { $0.before.recordID == recordID })
    else { return false }
    return eligibility.selectedRevision == change.before.revision
      && eligibility.claimIDs == change.replacements + change.historicalPrivate
  }

  private mutating func save(_ persist: (Self) throws -> Void, change: (inout Self) -> Void) throws
  {
    var next = self
    change(&next)
    try persist(next)
    self = next
  }
}
