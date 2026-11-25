import Foundation

package struct WorktreeMergeResult: Sendable {
  package let projectID: String
  package let operationID: UUID
  package let base: String
  package let oid: String
}

extension WorktreeRepository {
  /// The adapter must authorize every destination, including nested registered
  /// projects, against current permissions. An empty list still requires source authority.
  package func merge(
    projectID: String, limits: WorktreePromotionLimits = .init(),
    authorize: (DerivedProjectRecord, [URL]) throws -> Void
  ) throws -> WorktreeMergeResult {
    try limits.validate()
    if let recovered = try withLock(
      validateHead: false,
      { lock -> WorktreeMergeResult? in
        try recoverMerge(projectID, lock: lock, limits: limits, authorize: authorize)
      })
    {
      return recovered
    }
    let publication = try publish(projectID: projectID, limits: limits) { try authorize($0, []) }
    return try withLock(validateHead: false) { lock in
      guard let record = try store.records().first(where: { $0.projectID == projectID }),
        record.state == .active, record.revision < Int64.max - 1,
        let registration = record.worktree,
        registration.lastPublishedOID == publication.oid, registration.base != registration.branch,
        let expected = try revision(registration.base)
      else {
        throw WorktreeError.recoveryRequired(
          "Merge requires an active published branch and recorded base.")
      }
      try requireMergeHead(registration.base)
      try requireDirectRef(registration.base, oid: expected)
      try requireDirectRef(registration.branch, oid: publication.oid)
      guard
        try command(["merge-base", "--is-ancestor", expected, publication.oid], accepting: [0, 1])
          .exitCode == 0
      else {
        throw WorktreeError.invalidRequest(
          "The published branch cannot fast-forward the recorded base.")
      }
      let paths = try mergePaths(expected, publication.oid)
      try authorize(
        record, paths.map { URL(fileURLWithPath: identity.main.path).appendingPathComponent($0) })
      var journal = WorktreeMergeJournal(
        version: 2, operationID: UUID(), repository: identity,
        record: record, expectedBase: expected, target: publication.oid, paths: paths,
        phase: .captured)
      let previous = try readMerge(projectID).map(mergeBytes)
      try saveMerge(journal, replacing: previous)
      let stage = try mergeDirectory().child(
        journal.operationID.uuidString.lowercased(), create: true, exclusive: true)
      try io.write(mergeOwner(journal), name: "owner.json", in: stage, replacing: nil)
      let old = try mergeBytes(journal)
      journal.staging = stage.identity
      try saveMerge(journal, replacing: old)
      return try finishMerge(&journal, lock: lock, limits: limits, authorize: authorize)
    }
  }

  func recoverMerge(
    _ projectID: String, lock: RepositoryLock, limits: WorktreePromotionLimits,
    authorize: (DerivedProjectRecord, [URL]) throws -> Void
  ) throws -> WorktreeMergeResult? {
    guard var pending = try readMerge(projectID) else { return nil }
    // A candidate with no live source guards reached no checkout effect.
    if [.captured, .prepared].contains(pending.phase),
      pending.sourceGuards == nil || pending.sourceGuards?.cleaning == true
    {
      try authorize(pending.record, [])
      try advanceMerge(&pending, to: .abandoned)
    }
    if [.finished, .abandoned].contains(pending.phase) {
      try authorize(pending.record, [])
      try cleanMergeProtection(&pending, lock: lock)
      try cleanMergeStaging(pending)
      return nil
    }
    return try finishMerge(&pending, lock: lock, limits: limits, authorize: authorize)
  }

  private func requireMergeHead(_ base: String) throws {
    let common = try WorktreeDirectory(URL(fileURLWithPath: identity.common.path))
    guard
      try io.read("HEAD", in: common, limit: 2048) == Data(("ref: " + base + "\n").utf8),
      try command(["symbolic-ref", "--quiet", "ORIG_HEAD"], accepting: [0, 1]).exitCode == 1
    else {
      throw WorktreeError.recoveryRequired(
        "Main checkout must name the recorded base with regular pseudorefs.")
    }
    let entries = try common.entries(limit: 100_000)
    guard
      Set(entries).isDisjoint(with: [
        "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply",
        "sequencer",
      ])
    else {
      throw WorktreeError.busy("Main checkout has an unfinished Git operation.")
    }
  }

