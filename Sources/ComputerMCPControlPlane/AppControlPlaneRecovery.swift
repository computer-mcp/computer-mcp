import ComputerMCPGateway
import Foundation

extension AppControlPlaneService {
  package func recoveryStores() async throws -> [RecoveryStoreView] {
    try await withRecoveryOwner { try $0.list() }
  }

  package func reviewRecoveryRelease(
    storeKey: String, generation: UUID, selections: [RecoveryRecordSelection]
  ) async throws -> RecoveryReleaseReview {
    try await withRecoveryOwner {
      try $0.reviewRelease(storeKey: storeKey, generation: generation, selections: selections)
    }
  }

  package func confirmRecoveryRelease(_ review: RecoveryReleaseReview) async throws
    -> RecoveryOperationStatus
  {
    try await withRecoveryOwner { try $0.confirm(review) }
  }

  package func prepareRecoveryMaintenance(storeKey: String, generation: UUID) async throws
    -> RecoveryMaintenancePreparation
  {
    try await withRecoveryOwner {
      try $0.prepareMaintenance(storeKey: storeKey, generation: generation)
    }
  }

  package func runRecoveryMaintenance(_ review: RecoveryMaintenanceReview) async throws
    -> RecoveryOperationStatus
  {
    try await withRecoveryOwner { try $0.run(review) }
  }

  package func recoveryOperation(handle: RecoveryOperationHandle) async throws
    -> RecoveryOperationLookup
  {
    try await withRecoveryOwner { try $0.operation(handle: handle) }
  }

  package func resumeRecoveryOperation(handle: RecoveryOperationHandle) async throws
    -> RecoveryOperationStatus
  {
    try await withRecoveryOwner { try $0.resume(handle: handle) }
  }

  private func withRecoveryOwner<T: Sendable>(
    _ operation: @escaping @Sendable (GatewayRecoveryOwnerService) throws -> T
  ) async throws -> T {
    guard let recoveryOwner else { throw AppControlPlaneServiceError.recoveryOwnerUnavailable }
    let task = Task.detached { try operation(recoveryOwner) }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
}
