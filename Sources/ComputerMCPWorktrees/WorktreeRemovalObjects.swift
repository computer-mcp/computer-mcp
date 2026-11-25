import Foundation

extension WorktreeRepository {
  func verifyFinalRecoveryCapture(
    _ handoff: WorktreeRecoveryHandoff, record: DerivedProjectRecord,
    store: WorktreeRecoveryStore.Locked, budget: WorktreeObjectBudget
  ) throws {
    try budget.check()
    let retention = handoff.retention
    guard handoff.phase == .sourceInstalled,
      let registration = record.worktree, registration.repository == identity,
      case .host(let worktreeID, let generation) = record.provenance,
      generation == retention.owner.storageGeneration, worktreeID == retention.owner.worktreeID,
      record.source == source, retention.owner.source == source,
      registration.branchID == retention.owner.branchID,
      registration.branch == retention.owner.branch
    else { throw invalidRecoveryMetadata() }
    let directory = try WorktreeDirectory(URL(fileURLWithPath: registration.gitDirectory.path))
    let objects = try WorktreeDirectory(URL(fileURLWithPath: registration.objects.path))
    guard directory.identity == registration.gitDirectory, objects.identity == registration.objects
    else { throw invalidRecoveryMetadata() }
    try verifyPrivateControls(
      directory: directory, objects: objects, root: URL(fileURLWithPath: registration.root.path),
      repository: identity)
    let metadata = try WorktreePrivateMetadata(
      directory: directory, format: identity.format, io: io,
      limit: git.maxOutputBytes * 8, deadline: budget.deadline,
      recoveryRootLimit: budget.limits.objectCount)
    try retention.verifyFinalCapture(metadata)
    try handoff.verifyRecoveryPack(repository: self, store: store, budget: budget)
  }

}
