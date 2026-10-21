import ComputerMCPConfiguration
import Foundation

extension DeliveryRepository {
  func apply(_ request: DeliveryRequest) throws -> (DeliveryResult, DeliveryFailure?) {
    try withLock {
      try recover()
      let base = try preflight(request)
      let operationID = UUID().uuidString.lowercased()
      let worktree = try Self.checkedPath(scope.worktreeRoot + "/" + operationID, inside: root)
      var journal = DeliveryJournal(
        operationID: operationID, workspace: scope.workspace, scope: scope.id,
        repository: root.path, defaultBranch: scope.defaultBranch, branch: request.branch,
        worktree: worktree.path, base: base)
      do { try io.write(journal, to: journals) } catch {
        throw DeliveryFailure(reason: .journalFailed, detail: "Cannot start the delivery journal.")
      }
      var failure: DeliveryFailure?
      do {
        try cancellation.check()
        var arguments = ["worktree", "add", "-b", request.branch]
        if scope.sparse { arguments.append("--no-checkout") }
        _ = try Self.checkedPath(scope.worktreeRoot + "/" + operationID, inside: root)
        guard !FileManager.default.fileExists(atPath: worktree.path) else {
          throw DeliveryFailure(
            reason: .worktreeUnrecognized, detail: "Worktree path already exists: \(worktree.path)")
        }
        try git.run(arguments + [worktree.path, base], at: root)
        try recordCreation(&journal)
        guard let worktreeGit = try verifiedWorktree(journal) else {
          throw DeliveryFailure(
            reason: .worktreeUnrecognized, detail: "Delivery worktree is missing.")
        }
        if scope.sparse {
          // Anchored literal patterns select files, including glob metacharacters in their names.
          let patterns = request.paths.map {
            "/"
              + $0.reduce(into: "") { result, character in
                if "\\*?[]!#".contains(character) { result.append("\\") }
                result.append(character)
              }
          }
          guard try FileManager.default.contentsOfDirectory(atPath: worktree.path) == [".git"]
          else {
            throw DeliveryFailure(
              reason: .cleanupFailed,
              detail: "Worktree changed before sparse checkout: \(worktree.path)")
          }
          try requireWorktree(journal, at: base).run(
            ["sparse-checkout", "set", "--no-cone", "--"] + patterns, at: worktree)
          let checkoutGit = try requireWorktree(journal, at: base)
          guard try FileManager.default.contentsOfDirectory(atPath: worktree.path) == [".git"]
          else {
            throw DeliveryFailure(
              reason: .cleanupFailed, detail: "Worktree changed before checkout: \(worktree.path)")
          }
          try checkoutGit.run(["checkout", "--no-overwrite-ignore"], at: worktree)
        }
        journal.files = try edit(request, journal: &journal, git: worktreeGit)
        try cancellation.check()
        let stagingGit = try requireWorktree(journal, at: base)
        guard
          try stagingGit.run(
            [
              "--no-optional-locks", "diff", "--no-ext-diff", "--no-textconv", "--cached",
              "--quiet", "--",
            ]
              + request.paths,
            at: worktree, accepting: [0, 1]
          ).exitCode == 0
        else {
          throw DeliveryFailure(
            reason: .gitFailed, detail: "Delivery target index entries have changed.")
        }
        try stagingGit.run(["add", "--"] + request.paths, at: worktree)
        journal.staged = try stagedEntries(journal, git: stagingGit)
        try io.write(journal, to: journals)
        try cancellation.check()
        let committingGit = try requireWorktree(journal, at: base)
        _ = try stagedEntries(journal, git: committingGit)
        guard try committingGit.revision("HEAD", at: worktree) == base else {
          throw DeliveryFailure(reason: .gitFailed, detail: "Delivery worktree HEAD has changed.")
        }
        try committingGit.run(["commit", "-m", request.message], at: worktree)
        guard let commit = try committingGit.revision("HEAD", at: worktree), commit != base else {
          throw DeliveryFailure(reason: .gitFailed, detail: "Git did not create a delivery commit.")
        }
        journal.commit = commit
        journal.phase = .committed
        do { try io.write(journal, to: journals) } catch {
          journal.state = .committed
          journal.reason = .journalFailed
          // Do not attempt to land a commit whose durable record could not be updated.
          return (finish(&journal), nil)
        }
        try cancellation.check()
        if try verifyPaths(&journal, base: base, paths: request.paths) {
          if scope.mode == .commitOnly {
            journal.state = .committed
            journal.reason = .commitOnly
          } else {
            try land(&journal, paths: request.paths)
          }
        }
      } catch {
        failure =
          (error as? DeliveryFailure)
          ?? DeliveryFailure(
            reason: .gitFailed, detail: boundedDeliveryText(error.localizedDescription))
        // A hook, timeout or failed journal write can leave a commit despite a failed command.
        do {
          _ = try worktreeForCleanup(journal)
          if journal.commit == nil,
            let commit = try git.revision("refs/heads/\(request.branch)", at: root), commit != base
          {
            journal.commit = commit
          }
          journal.merged =
            try journal.commit.map {
              try git.revision("HEAD", at: main) == $0
            } ?? false
        } catch {
          journal.phase = .cleanupPending
          journal.state = .cleanupPending
          journal.reason =
            switch (error as? DeliveryFailure)?.reason {
            case .worktreeUnrecognized: .worktreeUnrecognized
            case .rebaseInProgress: .rebaseInProgress
            case .branchUnproven: .branchUnproven
            case .worktreeRegistrationRetained: .worktreeRegistrationRetained
            default: .cleanupFailed
            }
          journal.message = boundedDeliveryText(error.localizedDescription)
          try? io.write(journal, to: journals)
          return (retainedResult(journal), nil)
        }
        journal.state = journal.merged ? .merged : (journal.commit == nil ? .aborted : .committed)
        journal.reason = journal.merged ? nil : failure?.reason
      }
      let result = finish(&journal)
      return (result, result.reason == failure?.reason ? failure : nil)
    }
  }

