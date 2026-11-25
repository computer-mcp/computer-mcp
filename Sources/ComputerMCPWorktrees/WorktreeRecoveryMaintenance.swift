import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

struct WorktreeRecoveryWithdrawal: Codable, Equatable, Sendable {
  enum Phase: String, Codable, Sendable {
    case withdrawing, verifying, restoringDeferred, restoringRecovery, disposing
  }

  let packQuarantine: String
  let indexQuarantine: String
  var phase: Phase = .withdrawing
  var reason: String?

  init(id: UUID) {
    let prefix = "owner-" + id.uuidString.lowercased()
    packQuarantine = prefix + ".pack.quarantine"
    indexQuarantine = prefix + ".idx.quarantine"
  }

  func validate(review: RecoveryMaintenanceReview) throws {
    let expected = Self(id: review.handle.id)
    guard review.proof.candidate != nil, packQuarantine == expected.packQuarantine,
      indexQuarantine == expected.indexQuarantine,
      (reason != nil) == [.restoringDeferred, .restoringRecovery].contains(phase)
    else { throw invalidRecoveryMetadata() }
  }

  var names: Set<String> { [packQuarantine, indexQuarantine] }
}

extension WorktreeRecoveryOwnerService {
  package func prepareMaintenance(key: String, generation: UUID, principal: String) throws
    -> RecoveryMaintenancePreparation
  {
    try requirePrincipal(principal)
    let deadline = ContinuousClock.now.advanced(by: limits.duration)
    do {
      let snapshot = try stores.withExisting(key: key, generation: generation, exclusive: false) {
        store in
        try store.requireMaintenanceIdle()
        return (store.repository, try store.observedCatalog().catalog)
      }
      let evidence = try maintenanceEvidence(
        repository: snapshot.0, catalog: snapshot.1, live: liveSource(snapshot.0),
        deadline: deadline)
      let proof = try stores.withExisting(key: key, generation: generation, exclusive: false) {
        store in
        try store.requireMaintenanceIdle()
        let current = try store.observedCatalog()
        guard current.catalog == snapshot.1 else {
          throw WorktreeError.busy("Recovery catalog changed during preparation.")
        }
        return try proveMaintenance(in: store, catalog: current, deadline: deadline)
      }
      guard
        try dependencies.recoveryEvidence(for: snapshot.0, sources: evidence.sources)
          == evidence.sql
      else { return .deferred("Recovery dependencies changed during preparation.") }
      let handle = try RecoveryReviewedRequest.issue(
        proof, key: key, generation: generation, action: .maintenance, principal: principal)
      return .reviewed(.init(handle: handle, proof: proof))
    } catch WorktreeError.busy(let reason) {
      return .deferred(reason)
    } catch {
      guard isMaintenanceIntegrityFailure(error) else { throw error }
      return .recoveryRequired(error.localizedDescription)
    }
  }

  package func run(_ review: RecoveryMaintenanceReview, principal: String) throws
    -> RecoveryOperationStatus
  {
    try submitMaintenance(review.handle, review: review, principal: principal)
  }

