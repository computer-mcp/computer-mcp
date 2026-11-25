import Foundation

/// Persisted in the deletion journal before acquiring source guards. The
/// branch-to-lock receipt later authorizes only this exact catalog release.
struct WorktreeRecoveryBranchSelection: Codable, Equatable {
  let operationID: UUID
  let repository: WorktreeRepositoryIdentity
  let source: DerivedProjectSource
  let generation: UUID
  let protection: ProtectedWorktreeBranch
  let owner: WorktreeRecoveryRecord.Owner?
  let baseOID: String?
  let force: Bool
  let before: [WorktreeRecoveryRecord.Selection]
  let pinned: [WorktreeRecoveryRecord]
  let releaseOperationID: UUID
  let retained: [WorktreeRecoveryRecord.Selection]
  let released: [WorktreeRecoveryReleaseReceipt]

  init(
    operationID: UUID, repository: WorktreeRepositoryIdentity, source: DerivedProjectSource,
    protection: ProtectedWorktreeBranch, baseOID: String?, force: Bool,
    authority: WorktreeBranchAuthority, catalog: WorktreeRecoveryCatalog,
    originalBaseObjects: Set<String>
  ) throws {
    guard protection.repository == repository.common, source.root == repository.source.path,
      !force || authority == .fullAccess, force || baseOID != nil
    else { throw invalidRecoveryMetadata() }
    self.operationID = operationID
    self.repository = repository
    self.source = source
    generation = catalog.generation
    self.protection = protection
    self.baseOID = baseOID
    self.force = force
    let releaseID = UUID()
    releaseOperationID = releaseID
    let matching = catalog.records.filter {
      $0.owner.source == source && $0.owner.branchID == protection.branchID
        && $0.owner.branch == protection.branch && $0.owner.worktreeID == protection.worktreeID
    }.sorted { $0.id.uuidString < $1.id.uuidString }
    let selectedOwner = matching.first?.owner
    owner = selectedOwner
    guard
      matching.allSatisfy({
        $0.owner == selectedOwner && $0.base.ref == protection.base
          && $0.base.oid == protection.baseOID
          && $0.base.history == protection.baseHistory && $0.state == .retained
          && $0.revision < Int64.max - 3 && !$0.dependencies.contains(operationID)
      })
    else { throw invalidRecoveryMetadata() }
    let selected = matching.filter { force || originalBaseObjects.contains($0.oid) }
    guard selected.allSatisfy({ $0.dependencies.isEmpty }) else {
      throw WorktreeError.recoveryRequired(
        "A pending operation still protects selected recovery data.")
    }
    let releasedIDs = Set(selected.map(\.id))
    before = matching.map(\.selection)
    let pinned = matching.map { record in
      var next = record
      next.revision += 1
      next.dependencies.append(operationID)
      return next
    }
    self.pinned = pinned
    let terminal = pinned.map { Self.removingPin($0, operationID: operationID) }
    retained = terminal.filter { !releasedIDs.contains($0.id) }.map(\.selection)
    let request = Request(
      repository: repository, source: source, generation: catalog.generation,
      protection: protection, baseOID: baseOID, force: force)
    let digest = try request.digest()
    let releaseRecords = terminal.filter { releasedIDs.contains($0.id) }
    let selections = try WorktreeRecoveryReleaseReceipt.digest(of: releaseRecords.map(\.selection))
    released = releaseRecords.map {
      .init(
        storeGeneration: catalog.generation, owner: $0.owner, selection: $0.selection,
        operationID: releaseID, requestDigest: digest, selectionDigest: selections)
    }
    var bytes = 0
    for receipt in released {
      bytes = try recoverySum(bytes, receipt.encoded().count)
      guard bytes <= WorktreeRecoveryReleaseReceipt.operationByteLimit else {
        throw WorktreeError.busy("Branch recovery selection exceeds the release receipt bound.")
      }
    }
  }

  /// The lifecycle journal already contains this selection. Pin its revisions
  /// before normalization can change either source representation.
  func prepare(in store: WorktreeRecoveryStore.Locked) throws {
    guard store.generation == generation else { throw invalidRecoveryMetadata() }
    guard !pinned.isEmpty else { return }
    let catalog = try store.catalog()
    let digest = try requestDigest()
    if let intent = catalog.intents.first(where: { $0.id == operationID }) {
      try requireIntent(intent, digest: digest)
      return
    }
    let current = Dictionary(uniqueKeysWithValues: catalog.records.map { ($0.id, $0) })
    guard before.count == pinned.count else { throw invalidRecoveryMetadata() }
    for (selection, record) in zip(before, pinned) {
      guard let original = current[selection.recordID], original.selection == selection,
        record.owner == owner, record.follows(original), record.claims == original.claims,
        record.acknowledgements == original.acknowledgements
      else { throw invalidRecoveryMetadata() }
    }
    try store.admit(
      operationID: operationID, kind: .branchDeletion, requestDigest: digest,
      records: pinned,
      completionSteps: [pinned.map { Self.removingPin($0, operationID: operationID) }],
      releaseCandidates: Set(released.map(\.selection.recordID)))
  }

