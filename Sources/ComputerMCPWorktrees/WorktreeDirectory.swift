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
  package let birthSeconds: Int64?
  package let birthNanoseconds: Int64?
}

package final class WorktreeDirectory {
  package let url: URL
  package let identity: WorktreeDirectoryIdentity
  let descriptor: Int32
  private let usesPhysicalPath: Bool

  package convenience init(_ url: URL) throws {
    try self.init(url, usesPhysicalPath: false)
  }

  /// Open the exact POSIX canonical path supplied by source admission.
  package convenience init(physicalURL: URL) throws {
    try self.init(physicalURL, usesPhysicalPath: true)
  }

  private init(_ input: URL, usesPhysicalPath: Bool) throws {
    let url = usesPhysicalPath ? input : input.standardizedFileURL
    let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw Self.posixError() }
    var status = stat()
    var current = stat()
    guard fstat(fd, &status) == 0, lstat(url.path, &current) == 0,
      Self.pathMatches(url, usesPhysicalPath: usesPhysicalPath),
      current.st_mode & S_IFMT == S_IFDIR,
      current.st_dev == status.st_dev, current.st_ino == status.st_ino
    else {
      close(fd)
      throw WorktreeError.identityChanged("Directory identity changed: \(url.path)")
    }
    self.url = url
    self.usesPhysicalPath = usesPhysicalPath
    descriptor = fd
    identity = Self.identity(url.path, status)
  }

  deinit { close(descriptor) }

  package func verify() throws {
    var current = stat()
    guard Self.pathMatches(url, usesPhysicalPath: usesPhysicalPath),
      lstat(url.path, &current) == 0, current.st_mode & S_IFMT == S_IFDIR,
      Self.identity(url.path, current) == identity
    else { throw WorktreeError.identityChanged("Directory identity changed: \(url.path)") }
  }

  package func child(_ name: String, create: Bool = false, exclusive: Bool = false) throws
    -> WorktreeDirectory
  {
    try Self.requireName(name)
    try verify()
    if create {
      guard mkdirat(descriptor, name, 0o700) == 0 || (!exclusive && errno == EEXIST) else {
        throw Self.posixError()
      }
      try synchronize()
    }
    let child = try WorktreeDirectory(
      url.appendingPathComponent(name, isDirectory: true), usesPhysicalPath: usesPhysicalPath)
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

  private static func pathMatches(_ url: URL, usesPhysicalPath: Bool) -> Bool {
    guard usesPhysicalPath else { return url.resolvingSymlinksInPath().path == url.path }
    // Foundation can spell Darwin's physical /private/tmp using its /tmp symlink.
    guard let resolved = realpath(url.path, nil) else { return false }
    defer { free(resolved) }
    return String(cString: resolved) == url.path
  }

  private static func identity(_ path: String, _ status: stat) -> WorktreeDirectoryIdentity {
    #if canImport(Darwin)
      let seconds: Int64? = Int64(status.st_birthtimespec.tv_sec)
      let nanos: Int64? = Int64(status.st_birthtimespec.tv_nsec)
    #else
      let seconds: Int64? = nil
      let nanos: Int64? = nil
    #endif
    return .init(
      path: path, device: Int64(status.st_dev), inode: UInt64(status.st_ino),
      birthSeconds: seconds, birthNanoseconds: nanos)
  }

  static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
