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
    try service.view(owner: owner(), now: now)
  }

  package func answerRequest(
    _ id: UUID, answer: PermissionAnswer, expectedRevision: UInt64, now: Date = Date()
  ) throws -> RevocationResult {
    try service.answerRequest(
      id, answer: answer, owner: owner(), expectedRevision: expectedRevision, now: now)
  }

  package func revokePermission(
    _ permission: Permission, profileID: GatewayProfileID, expectedRevision: UInt64,
    now: Date = Date()
  ) throws -> RevocationResult {
    try service.revokePermission(
      permission, profileID: profileID, owner: owner(), expectedRevision: expectedRevision, now: now
    )
  }

  package func updateProfile(
    _ profile: PermissionProfile, expectedProfileRevision: Int64?, expectedRevision: UInt64,
    now: Date = Date()
  ) throws {
    try service.updateProfile(
      profile, owner: owner(), expectedProfileRevision: expectedProfileRevision,
      expectedRevision: expectedRevision, now: now)
  }

  package func setOwnerPolicy(
    _ document: Data?, profileID: GatewayProfileID, expectedRevision: UInt64, now: Date = Date()
  ) throws -> RevocationResult {
    try service.setOwnerPolicy(
      document, profileID: profileID, owner: owner(), expectedRevision: expectedRevision, now: now)
  }

  package func confirmAuthority(
    epoch: UUID, expectedRevision: UInt64,
    profileEdits: [PermissionProfile] = [], now: Date = Date()
  ) throws {
    try service.confirmAuthority(
      owner: owner(), epoch: epoch, expectedRevision: expectedRevision,
      profileEdits: profileEdits, now: now)
  }
}
