import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc

  // Glibc also exports a struct named flock; bind the function by its C symbol.
  @_silgen_name("flock") private func flock(_ descriptor: Int32, _ operation: Int32) -> Int32
#endif

/// A non-blocking advisory lock, held until release or deinitialization. Keep the lock
/// file in place: unlinking it would let another opener lock a different inode.
/// Separate acquisitions conflict even within one process.
package final class FileLock {
  package enum Mode: Sendable { case shared, exclusive }

  private var descriptor: Int32

  package init(path: String, mode: Mode) throws {
    let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    guard flock(descriptor, (mode == .shared ? LOCK_SH : LOCK_EX) | LOCK_NB) == 0 else {
      let code = errno
      close(descriptor)
      if code == EWOULDBLOCK || code == EAGAIN { throw FileLockError.held(path: path) }
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    self.descriptor = descriptor
  }

  deinit { release() }

  /// Idempotent. The owner must serialize release with any other use of this lock.
  package func release() {
    guard descriptor >= 0 else { return }
    flock(descriptor, LOCK_UN)
    close(descriptor)
    descriptor = -1
  }
}

package enum FileLockError: Error, Equatable {
  case held(path: String)
}
