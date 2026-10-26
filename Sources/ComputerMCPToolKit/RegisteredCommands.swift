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
  package let inspectionExecution: CLIProcessExecution

  package init(
    configuration: GatewayConfiguration, launcher: ExecutionLauncher = ExecutionLauncher(),
    commandRunner: any CommandRunning,
    environment: [String: String], sqliteCommand: CLICommandConfig? = nil,
    builtinExecutables: [String: String] = [:]
  ) {
    self.configuration = configuration
    self.commandRunner = commandRunner
    self.environment = environment
    self.sqliteCommand = sqliteCommand
    self.builtinExecutables = builtinExecutables
    self.inspectionExecution = CLIProcessExecution(
      launcher: launcher, policy: .readOnly,
      maxConcurrentCalls: configuration.policy.maxShellSessions, inheritsEnvironment: false)
    self.execution = CLIProcessExecution(
      launcher: launcher, maxConcurrentCalls: configuration.policy.maxShellSessions,
      inheritsEnvironment: false)
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
