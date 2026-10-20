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

  struct Change: Codable, Sendable {
    var path: String
    var original: Data?
    var written: Data
    var index: String
    // Git blob IDs digest the exact bytes using the repository's object format.
    var originalDigest: String?
    var finalDigest: String?
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
  var worktreeIdentity: WorktreeIdentity?
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
    case worktreeIdentity = "worktree_identity"
    case workspace, scope, repository, branch, worktree, base, phase, commit, merged, state, reason,
      files, changes, staged, rebase, message
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

  func writeFile(_ change: DeliveryJournal.Change, to path: URL) throws {
    try beforeFileWrite(change, path)
    if let original = change.original {
      guard try Data(contentsOf: path) == original else {
        throw DeliveryFailure(
          reason: .gitFailed, detail: "Delivery target changed before writing: \(change.path)")
      }
      try change.written.write(to: path)
    } else {
      let descriptor = open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o644)
      guard descriptor >= 0 else {
        if errno == EEXIST {
          throw DeliveryFailure(reason: .fileExists, detail: "File already exists: \(change.path)")
        }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      defer { try? handle.close() }
      try handle.write(contentsOf: change.written)
    }
  }

  func prepareDirectory(_ directory: URL) throws {
    let parent = directory.deletingLastPathComponent()
    if !FileManager.default.fileExists(atPath: parent.path) {
      try prepareDirectory(parent)
    }
    if mkdir(directory.path, 0o755) != 0 {
      let code = errno
      var isDirectory: ObjCBool = false
      guard code == EEXIST,
        FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
    }
    // Sync even an existing entry: another process may have just created it before locking.
    try synchronizeDirectory(parent)
  }

  private func synchronizeDirectory(_ directory: URL) throws {
    try beforeDirectorySync(directory)
    let descriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }

  func write(_ journal: DeliveryJournal, to directory: URL) throws {
    try beforeJournalWrite(journal)
    try prepareDirectory(directory)
    let target = directory.appendingPathComponent("\(journal.operationID).json")
    let temporary = directory.appendingPathComponent(".\(journal.operationID).tmp")
    let descriptor = open(
      temporary.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer {
      try? handle.close()
      try? FileManager.default.removeItem(at: temporary)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    try handle.write(contentsOf: encoder.encode(journal))
    try handle.synchronize()
    guard rename(temporary.path, target.path) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    try synchronizeDirectory(directory)
  }
}
