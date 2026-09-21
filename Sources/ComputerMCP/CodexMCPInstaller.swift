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
  case unusableExecutable(String, String)

  package var errorDescription: String? {
    switch self {
    case .missingCodexCLI(let name):
      return "Could not find \(name). Install Codex CLI or pass --codex-cli."
    case .missingServerExecutable(let name):
      return "Could not find \(name). Build computer-mcp or pass --server-executable."
    case .unusableExecutable(let name, let message):
      return "Could not use \(name): \(message)"
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
      serverArguments: ["serve", "stdio", "--config", resolvedConfigPath]
    )
  }

  package func planApp(
    codexCLI: String?,
    serverName: String,
    executablePath: String,
    socketPath: String? = nil
  ) throws -> CodexMCPInstallInvocation {
    var serverArguments = ["bridge", "--client-identity", "local-mcp"]
    if let socketPath {
      serverArguments += ["--socket", absolutePath(socketPath)]
    }
    return try makeInvocation(
      codexCLI: codexCLI,
      serverName: serverName,
      executablePath: executablePath,
      serverArguments: serverArguments
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
    executablePath: String,
    socketPath: String? = nil
  ) throws -> CommandResult {
    let invocation = try planApp(
      codexCLI: codexCLI,
      serverName: serverName,
      executablePath: executablePath,
      socketPath: socketPath
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
    let resolvedExecutablePath = try resolveExecutable(
      executablePath, missing: { .missingServerExecutable($0) })
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
    let inspection = ExecutableInspection.inspect(
      executable,
      workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
      environment: ProcessInfo.processInfo.environment)
    guard inspection.exists, let path = inspection.path else { throw missing(executable) }
    guard !inspection.hasKnownFailure else {
      throw CodexMCPInstallerError.unusableExecutable(executable, inspection.message)
    }
    return path
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

}
