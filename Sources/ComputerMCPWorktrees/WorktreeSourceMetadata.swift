import ComputerMCPPlatformPOSIX
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

struct WorktreeSourceFileProof: Codable, Equatable {
  let device: Int64
  let inode: UInt64
  let birthSeconds: Int64?
  let birthNanoseconds: Int64?
  let mode: UInt32
  let bytes: Int
  let digest: String

  fileprivate init(_ status: stat, contents: Data) {
    device = Int64(status.st_dev)
    inode = UInt64(status.st_ino)
    #if canImport(Darwin)
      birthSeconds = Int64(status.st_birthtimespec.tv_sec)
      birthNanoseconds = Int64(status.st_birthtimespec.tv_nsec)
    #else
      birthSeconds = nil
      birthNanoseconds = nil
    #endif
    mode = UInt32(status.st_mode & 0o7777)
    bytes = contents.count
    digest = WorktreeObjectSnapshot.digest(contents)
  }

  fileprivate func matchesIdentity(_ status: stat) -> Bool {
    guard device == Int64(status.st_dev), inode == UInt64(status.st_ino) else { return false }
    #if canImport(Darwin)
      return birthSeconds == Int64(status.st_birthtimespec.tv_sec)
        && birthNanoseconds == Int64(status.st_birthtimespec.tv_nsec)
    #else
      return birthSeconds == nil && birthNanoseconds == nil
    #endif
  }
}

struct WorktreeSourcePermissions: Equatable {
  enum Sharing: Equatable {
    case umask, group, all
    case explicit(mode_t)
  }
  let sharing: Sharing

  init(_ value: String?) throws {
    switch value?.lowercased() {
    case nil, "umask", "false", "no", "off", "0": sharing = .umask
    case "group", "true", "yes", "on", "1": sharing = .group
    case "all", "world", "everybody", "2": sharing = .all
    case let value?:
      guard let bits = mode_t(value, radix: 8), bits <= 0o777, bits & 0o600 == 0o600 else {
        throw WorktreeError.unsupportedRepository("Invalid Git shared repository permissions.")
      }
      sharing = .explicit(bits)
    }
  }

  func adjusted(_ original: mode_t, directory: Bool = false) -> mode_t {
    let extra: mode_t
    let replace: Bool
    switch sharing {
    case .umask: return original
    case .group: (extra, replace) = (0o660, false)
    case .all: (extra, replace) = (0o664, false)
    case .explicit(let bits): (extra, replace) = (bits, true)
    }
    var tweak = original & 0o200 == 0 ? extra & ~0o222 : extra
    if original & 0o100 != 0 { tweak |= (tweak & 0o444) >> 2 }
    let mode = (replace ? original & ~0o777 : original) | tweak
    return directory ? mode | ((mode & 0o444) >> 2) | 0o2000 : mode
  }
}

struct WorktreeSourceMetadata {
  static let maximumBytes = 128 * 1024 * 1024
  let common: WorktreeDirectory
  let format: WorktreeObjectFormat
  let permissions: WorktreeSourcePermissions
  let io: WorktreeJournalIO

  struct Location {
    let parent: WorktreeDirectory
    let leaf: String
    let ancestry: [WorktreeDirectory]

    func renamed(_ name: String) throws -> Self {
      try WorktreeDirectory.requireName(name)
      return Self(parent: parent, leaf: name, ancestry: ancestry)
    }

    func verify() throws {
      for directory in ancestry { try directory.verify() }
    }

    func synchronize(using io: WorktreeJournalIO) throws {
      for directory in ancestry.reversed() {
        try io.beforeDirectorySync()
        try directory.synchronize()
      }
    }

    func verifyAbsent() throws {
      try verify()
      guard try !parent.hasEntry(leaf) else { throw sourceMetadataChanged() }
    }

