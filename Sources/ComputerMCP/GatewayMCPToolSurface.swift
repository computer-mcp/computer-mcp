import ComputerMCPCore
import Foundation

/// Exposes canonical registry tools directly through MCP.
package struct GatewayMCPToolSurface: Sendable {
  private let gateway: any GatewayToolServing

  package init(registry: any GatewayToolServing) {
    self.gateway = registry
  }

  package func listTools(context: InvocationContext = .empty) throws -> [MCPTool] {
    try gateway.listTools(context: context)
  }

  package func listToolsAsync(context: InvocationContext = .empty) async throws -> [MCPTool] {
    try await gateway.listToolsAsync(context: context)
  }

  package func callTool(name: String, arguments: JSONValue?, context: InvocationContext = .empty)
    throws -> JSONValue
  {
    try gateway.callTool(name: name, arguments: arguments, context: context)
  }

  package func callToolAsync(
    name: String, arguments: JSONValue?, context: InvocationContext = .empty
  ) async throws -> JSONValue {
    try await gateway.callToolAsync(name: name, arguments: arguments, context: context)
  }
}
