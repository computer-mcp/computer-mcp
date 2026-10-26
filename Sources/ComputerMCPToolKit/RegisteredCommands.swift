import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPProcess
import Foundation

/// Shares configured command resolution and execution across tool domains.
package struct RegisteredCommands: Sendable {
  private let configuration: GatewayConfiguration
  private let commandRunner: any CommandRunning
  private let environment: [String: String]
  private let builtinExecutables: [String: String]
  private let sqliteCommand: CLICommandConfig?
  package let execution: CLIProcessExecution

  package init(
    configuration: GatewayConfiguration, commandRunner: any CommandRunning,
    environment: [String: String], sqliteCommand: CLICommandConfig? = nil,
    builtinExecutables: [String: String] = [:]
  ) {
    self.configuration = configuration
    self.commandRunner = commandRunner
    self.environment = environment
    self.sqliteCommand = sqliteCommand
    self.builtinExecutables = builtinExecutables
    self.execution = CLIProcessExecution(
      maxConcurrentCalls: configuration.policy.maxShellSessions, inheritsEnvironment: false)
  }

  package func runRegisteredCLI(
    command: CLICommandConfig,
    args: [String],
    timeout: Int?,
    requireArbitraryArgs: Bool,
    maxOutputBytes: Int? = nil
  ) throws -> CommandResult {
    if requireArbitraryArgs && (!command.allowAnyArgs || command.tree != nil) {
      throw GatewayToolError.disabled(
        "CLI command '\(command.id)' does not allow arbitrary args.")
    }

    let invocation = try resolveCLIInvocation(command)
    return try commandRunner.run(
      executable: invocation.executable,
      arguments: invocation.arguments + args,
      workingDirectory: command.resolvedWorkingDirectory(base: configuration.projectDirectory),
      environment: command.env,
      timeoutMilliseconds: timeout ?? command.defaultTimeoutMs
        ?? configuration.policy.defaultTimeoutMs,
      maxOutputBytes: maxOutputBytes ?? configuration.policy.maxOutputBytes
    )
  }

  package func validateProjectGitLayout(at project: URL) throws {
    let command = configuration.cli.commands.first { $0.id == "git" }
    try ProjectGitLayout.validate(
      project: project,
      environment: environment.merging(command?.env ?? [:]) { _, value in value },
      invocation: command.map { try resolveCLIInvocation($0) })
  }

  package func runHostGit(
    command: CLICommandConfig, args: [String], timeout: Int?, maxOutputBytes: Int? = nil
  ) throws -> CommandResult {
    let invocation = try resolveCLIInvocation(command)
    let home = try PrivateProcessHome()
    defer { withExtendedLifetime(home) {} }
    let sourceEnvironment = self.environment.merging(command.env) { _, value in value }
    let environment = HostGitConfiguration.environment(
      sourceEnvironment, home: home.url)
    let directory = command.resolvedWorkingDirectory(base: configuration.projectDirectory)
    let limit = timeout ?? command.defaultTimeoutMs ?? configuration.policy.defaultTimeoutMs
    let keys = try commandRunner.runIsolated(
      executable: invocation.executable,
      arguments: invocation.arguments + HostGitConfiguration.arguments + [
        "config", "--null", "--name-only", "--list", "--no-includes",
      ],
      workingDirectory: directory, environment: environment,
      timeoutMilliseconds: limit, maxOutputBytes: 1_048_576)
    guard keys.exitCode == 0, !keys.timedOut, !keys.stdoutTruncated else {
      throw GatewayToolError.executionFailed("Cannot inspect Git program configuration.")
    }
    var options = try HostGitConfiguration.overrides(for: keys.stdout)
    if let operation = args.first,
      ["commit", "merge", "rebase", "tag", "stash", "cherry-pick", "revert"].contains(operation)
    {
      for key in ["user.name", "user.email"] {
        let identity = try commandRunner.runIsolated(
          executable: invocation.executable,
          arguments: invocation.arguments + HostGitConfiguration.arguments
            + ["config", "--null", "--get", key],
          workingDirectory: directory,
          environment: HostGitConfiguration.identityEnvironment(sourceEnvironment),
          timeoutMilliseconds: limit, maxOutputBytes: 65_536)
        guard !identity.timedOut, !identity.stdoutTruncated,
          identity.exitCode == 0 || identity.exitCode == 1
        else { throw GatewayToolError.executionFailed("Cannot read Git author identity.") }
        if identity.exitCode == 0 {
          options += ["-c", "\(key)=\(String(identity.stdout.dropLast()))"]
        }
      }
    }
    let operation = args.drop(while: { $0 == "--no-optional-locks" }).first
    let takesPathspecs =
      operation.map {
        [
          "add", "blame", "checkout", "clean", "commit", "diff", "grep", "log", "ls-files",
          "ls-tree", "reset", "restore", "rm", "show", "status",
        ].contains($0)
      } ?? false
    let stashPaths = args.starts(with: ["stash", "push"]) || args.starts(with: ["stash", "show"])
    let pathspecOptions = takesPathspecs || stashPaths ? ["--literal-pathspecs"] : []
    return try commandRunner.runIsolated(
      executable: invocation.executable,
      arguments: invocation.arguments + HostGitConfiguration.arguments
        + options + pathspecOptions + args,
      workingDirectory: directory, environment: environment,
      timeoutMilliseconds: limit,
      maxOutputBytes: maxOutputBytes ?? configuration.policy.maxOutputBytes)
  }

  package func runSQLite(
    command: CLICommandConfig, args: [String], timeout: Int, maxOutputBytes: Int
  ) throws -> CommandResult {
    let invocation = try resolveCLIInvocation(command)
    let home = try PrivateProcessHome()
    defer { withExtendedLifetime(home) {} }
    var isolated = environment.merging(command.env) { _, value in value }
    isolated["HOME"] = home.url.path
    return try commandRunner.runIsolated(
      executable: invocation.executable,
      arguments: invocation.arguments + ["-init", "/dev/null", "-safe"] + args,
      workingDirectory: command.resolvedWorkingDirectory(base: configuration.projectDirectory),
      environment: isolated, timeoutMilliseconds: timeout, maxOutputBytes: maxOutputBytes)
  }

  package func resolveCLIInvocation(_ command: CLICommandConfig) throws
    -> (executable: String, arguments: [String])
  {
    guard !command.interpreterBindings.isEmpty else { return (command.executable, []) }
    let invocation = ExecutableInspection.invocation(
      command.executable,
      workingDirectory: command.resolvedWorkingDirectory(base: configuration.projectDirectory)
        ?? configuration.projectDirectory,
      environment: environment.merging(command.env) { _, value in value },
      interpreterBindings: command.interpreterBindings)
    guard !invocation.inspection.hasKnownFailure, let executable = invocation.executable else {
      throw GatewayToolError.invalidArguments(invocation.inspection.message)
    }
    return (executable, invocation.arguments)
  }

  package func resolveExecutable(_ executable: String, command: CLICommandConfig)
    -> ExecutableInspection
  {
    ExecutableInspection.invocation(
      executable,
      workingDirectory: command.resolvedWorkingDirectory(base: configuration.projectDirectory)
        ?? configuration.projectDirectory,
      environment: environment.merging(command.env) { _, value in value },
      interpreterBindings: command.interpreterBindings
    ).inspection
  }

  package func resolveExecutable(
    _ executable: String, base: URL?, defaultBase: URL, overrides: [String: String]
  ) -> ExecutableInspection {
    ExecutableInspection.inspect(
      executable, workingDirectory: base ?? defaultBase,
      environment: environment.merging(overrides) { _, value in value })
  }

  package func builtinExecutable(_ name: String) throws -> String {
    guard let executable = builtinExecutables[name] else {
      throw GatewayToolError.disabled("Builtin command '\(name)' is unavailable on this platform.")
    }
    return executable
  }

  package func sqliteCLICommand() throws -> CLICommandConfig {
    guard let sqliteCommand else {
      throw GatewayToolError.disabled("SQLite inspection is unavailable on this platform.")
    }
    return sqliteCommand
  }

  package func gitCLICommand() throws -> CLICommandConfig {
    guard let command = configuration.cli.commands.first(where: { $0.id == "git" }) else {
      throw GatewayToolError.disabled(
        "git.* tools require a registered CLI provider with id 'git'.")
    }
    return command
  }
}
