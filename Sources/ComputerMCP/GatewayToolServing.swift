import Foundation

/// MCP admission and execution may suspend while selecting an owned runtime.
package protocol GatewayAsyncToolServing: Sendable {
  func listToolsAsync() async throws -> [MCPTool]
  func callToolAsync(name: String, arguments: JSONValue?) async throws -> JSONValue
  func callToolForMCPAsync(name: String, arguments: JSONValue?) async throws -> JSONValue
  func toolChanges() -> AsyncStream<Void>
  func refreshTools() async throws
  func shutdown() async
}

extension GatewayAsyncToolServing {
  package func toolChanges() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
  package func refreshTools() async throws {}

  package func callToolForMCPAsync(
    name: String,
    arguments: JSONValue?
  ) async throws -> JSONValue {
    try await callToolAsync(name: name, arguments: arguments)
  }

  package func shutdown() async {}
}

/// Synchronous registries expose the same asynchronous boundary to transports.
package protocol GatewayToolServing: GatewayAsyncToolServing {
  func listTools() throws -> [MCPTool]
  func callTool(name: String, arguments: JSONValue?) throws -> JSONValue
}

extension GatewayToolServing {
  package func listToolsAsync() async throws -> [MCPTool] {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(with: Result(catching: self.listTools))
      }
    }
  }

  package func callToolAsync(name: String, arguments: JSONValue?) async throws -> JSONValue {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(
          with: Result {
            try self.callTool(name: name, arguments: arguments)
          })
      }
    }
  }

}

extension GatewayToolRegistry: GatewayToolServing {}
