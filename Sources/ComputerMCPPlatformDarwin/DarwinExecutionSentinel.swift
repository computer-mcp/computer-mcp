import ComputerMCPSandbox
import Darwin
import Foundation

/// An unreaped child bounds this execution's portion of XNU's newest-first zombproc list.
/// Host reapers must wait for specific PIDs: wait/waitpid(-1) or SIGCHLD auto-reaping would
/// destroy this boundary. Ownership retains it through failed completion and background cleanup.
final class DarwinExecutionSentinel: Sendable {
  // These unsandboxed children have known provenance even when sandbox_check cannot query
  // zombproc. Tracking identities lets concurrent executions classify each other's sentinels.
  private static let registered = Registry()
  let identity: DarwinProcessIdentity
  private let reap: @Sendable () -> Void

  init(identity: DarwinProcessIdentity, reap: @escaping @Sendable () -> Void) {
    self.identity = identity
    self.reap = reap
    Self.registered.insert(identity)
  }

  convenience init() throws {
    var attributes: posix_spawnattr_t?
    var result = posix_spawnattr_init(&attributes)
    guard result == 0 else {
      throw ExecutionEnvironmentError.launchFailed(
        "Cannot initialize execution sentinel: \(result)")
    }
    defer { posix_spawnattr_destroy(&attributes) }
    result = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
    guard result == 0 else {
      throw ExecutionEnvironmentError.launchFailed("Cannot configure execution sentinel: \(result)")
    }
    let executable = strdup("/usr/bin/true")!
    defer { free(executable) }
    var arguments: [UnsafeMutablePointer<CChar>?] = [executable, nil]
    var environment: [UnsafeMutablePointer<CChar>?] = [nil]
    var pid: pid_t = 0
    result = posix_spawn(&pid, executable, nil, &attributes, &arguments, &environment)
    guard result == 0 else {
      throw ExecutionEnvironmentError.launchFailed("Cannot spawn execution sentinel: \(result)")
    }
    let child = pid
    let reap: @Sendable () -> Void = {
      var status: Int32 = 0
      while waitpid(child, &status, 0) == -1 && errno == EINTR {}
    }
    // WNOWAIT waits for exit completion without removing the child's proc record. No member
    // may be created until this returns; proc_prepareexit (kern_exit.c) inserts at zombproc's head.
    var info = siginfo_t()
    repeat {
      result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT)
    } while result == -1 && errno == EINTR
    guard result == 0, info.si_pid == pid,
      let identity = DarwinProcessIdentity.current(pid: pid, includingZombies: true)?.identity
    else {
      reap()
      throw ExecutionEnvironmentError.launchFailed("Cannot confirm execution sentinel exit")
    }
    self.init(identity: identity, reap: reap)
  }

  /// Spawning and WNOWAIT can block; each creation has its own worker, outside shared executors.
  static func create() async throws -> DarwinExecutionSentinel {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue(label: "execution.sentinel", qos: .userInitiated).async {
        continuation.resume(with: Result { try DarwinExecutionSentinel() })
      }
    }
  }

  static func identities() -> Set<DarwinProcessIdentity> {
    registered.snapshot()
  }

  deinit {
    reap()
    Self.registered.remove(identity)
  }

  private final class Registry: @unchecked Sendable {
    private let lock = NSLock()
    private var identities: [DarwinProcessIdentity: Int] = [:]

    func insert(_ identity: DarwinProcessIdentity) {
      lock.withLock { identities[identity, default: 0] += 1 }
    }

    func snapshot() -> Set<DarwinProcessIdentity> {
      lock.withLock { Set(identities.keys) }
    }

    func remove(_ identity: DarwinProcessIdentity) {
      lock.withLock {
        if let count = identities[identity], count > 1 {
          identities[identity] = count - 1
        } else {
          identities[identity] = nil
        }
      }
    }
  }
}
