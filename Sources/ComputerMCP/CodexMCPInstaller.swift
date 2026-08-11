import Foundation

package struct CodexMCPInstallInvocation: Codable, Equatable, Sendable {
  package var codexCLI: String
  package var arguments: [String]
  package var mcpCommand: [String]

  private enum CodingKeys: String, CodingKey {
    case codexCLI = "codex_cli"
    case arguments
    case mcpCommand = "mcp_command"
  }

  package init(codexCLI: String, arguments: [String], mcpCommand: [String]) {
    self.codexCLI = codexCLI
    self.arguments = arguments
    self.mcpCommand = mcpCommand
  }
}

package enum CodexMCPInstallerError: Error, LocalizedError, Equatable {
  case missingCodexCLI(String)
  case missingServerExecutable(String)

  package var errorDescription: String? {
    switch self {
    case .missingCodexCLI(let name):
      return "Could not find \(name). Install Codex CLI or pass --codex-cli."
    case .missingServerExecutable(let name):
      return "Could not find \(name). Build computer-mcp or pass --server-executable."
    }
  }
}

package struct CodexMCPInstaller: Sendable {
  package var commandRunner: CommandRunning

  package init(commandRunner: CommandRunning = ProcessCommandRunner()) {
    self.commandRunner = commandRunner
  }

  package func plan(
    codexCLI: String?,
    serverName: String,
    configPath: String,
    executablePath: String
  ) throws -> CodexMCPInstallInvocation {
    let resolvedConfigPath = absolutePath(configPath)
    return try makeInvocation(
      codexCLI: codexCLI,
      serverName: serverName,
      executablePath: executablePath,
      serverArguments: ["serve", "--config", resolvedConfigPath]
    )
  }

  package func planApp(
    codexCLI: String?,
    serverName: String,
    executablePath: String
  ) throws -> CodexMCPInstallInvocation {
    try makeInvocation(
      codexCLI: codexCLI,
      serverName: serverName,
      executablePath: executablePath,
      serverArguments: ["bridge", "--client-identity", "local-mcp"]
    )
  }

  package func install(
    codexCLI: String?,
    serverName: String,
    configPath: String,
    executablePath: String
  ) throws -> CommandResult {
    let invocation = try plan(
      codexCLI: codexCLI,
      serverName: serverName,
      configPath: configPath,
      executablePath: executablePath
    )
    return try commandRunner.run(
      executable: invocation.codexCLI,
      arguments: invocation.arguments,
      workingDirectory: nil,
      environment: [:],
      timeoutMilliseconds: 30_000,
      maxOutputBytes: 1_048_576
    )
  }

  package func installApp(
    codexCLI: String?,
    serverName: String,
    executablePath: String
  ) throws -> CommandResult {
    let invocation = try planApp(
      codexCLI: codexCLI,
      serverName: serverName,
      executablePath: executablePath
    )
    return try run(invocation)
  }

  private func makeInvocation(
    codexCLI: String?,
    serverName: String,
    executablePath: String,
    serverArguments: [String]
  ) throws -> CodexMCPInstallInvocation {
    let resolvedCodexCLI = try resolveExecutable(
      codexCLI ?? "codex",
      missing: { .missingCodexCLI($0) }
    )
    let resolvedExecutablePath: String
    if executablePath.contains("/") {
      let absolute = absolutePath(executablePath)
      guard FileManager.default.isExecutableFile(atPath: absolute) else {
        throw CodexMCPInstallerError.missingServerExecutable(executablePath)
      }
      resolvedExecutablePath = absolute
    } else {
      resolvedExecutablePath = try resolveExecutable(
        executablePath,
        missing: { .missingServerExecutable($0) }
      )
    }
    let mcpCommand = [resolvedExecutablePath] + serverArguments
    return CodexMCPInstallInvocation(
      codexCLI: resolvedCodexCLI,
      arguments: ["mcp", "add", serverName, "--"] + mcpCommand,
      mcpCommand: mcpCommand
    )
  }

  private func run(_ invocation: CodexMCPInstallInvocation) throws -> CommandResult {
    try commandRunner.run(
      executable: invocation.codexCLI,
      arguments: invocation.arguments,
      workingDirectory: nil,
      environment: [:],
      timeoutMilliseconds: 30_000,
      maxOutputBytes: 1_048_576
    )
  }

  private func resolveExecutable(
    _ executable: String,
    missing: (String) -> CodexMCPInstallerError
  ) throws -> String {
    if executable.contains("/") {
      guard FileManager.default.isExecutableFile(atPath: executable) else {
        throw missing(executable)
      }
      return absolutePath(executable)
    }
    if let path = findOnPath(executable) {
      return path
    }
    throw missing(executable)
  }

  private func absolutePath(_ path: String) -> String {
    URL(
      fileURLWithPath: path,
      relativeTo: URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath,
        isDirectory: true
      )
    )
    .absoluteURL.path
  }

  private func findOnPath(_ name: String) -> String? {
    let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
      .split(separator: ":")
      .map(String.init)
    for path in paths {
      let candidate = URL(fileURLWithPath: path).appendingPathComponent(name).path
      if FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }
    return nil
  }
}
