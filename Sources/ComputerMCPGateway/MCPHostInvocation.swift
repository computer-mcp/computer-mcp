import ComputerMCPCore
import ComputerMCPProcess
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
  let authorizationRevision: Int64
  let providerExecution: PreparedExecutionContext?
  /// The lifecycle operation reserved for this invocation before forwarding.
  var operationID: UUID?

  init(
    id: UUID, requestLeaseID: UUID, admission: HostCallAdmission?, reference: MCPToolReference,
    admittedCapability: CapabilityDescriptor, upstreamName: String, arguments: [String: JSONValue],
    context: ExecutionContext, authorizationRevision: Int64,
    providerExecution: PreparedExecutionContext? = nil
  ) {
    self.id = id
    self.requestLeaseID = requestLeaseID
    self.admission = admission
    self.reference = reference
    self.admittedCapability = admittedCapability
    self.upstreamName = upstreamName
    self.arguments = arguments
    self.context = context
    self.authorizationRevision = authorizationRevision
    self.providerExecution = providerExecution
  }

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
  let authorizationID: UUID?
  let providerAuthorizationIDs: Set<UUID>

  init(
    context: ExecutionContext, profileRevision: Int64,
    consent: GatewayFullAccessConsent?, authorizationID: UUID? = nil,
    providerAuthorizationIDs: Set<UUID> = []
  ) {
    self.context = context
    self.profileRevision = profileRevision
    self.consent = consent
    self.authorizationID = authorizationID
    self.providerAuthorizationIDs = providerAuthorizationIDs
  }
}

/// Raised before metadata changes so a fresh policy check can retry once.
enum HostCallAuthorityConflict: Error {
  case profileRevision
}