  /// Called before normalization and again while arming deletion. This
  /// readback cannot be substituted by an OID search after the source is gone.
  func verifyBeforeDeletion(
    in store: WorktreeRecoveryStore.Locked, git: WorktreeGit, budget: WorktreeObjectBudget
  ) throws {
    guard store.generation == generation else { throw invalidRecoveryMetadata() }
    if let owner {
      let catalog = try store.catalog()
      guard let intent = catalog.intents.first(where: { $0.id == operationID })
      else { throw invalidRecoveryMetadata() }
      try requireIntent(intent, digest: requestDigest())
      try store.verifyRetainedRecords(
        pinned.map(\.selection), owner: owner, git: git, budget: budget)
    } else if !retained.isEmpty || !released.isEmpty {
      throw invalidRecoveryMetadata()
    }
  }

  func releaseAfterDeletion(
    in store: WorktreeRecoveryStore.Locked, verifySourceDeleted: () throws -> Void
  ) throws {
    guard store.generation == generation,
      released.allSatisfy({
        $0.operationID == releaseOperationID && $0.owner == owner
          && $0.storeGeneration == generation
      })
    else { throw invalidRecoveryMetadata() }
    try verifySourceDeleted()
    let catalog = try store.catalog()
    let byID = Dictionary(uniqueKeysWithValues: catalog.records.map { ($0.id, $0) })
    if let intent = catalog.intents.first(where: { $0.id == operationID }) {
      try requireIntent(intent, digest: requestDigest())
      guard pinned.allSatisfy({ byID[$0.id] == $0 }) else { throw invalidRecoveryMetadata() }
      let terminal = pinned.map { Self.removingPin($0, operationID: operationID) }
      try withoutActuallyEscaping(verifySourceDeleted) { verify in
        try store.advance(
          operationID: operationID, records: terminal, verifyTerminalOutcome: verify,
          releasing: released)
      }
    } else {
      guard retained.allSatisfy({ byID[$0.recordID]?.selection == $0 })
      else { throw invalidRecoveryMetadata() }
    }
    if !released.isEmpty {
      try store.releaseAnchors(released, verifyAuthority: verifySourceDeleted)
    }
  }

  func retiredReleaseReceipts() throws -> [WorktreeRecoveryReleaseReceipt] {
    guard let owner, owner.source == source, owner.matches(protection),
      releaseOperationID != operationID, before.count == pinned.count
    else { throw invalidRecoveryMetadata() }
    let retired = Set(released.map(\.selection.recordID))
    guard retired.count == released.count, !retired.isEmpty else {
      throw invalidRecoveryMetadata()
    }
    let records = try zip(before, pinned).compactMap { prior, record -> WorktreeRecoveryRecord? in
      guard retired.contains(prior.recordID) else { return nil }
      try record.validate(repository: repository, generation: generation)
      guard record.id == prior.recordID, record.oid == prior.oid,
        prior.revision > 0, prior.revision < Int64.max - 3,
        record.revision == prior.revision + 1, record.owner == owner,
        record.state == .retained, record.dependencies == [operationID]
      else { throw invalidRecoveryMetadata() }
      return Self.removingPin(record, operationID: operationID)
    }
    let request = Request(
      repository: repository, source: source, generation: generation, protection: protection,
      baseOID: baseOID, force: force)
    let expected = try WorktreeRecoveryReleaseReceipt.batch(
      for: records, operationID: releaseOperationID, requestDigest: request.digest())
    guard released == expected else { throw invalidRecoveryMetadata() }
    return expected
  }

  private func requireIntent(_ intent: WorktreeRecoveryIntent, digest: String) throws {
    guard intent.kind == .branchDeletion, intent.requestDigest == digest,
      intent.selections == pinned.map(\.selection)
    else { throw invalidRecoveryMetadata() }
  }

  private func requestDigest() throws -> String {
    let bytes = try recoveryJSON(self)
    guard bytes.count <= WorktreeRecoveryCatalog.byteLimit else {
      throw WorktreeError.busy("Branch recovery selection exceeds its journal bound.")
    }
    return WorktreeObjectSnapshot.digest(bytes)
  }

  private static func removingPin(
    _ record: WorktreeRecoveryRecord, operationID: UUID
  ) -> WorktreeRecoveryRecord {
    var next = record
    next.revision += 1
    next.dependencies.removeAll { $0 == operationID }
    return next
  }

  private struct Request: Encodable {
    let repository: WorktreeRepositoryIdentity
    let source: DerivedProjectSource
    let generation: UUID
    let protection: ProtectedWorktreeBranch
    let baseOID: String?
    let force: Bool

    func digest() throws -> String {
      WorktreeObjectSnapshot.digest(try recoveryJSON(self))
    }
  }
}
