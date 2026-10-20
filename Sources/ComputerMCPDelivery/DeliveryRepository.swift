import ComputerMCPConfiguration
import ComputerMCPPlatformPOSIX
import Foundation

internal final class DeliveryCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  func cancel() { lock.withLock { value = true } }
  var isCancelled: Bool { lock.withLock { value } }
  func check() throws {
    if isCancelled {
      throw DeliveryFailure(reason: .interrupted, detail: "Delivery was interrupted.")
    }
  }
}

internal struct DeliveryRepository: Sendable {
  let scope: DeliveryScope
  let git: DeliveryGit
  let root: URL
  let main: URL
  let common: URL
  let io: DeliveryIO
  let cancellation: DeliveryCancellation
  var journals: URL { common.appendingPathComponent("computer-mcp/delivery", isDirectory: true) }

  init(
    scope: DeliveryScope, workspace: URL, git: DeliveryGit, io: DeliveryIO = .init(),
    cancellation: DeliveryCancellation = .init()
  ) throws {
    self.scope = scope
    self.git = git
    self.io = io
    self.cancellation = cancellation
    let workspace = workspace.standardizedFileURL.resolvingSymlinksInPath()
    let repository = try Self.checkedPath(scope.repository, inside: workspace, allowRoot: true)
    let top = try git.run(["--no-optional-locks", "rev-parse", "--show-toplevel"], at: repository)
      .stdout
      .trimmingCharacters(in: .newlines)
    root = URL(fileURLWithPath: top).standardizedFileURL.resolvingSymlinksInPath()
    guard root.path == repository.path else {
      throw DeliveryFailure(
        reason: .pathInvalid, detail: "repository must identify a repository root.")
    }
    let commonPath = try git.run(
      ["--no-optional-locks", "rev-parse", "--git-common-dir"], at: root
    ).stdout
      .trimmingCharacters(in: .newlines)
    common =
      (commonPath.hasPrefix("/")
      ? URL(fileURLWithPath: commonPath) : root.appendingPathComponent(commonPath))
      .standardizedFileURL.resolvingSymlinksInPath()
    let worktrees = try git.run(
      ["--no-optional-locks", "worktree", "list", "--porcelain", "-z"], at: root
    ).stdout
    guard let entry = worktrees.split(separator: "\0").first, entry.hasPrefix("worktree ") else {
      throw DeliveryFailure(reason: .gitFailed, detail: "Cannot locate the main checkout.")
    }
    main = URL(fileURLWithPath: String(entry.dropFirst(9))).standardizedFileURL
      .resolvingSymlinksInPath()
  }

  func withLock<T>(_ action: () throws -> T) throws -> T {
    let directory = common.appendingPathComponent("computer-mcp", isDirectory: true)
    try io.prepareDirectory(directory)
    let deadline = ContinuousClock.now.advanced(by: .seconds(60))
    while true {
      try cancellation.check()
      do {
        let lock = try FileLock(
          path: directory.appendingPathComponent("delivery.lock").path, mode: .exclusive)
        defer { lock.release() }
        return try action()
      } catch FileLockError.held {
        guard ContinuousClock.now < deadline else {
          throw DeliveryFailure(
            reason: .busy, detail: "Repository delivery lock timed out after 60 seconds.")
        }
        Thread.sleep(forTimeInterval: 0.025)
      }
    }
  }

  func preflight(_ request: DeliveryRequest) throws -> String {
    try cancellation.check()
    guard
      try git.run(
        ["--no-optional-locks", "interpret-trailers", "--parse"], at: root,
        input: Data(request.message.utf8)
      ).stdout.isEmpty
    else {
      throw DeliveryFailure(reason: .messageInvalid, detail: "Git trailers are not allowed.")
    }
    for path in request.paths {
      guard scope.contains(path: path) else {
        throw DeliveryFailure(
          reason: .pathOutsideScope, detail: "Path is outside the delivery scope: \(path)")
      }
      _ = try Self.checkedPath(path, inside: root)
      _ = try Self.checkedPath(path, inside: main)
    }
    _ = try Self.checkedPath(scope.worktreeRoot, inside: root)
    guard
      try git.run(
        ["--no-optional-locks", "check-ignore", "-q", "--", scope.worktreeRoot + "/"], at: root,
        accepting: [0, 1]
      ).exitCode == 0
    else {
      throw DeliveryFailure(
        reason: .worktreeRootNotIgnored, detail: "The repository must ignore worktree_root.")
    }
    if scope.mode == .land { try requireMainBranch(scope.defaultBranch) }
    let status = try git.run(
      [
        "--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all",
        "--ignored=matching", "--",
      ]
        + request.paths, at: main)
    guard status.stdout.isEmpty else {
      throw DeliveryFailure(
        reason: .mainCheckoutDirty,
        detail: "A target file has uncommitted changes in the main checkout.")
    }
    guard try git.revision("refs/heads/\(request.branch)", at: root) == nil else {
      throw DeliveryFailure(
        reason: .branchExists, detail: "Branch already exists: \(request.branch)")
    }
    guard let base = try git.revision("refs/heads/\(scope.defaultBranch)", at: root) else {
      throw DeliveryFailure(reason: .gitFailed, detail: "The default branch does not exist.")
    }
    return base
  }

