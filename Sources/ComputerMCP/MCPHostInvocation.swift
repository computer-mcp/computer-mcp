import Foundation

/// Host-owned evidence that a forwarded operation is currently authorized and executing.
/// It never leaves the gateway and is not reconstructed from plugin assertions.
struct MCPHostInvocation: Sendable {
  let id = UUID()
  let reference: MCPToolReference
  let upstreamName: String
  let upstreamArguments: [String: JSONValue]
  let arguments: [String: JSONValue]
  let context: ExecutionContext
  let ticketID: String?
  let ticketInvocationID: String?
  let parentRequestID: String?
}
