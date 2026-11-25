import Foundation

package enum WorktreeBranchAuthority: Sendable { case sandbox, fullAccess }

package struct WorktreeBranchDeletion: Sendable {
  package let branch: String
  package let oid: String
  package let deleted: Bool
}

private struct WorktreeBranchDeletionJournal: Codable {
  enum Phase: String, Codable { case prepared, committed, released, finished }
  var version: Int? = 2
  let operationID: UUID
  let repository: WorktreeRepositoryIdentity
  let branch: String
  let oid: String
  let base: String
  let baseOID: String?
  let baseLog: WorktreeSourceLogPrefix?
  let force: Bool
  let protection: ProtectedWorktreeBranch?
  var phase: Phase = .prepared
  var selection: WorktreeRecoveryBranchSelection?
  var guards: WorktreeSourceGuardJournal?
  var sourceDeletion: WorktreeSourceDeletion?
  var storeReleased: Bool?
}

extension WorktreeRepository {
  /// Preview and confirmation are data in the current call. Every force retry
  /// independently requires Full access.
  package func deleteBranch(
    _ name: String, authority: WorktreeBranchAuthority, force: Bool = false,
    dryRun: Bool = true, confirm: Bool = false,
    authorize: (ProtectedWorktreeBranch?) throws -> Void
  ) throws -> WorktreeBranchDeletion {
    guard !force || authority == .fullAccess else {
      throw WorktreeError.invalidRequest("Sandbox branch deletion cannot force.")
    }
    return try withLock(validateHead: false) { lock in
      let branch = try requireBranch(name)
      try storage.prepare()
      let directory = try deletionDirectory()
      var selected: WorktreeBranchDeletionJournal?
      for name in try directory.entries(limit: 100_000) where name.hasSuffix(".json") {
        let journal = try readDeletion(name, in: directory)
        guard journal.repository == identity, journal.branch == branch, journal.phase != .finished
        else { continue }
        guard selected == nil else { throw invalidRecoveryMetadata() }
        selected = journal
      }
      if var pending = selected {
        guard pending.force == force else {
          throw WorktreeError.invalidRequest("Deletion retry must explicitly repeat its inputs.")
        }
        try authorize(pending.protection)
        if dryRun || !confirm { return .init(branch: branch, oid: pending.oid, deleted: false) }
        return try finishBranchDeletion(
          &pending, lock: lock, authority: authority, authorize: authorize)
      }
      let protection = try store.protectedBranches().first {
        $0.repository == identity.common && $0.branch == branch
      }
      try authorize(protection)
      try requireUnusedBranch(branch)
      guard let oid = try revision(branch) else {
        throw WorktreeError.invalidRequest("Branch does not exist.")
      }
      let base: String
      if let protection {
        base = protection.base
      } else {
        let output = try command(["symbolic-ref", "--quiet", "HEAD"], accepting: [0, 1])
        guard output.exitCode == 0 else {
          throw WorktreeError.invalidRequest("A current base branch is required.")
        }
        base = String(decoding: output.output, as: UTF8.self).trimmingCharacters(in: .newlines)
      }
      guard base != branch, base.hasPrefix("refs/heads/"),
        base == (try requireBranch(String(base.dropFirst("refs/heads/".count))))
      else {
        throw WorktreeError.invalidRequest("Cannot delete the current base branch.")
      }
      let metadata = try sourceMetadata()
      let baseOID = try metadata.direct(base).oid
      let baseLog = try metadata.read("logs/" + base).map { WorktreeSourceLogPrefix($0.contents) }
      var journal = WorktreeBranchDeletionJournal(
        operationID: UUID(), repository: identity,
        branch: branch, oid: oid, base: base, baseOID: baseOID, baseLog: baseLog, force: force,
        protection: protection
      )
      try requireDeletionPolicy(journal, metadata: metadata, deleted: false)
      if dryRun || !confirm { return .init(branch: branch, oid: oid, deleted: false) }
      try saveDeletion(journal, replacing: nil)
      return try finishBranchDeletion(
        &journal, lock: lock, authority: authority, authorize: authorize)
    }
  }

  func hasPendingBranchDeletion(_ ref: String) throws -> Bool {
    guard FileManager.default.fileExists(atPath: storage.journals.path) else { return false }
    let directory = try deletionDirectory()
    for name in try directory.entries(limit: 100_000) where name.hasSuffix(".json") {
      let journal = try readDeletion(name, in: directory)
      if journal.repository == identity, journal.branch == ref, journal.phase != .finished {
        return true
      }
    }
    return false
  }

