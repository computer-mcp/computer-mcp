import ComputerMCPCore
import ComputerMCPToolKit
import Foundation

extension ProcessToolProvider {
  internal func requireCLIProviders() throws {
    guard !environment.configuration.cli.commands.isEmpty else {
      throw GatewayToolError.disabled("CLI gateway tools require at least one configured provider.")
    }
  }

  internal func spawnProcess(arguments object: [String: JSONValue]) throws -> JSONValue {
    guard object["args"] == nil else {
      throw GatewayToolError.invalidArguments("Unknown argument 'args'; use 'argv'.")
    }
    let id = try requiredString("id", in: object)
    guard let command = environment.configuration.cli.commands.first(where: { $0.id == id }) else {
      throw GatewayToolError.unknownCLI(id)
    }
    guard command.allowAnyArgs, command.tree == nil else {
      throw GatewayToolError.disabled(
        "CLI command '\(command.id)' does not allow arbitrary args.")
    }
    guard object["argv"] != nil else {
      throw GatewayToolError.invalidArguments("Missing required 'argv'.")
    }
    let args = try optionalStringArray("argv", in: object)
    let invocation = try environment.registeredCommands.resolveCLIInvocation(command)
    let processID = try environment.processManager.spawn(
      executable: invocation.executable,
      arguments: invocation.arguments + args,
      workingDirectory: command.resolvedWorkingDirectory(
        base: environment.configuration.workspaceDirectory),
      environment: command.env,
      maxOutputBytes: environment.configuration.policy.maxOutputBytes
    )
    return .object(["process_id": .string(processID)])
  }

  internal func listProcesses() throws -> JSONValue {
    .object([
      "processes": .array(try environment.processManager.list().map(\.json))
    ])
  }

  internal func readProcess(arguments object: [String: JSONValue]) throws -> JSONValue {
    let id = try requiredString("process_id", in: object)
    return try environment.processManager.read(processID: id).json
  }

  internal func cancelProcess(arguments object: [String: JSONValue]) throws -> JSONValue {
    let id = try requiredString("process_id", in: object)
    return try environment.processManager.cancel(processID: id).json
  }
}
