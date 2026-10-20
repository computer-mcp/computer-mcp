import ComputerMCPCore
import Foundation

/// Local client-control contracts and validated dispatch for an admitted HTTP generation.
package protocol GatewayClientControlProvider: Sendable {
  func listTools() throws -> [MCPTool]
  func callTool(
    name: String, arguments: JSONValue?, owner: GatewayHTTPApp, generation: UUID
  ) async throws -> JSONValue
}
