import CryptoKit
import Foundation

/// Each instance is one immutable catalog generation. The router replaces definitions,
/// capabilities, and this provider together after a complete validated reload.
struct CLITreeToolProvider: GatewayToolProvider {
  let registration: CLICommandConfig
  let tree: CLITree
  let workspace: URL
  let execution: CLIProcessExecution
  let timeoutMilliseconds: Int
  let maxOutputBytes: Int

  var id: String { "cli-tree:\(registration.id)" }

  func listTools() throws -> [MCPTool] {
    tree.commands.filter(\.executable).map { command in
      MCPTool(
        name: toolName(command), title: ([registration.id] + command.path).joined(separator: " "),
        description: command.description, inputSchema: command.inputSchema,
        outputSchema: resultSchema(command),
        meta: .object([
          "cli": .object([
            "registration": .string(registration.id), "command": .string(command.id),
            "path": .array(command.path.map(JSONValue.string)),
            "source": .string(tree.source), "executable_version": .string(tree.executableVersion),
            "coverage": .string(tree.coverage.rawValue),
            "omissions": .array(tree.omissions.map(JSONValue.string)),
            "executable_check_count": .number(Double(tree.executableChecks.count)),
            "compatibility": .string(
              tree.executableChecks.isEmpty ? "not_declared" : "required_before_call"),
          ])
        ]))
    }
  }

  func capability(for tool: MCPTool) -> CapabilityDescriptor {
    // A tree is publisher input. Execution keeps the same host Full Shell boundary
    // as registered cli.exec, independently of a publisher's risk hint.
    CapabilityDescriptor(id: tool.name, risk: .fullShell, workspaceRequirement: .required)
  }

  func callTool(name: String, arguments: JSONValue?) throws -> JSONValue {
    let command = try command(named: name)
    let invocation = try CLIArgumentEncoder.encode(arguments ?? .object([:]), command: command)
    let result = try execution.run(
      executable: registration.executable, invocation: invocation,
      cwd: registration.resolvedWorkingDirectory(base: workspace) ?? workspace,
      environment: registration.env, timeoutMilliseconds: timeoutMilliseconds,
      maxOutputBytes: maxOutputBytes, executableChecks: tree.executableChecks)
    return try response(result, command: command)
  }

  func callToolAsync(name: String, arguments: JSONValue?) async throws -> JSONValue {
    let command = try command(named: name)
    let invocation = try CLIArgumentEncoder.encode(arguments ?? .object([:]), command: command)
    let result = try await execution.runAsync(
      executable: registration.executable, invocation: invocation,
      cwd: registration.resolvedWorkingDirectory(base: workspace) ?? workspace,
      environment: registration.env, timeoutMilliseconds: timeoutMilliseconds,
      maxOutputBytes: maxOutputBytes, executableChecks: tree.executableChecks)
    return try response(result, command: command)
  }

  private func command(named name: String) throws -> CLICommandDescriptor {
    guard let command = tree.commands.first(where: { $0.executable && toolName($0) == name }) else {
      throw GatewayToolError.unknownTool(name)
    }
    return command
  }

  private func toolName(_ command: CLICommandDescriptor) -> String {
    let registrationID = Data(SHA256.hash(data: Data(registration.id.utf8)))
      .base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return "cli_\(registrationID)_\(command.id)"
  }

  private func resultSchema(_ command: CLICommandDescriptor) -> JSONValue {
    var properties: [String: JSONValue] = [:]
    if let schema = command.outputSchema { properties["data"] = schema }
    return .object([
      "type": .string("object"),
      "properties": .object([
        "result": .object([
          "type": .string("object"), "properties": .object(properties),
        ])
      ]), "required": .array([.string("result")]),
    ])
  }

  private func response(_ result: ShellSessionSnapshot, command: CLICommandDescriptor) throws
    -> JSONValue
  {
    var failed =
      result.exitCode != 0 || result.timedOut || result.cancelled
      || result.launchError != nil || !result.streamErrors.isEmpty
    var output: [String: JSONValue] = [
      "exit_code": result.exitCode.map { .number(Double($0)) } ?? .null,
      "signal": result.signal.map { .number(Double($0)) } ?? .null,
      "timed_out": .bool(result.timedOut), "cancelled": .bool(result.cancelled),
      "stdout": stream(result.stdout, preferBinary: command.stdout == .binary),
      "stderr": stream(result.stderr, preferBinary: false),
    ]
    if result.launchError != nil || !result.streamErrors.isEmpty {
      output["error"] = .string("CLI execution or stream capture failed.")
    }
    if command.stdout == .json, !failed {
      do {
        guard !result.stdout.truncated, !result.stdout.missedBytes,
          let base64 = result.stdout.base64, let data = Data(base64Encoded: base64)
        else { throw CLITreeError.invalid("JSON output was truncated.") }
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        if let schema = command.outputSchema {
          try CLIValueValidation.validate(value, schema: schema, path: "stdout")
        }
        output["data"] = value
      } catch {
        failed = true
        output["error"] = .string(
          "CLI stdout is incomplete JSON or does not satisfy its declared schema.")
      }
    }
    let envelope = JSONValue.object(["result": .object(output)])
    return .object([
      "structuredContent": envelope, "isError": .bool(failed),
      "content": .array([
        .object([
          "type": .string("text"),
          "text": .string(String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)),
        ])
      ]),
    ])
  }

  private func stream(_ stream: ShellStreamRead, preferBinary: Bool) -> JSONValue {
    let data = stream.base64.flatMap { Data(base64Encoded: $0) } ?? Data()
    let text = preferBinary ? nil : String(data: data, encoding: .utf8)
    return .object([
      "encoding": .string(text == nil ? "base64" : "utf8"),
      "data": .string(text ?? data.base64EncodedString()),
      "truncated": .bool(stream.truncated || stream.missedBytes),
    ])
  }
}