  func requireMainBranch(_ branch: String) throws {
    let current = try git.run(
      ["--no-optional-locks", "symbolic-ref", "--quiet", "HEAD"], at: main, accepting: [0, 1]
    )
    .stdout.trimmingCharacters(in: .newlines)
    guard current == "refs/heads/\(branch)" else {
      throw DeliveryFailure(
        reason: .mainCheckoutBranch, detail: "The main checkout must be on \(branch).")
    }
  }

  /// All path components, including the final component and dangling links, are inspected.
  static func checkedPath(_ path: String, inside root: URL, allowRoot: Bool = false) throws -> URL {
    guard let normalized = DeliveryScope.normalizedPath(path, allowRoot: allowRoot) else {
      throw DeliveryFailure(
        reason: .pathInvalid, detail: "Invalid relative repository path: \(path)")
    }
    var target = root
    for component in normalized.split(separator: "/") where component != "." {
      target.appendPathComponent(String(component))
      do {
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
          throw DeliveryFailure(
            reason: .pathInvalid, detail: "Delivery paths cannot traverse symbolic links: \(path)")
        }
      } catch let error as DeliveryFailure { throw error } catch let error as CocoaError
        where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
      {}
    }
    let resolved = target.resolvingSymlinksInPath().standardizedFileURL.path
    guard resolved == root.path || resolved.hasPrefix(root.path + "/") else {
      throw DeliveryFailure(reason: .pathInvalid, detail: "Path escapes the repository: \(path)")
    }
    return target
  }

  /// Reconciles every unfinished operation in the shared repository while the caller holds its lock.
  func recover() throws {
    guard FileManager.default.fileExists(atPath: journals.path) else { return }
    for url in try FileManager.default.contentsOfDirectory(
      at: journals, includingPropertiesForKeys: nil
    )
    .filter({ $0.pathExtension == "json" }).sorted(by: { $0.path < $1.path }) {
      try cancellation.check()
      var journal = try JSONDecoder().decode(DeliveryJournal.self, from: Data(contentsOf: url))
      guard journal.schemaVersion == 1,
        journal.operationID == url.deletingPathExtension().lastPathComponent,
        UUID(uuidString: journal.operationID) != nil, journal.repository.hasPrefix("/"),
        journal.branch.range(
          of:
            "^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)/[a-z0-9]+(-[a-z0-9]+)*$",
          options: .regularExpression) != nil,
        journal.worktree.hasPrefix(journal.repository + "/"),
        journal.worktree.hasSuffix("/" + journal.operationID)
      else {
        throw DeliveryFailure(
          reason: .journalFailed, detail: "Invalid delivery journal: \(url.lastPathComponent)")
      }
      if journal.phase == .finished { continue }
      let recordedRoot = URL(fileURLWithPath: journal.repository).standardizedFileURL
        .resolvingSymlinksInPath()
      if recordedRoot.path != root.path {
        let recordedCommon = try git.run(
          ["--no-optional-locks", "rev-parse", "--git-common-dir"], at: recordedRoot
        ).stdout
          .trimmingCharacters(in: .newlines)
        let recordedCommonURL =
          (recordedCommon.hasPrefix("/")
          ? URL(fileURLWithPath: recordedCommon)
          : recordedRoot.appendingPathComponent(recordedCommon))
          .standardizedFileURL.resolvingSymlinksInPath()
        guard recordedCommonURL.path == common.path else {
          throw DeliveryFailure(
            reason: .journalFailed, detail: "Journal belongs to a different repository.")
        }
      }
      let relativeWorktree = String(journal.worktree.dropFirst(journal.repository.count + 1))
      _ = try Self.checkedPath(relativeWorktree, inside: recordedRoot)
      do { try abortRebase(journal) } catch {
        journal.phase = .cleanupPending
        journal.state = .cleanupPending
        journal.reason =
          (error as? DeliveryFailure)?.reason == .worktreeUnrecognized
          ? .worktreeUnrecognized : .cleanupFailed
        try io.write(journal, to: journals)
        continue
      }
      let branchCommit = try git.revision("refs/heads/\(journal.branch)", at: root)
      if let branchCommit, branchCommit != journal.base { journal.commit = branchCommit }
      var defaultTip: String?
      if let commit = journal.commit {
        defaultTip = try git.revision("refs/heads/\(journal.defaultBranch)", at: root)
        journal.merged =
          try defaultTip.map { try git.isAncestor(commit, of: $0, at: root) } ?? false
        journal.state = journal.merged ? .merged : .committed
        journal.reason = journal.merged ? nil : .interrupted
      } else {
        journal.state = .aborted
        journal.reason = .interrupted
      }
      _ = finish(&journal, verifiedDefault: defaultTip)
    }
  }

  private func hasWorktreeRegistration(_ worktree: URL) throws -> Bool {
    // Resolve existing ancestors so missing directories retain the repository's canonical aliases.
    func resolvedPath(_ url: URL) -> String {
      var existing = url.standardizedFileURL
      var missing: [String] = []
      while !FileManager.default.fileExists(atPath: existing.path) {
        missing.append(existing.lastPathComponent)
        existing.deleteLastPathComponent()
      }
      let resolved = missing.reversed().reduce(existing.resolvingSymlinksInPath()) {
        $0.appendingPathComponent($1, isDirectory: true)
      }
      return resolved.path
    }
    let listing = try git.run(
      ["--no-optional-locks", "worktree", "list", "--porcelain", "-z"], at: root
    ).stdout.split(separator: "\0")
    let path = resolvedPath(worktree)
    return listing.contains(where: { entry in
      guard entry.hasPrefix("worktree ") else { return false }
      return resolvedPath(URL(fileURLWithPath: String(entry.dropFirst(9)))) == path
    })
  }

  func recordWorktreeIdentity(_ journal: inout DeliveryJournal) throws {
    let worktree = URL(fileURLWithPath: journal.worktree)
    let directory = try worktreeDirectory(at: worktree)
    let gitdir = try String(contentsOf: directory.appendingPathComponent("gitdir"), encoding: .utf8)
    journal.worktreeIdentity = .init(directory: directory.path, gitdir: gitdir)
    _ = try verifiedWorktree(journal)
    try io.write(journal, to: journals)
  }

  private func worktreeDirectory(at worktree: URL) throws -> URL {
    let gitFile = worktree.appendingPathComponent(".git")
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: gitFile.path),
      attributes[.type] as? FileAttributeType == .typeRegular,
      let marker = try? String(contentsOf: gitFile, encoding: .utf8).trimmingCharacters(
        in: .newlines),
      marker.hasPrefix("gitdir: ")
    else { throw unrecognizedWorktree(worktree) }
    let path = String(marker.dropFirst(8))
    let directory =
      (path.hasPrefix("/")
      ? URL(fileURLWithPath: path)
      : worktree.appendingPathComponent(path)).standardizedFileURL.resolvingSymlinksInPath()
    guard
      directory.deletingLastPathComponent().path
        == common.appendingPathComponent("worktrees").path
    else { throw unrecognizedWorktree(worktree) }
    return directory
  }

  private func unrecognizedWorktree(_ worktree: URL) -> DeliveryFailure {
    DeliveryFailure(
      reason: .worktreeUnrecognized,
      detail: "Unrecognized worktree retained: \(worktree.path)")
  }

  /// No Git process is launched in this path until its recorded registration is verified.
  func verifiedWorktree(_ journal: DeliveryJournal) throws -> DeliveryGit? {
    let worktree = URL(fileURLWithPath: journal.worktree)
    guard FileManager.default.fileExists(atPath: worktree.path) else {
      try pruneWorktreeRegistration(at: worktree)
      return nil
    }
    do {
      guard try hasWorktreeRegistration(worktree), let identity = journal.worktreeIdentity else {
        throw unrecognizedWorktree(worktree)
      }
      let directory = try worktreeDirectory(at: worktree)
      guard directory.path == identity.directory,
        let backlink = try? String(
          contentsOf: directory.appendingPathComponent("gitdir"), encoding: .utf8),
        backlink == identity.gitdir,
        let commonPath = try? String(
          contentsOf: directory.appendingPathComponent("commondir"), encoding: .utf8
        )
        .trimmingCharacters(in: .newlines)
      else { throw unrecognizedWorktree(worktree) }
      let backlinkPath = backlink.trimmingCharacters(in: .newlines)
      let backlinkURL =
        (backlinkPath.hasPrefix("/")
        ? URL(fileURLWithPath: backlinkPath)
        : directory.appendingPathComponent(backlinkPath)).standardizedFileURL
        .resolvingSymlinksInPath()
      let commonURL =
        (commonPath.hasPrefix("/")
        ? URL(fileURLWithPath: commonPath)
        : directory.appendingPathComponent(commonPath)).standardizedFileURL
        .resolvingSymlinksInPath()
      guard backlinkURL.path == worktree.appendingPathComponent(".git").path,
        commonURL.path == common.path
      else { throw unrecognizedWorktree(worktree) }
      let pinned = git.pinned(to: worktree, directory: directory)
      let branch = try pinned.run(
        ["--no-optional-locks", "symbolic-ref", "--quiet", "HEAD"], at: worktree, accepting: [0, 1]
      ).stdout.trimmingCharacters(in: .newlines)
      // Rebase detaches HEAD; its durable head-name identifies the branch that abort will restore.
      let rebaseBranch = rebaseDirectory(journal).flatMap {
        try? String(contentsOf: $0.appendingPathComponent("head-name"), encoding: .utf8)
          .trimmingCharacters(in: .newlines)
      }
      guard
        branch == "refs/heads/\(journal.branch)"
          || (branch.isEmpty && rebaseBranch == "refs/heads/\(journal.branch)")
      else { throw unrecognizedWorktree(worktree) }
      let top = try pinned.run(
        ["--no-optional-locks", "rev-parse", "--show-toplevel"], at: worktree
      )
      .stdout.trimmingCharacters(in: .newlines)
      guard
        URL(fileURLWithPath: top).standardizedFileURL.resolvingSymlinksInPath().path
          == worktree.path
      else { throw unrecognizedWorktree(worktree) }
      try io.afterWorktreeVerification(journal)
      return pinned
    } catch let error as DeliveryFailure where error.reason == .worktreeUnrecognized {
      guard try FileManager.default.contentsOfDirectory(atPath: worktree.path).isEmpty else {
        throw error
      }
      try FileManager.default.removeItem(at: worktree)
      try pruneWorktreeRegistration(at: worktree)
      return nil
    }
  }

  func rebaseDirectory(_ journal: DeliveryJournal) -> URL? {
    guard let identity = journal.worktreeIdentity else { return nil }
    return ["rebase-merge", "rebase-apply"].map {
      URL(fileURLWithPath: identity.directory).appendingPathComponent($0)
    }.first { FileManager.default.fileExists(atPath: $0.path) }
  }

  @discardableResult
  func abortRebase(_ journal: DeliveryJournal) throws -> DeliveryGit? {
    guard let pinned = try verifiedWorktree(journal) else { return nil }
    if rebaseDirectory(journal) != nil {
      try pinned.run(["rebase", "--abort"], at: URL(fileURLWithPath: journal.worktree))
    }
    return pinned
  }

  private func pruneWorktreeRegistration(at worktree: URL) throws {
    guard try hasWorktreeRegistration(worktree) else { return }
    try git.run(["worktree", "prune", "--expire=now"], at: root)
    guard try !hasWorktreeRegistration(worktree) else {
      throw DeliveryFailure(
        reason: .cleanupFailed, detail: "Worktree registration remains: \(worktree.path)")
    }
  }

  private func undoEdits(_ journal: DeliveryJournal, git pinned: DeliveryGit) throws {
    let worktree = URL(fileURLWithPath: journal.worktree)
    guard try pinned.revision("HEAD", at: worktree) == journal.base else { return }
    for change in journal.changes ?? [] {
      let path = try Self.checkedPath(change.path, inside: worktree)
      let index = try pinned.run(
        ["--no-optional-locks", "ls-files", "--stage", "-z", "--", change.path], at: worktree
      ).stdout
      if index != change.index, index == journal.staged?[change.path] {
        try pinned.run(
          ["restore", "--staged", "--source=\(journal.base)", "--", change.path], at: worktree)
      }
      guard let current = try? Data(contentsOf: path), current == change.written else { continue }
      if let original = change.original {
        try original.write(to: path)
      } else {
        try FileManager.default.removeItem(at: path)
      }
    }
  }

  private func cleanup(_ journal: DeliveryJournal, verifiedDefault: String?) throws {
    try io.beforeCleanup(journal)
    let worktree = URL(fileURLWithPath: journal.worktree)
    if let pinned = try abortRebase(journal) {
      if journal.state == .aborted { try undoEdits(journal, git: pinned) }
      // Git's removal check ignores ignored files; include them when protecting other writers.
      guard
        try pinned.run(
          [
            "--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all",
            "--ignored=matching",
          ],
          at: worktree
        ).stdout.isEmpty
      else {
        throw DeliveryFailure(
          reason: .cleanupFailed, detail: "Worktree has uncommitted changes: \(worktree.path)")
      }
      if try verifiedWorktree(journal) != nil {
        try git.run(["worktree", "remove", worktree.path], at: root)
      }
    }
    guard journal.state == .merged || journal.state == .aborted,
      let branchTip = try git.revision("refs/heads/\(journal.branch)", at: root)
    else { return }
    let expected = journal.commit ?? journal.base
    guard let defaultTip = try git.revision("refs/heads/\(journal.defaultBranch)", at: root),
      let head = try git.revision("HEAD", at: main)
    else { throw DeliveryFailure(reason: .cleanupFailed, detail: "Main checkout has changed.") }
    if journal.state == .aborted {
      guard try git.isAncestor(branchTip, of: defaultTip, at: root) else {
        throw DeliveryFailure(
          reason: .cleanupFailed,
          detail: "Delivery branch is not reachable from the current default branch.")
      }
    } else {
      guard defaultTip == verifiedDefault else {
        throw DeliveryFailure(reason: .cleanupFailed, detail: "Default branch has changed.")
      }
      // Live landing must still have exact HEAD; recovery supplies the tip used for reachability.
      guard head == verifiedDefault else {
        throw DeliveryFailure(reason: .cleanupFailed, detail: "Main checkout HEAD has changed.")
      }
    }
    let headRef = try git.run(
      ["--no-optional-locks", "symbolic-ref", "--quiet", "HEAD"], at: main,
      accepting: [0, 1]
    ).stdout.trimmingCharacters(in: .newlines)
    guard headRef != "refs/heads/\(journal.defaultBranch)" || head == defaultTip else {
      throw DeliveryFailure(
        reason: .cleanupFailed, detail: "Default branch and main HEAD changed during cleanup.")
    }
    try io.beforeBranchDeletion(journal.branch, expected)
    let currentHeadRef = try git.run(
      ["--no-optional-locks", "symbolic-ref", "--quiet", "HEAD"], at: main,
      accepting: [0, 1]
    ).stdout.trimmingCharacters(in: .newlines)
    guard headRef == currentHeadRef else {
      throw DeliveryFailure(
        reason: .cleanupFailed, detail: "Main checkout HEAD branch has changed.")
    }
    var transaction = "start\nverify HEAD \(head)\n"
    // Verifying symbolic HEAD also locks/verifies its default referent. Listing both is rejected
    // by Git as duplicate updates. Other HEAD targets require a separate default verification.
    if headRef != "refs/heads/\(journal.defaultBranch)" {
      transaction += "verify refs/heads/\(journal.defaultBranch) \(defaultTip)\n"
    }
    transaction += "delete refs/heads/\(journal.branch) \(expected)\nprepare\ncommit\n"
    try git.run(["update-ref", "--stdin"], at: main, input: Data(transaction.utf8))
  }

  // Recovery verifies reachability from a captured default tip; live landing verifies exact HEAD.
  func finish(_ journal: inout DeliveryJournal, verifiedDefault: String? = nil) -> DeliveryResult {
    do {
      journal.message = nil
      try cleanup(journal, verifiedDefault: verifiedDefault ?? journal.commit)
      journal.phase = .finished
      if journal.reason == .journalFailed {
        // The started record and retained branch remain sufficient for recovery.
        try? io.write(journal, to: journals)
      } else {
        try io.write(journal, to: journals)
      }
    } catch {
      journal.phase = .cleanupPending
      journal.state = .cleanupPending
      journal.reason =
        (error as? DeliveryFailure)?.reason == .worktreeUnrecognized
        ? .worktreeUnrecognized : .cleanupFailed
      journal.message = boundedDeliveryText(error.localizedDescription)
      try? io.write(journal, to: journals)
    }
    var result = journal.result
    if result.state == .cleanupPending,
      let branch = try? git.run(
        ["--no-optional-locks", "show-ref", "--verify", "--quiet", "refs/heads/\(journal.branch)"],
        at: root,
        accepting: [0, 1])
    {
      result.branch = branch.exitCode == 0 ? journal.branch : nil
    }
    return result
  }
}