    func hasIdentity(_ proof: WorktreeSourceFileProof) throws -> Bool {
      try verify()
      var status = stat()
      if fstatat(parent.descriptor, leaf, &status, AT_SYMLINK_NOFOLLOW) == 0 {
        return proof.matchesIdentity(status)
      }
      guard errno == ENOENT else { throw WorktreeDirectory.posixError() }
      return false
    }
  }

  final class File {
    let handle: FileHandle
    let proof: WorktreeSourceFileProof
    let contents: Data

    fileprivate init(handle: FileHandle, contents: Data, status: stat) {
      self.handle = handle
      self.contents = contents
      proof = WorktreeSourceFileProof(status, contents: contents)
    }

    func verify(at location: Location) throws {
      try location.verify()
      var status = stat()
      var current = stat()
      guard fstat(handle.fileDescriptor, &status) == 0,
        fstatat(location.parent.descriptor, location.leaf, &current, AT_SYMLINK_NOFOLLOW) == 0,
        status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1,
        status.st_size == proof.bytes, UInt32(status.st_mode & 0o7777) == proof.mode,
        proof.matchesIdentity(status), proof.matchesIdentity(current),
        current.st_mode == status.st_mode, current.st_size == status.st_size, current.st_nlink == 1
      else { throw sourceMetadataChanged() }
    }

    func synchronize(at location: Location, using io: WorktreeJournalIO) throws {
      try verify(at: location)
      try handle.synchronize()
      try location.synchronize(using: io)
      try verify(at: location)
    }
  }

  static func requireBranch(_ path: String) throws {
    guard path.hasPrefix("refs/heads/"), path.utf8.count > "refs/heads/".utf8.count else {
      throw WorktreeError.invalidRequest("Expected a source branch ref.")
    }
    try WorktreePrivateMetadata.requireRef(path)
  }

  func validOID(_ oid: String) -> Bool { format.contains(oid) && oid.utf8.contains { $0 != 48 } }

  func location(_ path: String, createParents: Bool = false) throws -> Location? {
    switch path {
    case "HEAD", "packed-refs", "logs/HEAD": break
    default:
      try Self.requireBranch(path.hasPrefix("logs/") ? String(path.dropFirst(5)) : path)
    }
    let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    var ancestry = [common]
    var parent = common
    for component in components.dropLast() {
      try WorktreeDirectory.requireName(component)
      try parent.verify()
      if !createParents, try !parent.hasEntry(component) {
        for directory in ancestry { try directory.verify() }
        return nil
      }
      var created = false
      if createParents {
        let result = mkdirat(parent.descriptor, component, 0o777)
        guard result == 0 || errno == EEXIST else { throw WorktreeDirectory.posixError() }
        created = result == 0
      }
      let child = try parent.child(component)
      if created {
        var status = stat()
        guard fstat(child.descriptor, &status) == 0,
          fchmod(child.descriptor, permissions.adjusted(status.st_mode & 0o7777, directory: true))
            == 0
        else { throw WorktreeDirectory.posixError() }
        try child.synchronize()
        try parent.synchronize()
      }
      ancestry.append(child)
      parent = child
    }
    guard let leaf = components.last else { throw sourceMetadataChanged() }
    try WorktreeDirectory.requireName(leaf)
    return Location(parent: parent, leaf: leaf, ancestry: ancestry)
  }

