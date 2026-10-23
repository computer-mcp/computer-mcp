import ComputerMCPPlatform
import Foundation

package final class RecordingCommandRunner: CommandRunning, @unchecked Sendable {
  package init() {}

  package struct Call: Equatable {
    package var executable: String
    package var arguments: [String]
    package var timeoutMilliseconds: Int
    package var maxOutputBytes: Int
  }

  package struct Output {
    package var stdout: String
    package var stdoutData: Data? = nil
    package var stderr: String = ""
    package var stderrData: Data? = nil
    package var exitCode: Int32? = 0
    package var stdoutTruncated: Bool = false
    package var stderrTruncated: Bool = false
    package init(
      stdout: String, stdoutData: Data? = nil, stderr: String = "", stderrData: Data? = nil,
      exitCode: Int32? = 0, stdoutTruncated: Bool = false, stderrTruncated: Bool = false
    ) {
      self.stdout = stdout
      self.stdoutData = stdoutData
      self.stderr = stderr
      self.stderrData = stderrData
      self.exitCode = exitCode
      self.stdoutTruncated = stdoutTruncated
      self.stderrTruncated = stderrTruncated
    }
  }

  package var stdout = "ok"
  package var stderr = ""
  package var exitCode: Int32? = 0
  package var stdoutTruncated = false
  package var stderrTruncated = false
  package var outputs: [Output] = []
  package var onRun: ((Call) throws -> Void)?
  package private(set) var calls: [Call] = []

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

  package func runToFile(
    executable: String, arguments: [String], workingDirectory: URL?,
    environment: [String: String], timeoutMilliseconds: Int, maxOutputBytes: Int,
    outputDescriptor: Int32
  ) throws -> CommandResult {
    let result = try runData(
      executable: executable, arguments: arguments, workingDirectory: workingDirectory,
      environment: environment, timeoutMilliseconds: timeoutMilliseconds,
      maxOutputBytes: maxOutputBytes)
    try FileHandle(fileDescriptor: outputDescriptor, closeOnDealloc: false).write(
      contentsOf: result.stdout)
    return CommandResult(
      executable: result.executable, arguments: result.arguments, exitCode: result.exitCode,
      timedOut: result.timedOut, stdout: "", stderr: result.stderrString,
      stdoutTruncated: result.stdoutTruncated, stderrTruncated: result.stderrTruncated)
  }

  package func runData(
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String],
    timeoutMilliseconds: Int,
    maxOutputBytes: Int
  ) throws -> CommandDataResult {
    let call = Call(
      executable: executable,
      arguments: arguments,
      timeoutMilliseconds: timeoutMilliseconds,
      maxOutputBytes: maxOutputBytes
    )
    calls.append(call)
    try onRun?(call)
    let output =
      outputs.isEmpty
      ? Output(
        stdout: stdout,
        stderr: stderr,
        exitCode: exitCode,
        stdoutTruncated: stdoutTruncated,
        stderrTruncated: stderrTruncated
      )
      : outputs.removeFirst()
    return CommandDataResult(
      executable: executable,
      arguments: arguments,
      exitCode: output.exitCode,
      timedOut: false,
      stdout: output.stdoutData ?? Data(output.stdout.utf8),
      stderr: output.stderrData ?? Data(output.stderr.utf8),
      stdoutTruncated: output.stdoutTruncated,
      stderrTruncated: output.stderrTruncated
    )
  }
}
