import Foundation

package struct WorktreeRemovalResult: Equatable, Sendable {
  package let projectID: String
  package let branch: String
  package let oid: String
  package let terminationWarnings: [String]
}

struct WorktreeRemovalJournal: Codable {
  enum Phase: String, Codable {
    case closing, preserved, content, repository, runtime, reconciling, unregistering, finished,
      abandoned
  }
  let operationID: UUID
  let repository: WorktreeRepositoryIdentity
  var record: DerivedProjectRecord
  let admission: WorktreeAdmission
  let force: Bool
  var phase: Phase
  var oid: String?
  var terminationWarnings: [String]?
  var guards: WorktreeSourceGuardJournal?
  var repositoryArmed: Bool?
  var reconciliation: WorktreeRecoveryReconciliation?
  var terminal: WorktreeRecoveryTerminal?

  func requireCompletionSpace(limit: Int = WorktreeRecoveryCatalog.byteLimit) throws {
    guard terminal?.receipts != nil, reconciliation != nil else { throw invalidRecoveryMetadata() }
    var largest = self
    largest.repositoryArmed = true
    largest.phase = .unregistering
    // Keep the live guards and the longer unfinished flag in the projection.
    guard try recoveryJSON(largest).count <= limit else {
      throw WorktreeError.busy("Removal completion exceeds its journal byte bound.")
    }
  }
}

extension WorktreeRepository {
  /// The caller supplies the execution owner's termination barrier and live
  /// authorization, including main-checkout destinations needed by recovery.
  /// A host-reserved `operationID` names a new removal journal; an incomplete
  /// journal of another operation is never adopted under that ID.
  package func remove(
    projectID: String, force: Bool = false, operationID: UUID? = nil,
    limits: WorktreePromotionLimits = .init(),
    terminate: (WorktreeAdmission, UUID) async throws -> Void,
    authorize: (DerivedProjectRecord, [URL]) throws -> Void
  ) async throws -> WorktreeRemovalResult {
    try limits.validate()
    let lock = try acquireLock(validateHead: false)
    defer { lock.release() }
    var pending = try readRemoval(projectID)
    if let operationID, let other = pending, other.operationID != operationID,
      other.phase != .abandoned
    {
      throw WorktreeError.busy("Another removal operation is incomplete for this worktree.")
    }
    if var completed = pending, completed.phase == .finished {
      try authorize(completed.record, [])
      try synchronizeRemoval(completed)
      try cleanRemovalGuards(&completed, lock: lock)
      return try removalResult(completed)
    }
    if let abandoned = pending, abandoned.phase == .abandoned {
      try authorize(abandoned.record, [])
      try abandoned.admission.reopen(operationID: abandoned.operationID)
      pending = nil
    }
    if pending == nil {
      guard let record = try store.records().first(where: { $0.projectID == projectID }),
        record.state == .active, let creation = try readJournal(projectID),
        creation.phase == .active, try matchesActiveRecord(creation, record)
      else { throw WorktreeError.recoveryRequired("No active host worktree to remove.") }
      try authorize(record, [])
      let topology = try verifyTopology(
        creation, repository: identity, source: source, validateHead: false)
      let admission = try WorktreeAdmission(topology: topology)
      let next = WorktreeRemovalJournal(
        operationID: operationID ?? UUID(), repository: identity, record: record,
        admission: admission, force: force, phase: .closing)
      try saveRemoval(next, replacing: try readRemoval(projectID).map(removalBytes))
      pending = next
    }
    var journal = pending!
    guard journal.force == force else {
      throw WorktreeError.invalidRequest("Retry must use the recorded removal inputs.")
    }
    try authorize(journal.record, [])
    _ = try journal.admission.close(operationID: journal.operationID)
    try await terminate(journal.admission, journal.operationID)
    try journal.admission.requireDrained(operationID: journal.operationID)
    let warnings = try journal.admission.terminationWarnings(operationID: journal.operationID)
    if journal.terminationWarnings != warnings {
      let previous = try removalBytes(journal)
      journal.terminationWarnings = warnings
      try saveRemoval(journal, replacing: previous)
    }
    try lock.verify()
    if journal.phase == .closing {
      try reconcileRemovalDependencies(projectID, lock: lock, limits: limits, authorize: authorize)
      guard let creation = try readJournal(projectID),
        let current = try store.records().first(where: { $0.projectID == projectID }),
        current.state == .active, try matchesActiveRecord(creation, current)
      else { throw WorktreeError.recoveryRequired("Removal registration changed.") }
      let topology = try verifyTopology(
        creation, repository: identity, source: source, validateHead: false)
      if !force, try !status(topology).isEmpty {
        let publication = try readPublication(projectID)
        if publication?.removalID != journal.operationID || publication?.phase == .rejected {
          try advanceRemoval(&journal, to: .abandoned)
          try journal.admission.reopen(operationID: journal.operationID)
        }
        throw WorktreeError.busy("Worktree contains tracked, staged, untracked or ignored changes.")
      }
      let publication = try publishLocked(
        projectID: projectID, preserving: [], limits: limits, lock: lock,
        removalID: journal.operationID, authorize: { try authorize($0, []) })
      guard let published = try store.records().first(where: { $0.projectID == projectID }),
        published.worktree?.lastPublishedOID == publication.oid
      else { throw WorktreeError.recoveryRequired("Worktree changed after removal capture.") }
      try authorize(published, [])
      try topology.verifyDirectories()
      let old = try removalBytes(journal)
      journal.record = published
      journal.oid = publication.oid
      journal.phase = .preserved
      try saveRemoval(journal, replacing: old)
    }
    return try finishRemoval(&journal, lock: lock, limits: limits, authorize: authorize)
  }

