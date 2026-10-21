import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Persisted before worktree creation. Git state is authoritative during recovery.
internal struct DeliveryJournal: Codable, Sendable {
  struct WorktreeIdentity: Codable, Sendable {
    var directory: String
    var gitdir: String
  }

  struct Creation: Codable, Sendable {
    var branchCommit: String
    var worktree: WorktreeIdentity
    var sparse: Bool?
  }

  struct Change: Codable, Sendable {
    enum WriteState: String, Codable, Sendable {
      case pending, writing, written, rejected
    }

    var path: String
    var original: Data?
    var written: Data
    var index: String
    // Git blob IDs digest the exact bytes using the repository's object format.
    var originalDigest: String?
    var finalDigest: String?
    // Missing evidence and an interrupted write both require manual reconciliation.
    var writeState: WriteState?
  }

  struct Rebase: Codable, Sendable {
    var original: String
    var onto: String
  }

  enum Phase: String, Codable, Sendable {
    case started, committed
    case cleanupPending = "cleanup_pending"
    case finished
  }
  var schemaVersion = 1
  var operationID: String
  var workspace: String
  var scope: String
  var repository: String
  var defaultBranch: String
  var branch: String
  var worktree: String
  var base: String
  var creation: Creation?
  // Each undo record is durable before its file is written. Index entries are saved after staging.
  var changes: [Change]?
  var staged: [String: String]?
  var rebase: Rebase?
  var phase: Phase = .started
  var commit: String?
  var merged = false
  var state: DeliveryState?
  var reason: DeliveryReason?
  var message: String?
  var files: [DeliveryFile] = []

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case operationID = "operation_id"
    case defaultBranch = "default_branch"
    case workspace, scope, repository, branch, worktree, base, phase, commit, merged, state, reason,
      files, changes, staged, rebase, message, creation
  }

  var result: DeliveryResult {
    DeliveryResult(
      state: state ?? .aborted, commit: commit,
      branch: (state == .committed || state == .cleanupPending) ? branch : nil,
      reason: reason, message: message, files: files)
  }
}

/// Narrow mutation boundaries; production defaults perform no additional work.
internal struct DeliveryIO: Sendable {
  var beforeJournalWrite: @Sendable (DeliveryJournal) throws -> Void = { _ in }
  var beforeCleanup: @Sendable (DeliveryJournal) throws -> Void = { _ in }
  var beforeBranchDeletion: @Sendable (_ branch: String, _ checkedCommit: String) throws -> Void = {
    _, _ in
  }
  var beforeDirectorySync: @Sendable (URL) throws -> Void = { _ in }
  var beforeMergeCheck: @Sendable (DeliveryJournal) throws -> Void = { _ in }
  var afterWorktreeVerification: @Sendable (DeliveryJournal) throws -> Void = { _ in }
  var beforeFileWrite: @Sendable (DeliveryJournal.Change, URL) throws -> Void = { _, _ in }
  var beforeEmptyDirectoryRemoval: @Sendable (URL) throws -> Void = { _ in }
  var beforeFileRollback: @Sendable (URL) throws -> Void = { _ in }