  private func requireUnusedBranch(_ ref: String) throws {
    let inventory = try WorktreeInventoryEntry.parse(
      command(["worktree", "list", "--porcelain", "-z"]).output)
    guard !inventory.contains(where: { $0.branch == ref }),
      try !store.records().contains(where: {
        $0.worktree?.repository.common == identity.common && $0.worktree?.branch == ref
      })
    else { throw WorktreeError.busy("A live or retained worktree still owns this branch.") }
  }

  private func requireDeletionPolicy(
    _ journal: WorktreeBranchDeletionJournal, metadata: WorktreeSourceMetadata, deleted: Bool
  ) throws {
    try requireUnusedBranch(journal.branch)
    guard try metadata.direct(journal.branch).oid == (deleted ? nil : journal.oid),
      try metadata.direct(journal.base).oid == journal.baseOID,
      try metadata.read("logs/" + journal.base).map({ WorktreeSourceLogPrefix($0.contents) })
        == journal.baseLog
    else { throw sourceMetadataChanged() }
    let protected = try store.protectedBranches().filter {
      $0.repository == identity.common && $0.branch == journal.branch
    }
    if let protection = journal.protection {
      guard protected == [protection] || (journal.storeReleased == true && protected.isEmpty)
      else { throw invalidRecoveryMetadata() }
    } else {
      guard protected.isEmpty,
        try metadata.read("HEAD", limit: 4096)?.contents
          == Data(("ref: " + journal.base + "\n").utf8)
      else { throw sourceMetadataChanged() }
    }
    guard !journal.force else { return }
    guard let baseOID = journal.baseOID else {
      throw WorktreeError.invalidRequest("A merged branch requires an existing base.")
    }
    if !deleted, try !isAncestor(journal.oid, of: baseOID) {
      throw WorktreeError.invalidRequest("Branch is not merged into its recorded base.")
    }
    if let protection = journal.protection {
      guard journal.oid == protection.publishedOID, let history = protection.baseHistory
      else { throw sourceMetadataChanged() }
      if !deleted {
        guard let log = try refHistory(journal.branch),
          String(decoding: log, as: UTF8.self).split(separator: "\n").contains(where: {
            $0.hasSuffix("\tcomputer-mcp worktree " + protection.worktreeID.uuidString.lowercased())
          })
        else { throw sourceMetadataChanged() }
      }
      try requireRefHistory(journal.base, history: history, expectedOID: baseOID)
    }
  }

  /// A retained tag keeps its original identity even when the tagged commit is integrated.
  private func baseObjectClosure(_ oid: String?, budget: WorktreeObjectBudget) throws -> Set<String>
  {
    guard let oid else { return [] }
    try identity.verify()
    let count = min(budget.limits.objectCount, WorktreeRecoveryCatalog.recordLimit)
    let output = try git.run(
      ["rev-list", "--objects", "--no-object-names", oid],
      at: URL(fileURLWithPath: identity.main.path),
      gitDirectory: URL(fileURLWithPath: identity.common.path), deadline: budget.deadline,
      commandOutputBytes: (count + 1) * (identity.format.hexCount + 1)
    ).output
    try budget.check()
    guard output.last == 10, let contents = String(data: output.dropLast(), encoding: .utf8) else {
      throw invalidRecoveryMetadata()
    }
    let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.count <= count else {
      throw WorktreeError.busy("Recorded base exceeds its object verification bound.")
    }
    var objects: Set<String> = []
    for line in lines {
      try budget.check()
      let oid = String(line)
      guard identity.format.containsRecoveryOID(oid), objects.insert(oid).inserted
      else { throw invalidRecoveryMetadata() }
    }
    guard objects.contains(oid) else { throw invalidRecoveryMetadata() }
    try identity.verify()
    return objects
  }