  private func mergePaths(_ old: String, _ new: String) throws -> [String] {
    try checkoutPaths(
      command(["diff-tree", "--no-commit-id", "--no-renames", "-r", "--name-only", "-z", old, new])
        .output)
  }

  private func checkoutPaths(_ data: Data) throws -> [String] {
    guard let text = String(data: data, encoding: .utf8) else {
      throw WorktreeError.unsupportedRepository("Checkout filenames must be valid UTF-8.")
    }
    let paths = Array(Set(text.split(separator: "\0").map(String.init))).sorted()
    for path in paths { try WorktreeCheckoutSnapshot.requirePath(path) }
    return paths
  }

  func finishMerge(
    _ journal: inout WorktreeMergeJournal, lock: RepositoryLock, limits: WorktreePromotionLimits,
    authorize: (DerivedProjectRecord, [URL]) throws -> Void
  ) throws -> WorktreeMergeResult {
    try synchronizeMerge(journal)
    let root = try WorktreeDirectory(URL(fileURLWithPath: identity.main.path))
    let common = try WorktreeDirectory(URL(fileURLWithPath: identity.common.path))
    let paths = journal.paths
    let destinations = paths.map { root.url.appendingPathComponent($0) }
    let managed = journal.record.worktree!.branch
    let branches = [journal.base, managed]
    try authorize(journal.record, destinations)
    try requireMergeHead(journal.base)
    if journal.staging == nil, journal.phase == .captured {
      let stage = try mergeDirectory().child(
        journal.operationID.uuidString.lowercased(), create: true, exclusive: true)
      try io.write(mergeOwner(journal), name: "owner.json", in: stage, replacing: nil)
      try updateMerge(&journal) { $0.staging = stage.identity }
    }
    func current(synchronize: Bool = false) throws -> WorktreeCheckoutSnapshot {
      guard let index = try io.read("index", in: common, limit: git.maxOutputBytes * 8) else {
        throw WorktreeError.recoveryRequired("Main index is missing.")
      }
      return try .capture(
        paths: paths, root: root, index: index, limits: limits, synchronize: synchronize)
    }
    if [.captured, .prepared].contains(journal.phase), journal.sourceGuards == nil,
      journal.indexLease == nil
    {
      let before = try current()
      try requireSafeCheckout(journal, snapshot: before)
      guard let index = try io.read("index", in: common, limit: git.maxOutputBytes * 8),
        WorktreeObjectSnapshot.digest(index) == before.index
      else { throw WorktreeError.busy("Main index changed during merge preparation.") }
      let stage = try mergeStaging(journal)
      let prior = try io.read("index", in: stage, limit: git.maxOutputBytes * 8)
      try io.write(index, name: "index", in: stage, replacing: prior)
      try updateMerge(&journal) {
        $0.before = before
        $0.phase = .prepared
      }
    }
    let lease = try WorktreeIndexLease(
      directory: common, operationID: journal.operationID, reopening: journal.indexLease)
    if journal.indexLease == nil {
      let proof = try lease.proof()
      try updateMerge(&journal) { $0.indexLease = proof }
    }
    let metadata = try sourceMetadata()
    var ownership =
      try journal.sourceGuards
      ?? .init(
        operationID: journal.operationID, common: common.identity, branches: branches,
        guardingHead: true)
    let guards: WorktreeSourceGuards
    do {
      guards = try WorktreeSourceGuards.acquire(
        &ownership, metadata: metadata, repositoryLock: lock, branches: branches,
        guardingHead: true,
        persist: { ownership in try updateMerge(&journal) { $0.sourceGuards = ownership } })
    } catch {
      if [.captured, .prepared].contains(journal.phase) {
        try retireMergeIndex(&journal, common: common, held: lease)
      }
      throw error
    }
    func verifyAuthority(_ state: WorktreeMergeJournal) throws {
      try Task.checkCancellation()
      try guards.verify()
      try lease.verify()
      try requireMergeHead(state.base)
      try authorize(state.record, destinations)
      let existing = try store.records().first { $0.projectID == state.record.projectID }
      guard
        existing == state.record
          || ([.published, .ledger].contains(state.phase) && existing == mergedRecord(state))
      else { throw DerivedProjectStoreError.revisionConflict }
    }

    do {
      try verifyAuthority(journal)
      let base = try metadata.direct(journal.base).oid
      guard base == journal.expectedBase || base == journal.target,
        try metadata.direct(managed).oid == journal.target
      else { throw sourceMetadataChanged() }
      if journal.phase == .checkout, base == journal.expectedBase, try current() == journal.before {
        try advanceMerge(&journal, to: .prepared)
      }
      if [.captured, .prepared].contains(journal.phase) {
        guard base == journal.expectedBase,
          try mergePaths(journal.expectedBase, journal.target) == journal.paths,
          try command(
            ["merge-base", "--is-ancestor", journal.expectedBase, journal.target],
            accepting: [0, 1]
          ).exitCode == 0
        else {
          throw WorktreeError.recoveryRequired("Merge ancestry or destination set changed.")
        }
        if journal.sourceCommit == nil {
          let write = try mergeSourceCommit(journal, guards: guards)
          try updateMerge(&journal) { $0.sourceCommit = write }
        }
        let before = try current()
        if let recorded = journal.before, recorded != before {
          throw WorktreeError.recoveryRequired("Checkout changed after merge preparation.")
        }
        try requireSafeCheckout(journal, snapshot: before)
        guard let index = try io.read("index", in: common, limit: git.maxOutputBytes * 8),
          WorktreeObjectSnapshot.digest(index) == before.index
        else { throw WorktreeError.busy("Main index changed before checkout.") }
        let stage = try mergeStaging(journal)
        let priorIndex = try io.read("index", in: stage, limit: git.maxOutputBytes * 8)
        if priorIndex != index {
          try io.write(index, name: "index", in: stage, replacing: priorIndex)
        }
        if journal.before == nil || journal.phase != .prepared {
          try updateMerge(&journal) {
            $0.before = before
            $0.phase = .prepared
          }
        }
        _ = try checkout(journal, stage: stage, dryRun: true)
        guard try current() == before else {
          throw WorktreeError.busy("Checkout changed during preflight.")
        }
        try verifyAuthority(journal)
        try advanceMerge(&journal, to: .checkout)
        _ = try checkout(journal, stage: stage, dryRun: false)
        // Finish fingerprinting the already admitted checkout before checking
        // authority to commit the ref. Recovery needs its exact after-image.
        try guards.verify()
        try lease.verify()
        let dirty = try checkoutPaths(
          git.run(
            ["diff-files", "--name-only", "-z", "--"],
            at: root.url, gitDirectory: common.url,
            index: stage.url.appendingPathComponent("index")
          ).output)
        guard Set(dirty).isDisjoint(with: paths) else {
          throw WorktreeError.recoveryRequired("Checkout files changed during the transition.")
        }
        guard
          let updated = try io.read(
            "index", in: stage, limit: git.maxOutputBytes * 8, synchronize: true)
        else { throw WorktreeError.recoveryRequired("Checkout produced no index.") }
        try guards.verify()
        try lease.verify()
        try io.write(updated, name: "index", in: common, replacing: index)
        let after = try current(synchronize: true)
        try updateMerge(&journal) {
          $0.after = after
          $0.phase = .ready
        }
      }
      guard [.ready, .published, .ledger].contains(journal.phase), try current() == journal.after
      else {
        throw WorktreeError.recoveryRequired("Checkout may be incomplete; retain files and index.")
      }
      if journal.sourceCommit == nil && base == journal.expectedBase && journal.phase == .ready {
        let write = try mergeSourceCommit(journal, guards: guards)
        try updateMerge(&journal) { $0.sourceCommit = write }
      }
      if var write = journal.sourceCommit {
        try write.completeSource(
          guards: guards,
          revalidate: {
            try verifyAuthority(journal)
            guard try current(synchronize: true) == journal.after else {
              throw WorktreeError.recoveryRequired("Checkout changed before reference commit.")
            }
          },
          persist: { next in try updateMerge(&journal) { $0.sourceCommit = next } })
      } else {
        guard journal.version == 1 else { throw sourceMetadataChanged() }
        try synchronizeLegacyMerge(journal, guards: guards)
      }
      try verifyAuthority(journal)
      if journal.phase == .ready { try advanceMerge(&journal, to: .published) }
      if journal.phase == .published {
        let next = mergedRecord(journal)
        if try store.records().first(where: { $0.projectID == next.projectID }) != next {
          let registration = next.worktree!
          try store.commit(
            next, expecting: journal.record.revision,
            protecting: .init(
              repository: identity.common, branchID: registration.branchID,
              branch: registration.branch, base: registration.base, baseOID: registration.baseOID,
              publishedOID: registration.lastPublishedOID, worktreeID: next.provenance.worktreeID,
              mergedOID: journal.target, baseHistory: registration.baseHistory))
        }
        try advanceMerge(&journal, to: .ledger)
      }
      try advanceMerge(&journal, to: .finished)
    } catch {
      if [.captured, .prepared].contains(journal.phase) {
        try cleanMergeProtection(&journal, lock: lock, held: guards, lease: lease)
      }
      throw error
    }
    try cleanMergeProtection(&journal, lock: lock, held: guards, lease: lease)
    try cleanMergeStaging(journal)
    return .init(
      projectID: journal.record.projectID, operationID: journal.operationID, base: journal.base,
      oid: journal.target)
  }