  func submitMaintenance(
    _ handle: RecoveryOperationHandle, review: RecoveryMaintenanceReview?, principal: String
  ) throws -> RecoveryOperationStatus {
    try requirePrincipal(principal)
    try validateHandle(handle)
    let start = ContinuousClock.now
    let deadline = start.advanced(by: limits.duration)
    let verificationDeadline = start.advanced(by: limits.duration * 2 / 3)
    let request = review.map(RecoveryReviewedRequest.maintenance)
    let initial = try withStore(handle) {
      store -> (RecoveryOperationStatus?, WorktreeRepositoryIdentity) in
      let current = try store.observeOwnerOperation(
        handle, principal: principal, request: request, synchronizing: true)
      if let result = current.result { return (result.record.status, store.repository) }
      if let entry = current.active, entry.record.handle == handle {
        return (
          try replayWithdrawal(
            entry, in: store, verificationDeadline: verificationDeadline, deadline: deadline),
          store.repository
        )
      }
      guard let request else { throw WorktreeRecoveryOwnerError.unsubmitted }
      guard current.active == nil else {
        throw WorktreeError.busy("Another owner operation has the active recovery journal.")
      }
      try checkSubmission(request, principal: principal, repository: store.repository)
      return (nil, store.repository)
    }
    if let status = initial.0 { return status }
    guard let review, let request else { throw WorktreeRecoveryOwnerError.unsubmitted }
    let repository = initial.1
    do {
      return try coordinate(repository, deadline: verificationDeadline) { live in
        let catalog = try withStore(handle, exclusive: false) { try $0.observedCatalog() }
        if WorktreeObjectSnapshot.digest(catalog.bytes) != review.proof.catalogDigest {
          return try refuseMaintenance(
            request, principal: principal, reason: .stale,
            verificationDeadline: verificationDeadline, deadline: deadline)
        }
        let firstPassDeadline = start.advanced(by: limits.duration / 3)
        let evidence: MaintenanceEvidence
        do {
          evidence = try maintenanceEvidence(
            repository: repository, catalog: catalog.catalog, live: live,
            deadline: firstPassDeadline)
        } catch WorktreeError.busy(let reason) {
          return try refuseMaintenance(
            request, principal: principal, reason: .deferred(reason),
            verificationDeadline: verificationDeadline, deadline: deadline)
        } catch {
          guard isMaintenanceIntegrityFailure(error) else { throw error }
          return try refuseMaintenance(
            request, principal: principal, reason: .recoveryRequired(error.localizedDescription),
            verificationDeadline: verificationDeadline, deadline: deadline)
        }
        return try withStore(handle) { store in
          let current = try store.observeOwnerOperation(
            handle, principal: principal, request: request, synchronizing: true)
          if let result = current.result { return result.record.status }
          if let active = current.active {
            guard active.record.handle == handle else {
              throw WorktreeError.busy("Another owner operation has the active recovery journal.")
            }
            return try replayWithdrawal(
              active, in: store, verificationDeadline: verificationDeadline, deadline: deadline)
          }
          let currentCatalog = try store.observedCatalog()
          var record = RecoveryOwnerJournal(request: request, principal: principal)
          do {
            if currentCatalog.bytes != catalog.bytes
              || WorktreeObjectSnapshot.digest(currentCatalog.bytes) != review.proof.catalogDigest
            {
              record.outcome = .stale
            } else {
              let proof = try proveMaintenance(
                in: store, catalog: currentCatalog, deadline: firstPassDeadline)
              if proof != review.proof {
                record.outcome = .stale
              } else if proof.candidate == nil {
                record.outcome = .measured(
                  try .init(baseline: proof.allocatedBytes, final: proof.allocatedBytes))
              } else {
                record.maintenance = .init(id: handle.id)
              }
            }
          } catch WorktreeError.busy(let reason) {
            record.outcome = .deferred(reason)
          } catch {
            guard isMaintenanceIntegrityFailure(error) else { throw error }
            record.outcome = .recoveryRequired(error.localizedDescription)
          }
          let entry: WorktreeRecoveryStore.Locked.OwnerEntry
          if record.maintenance != nil || record.outcome.isMeasured {
            guard try liveSource(repository) == live else {
              record.maintenance = nil
              record.outcome = .stale
              let refused = try store.saveOwnerOperation(record, replacing: nil)
              try store.publishOwnerResult(refused)
              return refused.record.status
            }
            var sealed: WorktreeRecoveryStore.Locked.OwnerEntry?
            let valid = try dependencies.validateRecoveryEvidence(
              evidence.sql, for: repository, sources: evidence.sources
            ) {
              sealed = try store.saveOwnerOperation(record, replacing: nil)
            }
            if valid, let sealed {
              entry = sealed
            } else {
              record.maintenance = nil
              record.outcome = .stale
              entry = try store.saveOwnerOperation(record, replacing: nil)
            }
          } else {
            entry = try store.saveOwnerOperation(record, replacing: nil)
          }
          return try replayWithdrawal(
            entry, in: store, verificationDeadline: verificationDeadline, deadline: deadline)
        }
      }
    } catch WorktreeError.identityChanged(let reason) {
      return try refuseMaintenance(
        request, principal: principal, reason: .recoveryRequired(reason),
        verificationDeadline: verificationDeadline, deadline: deadline)
    }
  }

