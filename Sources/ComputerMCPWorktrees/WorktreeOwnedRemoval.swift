import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

extension WorktreeDirectory {
  /// The journal supplies the owned root; traversal never follows links or
  /// delegates a recursive delete to a path-based tool.
  func removeOwnedTree(
    _ expected: WorktreeDirectoryIdentity, io: WorktreeJournalIO,
    authorize: (URL) throws -> Void = { _ in }
  ) throws {
    let url = URL(fileURLWithPath: expected.path)
    guard url.deletingLastPathComponent() == self.url else {
      throw WorktreeError.identityChanged("Removal root has a different parent.")
    }
    var status = stat()
    if fstatat(descriptor, url.lastPathComponent, &status, AT_SYMLINK_NOFOLLOW) != 0 {
      guard errno == ENOENT else { throw Self.posixError() }
      return
    }
    let child = try self.child(url.lastPathComponent)
    guard child.identity == expected else {
      throw WorktreeError.identityChanged("Removal root was replaced.")
    }
    var remaining = 1_000_000
    try child.removeContents(io: io, remaining: &remaining, authorize: authorize)
    try io.beforePublication()
    try verify()
    try child.verify()
    guard unlinkat(descriptor, url.lastPathComponent, AT_REMOVEDIR) == 0 else {
      throw Self.posixError()
    }
    try io.beforeDirectorySync()
    try synchronize()
  }

  private func removeContents(
    io: WorktreeJournalIO, remaining: inout Int,
    authorize: (URL) throws -> Void
  ) throws {
    for name in try entries(limit: remaining) {
      guard remaining > 0 else { throw WorktreeError.busy("Removal inventory exceeds its bound.") }
      remaining -= 1
      var before = stat()
      guard fstatat(descriptor, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw Self.posixError()
      }
      if before.st_mode & S_IFMT == S_IFDIR {
        let directory = try child(name)
        guard directory.identity.device == Int64(before.st_dev),
          directory.identity.inode == UInt64(before.st_ino)
        else {
          throw WorktreeError.identityChanged("Removal directory changed.")
        }
        try directory.removeContents(io: io, remaining: &remaining, authorize: authorize)
        try directory.verify()
      }
      try authorize(url.appendingPathComponent(name))
      try io.beforePublication()
      try verify()
      var current = stat()
      guard fstatat(descriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
        current.st_dev == before.st_dev, current.st_ino == before.st_ino,
        current.st_mode & S_IFMT == before.st_mode & S_IFMT
      else { throw WorktreeError.identityChanged("Removal entry changed.") }
      guard unlinkat(descriptor, name, before.st_mode & S_IFMT == S_IFDIR ? AT_REMOVEDIR : 0) == 0
      else {
        throw Self.posixError()
      }
    }
    try io.beforeDirectorySync()
    try synchronize()
  }
}
