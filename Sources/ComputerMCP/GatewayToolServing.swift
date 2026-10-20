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
  package func toolChanges(context: InvocationContext = .empty) -> AsyncStream<Void> {
    AsyncStream { $0.finish() }
  }
  package func refreshTools(context: InvocationContext = .empty) async throws {}

  package func callToolForMCPAsync(
    name: String,
    arguments: JSONValue?, context: InvocationContext = .empty
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
  package func listToolsAsync(context: InvocationContext = .empty) async throws -> [MCPTool] {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(with: Result { try self.listTools(context: context) })
      }
    }
  }

  package func callToolAsync(
    name: String, arguments: JSONValue?, context: InvocationContext = .empty
  ) async throws -> JSONValue {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(
          with: Result {
            try self.callTool(name: name, arguments: arguments, context: context)
          })
      }
    }
  }

}

extension GatewayToolRegistry: GatewayToolServing {}
