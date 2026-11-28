import Combine
import ComputerMCPGateway
import ComputerMCPPermissions
import Foundation

@MainActor
protocol WorktreeRecoveryServicing {
  func fetchProjectWorktrees() async throws -> [ProjectWorktreeInventory]
  func fetchRecoveryStores() async throws -> [RecoveryStoreView]
  func worktreeRecoveryEpoch() async throws -> UUID
  func reviewWorktreeRemoval(_ target: ManagedWorktreeRemovalTarget, epoch: UUID) async throws
    -> ManagedWorktreeRemovalReview
  func confirmWorktreeRemoval(
    _ review: ManagedWorktreeRemovalReview, discard: Bool, epoch: UUID
  ) async throws
  func worktreeRemovalOutcome(_ review: ManagedWorktreeRemovalReview) async throws
    -> ManagedWorktreeRemovalOutcome
  func reviewRecoveryRelease(
    storeKey: String, generation: UUID, selections: [RecoveryRecordSelection], epoch: UUID
  ) async throws -> RecoveryReleaseReview
  func confirmRecoveryRelease(_ review: RecoveryReleaseReview, epoch: UUID) async throws
    -> RecoveryOperationStatus
  func prepareRecoveryMaintenance(storeKey: String, generation: UUID, epoch: UUID) async throws
    -> RecoveryMaintenancePreparation
  func runRecoveryMaintenance(_ review: RecoveryMaintenanceReview, epoch: UUID) async throws
    -> RecoveryOperationStatus
  func recoveryOperation(handle: RecoveryOperationHandle) async throws -> RecoveryOperationLookup
  func resumeRecoveryOperation(handle: RecoveryOperationHandle, epoch: UUID) async throws
    -> RecoveryOperationStatus
}

struct RecoveryStoreIdentity: Hashable {
  let key: String
  let generation: UUID

  init(_ store: RecoveryStoreView) {
    key = store.key
    generation = store.generation
  }

  init(_ handle: RecoveryOperationHandle) {
    key = handle.storeKey
    generation = handle.generation
  }
}

struct RetainedRecoverySelection: Hashable {
  let store: RecoveryStoreIdentity
  let recordID: UUID
  let revision: Int64
  let oid: String

  init(store: RecoveryStoreIdentity, record: RecoveryRecordView) {
    self.store = store
    recordID = record.id
    revision = record.revision
    oid = record.oid
  }

  var selection: RecoveryRecordSelection { .init(recordID: recordID, revision: revision, oid: oid) }
}

struct RecoveryWorktreeRow: Identifiable {
  enum ID: Hashable {
    case managed(UUID)
    case foreign(String)
  }

  enum State {
    case active, removed, foreign, unavailable
  }

  let id: ID
  let state: State
  let name: String
  let path: String?
  let dirty: Bool?
  let target: ManagedWorktreeRemovalTarget?

  init?(_ entry: ProjectWorktreeView, source: RecoverySource) {
    if let worktreeID = entry.worktreeID {
      id = .managed(worktreeID)
      if entry.lifecycleState == .active, entry.isInspectable, entry.dirty != nil,
        let projectID = entry.projectID, let generation = entry.storageGeneration,
        let revision = entry.lifecycleRevision
      {
        state = .active
        target = .init(
          source: source, projectID: projectID, worktreeID: worktreeID, generation: generation,
          revision: revision)
      } else {
        state = .unavailable
        target = nil
      }
    } else if let path = entry.path, entry.projectID == nil {
      id = .foreign(path)
      state = .foreign
      target = nil
    } else {
      return nil
    }
    name = entry.branch ?? entry.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "—"
    path = entry.path
    dirty = entry.dirty
  }

  init(removed id: UUID, branch: String, path: String? = nil) {
    self.id = .managed(id)
    state = .removed
    name = branch
    self.path = path
    dirty = nil
    target = nil
  }
}

enum RecoveryOperationReview: Equatable {
  case release(RecoveryReleaseReview)
  case maintenance(RecoveryMaintenanceReview)

  var handle: RecoveryOperationHandle {
    switch self {
    case .release(let review): review.handle
    case .maintenance(let review): review.handle
    }
  }

  init(_ status: RecoveryOperationStatus) {
    switch status.request {
    case .release(let review): self = .release(review)
    case .maintenance(let review): self = .maintenance(review)
    }
  }
}

