import ComputerMCPPlatform
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation

/// Supplies the host's configuration inventory separately from subcommand response fixtures.
/// Real-repository tests exercise the configuration overrides and process side effects.
final class GitCommandRecorder: CommandRunning, @unchecked Sendable {
  private let recorder = RecordingCommandRunner()
  private let resolvedObjects: [String: String]

  init(resolving objects: [String: String] = [:]) { resolvedObjects = objects }

  var stdout: String {
    get { recorder.stdout }
    set { recorder.stdout = newValue }
  }
  var stderr: String {
    get { recorder.stderr }
    set { recorder.stderr = newValue }
  }
  var exitCode: Int32? {
    get { recorder.exitCode }
    set { recorder.exitCode = newValue }
  }
  var stdoutTruncated: Bool {
    get { recorder.stdoutTruncated }
    set { recorder.stdoutTruncated = newValue }
  }
  var stderrTruncated: Bool {
    get { recorder.stderrTruncated }
    set { recorder.stderrTruncated = newValue }
  }
  var outputs: [RecordingCommandRunner.Output] {
    get { recorder.outputs }
    set { recorder.outputs = newValue }
  }
  var calls: [RecordingCommandRunner.Call] { recorder.calls }

  func run(
    executable: String, arguments: [String], workingDirectory: URL?, environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult {
    var args = arguments
    if args.starts(with: HostGitConfiguration.arguments) {
      args.removeFirst(HostGitConfiguration.arguments.count)
    }
    if args.first == "--literal-pathspecs" { args.removeFirst() }
    if args == ["config", "--null", "--name-only", "--list", "--no-includes"] {
      return CommandResult(
        executable: executable, arguments: arguments, exitCode: 0, timedOut: false,
        stdout: "", stderr: "", stdoutTruncated: false, stderrTruncated: false)
    }
    if args.starts(with: ["config", "--null", "--get"]) {
      return CommandResult(
        executable: executable, arguments: arguments, exitCode: 1, timedOut: false,
        stdout: "", stderr: "", stdoutTruncated: false, stderrTruncated: false)
    }
    if args.prefix(3) == ["rev-parse", "--verify", "--end-of-options"],
      let spec = args.last, let object = resolvedObjects[spec]
    {
      return CommandResult(
        executable: executable, arguments: args, exitCode: 0, timedOut: false,
        stdout: object + "\n", stderr: "", stdoutTruncated: false, stderrTruncated: false)
    }
    return try recorder.run(
      executable: executable, arguments: args, workingDirectory: workingDirectory,
      environment: environment, timeoutMilliseconds: timeoutMilliseconds,
      maxOutputBytes: maxOutputBytes)
  }

  func runData(
    executable: String, arguments: [String], workingDirectory: URL?, environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandDataResult {
    let result = try run(
      executable: executable, arguments: arguments, workingDirectory: workingDirectory,
      environment: environment, timeoutMilliseconds: timeoutMilliseconds,
      maxOutputBytes: maxOutputBytes)
    return CommandDataResult(
      executable: executable, arguments: result.arguments, exitCode: result.exitCode,
      timedOut: result.timedOut, stdout: Data(result.stdout.utf8), stderr: Data(result.stderr.utf8),
      stdoutTruncated: result.stdoutTruncated, stderrTruncated: result.stderrTruncated)
  }
}
