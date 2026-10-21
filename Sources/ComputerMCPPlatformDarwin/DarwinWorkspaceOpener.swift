import ComputerMCPPlatform
import Foundation

package struct DarwinWorkspaceOpener: WorkspaceOpener {
  private let commandRunner: any CommandRunning

  package init(commandRunner: any CommandRunning) {
    self.commandRunner = commandRunner
  }

  package func open(
    _ url: URL, application: String?, workingDirectory: URL,
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult {
    var arguments: [String] = []
    if let application { arguments.append(contentsOf: ["-a", application]) }
    arguments.append(url.path)
    return try run(
      arguments: arguments, workingDirectory: workingDirectory,
      timeoutMilliseconds: timeoutMilliseconds, maxOutputBytes: maxOutputBytes)
  }

  package func reveal(
    _ url: URL, workingDirectory: URL, timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult {
    try run(
      arguments: ["-R", url.path], workingDirectory: workingDirectory,
      timeoutMilliseconds: timeoutMilliseconds, maxOutputBytes: maxOutputBytes)
  }

  private func run(
    arguments: [String], workingDirectory: URL, timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult {
    try commandRunner.run(
      executable: "/usr/bin/open", arguments: arguments,
      workingDirectory: workingDirectory, environment: [:],
      timeoutMilliseconds: timeoutMilliseconds, maxOutputBytes: maxOutputBytes)
  }
}
