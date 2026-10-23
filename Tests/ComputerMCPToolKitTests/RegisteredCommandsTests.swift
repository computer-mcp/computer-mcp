import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPProcess
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

struct RegisteredCommandsTests {
  @Test(arguments: [0, 1, 2])
  func commandExecutionKeepsArgvWorkingDirectoryEnvironmentAndTimeoutPrecedence(level: Int)
    async throws
  {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url
    let argv = ["", "空 格;$(no-execution)", "--", "-1"]
    let expected = Self.result
    let runner = InspectingCommandRunner {
      executable, arguments, cwd, environment, timeout, maxBytes in
      #expect(executable == "registered-tool")
      #expect(arguments == argv)
      #expect(cwd?.path == root.appendingPathComponent("child").path)
      #expect(environment == ["OVERRIDE": "child"])
      #expect(timeout == [3_000, 2_000, 1_000][level])
      #expect(maxBytes == 2_048)
      return expected
    }
    let command = CLICommandConfig(
      id: "tool", executable: "registered-tool", cwd: "child", env: ["OVERRIDE": "child"],
      defaultTimeoutMs: level >= 1 ? 2_000 : nil)
    let commands = RegisteredCommands(
      configuration: .init(
        policy: .init(defaultTimeoutMs: 3_000, maxOutputBytes: 2_048),
        cli: .init(commands: [command]), projectDirectory: root),
      commandRunner: runner, environment: ["HOST": "host"])
    #expect(
      try commands.runRegisteredCLI(
        command: command, args: argv, timeout: level == 2 ? 1_000 : nil,
        requireArbitraryArgs: true) == expected)
    await commands.execution.shutdown()
  }

  @Test(arguments: [false, true])
  func arbitraryArgsAreRefusedBeforeExecution(tree: Bool) async throws {
    let runner = InspectingCommandRunner { _, _, _, _, _, _ in
      Issue.record("A refused registration reached the command runner.")
      return Self.result
    }
    let command = CLICommandConfig(
      id: "guarded", executable: "tool", allowAnyArgs: tree,
      tree: tree ? .init(kind: .file, path: "tree.json") : nil)
    let commands = RegisteredCommands(
      configuration: .init(), commandRunner: runner, environment: [:])
    #expect(
      throws: GatewayToolError.disabled("CLI command 'guarded' does not allow arbitrary args.")
    ) {
      try commands.runRegisteredCLI(
        command: command, args: [], timeout: nil, requireArbitraryArgs: true)
    }
    await commands.execution.shutdown()
  }

  @Test
  func discoveryMayExecuteHelpWithoutArbitraryArgsPermission() async throws {
    let commands = RegisteredCommands(
      configuration: .init(),
      commandRunner: InspectingCommandRunner { _, arguments, _, _, _, _ in
        #expect(arguments == ["--help"])
        return Self.result
      }, environment: [:])
    _ = try commands.runRegisteredCLI(
      command: .init(id: "tool", executable: "tool", allowAnyArgs: false), args: ["--help"],
      timeout: nil, requireArbitraryArgs: false)
    await commands.execution.shutdown()
  }

  @Test
  func interpreterValidationIsConditionalOnBindingsAndPreservesInspectionErrors() async throws {
    let temporary = try ScopedTemporaryDirectory()
    let script = temporary.url.appendingPathComponent("script")
    try "#!/missing/interpreter\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    var command = CLICommandConfig(id: "script", executable: script.path)
    let commands = RegisteredCommands(
      configuration: .init(projectDirectory: temporary.url),
      commandRunner: InspectingCommandRunner { _, _, _, _, _, _ in Self.result }, environment: [:])
    #expect(try commands.resolveCLIInvocation(command).executable == script.path)
    #expect(try commands.resolveCLIInvocation(command).arguments.isEmpty)
    command.interpreterBindings = ["runtime": "/bin/sh"]
    let inspection = commands.resolveExecutable(script.path, command: command)
    #expect(inspection.hasKnownFailure)
    #expect(throws: GatewayToolError.invalidArguments(inspection.message)) {
      try commands.resolveCLIInvocation(command)
    }
    await commands.execution.shutdown()
  }

  @Test
  func executableLookupUsesOverridesAndDeduplicatesPathMatches() async throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url.resolvingSymlinksInPath()
    let first = root.appendingPathComponent("first")
    let second = root.appendingPathComponent("second")
    for directory in [first, second] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try FileManager.default.copyItem(
        at: URL(fileURLWithPath: "/bin/sh").resolvingSymlinksInPath(),
        to: directory.appendingPathComponent("tool"))
    }
    let environment = ["PATH": "\(first.path):\(first.path):\(second.path)"]
    #expect(
      pathExecutables("tool", allMatches: false, environment: environment)
        == [first.appendingPathComponent("tool").path])
    #expect(
      pathExecutables("tool", allMatches: true, environment: environment)
        == [first.appendingPathComponent("tool").path, second.appendingPathComponent("tool").path])
    let commands = RegisteredCommands(
      configuration: .init(projectDirectory: root),
      commandRunner: InspectingCommandRunner { _, _, _, _, _, _ in Self.result },
      environment: environment)
    let resolved = commands.resolveExecutable(
      "tool", base: nil, defaultBase: root, overrides: ["PATH": second.path])
    #expect(resolved.path == second.appendingPathComponent("tool").path)
    #expect(resolved.status == .passed)
    let resolvedPath = try #require(resolved.path)
    #expect(
      executableResolutionJSON(resolved).objectValue?["resolved_path"] == .string(resolvedPath))
    let relative = commands.resolveExecutable(
      "./tool", command: .init(id: "tool", executable: "./tool", cwd: "first"))
    #expect(relative.path == first.appendingPathComponent("tool").path)
    await commands.execution.shutdown()
  }

  @Test
  func gitSelectionUsesTheConfiguredRegistrationAndKeepsMissingProviderError() async throws {
    let git = CLICommandConfig(id: "git", executable: "custom-git")
    let runner = InspectingCommandRunner { _, _, _, _, _, _ in Self.result }
    let commands = RegisteredCommands(
      configuration: .init(cli: .init(commands: [git])), commandRunner: runner, environment: [:])
    #expect(try commands.gitCLICommand() == git)
    let missing = RegisteredCommands(
      configuration: .init(), commandRunner: runner, environment: [:])
    #expect(
      throws: GatewayToolError.disabled(
        "git.* tools require a registered CLI provider with id 'git'.")
    ) {
      try missing.gitCLICommand()
    }
    await commands.execution.shutdown()
    await missing.execution.shutdown()
  }

  private static let result = CommandResult(
    executable: "tool", arguments: [], exitCode: 7, timedOut: false, stdout: "output",
    stderr: "error", stdoutTruncated: true, stderrTruncated: false)
}

private struct InspectingCommandRunner: CommandRunning {
  var body: @Sendable (String, [String], URL?, [String: String], Int, Int) throws -> CommandResult

  func run(
    executable: String, arguments: [String], workingDirectory: URL?, environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult {
    try body(
      executable, arguments, workingDirectory, environment, timeoutMilliseconds, maxOutputBytes)
  }

  func runData(
    executable: String, arguments: [String], workingDirectory: URL?, environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandDataResult {
    throw UnexpectedDataRequest()
  }

  private struct UnexpectedDataRequest: Error {}
}
