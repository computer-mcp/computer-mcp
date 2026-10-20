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
        try git.run(arguments + [worktree.path, base], at: root)
        try recordWorktreeIdentity(&journal)
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
          try worktreeGit.run(
            ["sparse-checkout", "set", "--no-cone", "--"] + patterns, at: worktree)
          try worktreeGit.run(["checkout"], at: worktree)
        }
        journal.files = try edit(request, journal: &journal, git: worktreeGit)
        try cancellation.check()
        guard
          try worktreeGit.run(
            ["--no-optional-locks", "diff", "--cached", "--quiet", "--"] + request.paths,
            at: worktree, accepting: [0, 1]
          ).exitCode == 0
        else {
          throw DeliveryFailure(
            reason: .gitFailed, detail: "Delivery target index entries have changed.")
        }
        try worktreeGit.run(["add", "--"] + request.paths, at: worktree)
        journal.staged = try Dictionary(
          uniqueKeysWithValues: request.paths.map { path in
            (
              path,
              try worktreeGit.run(
                ["--no-optional-locks", "ls-files", "--stage", "-z", "--", path], at: worktree
              ).stdout
            )
          })
        try io.write(journal, to: journals)
        try cancellation.check()
        try worktreeGit.run(["commit", "-m", request.message], at: worktree)
        guard let commit = try worktreeGit.revision("HEAD", at: worktree), commit != base else {
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
          try abortRebase(journal)
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
            (error as? DeliveryFailure)?.reason == .worktreeUnrecognized
            ? .worktreeUnrecognized : .cleanupFailed
          try? io.write(journal, to: journals)
          return (journal.result, nil)
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
      // No intervening Git command may separate this baseline check from the merge it guards.
      if try git.revision("HEAD", at: main) == validatedBase {
        let merge = try git.run(
          ["merge", "--ff-only", "--no-squash", "--no-edit", journal.commit!], at: main,
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
    guard let pinned = try verifiedWorktree(journal) else {
      throw DeliveryFailure(reason: .worktreeUnrecognized, detail: "Delivery worktree is missing.")
    }
    let worktree = URL(fileURLWithPath: journal.worktree)
    let original = journal.commit!
    var failure: DeliveryFailure?
    do {
      let result = try pinned.run(["rebase", base], at: worktree, accepting: [0, 1, 128])
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
    if rebaseDirectory(journal) != nil {
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
      ["--no-optional-locks", "diff", "--no-renames", "--name-only", "-z", base, journal.commit!],
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
      var created: Bool
      var ranges: [Range<Int>]
    }
    var expected: [String: EditedFile] = [:]
    for edit in request.edits {
      try cancellation.check()
      let url = try Self.checkedPath(edit.path, inside: worktree)
      switch edit.change {
      case .create(let content):
        guard !FileManager.default.fileExists(atPath: url.path) else {
          throw DeliveryFailure(reason: .fileExists, detail: "File already exists: \(edit.path)")
        }
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        expected[edit.path] = EditedFile(content: content, created: true, ranges: [])
      case .replace(let old, let new):
        guard FileManager.default.fileExists(atPath: url.path) else {
          throw DeliveryFailure(reason: .fileMissing, detail: "File does not exist: \(edit.path)")
        }
        guard let content = String(data: try Data(contentsOf: url), encoding: .utf8) else {
          throw DeliveryFailure(reason: .notText, detail: "File is not UTF-8 text: \(edit.path)")
        }
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
        let previous = expected[edit.path]
        var ranges = (previous?.ranges ?? []).map { previous -> Range<Int> in
          let lower =
            previous.lowerBound > start
            ? max(start, previous.lowerBound + newLines - oldLines) : previous.lowerBound
          let upper =
            previous.upperBound > start
            ? max(lower + 1, previous.upperBound + newLines - oldLines) : previous.upperBound
          return lower..<upper
        }
        ranges.append(start..<(start + newLines + 1))
        expected[edit.path] = EditedFile(
          content: content.replacingCharacters(in: range, with: new),
          created: previous?.created ?? false, ranges: ranges)
      }
      let written = Data(expected[edit.path]!.content.utf8)
      var changes = journal.changes ?? []
      if let index = changes.firstIndex(where: { $0.path == edit.path }) {
        changes[index].written = written
      } else {
        let index = try pinned.run(
          ["--no-optional-locks", "ls-files", "--stage", "-z", "--", edit.path], at: worktree
        ).stdout
        changes.append(
          .init(
            path: edit.path, original: try? Data(contentsOf: url), written: written, index: index))
      }
      journal.changes = changes
      try io.write(journal, to: journals)
      try written.write(to: url)
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
        file.created
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
}
