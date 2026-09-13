import Darwin
import Foundation

/// Owns a private directory created by the host or reopened from its ownership receipt.
/// All child writes and cleanup are anchored to open directory descriptors.
final class PluginArchiveDirectory {
  let url: URL
  let descriptor: Int32
  private let parent: Int32
  private let name: String
  private var directoryPaths: [ino_t: [String]] = [:]

  convenience init(at requestedURL: URL) throws {
    try self.init(at: requestedURL, identity: nil)
  }

  convenience init(recovering identity: PluginDirectoryIdentity) throws {
    try self.init(at: identity.url, identity: identity)
  }

  private init(at requestedURL: URL, identity: PluginDirectoryIdentity?) throws {
    guard requestedURL.isFileURL, requestedURL.path.hasPrefix("/"),
      requestedURL.host.map({ $0.isEmpty || $0 == "localhost" }) != false,
      requestedURL.query == nil, requestedURL.fragment == nil,
      !requestedURL.path.contains("\0"),
      !requestedURL.pathComponents.contains(".."),
      requestedURL.lastPathComponent != ".", !requestedURL.lastPathComponent.isEmpty
    else { throw PluginArchiveError.invalidInput }
    let parentURL = try WorkspacePathResolver.canonicalWorkspace(
      requestedURL.deletingLastPathComponent())
    let parent = Darwin.open(parentURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard parent >= 0 else { throw PluginArchiveError.fileSystemFailure }
    var status = stat()
    guard fstat(parent, &status) == 0, status.st_uid == geteuid(),
      status.st_mode & 0o022 == 0
    else {
      Darwin.close(parent)
      throw PluginArchiveError.invalidInput
    }
    let name = requestedURL.lastPathComponent
    if identity == nil, mkdirat(parent, name, 0o700) != 0 {
      Darwin.close(parent)
      throw PluginArchiveError.conflictingPath
    }
    let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      if identity == nil { unlinkat(parent, name, AT_REMOVEDIR) }
      Darwin.close(parent)
      throw PluginArchiveError.fileSystemFailure
    }
    guard fstat(descriptor, &status) == 0, status.st_uid == geteuid(),
      status.st_mode & 0o077 == 0,
      identity.map({ $0.matches(status) }) ?? true
    else {
      Darwin.close(descriptor)
      Darwin.close(parent)
      throw PluginArchiveError.fileSystemFailure
    }
    self.parent = parent
    self.name = name
    self.descriptor = descriptor
    self.url = parentURL.appendingPathComponent(name, isDirectory: true)
  }

  deinit {
    Darwin.close(descriptor)
    Darwin.close(parent)
  }

  func createDirectory(_ parts: [String]) throws {
    let directory = try openDirectory(parts)
    defer { Darwin.close(directory) }
    guard fsync(directory) == 0 else { throw PluginArchiveError.fileSystemFailure }
  }

  func createFile(
    _ parts: [String], executable: Bool, readOnly: Bool = false,
    write: (Int32) throws -> Void
  ) throws {
    guard let name = parts.last else { throw PluginArchiveError.unsafePath }
    let directory = try openDirectory(Array(parts.dropLast()))
    defer { Darwin.close(directory) }
    let file = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard file >= 0 else { throw PluginArchiveError.conflictingPath }
    defer { Darwin.close(file) }
    try write(file)
    // Preserve only whether the package owns an executable; never ownership,
    // set-id/sticky bits, ACLs, xattrs, or group/world access from the archive.
    guard fchmod(file, (readOnly ? 0o400 : 0o600) | (executable ? 0o100 : 0)) == 0,
      fsync(file) == 0, fsync(directory) == 0
    else { throw PluginArchiveError.fileSystemFailure }
  }

  func finish() throws {
    guard stillOwnsName(), fsync(descriptor) == 0, fsync(parent) == 0 else {
      throw PluginArchiveError.fileSystemFailure
    }
  }

  func identity() throws -> PluginDirectoryIdentity {
    var status = stat()
    guard stillOwnsName(), fstat(descriptor, &status) == 0 else {
      throw PluginArchiveError.fileSystemFailure
    }
    return PluginDirectoryIdentity(url: url, status: status)
  }