  private func finishBranchDeletion(
    _ journal: inout WorktreeBranchDeletionJournal, lock: RepositoryLock,
    authority: WorktreeBranchAuthority, authorize: (ProtectedWorktreeBranch?) throws -> Void
  ) throws -> WorktreeBranchDeletion {
    var state = journal
    defer { journal = state }
    guard state.version == 2, !state.force || authority == .fullAccess,
      state.selection.map({ $0.source == source }) ?? true
    else {
      throw WorktreeError.recoveryRequired("Deletion has no attributable recovery-store receipt.")
    }
    let metadata = try sourceMetadata()
    let branch = state.branch
    let base = state.base
    let branches = [branch, base]
    let guardingHead = state.protection == nil
    let operationID = state.operationID
    let deletionReceipts = state.sourceDeletion?.deletionReceipts ?? [:]
    let budget = try WorktreeObjectBudget(.init())
    func save(_ change: (inout WorktreeBranchDeletionJournal) -> Void) throws {
      let previous = try deletionBytes(state)
      var next = state
      change(&next)
      try saveDeletion(next, replacing: previous)
      state = next
    }
    try authorize(state.protection)
    try lock.verify()
    try save { _ in }
    func finish(_ recovery: WorktreeRecoveryStore.Locked?) throws -> WorktreeBranchDeletion {
      if let sql = state.protection, let recovery, state.selection == nil {
        guard state.phase == .prepared, state.sourceDeletion == nil else {
          throw invalidRecoveryMetadata()
        }
        try requireDeletionPolicy(state, metadata: metadata, deleted: false)
        let projectID = "worktree-" + sql.worktreeID.uuidString.lowercased()
        guard let removal = try readRemoval(projectID),
          case .removed = try storage.removalOutcome(
            projectID: projectID, operationID: removal.operationID,
            registrationRemoved: { try !store.records().contains { $0.projectID == projectID } }),
          removal.guards == nil, removal.oid == sql.publishedOID,
          removal.record.worktree?.branchID == sql.branchID,
          let publication = try readPublication(projectID), publication.phase == .finished,
          publication.removalID == removal.operationID,
          let retention = publication.handoff?.retention,
          retention.generation == recovery.generation, retention.owner.worktreeID == sql.worktreeID
        else { throw invalidRecoveryMetadata() }
        let catalog = try recovery.catalog()
        guard
          catalog.records.contains(where: { record in
            record.owner == retention.owner && record.oid == sql.publishedOID
              && record.state == .retained
              && record.claims.contains {
                $0.reason == .privateHead && $0.capture == retention.capture
              }
          })
        else { throw invalidRecoveryMetadata() }
        let objects = try state.force ? [] : baseObjectClosure(state.baseOID, budget: budget)
        let selected = try WorktreeRecoveryBranchSelection(
          operationID: operationID, repository: identity, source: source, protection: sql,
          baseOID: state.baseOID, force: state.force, authority: authority,
          catalog: catalog,
          originalBaseObjects: objects)
        guard selected.owner == retention.owner else { throw invalidRecoveryMetadata() }
        try save { $0.selection = selected }
      }
      if state.protection != nil, recovery == nil || state.selection == nil {
        throw invalidRecoveryMetadata()
      }
      if state.phase == .prepared, let selection = state.selection, let recovery {
        try selection.prepare(in: recovery)
      }
      var ownership =
        try state.guards
        ?? .init(
          operationID: operationID, common: identity.common, branches: branches,
          guardingHead: guardingHead)
      if ownership.cleaning {
        guard state.phase == .released else { throw invalidRecoveryMetadata() }
        try WorktreeSourceGuards.finishCleanup(
          ownership, metadata: metadata, repositoryLock: lock, branches: branches,
          guardingHead: guardingHead, deletionReceipts: deletionReceipts)
        try save { $0.phase = .finished }
        return .init(branch: branch, oid: state.oid, deleted: true)
      }
      let guards = try WorktreeSourceGuards.acquire(
        &ownership, metadata: metadata, repositoryLock: lock, branches: branches,
        guardingHead: guardingHead, deletionReceipts: deletionReceipts,
        persist: { value in try save { $0.guards = value } })
      func revalidate(_ deleted: Bool) throws {
        try lock.verify()
        try guards.verify()
        try authorize(state.protection)
        try requireDeletionPolicy(state, metadata: metadata, deleted: deleted)
      }
      if let selection = state.selection, let recovery {
        let hasActivePin = try recovery.catalog().intents.contains { $0.id == operationID }
        if state.phase == .prepared || (state.phase == .committed && hasActivePin) {
          try guards.verify()
          try selection.verifyBeforeDeletion(in: recovery, git: git, budget: budget)
        }
      }
      if state.sourceDeletion == nil {
        guard state.phase == .prepared else { throw invalidRecoveryMetadata() }
        try revalidate(false)
        let sourceDeletion = try WorktreeSourceDeletion(
          branch: branch, expected: state.oid, base: base, expectedBase: state.baseOID,
          requireSymbolicHead: guardingHead, guards: guards)
        try save { $0.sourceDeletion = sourceDeletion }
      }
      guard var sourceDeletion = state.sourceDeletion else { throw invalidRecoveryMetadata() }
      try sourceDeletion.completeSource(
        guards: guards, revalidate: revalidate,
        persist: { value in try save { $0.sourceDeletion = value } })
      guard sourceDeletion.phase == .sourceDeleted else { throw invalidRecoveryMetadata() }
      if state.phase == .prepared { try save { $0.phase = .committed } }
      if state.phase == .committed {
        func verifyDeletion() throws {
          try revalidate(true)
          guard state.sourceDeletion?.phase == .sourceDeleted,
            let receipt = sourceDeletion.deletionReceipts[branch],
            try guards.guardProof(for: branch) == receipt
          else { throw sourceMetadataChanged() }
          try save { _ in }
        }
        if let selection = state.selection, let recovery {
          try selection.releaseAfterDeletion(in: recovery, verifySourceDeleted: verifyDeletion)
        }
        try verifyDeletion()
        if state.storeReleased != true { try save { $0.storeReleased = true } }
        if let sql = state.protection,
          try store.protectedBranches().contains(sql)
        {
          try verifyDeletion()
          try store.releaseProtection(sql)
        }
        try save { $0.phase = .released }
      }
      guard state.phase == .released else { throw invalidRecoveryMetadata() }
      try revalidate(true)
      try guards.release(
        &ownership, branches: branches, guardingHead: guardingHead,
        deletionReceipts: sourceDeletion.deletionReceipts,
        persist: { value in try save { $0.guards = value } })
      try save { $0.phase = .finished }
      return .init(branch: branch, oid: state.oid, deleted: true)
    }
    if state.protection != nil {
      return try WorktreeRecoveryStore(storage: storage, io: io)
        .withExclusive(repository: identity) { try finish($0) }
    }
    return try finish(nil)
  }

