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
        if scope.sparse {
          // Anchored literal patterns select files, including glob metacharacters in their names.
          let patterns = request.paths.map {
            "/"
              + $0.reduce(into: "") { result, character in
                if "\\*?[]!#".contains(character) { result.append("\\") }
                result.append(character)
              }
          }
          try git.run(["sparse-checkout", "set", "--no-cone", "--"] + patterns, at: worktree)
          try git.run(["checkout"], at: worktree)
        }
        journal.files = try edit(request, in: worktree)
        try cancellation.check()
        try git.run(["add", "--"] + request.paths, at: worktree)
        try cancellation.check()
        try git.run(["commit", "-m", request.message], at: worktree)
        guard let commit = try git.revision("HEAD", at: worktree), commit != base else {
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
        if scope.mode == .commitOnly {
          journal.state = .committed
          journal.reason = .commitOnly
        } else {
          try land(&journal, worktree: worktree)
        }
      } catch {
        failure =
          (error as? DeliveryFailure)
          ?? DeliveryFailure(
            reason: .gitFailed, detail: boundedDeliveryText(error.localizedDescription))
        // A hook, timeout or failed journal write can leave a commit despite a failed command.
        do {
          try abortRebase(at: worktree)
          if let commit = try git.revision("refs/heads/\(request.branch)", at: root), commit != base
          {
            journal.commit = commit
          }
          journal.merged =
            try journal.commit.map {
              try git.isAncestor($0, of: "refs/heads/\(scope.defaultBranch)", at: root)
            } ?? false
        } catch {
          journal.phase = .cleanupPending
          journal.state = .cleanupPending
          journal.reason = .cleanupFailed
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

  private func land(_ journal: inout DeliveryJournal, worktree: URL) throws {
    try cancellation.check()
    try requireMainBranch(scope.defaultBranch)
    let merge = try git.run(
      ["merge", "--ff-only", "refs/heads/\(journal.branch)"], at: main, accepting: [0, 1, 128])
    if merge.exitCode == 0 {
      journal.merged = true
      journal.state = .merged
      return
    }
    let currentDefault = try git.revision("refs/heads/\(scope.defaultBranch)", at: root)
    guard currentDefault != journal.base else {
      throw DeliveryFailure(
        reason: .gitFailed, detail: "Fast-forward merge failed.", exitCode: merge.exitCode,
        stderr: merge.stderr)
    }
    try cancellation.check()
    let original = journal.commit!
    let rebase = try git.run(
      ["rebase", "refs/heads/\(scope.defaultBranch)"], at: worktree, accepting: [0, 1, 128])
    if rebase.exitCode != 0 {
      try abortRebase(at: worktree)
      guard try git.revision("refs/heads/\(journal.branch)", at: root) == original else {
        throw DeliveryFailure(
          reason: .gitFailed, detail: "Rebase abort did not restore the saved commit.")
      }
      journal.state = .committed
      journal.reason = .rebaseConflict
      return
    }
    journal.commit = try git.revision("HEAD", at: worktree)
    do { try io.write(journal, to: journals) } catch {
      journal.state = .committed
      journal.reason = .journalFailed
      return
    }
    try cancellation.check()
    try requireMainBranch(scope.defaultBranch)
    let retry = try git.run(
      ["merge", "--ff-only", "refs/heads/\(journal.branch)"], at: main, accepting: [0, 1, 128])
    journal.merged = retry.exitCode == 0
    journal.state = journal.merged ? .merged : .committed
    journal.reason = journal.merged ? nil : .notFastForward
  }

  private func edit(_ request: DeliveryRequest, in worktree: URL) throws -> [DeliveryFile] {
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
      try Data(expected[edit.path]!.content.utf8).write(to: url)
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
