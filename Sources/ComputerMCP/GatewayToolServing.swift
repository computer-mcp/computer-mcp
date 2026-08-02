package protocol GatewayToolServing: Sendable {
  func listTools() throws -> [MCPTool]
  func callTool(name: String, arguments: JSONValue?) throws -> JSONValue
  func callToolAsync(name: String, arguments: JSONValue?) async throws -> JSONValue
  func callToolForMCPAsync(name: String, arguments: JSONValue?) async throws -> JSONValue
}

extension GatewayToolServing {
  package func callToolAsync(name: String, arguments: JSONValue?) async throws -> JSONValue {
    try callTool(name: name, arguments: arguments)
  }

  package func callToolForMCPAsync(
    name: String,
    arguments: JSONValue?
  ) async throws -> JSONValue {
    try await callToolAsync(name: name, arguments: arguments)
  }
}

extension GatewayToolRegistry: GatewayToolServing {}
