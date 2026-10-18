import Foundation

/// Finite argv commands using the shared CLI lifecycle and a complete child environment.
/// Synchronous callers must use their blocking executor, not a UI or cooperative executor.
struct ManagedCommandRunner: CommandRunning {
  private let execution = CLIProcessExecution(inheritsEnvironment: false)

  func run(
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

  func runData(
    executable: String, arguments: [String], workingDirectory: URL?, environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandDataResult {
    let value = try execution.run(
      executable: executable, invocation: .init(arguments: arguments, standardInput: Data()),
      cwd: workingDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
      environment: environment, timeoutMilliseconds: timeoutMilliseconds,
      maxOutputBytes: maxOutputBytes)
    guard !value.isRunning else {
      throw CommandRunnerError.launchFailed(
        "Command cleanup could not be confirmed within its deadline.")
    }
    guard value.launchError == nil, value.streamErrors.isEmpty,
      let stdout = value.stdout.base64.flatMap({ Data(base64Encoded: $0) }),
      let stderr = value.stderr.base64.flatMap({ Data(base64Encoded: $0) })
    else {
      throw CommandRunnerError.launchFailed("Command execution or output collection failed.")
    }
    return .init(
      executable: executable, arguments: arguments, exitCode: value.exitCode ?? value.signal,
      timedOut: value.timedOut, stdout: stdout, stderr: stderr,
      stdoutTruncated: value.stdout.truncated || value.stdout.missedBytes,
      stderrTruncated: value.stderr.truncated || value.stderr.missedBytes)
  }
}
