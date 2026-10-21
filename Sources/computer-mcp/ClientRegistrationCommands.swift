import ArgumentParser
import ComputerMCPConfiguration
import ComputerMCPControlPlane
import ComputerMCPCore
import ComputerMCPMacOS
import ComputerMCPPlatform
import Foundation

struct ClientRegistrationOptions: ParsableArguments {
  @Option(name: .long, help: "MCP server name in the client.") var name = "computer-mcp"
  @Option(name: .long, help: "Explicit path to the client CLI (Codex or Claude Code).")
  var clientCLI: String?
  @Flag(name: .long, help: "Print the displayable plan and fingerprint without writing.")
  var dryRun = false
  @Option(
    name: .long,
    help: "Apply only the reviewed dry-run fingerprint; required for a different entry.")
  var expect: String?

  func run(
    client: RegistrationClient, operation: ClientRegistrationOperation,
    server: ClientRegistrationCommand
  ) throws {
    let environment = ProcessInfo.processInfo.environment
    let home =
      environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? FileManager.default.homeDirectoryForCurrentUser
    let service = MacOSPlatform.clientRegistrationService(
      homeDirectory: home, environment: environment)
    try run(client: client, operation: operation, server: server, service: service)
  }

  func run(
    client: RegistrationClient, operation: ClientRegistrationOperation,
    server: ClientRegistrationCommand, service: ClientRegistrationService,
    output: (JSONValue) -> Void = printJSON
  ) throws {
    guard client != .claudeDesktop || clientCLI == nil else {
      throw ValidationError("--client-cli is unavailable for Claude Desktop.")
    }
    do {
      let plan = try service.preview(
        client: client, operation: operation, server: server, name: name, clientCLI: clientCLI)
      if dryRun {
        output(try JSONValue.encoded(plan.display))
        if let refusal = plan.display.refusalCode { throw ExitCode(refusal == .uncertain ? 2 : 1) }
        return
      }
      if let uncertain = plan.uncertainResult {
        output(try JSONValue.encoded(uncertain))
        throw ExitCode(2)
      }
      if let expect, expect != plan.fingerprint {
        throw ClientRegistrationError(.changedSincePreview)
      }
      if let refusal = plan.display.refusalCode { throw ClientRegistrationError(refusal) }
      if plan.display.requiresConfirmation, expect == nil {
        output(
          .object([
            "error_code": .string("confirmation_required"),
            "plan": try JSONValue.encoded(plan.display),
          ]))
        throw ExitCode.failure
      }
      let result = try service.apply(plan)
      output(try JSONValue.encoded(result))
      if result.outcome == .uncertain { throw ExitCode(2) }
      if result.outcome != .succeeded { throw ExitCode.failure }
    } catch let error as ClientRegistrationError {
      output(.object(["error_code": .string(error.code.rawValue)]))
      throw ExitCode(error.code == .uncertain ? 2 : 1)
    }
  }
}

struct ClientInstallOptions: ParsableArguments {
  @OptionGroup var registration: ClientRegistrationOptions
  @Option(
    name: .long, help: "Standalone computer-mcp TOML manifest; validated before registration.")
  var config: String?
  @Flag(name: .long, help: "Register the App-owned bridge.") var app = false
  @Option(name: .long, help: "App Gateway Socket path; requires --app.") var socket: String?
  @Option(name: .long, help: "Path to the computer-mcp server executable.") var serverExecutable:
    String?

  func run(client: RegistrationClient) throws {
    guard app != (config != nil) else {
      throw ValidationError("Pass exactly one of --app or --config.")
    }
    guard app || socket == nil else { throw ValidationError("--socket requires --app.") }
    let executable = try serverExecutable ?? currentExecutableURL().path
    let server: ClientRegistrationCommand
    if let config {
      let configuration = try GatewayConfiguration.load(path: config)
      try configuration.validate()
      server = .standalone(executable: executable, config: config)
    } else {
      server = .app(executable: executable, socket: socket ?? registrationDefaultSocket())
    }
    try registration.run(client: client, operation: .register, server: server)
  }
}

private func registrationDefaultSocket() -> String {
  let home =
    ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser
  return home.appendingPathComponent(
    "Library/Application Support/\(AppDistributionEnvironment.production.applicationSupportDirectoryName)/Runtime/gateway.sock"
  ).path
}

struct ClientUninstallOptions: ParsableArguments {
  @OptionGroup var registration: ClientRegistrationOptions
  func run(client: RegistrationClient) throws {
    try registration.run(
      client: client, operation: .remove,
      server: .app(executable: currentExecutableURL().path, socket: registrationDefaultSocket()))
  }
}

struct InstallCodex: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "codex", abstract: "Register Computer MCP with Codex.")
  @OptionGroup var options: ClientInstallOptions
  func run() throws { try options.run(client: .codex) }
}

struct InstallClaudeCode: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "claude-code", abstract: "Register Computer MCP with Claude Code in user scope.")
  @OptionGroup var options: ClientInstallOptions
  func run() throws { try options.run(client: .claudeCode) }
}

struct InstallClaudeDesktop: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "claude-desktop",
    abstract: "Register Computer MCP with Claude Desktop while it is closed.")
  @OptionGroup var options: ClientInstallOptions
  func run() throws { try options.run(client: .claudeDesktop) }
}

struct UninstallCodex: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "codex", abstract: "Remove the named Codex MCP registration.")
  @OptionGroup var options: ClientUninstallOptions
  func run() throws { try options.run(client: .codex) }
}

struct UninstallClaudeCode: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "claude-code", abstract: "Remove the named Claude Code user MCP registration.")
  @OptionGroup var options: ClientUninstallOptions
  func run() throws { try options.run(client: .claudeCode) }
}

struct UninstallClaudeDesktop: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "claude-desktop",
    abstract: "Remove the named Claude Desktop MCP registration while it is closed.")
  @OptionGroup var options: ClientUninstallOptions
  func run() throws { try options.run(client: .claudeDesktop) }
}
