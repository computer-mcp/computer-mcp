import Foundation

package struct CommandResult: Codable, Equatable, Sendable {
  package var executable: String
  package var arguments: [String]
  package var exitCode: Int32?
  package var timedOut: Bool
  package var stdout: String
  package var stderr: String
  package var stdoutTruncated: Bool
  package var stderrTruncated: Bool

  private enum CodingKeys: String, CodingKey {
    case executable
    case arguments
    case exitCode = "exit_code"
    case timedOut = "timed_out"
    case stdout
    case stderr
    case stdoutTruncated = "stdout_truncated"
    case stderrTruncated = "stderr_truncated"
  }

  package init(
    executable: String,
    arguments: [String],
    exitCode: Int32?,
    timedOut: Bool,
    stdout: String,
    stderr: String,
    stdoutTruncated: Bool,
    stderrTruncated: Bool
  ) {
    self.executable = executable
    self.arguments = arguments
    self.exitCode = exitCode
    self.timedOut = timedOut
    self.stdout = stdout
    self.stderr = stderr
    self.stdoutTruncated = stdoutTruncated
    self.stderrTruncated = stderrTruncated
  }

}

package struct CommandDataResult: Equatable, Sendable {
  package var executable: String
  package var arguments: [String]
  package var exitCode: Int32?
  package var timedOut: Bool
  package var stdout: Data
  package var stderr: Data
  package var stdoutTruncated: Bool
  package var stderrTruncated: Bool

  package init(
    executable: String,
    arguments: [String],
    exitCode: Int32?,
    timedOut: Bool,
    stdout: Data,
    stderr: Data,
    stdoutTruncated: Bool,
    stderrTruncated: Bool
  ) {
    self.executable = executable
    self.arguments = arguments
    self.exitCode = exitCode
    self.timedOut = timedOut
    self.stdout = stdout
    self.stderr = stderr
    self.stdoutTruncated = stdoutTruncated
    self.stderrTruncated = stderrTruncated
  }

  package var stdoutString: String {
    String(decoding: stdout, as: UTF8.self)
  }

  package var stderrString: String {
    String(decoding: stderr, as: UTF8.self)
  }
}

package protocol CommandRunning: Sendable {
  func run(
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String],
    timeoutMilliseconds: Int,
    maxOutputBytes: Int
  ) throws -> CommandResult

  /// Runs with exactly the supplied environment, excluding inherited process variables.
  func runIsolated(
    executable: String, arguments: [String], workingDirectory: URL?,
    environment: [String: String], timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult

  /// Writes stdout to an already-open host-owned descriptor without reopening its pathname.
  func runToFile(
    executable: String, arguments: [String], workingDirectory: URL?,
    environment: [String: String], timeoutMilliseconds: Int, maxOutputBytes: Int,
    outputDescriptor: Int32
  ) throws -> CommandResult

  /// The child uses the opened directory and streams through the supplied descriptors.
  func runInDirectory(
    executable: String, arguments: [String], directoryDescriptor: Int32,
    inputDescriptor: Int32, outputDescriptor: Int32, environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult

  func runData(
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String],
    timeoutMilliseconds: Int,
    maxOutputBytes: Int
  ) throws -> CommandDataResult
}

extension CommandRunning {
  package func runInDirectory(
    executable: String, arguments: [String], directoryDescriptor: Int32,
    inputDescriptor: Int32, outputDescriptor: Int32, environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult {
    throw CommandRunnerError.launchFailed(
      "This command runner does not support descriptor working directories.")
  }

  package func runIsolated(
    executable: String, arguments: [String], workingDirectory: URL?,
    environment: [String: String], timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult {
    try run(
      executable: executable, arguments: arguments, workingDirectory: workingDirectory,
      environment: environment, timeoutMilliseconds: timeoutMilliseconds,
      maxOutputBytes: maxOutputBytes)
  }

  package func runToFile(
    executable: String, arguments: [String], workingDirectory: URL?,
    environment: [String: String], timeoutMilliseconds: Int, maxOutputBytes: Int,
    outputDescriptor: Int32
  ) throws -> CommandResult {
    throw CommandRunnerError.launchFailed("This command runner does not support descriptor output.")
  }
}

package enum CommandRunnerError: Error, LocalizedError, Equatable {
  case launchFailed(String)

  package var errorDescription: String? {
    switch self {
    case .launchFailed(let message):
      return message
    }
  }
}
