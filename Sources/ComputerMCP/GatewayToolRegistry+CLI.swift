import Foundation

extension GatewayToolRegistry {
  internal func requireCLIProviders() throws {
    guard !configuration.cli.commands.isEmpty else {
      throw GatewayToolError.disabled("CLI gateway tools require at least one configured provider.")
    }
  }

  internal func cliList() -> JSONValue {
    .array(
      configuration.cli.commands.map { command in
        .object([
          "id": .string(command.id),
          "executable": .string(command.executable),
          "description": .string(command.description ?? ""),
          "risk": .string(command.risk ?? "unspecified"),
          "discovery": .array(command.discovery.map { .string($0) }),
          "has_interface": .bool(command.interface != nil),
          "has_tree": .bool(command.tree != nil),
        ])
      })
  }

  internal func cliDescribe(arguments object: [String: JSONValue]) throws -> JSONValue {
    let id = try requiredString("id", in: object)
    let command = try registeredCLICommand(id)
    return cliDescription(command)
  }

  internal func cliStatus(arguments object: [String: JSONValue]) throws -> JSONValue {
    let id = try optionalString("id", in: object)
    let commands: [CLICommandConfig]
    if let id {
      commands = [try registeredCLICommand(id)]
    } else {
      commands = configuration.cli.commands
    }

    return .object([
      "commands": .array(commands.map { cliExecutableStatus($0) })
    ])
  }

  internal func runCLIHelp(arguments object: [String: JSONValue]) throws -> JSONValue {
    guard object["args"] == nil else {
      throw GatewayToolError.invalidArguments("Unknown argument 'args'; use 'path'.")
    }
    let id = try requiredString("id", in: object)
    let command = try registeredCLICommand(id)
    let path = try optionalStringArray("path", in: object)
    if let source = command.tree {
      guard source.kind == .file else {
        throw GatewayToolError.disabled(
          "This CLI uses an executable interface exporter; use its projected tools and catalog metadata."
        )
      }
      let tree = try source.load(
        command: command, workspace: configuration.workspaceDirectory, execution: cliExecution)
      guard let node = tree.commands.first(where: { $0.path == path }) else {
        throw GatewayToolError.invalidArguments("The path is not in the declared CLI tree.")
      }
      // cli.help is read-only. Publisher-provided help argv is metadata, not an
      // authority to execute arbitrary code through a discovery capability.
      return .object([
        "id": .string(command.id), "path": .array(path.map(JSONValue.string)),
        "description": .string(node.description), "input_schema": node.inputSchema,
        "help_argv": node.helpArgv.map { .array($0.map(JSONValue.string)) } ?? .null,
        "executed": .bool(false), "coverage": .string(tree.coverage.rawValue),
      ])
    }
    var helpArgv = path
    if helpArgv.last != "--help" && helpArgv.last != "-h" {
      helpArgv.append("--help")
    }

    let result = try runRegisteredCLI(
      command: command,
      args: helpArgv,
      timeout: optionalInt("timeout_ms", in: object),
      requireArbitraryArgs: false
    )
    return .object([
      "id": .string(command.id),
      "path": .array(path.map { .string($0) }),
      "help_argv": .array(helpArgv.map { .string($0) }),
      "exec_context": .object([
        "tool": .string("cli.exec"),
        "id": .string(command.id),
        "argv_prefix": .array(path.map { .string($0) }),
      ]),
      "interface": command.interface?.json ?? .null,
      "stdout": .string(result.stdout),
      "stderr": .string(result.stderr),
      "exit_code": result.exitCode.map { .integer(Int64($0)) } ?? .null,
    ])
  }

  internal func runCLIExec(arguments object: [String: JSONValue]) throws -> JSONValue {
    let id = try requiredString("id", in: object)
    let args = try requiredStringArray("argv", in: object)
    let command = try registeredCLICommand(id)
    return try runRegisteredCLI(
      command: command,
      args: args,
      timeout: optionalInt("timeout_ms", in: object),
      requireArbitraryArgs: true
    )
    .json
  }

  private func registeredCLICommand(_ id: String) throws -> CLICommandConfig {
    guard let command = configuration.cli.commands.first(where: { $0.id == id }) else {
      throw GatewayToolError.unknownCLI(id)
    }
    return command
  }

  internal func runRegisteredCLI(
    command: CLICommandConfig,
    args: [String],
    timeout: Int?,
    requireArbitraryArgs: Bool
  ) throws -> CommandResult {
    if requireArbitraryArgs && (!command.allowAnyArgs || command.tree != nil) {
      throw GatewayToolError.disabled(
        "CLI command '\(command.id)' does not allow arbitrary args.")
    }

    let invocation = try resolveCLIInvocation(command)
    return try commandRunner.run(
      executable: invocation.executable,
      arguments: invocation.arguments + args,
      workingDirectory: command.resolvedWorkingDirectory(base: configuration.workspaceDirectory),
      environment: command.env,
      timeoutMilliseconds: timeout ?? command.defaultTimeoutMs
        ?? configuration.policy.defaultTimeoutMs,
      maxOutputBytes: configuration.policy.maxOutputBytes
    )
  }

