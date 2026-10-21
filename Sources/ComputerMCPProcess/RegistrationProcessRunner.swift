import ComputerMCPPlatform
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Registration runs with a complete environment, no shell and no inherited stdin.
/// A nil exit code means termination could not be confirmed; callers must stop.
package protocol RegistrationProcessRunning: Sendable {
  func run(
    executable: String, arguments: [String], environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult
}

package struct RegistrationProcessRunner: RegistrationProcessRunning {
  package init() {}

  package func run(
    executable: String, arguments: [String], environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult {
    guard executable.hasPrefix("/"),
      ([executable] + arguments + environment.flatMap { [$0.key, $0.value] })
        .allSatisfy({ !$0.contains("\0") })
    else { throw CommandRunnerError.launchFailed("Invalid registration process input.") }

    var out: [Int32] = [0, 0]
    var err: [Int32] = [0, 0]
    guard pipe(&out) == 0 else { throw launchError() }
    defer { for descriptor in out { close(descriptor) } }
    guard pipe(&err) == 0 else { throw launchError() }
    defer { for descriptor in err { close(descriptor) } }
    for descriptor in out + err {
      guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw launchError() }
    }
    for descriptor in [out[0], err[0]] {
      guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw launchError() }
    }

    #if canImport(Darwin)
      var actions: posix_spawn_file_actions_t?
      var attributes: posix_spawnattr_t?
    #else
      var actions = posix_spawn_file_actions_t()
      var attributes = posix_spawnattr_t()
    #endif
    guard posix_spawn_file_actions_init(&actions) == 0 else { throw launchError() }
    defer { posix_spawn_file_actions_destroy(&actions) }
    guard posix_spawnattr_init(&attributes) == 0 else { throw launchError() }
    defer { posix_spawnattr_destroy(&attributes) }
    guard
      posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
      posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO) == 0,
      posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO) == 0,
      posix_spawnattr_setpgroup(&attributes, 0) == 0,
      posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0
    else { throw launchError() }

    let argv = ([executable] + arguments).map { strdup($0) } + [nil]
    let envp =
      environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
      for pointer in argv { free(pointer) }
      for pointer in envp { free(pointer) }
    }
    var pid: pid_t = 0
    let launch = argv.withUnsafeBufferPointer { argv in
      envp.withUnsafeBufferPointer { envp in
        posix_spawn(&pid, executable, &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
      }
    }
    guard launch == 0 else { throw launchError() }

    var stdout = Data()
    var stderr = Data()
    var stdoutTruncated = false
    var stderrTruncated = false
    let clock = ContinuousClock()
    let deadline = clock.now + .milliseconds(max(1, timeoutMilliseconds))
    var killDeadline: ContinuousClock.Instant?
    var timedOut = false
    var status: Int32 = 0
    var confirmed = false
    while true {
      drain(out[0], into: &stdout, truncated: &stdoutTruncated, limit: maxOutputBytes)
      drain(err[0], into: &stderr, truncated: &stderrTruncated, limit: maxOutputBytes)
      let waited = waitpid(pid, &status, WNOHANG)
      if waited == pid {
        confirmed = true
        break
      }
      if waited < 0, errno != EINTR { break }
      if !timedOut, clock.now >= deadline {
        timedOut = true
        // The group exists before exec, so descendants cannot escape through a spawn race.
        kill(-pid, SIGKILL)
        killDeadline = clock.now + .seconds(2)
      }
      if let killDeadline, clock.now >= killDeadline { break }
      usleep(1_000)
    }
    drain(out[0], into: &stdout, truncated: &stdoutTruncated, limit: maxOutputBytes)
    drain(err[0], into: &stderr, truncated: &stderrTruncated, limit: maxOutputBytes)
    let exitCode: Int32? =
      confirmed ? ((status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)) : nil
    let stdoutText = String(data: stdout, encoding: .utf8)
    let stderrText = String(data: stderr, encoding: .utf8)
    return CommandResult(
      executable: executable, arguments: arguments, exitCode: exitCode, timedOut: timedOut,
      stdout: stdoutText ?? "", stderr: stderrText ?? "",
      stdoutTruncated: stdoutTruncated || stdoutText == nil,
      stderrTruncated: stderrTruncated || stderrText == nil)
  }

  private func launchError() -> CommandRunnerError {
    .launchFailed("Could not launch the registration client process.")
  }

  private func drain(_ descriptor: Int32, into data: inout Data, truncated: inout Bool, limit: Int)
  {
    var bytes = [UInt8](repeating: 0, count: 8_192)
    // Bound each turn even when a child writes continuously; the deadline still runs.
    for _ in 0..<32 {
      let count = read(descriptor, &bytes, bytes.count)
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { return }
      let available = max(0, max(1, limit) - data.count)
      data.append(contentsOf: bytes.prefix(min(count, available)))
      if count > available { truncated = true }
    }
  }
}