  private func refuseMaintenance(
    _ request: RecoveryReviewedRequest, principal: String, reason: RecoveryOperationStatus.Outcome,
    verificationDeadline: ContinuousClock.Instant, deadline: ContinuousClock.Instant
  ) throws -> RecoveryOperationStatus {
    try withStore(request.handle) { store in
      let current = try store.observeOwnerOperation(
        request.handle, principal: principal, request: request, synchronizing: true)
      if let result = current.result { return result.record.status }
      if let active = current.active {
        guard active.record.handle == request.handle else {
          throw WorktreeError.busy("Another owner operation has the active recovery journal.")
        }
        return try replayWithdrawal(
          active, in: store, verificationDeadline: verificationDeadline, deadline: deadline)
      }
      let entry = try store.saveOwnerOperation(
        .init(request: request, principal: principal, outcome: reason), replacing: nil)
      if entry.record.isResult { try store.publishOwnerResult(entry) }
      return entry.record.status
    }
  }

  private func proveMaintenance(
    in store: WorktreeRecoveryStore.Locked,
    catalog: (catalog: WorktreeRecoveryCatalog, bytes: Data),
    deadline: ContinuousClock.Instant
  ) throws -> WorktreeRecoveryMaintenanceProof {
    guard catalog.catalog.intents.isEmpty,
      catalog.catalog.records.allSatisfy({ $0.state == .retained && $0.dependencies.isEmpty })
    else { throw WorktreeError.busy("Recovery catalog has pending lifecycle intents.") }
    let parent = try store.maintenanceNamespace()
    let budget = try WorktreeMaintenanceBudget(
      limits: limits, format: store.repository.format, deadline: deadline)
    let pool = maintenancePool(in: store, budget: budget)
    let inventory = try store.packInventory(parent, pool: pool, budget: budget)
    let closure = try store.maintenanceClosure(catalog.catalog, pool: pool)
    let pair = try inventory.candidate(for: closure.manifest)
    try budget.check()
    try store.checkIdentity()
    return try .init(
      catalogDigest: WorktreeObjectSnapshot.digest(catalog.bytes),
      inventoryDigest: inventory.digest(),
      survivingInventoryDigest: inventory.digest(excluding: pair?.hash),
      closureDigest: closure.digest,
      parent: parent?.identity, candidate: pair, allocatedBytes: inventory.allocatedBytes)
  }

  private func maintenancePool(
    in store: WorktreeRecoveryStore.Locked, budget: WorktreeMaintenanceBudget
  )
    -> WorktreeStagedObjects
  {
    .init(
      directory: store.objectsDirectory, repository: store.gitDirectory, git: git,
      format: store.repository.format, deadline: budget.deadline, limits: limits,
      maintenanceBudget: budget)
  }

  private struct MaintenanceEvidence {
    let sources: Set<DerivedProjectSource>
    let sql: WorktreeRecoveryDependencyEvidence
  }

