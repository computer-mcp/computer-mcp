/// Exposes canonical registry tools directly through MCP.
package struct GatewayMCPToolSurface: Sendable {
  private let gateway: any GatewayToolServing

  package init(registry: any GatewayToolServing) {
    self.gateway = registry
  }

  package func listTools() throws -> [MCPTool] {
    try gateway.listTools()
  }

  package func callTool(name: String, arguments: JSONValue?) throws -> JSONValue {
    try gateway.callTool(name: name, arguments: arguments)
  }

  package func callToolAsync(name: String, arguments: JSONValue?) async throws -> JSONValue {
    try await gateway.callToolAsync(name: name, arguments: arguments)
  }
}
