import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// A retained directory descriptor anchors host-owned metadata operations. Persisted
/// identity is evidence to compare, never authority to delete a matching pathname.
package struct WorktreeDirectoryIdentity: Codable, Equatable, Sendable {
  package let path: String
  package let device: Int64
  package let inode: UInt64
}

package final class WorktreeDirectory {
  package let url: URL
  package let identity: WorktreeDirectoryIdentity
  let descriptor: Int32

  package init(_ url: URL) throws {
    let url = url.standardizedFileURL
    let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw Self.posixError() }
    var status = stat()
    var current = stat()
    guard fstat(fd, &status) == 0, lstat(url.path, &current) == 0,
      url.resolvingSymlinksInPath().path == url.path,
      current.st_mode & S_IFMT == S_IFDIR,
      current.st_dev == status.st_dev, current.st_ino == status.st_ino
    else {
      close(fd)
      throw WorktreeError.identityChanged("Directory identity changed: \(url.path)")
    }
    self.url = url
    descriptor = fd
    identity = .init(path: url.path, device: Int64(status.st_dev), inode: UInt64(status.st_ino))
  }

  deinit { close(descriptor) }

  package func verify() throws {
    var current = stat()
    guard url.resolvingSymlinksInPath().path == url.path,
      lstat(url.path, &current) == 0, current.st_mode & S_IFMT == S_IFDIR,
      Int64(current.st_dev) == identity.device, UInt64(current.st_ino) == identity.inode
    else { throw WorktreeError.identityChanged("Directory identity changed: \(url.path)") }
  }

  package func child(_ name: String, create: Bool = false) throws -> WorktreeDirectory {
    try Self.requireName(name)
    try verify()
    if create {
      guard mkdirat(descriptor, name, 0o700) == 0 || errno == EEXIST else {
        throw Self.posixError()
      }
      try synchronize()
    }
    let child = try WorktreeDirectory(url.appendingPathComponent(name, isDirectory: true))
    try verify()
    return child
  }

  package func synchronize() throws {
    try verify()
    guard fsync(descriptor) == 0 else { throw Self.posixError() }
  }

  static func requireName(_ name: String) throws {
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
      throw WorktreeError.unsafeConfiguration("Expected a single directory entry name.")
    }
  }

  static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