  private func land(_ journal: inout DeliveryJournal, paths: [String]) throws {
    var validatedBase = journal.base
    journal.state = .committed
    journal.reason = .notFastForward
    for attempt in 0...1 {
      try cancellation.check()
      try io.beforeMergeCheck(journal)
      try requireMainBranch(scope.defaultBranch)
      try git.requireRegularOriginalHead(at: main)
      // No intervening Git command may separate this baseline check from the merge it guards.
      if try git.revision("HEAD", at: main) == validatedBase {
        // Git applies an existing merge autostash even when creation is disabled.
        let autostash = common.appendingPathComponent("MERGE_AUTOSTASH")
        do {
          _ = try FileManager.default.attributesOfItem(atPath: autostash.path)
          throw DeliveryFailure(
            reason: .gitFailed, detail: "Pending merge autostash retained: \(autostash.path)")
        } catch let error as CocoaError
          where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
        {}
        let merge = try git.run(
          [
            "merge", "--ff-only", "--no-squash", "--no-edit", "--no-overwrite-ignore",
            "--no-autostash",
            journal.commit!,
          ], at: main,
          accepting: [0, 1, 128])
        if try git.revision("HEAD", at: main) == journal.commit {
          journal.merged = true
          journal.state = .merged
          journal.reason = nil
          return
        }
        guard merge.exitCode != 0 else { return }
      }
      guard attempt == 0,
        let currentDefault = try git.revision("refs/heads/\(scope.defaultBranch)", at: root),
        currentDefault != validatedBase
      else { return }
      // A post-merge hook may have advanced HEAD after the delivery commit landed.
      guard try !git.isAncestor(journal.commit!, of: currentDefault, at: root) else { return }
      guard try rebase(&journal, onto: currentDefault, paths: paths) else { return }
      validatedBase = currentDefault
    }
  }

