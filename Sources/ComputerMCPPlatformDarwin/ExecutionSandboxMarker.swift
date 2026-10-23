import CDarwinExecution
import ComputerMCPSandbox
import Darwin
import Foundation

/// Existing vnodes make sandbox_check distinguish an allowance from path lookup failure.
/// The shared directory is inaccessible to executed programs except for their own read marker.
final class ExecutionSandboxMarker: Sendable {
  let directory: SandboxPath
  let own: SandboxPath
  let common: SandboxPath
  private static let storage = Storage()

  init() throws {
    (directory, own, common) = try Self.storage.acquire()

  }

  func contains(
    _ pid: pid_t,
    check: (pid_t, String) -> Int32 = { execution_sandbox_check($0, $1) }
  ) throws -> Bool {
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

  deinit { Self.storage.release(own) }

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

    func release(_ own: SandboxPath) {
      lock.withLock {
        try? FileManager.default.removeItem(atPath: own.value)
        count -= 1
        if count == 0, let root {
          try? FileManager.default.removeItem(at: root)
          self.root = nil
        }
      }
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
