import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPProcess
import Foundation

extension GatewayPermissionService {
  func authorizeProviderExecution(
    review: GatewayProviderReview, registrationID: String,
    caller: InvocationAuthorization?, retryIDs: Set<UUID>
  ) throws -> ProviderExecutionBinding {
    let result: Result<ProviderExecutionBinding, any Error> = try transactionWithPolicy {
      database, ledger, policies in
      _ = try refresh(database, ledger: &ledger, snapshot: policies, now: Date())
      return Result {
        guard try GatewayDatabase.configurationState(in: database) == review.configuration,
          let record = try ProviderAuthorityRecord.load(review.identity, in: database)
        else { throw GatewayPermissionError.invalidBinding }
        let approval = try Self.providerApproval(record)
        guard approval.enabled, approval.sourceDigest == review.sourceDigest,
          approval.epoch == ledger.authorizationEpochID
        else { throw GatewayPermissionError.invalidBinding }
        if let caller {
          guard try ledger.invocationAccess(caller.id) == caller else {
            throw PermissionModelError.invalidAuthorization
          }
        }
        let permission: Permission =
          switch review.identity {
          case .package(let name): .plugin(name)
          case .localServer(let name): .mcpServer(name)
          }
        let required = caller?.requirements
        let requirements = InvocationRequirements(
          actions: required?.actions.filter { $0.requirement.permission != permission } ?? [],
          paths: required?.paths ?? [], networks: required?.networks ?? [],
          mode: caller == nil ? .sandbox : (approval.fullAccessConsent?.mode ?? .sandbox),
          sandboxProjectID: required?.sandboxProjectID, execution: required?.execution)
        let decision = try ledger.authorize(
          invocation: InvocationIdentity(
            principal: approval.principal, tool: caller?.invocation.tool ?? "provider.discovery",
            projectID: caller?.invocation.projectID,
            argumentsDigest: caller?.invocation.argumentsDigest ?? review.sourceDigest),
          requirements: requirements, retryIDs: retryIDs, now: Date())
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
