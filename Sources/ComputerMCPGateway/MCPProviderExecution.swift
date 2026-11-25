import ComputerMCPPermissions
import ComputerMCPProcess
import Foundation

/// The runtime resolves this source from its reviewed registration, never MCP metadata.
struct MCPProviderExecutionSource: Sendable {
  let digest: String
  var vendorExecution: VendorExecutionSource? = nil
  /// Replacement eligibility and caller liveness are checked in the admission snapshot.
  let prepareDiscovery:
    @Sendable (GatewayDiscoveryReplacement?, GatewayDiscoveryCaller?) throws ->
      PreparedExecutionContext
}

/// Standing grants may share a process only while both complete authority bases match.
/// Request-scoped authority stays with the execution that consumed it.
struct MCPProviderSessionAuthority: Hashable, Sendable {
  enum Filesystem: Hashable, Sendable {
    case readOnly, writable, unconfined
  }

  let provider: PluginIdentity
  let registrationID: String
  let sourceDigest: String
  let projectID: String?
  let project: ProviderProjectIdentity?
  let filesystem: Filesystem
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
    project = execution.providerProject
    switch execution.mode {
    case .sandbox(let configuration):
      filesystem = configuration.readOnly ? .readOnly : .writable
    case .fullAccess:
      filesystem = .unconfined
    }
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

  static func requireMatch(
    admitted: PreparedExecutionContext?, running: PreparedExecutionContext?,
    managedObservation: Bool = false
  ) throws {
    if admitted?.provider == nil, running?.provider == nil { return }
    guard let admitted, let running else { throw PermissionModelError.invalidAuthorization }
    let call = try Self(admitted)
    let connection = try Self(running)
    if managedObservation && call != connection {
      // The selected adapter retains the result. The observation has its own
      // admission and receives no private vendor-operation rights.
      guard call.sharesDelegation(with: connection), call.delegator != nil,
        call.sourceDigest == connection.sourceDigest, call.project == connection.project,
        call.scopedExecution == nil, connection.scopedExecution == nil
      else { throw PermissionModelError.invalidAuthorization }
      try admitted.validateProviderLaunch()
      _ = try running.authority.access(running.executionID, operation: .readResult)
      return
    }
    guard call == connection else { throw PermissionModelError.invalidAuthorization }
    try admitted.validateProviderLaunch()
    if running !== admitted { try running.validateProviderLaunch() }
  }
}
