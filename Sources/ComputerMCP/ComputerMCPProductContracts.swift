import Foundation

/// Stable, executable-facing artifacts used by the CLI product boundary.
package enum ComputerMCPProductContracts {
  package static func validateMCPConnections(configuration: GatewayConfiguration) async throws
    -> JSONValue
  {
    try Task.checkCancellation()
    let client = MCPProxyClient(workingDirectory: configuration.workspaceDirectory)
    do {
      let result = try await BlockingOperationExecutor(label: "computer-mcp.config-connect").perform
      {
        JSONValue.array(
          try configuration.mcp.servers.map { server in
            guard server.enabled else {
              return .object([
                "id": .string(server.id), "state": .string("disabled"),
                "checked": .bool(false), "tools": .array([]),
              ])
            }
            let tools = try client.listTools(server: server)
            return .object([
              "id": .string(server.id), "ok": .bool(true),
              "tools": .array(tools.map(\.json)),
            ])
          })
      }
      try Task.checkCancellation()
      await client.shutdown()
      return result
    } catch {
      await client.shutdown()
      throw error
    }
  }

  package static func providers(configPath: String) throws -> JSONValue {
    let configurationURL = URL(fileURLWithPath: configPath).standardizedFileURL
    let gateway = try GatewayConfiguration.load(path: configurationURL.path)
    let providers = try ExternalProviderDiscovery(configuration: gateway).discover().sorted {
      $0.providerID < $1.providerID
    }
    return .object([
      "schema_version": .number(1),
      "configuration": .string(configurationURL.lastPathComponent),
      "providers": .array(providers.map(providerJSON)),
    ])
  }

  package static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
    let encoder = CanonicalJSONCoding.encoder(outputFormatting: [.sortedKeys])
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    return try JSONDecoder().decode(JSONValue.self, from: data)
  }

  private static func providerJSON(_ provider: ExternalProviderDiscoveryResult) -> JSONValue {
    var doctor: [String: JSONValue] = [
      "state": .string(provider.doctorStatus.state.rawValue),
      "message": .string(sanitizedText(provider.doctorStatus.message)),
      "missing_capabilities": .array(
        provider.doctorStatus.missingCapabilities.sorted().map(JSONValue.string)
      ),
    ]
    if let exitCode = provider.doctorStatus.exitCode {
      doctor["exit_code"] = .number(Double(exitCode))
    }

    var object: [String: JSONValue] = [
      "id": .string(provider.providerID),
      "kind": .string(provider.kind.rawValue),
      "available": .bool(provider.resolvedPath != nil),
      "doctor": .object(doctor),
      "diagnostics": .array(
        provider.diagnostics.sorted {
          ($0.code.rawValue, $0.operation, $0.message)
            < ($1.code.rawValue, $1.operation, $1.message)
        }.map { diagnostic in
          .object([
            "code": .string(diagnostic.code.rawValue),
            "operation": .string(sanitizedText(diagnostic.operation, maximumCharacters: 256)),
            "message": .string(sanitizedText(diagnostic.message)),
          ])
        }
      ),
    ]
    if let resolvedPath = provider.resolvedPath {
      object["executable_path"] = .string(resolvedPath)
    }
    if let version = provider.version {
      object["version"] = .string(sanitizedText(version, maximumCharacters: 512))
    }
    return .object(object)
  }

  private static func sanitizedText(
    _ value: String,
    maximumCharacters: Int = 4_096
  ) -> String {
    let patterns = [
      #"(?i)(authorization\s*:\s*bearer\s+)[^\s]+"#,
      #"(?i)((?:api[_-]?key|token|credential|secret)\s*[=:]\s*)[^\s,;]+"#,
    ]
    let redacted = patterns.reduce(value) { current, pattern in
      guard let expression = try? NSRegularExpression(pattern: pattern) else {
        return current
      }
      let range = NSRange(current.startIndex..<current.endIndex, in: current)
      return expression.stringByReplacingMatches(
        in: current,
        range: range,
        withTemplate: "$1[REDACTED]"
      )
    }
    return String(redacted.prefix(maximumCharacters))
  }
}