  private func maintenanceEvidence(
    repository: WorktreeRepositoryIdentity, catalog: WorktreeRecoveryCatalog, live: Bool,
    deadline: ContinuousClock.Instant
  ) throws -> MaintenanceEvidence {
    let evidenceBudget = WorktreeRecoveryEvidenceBudget(deadline: deadline)
    try evidenceBudget.check()
    let placeholder = DerivedProjectSource(
      id: repository.source.path, root: repository.source.path, registeredAt: .distantPast)
    let journalReader = reader(repository, placeholder)
    let creations = try journalReader.recoveryCreations(account: evidenceBudget.account)
    let sources = Set(creations.map { $0.record.source }).union(catalog.records.map(\.owner.source))
    let sql = try dependencies.recoveryEvidence(for: repository, sources: sources)
    guard sql.unfinishedOperations.isEmpty, sql.executions.isEmpty,
      try journalReader.pendingRecoveryDeletions(account: evidenceBudget.account).isEmpty
    else { throw WorktreeError.busy("Recovery maintenance is waiting for lifecycle dependencies.") }
    var owners = Set(catalog.records.map(\.owner))
    for creation in creations {
      try evidenceBudget.check()
      guard [.active, .removed].contains(creation.phase),
        case .host(let id, let generation) = creation.record.provenance
      else { throw WorktreeError.busy("A worktree generation has unfinished lifecycle evidence.") }
      owners.insert(
        .init(
          source: creation.record.source, branchID: creation.branchID,
          branch: creation.branch, worktreeID: id, storageGeneration: generation))
    }
    let registrations = Set(sql.registrations)
    let derived = Dictionary(uniqueKeysWithValues: sql.derived.map { ($0.projectID, $0) })
    for owner in owners {
      try evidenceBudget.check()
      let reader = reader(repository, owner.source)
      guard
        try !reader.hasPendingRecoveryLifecycle(
          owner, generation: catalog.generation, account: evidenceBudget.account)
      else {
        throw WorktreeError.busy("An unfinished worktree journal protects the recovery store.")
      }
      if let record = derived[owner.projectID] {
        guard live, registrations.contains(owner.source) else {
          throw WorktreeError.busy("A live worktree depends on an unavailable source.")
        }
        _ = try reader.recoveryTopology(record, owner: owner)
      } else {
        let final = try reader.recoveryFinalCapture(
          owner, generation: catalog.generation, account: evidenceBudget.account)
        if let protection = sql.protections.first(where: owner.matches) {
          guard protection.publishedOID == final.oid else { throw invalidRecoveryMetadata() }
        }
      }
    }
    let ownerIDs = Set(owners.map(\.projectID))
    guard
      !sql.derived.contains(where: {
        $0.worktree?.repository == repository && !ownerIDs.contains($0.projectID)
      })
    else { throw invalidRecoveryMetadata() }
    try evidenceBudget.check()
    return .init(sources: sources, sql: sql)
  }