  private func updateMerge(
    _ journal: inout WorktreeMergeJournal, _ change: (inout WorktreeMergeJournal) -> Void
  ) throws {
    let previous = try mergeBytes(journal)
    change(&journal)
    try saveMerge(journal, replacing: previous)
  }

  private func mergedRecord(_ journal: WorktreeMergeJournal) -> DerivedProjectRecord {
    var record = journal.record
    record.revision += 1
    record.worktree!.mergedOID = journal.target
    return record
  }

  private func mergeSourceCommit(
    _ journal: WorktreeMergeJournal, guards: WorktreeSourceGuards
  ) throws -> WorktreeSourceMerge {
    try .init(
      base: journal.base, managed: journal.record.worktree!.branch, expected: journal.expectedBase,
      target: journal.target, message: mergeMessage(journal),
      committer: journal.expectedBase == journal.target ? nil : sourceMergeCommitter(),
      guards: guards)
  }

  /// A version-one receipt owns only the old acknowledged single-ref result.
  private func synchronizeLegacyMerge(
    _ journal: WorktreeMergeJournal, guards: WorktreeSourceGuards
  ) throws {
    let metadata = guards.metadata
    let current = try metadata.direct(journal.base)
    guard current.oid == journal.target else { throw sourceMetadataChanged() }
    let path = current.loose == nil ? "packed-refs" : journal.base
    guard let file = current.loose ?? current.packed, let location = try metadata.location(path)
    else { throw sourceMetadataChanged() }
    if journal.expectedBase != journal.target {
      for path in ["logs/HEAD", "logs/" + journal.base] {
        guard let log = try metadata.read(path), let location = try metadata.location(path),
          log.contents.last == 10,
          let last = log.contents.dropLast().split(separator: 10, omittingEmptySubsequences: false)
            .last,
          let entry = WorktreeSourceReflogEntry(last), entry.old == journal.expectedBase,
          entry.new == journal.target, entry.message == Data(mergeMessage(journal).utf8)
        else { throw sourceMetadataChanged() }
        try log.synchronize(at: location, using: io)
      }
    }
    try file.synchronize(at: location, using: io)
    try guards.verify()
  }