  private func reconcileRemovalDependencies(
    _ id: String, lock: RepositoryLock, limits: WorktreePromotionLimits,
    authorize: (DerivedProjectRecord, [URL]) throws -> Void
  ) throws {
    _ = try recoverMerge(id, lock: lock, limits: limits, authorize: authorize)
    if var pending = try readPublication(id),
      ![.finished, .rejected].contains(pending.phase) || pending.sourcePublication?.guards != nil
    {
      _ = try recoverPublication(&pending, lock: lock, authorize: { try authorize($0, []) })
    }
  }

  private func finishRemoval(
    _ journal: inout WorktreeRemovalJournal, lock: RepositoryLock, limits: WorktreePromotionLimits,
    authorize: (DerivedProjectRecord, [URL]) throws -> Void
  ) throws -> WorktreeRemovalResult {
    var state = journal
    defer { journal = state }
    let original = state.record
    let id = state.operationID
    guard let registration = original.worktree, let oid = state.oid,
      var creation = try readJournal(original.projectID),
      let publication = try readPublication(original.projectID),
      publication.version == 2, publication.phase == .finished, publication.capturedOID == oid,
      publication.removalID == id, publication.operationID == id,
      publication.sourcePublication?.guards == nil, let handoff = publication.handoff,
      handoff.retention.kind == .removal, handoff.retention.operationID == id,
      try readMerge(original.projectID).map({ [.finished, .abandoned].contains($0.phase) }) ?? true
    else { throw WorktreeError.recoveryRequired("Removal preservation receipt is incomplete.") }
    try synchronizeRemoval(state)
    try savePublication(publication, replacing: publicationBytes(publication))
    try state.admission.requireDrained(operationID: id)
    let retention = handoff.retention
    if let reconciliation = state.reconciliation {
      guard reconciliation.removalID == id, reconciliation.generation == retention.generation,
        reconciliation.owner == retention.owner, reconciliation.finalCapture == retention.capture
      else { throw invalidRecoveryMetadata() }
    }
    let branch = registration.branch
    guard original.revision < Int64.max - 1 else { throw invalidRecoveryMetadata() }
    var removing = original
    removing.state = .removing
    removing.revision += 1
    let expectedProtection = ProtectedWorktreeBranch(
      repository: identity.common, branchID: registration.branchID, branch: branch,
      base: registration.base, baseOID: registration.baseOID, publishedOID: oid,
      worktreeID: original.provenance.worktreeID, mergedOID: registration.mergedOID,
      baseHistory: registration.baseHistory)
    let metadata = try sourceMetadata()
    let budget = try WorktreeObjectBudget(limits)
    func save(_ change: (inout WorktreeRemovalJournal) throws -> Void) throws {
      let previous = try removalBytes(state)
      var next = state
      try change(&next)
      try saveRemoval(next, replacing: previous)
      state = next
    }
    func unregister() throws -> WorktreeRemovalResult {
      try lock.verify()
      try identity.verify()
      try authorize(original, [])
      guard state.phase == .unregistering, state.guards == nil,
        state.reconciliation?.finished == true, state.terminal?.receipts != nil,
        try store.protectedBranches().contains(expectedProtection)
      else { throw invalidRecoveryMetadata() }
      let current = try store.records().first(where: { $0.projectID == original.projectID })
      guard current == nil || current == removing else {
        throw DerivedProjectStoreError.revisionConflict
      }
      if creation.phase != .removed {
        let old = try encoded(creation)
        creation.phase = .removed
        try saveJournal(creation, replacing: old)
      } else {
        try io.synchronize(
          creation.id + ".json", in: WorktreeDirectory(storage.journals),
          expecting: encoded(creation))
      }
      if let current {
        try store.remove(current.projectID, expecting: current.revision)
      }
      try save { $0.phase = .finished }
      return try removalResult(state)
    }
    return try WorktreeRecoveryStore(storage: storage, io: io)
      .withExclusive(repository: identity) { recovery in
        guard retention.generation == recovery.generation else { throw invalidRecoveryMetadata() }
        if state.phase == .unregistering {
          try authorize(original, [])
          try cleanRemovalGuards(&state, lock: lock)
          return try unregister()
        }
        var ownership =
          try state.guards
          ?? .init(
            operationID: id, common: identity.common, branches: [branch], guardingHead: false)
        let protection = try WorktreeSourceGuards.acquire(
          &ownership, metadata: metadata, repositoryLock: lock, branches: [branch],
          guardingHead: false, persist: { next in try save { $0.guards = next } })
        func verifyAuthority() throws {
          try lock.verify()
          try protection.verify()
          try identity.verify()
          try authorize(original, [])
          guard try metadata.direct(branch).oid == oid,
            try store.protectedBranches().contains(expectedProtection)
          else { throw sourceMetadataChanged() }
          let current = try store.records().first { $0.projectID == original.projectID }
          if state.phase == .preserved {
            guard current == original || current == removing else {
              throw DerivedProjectStoreError.revisionConflict
            }
          } else {
            guard current == removing else { throw DerivedProjectStoreError.revisionConflict }
          }
        }
        func verifyPrivate() throws {
          try verifyAuthority()
          try verifyFinalRecoveryCapture(handoff, record: original, store: recovery, budget: budget)
        }
        func sealed(_ recordID: UUID, _ evidence: WorktreeRecoveryRecord.Acknowledgement)
          throws -> Bool
        {
          try requireAcknowledgementSeal(
            recordID, evidence: evidence, owner: retention.owner, generation: retention.generation)
        }
        try verifyAuthority()
        if state.phase == .preserved {
          let topology = try verifyTopology(
            creation, repository: identity, source: source, validateHead: false)
          guard try state.force || status(topology).isEmpty else {
            throw WorktreeError.busy("Worktree became dirty after final capture.")
          }
          try verifyPrivate()
          if state.reconciliation == nil {
            let reconciliation = try WorktreeRecoveryReconciliation(
              operationID: UUID(), final: retention, catalog: recovery.catalog(), sealed: sealed)
            try save { $0.reconciliation = reconciliation }
          }
          guard let reconciliation = state.reconciliation else { throw invalidRecoveryMetadata() }
          try reconciliation.prepare(
            in: recovery, verifyFinalRetention: verifyPrivate, sealed: sealed,
            persist: { next in try save { $0.reconciliation = next } })
          let final = try recovery.retentionCompletion(retention)
          guard final.pending else { throw invalidRecoveryMetadata() }
          let terminal = try (state.terminal ?? WorktreeRecoveryTerminal()).planning(
            retention, records: final.records, sealed: sealed)
          let completion = try reconciliation.planning(
            in: recovery.catalog(), afterRetiring: final.records, sealed: sealed)
          try save {
            $0.terminal = terminal
            $0.reconciliation = completion
            try $0.requireCompletionSpace()
          }
          try verifyAuthority()
          if try store.records().first(where: { $0.projectID == removing.projectID }) != removing {
            try store.commit(removing, expecting: original.revision, protecting: nil)
          }
          if creation.phase == .active {
            let old = try encoded(creation)
            creation.phase = .removing
            try saveJournal(creation, replacing: old)
          }
          try save { $0.phase = .content }
        }
        let steps:
          [(WorktreeRemovalJournal.Phase, WorktreeDirectoryIdentity, WorktreeRemovalJournal.Phase)] =
            [
              (.content, registration.contentParent, .repository),
              (.repository, registration.repositoryParent, .runtime),
              (.runtime, registration.runtime, .reconciling),
            ]
        for (phase, directory, next) in steps where state.phase == phase {
          try verifyAuthority()
          if phase == .content {
            if state.terminal?.receipts != nil { try state.requireCompletionSpace() }
            try requireRemovalChild(registration.root)
            try verifyPrivate()
          }
          if phase == .repository {
            try requireRemovalChild(registration.gitDirectory)
            if state.repositoryArmed != true {
              try verifyPrivate()
              try save { $0.repositoryArmed = true }
            } else if try removalMetadataStillIntact(registration.gitDirectory) {
              // HEAD is the first entry removed by the owned Git directory traversal.
              try verifyPrivate()
            }
          }
          let parent = try WorktreeDirectory(
            URL(fileURLWithPath: directory.path).deletingLastPathComponent())
          try parent.removeOwnedTree(directory, io: io) { path in
            if phase == .content {
              let root = URL(fileURLWithPath: original.root)
              if path.path == root.path || path.path.hasPrefix(root.path + "/") {
                try authorize(original, [path])
              }
            }
          }
          try io.beforeDirectorySync()
          try parent.synchronize()
          try save { $0.phase = next }
        }
        if state.phase == .reconciling {
          func verifyTeardown() throws {
            try verifyAuthority()
            try synchronizeRemoval(state)
            guard state.phase == .reconciling, state.repositoryArmed == true
            else { throw invalidRecoveryMetadata() }
            for removed in [
              registration.contentParent, registration.repositoryParent, registration.runtime,
            ] {
              let target = URL(fileURLWithPath: removed.path)
              let parent = try WorktreeDirectory(target.deletingLastPathComponent())
              guard try !parent.hasEntry(target.lastPathComponent) else {
                throw invalidRecoveryMetadata()
              }
            }
          }
          try verifyTeardown()
          guard var reconciliation = state.reconciliation else { throw invalidRecoveryMetadata() }
          var terminal = state.terminal ?? WorktreeRecoveryTerminal()
          if state.terminal == nil { try save { $0.terminal = terminal } }
          try terminal.complete(
            retention, store: recovery, verifyTerminalOutcome: verifyTeardown, sealed: sealed,
            persist: { next in try save { $0.terminal = next } })
          try reconciliation.complete(
            in: recovery, verifyTeardown: verifyTeardown, sealed: sealed,
            persist: { next in
              try save {
                $0.reconciliation = next
                try $0.requireCompletionSpace()
              }
            })
          try save { $0.phase = .unregistering }
        }
        guard state.phase == .unregistering else { throw invalidRecoveryMetadata() }
        try verifyAuthority()
        try protection.release(
          &ownership, branches: [branch], guardingHead: false,
          persist: { next in try save { $0.guards = next } })
        try save { $0.guards = nil }
        return try unregister()
      }
  }

