import Foundation

package enum WorktreeBranchAuthority: Sendable { case sandbox, fullAccess }

package struct WorktreeBranchDeletion: Sendable {
  package let branch: String
  package let oid: String
  package let deleted: Bool
}

private struct WorktreeBranchDeletionJournal: Codable {
  enum Phase: String, Codable { case prepared, committed, released, finished }
  let operationID: UUID
  let repository: WorktreeRepositoryIdentity
  let branch: String
  let oid: String
  let base: String
  let baseOID: String?
  let force: Bool
  let protection: ProtectedWorktreeBranch?
  let releasedRoots: [String: String]
  /// These UUID-scoped references and this journal outlive branch protection.
  /// A later branch with the same name never acquires their ownership.
  let retainedRoots: [String: String]
  var roots: [String: String] { releasedRoots.merging(retainedRoots) { released, _ in released } }
  var phase: Phase
  var receipt: String { "refs/computer-mcp/deletions/" + operationID.uuidString.lowercased() }

  enum CodingKeys: String, CodingKey {
    case operationID, repository, branch, oid, base, baseOID, force, protection
    case releasedRoots, retainedRoots, phase
  }
  private enum LegacyKeys: String, CodingKey { case roots }

  init(
    operationID: UUID, repository: WorktreeRepositoryIdentity, branch: String, oid: String,
    base: String, baseOID: String?, force: Bool, protection: ProtectedWorktreeBranch?,
    releasedRoots: [String: String], retainedRoots: [String: String], phase: Phase
  ) {
    self.operationID = operationID
    self.repository = repository
    self.branch = branch
    self.oid = oid
    self.base = base
    self.baseOID = baseOID
    self.force = force
    self.protection = protection
    self.releasedRoots = releasedRoots
    self.retainedRoots = retainedRoots
    self.phase = phase
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    operationID = try values.decode(UUID.self, forKey: .operationID)
    repository = try values.decode(WorktreeRepositoryIdentity.self, forKey: .repository)
    branch = try values.decode(String.self, forKey: .branch)
    oid = try values.decode(String.self, forKey: .oid)
    base = try values.decode(String.self, forKey: .base)
    baseOID = try values.decodeIfPresent(String.self, forKey: .baseOID)
    force = try values.decode(Bool.self, forKey: .force)
    protection = try values.decodeIfPresent(ProtectedWorktreeBranch.self, forKey: .protection)
    phase = try values.decode(Phase.self, forKey: .phase)
    if let released = try values.decodeIfPresent([String: String].self, forKey: .releasedRoots) {
      releasedRoots = released
      retainedRoots = try values.decode([String: String].self, forKey: .retainedRoots)
    } else {
      // The legacy journal released every root, having checked reachability or force.
      releasedRoots = try decoder.container(keyedBy: LegacyKeys.self).decode(
        [String: String].self, forKey: .roots)
      retainedRoots = [:]
    }
  }
}

