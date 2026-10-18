import Foundation

extension GatewayToolRegistry {
  internal func spawnProcess(arguments object: [String: JSONValue]) throws -> JSONValue {
    guard object["args"] == nil else {
      throw GatewayToolError.invalidArguments("Unknown argument 'args'; use 'argv'.")
    }
    let id = try requiredString("id", in: object)
    guard let command = configuration.cli.commands.first(where: { $0.id == id }) else {
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
    let invocation = try resolveCLIInvocation(command)
    let processID = try processManager.spawn(
      executable: invocation.executable,
      arguments: invocation.arguments + args,
      workingDirectory: command.resolvedWorkingDirectory(base: configuration.workspaceDirectory),
      environment: command.env,
      maxOutputBytes: configuration.policy.maxOutputBytes
    )
    return .object(["process_id": .string(processID)])
  }

  internal func listProcesses() throws -> JSONValue {
    .object([
      "processes": .array(try processManager.list().map(\.json))
    ])
  }

  internal func readProcess(arguments object: [String: JSONValue]) throws -> JSONValue {
    let id = try requiredString("process_id", in: object)
    return try processManager.read(processID: id).json
  }

  internal func cancelProcess(arguments object: [String: JSONValue]) throws -> JSONValue {
    let id = try requiredString("process_id", in: object)
    return try processManager.cancel(processID: id).json
  }
}
