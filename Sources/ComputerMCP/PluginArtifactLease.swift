import Darwin
import Foundation
import os

/// Pins an owned installation independently of its current selection in the store.
/// Acquisition and deletion both hold the installation transaction lock, so a
/// reader cannot create a replacement lock while cleanup removes the directory.
final class PluginArtifactLease: Sendable {
  let identity: PluginDirectoryIdentity
  private let descriptor: Int32
  private let closed = OSAllocatedUnfairLock(initialState: false)

  init(directory: PluginArchiveDirectory, exclusive: Bool) throws {
    let descriptor = openat(
      directory.descriptor, "artifact.lock",
      O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw PluginArchiveError.fileSystemFailure }
    do {
      var status = stat()
      var named = stat()
      guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
        status.st_uid == geteuid(), status.st_mode & 0o077 == 0, status.st_nlink == 1
      else { throw PluginArchiveError.invalidInput }
      guard flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
        if errno == EWOULDBLOCK { throw PluginStoreError.artifactInUse }
        throw PluginArchiveError.fileSystemFailure
      }
      guard fstatat(directory.descriptor, "artifact.lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
        named.st_dev == status.st_dev, named.st_ino == status.st_ino
      else { throw PluginArchiveError.fileSystemFailure }
      self.identity = try directory.identity()
      self.descriptor = descriptor
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  deinit { close() }

  /// This descriptor is private to one runtime; child ownership uses separate
  /// process receipts. End its lock explicitly so incidental fork-before-exec
  /// copies cannot extend a finished runtime's lease.
  func close() {
    closed.withLock { closed in
      guard !closed else { return }
      closed = true
      flock(descriptor, LOCK_UN)
      Darwin.close(descriptor)
    }
  }
}
