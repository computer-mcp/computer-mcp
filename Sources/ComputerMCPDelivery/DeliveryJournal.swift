import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Persisted before worktree creation. Git state is authoritative during recovery.
internal struct DeliveryJournal: Codable, Sendable {
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
  var phase: Phase = .started
  var commit: String?
  var merged = false
  var state: DeliveryState?
  var reason: DeliveryReason?
  var files: [DeliveryFile] = []

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case operationID = "operation_id"
    case defaultBranch = "default_branch"
    case workspace, scope, repository, branch, worktree, base, phase, commit, merged, state, reason,
      files
  }

  var result: DeliveryResult {
    DeliveryResult(
      state: state ?? .aborted, commit: commit,
      branch: (state == .committed || state == .cleanupPending) ? branch : nil,
      reason: reason, files: files)
  }
}

/// Fault injection is limited to durable writes and cleanup boundaries.
internal struct DeliveryIO: Sendable {
  var beforeJournalWrite: @Sendable (DeliveryJournal) throws -> Void = { _ in }
  var beforeCleanup: @Sendable (DeliveryJournal) throws -> Void = { _ in }

  func write(_ journal: DeliveryJournal, to directory: URL) throws {
    try beforeJournalWrite(journal)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
    let parent = open(directory.path, O_RDONLY | O_CLOEXEC)
    guard parent >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(parent) }
    guard fsync(parent) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }
}
