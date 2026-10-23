import ComputerMCPPlatform
import Foundation

/// Registration runs with a complete environment, no shell and no inherited stdin.
/// A nil exit code means termination could not be confirmed; callers must stop.
package protocol RegistrationProcessRunning: Sendable {
  func run(
    executable: String, arguments: [String], environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult
}

package struct RegistrationProcessRunner: RegistrationProcessRunning {
  private let launcher: ExecutionLauncher

  package init(launcher: ExecutionLauncher = ExecutionLauncher()) { self.launcher = launcher }

  package func run(
    executable: String, arguments: [String], environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult {
    guard executable.hasPrefix("/") else {
      throw CommandRunnerError.launchFailed("Registration requires an absolute executable path.")
    }
    let result: CommandDataResult
    do {
      result = try ManagedCommandRunner(launcher: launcher, policy: HostExecutionPolicy.current)
        .runData(
          executable: executable, arguments: arguments,
          workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
          environment: environment, timeoutMilliseconds: timeoutMilliseconds,
          maxOutputBytes: maxOutputBytes)
    } catch ShellRuntimeError.timeoutWaitingForTermination {
      return .init(
        executable: executable, arguments: arguments, exitCode: nil, timedOut: true,
        stdout: "", stderr: "Execution termination could not be confirmed.",
        stdoutTruncated: false, stderrTruncated: false)
    }
    let stdout = String(data: result.stdout, encoding: .utf8)
    let stderr = String(data: result.stderr, encoding: .utf8)
    return .init(
      executable: executable, arguments: arguments, exitCode: result.exitCode,
      timedOut: result.timedOut, stdout: stdout ?? "", stderr: stderr ?? "",
      stdoutTruncated: result.stdoutTruncated || stdout == nil,
      stderrTruncated: result.stderrTruncated || stderr == nil)
  }
}