  /// Only the reserved staging child is disposable in a committed installation.
  func removeStaging() throws {
    guard stillOwnsName() else { throw PluginArchiveError.fileSystemFailure }
    var status = stat()
    guard fstatat(descriptor, "package", &status, AT_SYMLINK_NOFOLLOW) == 0,
      status.st_mode & S_IFMT == S_IFDIR, status.st_uid == geteuid(),
      status.st_mode & 0o077 == 0
    else { throw PluginArchiveError.invalidPackage }
    if fstatat(descriptor, "staging", &status, AT_SYMLINK_NOFOLLOW) != 0 {
      if errno == ENOENT { return }
      throw PluginArchiveError.fileSystemFailure
    }
    guard status.st_mode & S_IFMT == S_IFDIR else {
      throw PluginArchiveError.fileSystemFailure
    }
    let child = openat(descriptor, "staging", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard child >= 0 else { throw PluginArchiveError.fileSystemFailure }
    defer { Darwin.close(child) }
    try Self.removeContents(child)
    guard unlinkat(descriptor, "staging", AT_REMOVEDIR) == 0, fsync(descriptor) == 0 else {
      throw PluginArchiveError.fileSystemFailure
    }
  }

  /// A renamed/replaced staging root is never deleted by pathname.
  func discard() throws {
    guard stillOwnsName() else { throw PluginArchiveError.fileSystemFailure }
    try Self.removeContents(descriptor)
    guard stillOwnsName(), unlinkat(parent, name, AT_REMOVEDIR) == 0, fsync(parent) == 0 else {
      throw PluginArchiveError.fileSystemFailure
    }
  }

  private func stillOwnsName() -> Bool {
    var opened = stat()
    var named = stat()
    return fstat(descriptor, &opened) == 0
      && fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0
      && opened.st_dev == named.st_dev && opened.st_ino == named.st_ino
      && named.st_mode & S_IFMT == S_IFDIR
  }

  private func openDirectory(_ parts: [String]) throws -> Int32 {
    var directory = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
    guard directory >= 0 else { throw PluginArchiveError.fileSystemFailure }
    do {
      for (index, part) in parts.enumerated() {
        if mkdirat(directory, part, 0o700) != 0, errno != EEXIST {
          throw PluginArchiveError.fileSystemFailure
        }
        let child = openat(directory, part, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard child >= 0 else { throw PluginArchiveError.conflictingPath }
        Darwin.close(directory)
        directory = child
        var status = stat()
        guard fstat(child, &status) == 0 else { throw PluginArchiveError.fileSystemFailure }
        let spelling = Array(parts[...index])
        if let existing = directoryPaths[status.st_ino],
          !existing.joined(separator: "/").utf8.elementsEqual(spelling.joined(separator: "/").utf8)
        {
          throw PluginArchiveError.conflictingPath
        }
        directoryPaths[status.st_ino] = spelling
      }
      return directory
    } catch {
      Darwin.close(directory)
      throw error
    }
  }

  private static func removeContents(_ directory: Int32) throws {
    let duplicate = fcntl(directory, F_DUPFD_CLOEXEC, 0)
    guard duplicate >= 0 else { throw PluginArchiveError.fileSystemFailure }
    guard let stream = fdopendir(duplicate) else {
      Darwin.close(duplicate)
      throw PluginArchiveError.fileSystemFailure
    }
    defer { closedir(stream) }
    while true {
      errno = 0
      guard let entry = readdir(stream) else {
        guard errno == 0 else { throw PluginArchiveError.fileSystemFailure }
        return
      }
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1_024) { String(cString: $0) }
      }
      if name == "." || name == ".." { continue }
      var status = stat()
      guard fstatat(directory, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw PluginArchiveError.fileSystemFailure
      }
      if status.st_mode & S_IFMT == S_IFDIR {
        let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard child >= 0 else { throw PluginArchiveError.fileSystemFailure }
        defer { Darwin.close(child) }
        try removeContents(child)
        guard unlinkat(directory, name, AT_REMOVEDIR) == 0 else {
          throw PluginArchiveError.fileSystemFailure
        }
      } else if unlinkat(directory, name, 0) != 0 {
        throw PluginArchiveError.fileSystemFailure
      }
    }
  }
}
