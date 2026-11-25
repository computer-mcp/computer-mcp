import ComputerMCPCore
import ComputerMCPPersistence
import ComputerMCPWorktrees
import Foundation
import GRDB

package typealias RecoveryStoreView = ComputerMCPWorktrees.RecoveryStoreView
package typealias RecoveryOperationHandle = ComputerMCPWorktrees.RecoveryOperationHandle
package typealias RecoveryOperationStatus = ComputerMCPWorktrees.RecoveryOperationStatus
package typealias RecoveryReleaseReview = ComputerMCPWorktrees.RecoveryReleaseReview
package typealias RecoveryRecordSelection = WorktreeRecoveryRecord.Selection
package typealias RecoveryMaintenanceReview = ComputerMCPWorktrees.RecoveryMaintenanceReview
package typealias RecoveryMaintenancePreparation = ComputerMCPWorktrees
  .RecoveryMaintenancePreparation
package typealias RecoveryOperationLookup = ComputerMCPWorktrees.RecoveryOperationLookup

/// In-process authority for the trusted App owner. Creating this service
/// installs no commands in the gateway, CLI, or control socket.
package struct GatewayRecoveryOwnerService: Sendable {
  private let owner: ExecutionContext
  private let worktrees: WorktreeRecoveryOwnerService

  package init(
    database: GatewayDatabase, platform: PlatformServices, owner: ExecutionContext,
    journalIO: WorktreeJournalIO = .init(), maintenanceLimits: WorktreePromotionLimits = .init()
  ) throws {
    guard let storage = database.worktreeStorage else {
      throw WorktreeRecoveryOwnerError.unavailable
    }
    self.owner = owner
    worktrees = try WorktreeRecoveryOwnerService(
      storage: storage, derived: database.derivedProjectStore(inspectNesting: { _ in [] }),
      dependencies: GatewayRecoveryDependencyReader(database: database),
      executor: GatewayWorktreeGit(launcher: platform.launcher, executable: platform.gitExecutable),
      journalIO: journalIO, maintenanceLimits: maintenanceLimits)
  }

  package func list() throws -> [RecoveryStoreView] {
    _ = try principal()
    return try worktrees.list()
  }

  package func reviewRelease(
    storeKey: String, generation: UUID, selections: [RecoveryRecordSelection]
  ) throws -> RecoveryReleaseReview {
    try worktrees.reviewRelease(
      key: storeKey, generation: generation, selections: selections, principal: principal())
  }

  package func confirm(_ review: RecoveryReleaseReview) throws -> RecoveryOperationStatus {
    try worktrees.confirm(review, principal: principal())
  }

  package func prepareMaintenance(storeKey: String, generation: UUID) throws
    -> RecoveryMaintenancePreparation
  {
    try worktrees.prepareMaintenance(key: storeKey, generation: generation, principal: principal())
  }

  package func run(_ review: RecoveryMaintenanceReview) throws -> RecoveryOperationStatus {
    try worktrees.run(review, principal: principal())
  }

  package func operation(handle: RecoveryOperationHandle) throws -> RecoveryOperationLookup {
    try worktrees.operation(handle, principal: principal())
  }

  package func resume(handle: RecoveryOperationHandle) throws -> RecoveryOperationStatus {
    try worktrees.resume(handle, principal: principal())
  }

  private func principal() throws -> String {
    guard owner.caller == .localApp, owner.profileID == .localAdmin,
      let id = owner.trustedPrincipalID, !id.isEmpty, id.utf8.count <= 1024
    else { throw WorktreeRecoveryOwnerError.unauthorized }
    return id
  }
}

private struct GatewayRecoveryDependencyReader: WorktreeRecoveryDependencyReading {
  let database: GatewayDatabase

  func recoveryEvidence(
    for repository: WorktreeRepositoryIdentity, sources: Set<DerivedProjectSource>
  )
    throws -> WorktreeRecoveryDependencyEvidence
  {
    try database.connection.writer.read { sql in
      try evidence(in: sql, repository: repository, sources: sources)
    }
  }

  func validateRecoveryEvidence(
    _ expected: WorktreeRecoveryDependencyEvidence,
    for repository: WorktreeRepositoryIdentity, sources: Set<DerivedProjectSource>,
    commit: () throws -> Void
  ) throws -> Bool {
    try database.connection.writer.write { sql in
      guard try evidence(in: sql, repository: repository, sources: sources) == expected else {
        return false
      }
      try commit()
      return true
    }
  }

  private func evidence(
    in sql: Database, repository: WorktreeRepositoryIdentity, sources: Set<DerivedProjectSource>
  ) throws -> WorktreeRecoveryDependencyEvidence {
    let sourceIDs = Set(sources.map(\.id))
    let derived = try SQLiteDerivedProjectStore.records(sql).filter {
      $0.source.root == repository.sourcePath || sourceIDs.contains($0.source.id)
        || $0.worktree?.repository == repository
    }
    let canonicalRoots = Dictionary(
      grouping: try ProjectCanonicalRootRecord.fetchAll(sql), by: \.projectID)
    let registrations = try ProjectRecord.order(Column("id")).fetchAll(sql).compactMap {
      project -> DerivedProjectSource? in
      let owned = canonicalRoots[project.id]?.first {
        $0.createdAt.databaseValue == project.createdAt.databaseValue
      }
      let root = owned?.canonicalRootPath ?? project.rootPath
      guard sourceIDs.contains(project.id) || root == repository.sourcePath else { return nil }
      return .init(id: project.id, root: root, registeredAt: project.createdAt)
    }
    let liveSourceIDs = sourceIDs.union(registrations.map(\.id)).union(derived.map(\.source.id))
    let projectIDs = Set(derived.map(\.projectID))
    let protections = try SQLiteDerivedProjectStore.protectedBranches(
      in: sql, repositoryKey: repository.protectionKey
    ).filter { $0.repository == repository.commonDirectory }
    let unfinished = try HostOperationStore.unfinished(in: sql, byteLimit: 128 * 1024 * 1024)
      .compactMap { operation -> WorktreeRecoveryDependencyEvidence.Activity? in
        let binding = operation.binding
        guard
          liveSourceIDs.contains(binding.admission.sourceProjectID)
            || projectIDs.contains(binding.admission.projectID)
        else { return nil }
        return .init(id: operation.id, revision: operation.state.rawValue)
      }
    let rows = try Row.fetchCursor(
      sql,
      sql: """
        SELECT id, payload FROM permissionRuntimeExecutions
        WHERE json_extract(CAST(payload AS TEXT), '$.worktreeUse') IS NOT NULL
          AND json_extract(CAST(payload AS TEXT), '$.completed') IS NOT 1
        ORDER BY id
        """)
    var executions: [WorktreeRecoveryDependencyEvidence.Activity] = []
    var remaining = 128 * 1024 * 1024
    while let row = try rows.next() {
      let payload: Data = row["payload"]
      guard payload.count <= remaining else {
        throw WorktreeError.busy("Execution dependency evidence exceeds its byte bound.")
      }
      remaining -= payload.count
      let execution = try ExecutionRuntimeRecord.decode(payload)
      guard row["id"] == execution.id.uuidString, let use = execution.worktreeUse,
        !execution.completed
      else { throw PermissionPersistenceError.invalidCurrentState }
      if projectIDs.contains(use.admission.projectID) {
        executions.append(.init(id: execution.id, revision: use.admission.generation.uuidString))
      }
    }
    return .init(
      registrations: registrations, derived: derived, protections: protections,
      unfinishedOperations: unfinished, executions: executions)
  }
}
