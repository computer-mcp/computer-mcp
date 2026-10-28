import Foundation

/// Retains the verified directory descriptors while a use lease owns admission.
/// Its fields never mutate; verification opens independent file descriptors.
package final class WorktreeExecutionBinding: @unchecked Sendable {
  package let projectID: String
  package let generation: UUID
  package let root: WorktreeDirectoryIdentity
  package let common: WorktreeDirectoryIdentity
  package let repository: WorktreeDirectoryIdentity
  package let admission: WorktreeAdmission
  private let owner: WorktreeRepository
  private let topology: VerifiedWorktreeTopology
  private let controlDirectories: [WorktreeDirectory]

  init(_ topology: VerifiedWorktreeTopology, owner: WorktreeRepository) throws {
    self.topology = topology
    self.owner = owner
    projectID = topology.projectID
    generation = topology.generation
    root = topology.root.identity
    common = topology.common.identity
    repository = topology.gitDirectory.identity
    controlDirectories = try [
      topology.gitDirectory.child("info"), topology.gitDirectory.child("hooks"),
      topology.objects.child("info"),
    ]
    admission = try WorktreeAdmission(topology: topology)
    try verify()
  }

  /// Removal holds repository coordination while draining uses; this cannot acquire it.
  package func verify() throws {
    try owner.identity.verify()
    try topology.verifyDirectories()
    for directory in controlDirectories { try directory.verify() }
    try owner.verifyPrivateControls(topology, repository: owner.identity)
  }
}

extension WorktreeRepository {
  package func executionBinding(projectID: String) throws -> WorktreeExecutionBinding {
    try WorktreeExecutionBinding(topology(projectID: projectID), owner: self)
  }
}
