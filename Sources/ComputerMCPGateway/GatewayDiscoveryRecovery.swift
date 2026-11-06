import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPProcess
import Foundation

/// Immutable identity of a host-created, projectless metadata execution.
struct GatewayDiscoverySelection: Equatable, Sendable {
  let executionID: UUID
  let provider: PluginIdentity
  let registrationID: String
  let sourceDigest: String
  let authorization: BasisIdentity
  let authorizationIDs: Set<UUID>

  init?(executionID: UUID, binding: ProviderExecutionBinding) {
    let proof = binding.providerAuthorization
    guard binding.delegatingAuthorization == nil, proof.invocation.projectID == nil,
      proof.invocation.tool == "provider.discovery"
    else { return nil }
    self.executionID = executionID
    provider = binding.identity
    registrationID = binding.registrationID
    sourceDigest = binding.sourceDigest
    authorization = proof.identity
    authorizationIDs = binding.authorizationIDs
  }

  func validate(in ledger: inout PermissionLedger, operation: ExecutionOperation, now: Date) throws
  {
    guard let proof = ledger.authorizations[authorization.id], proof.identity == authorization,
      proof.executionID == executionID, proof.invocation.principal == .plugin(provider),
      proof.invocation.projectID == nil, proof.invocation.tool == "provider.discovery",
      let execution = ledger.executions[executionID],
      execution.authorizationIDs == authorizationIDs,
      execution.owner == .plugin(provider), execution.delegatedTo == nil,
      !execution.revoked, execution.interruptedAt == nil,
      ledger.executionAccess(
        executionID, principal: .plugin(provider), operation: operation,
        connectionID: nil, authorizingInvocation: nil, now: now) == .allowed
    else { throw PermissionModelError.invalidAuthorization }
  }
}

/// A routing hint from the coordinator's rejected discovery input transaction.
struct GatewayDiscoveryExpired: Error {
  let selection: GatewayDiscoverySelection
}

/// A caller-local failure must bypass shared connection failure bookkeeping.
struct GatewayDiscoveryCallerStopped: Error {
  let underlying: any Error
}

package struct GatewayDiscoveryCaller: Sendable {
  let executionID: UUID?
  let authorizationIDs: Set<UUID>
  let check: @Sendable () throws -> Void
  let checkLedger: @Sendable (inout PermissionLedger, Date) throws -> Void
}

package struct GatewayDiscoveryReplacement: Sendable {
  let selected: GatewayDiscoverySelection
  let reuse: PreparedExecutionContext?
  let caller: GatewayDiscoveryCaller
}
