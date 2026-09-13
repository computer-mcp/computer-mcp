import Darwin
import Foundation
import os

/// Local ownership evidence, not plugin metadata or an importable authorization.
struct PluginDirectoryIdentity: Codable, Equatable, Sendable {
  let url: URL
  let device: Int32
  let inode: UInt64
  let birthSeconds: Int
  let birthNanoseconds: Int

  init(url: URL, status: stat) {
    self.url = url
    device = status.st_dev
    inode = status.st_ino
    birthSeconds = status.st_birthtimespec.tv_sec
    birthNanoseconds = status.st_birthtimespec.tv_nsec
  }

  func matches(_ status: stat) -> Bool {
    device == status.st_dev && inode == status.st_ino
      && birthSeconds == status.st_birthtimespec.tv_sec
      && birthNanoseconds == status.st_birthtimespec.tv_nsec
  }
}

/// Serializes filesystem transactions across store instances and host restarts.
/// A worker inherits the same open lock reference; closing the host reference
/// must not unlock a worker that is still writing after its parent exits.
final class PluginInstallationStorage: Sendable {
  let root: URL
  let lockDescriptor: Int32
  private let descriptor: Int32
  private let parent: Int32
  private let identity: PluginDirectoryIdentity
  private let closed = OSAllocatedUnfairLock(initialState: false)

