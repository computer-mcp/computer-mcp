import Crypto
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Git switch changes files before attempting HEAD.lock. This separate reservation
/// excludes ordinary index writers through checkout and the guarded ref commit.
final class WorktreeIndexLease {
  let directory: WorktreeDirectory
  private var descriptor: Int32 = -1
  private let marker: Data

  init(
    directory: WorktreeDirectory, operationID: UUID, reopening expected: WorktreeRecoveryStageFile?
  ) throws {
    self.directory = directory
    marker = Data((operationID.uuidString.lowercased() + "\n").utf8)
    try directory.verify()
    if expected != nil {
      descriptor = openat(
        directory.descriptor, "index.lock", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    } else {
      descriptor = openat(
        directory.descriptor, "index.lock",
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    }
    guard descriptor >= 0 else {
      throw WorktreeError.recoveryRequired(
        "The main index is locked; retain existing locks for reconciliation.")
    }
    do {
      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
      if let expected {
        guard try proof() == expected else {
          throw WorktreeError.identityChanged("Main index reservation changed.")
        }
      } else {
        try handle.write(contentsOf: marker)
      }
      try handle.synchronize()
      try directory.synchronize()
    } catch {
      close(descriptor)
      descriptor = -1
      throw error
    }
  }

  deinit { if descriptor >= 0 { close(descriptor) } }

  func proof() throws -> WorktreeRecoveryStageFile {
    try verify()
    return try WorktreeRecoveryStageFile.read(
      "index.lock", in: directory, limit: marker.count,
      opened: FileHandle(fileDescriptor: descriptor, closeOnDealloc: false))
  }

  func verify() throws {
    try directory.verify()
    var opened = stat()
    var current = stat()
    guard fstat(descriptor, &opened) == 0,
      fstatat(directory.descriptor, "index.lock", &current, AT_SYMLINK_NOFOLLOW) == 0,
      opened.st_dev == current.st_dev, opened.st_ino == current.st_ino,
      current.st_mode & S_IFMT == S_IFREG, current.st_nlink == 1,
      try WorktreeJournalIO().read("index.lock", in: directory, limit: 128) == marker
    else { throw WorktreeError.identityChanged("Main index reservation changed.") }
  }

  func release() throws {
    try verify()
    guard unlinkat(directory.descriptor, "index.lock", 0) == 0 else {
      throw WorktreeDirectory.posixError()
    }
    try directory.synchronize()
  }
}

struct WorktreeCheckoutSnapshot: Codable, Equatable {
  struct Node: Codable, Equatable {
    let kind: String
    let mode: UInt32
    let digest: String?
  }
  let files: [String: Node]
  let index: String

  static func capture(
    paths: [String], root: WorktreeDirectory, index: Data, limits: WorktreePromotionLimits,
    synchronize: Bool = false
  ) throws -> Self {
    var files: [String: Node] = [:]
    var bytes = 0
    let deadline = ContinuousClock.now.advanced(by: limits.duration)
    func check() throws {
      try Task.checkCancellation()
      guard ContinuousClock.now < deadline, files.count < limits.objectCount,
        bytes <= limits.inputBytes
      else {
        throw WorktreeError.busy("Checkout fingerprint exceeds its bounds.")
      }
    }
    func visit(_ path: String, in parent: WorktreeDirectory, name: String, recurse: Bool) throws {
      try check()
      try parent.verify()
      var status = stat()
      if fstatat(parent.descriptor, name, &status, AT_SYMLINK_NOFOLLOW) != 0 {
        guard errno == ENOENT else { throw WorktreeDirectory.posixError() }
        files[path] = .init(kind: "absent", mode: 0, digest: nil)
        if synchronize { try parent.synchronize() }
        return
      }
      let mode = UInt32(status.st_mode & 0o7777)
      if status.st_mode & S_IFMT == S_IFDIR {
        files[path] = .init(kind: "directory", mode: mode, digest: nil)
        if recurse {
          let child = try parent.child(name)
          for entry in try child.entries(limit: limits.objectCount) {
            guard entry.lowercased() != ".git" else {
              throw WorktreeError.busy("Checkout intersects nested Git administration.")
            }
            try visit(path + "/" + entry, in: child, name: entry, recurse: true)
          }
        }
      } else if status.st_mode & S_IFMT == S_IFLNK {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlinkat(parent.descriptor, name, &buffer, buffer.count)
        guard count >= 0, count < buffer.count else { throw WorktreeDirectory.posixError() }
        bytes += count
        files[path] = .init(
          kind: "symlink", mode: mode,
          digest: WorktreeObjectSnapshot.digest(Data(buffer.prefix(count))))
      } else if status.st_mode & S_IFMT == S_IFREG {
        guard status.st_size >= 0, status.st_size <= limits.inputBytes - bytes else {
          throw WorktreeError.busy("Checkout input exceeds its byte bound.")
        }
        let fd = openat(parent.descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw WorktreeDirectory.posixError() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_dev == status.st_dev,
          opened.st_ino == status.st_ino
        else {
          throw WorktreeError.identityChanged("Checkout file changed during capture.")
        }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
          bytes += chunk.count
          try check()
          digest.update(data: chunk)
        }
        if synchronize { try handle.synchronize() }
        files[path] = .init(
          kind: "file", mode: mode,
          digest: digest.finalize().map { String(format: "%02x", $0) }.joined())
      } else {
        throw WorktreeError.busy("Checkout intersects a special file.")
      }
      var current = stat()
      guard fstatat(parent.descriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
        current.st_dev == status.st_dev, current.st_ino == status.st_ino,
        current.st_mode == status.st_mode, current.st_size == status.st_size
      else {
        throw WorktreeError.identityChanged("Checkout input changed during capture.")
      }
      if synchronize { try parent.synchronize() }
    }
    for path in paths {
      try requirePath(path)
      let components = path.split(separator: "/").map(String.init)
      var parent = root
      var prefix: [String] = []
      for (offset, name) in components.enumerated() {
        prefix.append(name)
        let partial = prefix.joined(separator: "/")
        try visit(partial, in: parent, name: name, recurse: offset == components.count - 1)
        if offset < components.count - 1 {
          if files[partial]?.kind == "absent" { break }
          guard files[partial]?.kind == "directory" else {
            // A file/directory transition is represented by the ancestor node.
            break
          }
          parent = try parent.child(name)
        }
      }
    }
    try root.verify()
    if synchronize { try root.synchronize() }
    return .init(files: files, index: WorktreeObjectSnapshot.digest(index))
  }

  static func requirePath(_ path: String) throws {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
      path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
        !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git"
      })
    else { throw WorktreeError.unsafeConfiguration("Invalid checkout path.") }
  }
}
