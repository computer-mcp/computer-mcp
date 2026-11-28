import ComputerMCPCore
import Foundation

/// MCP admission and execution may suspend while selecting an owned runtime.
package protocol GatewayAsyncToolServing: Sendable {
  func listToolsAsync(context: InvocationContext) async throws -> [MCPTool]
  func callToolAsync(name: String, arguments: JSONValue?, context: InvocationContext) async throws
    -> JSONValue
  func callToolForMCPAsync(name: String, arguments: JSONValue?, context: InvocationContext)
    async throws -> JSONValue
  func toolChanges(context: InvocationContext) -> AsyncStream<Void>
  func refreshTools(context: InvocationContext) async throws
  func shutdown() async
}

extension GatewayAsyncToolServing {
  package func toolChanges(context: InvocationContext) -> AsyncStream<Void> {
    AsyncStream { $0.finish() }
  }
  package func refreshTools(context: InvocationContext) async throws {}

  package func callToolForMCPAsync(
    name: String,
    arguments: JSONValue?, context: InvocationContext
  ) async throws -> JSONValue {
    try await callToolAsync(name: name, arguments: arguments, context: context)
  }

  package func shutdown() async {}
}

/// Synchronous registries expose the same asynchronous boundary to transports.
package protocol GatewayToolServing: GatewayAsyncToolServing {
  func listTools(context: InvocationContext) throws -> [MCPTool]
  func callTool(name: String, arguments: JSONValue?, context: InvocationContext) throws -> JSONValue
}

extension GatewayToolServing {
  package func listToolsAsync(context: InvocationContext) async throws -> [MCPTool] {
    try await gatewayServingOperations.perform {
      try self.listTools(context: context)
    }
  }

  package func callToolAsync(
    name: String, arguments: JSONValue?, context: InvocationContext
  ) async throws -> JSONValue {
    try await gatewayServingOperations.perform {
      try self.callTool(name: name, arguments: arguments, context: context)
    }
  }

}

private let gatewayServingOperations = BlockingOperationExecutor(
  label: "computer-mcp.gateway-serving", serial: false)
