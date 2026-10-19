import ComputerMCPProcess
import Foundation

extension CLIProcessExecution {
  /// Launches a CLI command; `executableChecks` must pass before the target command runs.
  func run(
    executable: String, invocation: CLIInvocation, cwd: URL, environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int, executableChecks: [CLIExecutableCheck] = [],
    interpreterBindings: [String: String] = [:]
  ) throws -> ShellSessionSnapshot {
    try Self.cliErrors {
      try launch(
        executable: executable, invocation: invocation, cwd: cwd, environment: environment,
        timeoutMilliseconds: timeoutMilliseconds, maxOutputBytes: maxOutputBytes,
        verification: CLIExecutableChecks(executableChecks),
        interpreterBindings: interpreterBindings)
    }
  }

  func runAsync(
    executable: String, invocation: CLIInvocation, cwd: URL, environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int, executableChecks: [CLIExecutableCheck] = [],
    interpreterBindings: [String: String] = [:]
  ) async throws -> ShellSessionSnapshot {
    do {
      return try await launchAsync(
        executable: executable, invocation: invocation, cwd: cwd, environment: environment,
        timeoutMilliseconds: timeoutMilliseconds, maxOutputBytes: maxOutputBytes,
        verification: CLIExecutableChecks(executableChecks),
        interpreterBindings: interpreterBindings)
    } catch ProcessLaunchError.invalid(let reason) {
      throw CLITreeError.invalid(reason)
    }
  }

  private static func cliErrors<Result>(_ body: () throws -> Result) throws -> Result {
    do {
      return try body()
    } catch ProcessLaunchError.invalid(let reason) {
      throw CLITreeError.invalid(reason)
    }
  }
}

/// Runs each compatibility check against the resolved executable, and refuses the launch
/// when a check fails, the deadline passes, or the executable or interpreter changes.
private struct CLIExecutableChecks: LaunchVerification {
  let checks: [CLIExecutableCheck]

  init?(_ checks: [CLIExecutableCheck]) {
    guard !checks.isEmpty else { return nil }
    self.checks = checks
  }

  func verify(_ launch: ResolvedProcessLaunch, call: BoundedProcessCall) throws -> String {
    guard checks.count <= 4 else {
      throw CLITreeError.invalid("Too many executable checks.")
    }
    for check in checks { try check.validate() }
    let deadline = ContinuousClock.now.advanced(
      by: .milliseconds(min(launch.timeoutMilliseconds, 5_000)))
    let identity = try CLIExecutableIdentity.capture(
      executable: launch.executable, cwd: launch.cwd, environment: launch.environment,
      interpreterBindings: launch.interpreterBindings)
    for check in checks {
      guard !call.isCancelled else { throw CancellationError() }
      let remaining = ContinuousClock.now.duration(to: deadline)
      guard remaining > .zero else {
        throw CLITreeError.invalid("CLI compatibility check timed out.")
      }
      let parts = remaining.components
      let milliseconds = max(
        1, Int(parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000))
      let result: ShellSessionSnapshot
      do {
        result = try call.execute(
          executable: identity.executable, arguments: identity.arguments + check.args,
          standardInput: Data(), cwd: launch.cwd, environment: launch.environment,
          timeoutMilliseconds: milliseconds, maxOutputBytes: 4_194_304)
      } catch {
        guard !call.isCancelled else { throw CancellationError() }
        throw CLITreeError.invalid(
          "CLI executable compatibility check could not run; target command was not executed.")
      }
      guard !call.isCancelled else { throw CancellationError() }
      guard check.matches(result), ContinuousClock.now < deadline else {
        throw CLITreeError.invalid(
          "CLI executable failed its compatibility check; target command was not executed.")
      }
      guard
        try CLIExecutableIdentity.capture(
          executable: launch.executable, cwd: launch.cwd, environment: launch.environment,
          interpreterBindings: launch.interpreterBindings) == identity
      else {
        throw CLITreeError.invalid(
          "CLI executable or interpreter changed during compatibility checks; retry after the update completes."
        )
      }
    }
    return identity.executable
  }
}