  private func rebase(_ journal: inout DeliveryJournal, onto base: String, paths: [String]) throws
    -> Bool
  {
    try cancellation.check()
    let worktree = URL(fileURLWithPath: journal.worktree)
    let original = journal.commit!
    guard rebaseDirectory(journal) == nil else {
      throw DeliveryFailure(reason: .cleanupFailed, detail: "An unowned rebase is in progress.")
    }
    journal.rebase = .init(original: original, onto: base)
    try io.write(journal, to: journals)
    var failure: DeliveryFailure?
    var invoked = false
    do {
      let pinned = try requireWorktree(journal, at: original)
      try requireVisibleIndex(journal, git: pinned)
      guard
        try pinned.run(
          [
            "--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all",
            "--ignored=matching",
          ], at: worktree
        ).stdout.isEmpty
      else {
        throw DeliveryFailure(
          reason: .cleanupFailed, detail: "Worktree changed before rebase: \(worktree.path)")
      }
      guard rebaseDirectory(journal) == nil,
        try pinned.revision("HEAD", at: worktree) == original
      else {
        throw DeliveryFailure(
          reason: .cleanupFailed, detail: "Delivery worktree changed before rebase.")
      }
      try pinned.requireRegularOriginalHead(at: worktree)
      invoked = true
      let result = try pinned.run(
        ["rebase", "--no-update-refs", "--no-autostash", "--no-rebase-merges", base], at: worktree,
        accepting: [0, 1, 128])
      if result.exitCode != 0 {
        failure = DeliveryFailure(
          reason: .gitFailed, detail: "Rebase command failed.",
          exitCode: result.exitCode, stderr: result.stderr)
      }
    } catch {
      failure =
        (error as? DeliveryFailure)
        ?? DeliveryFailure(
          reason: .gitFailed,
          detail: boundedDeliveryText(error.localizedDescription))
    }
    if !invoked, let failure { throw failure }
    if rebaseDirectory(journal) != nil {
      guard invoked else {
        throw DeliveryFailure(
          reason: .rebaseInProgress, detail: "In-progress rebase retained: \(journal.worktree)")
      }
      try abortRebase(journal)
      guard try git.revision("refs/heads/\(journal.branch)", at: root) == original else {
        throw DeliveryFailure(
          reason: .gitFailed, detail: "Rebase abort did not restore the saved commit.")
      }
      journal.reason = .rebaseConflict
      return false
    }
    // A runner can fail after Git has finished rewriting the branch. Its actual tip owns the outcome.
    guard let actual = try git.revision("refs/heads/\(journal.branch)", at: root) else {
      throw DeliveryFailure(reason: .gitFailed, detail: "Delivery branch disappeared after rebase.")
    }
    journal.commit = actual
    let valid = try verifyPaths(&journal, base: base, paths: paths)
    if valid, let failure { journal.reason = failure.reason }
    do { try io.write(journal, to: journals) } catch {
      journal.reason = .journalFailed
      return false
    }
    return valid && failure == nil
  }

  private func verifyPaths(_ journal: inout DeliveryJournal, base: String, paths: [String]) throws
    -> Bool
  {
    let changedPaths = try git.run(
      [
        "--no-optional-locks", "diff", "--no-ext-diff", "--no-textconv", "--no-renames",
        "--name-only",
        "-z", base, journal.commit!,
      ],
      at: root
    ).stdout.split(separator: "\0").map(String.init)
    guard Set(changedPaths) == Set(paths), changedPaths.allSatisfy({ scope.contains(path: $0) })
    else {
      journal.state = .committed
      journal.reason = .scopeChanged
      return false
    }
    return true
  }

