import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Durable, expected-content replacement under the repository lock. Callers own the
/// schema and supply the last observed bytes; absent and changed files are distinct.
package struct WorktreeJournalIO: Sendable {
  package var beforePublication: @Sendable () throws -> Void = {}
  package var beforeDirectorySync: @Sendable () throws -> Void = {}

  package init(
    beforePublication: @escaping @Sendable () throws -> Void = {},
    beforeDirectorySync: @escaping @Sendable () throws -> Void = {}
  ) {
    self.beforePublication = beforePublication
    self.beforeDirectorySync = beforeDirectorySync
  }

  package func read(_ name: String, in directory: WorktreeDirectory, limit: Int) throws -> Data? {
    try WorktreeDirectory.requireName(name)
    try directory.verify()
    let fd = openat(directory.descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    if fd < 0, errno == ENOENT { return nil }
    guard fd >= 0 else { throw WorktreeDirectory.posixError() }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    var status = stat()
    guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
      status.st_nlink == 1, status.st_size >= 0, status.st_size <= limit
    else { throw WorktreeError.identityChanged("Invalid journal file: \(name)") }
    let content = try handle.read(upToCount: limit + 1) ?? Data()
    guard content.count <= limit else {
      throw WorktreeError.identityChanged("Journal exceeds limit.")
    }
    try requireIdentity(fd, name: name, directory: directory)
    return content
  }

  package func write(
    _ content: Data, name: String, in directory: WorktreeDirectory, replacing expected: Data?
  ) throws {
    try WorktreeDirectory.requireName(name)
    try directory.verify()
    let temporary = ".journal-\(UUID().uuidString.lowercased()).tmp"
    let fd = openat(
      directory.descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw WorktreeDirectory.posixError() }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer {
      if (try? requireIdentity(fd, name: temporary, directory: directory)) != nil {
        _ = unlinkat(directory.descriptor, temporary, 0)
      }
      try? handle.close()
    }
    try handle.write(contentsOf: content)
    try handle.synchronize()
    try beforePublication()
    try directory.verify()
    try requireIdentity(fd, name: temporary, directory: directory)
    let existing = try read(name, in: directory, limit: max(content.count, expected?.count ?? 0))
    guard existing == expected else {
      throw WorktreeError.identityChanged("Journal changed before publication: \(name)")
    }
    let result =
      expected == nil
      ? linkat(directory.descriptor, temporary, directory.descriptor, name, 0)
      : renameat(directory.descriptor, temporary, directory.descriptor, name)
    guard result == 0 else { throw WorktreeDirectory.posixError() }
    // A newly linked journal must have one link before it can be read as authority.
    if expected == nil {
      guard unlinkat(directory.descriptor, temporary, 0) == 0 else {
        throw WorktreeDirectory.posixError()
      }
    }
    try beforeDirectorySync()
    try directory.synchronize()
  }

  private func requireIdentity(_ fd: Int32, name: String, directory: WorktreeDirectory) throws {
    var opened = stat()
    var current = stat()
    guard fstat(fd, &opened) == 0,
      fstatat(directory.descriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
      current.st_mode & S_IFMT == S_IFREG, current.st_dev == opened.st_dev,
      current.st_ino == opened.st_ino
    else { throw WorktreeError.identityChanged("Journal file identity changed: \(name)") }
  }
}
