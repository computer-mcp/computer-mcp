import ComputerMCPCore

/// Management definitions and dispatch supplied by the host control plane.
package protocol GatewayManagementProvider: Sendable {
  var definitions: [ToolDefinition] { get }
  var readCapabilities: Set<String> { get }
  func containsTool(named name: String) -> Bool
  func call(
    name: String, arguments: [String: JSONValue], context: ExecutionContext
  ) async throws -> JSONValue
}