  private func removalMetadataStillIntact(_ expected: WorktreeDirectoryIdentity) throws -> Bool {
    let path = URL(fileURLWithPath: expected.path)
    let parent = try WorktreeDirectory(path.deletingLastPathComponent())
    guard try parent.hasEntry(path.lastPathComponent) else { return false }
    let directory = try parent.child(path.lastPathComponent)
    guard directory.identity == expected else { throw invalidRecoveryMetadata() }
    return try directory.hasEntry("HEAD")
  }

  private func cleanRemovalGuards(
    _ journal: inout WorktreeRemovalJournal, lock: RepositoryLock
  ) throws {
    guard var ownership = journal.guards, let branch = journal.record.worktree?.branch else {
      return
    }
    let metadata = try sourceMetadata()
    func persist(_ next: WorktreeSourceGuardJournal?) throws {
      let previous = try removalBytes(journal)
      journal.guards = next
      try saveRemoval(journal, replacing: previous)
    }
    if ownership.cleaning {
      try WorktreeSourceGuards.finishCleanup(
        ownership, metadata: metadata, repositoryLock: lock, branches: [branch], guardingHead: false
      )
    } else {
      let protection = try WorktreeSourceGuards.acquire(
        &ownership, metadata: metadata, repositoryLock: lock, branches: [branch],
        guardingHead: false, persist: { try persist($0) })
      try protection.release(
        &ownership, branches: [branch], guardingHead: false, persist: { try persist($0) })
    }
    try persist(nil)
  }

