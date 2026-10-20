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
      let worktree = try Self.checkedPath(relativeWorktree, inside: recordedRoot)
      do { try abortRebase(at: worktree) } catch let failure as DeliveryFailure
        where failure.reason == .worktreeUnrecognized
      {
        journal.phase = .cleanupPending
        journal.state = .cleanupPending
        journal.reason = .worktreeUnrecognized
        try io.write(journal, to: journals)
        continue
      }
      let branchCommit = try git.revision("refs/heads/\(journal.branch)", at: root)
      if let branchCommit, branchCommit != journal.base { journal.commit = branchCommit }
      if let commit = journal.commit {
        journal.merged = try git.isAncestor(
          commit, of: "refs/heads/\(journal.defaultBranch)", at: root)
        journal.state = journal.merged ? .merged : .committed
        journal.reason = journal.merged ? nil : .interrupted
      } else {
        journal.state = .aborted
        journal.reason = .interrupted
      }
      _ = finish(&journal)
    }
  }

  private func isRegisteredWorktree(_ worktree: URL) throws -> Bool {
    let listing = try git.run(
      ["--no-optional-locks", "worktree", "list", "--porcelain", "-z"], at: root
    ).stdout.split(
      separator: "\0")
    guard
      listing.contains(where: { entry in
        guard entry.hasPrefix("worktree ") else { return false }
        return URL(fileURLWithPath: String(entry.dropFirst(9))).standardizedFileURL
          .resolvingSymlinksInPath().path == worktree.path
      })
    else { return false }
    let gitFile = worktree.appendingPathComponent(".git")
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: gitFile.path),
      attributes[.type] as? FileAttributeType == .typeRegular,
      let marker = try? String(contentsOf: gitFile, encoding: .utf8).trimmingCharacters(
        in: .newlines),
      marker.hasPrefix("gitdir: ")
    else { return false }
    let gitPath = String(marker.dropFirst(8))
    let directory =
      (gitPath.hasPrefix("/")
      ? URL(fileURLWithPath: gitPath) : worktree.appendingPathComponent(gitPath))
      .standardizedFileURL.resolvingSymlinksInPath()
    guard
      directory.deletingLastPathComponent().path
        == common.appendingPathComponent("worktrees").path,
      let backlink = try? String(
        contentsOf: directory.appendingPathComponent("gitdir"), encoding: .utf8
      ).trimmingCharacters(in: .newlines)
    else { return false }
    let backlinkURL =
      (backlink.hasPrefix("/")
      ? URL(fileURLWithPath: backlink) : directory.appendingPathComponent(backlink))
      .standardizedFileURL.resolvingSymlinksInPath()
    guard backlinkURL.path == gitFile.path else { return false }
    // Only a validated gitfile may select the repository for this command.
    let top = try git.run(["--no-optional-locks", "rev-parse", "--show-toplevel"], at: worktree)
      .stdout
      .trimmingCharacters(in: .newlines)
    return URL(fileURLWithPath: top).standardizedFileURL.resolvingSymlinksInPath().path
      == worktree.path
  }

  /// Returns whether cleanup may remove a verified worktree. Unrecognized empty directories
  /// are removed; nonempty directories are preserved without invoking Git inside them.
  @discardableResult
  func abortRebase(at worktree: URL) throws -> Bool {
    guard FileManager.default.fileExists(atPath: worktree.path) else { return false }
    guard try isRegisteredWorktree(worktree) else {
      guard try FileManager.default.contentsOfDirectory(atPath: worktree.path).isEmpty else {
        throw DeliveryFailure(
          reason: .worktreeUnrecognized, detail: "Unrecognized worktree retained: \(worktree.path)")
      }
      try FileManager.default.removeItem(at: worktree)
      return false
    }
    for name in ["rebase-merge", "rebase-apply"] {
      let path = try git.run(
        ["--no-optional-locks", "rev-parse", "--git-path", name], at: worktree
      ).stdout
        .trimmingCharacters(in: .newlines)
      let url =
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : worktree.appendingPathComponent(path)
      if FileManager.default.fileExists(atPath: url.path) {
        try git.run(["rebase", "--abort"], at: worktree)
        return true
      }
    }
    return true
  }

  func cleanup(_ journal: DeliveryJournal) throws {
    try io.beforeCleanup(journal)
    let worktree = URL(fileURLWithPath: journal.worktree)
    if try abortRebase(at: worktree) {
      try git.run(["worktree", "remove", "--force", worktree.path], at: root)
    }
    if let commit = try git.revision("refs/heads/\(journal.branch)", at: root) {
      // A branch with an undelivered commit survives every cleanup path.
      let removable =
        try (commit == journal.base && journal.commit == nil)
        || git.isAncestor(commit, of: "refs/heads/\(journal.defaultBranch)", at: root)
      if removable {
        try io.beforeBranchDeletion(journal.branch, commit)
        try git.run(["update-ref", "-d", "refs/heads/\(journal.branch)", commit], at: root)
      }
    }
  }

  func finish(_ journal: inout DeliveryJournal) -> DeliveryResult {
    do {
      try cleanup(journal)
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
