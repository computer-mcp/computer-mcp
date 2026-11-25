import Foundation

/// The publication journal owns this state and embeds the pack handoff beside
/// it. The source compare-and-swap never changes a retention anchor.
struct WorktreeRecoverySourcePublication: Codable, Equatable {
  enum Phase: String, Codable { case sourcePublishing, sourcePublished, ledger, finished }

  let operationID: UUID
  let repository: WorktreeRepositoryIdentity
  let record: DerivedProjectRecord
  let proof: WorktreeSourcePublicationProof
  private(set) var guards: WorktreeSourceGuardJournal?
  private(set) var phase: Phase = .sourcePublishing

  init(
    repository: WorktreeRepositoryIdentity, record: DerivedProjectRecord, target: String,
    protectedBy protection: WorktreeSourceGuards, guardOwnership: WorktreeSourceGuardJournal
  ) throws {
    let metadata = protection.metadata
    guard let registration = record.worktree, metadata.common.identity == repository.common,
      guardOwnership.common == repository.common, !guardOwnership.cleaning,
      protection.operationID == guardOwnership.operationID
    else { throw invalidRecoveryMetadata() }
    try protection.verify(covering: [registration.branch, "packed-refs"])
    operationID = guardOwnership.operationID
    self.repository = repository
    self.record = record
    proof = try .init(
      operationID: operationID, branch: registration.branch,
      expected: registration.lastPublishedOID, target: target,
      message: "computer-mcp publication " + operationID.uuidString.lowercased(), metadata: metadata
    )
    guards = guardOwnership
  }

  /// Before entering, the recovery pack, retained records and pins are
  /// durable. All catalog completion runs under the same R/S/G ownership.
  mutating func complete(
    in owner: WorktreeRepository, lock: RepositoryLock,
    authorize: (DerivedProjectRecord) throws -> Void,
    verifyRetention: () throws -> Void, completeCatalog: () throws -> Void,
    persist: (Self) throws -> Void
  ) throws -> WorktreePublication {
    guard let registration = record.worktree, repository == owner.identity,
      record.source == owner.source, operationID == proof.operationID,
      guards.map({ $0.operationID == operationID }) ?? true,
      record.revision < Int64.max - 1,
      registration.branch == proof.branch, registration.lastPublishedOID == proof.expected,
      proof.message == "computer-mcp publication " + operationID.uuidString.lowercased()
    else { throw invalidRecoveryMetadata() }
    let original = record
    let receipt = proof
    let target = receipt.target
    let branch = receipt.branch
    let metadata = try owner.sourceMetadata()
    let branches = [branch]
    var updated = original
    updated.revision += 1
    updated.worktree!.publishedOID = target
    func validate(allowUpdated: Bool) throws {
      try Task.checkCancellation()
      try lock.verify()
      try owner.identity.verify()
      try authorize(original)
      let current = try owner.store.records().first { $0.projectID == original.projectID }
      guard current == original || (allowUpdated && current == updated)
      else { throw DerivedProjectStoreError.revisionConflict }
    }
    try validate(allowUpdated: phase != .sourcePublishing)
    try persist(self)
    if phase == .finished {
      try finishGuards(metadata: metadata, lock: lock, branches: branches, persist: persist)
      return .init(projectID: original.projectID, operationID: operationID, oid: target)
    }
    if phase != .ledger { try verifyRetention() }
    var protection = try acquire(
      metadata: metadata, lock: lock, branches: branches, persist: persist)
    if phase == .sourcePublishing {
      let state = try receipt.proveAndSynchronize(guards: protection) {
        try validate(allowUpdated: false)
      }
      if state == .retryExpectedUpdate {
        try release(protection, branches: branches, persist: persist)
        // A successful return requires the real commit acknowledgement,
        // joined output, and a successful quiescent exit. An error leaves
        // sourcePublishing for a later, independently guarded lost-ack replay.
        try owner.git.transaction(
          "start\nupdate \(branch) \(target) \(receipt.expected)\nprepare\n",
          at: URL(fileURLWithPath: repository.main.path),
          gitDirectory: URL(fileURLWithPath: repository.common.path), message: receipt.message
        ) {
          try validate(allowUpdated: false)
          guard try metadata.direct(branch).oid == receipt.expected else {
            throw sourceMetadataChanged()
          }
        }
        protection = try acquire(
          metadata: metadata, lock: lock, branches: branches, persist: persist)
      }
    }
    guard
      try receipt.proveAndSynchronize(
        guards: protection, revalidate: { try validate(allowUpdated: phase != .sourcePublishing) })
        == .durable,
      try owner.revision(branch) == target
    else { throw sourceMetadataChanged() }
    if phase == .sourcePublishing { try save(persist) { $0.phase = .sourcePublished } }
    if phase == .sourcePublished {
      try protection.verify()
      try validate(allowUpdated: true)
      if try owner.store.records().first(where: { $0.projectID == original.projectID }) != updated {
        try owner.store.commit(
          updated, expecting: original.revision,
          protecting: .init(
            repository: repository.common, branchID: registration.branchID, branch: branch,
            base: registration.base, baseOID: registration.baseOID, publishedOID: target,
            worktreeID: original.provenance.worktreeID, mergedOID: registration.mergedOID,
            baseHistory: registration.baseHistory))
      }
      try save(persist) { $0.phase = .ledger }
    }
    try protection.verify()
    try validate(allowUpdated: true)
    guard phase == .ledger,
      try owner.store.records().first(where: { $0.projectID == original.projectID }) == updated
    else { throw invalidRecoveryMetadata() }
    try completeCatalog()
    try save(persist) { $0.phase = .finished }
    try release(protection, branches: branches, persist: persist)
    return .init(projectID: original.projectID, operationID: operationID, oid: target)
  }

  private mutating func acquire(
    metadata: WorktreeSourceMetadata, lock: RepositoryLock, branches: [String],
    persist: (Self) throws -> Void
  ) throws -> WorktreeSourceGuards {
    if guards?.cleaning == true {
      try finishGuards(metadata: metadata, lock: lock, branches: branches, persist: persist)
    }
    var ownership =
      try guards
      ?? .init(
        operationID: operationID, common: repository.common, branches: branches, guardingHead: false
      )
    return try WorktreeSourceGuards.acquire(
      &ownership, metadata: metadata, repositoryLock: lock, branches: branches, guardingHead: false,
      persist: { update in try save(persist) { $0.guards = update } })
  }

  private mutating func release(
    _ protection: WorktreeSourceGuards, branches: [String], persist: (Self) throws -> Void
  ) throws {
    guard var ownership = guards else { throw invalidRecoveryMetadata() }
    try protection.release(
      &ownership, branches: branches, guardingHead: false,
      persist: { update in try save(persist) { $0.guards = update } })
    try save(persist) { $0.guards = nil }
  }

  private mutating func finishGuards(
    metadata: WorktreeSourceMetadata, lock: RepositoryLock, branches: [String],
    persist: (Self) throws -> Void
  ) throws {
    guard let ownership = guards else { return }
    if ownership.cleaning {
      try WorktreeSourceGuards.finishCleanup(
        ownership, metadata: metadata, repositoryLock: lock, branches: branches, guardingHead: false
      )
      try save(persist) { $0.guards = nil }
    } else {
      let protection = try acquire(
        metadata: metadata, lock: lock, branches: branches, persist: persist)
      try release(protection, branches: branches, persist: persist)
    }
  }

  private mutating func save(_ persist: (Self) throws -> Void, change: (inout Self) -> Void) throws
  {
    var next = self
    change(&next)
    try persist(next)
    self = next
  }
}
