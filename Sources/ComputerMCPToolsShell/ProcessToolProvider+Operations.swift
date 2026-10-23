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
        base: environment.configuration.projectDirectory),
      environment: command.env,
      maxOutputBytes: environment.configuration.policy.maxOutputBytes
    )
    return .object([
      "process_id": .string(processID),
      "limits": .object([
        "timeout_ms": .null,
        "output_bytes": .integer(Int64(environment.configuration.policy.maxOutputBytes)),
      ]),
    ])
  }

  internal func listProcesses() throws -> JSONValue {
    .object([
      "processes": .array(try environment.processManager.list().map(\.json))
    ])
  }

  internal func readProcess(arguments object: [String: JSONValue]) throws -> JSONValue {
    let id = try requiredString("process_id", in: object)
    let maxBytes =
      optionalInt("max_bytes", in: object) ?? environment.configuration.policy.maxOutputBytes
    guard (0...environment.configuration.policy.maxOutputBytes).contains(maxBytes) else {
      throw GatewayToolError.invalidArguments(
        "max_bytes must be between 0 and policy.max_output_bytes.")
    }
    return try environment.processManager.read(
      processID: id,
      stdoutCursor: Int64(optionalInt("stdout_cursor", in: object) ?? 0),
      stderrCursor: Int64(optionalInt("stderr_cursor", in: object) ?? 0),
      maxReadBytes: maxBytes
    ).json
  }

  internal func writeProcess(arguments object: [String: JSONValue]) throws -> JSONValue {
    let id = try requiredString("process_id", in: object)
    let text = object["text"]?.stringValue
    let base64 = object["base64"]?.stringValue
    guard text == nil || base64 == nil else {
      throw GatewayToolError.invalidArguments("Provide only one of text or base64.")
    }
    let data: Data
    if let base64 {
      guard let decoded = Data(base64Encoded: base64) else {
        throw GatewayToolError.invalidArguments("base64 is not valid Base64 data.")
      }
      data = decoded
    } else {
      data = Data((text ?? "").utf8)
    }
    guard data.count <= environment.configuration.policy.maxShellInputBytes else {
      throw GatewayToolError.invalidArguments("Input exceeds policy.max_shell_input_bytes.")
    }
    let result = try environment.processManager.write(
      processID: id, data: data,
      close: object["close"]?.boolValue ?? false)
    return .object([
      "process_id": .string(id), "bytes_written": .number(Double(result.bytesWritten)),
      "input_closed": .bool(result.inputClosed),
    ])
  }

  internal func cancelProcess(arguments object: [String: JSONValue]) throws -> JSONValue {
    let id = try requiredString("process_id", in: object)
    return try environment.processManager.cancel(processID: id).json
  }
}
