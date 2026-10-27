import Foundation

/// Registration generation and canonical root are captured together. A source ID
/// reused for another registration does not confer authority over retained children.
package struct DerivedProjectSource: Codable, Equatable, Sendable {
  package let id: String
  package let root: String
  package let registeredAt: Date

  package init(id: String, root: String, registeredAt: Date) {
    self.id = id
    self.root = root
    self.registeredAt = registeredAt
  }
}

package enum DerivedProjectProvenance: Codable, Equatable, Sendable {
  /// The owning adapter retains its exact versioned receipt bytes. This provenance
  /// cannot establish a host-verified private Git execution context.
  case plugin(receipt: Data)
  case host(worktreeID: UUID, storageGeneration: UUID)
}

package struct DerivedProjectRecord: Codable, Equatable, Sendable {
  package enum State: String, Codable, Sendable {
    case creating, active, removing, recoveryRequired
  }

  package let projectID: String
  package let source: DerivedProjectSource
  package let root: String
  package let provenance: DerivedProjectProvenance
  package var state: State
  package var revision: Int64
  package var worktree: WorktreeRegistration?

  package init(
    projectID: String, source: DerivedProjectSource, root: String,
    provenance: DerivedProjectProvenance, state: State = .active, revision: Int64 = 1
  ) {
    self.projectID = projectID
    self.source = source
    self.root = root
    self.provenance = provenance
    self.state = state
    self.revision = revision
  }

  package func validate() throws {
    guard !projectID.isEmpty, projectID != "*", !source.id.isEmpty, source.id != "*",
      source.id != projectID, source.registeredAt.timeIntervalSince1970.isFinite,
      revision > 0, revision < Int64.max,
      [root, source.root].allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") })
    else { throw DerivedProjectStoreError.invalidRecord }
    if case .plugin(let receipt) = provenance {
      guard !receipt.isEmpty, receipt.count <= 32_768, state == .active, worktree == nil else {
        throw DerivedProjectStoreError.invalidRecord
      }
    }
    if case .host = provenance, state == .active, worktree == nil {
      throw DerivedProjectStoreError.invalidRecord
    }
    try worktree?.validate(record: self)
  }
}

package struct ProtectedWorktreeBranch: Codable, Equatable, Sendable {
  package let repository: WorktreeDirectoryIdentity
  package let branchID: UUID
  package let branch: String
  package let base: String
  package let baseOID: String
  package let publishedOID: String
  package let mergedOID: String?
  package let worktreeID: UUID
  package let baseHistory: WorktreeRefHistory?

  package init(
    repository: WorktreeDirectoryIdentity, branchID: UUID, branch: String, base: String,
    baseOID: String, publishedOID: String, worktreeID: UUID, mergedOID: String? = nil,
    baseHistory: WorktreeRefHistory? = nil
  ) {
    self.repository = repository
    self.branchID = branchID
    self.branch = branch
    self.base = base
    self.baseOID = baseOID
    self.publishedOID = publishedOID
    self.mergedOID = mergedOID
    self.worktreeID = worktreeID
    self.baseHistory = baseHistory
  }

  package var repositoryKey: String {
    "\(repository.device):\(repository.inode):\(repository.path)"
  }
}

package enum DerivedProjectStoreError: Error, Equatable {
  case invalidRecord, revisionConflict, activationRequired
}

/// Calls are short atomic transactions. No Git, filesystem, process or runtime
/// work may execute while the store's write transaction is held.
package protocol DerivedProjectStore: Sendable {
  func records() throws -> [DerivedProjectRecord]
  func commit(
    _ record: DerivedProjectRecord, expecting revision: Int64?,
    protecting branch: ProtectedWorktreeBranch?
  ) throws
  func remove(_ id: String, expecting revision: Int64) throws
  func protectedBranches() throws -> [ProtectedWorktreeBranch]
  func releaseProtection(_ branch: ProtectedWorktreeBranch) throws
}