  private func cleanMergeProtection(
    _ journal: inout WorktreeMergeJournal, lock: RepositoryLock,
    held: WorktreeSourceGuards? = nil, lease: WorktreeIndexLease? = nil
  ) throws {
    try synchronizeMerge(journal)
    let common = try WorktreeDirectory(URL(fileURLWithPath: identity.common.path))
    let branches = [journal.base, journal.record.worktree!.branch]
    if var ownership = journal.sourceGuards {
      let metadata = try held?.metadata ?? sourceMetadata()
      if ownership.cleaning {
        try WorktreeSourceGuards.finishCleanup(
          ownership, metadata: metadata, repositoryLock: lock, branches: branches,
          guardingHead: true)
      } else {
        let guards =
          try held
          ?? WorktreeSourceGuards.acquire(
            &ownership, metadata: metadata, repositoryLock: lock, branches: branches,
            guardingHead: true,
            persist: { value in try updateMerge(&journal) { $0.sourceGuards = value } })
        try guards.release(
          &ownership, branches: branches, guardingHead: true,
          persist: { value in try updateMerge(&journal) { $0.sourceGuards = value } })
      }
      try updateMerge(&journal) { $0.sourceGuards = nil }
    }
    try retireMergeIndex(&journal, common: common, held: lease)
  }