  private func replayWithdrawal(
    _ original: WorktreeRecoveryStore.Locked.OwnerEntry, in store: WorktreeRecoveryStore.Locked,
    verificationDeadline: ContinuousClock.Instant, deadline: ContinuousClock.Instant
  ) throws -> RecoveryOperationStatus {
    if original.record.isResult {
      try store.publishOwnerResult(original)
      return original.record.status
    }
    if case .recoveryRequired = original.record.outcome { return original.record.status }
    guard case .maintenance(let review) = original.record.request,
      let pair = review.proof.candidate, let expectedParent = review.proof.parent,
      var withdrawal = original.record.maintenance
    else { throw invalidRecoveryMetadata() }
    var entry = original
    func phase(_ next: WorktreeRecoveryWithdrawal.Phase, reason: String? = nil) throws {
      withdrawal.phase = next
      withdrawal.reason = reason
      entry = try store.saveOwnerOperation(
        entry.record.advanced { $0.maintenance = withdrawal }, replacing: entry)
    }
    func drive() throws -> RecoveryOperationStatus.Outcome {
      let catalog = try store.observedCatalog()
      guard WorktreeObjectSnapshot.digest(catalog.bytes) == review.proof.catalogDigest,
        let parent = try store.maintenanceNamespace(), parent.identity == expectedParent
      else { throw invalidRecoveryMetadata() }
      let files = WithdrawalFiles(
        pair: pair, withdrawal: withdrawal, parent: parent, io: io, deadline: deadline)
      if withdrawal.phase == .withdrawing {
        try files.withdraw()
        try phase(.verifying)
      }
      if withdrawal.phase == .verifying {
        do {
          try files.requireQuarantined()
          let budget = try WorktreeMaintenanceBudget(
            limits: limits, format: store.repository.format, deadline: verificationDeadline)
          let pool = maintenancePool(in: store, budget: budget)
          let inventory = try store.packInventory(
            parent, pool: pool, budget: budget, quarantined: withdrawal.names)
          let closure = try store.maintenanceClosure(catalog.catalog, pool: pool)
          guard try inventory.digest() == review.proof.survivingInventoryDigest,
            closure.digest == review.proof.closureDigest
          else { throw invalidRecoveryMetadata() }
          try budget.check()
          try files.requireQuarantined()
        } catch WorktreeError.busy(let reason) {
          try phase(.restoringDeferred, reason: reason)
        } catch is CancellationError {
          try phase(.restoringDeferred, reason: "Recovery object verification was interrupted.")
        } catch {
          guard isMaintenanceIntegrityFailure(error) else { throw error }
          try phase(.restoringRecovery, reason: error.localizedDescription)
        }
        if withdrawal.phase == .verifying { try phase(.disposing) }
      }
      if [.restoringDeferred, .restoringRecovery].contains(withdrawal.phase) {
        try files.restore()
        let budget = try WorktreeMaintenanceBudget(
          limits: limits, format: store.repository.format, deadline: deadline)
        let inventory = try store.packInventory(parent, pool: nil, budget: budget)
        guard try inventory.digest() == review.proof.inventoryDigest,
          inventory.allocatedBytes == review.proof.allocatedBytes, let reason = withdrawal.reason
        else { throw invalidRecoveryMetadata() }
        return withdrawal.phase == .restoringDeferred
          ? .deferred(reason) : .recoveryRequired(reason)
      }
      guard withdrawal.phase == .disposing else { throw invalidRecoveryMetadata() }
      try files.dispose()
      let budget = try WorktreeMaintenanceBudget(
        limits: limits, format: store.repository.format, deadline: deadline)
      let surviving = try store.packInventory(parent, pool: nil, budget: budget)
      let removed = try checkedAllocation(pair.pack.allocatedBytes, pair.index.allocatedBytes)
      guard try surviving.digest() == review.proof.survivingInventoryDigest,
        try checkedAllocation(surviving.allocatedBytes, removed) == review.proof.allocatedBytes
      else { throw invalidRecoveryMetadata() }
      return try .measured(
        .init(baseline: review.proof.allocatedBytes, final: surviving.allocatedBytes))
    }
    let outcome: RecoveryOperationStatus.Outcome
    do {
      outcome = try drive()
    } catch {
      guard isMaintenanceIntegrityFailure(error) else { throw error }
      outcome = .recoveryRequired(error.localizedDescription)
    }
    entry = try store.saveOwnerOperation(
      entry.record.advanced { $0.outcome = outcome }, replacing: entry)
    if entry.record.isResult { try store.publishOwnerResult(entry) }
    return entry.record.status
  }
}

private struct WithdrawalFiles {
  let pair: WorktreeRecoveryPackPair
  let withdrawal: WorktreeRecoveryWithdrawal
  let parent: WorktreeDirectory
  let io: WorktreeJournalIO
  let deadline: ContinuousClock.Instant

  struct Entry {
    let file: WorktreeRecoveryPackPair.File
    let installed: String
    let quarantined: String
  }

  var pack: Entry {
    .init(file: pair.pack, installed: pair.packName, quarantined: withdrawal.packQuarantine)
  }
  var index: Entry {
    .init(file: pair.index, installed: pair.indexName, quarantined: withdrawal.indexQuarantine)
  }

  enum Location { case installed, quarantined, disposed }

