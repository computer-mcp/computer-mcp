import Foundation

package protocol GatewayToolProvider: Sendable {
  var id: String { get }
  func listTools() throws -> [MCPTool]
  func capability(for tool: MCPTool) throws -> CapabilityDescriptor
  func callTool(name: String, arguments: JSONValue?) throws -> JSONValue
  func callToolAsync(name: String, arguments: JSONValue?) async throws -> JSONValue
  func shutdown() async
}
