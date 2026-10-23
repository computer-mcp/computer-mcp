import ComputerMCPPlatform
import Foundation

/// Finite argv commands using the shared CLI lifecycle and a complete child environment.
/// Synchronous callers must use their blocking executor, not a UI or cooperative executor.
package struct ManagedCommandRunner: CommandRunning {
  private let execution: CLIProcessExecution

  package init(
    launcher: ExecutionLauncher = ExecutionLauncher(), policy: HostExecutionPolicy = .fullAccess
  ) {
    execution = CLIProcessExecution(launcher: launcher, policy: policy, inheritsEnvironment: false)
  }

  package func run(
    executable: String, arguments: [String], workingDirectory: URL?, environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult {
    let value = try runData(
      executable: executable, arguments: arguments, workingDirectory: workingDirectory,
      environment: environment, timeoutMilliseconds: timeoutMilliseconds,
      maxOutputBytes: maxOutputBytes)
    return .init(
      executable: executable, arguments: arguments, exitCode: value.exitCode,
      timedOut: value.timedOut,
      stdout: value.stdoutString, stderr: value.stderrString,
      stdoutTruncated: value.stdoutTruncated, stderrTruncated: value.stderrTruncated)
  }

  package func runData(
    executable: String, arguments: [String], workingDirectory: URL?, environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandDataResult {
    try runData(
      executable: executable, invocation: .init(arguments: arguments, standardInput: Data()),
      workingDirectory: workingDirectory, environment: environment,
      timeoutMilliseconds: timeoutMilliseconds, maxOutputBytes: maxOutputBytes)
  }

  /// Supplies finite stdin and closes it, retaining the managed timeout and cleanup policy.
  package func runData(
    executable: String, invocation: CLIInvocation, workingDirectory: URL?,
    environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandDataResult {
    let value = try execution.launch(
      executable: executable, invocation: invocation,
      cwd: workingDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
      environment: environment, timeoutMilliseconds: timeoutMilliseconds,
      maxOutputBytes: maxOutputBytes)
    guard !value.isRunning else {
      throw ShellRuntimeError.timeoutWaitingForTermination(value.sessionID)
    }
    guard value.launchError == nil, value.streamErrors.isEmpty,
      let stdout = value.stdout.base64.flatMap({ Data(base64Encoded: $0) }),
      let stderr = value.stderr.base64.flatMap({ Data(base64Encoded: $0) })
    else {
      throw CommandRunnerError.launchFailed("Command execution or output collection failed.")
    }
    return .init(
      executable: executable, arguments: invocation.arguments,
      exitCode: value.exitCode ?? value.signal,
      timedOut: value.timedOut, stdout: stdout, stderr: stderr,
      stdoutTruncated: value.stdout.truncated || value.stdout.missedBytes,
      stderrTruncated: value.stderr.truncated || value.stderr.missedBytes)
  }
}