struct RecoveryIssue: Identifiable {
  let id = UUID()
  let key: String
  let details: String?

  init(_ key: String, details: String? = nil) {
    self.key = key
    self.details = details
  }

  init(_ error: any Error) {
    switch error {
    case PermissionModelError.authoritySuspended:
      self.init("recovery.restore_review")
    case PermissionModelError.revisionConflict, RecoveryOwnerError.storeChanged,
      RecoveryOwnerError.identityConflict, WorktreeCleanupError.identityChanged:
      self.init("recovery.review_changed")
    default:
      self.init("recovery.operation_failed", details: AppLocalization.errorDescription(error))
    }
  }
}

@MainActor
final class WorktreeRecoveryModel: ObservableObject {
  struct Operation: Identifiable {
    let review: RecoveryOperationReview
    var epoch: UUID?
    var status: RecoveryOperationStatus?
    var issue: RecoveryIssue?
    var measuredAt: Date?

    var id: UUID { review.handle.id }

    var canResume: Bool {
      guard let status else { return true }
      if case .recoveryRequired = status.outcome { return false }
      if status.gates.contains(where: { $0.cleanup == .pending }) { return true }
      if case .pending = status.outcome { return true }
      return false
    }
  }

  struct Removal: Identifiable {
    let review: ManagedWorktreeRemovalReview
    let epoch: UUID
    let discard: Bool
    var outcome: ManagedWorktreeRemovalOutcome?
    var issue: RecoveryIssue?

    var id: UUID { review.operationID }

    var canResume: Bool { outcome == nil || outcome == .uncertain }
  }

  @Published private(set) var inventory: [ProjectWorktreeInventory]?
  @Published private(set) var stores: [RecoveryStoreView]?
  @Published private(set) var inventoryIssue: RecoveryIssue?
  @Published private(set) var storesIssue: RecoveryIssue?
  @Published private(set) var authorityIssue: RecoveryIssue?
  @Published private(set) var epoch: UUID?
  @Published private(set) var isWorking = false
  @Published private(set) var activeOperationID: UUID?
  @Published private(set) var operations: [Operation] = []
  @Published private(set) var removals: [Removal] = []
  @Published var issue: RecoveryIssue?

  private let service: any WorktreeRecoveryServicing

  init(service: any WorktreeRecoveryServicing) {
    self.service = service
  }

  var canChange: Bool { !isWorking && epoch != nil }
  var retainedCount: Int {
    stores?.reduce(0) { $0 + $1.records.filter { $0.state == .retained }.count } ?? 0
  }

  func refresh() async {
    guard !isWorking else { return }
    isWorking = true
    await Task { await reload() }.value
    isWorking = false
  }

  private func reload() async {
    async let worktrees: Void = loadWorktrees()
    async let recovery: Void = loadStores()
    async let authority: Void = loadAuthority()
    _ = await (worktrees, recovery, authority)
  }

  private func loadWorktrees() async {
    do {
      inventory = try await service.fetchProjectWorktrees()
      inventoryIssue = nil
    } catch is CancellationError {
    } catch {
      inventoryIssue = RecoveryIssue(error)
    }
  }

  private func loadStores() async {
    do {
      let values = try await service.fetchRecoveryStores()
      stores = values
      storesIssue = nil
      for status in values.compactMap(\.activeOperation) {
        let review = RecoveryOperationReview(status)
        var operation =
          operations.first { $0.id == review.handle.id && $0.review == review }
          ?? Operation(review: review)
        operation.status = status
        remember(operation)
      }
    } catch is CancellationError {
    } catch {
      storesIssue = RecoveryIssue(error)
    }
  }

  private func loadAuthority() async {
    do {
      epoch = try await service.worktreeRecoveryEpoch()
      authorityIssue = nil
    } catch is CancellationError {
    } catch {
      epoch = nil
      authorityIssue = RecoveryIssue(error)
    }
  }

  func projectInventory(id: String, registeredAt: Date?) -> ProjectWorktreeInventory? {
    guard let registeredAt else { return nil }
    return inventory?.first {
      $0.source.id == id && $0.source.registeredAt == registeredAt
    }
  }

