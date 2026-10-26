import ComputerMCPCore
import Crypto
import Foundation

/// Host-owned scope of a forwarded operation and any work retaining its acquisition.
/// It never leaves the gateway and is not reconstructed from plugin assertions.
struct MCPHostInvocation: Sendable {
  let id: UUID
  let requestLeaseID: UUID
  let admission: HostCallAdmission?
  let reference: MCPToolReference
  let admittedCapability: CapabilityDescriptor
  let upstreamName: String
  let arguments: [String: JSONValue]
  let context: ExecutionContext
  let ticketID: String?
  let auditInvocationID: String?
  let authorizationRevision: Int64

  static let metadataKey = "io.github.computer-mcp/host-invocation"

  static func argumentsDigest(_ arguments: [String: JSONValue]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return SHA256.hash(data: try encoder.encode(JSONValue.object(arguments)))
      .map { String(format: "%02x", $0) }.joined()
  }
}

/// Captured under session consent and checked inside the mutation's SQL transaction.
/// It never leaves the host or substitutes for the live request lease.
struct HostCallAuthoritySnapshot {
  let context: ExecutionContext
  let profileRevision: Int64
  let consent: GatewayFullAccessConsent?
}

/// Raised before metadata changes so a fresh policy check can retry once.
enum HostCallAuthorityConflict: Error {
  case profileRevision
}