  func edit(_ request: DeliveryRequest, journal: inout DeliveryJournal, git pinned: DeliveryGit)
    throws -> [DeliveryFile]
  {
    let worktree = URL(fileURLWithPath: journal.worktree)
    struct EditedFile {
      var content: String
      var original: Data?
      var index: String
      var ranges: [Range<Int>]
    }
    var expected: [String: EditedFile] = [:]
    for edit in request.edits {
      try cancellation.check()
      let url = try Self.checkedPath(edit.path, inside: worktree)
      switch edit.change {
      case .create(let content):
        guard expected[edit.path] == nil, !FileManager.default.fileExists(atPath: url.path) else {
          throw DeliveryFailure(reason: .fileExists, detail: "File already exists: \(edit.path)")
        }
        let index = try pinned.run(
          ["--no-optional-locks", "ls-files", "--stage", "-z", "--", edit.path], at: worktree
        ).stdout
        expected[edit.path] = EditedFile(content: content, original: nil, index: index, ranges: [])
      case .replace(let old, let new):
        var file: EditedFile
        if let previous = expected[edit.path] {
          file = previous
        } else {
          guard FileManager.default.fileExists(atPath: url.path) else {
            throw DeliveryFailure(reason: .fileMissing, detail: "File does not exist: \(edit.path)")
          }
          let original = try Data(contentsOf: url)
          guard let content = String(data: original, encoding: .utf8) else {
            throw DeliveryFailure(reason: .notText, detail: "File is not UTF-8 text: \(edit.path)")
          }
          let index = try pinned.run(
            ["--no-optional-locks", "ls-files", "--stage", "-z", "--", edit.path], at: worktree
          ).stdout
          file = EditedFile(content: content, original: original, index: index, ranges: [])
        }
        let content = file.content
        guard let range = content.range(of: old, options: .literal) else {
          throw DeliveryFailure(
            reason: .matchMissing, detail: "Replacement text was not found: \(edit.path)")
        }
        if content.range(
          of: old, options: .literal,
          range: content.index(after: range.lowerBound)..<content.endIndex) != nil
        {
          throw DeliveryFailure(
            reason: .matchAmbiguous, detail: "Replacement text occurs more than once: \(edit.path)")
        }
        let start = content[..<range.lowerBound].filter { $0 == "\n" }.count
        let oldLines = old.filter { $0 == "\n" }.count
        let newLines = new.filter { $0 == "\n" }.count
        var ranges = file.ranges.map { previous -> Range<Int> in
          let lower =
            previous.lowerBound > start
            ? max(start, previous.lowerBound + newLines - oldLines) : previous.lowerBound
          let upper =
            previous.upperBound > start
            ? max(lower + 1, previous.upperBound + newLines - oldLines) : previous.upperBound
          return lower..<upper
        }
        ranges.append(start..<(start + newLines + 1))
        file.content = content.replacingCharacters(in: range, with: new)
        file.ranges = ranges
        expected[edit.path] = file
      }
    }
    journal.changes = try request.paths.map { path in
      let file = expected[path]!
      let written = Data(file.content.utf8)
      return .init(
        path: path, original: file.original, written: written, index: file.index,
        originalDigest: try file.original.map { try pinned.blobID($0, at: worktree) },
        finalDigest: try pinned.blobID(written, at: worktree), writeState: .pending)
    }
    try io.write(journal, to: journals)
    for index in journal.changes!.indices {
      let change = journal.changes![index]
      try cancellation.check()
      _ = try requireWorktree(journal, at: journal.base)
      let url = try Self.checkedPath(change.path, inside: worktree)
      if change.original == nil {
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      }
      try io.writeFile(
        change, to: url,
        validate: {
          _ = try requireWorktree(journal, at: journal.base)
          _ = try Self.checkedPath(change.path, inside: worktree)
        },
        recordWrite: { state in
          var recorded = journal
          recorded.changes![index].writeState = state
          try io.write(recorded, to: journals)
          journal = recorded
        }
      )
    }
    return try request.paths.map { path in
      let url = try Self.checkedPath(path, inside: worktree)
      let file = expected[path]!
      guard try Data(contentsOf: url) == Data(file.content.utf8) else {
        throw DeliveryFailure(
          reason: .notText, detail: "File readback did not match the requested content: \(path)")
      }
      let lines = file.content.components(separatedBy: "\n")
      let ranges =
        file.original == nil
        ? [0..<min(20, lines.count)]
        : file.ranges.map {
          max(0, $0.lowerBound - 3)..<min(lines.count, $0.upperBound + 3)
        }
      var merged: [Range<Int>] = []
      for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
        if let last = merged.last, range.lowerBound <= last.upperBound {
          merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
        } else {
          merged.append(range)
        }
      }
      return DeliveryFile(
        path: path, snippets: merged.map { boundedDeliveryText(lines[$0].joined(separator: "\n")) })
    }
  }

  private func stagedEntries(_ journal: DeliveryJournal, git pinned: DeliveryGit) throws
    -> [String: String]
  {
    let changes = journal.changes ?? []
    let entries = try pinned.run(
      ["--no-optional-locks", "ls-files", "--stage", "-z", "--"] + changes.map(\.path),
      at: URL(fileURLWithPath: journal.worktree)
    ).stdout.split(separator: "\0")
    var staged: [String: String] = [:]
    for entry in entries {
      let fields = entry.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
      let metadata = fields[0].split(separator: " ")
      guard fields.count == 2, metadata.count == 3, metadata[2] == "0",
        let change = changes.first(where: { $0.path == fields[1] }),
        String(metadata[1]) == change.finalDigest, staged[change.path] == nil
      else {
        throw DeliveryFailure(
          reason: .gitFailed, detail: "Delivery target index blobs have changed.")
      }
      staged[change.path] = String(entry) + "\0"
    }
    guard staged.count == changes.count else {
      throw DeliveryFailure(
        reason: .gitFailed, detail: "Delivery target index entries are missing.")
    }
    return staged
  }
}
