import ComputerMCPGateway
import ComputerMCPPermissions
import Foundation

extension AppControlPlaneService {
  package func worktreeRecoveryEpoch() throws -> UUID {
    try Self.recoveryEpoch(requirePermissionControl())
  }

  package func reviewWorktreeRemoval(_ target: ManagedWorktreeRemovalTarget, epoch: UUID)
    async throws -> ManagedWorktreeRemovalReview
  {
    let validate = try recoveryValidation(epoch)
    return try await withRecoveryOwner {
      try $0.reviewRemoval(target, validate: validate)
    }
  }

  package func confirmWorktreeRemoval(
    _ review: ManagedWorktreeRemovalReview, discard: Bool, epoch: UUID
  ) async throws {
    let validate = try recoveryValidation(epoch)
    try await withRecoveryOwner {
      try await $0.remove(review, discard: discard, validate: validate)
    }
  }

  package func worktreeRemovalOutcome(_ review: ManagedWorktreeRemovalReview) async throws
    -> ManagedWorktreeRemovalOutcome
  {
    try await withRecoveryOwner { try $0.removalOutcome(review) }
  }

  package func recoveryStores() async throws -> [RecoveryStoreView] {
    try await withRecoveryOwner { try $0.list() }
  }

  package func reviewRecoveryRelease(
    storeKey: String, generation: UUID, selections: [RecoveryRecordSelection],
    epoch: UUID? = nil
  ) async throws -> RecoveryReleaseReview {
    try await withRecoveryOwner(epoch: epoch) {
      try $0.reviewRelease(storeKey: storeKey, generation: generation, selections: selections)
    }
  }

  package func confirmRecoveryRelease(_ review: RecoveryReleaseReview, epoch: UUID? = nil)
    async throws
    -> RecoveryOperationStatus
  {
    try await withRecoveryOwner(epoch: epoch) { try $0.confirm(review) }
  }

  package func prepareRecoveryMaintenance(
    storeKey: String, generation: UUID, epoch: UUID? = nil
  ) async throws
    -> RecoveryMaintenancePreparation
  {
    try await withRecoveryOwner(epoch: epoch) {
      try $0.prepareMaintenance(storeKey: storeKey, generation: generation)
    }
  }

  package func runRecoveryMaintenance(_ review: RecoveryMaintenanceReview, epoch: UUID? = nil)
    async throws
    -> RecoveryOperationStatus
  {
    try await withRecoveryOwner(epoch: epoch) { try $0.run(review) }
  }

  package func recoveryOperation(handle: RecoveryOperationHandle) async throws
    -> RecoveryOperationLookup
  {
    try await withRecoveryOwner { try $0.operation(handle: handle) }
  }

  package func resumeRecoveryOperation(handle: RecoveryOperationHandle, epoch: UUID? = nil)
    async throws
    -> RecoveryOperationStatus
  {
    try await withRecoveryOwner(epoch: epoch) { try $0.resume(handle: handle) }
  }

  private static func recoveryEpoch(_ permissions: PermissionControlService) throws -> UUID {
    let view = try permissions.view()
    guard !view.suspended, let epoch = view.epoch else {
      throw PermissionModelError.authoritySuspended
    }
    return epoch
  }

  private func recoveryValidation(_ epoch: UUID) throws -> @Sendable () throws -> Void {
    let permissions = try requirePermissionControl()
    return {
      guard try Self.recoveryEpoch(permissions) == epoch else {
        throw PermissionModelError.revisionConflict
      }
    }
  }

  private func withRecoveryOwner<T: Sendable>(
    epoch: UUID? = nil,
    _ operation: @escaping @Sendable (GatewayRecoveryOwnerService) async throws -> T
  ) async throws -> T {
    guard let recoveryOwner else { throw AppControlPlaneServiceError.recoveryOwnerUnavailable }
    let validate = try epoch.map { try recoveryValidation($0) }
    let task = Task.detached {
      try Task.checkCancellation()
      try validate?()
      return try await operation(recoveryOwner)
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
}
