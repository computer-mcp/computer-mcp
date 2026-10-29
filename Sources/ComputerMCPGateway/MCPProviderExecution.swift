import ComputerMCPPermissions
import ComputerMCPProcess
import Foundation

/// The runtime resolves this source from its reviewed registration, never MCP metadata.
struct MCPProviderExecutionSource: Sendable {
  let digest: String
  let prepareDiscovery: @Sendable () throws -> PreparedExecutionContext
}

/// Standing grants may share a process only while both complete authority bases match.
/// Request-scoped authority stays with the execution that consumed it.
struct MCPProviderSessionAuthority: Hashable, Sendable {
  let provider: PluginIdentity
  let registrationID: String
  let sourceDigest: String
  let projectID: String?
  let delegator: Principal?
  let providerBasis: Set<AuthorizationBasis>
  let delegatingBasis: Set<AuthorizationBasis>
  let scopedExecution: UUID?

  init(_ execution: PreparedExecutionContext) throws {
    guard let binding = execution.provider else {
      throw PermissionModelError.invalidAuthorization
    }
    provider = binding.identity
    registrationID = binding.registrationID
    sourceDigest = binding.sourceDigest
    projectID = binding.providerAuthorization.invocation.projectID
    delegator = binding.delegatingAuthorization?.invocation.principal
    providerBasis = binding.providerAuthorization.basis
    delegatingBasis = binding.delegatingAuthorization?.basis ?? []
    scopedExecution =
      binding.providerAuthorization.requestIDs.isEmpty
        && (binding.delegatingAuthorization?.requestIDs.isEmpty ?? true)
      ? nil : execution.executionID
  }

  func sharesDelegation(with other: Self) -> Bool {
    provider == other.provider && registrationID == other.registrationID
      && projectID == other.projectID && delegator == other.delegator
  }
}
