import ComputerMCPCore
import ComputerMCPPersistence
import ComputerMCPPlatform
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
package typealias RecoveryRecordView = ComputerMCPWorktrees.WorktreeRecoveryRecord
package typealias RecoverySource = ComputerMCPWorktrees.DerivedProjectSource
package typealias RecoveryOwnerError = ComputerMCPWorktrees.WorktreeRecoveryOwnerError
package typealias WorktreeCleanupError = ComputerMCPWorktrees.WorktreeError
package typealias ManagedWorktreeRemovalTarget = ComputerMCPWorktrees.ManagedWorktreeRemovalTarget
package typealias ManagedWorktreeRemovalReview = ComputerMCPWorktrees.ManagedWorktreeRemovalReview
package typealias ManagedWorktreeRemovalOutcome = ComputerMCPWorktrees.WorktreeOperationOutcome

/// In-process authority for the trusted App owner. Creating this service
/// installs no commands in the gateway, CLI, or control socket.
package struct GatewayRecoveryOwnerService: Sendable {
  private let owner: ExecutionContext
  private let worktrees: WorktreeRecoveryOwnerService
  private let database: GatewayDatabase
  private let platform: PlatformServices
  private let storage: WorktreeStorage

  package init(
    database: GatewayDatabase, platform: PlatformServices, owner: ExecutionContext,
    journalIO: WorktreeJournalIO = .init(), maintenanceLimits: WorktreePromotionLimits = .init()
  ) throws {
    guard let storage = database.worktreeStorage else {
      throw WorktreeRecoveryOwnerError.unavailable
    }
    self.owner = owner
    self.database = database
    self.platform = platform
    self.storage = storage
    worktrees = try WorktreeRecoveryOwnerService(
      storage: storage, derived: database.derivedProjectStore(inspectNesting: { _ in [] }),
      dependencies: GatewayRecoveryDependencyReader(database: database),
      executor: GatewayWorktreeGit(launcher: platform.launcher, executable: platform.gitExecutable),
      journalIO: journalIO, maintenanceLimits: maintenanceLimits)
  }

  package func list() throws -> [RecoveryStoreView] {
    try worktrees.list(principal: principal())
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

  package func reviewRemoval(
    _ target: ManagedWorktreeRemovalTarget, validate: @escaping @Sendable () throws -> Void
  ) throws -> ManagedWorktreeRemovalReview {
    let (repository, access) = try removalRepository(source: target.source, validate: validate)
    defer { access.close() }
    return try repository.reviewRemoval(target)
  }

  package func remove(
    _ review: ManagedWorktreeRemovalReview, discard: Bool,
    validate: @escaping @Sendable () throws -> Void
  ) async throws {
    let (repository, access) = try removalRepository(
      source: review.target.source, validate: validate)
    defer { access.close() }
    let coordinator = try database.permissionRuntime(platform: platform).coordinator
    _ = try await repository.remove(
      projectID: review.target.projectID, force: discard, operationID: review.operationID,
      review: review,
      terminate: { admission, operationID in
        try await coordinator.terminateWorktreeWriters(
          admission, operationID: operationID, until: .now.advanced(by: .seconds(30)))
      },
      authorize: { record, paths in
        if paths.isEmpty { try validate() }
        guard record.source == review.target.source,
          record.provenance
            == .host(
              worktreeID: review.target.worktreeID, storageGeneration: review.target.generation)
        else { throw WorktreeError.identityChanged("Worktree ownership changed.") }
      })
  }

  package func removalOutcome(_ review: ManagedWorktreeRemovalReview) throws
    -> ManagedWorktreeRemovalOutcome
  {
    _ = try principal()
    let outcome = try storage.removalOutcome(
      projectID: review.target.projectID, operationID: review.operationID
    ) {
      try !database.derivedProjects().contains { $0.projectID == review.target.projectID }
    }
    if case .removed(let result) = outcome, result.oid != review.head {
      throw WorktreeError.identityChanged("Removal readback refers to a different commit.")
    }
    return outcome
  }

  private func removalRepository(
    source: DerivedProjectSource, validate: @escaping @Sendable () throws -> Void
  ) throws -> (WorktreeRepository, ResolvedProjectAccess) {
    _ = try principal()
    try validate()
    guard let project = try database.project(id: source.id) else {
      throw WorktreeError.identityChanged("The source project is unavailable.")
    }
    let access = try platform.projectGrants.resolve(project)
    let root = URL(fileURLWithPath: source.root, isDirectory: true)
    @Sendable func checkSource() throws {
      try validate()
      guard access.isActive, let current = try database.project(id: source.id),
        current.createdAt == source.registeredAt,
        GatewayDatabase.canonicalProjectRoot(current.rootPath) == source.root,
        try ProjectRootIdentity(root) == access.rootIdentity
      else { throw WorktreeError.identityChanged("The registered source project changed.") }
    }
    do {
      let repository = try WorktreeRepository(
        source: source, store: database.derivedProjectStore(inspectNesting: { _ in [] }),
        storage: storage,
        executor: GatewayWorktreeGit(
          launcher: platform.launcher, executable: platform.gitExecutable),
        registeredProjectRoots: try database.projects().map { URL(fileURLWithPath: $0.rootPath) },
        timeoutMilliseconds: 30_000, maxOutputBytes: 16_777_216, lockTimeout: .seconds(30),
        owner: .init(bootSessionID: platform.launcher.bootSessionID),
        journalIO: .init(beforePublication: checkSource), checkAuthority: checkSource)
      return (repository, access)
    } catch {
      access.close()
      throw error
    }
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
