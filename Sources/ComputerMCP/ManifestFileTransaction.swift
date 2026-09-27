import CryptoKit
import Darwin
import Foundation

/// SQLite decides whether a synchronized file replacement committed. The journal
/// retains both possible file states until that decision can be recovered.
struct ManifestRecoveryRecord: Codable {
  let version: Int
  let revision: ConfigurationRevision
  let previous: Data?
}

struct ManifestFileTransaction {
  let manifestURL: URL
  let database: GatewayDatabase
  let fileManager: FileManager

  var recoveryURL: URL {
    manifestURL.deletingLastPathComponent().appendingPathComponent(
      ".\(manifestURL.lastPathComponent).activation.json")
  }

  func withExclusiveAccess<Result>(_ operation: () throws -> Result) throws -> Result {
    let lockURL = recoveryURL.appendingPathExtension("lock")
    let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else {
      throw AtomicManifestStoreError.posix(operation: "open manifest lock", code: errno)
    }
    defer { close(descriptor) }
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
      throw AtomicManifestStoreError.invalidRecoveryJournal
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      throw AtomicManifestStoreError.changeInProgress
    }
    defer { flock(descriptor, LOCK_UN) }
    return try operation()
  }

  func currentData() throws -> Data? {
    do {
      return try Data(contentsOf: manifestURL)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return nil
    }
  }

  /// Called under the manifest lock; the database callback remains synchronous.
  func commit(
    stagedURL: URL, previous: Data?, revision: ConfigurationRevision
  ) throws {
    guard try currentData() == previous else { throw AtomicManifestStoreError.staleDigest }
    let record = ManifestRecoveryRecord(version: 1, revision: revision, previous: previous)
    let temporary = recoveryURL.appendingPathExtension(UUID().uuidString)
    defer { try? fileManager.removeItem(at: temporary) }
    try Self.writeAndSynchronize(JSONEncoder().encode(record), to: temporary)
    guard
      renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, recoveryURL.path, UInt32(RENAME_EXCL)) == 0
    else {
      throw AtomicManifestStoreError.posix(
        operation: "publish manifest recovery record", code: errno)
    }
    do {
      try Self.synchronizeDirectory(manifestURL.deletingLastPathComponent())
      try database.activateConfigurationRevision(revision) {
        guard try currentData() == previous else { throw AtomicManifestStoreError.staleDigest }
        guard rename(stagedURL.path, manifestURL.path) == 0 else {
          throw AtomicManifestStoreError.posix(operation: "replace manifest", code: errno)
        }
        try fileManager.setAttributes(
          [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: manifestURL.path)
        try Self.synchronizeDirectory(manifestURL.deletingLastPathComponent())
      }
    } catch {
      // An unreadable database or unrecognized external edit retains the journal.
      // The caller must not claim that rollback completed in either case.
      if try recover() != true { throw error }
    }
    // The durable revision already committed. Cleanup cannot turn success into
    // failure; the next admission or startup retries an outstanding journal.
    try? removeRecoveryRecord()
  }

  @discardableResult
  func recover() throws -> Bool? {
    guard fileManager.fileExists(atPath: recoveryURL.path) else { return nil }
    let values = try recoveryURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
    guard values.isSymbolicLink != true, values.isRegularFile == true else {
      throw AtomicManifestStoreError.invalidRecoveryJournal
    }
    let record: ManifestRecoveryRecord
    do {
      record = try JSONDecoder().decode(
        ManifestRecoveryRecord.self, from: Data(contentsOf: recoveryURL))
    } catch {
      throw AtomicManifestStoreError.invalidRecoveryJournal
    }
    let proposed = Data(record.revision.manifest.utf8)
    guard record.version == 1, !proposed.isEmpty, record.revision.activatedAt != nil,
      record.revision.activationError == nil,
      record.revision.digest
        == SHA256.hash(data: proposed).map({ String(format: "%02x", $0) }).joined()
    else { throw AtomicManifestStoreError.invalidRecoveryJournal }
    let persisted = try database.configurationRevision(id: record.revision.id)
    if let persisted {
      guard persisted.digest == record.revision.digest,
        persisted.manifest == record.revision.manifest,
        persisted.activatedAt != nil, persisted.activationError == nil
      else { throw AtomicManifestStoreError.invalidRecoveryJournal }
    }
    let committed = persisted != nil
    let desired = committed ? proposed : record.previous
    let other = committed ? record.previous : proposed
    let actual = try currentData()
    if actual != desired {
      guard actual == other else {
        throw AtomicManifestStoreError.recoveryConflict(manifestURL.path)
      }
      if let desired {
        let temporary = recoveryURL.appendingPathExtension(UUID().uuidString)
        defer { try? fileManager.removeItem(at: temporary) }
        try Self.writeAndSynchronize(desired, to: temporary)
        guard try currentData() == actual else {
          throw AtomicManifestStoreError.recoveryConflict(manifestURL.path)
        }
        guard rename(temporary.path, manifestURL.path) == 0 else {
          throw AtomicManifestStoreError.posix(operation: "recover manifest", code: errno)
        }
      } else {
        guard try currentData() == actual else {
          throw AtomicManifestStoreError.recoveryConflict(manifestURL.path)
        }
        try fileManager.removeItem(at: manifestURL)
      }
      try Self.synchronizeDirectory(manifestURL.deletingLastPathComponent())
    }
    try removeRecoveryRecord()
    return committed
  }

  private func removeRecoveryRecord() throws {
    try fileManager.removeItem(at: recoveryURL)
    try Self.synchronizeDirectory(manifestURL.deletingLastPathComponent())
  }

  static func writeAndSynchronize(_ data: Data, to url: URL) throws {
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      throw AtomicManifestStoreError.posix(operation: "create staged manifest", code: errno)
    }
    var operationError: Error?
    data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return }
      var offset = 0
      while offset < rawBuffer.count {
        let written = Darwin.write(
          descriptor, baseAddress.advanced(by: offset), rawBuffer.count - offset)
        if written < 0, errno == EINTR { continue }
        if written <= 0 {
          operationError = AtomicManifestStoreError.posix(
            operation: "write staged manifest", code: written == 0 ? EIO : errno)
          break
        }
        offset += written
      }
    }
    if operationError == nil, fsync(descriptor) != 0 {
      operationError = AtomicManifestStoreError.posix(
        operation: "synchronize staged manifest", code: errno)
    }
    let closeResult = close(descriptor)
    if operationError == nil, closeResult != 0 {
      operationError = AtomicManifestStoreError.posix(
        operation: "close staged manifest", code: errno)
    }
    if let operationError { throw operationError }
  }

  static func synchronizeDirectory(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw AtomicManifestStoreError.posix(operation: "open manifest directory", code: errno)
    }
    let syncResult = fsync(descriptor)
    let syncError = errno
    _ = close(descriptor)
    guard syncResult == 0 else {
      throw AtomicManifestStoreError.posix(
        operation: "synchronize manifest directory", code: syncError)
    }
  }
}