  func location(_ entry: Entry) throws -> Location {
    let original = try parent.hasEntry(entry.installed)
    let quarantine = try parent.hasEntry(entry.quarantined)
    guard !original || !quarantine else { throw invalidRecoveryMetadata() }
    if !original && !quarantine { return .disposed }
    try requirePackFile(
      entry.file, named: original ? entry.installed : entry.quarantined, in: parent)
    return original ? .installed : .quarantined
  }

  func withdraw() throws {
    let packLocation = try location(pack)
    let indexLocation = try location(index)
    guard packLocation != .disposed, indexLocation != .disposed,
      packLocation == .installed || indexLocation == .quarantined
    else { throw invalidRecoveryMetadata() }
    try move(
      index, from: index.installed, to: index.quarantined, needed: indexLocation == .installed)
    try move(pack, from: pack.installed, to: pack.quarantined, needed: packLocation == .installed)
  }

  func requireQuarantined() throws {
    guard try location(pack) == .quarantined, try location(index) == .quarantined
    else { throw invalidRecoveryMetadata() }
    try verifyFile(pack, name: pack.quarantined)
    try verifyFile(index, name: index.quarantined)
    try sync()
  }

  func restore() throws {
    let packLocation = try location(pack)
    let indexLocation = try location(index)
    guard packLocation != .disposed, indexLocation != .disposed,
      packLocation == .installed || indexLocation == .quarantined
    else { throw invalidRecoveryMetadata() }
    try move(pack, from: pack.quarantined, to: pack.installed, needed: packLocation == .quarantined)
    try move(
      index, from: index.quarantined, to: index.installed, needed: indexLocation == .quarantined)
  }

  func dispose() throws {
    let indexLocation = try location(index)
    let packLocation = try location(pack)
    guard indexLocation != .installed, packLocation != .installed,
      packLocation == .quarantined || indexLocation == .disposed
    else { throw invalidRecoveryMetadata() }
    for (entry, location) in [(index, indexLocation), (pack, packLocation)] {
      if location == .quarantined {
        try io.beforePublication()
        try verifyFile(entry, name: entry.quarantined)
        guard try !parent.hasEntry(entry.installed) else { throw invalidRecoveryMetadata() }
        guard unlinkat(parent.descriptor, entry.quarantined, 0) == 0 else {
          throw WorktreeDirectory.posixError()
        }
      }
      guard try !parent.hasEntry(entry.installed), try !parent.hasEntry(entry.quarantined)
      else { throw invalidRecoveryMetadata() }
      try sync()
    }
  }

  private func move(_ entry: Entry, from: String, to: String, needed: Bool) throws {
    if needed {
      try io.beforePublication()
      try verifyFile(entry, name: from)
      try parent.renameExclusive(from, to: to)
      try requirePackFile(entry.file, named: to, in: parent)
    } else {
      try verifyFile(entry, name: to)
    }
    guard try !parent.hasEntry(from) else { throw invalidRecoveryMetadata() }
    try sync()
  }

  private func verifyFile(_ entry: Entry, name: String) throws {
    guard ContinuousClock.now < deadline else {
      throw WorktreeError.busy("Recovery pack transition exceeded its deadline.")
    }
    guard try packFile(name, in: parent, limit: entry.file.length) == entry.file
    else { throw invalidRecoveryMetadata() }
    guard ContinuousClock.now < deadline else {
      throw WorktreeError.busy("Recovery pack transition exceeded its deadline.")
    }
  }

  private func sync() throws {
    try io.beforeDirectorySync()
    try parent.synchronize()
  }
}

extension RecoveryOperationStatus.Outcome {
  fileprivate var isMeasured: Bool {
    if case .measured = self { return true }
    return false
  }
}

private func isMaintenanceIntegrityFailure(_ error: any Error) -> Bool {
  if isEvidenceFailure(error) { return true }
  guard let error = error as? POSIXError else { return false }
  return [.ENOENT, .ENOTDIR, .ELOOP, .EEXIST].contains(error.code)
}
