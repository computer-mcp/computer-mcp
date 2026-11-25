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

/// A selected tool call can spend an MCP delegation permit on an existing
/// resource without transferring that permit to the process or pool entry.
struct MCPSelectedResourceRetry: Sendable {
  private let admitted: PreparedExecutionContext
  private let running: PreparedExecutionContext

  init?(admitted: PreparedExecutionContext?, running: PreparedExecutionContext?) throws {
    guard let admitted, admitted.provider != nil, let running, running.provider != nil else {
      return nil
    }
    let call = try MCPProviderSessionAuthority(admitted)
    let connection = try MCPProviderSessionAuthority(running)
    let permission = Permission.mcpServer(call.registrationID)
    guard call.provider == .localServer(call.registrationID),
      call.sharesDelegation(with: connection), let delegator = call.delegator,
      call.sourceDigest == connection.sourceDigest, call.project == connection.project,
      call.filesystem == connection.filesystem,
      call.scopedExecution == admitted.executionID, connection.scopedExecution == nil,
      let caller = admitted.provider?.delegatingAuthorization,
      let project = caller.sandboxProjectID,
      running.provider?.delegatingAuthorization?.sandboxProjectID == project,
      admitted.provider?.providerAuthorization.sandboxProjectID == project,
      running.provider?.providerAuthorization.sandboxProjectID == project,
      Self.sessionBasis(call.providerBasis, project: project)
        == Self.sessionBasis(connection.providerBasis, project: project),
      let permit = Self.delegation(in: call.delegatingBasis, of: delegator, for: permission, .all),
      case .onlyThisTime(let request, let identity) = permit.source,
      caller.requestIDs == [request.id],
      admitted.provider?.providerAuthorization.requestIDs.isEmpty == true,
      let read = Self.delegation(
        in: connection.delegatingBasis, of: delegator, for: permission, .read),
      case .standing = read.source,
      Self.sessionBasis(
        call.delegatingBasis.subtracting([
          .permission(permit), .request(request), .permit(request: request, identity: identity),
        ]), project: project)
        == Self.sessionBasis(
          connection.delegatingBasis.subtracting([.permission(read)]), project: project)
    else { return nil }
    self.admitted = admitted
    self.running = running
  }

  func validate() throws {
    try admitted.validateProviderLaunch()
    try running.validateProviderLaunch()
  }

  private enum SessionEvidence: Hashable {
    case exact(AuthorizationBasis)
    case standingProjectGrant(Principal, PermissionGrant.Source)
  }

  private static func sessionBasis(_ basis: Set<AuthorizationBasis>, project: String)
    -> Set<SessionEvidence>
  {
    // Read and write requirements can pin the same standing grant. Both calls
    // already passed ledger admission for their own requirement; every path,
    // sandbox and policy element still has to agree for this connection.
    Set(
      basis.map { element in
        guard case .permission(let grant) = element,
          grant.requirement.permission == .project(project), grant.scope == .project(project),
          grant.pluginPurpose == nil, case .standing = grant.source
        else { return .exact(element) }
        return .standingProjectGrant(grant.principal, grant.source)
      })
  }

  private static func delegation(
    in basis: Set<AuthorizationBasis>, of principal: Principal, for permission: Permission,
    _ value: PermissionValue
  ) -> PermissionGrant? {
    for case .permission(let grant) in basis
    where grant.principal == principal && grant.requirement.permission == permission
      && grant.requirement.value == value && grant.scope == .principal && grant.pluginPurpose == nil
    {
      return grant
    }
    return nil
  }
}
