import Foundation

package protocol GatewayToolProvider: Sendable {
  var id: String { get }
  func listTools() throws -> [MCPTool]
  func capability(for tool: MCPTool) throws -> CapabilityDescriptor
  func callTool(name: String, arguments: JSONValue?) throws -> JSONValue
  func callToolAsync(name: String, arguments: JSONValue?) async throws -> JSONValue
  func shutdown() async
}

extension GatewayToolProvider {
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

  package func shutdown() async {}
}
