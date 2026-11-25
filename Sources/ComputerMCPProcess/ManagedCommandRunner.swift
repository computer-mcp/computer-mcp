import ComputerMCPPlatform
import ComputerMCPSandbox
import Foundation

/// Finite argv commands using the shared CLI lifecycle and a complete child environment.
/// Synchronous callers must use their blocking executor, not a UI or cooperative executor.
package struct ManagedCommandRunner: CommandRunning {
  private let execution: CLIProcessExecution
  private let launcher: ExecutionLauncher

  package init(launcher: ExecutionLauncher = ExecutionLauncher()) {
    self.launcher = launcher
    execution = CLIProcessExecution(launcher: launcher, inheritsEnvironment: false)
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
      stdoutTruncated: value.stdoutTruncated, stderrTruncated: value.stderrTruncated,
      ownership: value.ownership)
  }

  package func runIsolated(
    executable: String, arguments: [String], workingDirectory: URL?,
    environment: [String: String], timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult {
    try HostCommandEnvironment.$current.withValue(environment) {
      try ManagedCommandRunner(launcher: launcher).run(
        executable: executable, arguments: arguments, workingDirectory: workingDirectory,
        environment: environment, timeoutMilliseconds: timeoutMilliseconds,
        maxOutputBytes: maxOutputBytes)
    }
  }

  package func runToFile(
    executable: String, arguments: [String], workingDirectory: URL?,
    environment: [String: String], timeoutMilliseconds: Int, maxOutputBytes: Int,
    outputDescriptor: Int32
  ) throws -> CommandResult {
    let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
    defer { try? input.close() }
    return try HostCommandEnvironment.$current.withValue(environment) {
      try DescriptorCommandExecution.run(
        launcher: launcher, executable: executable, arguments: arguments,
        workingDirectory: workingDirectory, directoryDescriptor: nil,
        inputDescriptor: input.fileDescriptor, outputDescriptor: outputDescriptor,
        environment: environment, timeoutMilliseconds: timeoutMilliseconds,
        maxOutputBytes: maxOutputBytes)
    }
  }

  package func runInDirectory(
    executable: String, arguments: [String], directoryDescriptor: Int32,
    inputDescriptor: Int32, outputDescriptor: Int32, environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult {
    try HostCommandEnvironment.$current.withValue(environment) {
      try DescriptorCommandExecution.run(
        launcher: launcher, executable: executable, arguments: arguments,
        workingDirectory: nil, directoryDescriptor: directoryDescriptor,
        inputDescriptor: inputDescriptor, outputDescriptor: outputDescriptor,
        environment: environment, timeoutMilliseconds: timeoutMilliseconds,
        maxOutputBytes: maxOutputBytes)
    }
  }

  package func runBounded(
    executable: String, invocation: CLIInvocation, workingDirectory: URL,
    environment: [String: String], timeoutMilliseconds: Int, maxOutputBytes: Int,
    fileOutput: (descriptor: Int32, bytes: Int)?, fileSizeLimit: ExecutionFileSizeLimit?
  ) throws -> CommandDataResult {
    try HostCommandEnvironment.$current.withValue(environment) {
      try DescriptorCommandExecution.runBounded(
        launcher: launcher, executable: executable, invocation: invocation,
        directory: workingDirectory, environment: environment,
        timeoutMilliseconds: timeoutMilliseconds, maxOutputBytes: maxOutputBytes,
        fileOutput: fileOutput, fileSizeLimit: fileSizeLimit)
    }
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
      stderrTruncated: value.stderr.truncated || value.stderr.missedBytes,
      ownership: value.ownership)
  }
}