  func writeFile(
    _ change: DeliveryJournal.Change, to path: URL,
    validate: () throws -> Void,
    recordWrite: (DeliveryJournal.Change.WriteState) throws -> Void
  ) throws {
    try beforeFileWrite(change, path)
    try recordWrite(.writing)
    try validate()
    if let original = change.original {
      guard try Data(contentsOf: path) == original else {
        try recordWrite(.rejected)
        throw DeliveryFailure(
          reason: .gitFailed, detail: "Delivery target changed before writing: \(change.path)")
      }
      try replaceFile(at: path, with: change.written, expecting: original)
    } else {
      let descriptor = open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o644)
      guard descriptor >= 0 else {
        let code = errno
        try recordWrite(.rejected)
        if code == EEXIST {
          throw DeliveryFailure(reason: .fileExists, detail: "File already exists: \(change.path)")
        }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
      }
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      defer { try? handle.close() }
      try handle.write(contentsOf: change.written)
    }
    try recordWrite(.written)
  }

  func undoFile(_ change: DeliveryJournal.Change, at path: URL) throws {
    guard (try? Data(contentsOf: path)) == change.written else { return }
    if let original = change.original {
      try replaceFile(at: path, with: original, expecting: change.written, rollback: true)
    } else {
      try beforeFileRollback(path)
      guard unlink(path.path) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    }
  }

  private func replaceFile(
    at path: URL, with content: Data, expecting expected: Data, rollback: Bool = false
  ) throws {
    let permissions =
      try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions]
      as? NSNumber
    try withTemporaryFile(
      in: path.deletingLastPathComponent(), mode: mode_t(permissions?.uint16Value ?? 0o644)
    ) {
      temporary, handle in
      try handle.write(contentsOf: content)
      guard try Data(contentsOf: path) == expected else {
        throw DeliveryFailure(reason: .gitFailed, detail: "Delivery target changed: \(path.path)")
      }
      if rollback { try beforeFileRollback(path) }
      try requireTemporaryFile(temporary, handle: handle)
      guard rename(temporary.path, path.path) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    }
  }

  private func withTemporaryFile(
    in directory: URL, mode: mode_t, _ action: (URL, FileHandle) throws -> Void
  ) throws {
    let temporary = directory.appendingPathComponent(
      ".delivery-\(UUID().uuidString.lowercased()).tmp")
    let descriptor = open(
      temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer {
      if matchesTemporaryFile(temporary, handle: handle) { _ = unlink(temporary.path) }
      try? handle.close()
    }
    try action(temporary, handle)
  }

  private func matchesTemporaryFile(_ path: URL, handle: FileHandle) -> Bool {
    var opened = stat()
    var current = stat()
    return fstat(handle.fileDescriptor, &opened) == 0 && lstat(path.path, &current) == 0
      && opened.st_dev == current.st_dev && opened.st_ino == current.st_ino
      && current.st_mode & S_IFMT == S_IFREG
  }

  private func requireTemporaryFile(_ path: URL, handle: FileHandle) throws {
    guard matchesTemporaryFile(path, handle: handle) else {
      throw DeliveryFailure(
        reason: .cleanupFailed, detail: "Temporary file identity changed; retained: \(path.path)")
    }
  }

  func removeEmptyDirectory(_ directory: URL) throws {
    try beforeEmptyDirectoryRemoval(directory)
    guard rmdir(directory.path) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  func prepareDirectory(_ directory: URL) throws {
    let parent = directory.deletingLastPathComponent()
    if !FileManager.default.fileExists(atPath: parent.path) {
      try prepareDirectory(parent)
    }
    if mkdir(directory.path, 0o755) != 0 {
      let code = errno
      guard code == EEXIST,
        try FileManager.default.attributesOfItem(atPath: directory.path)[.type]
          as? FileAttributeType == .typeDirectory
      else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
    }
    // Sync even an existing entry: another process may have just created it before locking.
    try synchronizeDirectory(parent)
  }

  private func synchronizeDirectory(_ directory: URL) throws {
    try beforeDirectorySync(directory)
    let descriptor = open(directory.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }

  func write(_ journal: DeliveryJournal, to directory: URL) throws {
    try beforeJournalWrite(journal)
    try prepareDirectory(directory)
    let target = directory.appendingPathComponent("\(journal.operationID).json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let content = try encoder.encode(journal)
    try withTemporaryFile(in: directory, mode: 0o600) { temporary, handle in
      try handle.write(contentsOf: content)
      try handle.synchronize()
      try requireTemporaryFile(temporary, handle: handle)
      try requireJournalTarget(journal, at: target)
      guard rename(temporary.path, target.path) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    }
    try synchronizeDirectory(directory)
  }

  private func requireJournalTarget(_ journal: DeliveryJournal, at target: URL) throws {
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
      guard attributes[.type] as? FileAttributeType == .typeRegular else {
        throw DeliveryFailure(
          reason: .journalFailed, detail: "Journal target is not a regular file: \(target.path)")
      }
      let existing = try JSONDecoder().decode(DeliveryJournal.self, from: Data(contentsOf: target))
      guard existing.operationID == journal.operationID, existing.workspace == journal.workspace,
        existing.scope == journal.scope, existing.repository == journal.repository,
        existing.defaultBranch == journal.defaultBranch, existing.branch == journal.branch,
        existing.worktree == journal.worktree, existing.base == journal.base
      else {
        throw DeliveryFailure(
          reason: .journalFailed, detail: "Journal identity changed; retained: \(target.path)")
      }
    } catch let error as CocoaError
      where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
    {
      return
    }
  }
}
