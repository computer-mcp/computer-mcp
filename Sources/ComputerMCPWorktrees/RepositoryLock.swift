import ComputerMCPPlatformPOSIX
import Foundation

/// All host mutations of shared Git state use this lock.
/// Lock order is repository, worktree admission, then a short database transaction.
/// The descriptor owns exclusion; diagnostic metadata never establishes ownership.
package final class RepositoryLock {
  package struct Owner: Codable, Sendable {
    package let operationID: UUID
    package let hostInstanceID: UUID
    package let bootSessionID: String?
    package let processID: Int32

    private static let instanceID = UUID()

    package init(operationID: UUID = UUID(), bootSessionID: String? = nil) {
      self.operationID = operationID
      hostInstanceID = Self.instanceID
      self.bootSessionID = bootSessionID
      processID = ProcessInfo.processInfo.processIdentifier
    }
  }

  private let directory: WorktreeDirectory
  private let common: WorktreeDirectory
  private let lock: FileLock

  /// The caller chooses its waiting budget; cancellation is checked before admission
  /// and while waiting. A timeout never removes or replaces a lock file.
  package convenience init(
    commonDirectory: URL, owner: Owner, timeout: Duration,
    checkCancellation: () throws -> Void = { try Task.checkCancellation() }
  ) throws {
    try self.init(
      commonDirectory: commonDirectory, diagnostic: owner, timeout: timeout,
      checkCancellation: checkCancellation)
  }

  /// Recovery reuses the lifecycle lock inode without adding source state.
  convenience init(existingCommonDirectory: URL, timeout: Duration) throws {
    try self.init(
      commonDirectory: existingCommonDirectory, diagnostic: nil, timeout: timeout,
      checkCancellation: { try Task.checkCancellation() })
  }

  private init(
    commonDirectory: URL, diagnostic: Owner?, timeout: Duration,
    checkCancellation: () throws -> Void
  ) throws {
    common = try WorktreeDirectory(commonDirectory.resolvingSymlinksInPath().standardizedFileURL)
    directory = try common.child("computer-mcp", create: diagnostic != nil)
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while true {
      try checkCancellation()
      try common.verify()
      try directory.verify()
      do {
        let path = directory.url.appendingPathComponent("repository.lock").path
        lock =
          try diagnostic == nil
          ? FileLock(lockingExisting: path)
          : FileLock(path: path, mode: .exclusive)
        break
      } catch FileLockError.held {
        guard ContinuousClock.now < deadline else {
          throw WorktreeError.busy("Repository coordination lock timed out.")
        }
        Thread.sleep(forTimeInterval: 0.025)
      }
    }
    do {
      try checkCancellation()
      try verify()
      if let diagnostic {
        try lock.writeDiagnostic(JSONEncoder().encode(diagnostic))
        try directory.synchronize()
      }
    } catch {
      lock.release()
      throw error
    }
  }

  /// Recheck immediately before each irreversible boundary. Uncooperative external
  /// writers are not excluded by advisory locking and must be detected separately.
  package func verify() throws {
    try common.verify()
    try directory.verify()
    try lock.verifyIdentity()
  }

  package func release() { lock.release() }
}
