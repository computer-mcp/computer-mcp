import Foundation

package struct WorktreeRemovalResult: Sendable {
  package let projectID: String
  package let branch: String
  package let oid: String
  package let terminationWarnings: [String]
}

struct WorktreeRemovalJournal: Codable {
  enum Phase: String, Codable {
    case closing, preserved, content, repository, runtime, unregistering, finished,
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
}

extension WorktreeRepository {
  /// The caller supplies the execution owner's termination barrier and live
  /// authorization, including main-checkout destinations needed by recovery.
  package func remove(
    projectID: String, force: Bool = false, limits: WorktreePromotionLimits = .init(),
    terminate: (WorktreeAdmission, UUID) async throws -> Void,
    authorize: (DerivedProjectRecord, [URL]) throws -> Void
  ) async throws -> WorktreeRemovalResult {
    try limits.validate()
    let lock = try acquireLock(validateHead: false)
    defer { lock.release() }
    var pending = try readRemoval(projectID)
    if let pending, pending.phase == .finished {
      try authorize(pending.record, [])
      return try removalResult(pending)
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
        operationID: UUID(), repository: identity, record: record,
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
      let topology = try verifyTopology(creation, repository: identity, source: source)
      if !force, try !status(topology).isEmpty {
        try advanceRemoval(&journal, to: .abandoned)
        try journal.admission.reopen(operationID: journal.operationID)
        throw WorktreeError.busy("Worktree contains tracked, staged, untracked or ignored changes.")
      }
      let roots = try removalRoots(topology)
      let publication = try publishLocked(
        projectID: projectID, preserving: roots, limits: limits, lock: lock,
        authorize: { try authorize($0, []) })
      guard let published = try store.records().first(where: { $0.projectID == projectID }),
        published.worktree?.lastPublishedOID == publication.oid,
        try privateMetadata(topology).head == publication.oid
      else { throw WorktreeError.recoveryRequired("Worktree changed after removal capture.") }
      try authorize(published, [])
      try topology.verifyDirectories()
      let old = try removalBytes(journal)
      journal.record = published
      journal.oid = publication.oid
      journal.phase = .preserved
      try saveRemoval(journal, replacing: old)
    }
    return try finishRemoval(&journal, lock: lock, authorize: authorize)
  }

  private func reconcileRemovalDependencies(
    _ id: String, lock: RepositoryLock, limits: WorktreePromotionLimits,
    authorize: (DerivedProjectRecord, [URL]) throws -> Void
  ) throws {
    if var pending = try readMerge(id) {
      if [.captured, .prepared].contains(pending.phase) {
        try authorize(pending.record, [])
        try advanceMerge(&pending, to: .abandoned)
      }
      if [.finished, .abandoned].contains(pending.phase) {
        try cleanMergeStaging(pending)
      } else {
        _ = try finishMerge(&pending, lock: lock, limits: limits, authorize: authorize)
      }
    }
    if var pending = try readPublication(id) {
      if [.finished, .rejected].contains(pending.phase) {
        try cleanPublicationStaging(pending)
      } else {
        _ = try recoverPublication(&pending, lock: lock, authorize: { try authorize($0, []) })
      }
    }
  }

  private func finishRemoval(
    _ journal: inout WorktreeRemovalJournal, lock: RepositoryLock,
    authorize: (DerivedProjectRecord, [URL]) throws -> Void
  ) throws -> WorktreeRemovalResult {
    guard let registration = journal.record.worktree, let oid = journal.oid,
      var creation = try readJournal(journal.record.projectID)
    else { throw WorktreeError.recoveryRequired("Removal preservation receipt is incomplete.") }
    try requireDirectRef(registration.branch, oid: oid)
    guard let publication = try readPublication(journal.record.projectID),
      publication.phase == .finished, publication.capturedOID == oid,
      try readMerge(journal.record.projectID).map({ [.finished, .abandoned].contains($0.phase) })
        ?? true
    else { throw WorktreeError.recoveryRequired("A lifecycle journal still needs this worktree.") }
    for root in Set(publication.roots + [publication.expectedOID]) {
      try requireObjectRef(preservationRef(journal.record, oid: root), oid: root)
    }
    if journal.phase == .preserved {
      let topology = try verifyTopology(creation, repository: identity, source: source)
      guard try privateMetadata(topology).head == oid,
        try journal.force || status(topology).isEmpty
      else { throw WorktreeError.busy("Worktree changed before destruction.") }
      var removing = journal.record
      removing.state = .removing
      removing.revision += 1
      if try store.records().first(where: { $0.projectID == removing.projectID }) != removing {
        try store.commit(removing, expecting: journal.record.revision, protecting: nil)
      }
      if creation.phase == .active {
        let old = try encoded(creation)
        creation.phase = .removing
        try saveJournal(creation, replacing: old)
      }
      try advanceRemoval(&journal, to: .content)
    }
    let steps:
      [(WorktreeRemovalJournal.Phase, WorktreeDirectoryIdentity, WorktreeRemovalJournal.Phase)] = [
        (.content, registration.contentParent, .repository),
        (.repository, registration.repositoryParent, .runtime),
        (.runtime, registration.runtime, .unregistering),
      ]
    for (phase, directory, next) in steps where journal.phase == phase {
      try lock.verify()
      try journal.admission.requireDrained(operationID: journal.operationID)
      try authorize(journal.record, [])
      if phase == .content { try requireRemovalChild(registration.root) }
      if phase == .repository { try requireRemovalChild(registration.gitDirectory) }
      let parent = try WorktreeDirectory(
        URL(fileURLWithPath: directory.path).deletingLastPathComponent())
      try parent.removeOwnedTree(directory, io: io) { path in
        if phase == .content {
          let root = URL(fileURLWithPath: journal.record.root)
          if path.path == root.path || path.path.hasPrefix(root.path + "/") {
            try authorize(journal.record, [path])
          }
        }
      }
      try advanceRemoval(&journal, to: next)
    }
    if journal.phase == .unregistering {
      if let record = try store.records().first(where: { $0.projectID == journal.record.projectID })
      {
        var removing = journal.record
        removing.state = .removing
        removing.revision += 1
        guard record == removing else { throw DerivedProjectStoreError.revisionConflict }
        try store.remove(record.projectID, expecting: record.revision)
      }
      if creation.phase != .removed {
        let old = try encoded(creation)
        creation.phase = .removed
        try saveJournal(creation, replacing: old)
      }
      try advanceRemoval(&journal, to: .finished)
    }
    return try removalResult(journal)
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
    try io.write(
      removalBytes(journal), name: journal.record.projectID + ".json", in: removalDirectory(),
      replacing: previous)
  }

  func readRemoval(_ id: String) throws -> WorktreeRemovalJournal? {
    guard let data = try io.read(id + ".json", in: removalDirectory(), limit: 131_072) else {
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

  private func advanceRemoval(
    _ journal: inout WorktreeRemovalJournal, to phase: WorktreeRemovalJournal.Phase
  ) throws {
    let old = try removalBytes(journal)
    journal.phase = phase
    try saveRemoval(journal, replacing: old)
  }
}