  init(at requestedURL: URL) throws {
    guard requestedURL.isFileURL, requestedURL.path.hasPrefix("/"),
      requestedURL.host.map({ $0.isEmpty || $0 == "localhost" }) != false,
      requestedURL.query == nil, requestedURL.fragment == nil,
      !requestedURL.path.contains("\0"), !requestedURL.pathComponents.contains(".."),
      !requestedURL.lastPathComponent.isEmpty, requestedURL.lastPathComponent != "."
    else { throw PluginStoreError.invalidState }
    let parentURL = try WorkspacePathResolver.canonicalWorkspace(
      requestedURL.deletingLastPathComponent())
    let parent = Darwin.open(parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { throw PluginArchiveError.fileSystemFailure }
    var status = stat()
    guard fstat(parent, &status) == 0, status.st_uid == geteuid(), status.st_mode & 0o022 == 0
    else {
      Darwin.close(parent)
      throw PluginArchiveError.invalidInput
    }
    let name = requestedURL.lastPathComponent
    if mkdirat(parent, name, 0o700) != 0, errno != EEXIST {
      Darwin.close(parent)
      throw PluginArchiveError.fileSystemFailure
    }
    let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      Darwin.close(parent)
      throw PluginArchiveError.fileSystemFailure
    }
    do {
      guard fstat(descriptor, &status) == 0, status.st_uid == geteuid(),
        status.st_mode & 0o077 == 0
      else { throw PluginArchiveError.invalidInput }
      let root = parentURL.appendingPathComponent(name, isDirectory: true)
      let identity = PluginDirectoryIdentity(url: root, status: status)
      let lock = openat(
        descriptor, "store.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
      guard lock >= 0 else { throw PluginArchiveError.fileSystemFailure }
      do {
        guard fstat(lock, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
          status.st_uid == geteuid(), status.st_mode & 0o077 == 0, status.st_nlink == 1
        else { throw PluginArchiveError.invalidInput }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
          if errno == EWOULDBLOCK { throw PluginStoreError.installationBusy }
          throw PluginArchiveError.fileSystemFailure
        }
        var named = stat()
        guard fstatat(descriptor, "store.lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
          named.st_dev == status.st_dev, named.st_ino == status.st_ino,
          fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0, identity.matches(named),
          fsync(descriptor) == 0, fsync(parent) == 0
        else { throw PluginArchiveError.fileSystemFailure }
      } catch {
        Darwin.close(lock)
        throw error
      }
      self.root = root
      self.parent = parent
      self.descriptor = descriptor
      self.lockDescriptor = lock
      self.identity = identity
    } catch {
      Darwin.close(descriptor)
      Darwin.close(parent)
      throw error
    }
  }

  deinit {
    close()
  }

  /// Drops only this reference, preserving protection for an orphan worker.
  func close() {
    close(unlock: false)
  }

  /// All file operations and the worker must be joined before this call.
  /// Explicit unlock also retires copies temporarily held by unrelated forked
  /// children before their exec closes inherited descriptors. A crashed host
  /// never calls this method; the orphan worker retains the shared lock.
  func finishTransaction() {
    close(unlock: true)
  }

  private func close(unlock: Bool) {
    closed.withLock { closed in
      guard !closed else { return }
      closed = true
      if unlock { flock(lockDescriptor, LOCK_UN) }
      Darwin.close(lockDescriptor)
      Darwin.close(descriptor)
      Darwin.close(parent)
    }
  }

  private func withOpenStorage<Result: Sendable>(_ operation: @Sendable () throws -> Result) throws
    -> Result
  {
    try closed.withLock { closed in
      guard !closed else { throw PluginArchiveError.fileSystemFailure }
      return try operation()
    }
  }

  func validate(_ owned: PluginDirectoryIdentity) throws {
    try withOpenStorage { try validateLocation(owned) }
  }

  private func validateLocation(_ owned: PluginDirectoryIdentity) throws {
    var named = stat()
    guard fstatat(parent, root.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
      named.st_mode & S_IFMT == S_IFDIR, identity.matches(named),
      owned.url.deletingLastPathComponent().path == root.path,
      UUID(uuidString: owned.url.lastPathComponent)?.uuidString == owned.url.lastPathComponent
    else { throw PluginStoreError.invalidState }
  }

  func createInstallation() throws -> PluginDirectoryIdentity {
    try withOpenStorage {
      let url = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
      let directory = try PluginArchiveDirectory(at: url)
      do {
        let identity = try directory.identity()
        try validateLocation(identity)
        try directory.createDirectory(["staging"])
        try directory.finish()
        return identity
      } catch {
        try directory.discard()
        throw error
      }
    }
  }

  /// A complete payload becomes addressable before the database selects it.
  func promote(_ package: PluginPackage, into owned: PluginDirectoryIdentity) throws -> URL {
    try withOpenStorage {
      try validateLocation(owned)
      let container = try PluginArchiveDirectory(recovering: owned)
      let jobURL = package.root.deletingLastPathComponent()
      guard package.root.lastPathComponent == "payload",
        jobURL.deletingLastPathComponent().path == owned.url.appendingPathComponent("staging").path,
        UUID(uuidString: jobURL.lastPathComponent)?.uuidString == jobURL.lastPathComponent
      else { throw PluginStoreError.invalidState }
      let staging = openat(
        container.descriptor, "staging", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard staging >= 0 else { throw PluginArchiveError.fileSystemFailure }
      defer { Darwin.close(staging) }
      let job = openat(
        staging, jobURL.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard job >= 0 else { throw PluginArchiveError.fileSystemFailure }
      defer { Darwin.close(job) }
      guard renameatx_np(job, "payload", container.descriptor, "package", UInt32(RENAME_EXCL)) == 0,
        fsync(job) == 0
      else { throw PluginArchiveError.fileSystemFailure }
      try container.finish()
      return owned.url.appendingPathComponent("package", isDirectory: true)
    }
  }

  func clean(_ owned: PluginDirectoryIdentity, keepingPackage: Bool) throws {
    try withOpenStorage {
      try validateLocation(owned)
      var status = stat()
      if fstatat(descriptor, owned.url.lastPathComponent, &status, AT_SYMLINK_NOFOLLOW) != 0 {
        if errno == ENOENT && !keepingPackage { return }
        throw PluginArchiveError.fileSystemFailure
      }
      let directory = try PluginArchiveDirectory(recovering: owned)
      if keepingPackage { try directory.removeStaging() } else { try directory.discard() }
    }
  }
}
