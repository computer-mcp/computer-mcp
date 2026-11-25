import Foundation

/// SQL facts that can change independently of the repository lock.
package struct WorktreeRecoveryDependencyEvidence: Equatable, Sendable {
  package struct Activity: Equatable, Sendable {
    package let id: UUID
    package let revision: String

    package init(id: UUID, revision: String) {
      self.id = id
      self.revision = revision
    }
  }

  package let registrations: [DerivedProjectSource]
  package let derived: [DerivedProjectRecord]
  package let protections: [ProtectedWorktreeBranch]
  package let unfinishedOperations: [Activity]
  package let executions: [Activity]

  package init(
    registrations: [DerivedProjectSource], derived: [DerivedProjectRecord],
    protections: [ProtectedWorktreeBranch], unfinishedOperations: [Activity],
    executions: [Activity]
  ) {
    self.registrations = registrations
    self.derived = derived
    self.protections = protections
    self.unfinishedOperations = unfinishedOperations
    self.executions = executions
  }
}

package protocol WorktreeRecoveryDependencyReading: Sendable {
  func recoveryEvidence(
    for repository: WorktreeRepositoryIdentity, sources: Set<DerivedProjectSource>
  ) throws -> WorktreeRecoveryDependencyEvidence

  /// Called with the outer filesystem locks already held. The closure may write
  /// only through the held store, and cannot enter a gate or acquire a lock.
  func validateRecoveryEvidence(
    _ expected: WorktreeRecoveryDependencyEvidence,
    for repository: WorktreeRepositoryIdentity, sources: Set<DerivedProjectSource>,
    commit: () throws -> Void
  ) throws -> Bool
}

final class WorktreeRecoveryEvidenceBudget {
  private var remainingBytes = WorktreeRecoveryCatalog.byteLimit
  private var remainingFiles = WorktreeRecoveryCatalog.recordLimit
  private let deadline: ContinuousClock.Instant

  init(deadline: ContinuousClock.Instant) { self.deadline = deadline }

  func account(_ bytes: Int) throws {
    try check()
    guard remainingFiles > 0, bytes <= remainingBytes else {
      throw WorktreeError.busy("Recovery lifecycle evidence exceeds its aggregate bound.")
    }
    remainingFiles -= 1
    remainingBytes -= bytes
  }

  func check() throws {
    try Task.checkCancellation()
    guard ContinuousClock.now < deadline else {
      throw WorktreeError.busy("Recovery lifecycle evidence exceeded its deadline.")
    }
  }
}

extension WorktreeRecoveryRecord.Owner {
  var projectID: String { "worktree-" + worktreeID.uuidString.lowercased() }

  func matches(_ creation: WorktreeCreationJournal) -> Bool {
    creation.record.source == source && creation.id == projectID
      && creation.branchID == branchID && creation.branch == branch
      && creation.record.provenance
        == .host(
          worktreeID: worktreeID, storageGeneration: storageGeneration)
  }

  func matches(_ protection: ProtectedWorktreeBranch) -> Bool {
    protection.branchID == branchID && protection.branch == branch
      && protection.worktreeID == worktreeID
  }
}

extension WorktreeRepository {
  func recoveryTopology(
    _ record: DerivedProjectRecord, owner: WorktreeRecoveryRecord.Owner
  ) throws -> VerifiedWorktreeTopology {
    guard record.state == .active, record.worktree?.repository == identity,
      let creation = try readJournal(owner.projectID), creation.phase == .active,
      creation.repository == identity, owner.matches(creation),
      try matchesActiveRecord(creation, record)
    else { throw WorktreeError.identityChanged("Live recovery owner generation changed.") }
    return try verifyTopology(creation, repository: identity, source: source, validateHead: false)
  }

  func recoveryFinalCapture(
    _ owner: WorktreeRecoveryRecord.Owner, generation: UUID,
    account: (Int) throws -> Void = { _ in }
  ) throws -> (oid: String, capture: WorktreeRecoveryRecord.Claim.Capture) {
    guard let creation = try readJournal(owner.projectID, account: account),
      creation.phase == .removed,
      creation.repository == identity, owner.matches(creation),
      let removal = try readRemoval(owner.projectID, account: account),
      [.finished, .unregistering].contains(removal.phase), removal.guards == nil,
      removal.repositoryArmed == true, removal.terminal?.receipts != nil,
      let reconciliation = removal.reconciliation, reconciliation.finished,
      reconciliation.owner == owner, reconciliation.generation == generation,
      reconciliation.removalID == removal.operationID,
      let publication = try readPublication(owner.projectID, account: account),
      publication.phase == .finished,
      publication.operationID == removal.operationID, publication.removalID == removal.operationID,
      publication.sourcePublication?.guards == nil,
      let retention = publication.handoff?.retention, retention.kind == .removal,
      retention.owner == owner, retention.generation == generation,
      retention.capture == reconciliation.finalCapture, let oid = removal.oid,
      publication.capturedOID == oid, removal.record.worktree?.lastPublishedOID == oid,
      try retention.capturedHead() == oid
    else {
      throw WorktreeError.busy("Host teardown has no terminal proof for this recovery generation.")
    }
    guard let registration = removal.record.worktree else { throw invalidRecoveryMetadata() }
    for removed in [
      registration.contentParent, registration.repositoryParent, registration.runtime,
    ] {
      guard try WorktreeDirectory.openIfPresent(URL(fileURLWithPath: removed.path)) == nil
      else { throw WorktreeError.identityChanged("Inactive worktree storage was substituted.") }
    }
    return (oid, retention.capture)
  }

  func hasPendingRecoveryLifecycle(
    _ owner: WorktreeRecoveryRecord.Owner, generation: UUID,
    account: (Int) throws -> Void = { _ in }
  ) throws -> Bool {
    let id = owner.projectID
    if let publication = try readPublication(id, account: account),
      ![.finished, .rejected].contains(publication.phase)
        || publication.sourcePublication?.guards != nil || publication.installationGuards != nil
    {
      return true
    }
    if let removal = try readRemoval(id, account: account),
      ![.finished, .abandoned].contains(removal.phase)
    {
      // After SQL unregistration, the terminal teardown evidence can be used
      // even if publishing the finished phase lost its source directory.
      if removal.phase != .unregistering || removal.guards != nil
        || removal.reconciliation?.finished != true || removal.terminal?.receipts == nil
      {
        return true
      }
    }
    if let merge = try readMerge(id, account: account),
      ![.finished, .abandoned].contains(merge.phase) || merge.sourceGuards != nil
        || merge.indexLease != nil
    {
      return true
    }
    if let directory = try replacementDirectory(owner, create: false) {
      var remaining = WorktreeRecoveryCatalog.byteLimit
      for name in try directory.entries(limit: WorktreeRecoveryCatalog.referenceLimit) {
        if !name.hasSuffix(".json") { continue }
        guard let id = UUID(uuidString: String(name.dropLast(5))),
          name == id.uuidString.lowercased() + ".json",
          let replacement = try readReplacement(
            id, in: directory, owner: owner, generation: generation, synchronizing: false,
            account: { bytes in
              guard bytes <= remaining else {
                throw WorktreeError.busy("Replacement evidence exceeds its aggregate bound.")
              }
              remaining -= bytes
              try account(bytes)
            })
        else { throw invalidRecoveryMetadata() }
        if replacement.guardOwnership != nil || replacement.change?.phase != .finished {
          return true
        }
      }
    }
    return false
  }
}
