import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPProcess
import Foundation
import GRDB

extension GatewayPermissionService {
  static func executionApproval(
    review: GatewayProviderReview, database: Database, ledger: PermissionLedger
  ) throws -> GatewayProviderApproval {
    guard try GatewayDatabase.configurationState(in: database) == review.configuration,
      let record = try ProviderAuthorityRecord.load(review.identity, in: database)
    else { throw GatewayPermissionError.invalidBinding }
    let approval = try providerApproval(record)
    guard approval.enabled, approval.sourceDigest == review.sourceDigest,
      approval.epoch == ledger.authorizationEpochID
    else { throw GatewayPermissionError.invalidBinding }
    return approval
  }

  static func providerRequirements(
    approval: GatewayProviderApproval, caller: InvocationAuthorization?
  ) -> InvocationRequirements {
    let permission: Permission =
      switch approval.identity {
      case .package(let name): .plugin(name)
      case .localServer(let name): .mcpServer(name)
      }
    let required = caller?.requirements
    let effects =
      caller?.basis.compactMap { element -> PermissionAction? in
        guard case .permission(let grant) = element, grant.requirement.permission != permission
        else { return nil }
        return PermissionAction(
          requirement: grant.requirement, scope: grant.scope, pluginPurpose: grant.pluginPurpose)
      } ?? []
    return InvocationRequirements(
      actions: (required?.actions.filter { $0.requirement.permission != permission } ?? [])
        + effects,
      paths: required?.paths ?? [], networks: required?.networks ?? [],
      mode: caller == nil ? .sandbox : (approval.fullAccessConsent?.mode ?? .sandbox),
      sandboxProjectID: required?.sandboxProjectID, execution: required?.execution,
      providers: [
        ProviderRequirement(
          provider: approval.identity, digest: approval.requirementDigest, conservative: false)
      ])
  }

  /// Commit consumption only when both principals admit this call. A missing
  /// provider permission must not spend the delegator's one-time grant.
  static func admitProviderCall(
    source: GatewayProviderSource, invocation: InvocationIdentity,
    requirements: InvocationRequirements, retryIDs: Set<UUID>, connectionID: String?,
    now: Date, database: Database, ledger: inout PermissionLedger,
    callbackExecutionID: UUID? = nil
  ) throws -> (AuthorizationDecision, ProviderExecutionBinding?) {
    let approval = try executionApproval(review: source.review, database: database, ledger: ledger)
    let callerRetries = retryIDs.filter {
      ledger.requests[$0]?.invocation.principal == invocation.principal
        || ledger.requests[$0] == nil
    }
    let providerRetries = retryIDs.filter {
      ledger.requests[$0]?.invocation.principal == approval.principal
    }
    func caller(_ ledger: inout PermissionLedger) throws -> AuthorizationDecision {
      try ledger.authorize(
        invocation: invocation, requirements: requirements,
        retryIDs: callerRetries, connectionID: connectionID,
        callbackExecutionID: callbackExecutionID, now: now)
    }
    var candidate = ledger
    let decision: AuthorizationDecision
    do { decision = try caller(&candidate) } catch {
      return (try caller(&ledger), nil)
    }
    guard case .allowed(let callerProof) = decision else {
      ledger = candidate
      return (decision, nil)
    }
    let ownRequirements = providerRequirements(approval: approval, caller: callerProof)
    let ownInvocation = InvocationIdentity(
      principal: approval.principal, tool: invocation.tool,
      projectID: invocation.projectID, argumentsDigest: invocation.argumentsDigest)
    func provider(_ ledger: inout PermissionLedger) throws -> AuthorizationDecision {
      try ledger.authorize(
        invocation: ownInvocation, requirements: ownRequirements,
        retryIDs: providerRetries, callbackExecutionID: callbackExecutionID, now: now)
    }
    let own: AuthorizationDecision
    do { own = try provider(&candidate) } catch {
      return (try provider(&ledger), nil)
    }
    guard case .allowed(let providerProof) = own else {
      return (try provider(&ledger), nil)
    }
    let binding = try ProviderExecutionBinding(
      identity: source.review.identity,
      registrationID: source.registrationID, sourceDigest: source.review.sourceDigest,
      providerAuthorization: providerProof, delegatingAuthorization: callerProof)
    ledger = candidate
    return (.allowed(callerProof), binding)
  }

  func authorizeProviderExecution(
    review: GatewayProviderReview, registrationID: String,
    caller: InvocationAuthorization?, retryIDs: Set<UUID>
  ) throws -> ProviderExecutionBinding {
    let result: Result<ProviderExecutionBinding, any Error> = try transactionWithPolicy {
      database, ledger, policies in
      _ = try refresh(database, ledger: &ledger, snapshot: policies, now: Date())
      return Result {
        let approval = try Self.executionApproval(
          review: review, database: database, ledger: ledger)
        if let caller {
          guard try ledger.invocationAccess(caller.id) == caller else {
            throw PermissionModelError.invalidAuthorization
          }
        }
        let requirements = Self.providerRequirements(approval: approval, caller: caller)
        let decision = try ledger.authorize(
          invocation: InvocationIdentity(
            principal: approval.principal, tool: caller?.invocation.tool ?? "provider.discovery",
            projectID: caller?.invocation.projectID,
            argumentsDigest: caller?.invocation.argumentsDigest ?? review.sourceDigest),
          requirements: requirements,
          retryIDs: retryIDs.filter {
            ledger.requests[$0]?.invocation.principal == approval.principal
          },
          now: Date())
        switch decision {
        case .allowed(let provider):
          return try ProviderExecutionBinding(
            identity: review.identity, registrationID: registrationID,
            sourceDigest: review.sourceDigest, providerAuthorization: provider,
            delegatingAuthorization: caller)
        case .requests(let requests): throw GatewayPermissionCallError.required(requests)
        case .denied(let reason): throw GatewayPermissionCallError.denied(reason)
        }
      }
    }
    return try result.get()
  }

  func validateProviderExecution(_ binding: ProviderExecutionBinding) throws {
    try store.readWithDatabase { database, ledger in
      guard let record = try ProviderAuthorityRecord.load(binding.identity, in: database) else {
        throw GatewayPermissionError.invalidBinding
      }
      let approval = try Self.providerApproval(record)
      guard approval.enabled, approval.sourceDigest == binding.sourceDigest,
        approval.epoch == ledger.authorizationEpochID,
        binding.authorizationIDs.allSatisfy({ ledger.authorizations[$0] != nil })
      else { throw GatewayPermissionError.invalidBinding }
    }
  }
}
