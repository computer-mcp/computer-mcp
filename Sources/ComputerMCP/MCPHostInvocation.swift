import Foundation

/// Host-owned scope of a forwarded operation and any work retaining its acquisition.
/// It never leaves the gateway and is not reconstructed from plugin assertions.
struct MCPHostInvocation: Sendable {
  static let metadataKey = "io.github.computer-mcp/host-invocation"
  let id = UUID()
  let reference: MCPToolReference
  let admittedCapability: CapabilityDescriptor
  let upstreamName: String
  let upstreamArguments: [String: JSONValue]
  let arguments: [String: JSONValue]
  let context: ExecutionContext
  let ticketID: String?
  let ticketInvocationID: String?
  let parentRequestID: String?
  let authorizationRevision: Int64
}
