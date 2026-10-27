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
        guard var pending = try readMerge(projectID) else { return nil }
        if pending.phase == .finished {
          try cleanMergeStaging(pending)
          return nil
        }
        return try finishMerge(&pending, lock: lock, limits: limits, authorize: authorize)
      })
    {
      return recovered
    }
    let publication = try publish(projectID: projectID, limits: limits) { try authorize($0, []) }
    return try withLock(validateHead: false) { lock in
      guard let record = try store.records().first(where: { $0.projectID == projectID }),
        record.state == .active, let registration = record.worktree,
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
        version: 1, operationID: UUID(), repository: identity,
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

  private func finishMerge(
    _ journal: inout WorktreeMergeJournal, lock: RepositoryLock, limits: WorktreePromotionLimits,
    authorize: (DerivedProjectRecord, [URL]) throws -> Void
  ) throws -> WorktreeMergeResult {
    let root = try WorktreeDirectory(URL(fileURLWithPath: identity.main.path))
    let common = try WorktreeDirectory(URL(fileURLWithPath: identity.common.path))
    let destinations = journal.paths.map { root.url.appendingPathComponent($0) }
    try authorize(journal.record, destinations)
    try requireMergeHead(journal.base)
    let base = try revision(journal.base)
    guard base == journal.expectedBase || base == journal.target else {
      throw WorktreeError.recoveryRequired("Base branch has an unknown merge outcome.")
    }
    if journal.staging == nil, journal.phase == .captured {
      let stage = try mergeDirectory().child(
        journal.operationID.uuidString.lowercased(), create: true, exclusive: true)
      try io.write(mergeOwner(journal), name: "owner.json", in: stage, replacing: nil)
      let previous = try mergeBytes(journal)
      journal.staging = stage.identity
      try saveMerge(journal, replacing: previous)
    }
    let lease = try WorktreeIndexLease(directory: common, operationID: journal.operationID)
    var released = false
    defer { if !released { try? lease.release() } }
    func current(synchronize: Bool = false) throws -> WorktreeCheckoutSnapshot {
      guard let index = try io.read("index", in: common, limit: git.maxOutputBytes * 8) else {
        throw WorktreeError.recoveryRequired("Main index is missing.")
      }
      return try .capture(
        paths: journal.paths, root: root, index: index, limits: limits,
        synchronize: synchronize)
    }
    if journal.phase == .checkout, base == journal.expectedBase, try current() == journal.before {
      try advanceMerge(&journal, to: .prepared)
    }
    if [.ready, .published, .ledger].contains(journal.phase), base == journal.target {
      guard try current() == journal.after else {
        throw WorktreeError.recoveryRequired(
          "Merged checkout changed before reconciliation; retain it.")
      }
      if journal.expectedBase != journal.target {
        let receipt = try command(["reflog", "show", "-1", "--format=%H%x00%gs", journal.base])
          .output
        guard receipt == Data((journal.target + "\0" + mergeMessage(journal) + "\n").utf8) else {
          throw WorktreeError.recoveryRequired("Merge reference ownership cannot be proved.")
        }
      }
      if journal.phase == .ready { try advanceMerge(&journal, to: .published) }
    } else {
      guard base == journal.expectedBase, [.captured, .prepared, .ready].contains(journal.phase)
      else {
        throw WorktreeError.recoveryRequired(
          "Checkout may be incomplete; retain files and index for reconciliation.")
      }
      guard
        try store.records().first(where: { $0.projectID == journal.record.projectID })
          == journal.record
      else {
        throw DerivedProjectStoreError.revisionConflict
      }
      let stage = try mergeStaging(journal)
      let input =
        "start\nupdate HEAD \(journal.target) \(journal.expectedBase)\nverify \(journal.record.worktree!.branch) \(journal.target)\nprepare\n"
      try git.transaction(
        input, at: root.url, gitDirectory: common.url, dereference: true,
        message: mergeMessage(journal)
      ) {
        try lock.verify()
        try lease.verify()
        try requireMergeHead(journal.base)
        try requireDirectRef(journal.base, oid: journal.expectedBase)
        try requireDirectRef(journal.record.worktree!.branch, oid: journal.target)
        try authorize(journal.record, destinations)
        guard try mergePaths(journal.expectedBase, journal.target) == journal.paths,
          try command(
            ["merge-base", "--is-ancestor", journal.expectedBase, journal.target],
            accepting: [0, 1]
          ).exitCode == 0
        else {
          throw WorktreeError.recoveryRequired("Merge ancestry or destination set changed.")
        }
        if journal.phase == .ready {
          guard try current() == journal.after else {
            throw WorktreeError.recoveryRequired(
              "Checkout was edited after an interrupted reference update.")
          }
        } else {
          let before = try current()
          if let recorded = journal.before, recorded != before {
            throw WorktreeError.recoveryRequired("Checkout changed after merge preparation.")
          }
          try requireSafeCheckout(journal, snapshot: before)
          guard let index = try io.read("index", in: common, limit: git.maxOutputBytes * 8),
            WorktreeObjectSnapshot.digest(index) == before.index
          else {
            throw WorktreeError.busy("Main index changed before checkout.")
          }
          let priorIndex = try io.read("index", in: stage, limit: git.maxOutputBytes * 8)
          try io.write(index, name: "index", in: stage, replacing: priorIndex)
          let old = try mergeBytes(journal)
          journal.before = before
          journal.phase = .prepared
          try saveMerge(journal, replacing: old)
          _ = try checkout(journal, stage: stage, dryRun: true)
          guard try current() == before else {
            throw WorktreeError.busy("Checkout changed during preflight.")
          }
          try authorize(journal.record, destinations)
          try lease.verify()
          try lock.verify()
          try advanceMerge(&journal, to: .checkout)
          _ = try checkout(journal, stage: stage, dryRun: false)
          try lease.verify()
          let dirty = try checkoutPaths(
            git.run(
              ["diff-files", "--name-only", "-z", "--"],
              at: root.url, gitDirectory: common.url,
              index: stage.url.appendingPathComponent("index")
            ).output)
          guard Set(dirty).isDisjoint(with: journal.paths) else {
            throw WorktreeError.recoveryRequired("Checkout files changed during the transition.")
          }
          guard
            let updated = try io.read(
              "index", in: stage, limit: git.maxOutputBytes * 8, synchronize: true)
          else {
            throw WorktreeError.recoveryRequired("Checkout produced no index.")
          }
          try io.write(updated, name: "index", in: common, replacing: index)
          let checkoutPhase = try mergeBytes(journal)
          journal.after = try current(synchronize: true)
          journal.phase = .ready
          try saveMerge(journal, replacing: checkoutPhase)
        }
        try authorize(journal.record, destinations)
        try lock.verify()
        try lease.verify()
        guard
          try store.records().first(where: { $0.projectID == journal.record.projectID })
            == journal.record,
          try current() == journal.after
        else {
          throw WorktreeError.recoveryRequired(
            "Merge authority or checkout changed before reference commit.")
        }
      }
      try requireMergeHead(journal.base)
      try requireDirectRef(journal.base, oid: journal.target)
      try advanceMerge(&journal, to: .published)
    }
    try lock.verify()
    try lease.verify()
    try requireMergeHead(journal.base)
    try requireDirectRef(journal.base, oid: journal.target)
    if journal.phase == .published {
      var next = journal.record
      next.revision += 1
      next.worktree!.mergedOID = journal.target
      if try store.records().first(where: { $0.projectID == next.projectID }) != next {
        guard case .host(let worktreeID, _) = next.provenance else {
          throw DerivedProjectStoreError.invalidRecord
        }
        let registration = next.worktree!
        try store.commit(
          next, expecting: journal.record.revision,
          protecting: .init(
            repository: identity.common, branchID: registration.branchID,
            branch: registration.branch,
            base: registration.base, baseOID: registration.baseOID,
            publishedOID: registration.lastPublishedOID,
            worktreeID: worktreeID, mergedOID: journal.target))
      }
      try advanceMerge(&journal, to: .ledger)
    }
    try advanceMerge(&journal, to: .finished)
    try lease.release()
    released = true
    try cleanMergeStaging(journal)
    return .init(
      projectID: journal.record.projectID, operationID: journal.operationID, base: journal.base,
      oid: journal.target)
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

  private func cleanMergeStaging(_ journal: WorktreeMergeJournal) throws {
    guard let path = journal.staging?.path else { return }
    guard (try? FileManager.default.attributesOfItem(atPath: path)) != nil else { return }
    let stage = try mergeStaging(journal)
    try stage.verify()
    try FileManager.default.removeItem(at: stage.url)
    try mergeDirectory().synchronize()
  }
}