  private func retireMergeIndex(
    _ journal: inout WorktreeMergeJournal, common: WorktreeDirectory, held: WorktreeIndexLease?
  ) throws {
    guard let proof = journal.indexLease else { return }
    if try common.hasEntry("index.lock") {
      let lease =
        try held
        ?? WorktreeIndexLease(
          directory: common, operationID: journal.operationID, reopening: proof)
      guard try lease.proof() == proof else { throw sourceMetadataChanged() }
      try updateMerge(&journal) { $0.indexReleasing = true }
      try lease.release()
    } else {
      guard journal.indexReleasing == true else { throw sourceMetadataChanged() }
      try io.beforeDirectorySync()
      try common.synchronize()
    }
    try updateMerge(&journal) {
      $0.indexLease = nil
      $0.indexReleasing = nil
    }
  }

  private func checkout(_ journal: WorktreeMergeJournal, stage: WorktreeDirectory, dryRun: Bool)
    throws -> WorktreeGitResult
  {
    try git.run(
      ["read-tree", "--no-sparse-checkout", "--no-recurse-submodules", "-m", "-u"]
        + (dryRun ? ["-n"] : []) + [journal.expectedBase, journal.target],
      at: URL(fileURLWithPath: identity.main.path),
      gitDirectory: URL(fileURLWithPath: identity.common.path),
      index: stage.url.appendingPathComponent("index"))
  }

  private func requireSafeCheckout(
    _ journal: WorktreeMergeJournal, snapshot: WorktreeCheckoutSnapshot
  ) throws {
    // Configured attributes are read as data for refusal, never as executable authority.
    let attributes = try command(
      ["config", "--local", "--get", "core.attributesFile"], accepting: [0, 1]
    ).output
    let path = String(decoding: attributes, as: UTF8.self).trimmingCharacters(in: .newlines)
    try HostGitCheckout.requireNoFilters(revisions: [journal.expectedBase, journal.target]) {
      args, input in
      try command((path.isEmpty ? [] : ["-c", "core.attributesFile=" + path]) + args, input: input)
        .output
    }
    let flags = try command(["ls-files", "-v", "-z"]).output.split(separator: 0)
    guard flags.allSatisfy({ $0.first == 72 }) else {
      throw WorktreeError.busy("Main index contains unmerged, sparse or assumed-unchanged entries.")
    }
    func overlaps(_ path: String) -> Bool {
      journal.paths.contains { $0 == path || $0.hasPrefix(path + "/") || path.hasPrefix($0 + "/") }
    }
    for args in [
      ["diff-index", "--cached", "--name-only", "-z", journal.expectedBase, "--"],
      ["diff-files", "--name-only", "-z", "--"],
    ] {
      let dirty = try checkoutPaths(command(args).output)
      guard !dirty.contains(where: overlaps) else {
        throw WorktreeError.busy("Merge would overwrite local tracked or staged changes.")
      }
    }
    let tracked = Set(
      try checkoutPaths(command(["ls-tree", "-rz", "--name-only", journal.expectedBase]).output))
    for (path, node) in snapshot.files
    where overlaps(path) && ["file", "symlink"].contains(node.kind) {
      guard tracked.contains(path) else {
        throw WorktreeError.busy("Merge would overwrite untracked or ignored content.")
      }
    }
  }

  private func mergeMessage(_ journal: WorktreeMergeJournal) -> String {
    "computer-mcp merge " + journal.operationID.uuidString.lowercased()
  }

  func cleanMergeStaging(_ journal: WorktreeMergeJournal) throws {
    guard let path = journal.staging?.path else { return }
    guard (try? FileManager.default.attributesOfItem(atPath: path)) != nil else { return }
    let stage = try mergeStaging(journal)
    try stage.verify()
    try FileManager.default.removeItem(at: stage.url)
    try mergeDirectory().synchronize()
  }
}