  private func deletionDirectory() throws -> WorktreeDirectory {
    try WorktreeDirectory(storage.journals).child("branch-deletions", create: true)
  }

  private func deletionBytes(_ journal: WorktreeBranchDeletionJournal) throws -> Data {
    try recoveryJSON(journal)
  }

  private func readDeletion(_ name: String, in directory: WorktreeDirectory)
    throws -> WorktreeBranchDeletionJournal
  {
    guard let bytes = try io.read(name, in: directory, limit: WorktreeRecoveryCatalog.byteLimit)
    else { throw invalidRecoveryMetadata() }
    let journal = try JSONDecoder().decode(WorktreeBranchDeletionJournal.self, from: bytes)
    try WorktreeSourceMetadata.requireBranch(journal.branch)
    try WorktreeSourceMetadata.requireBranch(journal.base)
    guard name == journal.operationID.uuidString.lowercased() + ".json",
      journal.base != journal.branch,
      journal.repository.format.contains(journal.oid),
      journal.baseOID.map(journal.repository.format.contains) ?? true,
      journal.baseLog.map({ $0.bytes >= 0 && $0.digest.isRecoveryDigest }) ?? true,
      journal.version == nil || journal.version == 2,
      journal.protection.map({
        $0.repository == journal.repository.common && $0.branch == journal.branch
          && $0.base == journal.base
      }) ?? (journal.selection == nil),
      journal.guards.map({ $0.operationID == journal.operationID }) ?? true,
      journal.selection.map({
        $0.operationID == journal.operationID && $0.repository == journal.repository
          && $0.source.root == journal.repository.source.path && $0.protection == journal.protection
          && $0.force == journal.force && $0.baseOID == journal.baseOID
      }) ?? true,
      journal.sourceDeletion.map({
        $0.operationID == journal.operationID && $0.branch == journal.branch
          && $0.base == journal.base && $0.expected == journal.oid
          && $0.expectedBase == journal.baseOID
      }) ?? true
    else { throw invalidRecoveryMetadata() }
    if journal.version == 2, journal.phase != .prepared {
      guard journal.sourceDeletion?.phase == .sourceDeleted, journal.guards != nil,
        journal.phase == .committed || journal.storeReleased == true,
        journal.protection == nil || journal.selection != nil
      else { throw invalidRecoveryMetadata() }
    }
    return journal
  }

  private func saveDeletion(_ journal: WorktreeBranchDeletionJournal, replacing previous: Data?)
    throws
  {
    let bytes = try deletionBytes(journal)
    guard bytes.count <= WorktreeRecoveryCatalog.byteLimit else {
      throw WorktreeError.busy("Branch deletion journal exceeds its byte bound.")
    }
    let name = journal.operationID.uuidString.lowercased() + ".json"
    let directory = try deletionDirectory()
    if bytes == previous {
      try io.synchronize(name, in: directory, expecting: bytes)
    } else {
      try io.write(bytes, name: name, in: directory, replacing: previous)
    }
  }
}
