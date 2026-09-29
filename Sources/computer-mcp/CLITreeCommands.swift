import ArgumentParser
import ComputerMCP
import Foundation

struct CLITreeCommands: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "cli-tree",
    abstract: "Validate canonical CLI Tree JSON and check executable compatibility.",
    subcommands: [CLITreeValidate.self, CLITreeCheck.self])
}

struct CLITreeValidationOptions: ParsableArguments {
  @Argument(help: "Path to a canonical CLI Tree JSON file (maximum 4 MiB).") var file: String
  @Option(name: .long, help: "Require this exact executable_version metadata value.")
  var expectedVersion: String?
}

struct CLITreeValidate: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "validate",
    abstract: "Validate a tree without executing any commands; emit versioned JSON diagnostics.")
  @OptionGroup var options: CLITreeValidationOptions

  func run() throws {
    let report = CLITreeValidation.validate(
      file: URL(fileURLWithPath: options.file), expectedVersion: options.expectedVersion)
    printJSON(try JSONValue.encoded(report))
    if !report.valid { throw ExitCode.failure }
  }
}

struct CLITreeCheck: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "check",
    abstract: "Run a reviewed tree's declared executable checks; emit JSON and fail on drift.",
    discussion:
      "Runs only executable_checks, with empty stdin, a shared five-second deadline and bounded output. Review those arguments before use. This does not execute command nodes or prove undeclared coverage."
  )
  @OptionGroup var options: CLITreeValidationOptions
  @Option(name: .long, help: "Executable to check against the tree's exact output assertions.")
  var executable: String
  @Option(
    name: .long, help: "Working directory for declared checks (defaults to the current directory).")
  var workingDirectory: String?

  func run() async throws {
    let report = await CLITreeValidation.check(
      file: URL(fileURLWithPath: options.file), executable: executable,
      workingDirectory: URL(
        fileURLWithPath: workingDirectory ?? FileManager.default.currentDirectoryPath),
      expectedVersion: options.expectedVersion)
    printJSON(try JSONValue.encoded(report))
    if !report.valid { throw ExitCode.failure }
  }
}
