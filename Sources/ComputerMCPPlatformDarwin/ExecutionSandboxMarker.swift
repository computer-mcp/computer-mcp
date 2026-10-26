import CDarwinExecution
import ComputerMCPSandbox
import Darwin
import Foundation

/// Existing vnodes make sandbox_check distinguish an allowance from path lookup failure.
/// The shared directory is inaccessible to executed programs except for their own read marker.
final class ExecutionSandboxMarker: @unchecked Sendable {
  struct Recovery: Codable, Sendable {
    struct Entry: Codable, Sendable {
      let path: String
      let device: Int32
      let inode: UInt64
      let mode: UInt16

      init(_ path: String) throws {
        var value = stat()
        guard lstat(path, &value) == 0 else {
          throw ExecutionEnvironmentError.unavailable("Execution marker is unavailable")
        }
        self.path = path
        device = value.st_dev
        inode = value.st_ino
        mode = value.st_mode
      }

      func validate() throws {
        let current = try Self(path)
        guard current.device == device, current.inode == inode, current.mode == mode else {
          throw ExecutionEnvironmentError.unavailable("Execution marker identity changed")
        }
      }
    }
    let directory: Entry
    let own: Entry
    let common: Entry

    func validate() throws {
      try directory.validate()
      try own.validate()
      try common.validate()
    }
  }
  let directory: SandboxPath
  let own: SandboxPath
  let common: SandboxPath
  private let restored: Recovery?
  private let durability = NSLock()
  private var retainedForRecovery = false
  private static let storage = Storage()

  init() throws {
    (directory, own, common) = try Self.storage.acquire()
    restored = nil
  }

  init(recovery: Recovery) throws {
    try recovery.validate()
    directory = try SandboxPath(recovery.directory.path)
    own = try SandboxPath(recovery.own.path)
    common = try SandboxPath(recovery.common.path)
    guard own.value.hasPrefix(directory.value + "/"),
      common.value == directory.value + "/unsandboxed", own != common,
      recovery.directory.mode & S_IFMT == S_IFDIR,
      recovery.own.mode & S_IFMT == S_IFREG, recovery.common.mode & S_IFMT == S_IFREG
    else { throw ExecutionEnvironmentError.unavailable("Invalid execution marker recovery") }
    restored = recovery
  }

  func recovery() throws -> Recovery {
    durability.withLock { retainedForRecovery = true }
    if let restored {
      try restored.validate()
      return restored
    }
    return try Recovery(
      directory: .init(directory.value), own: .init(own.value), common: .init(common.value))
  }

  func contains(
    _ pid: pid_t,
    check: (pid_t, String) -> Int32 = { execution_sandbox_check($0, $1) }
  ) throws -> Bool {
    try restored?.validate()
    // Check denial first: another launch can enter its sandbox between the two queries.
    let commonResult = check(pid, common.value)
    guard commonResult == 0 || commonResult == 1 else {
      throw ExecutionEnvironmentError.launchFailed("Cannot query sandbox membership for PID \(pid)")
    }
    guard commonResult == 1 else { return false }
    let ownResult = check(pid, own.value)
    guard ownResult == 0 || ownResult == 1 else {
      throw ExecutionEnvironmentError.launchFailed("Cannot query sandbox membership for PID \(pid)")
    }
    return ownResult == 0
  }

  static func release(_ recovery: Recovery) throws {
    try Self.storage.releaseRecovered(recovery)
  }

  deinit {
    if restored == nil {
      Self.storage.release(own, retained: durability.withLock { retainedForRecovery })
    }
  }

  private final class Storage: @unchecked Sendable {
    private let lock = NSLock()
    private var root: URL?
    private var count = 0

    func acquire() throws -> (SandboxPath, SandboxPath, SandboxPath) {
      try lock.withLock {
        let manager = FileManager.default
        guard let canonical = realpath(manager.temporaryDirectory.path, nil) else {
          throw ExecutionEnvironmentError.launchFailed(
            "Cannot resolve execution marker directory: \(errno)")
        }
        defer { free(canonical) }
        let directory =
          root
          ?? URL(fileURLWithPath: String(cString: canonical))
          .appendingPathComponent("computer-mcp-executions-" + UUID().uuidString)
        let common = directory.appendingPathComponent("unsandboxed")
        let own = directory.appendingPathComponent(UUID().uuidString)
        do {
          if root == nil {
            try manager.createDirectory(
              at: directory, withIntermediateDirectories: false,
              attributes: [.posixPermissions: 0o700])
            try create(common)
          }
          try create(own)
          guard execution_sandbox_check(getpid(), own.path) == 0,
            execution_sandbox_check(getpid(), common.path) == 0
          else {
            throw ExecutionEnvironmentError.unavailable("Execution marker queries are unavailable")
          }
          let paths = try (
            SandboxPath(directory.path), SandboxPath(own.path), SandboxPath(common.path)
          )
          root = directory
          count += 1
          return paths
        } catch {
          try? manager.removeItem(at: own)
          if root == nil { try? manager.removeItem(at: directory) }
          throw error
        }
      }
    }

    func release(_ own: SandboxPath, retained: Bool) {
      lock.withLock {
        if !retained { try? FileManager.default.removeItem(atPath: own.value) }
        count -= 1
        if count == 0, let root { cleanEmpty(root) }
      }
    }

    func releaseRecovered(_ recovery: Recovery) throws {
      try lock.withLock {
        var info = stat()
        // Completion is committed before deletion. A crash after deletion must
        // allow acknowledgement to finish without touching a replacement inode.
        if lstat(recovery.directory.path, &info) != 0 {
          guard errno == ENOENT else {
            throw ExecutionEnvironmentError.unavailable("Cannot inspect execution marker directory")
          }
          return
        }
        try recovery.directory.validate()
        if lstat(recovery.own.path, &info) == 0 {
          try recovery.own.validate()
          try recovery.common.validate()
          guard unlink(recovery.own.path) == 0 else {
            throw ExecutionEnvironmentError.unavailable("Cannot release execution marker")
          }
        } else if errno != ENOENT {
          throw ExecutionEnvironmentError.unavailable("Cannot inspect execution marker")
        }
        let directory = URL(fileURLWithPath: recovery.directory.path)
        if count == 0 || directory.path != root?.path { cleanEmpty(directory) }
      }
    }

    private func cleanEmpty(_ directory: URL) {
      guard
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["unsandboxed"]
      else { return }
      unlink(directory.appendingPathComponent("unsandboxed").path)
      if rmdir(directory.path) == 0, root?.path == directory.path { root = nil }
    }

    private func create(_ url: URL) throws {
      let descriptor = open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
      guard descriptor >= 0 else {
        throw ExecutionEnvironmentError.launchFailed("Cannot create execution marker: \(errno)")
      }
      close(descriptor)
    }
  }
}
