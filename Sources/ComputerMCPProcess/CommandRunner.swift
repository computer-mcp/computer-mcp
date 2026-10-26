import ComputerMCPCore
import ComputerMCPPlatform
import Foundation

extension CommandResult {
  package var json: JSONValue {
    (try? JSONValue.encoded(self)) ?? .object([:])
  }
}

package final class ProcessCommandRunner: CommandRunning, Sendable {
  private let launcher: ExecutionLauncher
  private let baseEnvironment: [String: String]

  package init(
    launcher: ExecutionLauncher = ExecutionLauncher(),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.launcher = launcher
    baseEnvironment = environment
  }

  package func run(
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String],
    timeoutMilliseconds: Int,
    maxOutputBytes: Int
  ) throws -> CommandResult {
    let result = try runData(
      executable: executable,
      arguments: arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      timeoutMilliseconds: timeoutMilliseconds,
      maxOutputBytes: maxOutputBytes
    )
    return CommandResult(
      executable: result.executable,
      arguments: result.arguments,
      exitCode: result.exitCode,
      timedOut: result.timedOut,
      stdout: result.stdoutString,
      stderr: result.stderrString,
      stdoutTruncated: result.stdoutTruncated,
      stderrTruncated: result.stderrTruncated
    )
  }

  package func runData(
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String],
    timeoutMilliseconds: Int,
    maxOutputBytes: Int
  ) throws -> CommandDataResult {
    do {
      return try ManagedCommandRunner(
        launcher: launcher,
        policy: workingDirectory == nil ? .readOnly : HostExecutionPolicy.current
      )
      .runData(
        executable: executable, arguments: arguments, workingDirectory: workingDirectory,
        environment: baseEnvironment.merging(environment) { _, value in value },
        timeoutMilliseconds: timeoutMilliseconds, maxOutputBytes: maxOutputBytes)
    } catch let error as ProcessLaunchError {
      throw CommandRunnerError.launchFailed(error.localizedDescription)
    }
  }
}
