import Foundation

package protocol GatewayToolServing: Sendable {
  func listTools() throws -> [MCPTool]
  func callTool(name: String, arguments: JSONValue?) throws -> JSONValue
  func callToolAsync(name: String, arguments: JSONValue?) async throws -> JSONValue
  func callToolForMCPAsync(name: String, arguments: JSONValue?) async throws -> JSONValue
}

extension GatewayToolServing {
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

  package func callToolForMCPAsync(
    name: String,
    arguments: JSONValue?
  ) async throws -> JSONValue {
    try await callToolAsync(name: name, arguments: arguments)
  }
}

extension GatewayToolRegistry: GatewayToolServing {}
