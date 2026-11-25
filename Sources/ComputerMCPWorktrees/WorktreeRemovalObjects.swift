import Foundation

extension WorktreeRepository {
  func verifyFinalRecoveryCapture(
    _ handoff: WorktreeRecoveryHandoff, record: DerivedProjectRecord,
    store: WorktreeRecoveryStore.Locked, budget: WorktreeObjectBudget
  ) throws {
    try budget.check()
    let retention = handoff.retention
    guard handoff.phase == .retained, let installation = handoff.recoveryInstallation,
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
    try store.requireRetained(retention)
    try installation.synchronizeInstalled(
      in: store.packDirectory(), format: identity.format, io: io, deadline: budget.deadline)
    try store.verifyRetentionClosure(retention, git: git, budget: budget)
  }

  func removalRoots(_ topology: VerifiedWorktreeTopology) throws -> [String] {
    try privateMetadata(topology).roots
  }

  func objectRevision(_ ref: String) throws -> String? {
    let result = try command(
      ["rev-parse", "--verify", "--quiet", "--end-of-options", ref], accepting: [0, 1])
    guard result.exitCode == 0 else { return nil }
    let oid = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .newlines)
    guard identity.format.contains(oid) else {
      throw WorktreeError.identityChanged("Invalid reference object ID.")
    }
    return oid
  }

  func requireObjectRef(_ ref: String, oid: String) throws {
    guard try command(["symbolic-ref", "--quiet", ref], accepting: [0, 1]).exitCode == 1,
      try objectRevision(ref) == oid
    else { throw WorktreeError.recoveryRequired("Expected recovery reference changed.") }
  }
}
