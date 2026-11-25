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
  private var path: String

  package convenience init(path: String, mode: Mode) throws {
    try self.init(path: path, mode: mode, flags: O_RDWR | O_CREAT)
  }

  package convenience init(sharingExisting path: String) throws {
    try self.init(path: path, mode: .shared, flags: O_RDONLY)
  }

  package convenience init(lockingExisting path: String) throws {
    try self.init(path: path, mode: .exclusive, flags: O_RDWR)
  }

  package static func createExclusive(path: String) throws -> FileLock {
    let temporary = path + ".incoming-" + UUID().uuidString.lowercased()
    let lock = try FileLock(path: temporary, mode: .exclusive, flags: O_RDWR | O_CREAT | O_EXCL)
    defer {
      if lock.path == temporary, (try? lock.verifyIdentity()) != nil { _ = unlink(temporary) }
    }
    try lock.synchronize()
    #if canImport(Darwin)
      let result = renameatx_np(AT_FDCWD, temporary, AT_FDCWD, path, UInt32(RENAME_EXCL))
    #elseif canImport(Glibc)
      let result = LinuxSystemCalls.renameExclusive(AT_FDCWD, temporary, AT_FDCWD, path)
    #endif
    guard result == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    lock.path = path
    try lock.verifyIdentity()
    return lock
  }

  private init(path: String, mode: Mode, flags: Int32) throws {
    let descriptor = open(path, flags | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
      status.st_nlink == 1
    else {
      close(descriptor)
      throw FileLockError.identityChanged(path: path)
    }
    guard flock(descriptor, (mode == .shared ? LOCK_SH : LOCK_EX) | LOCK_NB) == 0 else {
      let code = errno
      close(descriptor)
      if code == EWOULDBLOCK || code == EAGAIN { throw FileLockError.held(path: path) }
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    var current = stat()
    guard lstat(path, &current) == 0, current.st_mode & S_IFMT == S_IFREG,
      current.st_dev == status.st_dev, current.st_ino == status.st_ino, current.st_nlink == 1
    else {
      close(descriptor)
      throw FileLockError.identityChanged(path: path)
    }
    self.descriptor = descriptor
    self.path = path
  }

  deinit { release() }

  package func verifyIdentity() throws {
    var opened = stat()
    var current = stat()
    guard descriptor >= 0, fstat(descriptor, &opened) == 0, lstat(path, &current) == 0,
      current.st_mode & S_IFMT == S_IFREG, current.st_nlink == 1,
      opened.st_dev == current.st_dev, opened.st_ino == current.st_ino
    else { throw FileLockError.identityChanged(path: path) }
  }

  package struct Identity: Codable, Equatable, Sendable {
    private let device: Int64
    private let inode: UInt64
    private let birthSeconds: Int64?
    private let birthNanoseconds: Int64?

    fileprivate init(_ status: stat) {
      device = Int64(status.st_dev)
      inode = UInt64(status.st_ino)
      #if canImport(Darwin)
        birthSeconds = Int64(status.st_birthtimespec.tv_sec)
        birthNanoseconds = Int64(status.st_birthtimespec.tv_nsec)
      #else
        birthSeconds = nil
        birthNanoseconds = nil
      #endif
    }
  }

  package func identity() throws -> Identity {
    try verifyIdentity()
    var status = stat()
    guard fstat(descriptor, &status) == 0 else {
      throw FileLockError.identityChanged(path: path)
    }
    return Identity(status)
  }

  private func synchronize() throws {
    try verifyIdentity()
    guard fsync(descriptor) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    try verifyIdentity()
  }

  /// Diagnostics are written through the held descriptor, without replacing the inode.
  /// The exclusive-lock owner is responsible for serializing access to this method.
  package func writeDiagnostic(_ data: Data) throws {
    try verifyIdentity()
    guard lseek(descriptor, 0, SEEK_SET) == 0, ftruncate(descriptor, 0) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    try handle.write(contentsOf: data)
    try handle.synchronize()
    try verifyIdentity()
  }

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
  case identityChanged(path: String)
}
