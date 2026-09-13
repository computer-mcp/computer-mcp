import CryptoKit
import Darwin
import Foundation

/// Host-local launch state. An available lock alone does not prove host authorization cleanup.
package struct MCPProcessReceiptStatus: Codable, Equatable, Sendable, Identifiable {
  package let id: String
  package let digest: String
  package let ownerPID: Int32?
  package let state: String
  package let recoverable: Bool
  package let blocksLaunch: Bool
}

/// A launch receipt and inherited lock outlive a crashed host. Live owners may
/// create independent sessions; failed or orphaned sessions block new launches.
final class MCPProcessOwnership: @unchecked Sendable {
  private struct Owner: Codable, Equatable {
    let pid: Int32
    let seconds: UInt64
    let microseconds: UInt64

    static func read(_ pid: Int32) throws -> Owner? {
      var info = proc_bsdinfo()
      let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
      errno = 0
      guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
        if errno == ESRCH { return nil }
        throw failure("Cannot establish the previous MCP owner's process identity.")
      }
      guard info.pbi_status != SZOMB else { return nil }
      return Owner(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }
  }

  private struct Receipt: Codable {
    let owner: Owner
    var cleanupFailed: Bool
    var hostServicesConfirmed: Bool?
  }

  private let root: URL
  private let scope: String
  private let name: String
  private let lock = NSLock()
  private var handle: FileHandle?
  private var receipt: Receipt

  func supervisorHandle() throws -> FileHandle {
    try lock.withLock {
      guard let handle else { throw Self.failure("MCP ownership receipt is closed.") }
      return handle
    }
  }