  func stores(for project: ProjectWorktreeInventory?) -> [RecoveryStoreView] {
    guard let project else { return [] }
    return (stores ?? []).filter { store in
      project.repository == store.repository
        || store.records.contains { $0.owner.source == project.source }
        || operations.contains { operation in
          guard RecoveryStoreIdentity(operation.review.handle) == RecoveryStoreIdentity(store),
            case .release(let review) = operation.review
          else { return false }
          return review.records.contains { $0.owner.source == project.source }
        }
    }
  }

  func worktrees(for project: ProjectWorktreeInventory) -> [RecoveryWorktreeRow] {
    var rows = project.worktrees.compactMap { RecoveryWorktreeRow($0, source: project.source) }
    var known = Set(rows.map(\.id))
    for removal in removals where removal.review.target.source == project.source {
      guard case .removed = removal.outcome,
        known.insert(.managed(removal.review.target.worktreeID)).inserted
      else { continue }
      rows.append(
        .init(
          removed: removal.review.target.worktreeID, branch: removal.review.branch,
          path: removal.review.path))
    }
    for store in stores(for: project) {
      for record in store.records where record.owner.source == project.source {
        let id = record.owner.worktreeID
        guard store.removedWorktreeIDs.contains(id), known.insert(.managed(id)).inserted else {
          continue
        }
        rows.append(
          .init(removed: id, branch: String(record.owner.branch.dropFirst("refs/heads/".count))))
      }
    }
    return rows
  }

  func reviewRemoval(_ target: ManagedWorktreeRemovalTarget) async
    -> (ManagedWorktreeRemovalReview, UUID)?
  {
    guard inventoryIssue == nil else { return nil }
    return await reviewing { epoch in
      (try await service.reviewWorktreeRemoval(target, epoch: epoch), epoch)
    }
  }

  func reviewRelease(_ choices: Set<RetainedRecoverySelection>) async
    -> (RecoveryReleaseReview, UUID)?
  {
    guard storesIssue == nil, let target = choices.first?.store,
      choices.allSatisfy({ $0.store == target }),
      let store = stores?.first(where: { RecoveryStoreIdentity($0) == target }),
      choices.isSubset(
        of: Set(
          store.records.filter { canSelect($0, in: store) }.map {
            RetainedRecoverySelection(store: target, record: $0)
          }))
    else {
      issue = RecoveryIssue("recovery.review_changed")
      return nil
    }
    return await reviewing { epoch in
      let selections = choices.map(\.selection)
      let review = try await service.reviewRecoveryRelease(
        storeKey: target.key, generation: target.generation, selections: selections, epoch: epoch)
      guard RecoveryStoreIdentity(review.handle) == target,
        Set(review.records.map { RetainedRecoverySelection(store: target, record: $0) }) == choices
      else { throw RecoveryOwnerError.identityConflict }
      return (review, epoch)
    }
  }

  func canSelect(_ record: RecoveryRecordView, in store: RecoveryStoreView) -> Bool {
    record.state == .retained && (store.dependencies[record.id] ?? []).isEmpty
  }

  func prepareMaintenance(_ store: RecoveryStoreIdentity) async -> (
    RecoveryMaintenanceReview, UUID
  )? {
    guard storesIssue == nil,
      stores?.contains(where: { RecoveryStoreIdentity($0) == store }) == true
    else { return nil }
    return await reviewing { epoch in
      switch try await service.prepareRecoveryMaintenance(
        storeKey: store.key, generation: store.generation, epoch: epoch)
      {
      case .reviewed(let review):
        guard RecoveryStoreIdentity(review.handle) == store else {
          throw RecoveryOwnerError.identityConflict
        }
        return (review, epoch)
      case .deferred(let details):
        issue = RecoveryIssue("storage.reclamation_deferred", details: details)
      case .recoveryRequired(let details):
        issue = RecoveryIssue("recovery.requires_attention", details: details)
      }
      return nil
    }
  }

  private func reviewing<T>(_ action: (UUID) async throws -> T?) async -> T? {
    guard canChange, let epoch else { return nil }
    isWorking = true
    defer { isWorking = false }
    do {
      return try await action(epoch)
    } catch is CancellationError {
      return nil
    } catch {
      issue = RecoveryIssue(error)
      await reload()
      return nil
    }
  }