extension WorktreeRepository {
  /// `force` is a current call input and requires Full access. Preview and
  /// confirmation are data in this call, never a durable grant for a later retry.
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
      for file in try directory.entries(limit: 100_000) where file.hasSuffix(".json") {
        guard let bytes = try io.read(file, in: directory, limit: 131_072) else { continue }
        var pending = try JSONDecoder().decode(WorktreeBranchDeletionJournal.self, from: bytes)
        guard pending.repository == identity,
          pending.branch
            == (try requireBranch(String(pending.branch.dropFirst("refs/heads/".count)))),
          pending.base == (try requireBranch(String(pending.base.dropFirst("refs/heads/".count)))),
          pending.branch != pending.base, identity.format.contains(pending.oid),
          pending.baseOID.map(identity.format.contains) ?? true,
          pending.protection.map({
            $0.repository == identity.common && $0.branch == pending.branch
              && $0.base == pending.base
          }) ?? pending.roots.isEmpty,
          Set(pending.releasedRoots.keys).isDisjoint(with: pending.retainedRoots.keys),
          !pending.force || pending.retainedRoots.isEmpty,
          pending.roots.allSatisfy({
            guard let protection = pending.protection else { return false }
            return $0.key == "refs/computer-mcp/recovery/"
              + protection.branchID.uuidString.lowercased() + "/" + $0.value
              && identity.format.contains($0.value)
          }),
          file == pending.operationID.uuidString.lowercased() + ".json"
        else {
          throw WorktreeError.recoveryRequired("Branch deletion journal identity changed.")
        }
        guard pending.branch == branch, pending.phase != .finished else { continue }
        guard pending.force == force else {
          throw WorktreeError.invalidRequest("Deletion retry must explicitly repeat its inputs.")
        }
        try authorize(pending.protection)
        if dryRun || !confirm { return .init(branch: branch, oid: pending.oid, deleted: false) }
        let normalized = try deletionBytes(pending)
        if normalized != bytes { try saveDeletion(pending, replacing: bytes) }
        return try finishBranchDeletion(&pending, lock: lock, authorize: authorize)
      }
      let protection = try store.protectedBranches().first {
        $0.repository == identity.common && $0.branch == branch
      }
      try authorize(protection)
      try requireUnusedBranch(branch)
      guard let oid = try revision(branch) else {
        throw WorktreeError.invalidRequest("Branch does not exist.")
      }
      try requireDirectRef(branch, oid: oid)
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
      let baseOID = try revision(base)
      try requireBranchValue(base, oid: baseOID)
      let roots = try protection.map(protectionRoots) ?? [:]
      let reachable = try force || roots.isEmpty ? Set<String>() : baseObjectClosure(baseOID)
      let released = roots.filter { force || reachable.contains($0.value) }
      let retained = roots.filter { !force && !reachable.contains($0.value) }
      var journal = WorktreeBranchDeletionJournal(
        operationID: UUID(), repository: identity,
        branch: branch, oid: oid, base: base, baseOID: baseOID, force: force,
        protection: protection, releasedRoots: released, retainedRoots: retained, phase: .prepared)
      try requireDeletionPolicy(journal)
      if dryRun || !confirm { return .init(branch: branch, oid: oid, deleted: false) }
      try saveDeletion(journal, replacing: nil)
      return try finishBranchDeletion(&journal, lock: lock, authorize: authorize)
    }
  }

  func hasPendingBranchDeletion(_ ref: String) throws -> Bool {
    guard FileManager.default.fileExists(atPath: storage.journals.path) else { return false }
    let directory = try deletionDirectory()
    for name in try directory.entries(limit: 100_000) where name.hasSuffix(".json") {
      guard let data = try io.read(name, in: directory, limit: 131_072) else { continue }
      let journal = try JSONDecoder().decode(WorktreeBranchDeletionJournal.self, from: data)
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

  private func requireBranchValue(_ ref: String, oid: String?) throws {
    guard try command(["symbolic-ref", "--quiet", ref], accepting: [0, 1]).exitCode == 1,
      try revision(ref) == oid
    else { throw WorktreeError.recoveryRequired("Expected branch value changed.") }
  }

  private func protectionRoots(_ branch: ProtectedWorktreeBranch) throws -> [String: String] {
    let prefix = "refs/computer-mcp/recovery/" + branch.branchID.uuidString.lowercased() + "/"
    let output = try command([
      "for-each-ref", "--format=%(refname) %(objectname) %(symref)", prefix,
    ]).output
    var result: [String: String] = [:]
    for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
      let fields = line.split(separator: " ", omittingEmptySubsequences: false)
      guard fields.count == 3, fields[2].isEmpty, fields[0] == prefix + fields[1],
        identity.format.contains(String(fields[1]))
      else {
        throw WorktreeError.recoveryRequired("Protected commit reference changed.")
      }
      result[String(fields[0])] = String(fields[1])
    }
    return result
  }

  private func requireDeletionPolicy(_ journal: WorktreeBranchDeletionJournal) throws {
    try requireUnusedBranch(journal.branch)
    try requireDirectRef(journal.branch, oid: journal.oid)
    try requireBranchValue(journal.base, oid: journal.baseOID)
    if let protection = journal.protection {
      guard try store.protectedBranches().contains(protection),
        try protectionRoots(protection) == journal.roots
      else {
        throw WorktreeError.recoveryRequired("Branch protection changed.")
      }
    }
    guard !journal.force else { return }
    guard let baseOID = journal.baseOID, try isAncestor(journal.oid, of: baseOID) else {
      throw WorktreeError.invalidRequest("Branch is not merged into its recorded base.")
    }
    if let protection = journal.protection {
      guard journal.oid == protection.publishedOID, let history = protection.baseHistory,
        let log = try refHistory(journal.branch),
        String(decoding: log, as: UTF8.self).split(separator: "\n").contains(where: {
          $0.hasSuffix("\tcomputer-mcp worktree " + protection.worktreeID.uuidString.lowercased())
        })
      else { throw WorktreeError.recoveryRequired("Branch or base registration proof changed.") }
      try requireRefHistory(journal.base, history: history, expectedOID: baseOID)
      let reachable = try baseObjectClosure(baseOID)
      guard journal.releasedRoots.values.allSatisfy(reachable.contains),
        journal.retainedRoots.values.allSatisfy({ !reachable.contains($0) })
      else { throw WorktreeError.recoveryRequired("Recovery root release set changed.") }
    }
  }

  /// Compare original objects, not peeled commits: a tag naming an integrated
  /// commit is still an independent retention root. Git bounds this traversal.
  private func baseObjectClosure(_ oid: String?) throws -> Set<String> {
    guard let oid else { return [] }
    let output = try command(["rev-list", "--objects", "--no-object-names", oid]).output
    let objects = Set(
      String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init))
    guard !objects.isEmpty, objects.allSatisfy(identity.format.contains) else {
      throw WorktreeError.recoveryRequired("Invalid base object closure.")
    }
    return objects
  }

  private func requireDeletionOutcome(_ journal: WorktreeBranchDeletionJournal) throws {
    try requireBranchValue(journal.branch, oid: nil)
    try requireBranchValue(journal.base, oid: journal.baseOID)
    for ref in journal.releasedRoots.keys {
      guard try objectRevision(ref) == nil else {
        throw WorktreeError.recoveryRequired("Released recovery root survived deletion.")
      }
    }
    for (ref, oid) in journal.retainedRoots { try requireObjectRef(ref, oid: oid) }
  }

  private func finishBranchDeletion(
    _ journal: inout WorktreeBranchDeletionJournal, lock: RepositoryLock,
    authorize: (ProtectedWorktreeBranch?) throws -> Void
  ) throws -> WorktreeBranchDeletion {
    if journal.phase == .prepared {
      if try revision(journal.receipt) == journal.oid {
        try requireDirectRef(journal.receipt, oid: journal.oid)
        try requireDeletionOutcome(journal)
      } else {
        guard try revision(journal.receipt) == nil else {
          throw WorktreeError.recoveryRequired("Deletion receipt was replaced.")
        }
        let zero = String(repeating: "0", count: identity.format.hexCount)
        var input =
          "start\ndelete \(journal.branch) \(journal.oid)\nverify \(journal.base) \(journal.baseOID ?? zero)\n"
        for (ref, oid) in journal.releasedRoots.sorted(by: { $0.key < $1.key }) {
          input += "delete \(ref) \(oid)\n"
        }
        for (ref, oid) in journal.retainedRoots.sorted(by: { $0.key < $1.key }) {
          input += "verify \(ref) \(oid)\n"
        }
        input += "create \(journal.receipt) \(journal.oid)\nprepare\n"
        try git.transaction(
          input, at: URL(fileURLWithPath: identity.main.path),
          gitDirectory: URL(fileURLWithPath: identity.common.path),
          message: "computer-mcp branch deletion"
        ) {
          try lock.verify()
          try authorize(journal.protection)
          try requireDeletionPolicy(journal)
        }
      }
      try advanceDeletion(&journal, to: .committed)
    }
    if journal.phase == .committed {
      try requireDirectRef(journal.receipt, oid: journal.oid)
      try requireDeletionOutcome(journal)
      if let protection = journal.protection { try store.releaseProtection(protection) }
      try advanceDeletion(&journal, to: .released)
    }
    if journal.phase == .released {
      try requireDeletionOutcome(journal)
      if try revision(journal.receipt) != nil {
        try git.transaction(
          "start\ndelete \(journal.receipt) \(journal.oid)\nprepare\n",
          at: URL(fileURLWithPath: identity.main.path),
          gitDirectory: URL(fileURLWithPath: identity.common.path),
          message: "computer-mcp deletion receipt release"
        ) {
          try lock.verify()
          try authorize(journal.protection)
          try requireDirectRef(journal.receipt, oid: journal.oid)
        }
      }
      try advanceDeletion(&journal, to: .finished)
    }
    return .init(branch: journal.branch, oid: journal.oid, deleted: true)
  }

  private func deletionDirectory() throws -> WorktreeDirectory {
    try WorktreeDirectory(storage.journals).child("branch-deletions", create: true)
  }

  private func deletionBytes(_ journal: WorktreeBranchDeletionJournal) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(journal)
  }

  private func saveDeletion(_ journal: WorktreeBranchDeletionJournal, replacing previous: Data?)
    throws
  {
    try io.write(
      deletionBytes(journal), name: journal.operationID.uuidString.lowercased() + ".json",
      in: deletionDirectory(), replacing: previous)
  }

  private func advanceDeletion(
    _ journal: inout WorktreeBranchDeletionJournal, to phase: WorktreeBranchDeletionJournal.Phase
  ) throws {
    let old = try deletionBytes(journal)
    journal.phase = phase
    try saveDeletion(journal, replacing: old)
  }
}
