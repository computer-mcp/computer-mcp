import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPProcess
import ComputerMCPWorktrees
import Foundation

/// Shares configured command resolution and execution across tool domains.
package struct RegisteredCommands: Sendable {
  private let configuration: GatewayConfiguration
  private let launcher: ExecutionLauncher
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
    self.launcher = launcher
    self.configuration = configuration
    self.commandRunner = commandRunner
    self.environment = environment
    self.sqliteCommand = sqliteCommand
    self.builtinExecutables = builtinExecutables
    self.inspectionExecution = CLIProcessExecution(
      launcher: launcher,
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

  package func validateProjectGitLayout(at project: URL) throws {
    let fixed = try PreparedExecutionContext.current()?.fixedHostOperation
    let command = configuration.cli.commands.first { $0.id == "git" }
    try ProjectGitLayout.validate(
      project: project, launcher: launcher,
      environment: environment.merging(command?.env ?? [:]) { _, value in value },
      invocation: try fixed.map { ($0.gitExecutable.value, [String]()) }
        ?? command.map { try resolveHostInvocation($0) })
  }

  package func runHostGit(
    command: CLICommandConfig, args: [String], timeout: Int?, maxOutputBytes: Int? = nil
  ) throws -> CommandResult {
    let prepared = try PreparedExecutionContext.current()
    let fixed = prepared?.fixedHostOperation
    let invocation =
      try fixed.map { (executable: $0.gitExecutable.value, arguments: [String]()) }
      ?? resolveHostInvocation(command)
    let home = try PrivateProcessHome()
    defer { withExtendedLifetime(home) {} }
    let sourceEnvironment =
      fixed == nil ? self.environment.merging(command.env) { _, value in value } : self.environment
    let environment = HostGitConfiguration.environment(home: home.url)
    let directory =
      fixed.map { URL(fileURLWithPath: $0.directory.value) }
      ?? command.resolvedWorkingDirectory(base: configuration.projectDirectory)
    let limit = timeout ?? command.defaultTimeoutMs ?? configuration.policy.defaultTimeoutMs
    func run(
      executable: String, arguments: [String], workingDirectory: URL?,
      environment: [String: String], timeoutMilliseconds: Int, maxOutputBytes: Int,
      writing common: URL? = nil
    ) throws -> CommandResult {
      let body = {
        try commandRunner.runIsolated(
          executable: executable, arguments: arguments, workingDirectory: workingDirectory,
          environment: environment, timeoutMilliseconds: timeoutMilliseconds,
          maxOutputBytes: maxOutputBytes)
      }
      guard let prepared, let fixed else { return try body() }
      return try prepared.withHostGitCommand(
        arguments: arguments, directory: fixed.directory, environment: environment,
        writing: common.map { try .init($0.path) }, body)
    }
    let keys = try run(
      executable: invocation.executable,
      arguments: invocation.arguments + HostGitConfiguration.arguments + [
        "config", "--null", "--name-only", "--list", "--no-includes",
      ],
      workingDirectory: directory, environment: environment,
      timeoutMilliseconds: limit, maxOutputBytes: 1_048_576)
    guard keys.exitCode == 0, !keys.timedOut, !keys.stdoutTruncated else {
      throw GatewayToolError.executionFailed("Cannot inspect Git program configuration.")
    }
    var options: [String]
    do {
      options = try HostGitConfiguration.overrides(for: keys.stdout)
    } catch {
      throw GatewayToolError.executionFailed(error.localizedDescription)
    }
    if let operation = args.first,
      ["commit", "merge", "rebase", "tag", "stash", "cherry-pick", "revert"].contains(operation)
    {
      for key in ["user.name", "user.email"] {
        let identity = try run(
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
    let lock: RepositoryLock?
    let common: URL?
    let mutating: Bool
    switch operation {
    case "branch":
      mutating =
        args.contains("--") || args.contains(where: { ["-m", "-M", "-d", "-D"].contains($0) })
    case "tag": mutating = !args.contains("--list") && !args.contains("-l")
    case "stash": mutating = args.dropFirst().first == "push"
    case "worktree": mutating = args.dropFirst().first != "list"
    case "add", "switch", "checkout", "commit", "reset", "restore", "clean", "merge", "rebase",
      "update-ref", "cherry-pick", "revert":
      mutating = true
    default: mutating = false
    }
    if fixed?.allowsWrites == true || mutating {
      let located = try run(
        executable: invocation.executable,
        arguments: HostGitConfiguration.arguments + [
          "rev-parse", "--path-format=absolute", "--git-common-dir",
        ], workingDirectory: directory, environment: environment,
        timeoutMilliseconds: limit, maxOutputBytes: 65_536)
      guard located.exitCode == 0, !located.timedOut, !located.stdoutTruncated,
        located.stdout.last == "\n", !located.stdout.dropLast().contains("\n")
      else {
        throw GatewayToolError.executionFailed("Cannot identify the Git coordination directory.")
      }
      common = try ProjectPathResolver.canonicalProject(
        URL(fileURLWithPath: String(located.stdout.dropLast())))
      if mutating { try prepared?.pathAccess?.check(common!, operation: .write) }
      lock = try RepositoryLock(
        commonDirectory: common!, owner: .init(bootSessionID: launcher.bootSessionID),
        timeout: .milliseconds(limit),
        checkCancellation: {
          if let prepared {
            _ = try prepared.authority.access(prepared.executionID, operation: .readResult)
          }
          try Task.checkCancellation()
        })
    } else {
      common = nil
      lock = nil
    }
    defer { lock?.release() }
    try lock?.verify()
    return try run(
      executable: invocation.executable,
      arguments: invocation.arguments + HostGitConfiguration.arguments
        + options + pathspecOptions + args,
      workingDirectory: directory, environment: environment,
      timeoutMilliseconds: limit,
      maxOutputBytes: maxOutputBytes ?? configuration.policy.maxOutputBytes, writing: common)
  }

  package func runSQLite(
    command: CLICommandConfig, args: [String], timeout: Int, maxOutputBytes: Int
  ) throws -> CommandResult {
    let invocation = try resolveHostInvocation(command)
    let home = try PrivateProcessHome()
    defer { withExtendedLifetime(home) {} }
    let isolated = ["HOME": home.url.path]
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

  package func resolveHostInvocation(_ command: CLICommandConfig) throws
    -> (executable: String, arguments: [String])
  {
    let invocation = try resolveCLIInvocation(command)
    let inspection = ExecutableInspection.inspect(
      invocation.executable,
      workingDirectory: command.resolvedWorkingDirectory(base: configuration.projectDirectory)
        ?? configuration.projectDirectory,
      environment: environment.merging(command.env) { _, value in value })
    guard !inspection.hasKnownFailure, let executable = inspection.path else {
      throw GatewayToolError.invalidArguments(inspection.message)
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
    if let fixed = try PreparedExecutionContext.current()?.fixedHostOperation {
      return CLICommandConfig(id: "git", executable: fixed.gitExecutable.value)
    }
    guard let command = configuration.cli.commands.first(where: { $0.id == "git" }) else {
      throw GatewayToolError.disabled(
        "git.* tools require a registered CLI provider with id 'git'.")
    }
    return command
  }
}