  func confirmRemoval(_ review: ManagedWorktreeRemovalReview, discard: Bool, epoch: UUID) async {
    guard discard == review.hasUncommittedChanges else { return }
    await runRemoval(.init(review: review, epoch: epoch, discard: discard))
  }

  func retryRemoval(_ removal: Removal) async {
    guard removals.contains(where: { $0.id == removal.id && $0.canResume }) else { return }
    await runRemoval(removal)
  }

  private func runRemoval(_ previous: Removal) async {
    guard start(previous.id, epoch: previous.epoch) else { return }
    removals.removeAll {
      $0.review.target.worktreeID == previous.review.target.worktreeID && $0.id != previous.id
        && !$0.canResume
    }
    var result = previous
    result.issue = nil
    remember(result)
    do {
      switch try await service.worktreeRemovalOutcome(result.review) {
      case .notStarted, .uncertain:
        try await service.confirmWorktreeRemoval(
          result.review, discard: result.discard, epoch: result.epoch)
      case .created, .removed, .refused:
        break
      }
    } catch {
      result.issue = RecoveryIssue(error)
    }
    do {
      result.outcome = try await service.worktreeRemovalOutcome(result.review)
      if case .removed = result.outcome { result.issue = nil }
      if result.outcome == .notStarted, result.issue?.key == "recovery.operation_failed" {
        result.outcome = nil
      }
    } catch {
      result.issue = RecoveryIssue(error)
    }
    remember(result)
    await finish()
  }

  func confirm(_ review: RecoveryOperationReview, epoch: UUID) async {
    await run(.init(review: review, epoch: epoch))
  }

  func retry(_ operation: Operation) async {
    guard operations.contains(where: { $0.id == operation.id && $0.canResume }) else { return }
    await run(operation)
  }

  private func run(_ previous: Operation) async {
    guard let currentEpoch = epoch, start(previous.id, epoch: previous.epoch ?? currentEpoch) else {
      return
    }
    let review = previous.review
    let handle = review.handle
    var result = previous
    result.epoch = currentEpoch
    result.issue = nil
    remember(result)
    do {
      switch try await service.recoveryOperation(handle: handle) {
      case .submitted(let status):
        guard RecoveryOperationReview(status) == review else {
          throw RecoveryOwnerError.identityConflict
        }
        result.status = status
        if result.canResume {
          _ = try await service.resumeRecoveryOperation(handle: handle, epoch: currentEpoch)
        }
      case .unsubmitted:
        guard previous.status == nil else { throw RecoveryOwnerError.identityConflict }
        switch review {
        case .release(let review):
          _ = try await service.confirmRecoveryRelease(review, epoch: currentEpoch)
        case .maintenance(let review):
          _ = try await service.runRecoveryMaintenance(review, epoch: currentEpoch)
        }
      }
    } catch {
      result.issue = RecoveryIssue(error)
    }
    do {
      if case .submitted(let status) = try await service.recoveryOperation(handle: handle),
        RecoveryOperationReview(status) == review
      {
        result.status = status
        if case .measured = status.outcome { result.measuredAt = Date() }
        if case .released = status.outcome,
          !status.gates.contains(where: { $0.cleanup == .pending })
        {
          result.issue = nil
        }
      }
    } catch {
      result.issue = RecoveryIssue(error)
    }
    if result.status == nil, result.issue?.key != "recovery.operation_failed",
      let issue = result.issue
    {
      self.issue = issue
      operations.removeAll { $0.id == result.id }
    } else {
      remember(result)
    }
    await finish()
  }

  private func start(_ id: UUID, epoch confirmedEpoch: UUID) -> Bool {
    guard !isWorking else { return false }
    guard epoch == confirmedEpoch else {
      issue = RecoveryIssue(authorityIssue?.key ?? "recovery.review_changed")
      return false
    }
    isWorking = true
    activeOperationID = id
    return true
  }

  private func finish() async {
    await reload()
    activeOperationID = nil
    isWorking = false
  }

  private func remember(_ operation: Operation) {
    if let index = operations.firstIndex(where: { $0.id == operation.id }) {
      operations[index] = operation
    } else {
      operations.append(operation)
    }
  }

  private func remember(_ removal: Removal) {
    if let index = removals.firstIndex(where: { $0.id == removal.id }) {
      removals[index] = removal
    } else {
      removals.append(removal)
    }
  }
}