  private func requireRemovalChild(_ expected: WorktreeDirectoryIdentity) throws {
    do {
      guard try WorktreeDirectory(URL(fileURLWithPath: expected.path)).identity == expected else {
        throw WorktreeError.identityChanged("A recorded removal child was replaced.")
      }
    } catch let error as POSIXError where error.code == .ENOENT {
      return
    }
  }

  private func removalResult(_ journal: WorktreeRemovalJournal) throws -> WorktreeRemovalResult {
    guard journal.phase == .finished, let oid = journal.oid,
      let branch = journal.record.worktree?.branch
    else {
      throw WorktreeError.recoveryRequired("Removal has no terminal outcome.")
    }
    return .init(
      projectID: journal.record.projectID, branch: branch, oid: oid,
      terminationWarnings: journal.terminationWarnings ?? [])
  }

  func removalDirectory() throws -> WorktreeDirectory {
    try WorktreeDirectory(storage.journals).child("removals", create: true)
  }

  func removalBytes(_ journal: WorktreeRemovalJournal) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(journal)
  }

  func saveRemoval(_ journal: WorktreeRemovalJournal, replacing previous: Data?) throws {
    let bytes = try removalBytes(journal)
    guard bytes.count <= WorktreeRecoveryCatalog.byteLimit else {
      throw WorktreeError.busy("Removal journal exceeds its byte bound.")
    }
    if bytes == previous {
      try synchronizeRemoval(journal)
    } else {
      try io.write(
        bytes, name: journal.record.projectID + ".json", in: removalDirectory(), replacing: previous
      )
    }
  }

  func readRemoval(_ id: String) throws -> WorktreeRemovalJournal? {
    guard
      let data = try io.read(
        id + ".json", in: removalDirectory(), limit: WorktreeRecoveryCatalog.byteLimit)
    else {
      return nil
    }
    let journal = try JSONDecoder().decode(WorktreeRemovalJournal.self, from: data)
    try journal.record.validate()
    guard journal.repository == identity, journal.record.projectID == id,
      journal.record.source == source, journal.record.worktree != nil,
      journal.admission.projectID == id,
      case .host(_, let generation) = journal.record.provenance,
      journal.admission.generation == generation,
      let creation = try readJournal(id), try matchesActiveRecord(creation, journal.record)
    else {
      throw WorktreeError.recoveryRequired("Removal journal identity is invalid.")
    }
    return journal
  }

  private func synchronizeRemoval(_ journal: WorktreeRemovalJournal) throws {
    try io.synchronize(
      journal.record.projectID + ".json", in: removalDirectory(), expecting: removalBytes(journal))
  }

  private func advanceRemoval(
    _ journal: inout WorktreeRemovalJournal, to phase: WorktreeRemovalJournal.Phase
  ) throws {
    let old = try removalBytes(journal)
    journal.phase = phase
    try saveRemoval(journal, replacing: old)
  }
}