  private func cliDescription(_ command: CLICommandConfig) -> JSONValue {
    .object([
      "id": .string(command.id),
      "executable": .string(command.executable),
      "description": .string(command.description ?? ""),
      "cwd": command.cwd.map(JSONValue.string) ?? .null,
      "allow_any_args": .bool(command.allowAnyArgs),
      "risk": .string(command.risk ?? "unspecified"),
      "discovery": .array(command.discovery.map { .string($0) }),
      "has_interface": .bool(command.interface != nil),
      "interface": command.interface?.json ?? .null,
      "tree": command.tree.flatMap { try? JSONValue.encoded($0) } ?? .null,
    ])
  }

  internal func validateExecutableLookupName(_ name: String) throws {
    try validateUTF8ByteLimit(name, name: "name", maxBytes: 128)
    guard !name.isEmpty else {
      throw GatewayToolError.invalidArguments("name must not be empty.")
    }
    guard !name.hasPrefix("-") else {
      throw GatewayToolError.invalidArguments("name must not start with an option marker.")
    }
    guard name != "." && name != ".." else {
      throw GatewayToolError.invalidArguments("name must be an executable basename.")
    }
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._+@-")
    guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
      throw GatewayToolError.invalidArguments(
        "name must be an executable basename without slashes or whitespace.")
    }
  }

  private func cliExecutableStatus(_ command: CLICommandConfig) -> JSONValue {
    let resolved = resolveExecutable(command.executable, command: command)
    return .object([
      "id": .string(command.id),
      "executable": .string(command.executable),
      "exists": .bool(resolved.exists),
      "is_executable": .bool(resolved.isExecutable),
      "resolved_path": resolved.path.map(JSONValue.string) ?? .null,
      "resolution_source": .string(resolved.source),
      "resolution": executableResolutionJSON(resolved),
      "cwd": command.resolvedWorkingDirectory(base: configuration.workspaceDirectory)
        .map { .string($0.standardizedFileURL.path) } ?? .null,
      "risk": .string(command.risk ?? "unspecified"),
      "has_interface": .bool(command.interface != nil),
    ])
  }

  internal func resolveExecutable(_ executable: String, command: CLICommandConfig)
    -> ExecutableInspection
  {
    ExecutableInspection.invocation(
      executable,
      workingDirectory: command.resolvedWorkingDirectory(base: configuration.workspaceDirectory)
        ?? configuration.workspaceDirectory,
      environment: environment.merging(command.env) { _, value in value },
      interpreterBindings: command.interpreterBindings
    ).inspection
  }

  internal func resolveCLIInvocation(_ command: CLICommandConfig) throws
    -> (executable: String, arguments: [String])
  {
    guard !command.interpreterBindings.isEmpty else { return (command.executable, []) }
    let invocation = ExecutableInspection.invocation(
      command.executable,
      workingDirectory: command.resolvedWorkingDirectory(base: configuration.workspaceDirectory)
        ?? configuration.workspaceDirectory,
      environment: environment.merging(command.env) { _, value in value },
      interpreterBindings: command.interpreterBindings)
    guard !invocation.inspection.hasKnownFailure, let executable = invocation.executable else {
      throw GatewayToolError.invalidArguments(invocation.inspection.message)
    }
    return (executable, invocation.arguments)
  }

  internal func resolveExecutable(
    _ executable: String, base: URL?, defaultBase: URL, overrides: [String: String]
  ) -> ExecutableInspection {
    ExecutableInspection.inspect(
      executable, workingDirectory: base ?? defaultBase,
      environment: environment.merging(overrides) { _, value in value })
  }

  internal func executableResolutionJSON(_ resolution: ExecutableInspection) -> JSONValue {
    resolution.json
  }

  internal func pathExecutables(_ executable: String, allMatches: Bool) -> [String] {
    var matches: [String] = []
    var seen = Set<String>()
    for directory in pathSearchDirectories() {
      let candidate = URL(fileURLWithPath: directory).appendingPathComponent(executable).path
      guard FileManager.default.isExecutableFile(atPath: candidate) else {
        continue
      }
      guard seen.insert(candidate).inserted else {
        continue
      }
      matches.append(candidate)
      if !allMatches {
        break
      }
    }
    return matches
  }

  internal func pathSearchDirectories() -> [String] {
    let pathValue =
      environment["PATH"]
      ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    return pathValue.split(separator: ":").map(String.init).filter { !$0.isEmpty }
  }
}
