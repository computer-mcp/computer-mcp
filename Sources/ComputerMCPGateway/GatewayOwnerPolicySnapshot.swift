import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPPersistence
import Foundation
import GRDB

package enum GatewayOwnerPolicyTarget: Hashable, Sendable {
  case profile(GatewayProfileID)
  case provider(PluginIdentity)
}

package struct GatewayOwnerPolicySnapshot: Sendable {
  package struct Limits: Sendable {
    /// Provider policy has no client caller dimension.
    package let caller: GatewayCallerKind?
    package let savedOwner: PolicyAvailability
    /// Combined target-wide ceilings. A connection may further narrow a profile.
    package let effective: ManagedLimits

    package func executionLimits(for request: ExecutionLimitRequest) throws
      -> EffectiveExecutionLimits
    {
      try .resolve(request, limits: [effective])
    }
  }

  package let target: GatewayOwnerPolicyTarget
  package let revision: UInt64
  package let epoch: UUID?
  package let canEdit: Bool
  package let savedText: String?
  package let ownerSource: GatewayManagedPolicyView?
  package let readOnlySources: [GatewayManagedPolicyView]
  package let limits: [Limits]
  package let trustedHosts: Set<String>
}

extension GatewayPermissionService {
  package func ownerPolicySnapshot(
    for target: GatewayOwnerPolicyTarget, owner: GatewayPermissionOwner, now: Date = Date()
  ) throws -> GatewayOwnerPolicySnapshot {
    try transactionWithPolicy { database, ledger, policies in
      try owner.authorize()
      let sources = try refresh(database, ledger: &ledger, snapshot: policies, now: now)
      let epoch = ledger.authorizationEpochID
      let active =
        epoch != nil && ledger.suspendedAuthority == nil
        && ledger.pendingEpochRecovery == nil

      let canEdit: Bool
      let limits: [GatewayOwnerPolicySnapshot.Limits]
      let ownerSource: GatewayManagedPolicyView?
      switch target {
      case .profile(let id):
        guard
          let row = try Row.fetchOne(
            database, sql: "SELECT * FROM permissionProfiles WHERE id = ?", arguments: [id.rawValue]
          )
        else { throw GatewayPermissionError.unknownProfile }
        let profile = try Self.decodeProfile(row, id: id)
        canEdit = active && (row["authorityEpoch"] as String?) == epoch?.uuidString
        ownerSource = sources.first { $0.profileID == id }
        limits = profile.allowedCallers.sorted { $0.rawValue < $1.rawValue }.map { caller in
          let owner = policies.ownerPolicy(id, caller: caller, epoch: canEdit ? epoch : nil)
          return .init(
            caller: caller, savedOwner: policies.savedOwnerPolicy(id, caller: caller),
            effective: policies.limits(owner: owner, caller: caller, previous: nil))
        }
      case .provider(let identity):
        guard try ProviderAuthorityRecord.load(identity, in: database) != nil else {
          throw GatewayPermissionError.invalidBinding
        }
        canEdit = active
        ownerSource = sources.first { $0.provider == identity }
        limits = [
          .init(
            caller: nil, savedOwner: policies.savedProviderPolicy(identity),
            effective: policies.providerLimits(
              identity, epoch: active ? epoch : nil,
              previous: ledger.environment.limits[.plugin(identity)]))
        ]
      }

      return .init(
        target: target, revision: try Self.controlRevision(database), epoch: epoch,
        canEdit: canEdit, savedText: policies.ownerText(for: target), ownerSource: ownerSource,
        readOnlySources: sources.filter { $0.source != .owner }, limits: limits,
        trustedHosts: Set(ledger.environment.trustedHosts.map(\.host)))
    }
  }

  package func validateOwnerPolicy(_ document: Data, owner: GatewayPermissionOwner) throws {
    try owner.authorize()
    _ = try GatewayResolvedPolicy(bytes: document, reader: policyReader)
  }
}
