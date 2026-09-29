import Foundation

extension GatewayToolRegistry {
  internal func runShell(arguments object: [String: JSONValue]) throws -> JSONValue {
    let timeout = optionalInt("timeout_ms", in: object) ?? configuration.policy.defaultTimeoutMs
    guard timeout > 0 else {
      throw GatewayToolError.invalidArguments("timeout_ms must be greater than zero.")
    }
    return try shellManager.run(
      request: shellLaunchRequest(arguments: object),
      defaultShell: configuration.policy.shellExecutable,
      defaultWorkingDirectory: configuration.workspaceDirectory,
      standardInput: try shellStandardInput(arguments: object),
      timeoutMilliseconds: timeout,
      maxOutputBytes: configuration.policy.maxOutputBytes,
      maxSessions: configuration.policy.maxShellSessions,
      terminationGraceMilliseconds: configuration.policy.shellTerminationGraceMs
    ).json
  }

  internal func spawnShell(arguments object: [String: JSONValue]) throws -> JSONValue {
    let timeout = optionalInt("timeout_ms", in: object)
    if let timeout, timeout <= 0 {
      throw GatewayToolError.invalidArguments("timeout_ms must be greater than zero when set.")
    }
    let id = try shellManager.spawn(
      request: shellLaunchRequest(arguments: object),
      defaultShell: configuration.policy.shellExecutable,
      defaultWorkingDirectory: configuration.workspaceDirectory,
      timeoutMilliseconds: timeout,
      maxOutputBytes: configuration.policy.maxOutputBytes,
      maxSessions: configuration.policy.maxShellSessions,
      terminationGraceMilliseconds: configuration.policy.shellTerminationGraceMs
    )
    return .object(["session_id": .string(id)])
  }

  internal func listShellSessions(arguments object: [String: JSONValue]) throws -> JSONValue {
    let maxBytes = optionalInt("max_bytes", in: object) ?? 0
    guard maxBytes >= 0 && maxBytes <= configuration.policy.maxOutputBytes else {
      throw GatewayToolError.invalidArguments(
        "max_bytes must be between 0 and policy.max_output_bytes."
      )
    }
    return .object([
      "sessions": .array(
        try shellManager.list(
          maxReadBytes: maxBytes,
          encoding: try shellEncoding(arguments: object)
        ).map(\.json)
      )
    ])
  }

  internal func readShellSession(arguments object: [String: JSONValue]) throws -> JSONValue {
    let maxBytes = optionalInt("max_bytes", in: object) ?? configuration.policy.maxOutputBytes
    guard maxBytes >= 0 && maxBytes <= configuration.policy.maxOutputBytes else {
      throw GatewayToolError.invalidArguments(
        "max_bytes must be between 0 and policy.max_output_bytes."
      )
    }
    return try shellManager.read(
      sessionID: requiredString("session_id", in: object),
      stdoutCursor: Int64(optionalInt("stdout_cursor", in: object) ?? 0),
      stderrCursor: Int64(optionalInt("stderr_cursor", in: object) ?? 0),
      maxReadBytes: maxBytes,
      encoding: shellEncoding(arguments: object)
    ).json
  }

  internal func writeShellSession(arguments object: [String: JSONValue]) throws -> JSONValue {
    let text = object["text"]?.stringValue
    let base64 = object["base64"]?.stringValue
    guard text == nil || base64 == nil else {
      throw GatewayToolError.invalidArguments("Provide only one of text or base64.")
    }
    let data: Data
    if let text {
      data = Data(text.utf8)
    } else if let base64 {
      guard let decoded = Data(base64Encoded: base64) else {
        throw GatewayToolError.invalidArguments("base64 is not valid Base64 data.")
      }
      data = decoded
    } else {
      data = Data()
    }
    guard data.count <= configuration.policy.maxShellInputBytes else {
      throw GatewayToolError.invalidArguments(
        "Shell input exceeds policy.max_shell_input_bytes."
      )
    }
    return try shellManager.write(
      sessionID: requiredString("session_id", in: object),
      data: data,
      close: object["close"]?.boolValue ?? false
    ).json
  }

  internal func cancelShellSession(arguments object: [String: JSONValue]) throws -> JSONValue {
    try shellManager.cancel(
      sessionID: requiredString("session_id", in: object)
    ).json
  }

  private func shellLaunchRequest(arguments object: [String: JSONValue]) throws
    -> ShellLaunchRequest
  {
    let modeValue = object["mode"]?.stringValue ?? ShellLaunchMode.shell.rawValue
    guard let mode = ShellLaunchMode(rawValue: modeValue) else {
      throw GatewayToolError.invalidArguments("mode must be shell or argv.")
    }
    return ShellLaunchRequest(
      mode: mode,
      command: object["command"]?.stringValue,
      executable: object["executable"]?.stringValue,
      argv: try optionalStringArray("argv", in: object),
      shell: object["shell"]?.stringValue,
      workingDirectory: object["cwd"]?.stringValue,
      environment: try optionalStringMap("env", in: object) ?? [:]
    )
  }

  private func shellEncoding(arguments object: [String: JSONValue]) throws -> ShellStreamEncoding {
    let value = object["encoding"]?.stringValue ?? ShellStreamEncoding.utf8.rawValue
    guard let encoding = ShellStreamEncoding(rawValue: value) else {
      throw GatewayToolError.invalidArguments("encoding must be utf8 or base64.")
    }
    return encoding
  }

  private func shellStandardInput(arguments object: [String: JSONValue]) throws -> Data {
    let text = object["stdin_text"]?.stringValue
    let base64 = object["stdin_base64"]?.stringValue
    guard text == nil || base64 == nil else {
      throw GatewayToolError.invalidArguments(
        "Provide only one of stdin_text or stdin_base64."
      )
    }
    let data: Data
    if let text {
      data = Data(text.utf8)
    } else if let base64 {
      guard let decoded = Data(base64Encoded: base64) else {
        throw GatewayToolError.invalidArguments("stdin_base64 is not valid Base64 data.")
      }
      data = decoded
    } else {
      data = Data()
    }
    guard data.count <= configuration.policy.maxShellInputBytes else {
      throw GatewayToolError.invalidArguments(
        "Shell input exceeds policy.max_shell_input_bytes."
      )
    }
    return data
  }

  internal func requireShellEnabled() throws {
    guard configuration.policy.shellEnabled else {
      throw GatewayToolError.disabled("Shell is disabled by policy.")
    }
  }
}
