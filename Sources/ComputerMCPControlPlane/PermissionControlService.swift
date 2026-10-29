import ComputerMCPCore
import ComputerMCPGateway
import ComputerMCPPermissions
import Foundation

/// Owner-only control projection over the gateway's durable permission service.
/// The composition supplies a live local owner proof for every operation.
package final class PermissionControlService: Sendable {
  private let service: GatewayPermissionService
  private let owner: @Sendable () throws -> GatewayPermissionOwner

  package init(
    service: GatewayPermissionService,
    owner: @escaping @Sendable () throws -> GatewayPermissionOwner
  ) {
    self.service = service
    self.owner = owner
  }

  package func view(now: Date = Date()) throws -> GatewayPermissionView {
    try service.view(owner: currentOwner(), now: now)
  }

  package func answerRequest(
    _ id: UUID, answer: PermissionAnswer, expectedRevision: UInt64, now: Date = Date()
  ) throws -> RevocationResult {
    let owner = try currentOwner()
    if let request = try service.view(owner: owner, now: now).requests.first(where: {
      $0.request.id == id
    }),
      case .projectRegistration = request.request.content
    {
      guard case .always = answer else { throw PermissionModelError.invalidRegistrationAnswer }
      _ = try service.answerProjectRequest(
        id, allow: true, owner: owner, expectedRevision: expectedRevision, now: now)
      return try service.reconcilePolicy(now: now)
    }
    return try service.answerRequest(
      id, answer: answer, owner: owner, expectedRevision: expectedRevision, now: now)
  }

  package func declineRequest(
    _ id: UUID, expectedRevision: UInt64, now: Date = Date()
  ) throws -> RevocationResult {
    let owner = try currentOwner()
    if let request = try service.view(owner: owner, now: now).requests.first(where: {
      $0.request.id == id
    }),
      case .projectRegistration = request.request.content
    {
      _ = try service.answerProjectRequest(
        id, allow: false, owner: owner, expectedRevision: expectedRevision, now: now)
      return try service.reconcilePolicy(now: now)
    }
    return try service.declineRequest(
      id, owner: owner, expectedRevision: expectedRevision, now: now)
  }

  package func revokePermission(
    _ permission: Permission, profileID: GatewayProfileID, expectedRevision: UInt64,
    now: Date = Date()
  ) throws -> RevocationResult {
    try service.revokePermission(
      permission, profileID: profileID, owner: currentOwner(), expectedRevision: expectedRevision,
      now: now
    )
  }

  package func updateProfile(
    _ profile: ProfileGrant, expectedProfileRevision: Int64?, expectedRevision: UInt64,
    authorization: GatewayManagementAuthorization? = nil, now: Date = Date()
  ) throws {
    try service.updateProfile(
      profile, owner: currentOwner(), expectedProfileRevision: expectedProfileRevision,
      expectedRevision: expectedRevision, authorization: authorization, now: now)
  }

  package func setOwnerPolicy(
    _ document: Data?, profileID: GatewayProfileID, expectedRevision: UInt64, now: Date = Date()
  ) throws -> RevocationResult {
    try service.setOwnerPolicy(
      document, profileID: profileID, owner: currentOwner(), expectedRevision: expectedRevision,
      now: now)
  }

  package func confirmAuthority(
    epoch: UUID, expectedRevision: UInt64,
    profileEdits: [ProfileGrant], now: Date = Date()
  ) throws {
    try service.confirmAuthority(
      owner: currentOwner(), epoch: epoch, expectedRevision: expectedRevision,
      profileEdits: profileEdits, now: now)
  }

  package func approveProvider(
    _ review: GatewayProviderReview, permissions: Permissions, fullAccess: Bool,
    expectedProviderRevision: Int64?, expectedRevision: UInt64, expectedEpoch: UUID
  ) throws -> GatewayProviderApproval {
    try service.approveProvider(
      review, permissions: permissions, fullAccess: fullAccess, owner: currentOwner(),
      expectedProviderRevision: expectedProviderRevision, expectedRevision: expectedRevision,
      expectedEpoch: expectedEpoch)
  }

  package func revokeProvider(
    _ identity: PluginIdentity, expectedProviderRevision: Int64, expectedRevision: UInt64
  ) throws -> RevocationResult {
    try service.revokeProvider(
      identity, owner: currentOwner(), expectedProviderRevision: expectedProviderRevision,
      expectedRevision: expectedRevision)
  }

  package func setOwnerPolicy(
    _ document: Data?, provider: PluginIdentity, expectedRevision: UInt64
  ) throws -> RevocationResult {
    try service.setOwnerPolicy(
      document, provider: provider, owner: currentOwner(), expectedRevision: expectedRevision)
  }
  private func currentOwner() throws -> GatewayPermissionOwner {
    let proof = try owner()
    guard let context = PermissionOwnerAuditScope.context else { return proof }
    return try proof.recording(context: context)
  }
}

/// Set only by trusted local control dispatch, never from tool arguments.
enum PermissionOwnerAuditScope {
  @TaskLocal static var context: ExecutionContext?
  @TaskLocal static var administrationEpoch: UUID?
}