  func read(_ location: Location, limit: Int = Self.maximumBytes) throws -> File? {
    try location.verify()
    let descriptor = openat(
      location.parent.descriptor, location.leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    if descriptor < 0, errno == ENOENT {
      try location.verify()
      return nil
    }
    guard descriptor >= 0 else { throw WorktreeDirectory.posixError() }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var before = stat()
    guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
      before.st_nlink == 1, before.st_size >= 0, before.st_size <= limit
    else { throw sourceMetadataChanged() }
    let contents = try handle.read(upToCount: Int(before.st_size)) ?? Data()
    var after = stat()
    guard fstat(descriptor, &after) == 0, Self.unchanged(before, after)
    else { throw sourceMetadataChanged() }
    let file = File(handle: handle, contents: contents, status: before)
    guard contents.count == before.st_size else { throw sourceMetadataChanged() }
    try file.verify(at: location)
    return file
  }

  private static func unchanged(_ before: stat, _ after: stat) -> Bool {
    #if canImport(Darwin)
      let old = [before.st_mtimespec, before.st_ctimespec]
      let current = [after.st_mtimespec, after.st_ctimespec]
    #else
      let old = [before.st_mtim, before.st_ctim]
      let current = [after.st_mtim, after.st_ctim]
    #endif
    return zip(old, current).allSatisfy {
      $0.tv_sec == $1.tv_sec && $0.tv_nsec == $1.tv_nsec
    }
  }

  func read(_ path: String, limit: Int = Self.maximumBytes) throws -> File? {
    guard let location = try location(path) else { return nil }
    return try read(location, limit: limit)
  }

  func create(_ bytes: Data, at location: Location, mode: mode_t, preserving: UInt32? = nil)
    throws -> File
  {
    guard bytes.count <= Self.maximumBytes else {
      throw WorktreeError.busy("Source metadata exceeds its byte bound.")
    }
    try location.verify()
    let descriptor = openat(
      location.parent.descriptor, location.leaf,
      O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
    guard descriptor >= 0 else { throw WorktreeDirectory.posixError() }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var status = stat()
    guard fstat(descriptor, &status) == 0 else { throw WorktreeDirectory.posixError() }
    let original = preserving.map { mode_t($0) } ?? (status.st_mode & 0o7777)
    guard fchmod(descriptor, permissions.adjusted(original)) == 0 else {
      throw WorktreeDirectory.posixError()
    }
    try handle.write(contentsOf: bytes)
    guard fstat(descriptor, &status) == 0 else { throw WorktreeDirectory.posixError() }
    let file = File(handle: handle, contents: bytes, status: status)
    try file.verify(at: location)
    return file
  }

  func move(_ file: File, from old: Location, to new: Location, replacing current: File? = nil)
    throws
  {
    try io.beforePublication()
    try file.verify(at: old)
    guard try read(old, limit: file.proof.bytes)?.proof == file.proof else {
      throw sourceMetadataChanged()
    }
    if let current {
      try current.verify(at: new)
      guard try read(new, limit: current.proof.bytes)?.proof == current.proof else {
        throw sourceMetadataChanged()
      }
      guard renameat(old.parent.descriptor, old.leaf, new.parent.descriptor, new.leaf) == 0 else {
        throw WorktreeDirectory.posixError()
      }
    } else {
      try new.verifyAbsent()
      #if canImport(Darwin)
        let result = renameatx_np(
          old.parent.descriptor, old.leaf, new.parent.descriptor, new.leaf, UInt32(RENAME_EXCL))
      #elseif canImport(Glibc)
        let result = LinuxSystemCalls.renameExclusive(
          old.parent.descriptor, old.leaf, new.parent.descriptor, new.leaf)
      #endif
      guard result == 0 else { throw WorktreeDirectory.posixError() }
    }
    try file.synchronize(at: new, using: io)
    guard try read(new, limit: file.proof.bytes)?.proof == file.proof else {
      throw sourceMetadataChanged()
    }
    try old.verifyAbsent()
  }

  func remove(_ file: File, at location: Location) throws {
    try io.beforePublication()
    try file.verify(at: location)
    guard try read(location, limit: file.proof.bytes)?.proof == file.proof else {
      throw sourceMetadataChanged()
    }
    guard unlinkat(location.parent.descriptor, location.leaf, 0) == 0 else {
      throw WorktreeDirectory.posixError()
    }
    try location.synchronize(using: io)
    try location.verifyAbsent()
  }
}

func sourceMetadataChanged() -> WorktreeError {
  .recoveryRequired("Source reference metadata cannot be attributed to the recorded operation.")
}