  static func acquire(root: URL, workspace: URL, registration: String) throws -> MCPProcessOwnership
  {
    let scope = try scope(workspace: workspace, registration: registration)
    return try withDirectory(root: root, scope: scope) { directory in
      let names = try entries(directory)
      guard names.count < 1_024 else { throw failure("MCP ownership receipt limit reached.") }
      for name in names where name != "scope.lock" {
        guard UUID(uuidString: name)?.uuidString == name else {
          throw failure("Unexpected file in MCP ownership storage.")
        }
        let descriptor = try openFile(directory, name: name, flags: O_RDWR)
        defer { Darwin.close(descriptor) }
        let available = flock(descriptor, LOCK_EX | LOCK_NB) == 0
        guard available || errno == EWOULDBLOCK else {
          throw failure("Cannot inspect MCP process lock.")
        }
        let prior = try readReceipt(descriptor)
        guard !prior.cleanupFailed else {
          throw failure(
            "[mcp.cleanup_failed] Previous MCP cleanup is unconfirmed; inspect the owned session before recovery."
          )
        }
        if available {
          guard unlinkat(directory, name, 0) == 0 else {
            throw failure("Cannot retire MCP launch receipt.")
          }
        } else if (try Owner.read(prior.owner.pid)) != prior.owner {
          throw failure(
            "[mcp.cleanup_pending] A previous MCP session has not released its process lock. Retry after cleanup finishes."
          )
        }
      }
      guard let owner = try Owner.read(getpid()) else {
        throw failure("Cannot identify the MCP host.")
      }
      let receipt = Receipt(owner: owner, cleanupFailed: false)
      let name = UUID().uuidString
      let descriptor = try openFile(directory, name: name, flags: O_RDWR | O_CREAT | O_EXCL)
      do {
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
          throw failure("Cannot reserve MCP process lock.")
        }
        try writeReceipt(receipt, descriptor: descriptor)
        guard fsync(directory) == 0 else { throw failure("Cannot persist MCP launch receipt.") }
        return MCPProcessOwnership(
          root: root, scope: scope, name: name, descriptor: descriptor, receipt: receipt)
      } catch {
        Darwin.close(descriptor)
        throw error
      }
    }
  }

  private init(root: URL, scope: String, name: String, descriptor: Int32, receipt: Receipt) {
    self.root = root
    self.scope = scope
    self.name = name
    self.handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    self.receipt = receipt
  }

  func finish(confirmed: Bool, hostServicesConfirmed: Bool = false) throws {
    try lock.withLock {
      guard let handle else { return }
      try Self.withDirectory(root: root, scope: scope) { directory in
        if confirmed {
          receipt.hostServicesConfirmed = true
          var original = stat()
          var named = stat()
          let verification = try Self.openFile(directory, name: name, flags: O_RDWR)
          defer { Darwin.close(verification) }
          guard fstat(handle.fileDescriptor, &original) == 0,
            fstat(verification, &named) == 0,
            original.st_dev == named.st_dev, original.st_ino == named.st_ino
          else { throw Self.failure("Cannot retire confirmed MCP ownership receipt.") }
          // Drop the host reference, then independently prove no inherited holder
          // survives. A supervisor exit alone does not establish watchdog exit.
          try handle.close()
          self.handle = nil
          let deadline = ContinuousClock.now + .seconds(1)
          while flock(verification, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, ContinuousClock.now < deadline else {
              receipt.cleanupFailed = true
              try Self.writeReceipt(receipt, descriptor: verification)
              throw Self.failure(
                "[mcp.cleanup_failed] An inherited MCP process lock is still held after shutdown.")
            }
            usleep(1_000)
          }
          guard unlinkat(directory, name, 0) == 0, fsync(directory) == 0 else {
            throw Self.failure("Cannot retire confirmed MCP ownership receipt.")
          }
        } else {
          receipt.cleanupFailed = true
          receipt.hostServicesConfirmed = hostServicesConfirmed
          try Self.writeReceipt(receipt, descriptor: handle.fileDescriptor)
          // Do not explicitly unlock: a supervisor may still hold this open-file reference.
          try handle.close()
          self.handle = nil
        }
      }
    }
  }

  static func inspect(root: URL, workspace: URL, registration: String) throws
    -> [MCPProcessReceiptStatus]
  {
    let scope = try scope(workspace: workspace, registration: registration)
    return try withDirectory(root: root, scope: scope) { directory in
      try entries(directory).filter { $0 != "scope.lock" }.sorted().map { name in
        guard UUID(uuidString: name)?.uuidString == name else {
          throw failure("Unexpected file in MCP ownership storage.")
        }
        let descriptor = try openFile(directory, name: name, flags: O_RDWR)
        defer { Darwin.close(descriptor) }
        return try inspect(descriptor, name: name, scope: scope)
      }
    }
  }

  /// Removes one reviewed receipt after independently locking it. Never signals a
  /// process, revokes a grant, launches a replacement, or replays a downstream call.
  static func recover(
    root: URL, workspace: URL, registration: String, id: String, expectedDigest: String
  ) throws {
    guard UUID(uuidString: id)?.uuidString == id else {
      throw failure("Invalid MCP ownership receipt ID.")
    }
    let scope = try scope(workspace: workspace, registration: registration)
    try withDirectory(root: root, scope: scope) { directory in
      let descriptor = try openFile(directory, name: id, flags: O_RDWR)
      defer { Darwin.close(descriptor) }
      let status = try inspect(descriptor, name: id, scope: scope)
      guard status.digest == expectedDigest, status.recoverable else {
        throw failure(
          "MCP cleanup state changed or cannot be safely recovered. Check the registration again.")
      }
      guard unlinkat(directory, id, 0) == 0, fsync(directory) == 0 else {
        throw failure("Cannot retire recovered MCP ownership receipt.")
      }
    }
  }

  private static func inspect(_ descriptor: Int32, name: String, scope: String) throws
    -> MCPProcessReceiptStatus
  {
    let available = flock(descriptor, LOCK_EX | LOCK_NB) == 0
    guard available || errno == EWOULDBLOCK else {
      throw failure("Cannot inspect MCP process lock.")
    }
    guard let receipt = try? readReceipt(descriptor) else {
      return .init(
        id: name, digest: "", ownerPID: nil, state: "invalid", recoverable: false,
        blocksLaunch: true)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(receipt)
    let digest = SHA256.hash(data: Data((scope + name).utf8) + data)
      .map { String(format: "%02x", $0) }.joined()
    let state: String
    if receipt.cleanupFailed {
      state = receipt.hostServicesConfirmed == true ? "cleanup_failed" : "host_cleanup_unconfirmed"
    } else if available {
      state = "stopped"
    } else {
      state = try Owner.read(receipt.owner.pid) == receipt.owner ? "running" : "cleanup_pending"
    }
    return .init(
      id: name, digest: digest, ownerPID: receipt.owner.pid, state: state,
      recoverable: available && receipt.cleanupFailed && receipt.hostServicesConfirmed == true,
      blocksLaunch: receipt.cleanupFailed || state == "cleanup_pending")
  }

  private static func scope(workspace: URL, registration: String) throws -> String {
    let identity = try JSONEncoder().encode([
      workspace.resolvingSymlinksInPath().path, registration,
    ])
    return SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
  }

  private static func readReceipt(_ descriptor: Int32) throws -> Receipt {
    var status = stat()
    guard fstat(descriptor, &status) == 0, (1...4_096).contains(status.st_size) else {
      throw failure("Invalid MCP ownership receipt size.")
    }
    var data = Data(count: Int(status.st_size))
    let count = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
    guard count == data.count else { throw failure("Cannot read MCP ownership receipt.") }
    return try JSONDecoder().decode(Receipt.self, from: data)
  }

  private static func writeReceipt(_ receipt: Receipt, descriptor: Int32) throws {
    let data = try JSONEncoder().encode(receipt)
    let count = data.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
    guard count == data.count, ftruncate(descriptor, off_t(data.count)) == 0, fsync(descriptor) == 0
    else {
      throw failure("Cannot persist MCP ownership receipt.")
    }
  }

  private static func openFile(_ directory: Int32, name: String, flags: Int32) throws -> Int32 {
    let protectedFlags = flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
    var descriptor: Int32
    if flags & O_CREAT != 0, flags & O_EXCL == 0 {
      // Publish the lock once, then open that inode. Concurrent nonexclusive
      // creation can return ENOENT on APFS even while the parent remains valid.
      descriptor = openat(directory, name, protectedFlags | O_EXCL, 0o600)
      if descriptor < 0, errno == EEXIST {
        descriptor = openat(directory, name, protectedFlags & ~O_CREAT)
      }
    } else {
      descriptor = openat(directory, name, protectedFlags, 0o600)
    }
    guard descriptor >= 0 else {
      throw failure("Cannot open MCP ownership file '\(name)' (errno \(errno)).")
    }
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
      status.st_uid == geteuid(), status.st_mode & 0o077 == 0, status.st_nlink == 1
    else {
      Darwin.close(descriptor)
      throw failure("MCP ownership file must be private and regular.")
    }
    return descriptor
  }

  private static func withDirectory<T>(root: URL, scope: String, _ body: (Int32) throws -> T) throws
    -> T
  {
    let parentURL = root.deletingLastPathComponent().resolvingSymlinksInPath()
    let parent = Darwin.open(parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { throw failure("Cannot open MCP ownership parent.") }
    defer { Darwin.close(parent) }
    var status = stat()
    guard fstat(parent, &status) == 0, status.st_uid == geteuid(), status.st_mode & 0o022 == 0
    else {
      throw failure("MCP ownership parent must be user-owned and not writable by others.")
    }
    func openDirectory(_ parent: Int32, _ name: String) throws -> Int32 {
      if mkdirat(parent, name, 0o700) != 0, errno != EEXIST {
        throw failure("Cannot create MCP ownership directory.")
      }
      let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard descriptor >= 0 else { throw failure("Cannot open MCP ownership directory.") }
      var info = stat()
      guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0
      else {
        Darwin.close(descriptor)
        throw failure("MCP ownership directory must be private.")
      }
      return descriptor
    }
    let storage = try openDirectory(parent, root.lastPathComponent)
    defer { Darwin.close(storage) }
    let directory = try openDirectory(storage, scope)
    defer { Darwin.close(directory) }
    let gate = try openFile(directory, name: "scope.lock", flags: O_RDWR | O_CREAT)
    defer { Darwin.close(gate) }
    let deadline = ContinuousClock.now + .seconds(1)
    while flock(gate, LOCK_EX | LOCK_NB) != 0 {
      guard errno == EWOULDBLOCK || errno == EINTR, ContinuousClock.now < deadline else {
        throw failure("MCP ownership is busy; retry the operation.")
      }
      usleep(1_000)
    }
    defer { flock(gate, LOCK_UN) }
    guard fsync(storage) == 0, fsync(parent) == 0 else {
      throw failure("Cannot persist MCP ownership directory.")
    }
    return try body(directory)
  }

  private static func entries(_ descriptor: Int32) throws -> [String] {
    let copy = fcntl(descriptor, F_DUPFD_CLOEXEC, 10)
    guard copy >= 0 else { throw failure("Cannot inspect MCP ownership directory.") }
    guard let directory = fdopendir(copy) else {
      Darwin.close(copy)
      throw failure("Cannot inspect MCP ownership directory.")
    }
    defer { closedir(directory) }
    var names: [String] = []
    while true {
      errno = 0
      guard let entry = readdir(directory) else {
        guard errno == 0 else { throw failure("Cannot enumerate MCP ownership receipts.") }
        break
      }
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
      }
      if name != ".", name != ".." { names.append(name) }
      guard names.count < 1_024 else { throw failure("MCP ownership receipt limit reached.") }
    }
    return names
  }

  private static func failure(_ message: String) -> GatewayToolError { .executionFailed(message) }
}
