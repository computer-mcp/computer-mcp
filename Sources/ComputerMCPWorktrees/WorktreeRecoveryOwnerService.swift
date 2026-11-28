import ComputerMCPPlatformPOSIX
import Foundation

package struct WorktreeRecoveryOwnerService: Sendable {
  let storage: WorktreeStorage
  let derived: any DerivedProjectStore
  let dependencies: any WorktreeRecoveryDependencyReading
  let git: WorktreeGit
  let io: WorktreeJournalIO
  let limits: WorktreePromotionLimits

  var stores: WorktreeRecoveryStore { .init(storage: storage, io: io) }

  package init(
    storage: WorktreeStorage, derived: any DerivedProjectStore,
    dependencies: any WorktreeRecoveryDependencyReading, executor: any WorktreeGitExecuting,
    journalIO: WorktreeJournalIO = .init(),
    maintenanceLimits: WorktreePromotionLimits = .init()
  ) throws {
    try maintenanceLimits.validateRecoveryCapture()
    self.storage = storage
    self.derived = derived
    self.dependencies = dependencies
    io = journalIO
    limits = maintenanceLimits
    git = .init(
      executor: executor, home: storage.journals,
      timeoutMilliseconds: 30_000, maxOutputBytes: 1_048_576)
  }

  package func list(principal: String? = nil) throws -> [RecoveryStoreView] {
    if let principal { try requirePrincipal(principal) }
    return try stores.list().map { snapshot in
      let records = snapshot.catalog.records
      let (known, removedWorktreeIDs) = try evidenceForListing(
        records: records, repository: snapshot.repository, generation: snapshot.catalog.generation)
      var operation: RecoveryOperationStatus?
      if let principal {
        operation = try stores.withExisting(
          key: snapshot.key, generation: snapshot.catalog.generation, exclusive: false
        ) { store in
          guard let entry = try store.ownerEntry(RecoveryOwnerJournal.activeName),
            entry.record.principal == principal
          else { return nil }
          return entry.record.status
        }
      }
      return .init(
        key: snapshot.key, generation: snapshot.catalog.generation,
        repository: snapshot.repository, format: snapshot.repository.format, records: records,
        dependencies: known, removedWorktreeIDs: removedWorktreeIDs, activeOperation: operation)
    }
  }

  private func evidenceForListing(
    records: [WorktreeRecoveryRecord], repository: WorktreeRepositoryIdentity, generation: UUID
  ) throws -> ([UUID: [RecoveryStoreView.Dependency]], Set<UUID>) {
    let owners = Dictionary(grouping: records, by: \.owner)
    guard let first = owners.keys.first else { return ([:], []) }
    let evidence = try dependencies.recoveryEvidence(
      for: repository, sources: Set(owners.keys.map(\.source)))
    let derived = Dictionary(uniqueKeysWithValues: evidence.derived.map { ($0.projectID, $0) })
    let deletions = try reader(repository, first.source).pendingRecoveryDeletions()
    let protectedIDs = Set(evidence.protections.map(\.branchID))
    var known: [UUID: [RecoveryStoreView.Dependency]] = [:]
    var removed: Set<UUID> = []
    for (owner, rows) in owners {
      let reader = reader(repository, owner.source)
      var common: [RecoveryStoreView.Dependency] = []
      let active = derived[owner.projectID]
      if deletions.contains(where: owner.matches)
        || !evidence.unfinishedOperations.isEmpty || !evidence.executions.isEmpty
        || (try? reader.hasPendingRecoveryLifecycle(owner, generation: generation)) != false
      {
        common.append(.lifecycle)
      }
      let final =
        active == nil ? try? reader.recoveryFinalCapture(owner, generation: generation) : nil
      if final != nil { removed.insert(owner.worktreeID) }
      if active == nil && final == nil { common.append(.unresolvedOwner) }
      for record in rows {
        var dependencies = record.dependencies.map(RecoveryStoreView.Dependency.catalog) + common
        if active?.worktree?.lastPublishedOID == record.oid, record.objectType == .commit {
          dependencies.append(.expectedPublishedCommit)
        }
        if let final, protectedIDs.contains(owner.branchID), record.oid == final.oid,
          record.claims.contains(where: { $0.reason == .privateHead && $0.capture == final.capture }
          )
        {
          dependencies.append(.protectedFinalCapture)
        }
        if !dependencies.isEmpty { known[record.id] = dependencies }
      }
    }
    return (known, removed)
  }

  package func reviewRelease(
    key: String, generation: UUID, selections: [WorktreeRecoveryRecord.Selection], principal: String
  ) throws -> RecoveryReleaseReview {
    try requirePrincipal(principal)
    guard !selections.isEmpty, selections.count <= WorktreeRecoveryCatalog.referenceLimit,
      Set(selections.map(\.recordID)).count == selections.count
    else {
      throw WorktreeError.invalidRequest("Select a bounded batch of distinct recovery records.")
    }
    let (repository, records) = try stores.withExisting(
      key: key, generation: generation, exclusive: false
    ) { store in
      let catalog = try store.observedCatalog().catalog
      try store.validateAnchorContents(for: catalog)
      let byID = Dictionary(uniqueKeysWithValues: catalog.records.map { ($0.id, $0) })
      let records = try selections.sorted { $0.recordID.uuidString < $1.recordID.uuidString }.map {
        guard let record = byID[$0.recordID], record.selection == $0, record.state == .retained
        else { throw WorktreeError.busy("Recovery selection changed. Refresh before reviewing.") }
        return record
      }
      return (store.repository, records)
    }
    let owners = Set(records.map(\.owner))
    let evidence = try dependencies.recoveryEvidence(
      for: repository, sources: Set(owners.map(\.source)))
    let active = Dictionary(uniqueKeysWithValues: evidence.derived.map { ($0.projectID, $0) })
    let gates: [RecoveryReleaseRequest.Gate] = try owners.sorted { $0.projectID < $1.projectID }
      .compactMap { owner in
        guard let record = active[owner.projectID], record.state == .active,
          evidence.registrations.contains(owner.source),
          try liveSource(repository)
        else { return nil }
        let topology = try reader(repository, owner.source).recoveryTopology(record, owner: owner)
        return .init(record: record, existing: try WorktreeAdmission.existing(for: topology))
      }
    let request = RecoveryReleaseRequest(records: records, gates: gates)
    let handle = try RecoveryReviewedRequest.issue(
      request, key: key, generation: generation, action: .release, principal: principal)
    let review = RecoveryReleaseReview(handle: handle, release: request)
    try checkSubmission(.release(review), principal: principal, repository: repository)
    return review
  }

  package func operation(_ handle: RecoveryOperationHandle, principal: String) throws
    -> RecoveryOperationLookup
  {
    try requirePrincipal(principal)
    try validateHandle(handle)
    return try withStore(handle, exclusive: false) { store in
      let current = try store.observeOwnerOperation(
        handle, principal: principal, synchronizing: false)
      if let entry = current.result
        ?? current.active.flatMap({ $0.record.handle == handle ? $0 : nil })
      {
        return .submitted(entry.record.status)
      }
      return .unsubmitted
    }
  }

  package func confirm(_ review: RecoveryReleaseReview, principal: String) throws
    -> RecoveryOperationStatus
  {
    try submitRelease(review.handle, request: .release(review), principal: principal)
  }

  package func resume(_ handle: RecoveryOperationHandle, principal: String) throws
    -> RecoveryOperationStatus
  {
    switch handle.action {
    case .release: try submitRelease(handle, request: nil, principal: principal)
    case .maintenance: try submitMaintenance(handle, review: nil, principal: principal)
    }
  }

  private enum ReleaseProgress {
    case cleanup
    case pending(WorktreeRepositoryIdentity, WorktreeRecoveryStore.Locked.OwnerEntry)
    case recovery(RecoveryOperationStatus)
  }

  private func submitRelease(
    _ handle: RecoveryOperationHandle, request: RecoveryReviewedRequest?, principal: String
  ) throws -> RecoveryOperationStatus {
    try requirePrincipal(principal)
    try validateHandle(handle)
    let progress = try withStore(handle) { store in
      let current = try store.observeOwnerOperation(
        handle, principal: principal, request: request, synchronizing: true)
      if current.result != nil { return ReleaseProgress.cleanup }
      let entry: WorktreeRecoveryStore.Locked.OwnerEntry
      if let active = current.active, active.record.handle == handle {
        entry = active
      } else {
        guard let request else { throw WorktreeRecoveryOwnerError.unsubmitted }
        guard current.active == nil else {
          throw WorktreeError.busy("Another owner operation has the active recovery journal.")
        }
        try checkSubmission(request, principal: principal, repository: store.repository)
        entry = try store.saveOwnerOperation(
          .init(request: request, principal: principal), replacing: nil)
      }
      return try classifyAndReplay(entry, in: store, coordinated: false)
    }
    switch progress {
    case .cleanup:
      return try cleanGates(handle, principal: principal)
    case .recovery(let status):
      return status
    case .pending(let repository, let entry):
      guard case .release(let review) = entry.record.request else {
        throw invalidRecoveryMetadata()
      }
      var entry = entry
      if let scratch = entry.record.fallbackScratch {
        do {
          entry = try recoverFallbackScratch(scratch, entry: entry)
        } catch {
          guard isEvidenceFailure(error) else { throw error }
          try markReleaseRecovery(entry, reason: error.localizedDescription)
          return try releaseStatus(handle, principal: principal)
        }
      }
      do {
        return try coordinate(repository) { live in
          try admitRelease(
            review, entry: entry, repository: repository, live: live, principal: principal)
          return try releaseStatus(handle, principal: principal)
        }
      } catch WorktreeError.identityChanged(let reason) {
        try markReleaseRecovery(entry, reason: reason)
        return try releaseStatus(handle, principal: principal)
      }
    }
  }

  private func releaseStatus(_ handle: RecoveryOperationHandle, principal: String) throws
    -> RecoveryOperationStatus
  {
    let observed = try operation(handle, principal: principal)
    guard case .submitted(let status) = observed else { throw invalidRecoveryMetadata() }
    switch status.outcome {
    case .pending, .recoveryRequired: return status
    default: return try cleanGates(handle, principal: principal)
    }
  }

  /// Classification is store-only. Admitted batches and archives can always
  /// finish here, including after the source and admission gates disappear.
  private func classifyAndReplay(
    _ entry: WorktreeRecoveryStore.Locked.OwnerEntry, in store: WorktreeRecoveryStore.Locked,
    coordinated: Bool = true
  ) throws -> ReleaseProgress {
    if entry.record.isResult {
      try store.publishOwnerResult(entry)
      return .cleanup
    }
    if case .recoveryRequired = entry.record.outcome { return .recovery(entry.record.status) }
    guard case .release(let review) = entry.record.request else { throw invalidRecoveryMetadata() }
    if entry.record.fallbackScratch != nil { return .pending(store.repository, entry) }
    let receipts = try review.release.receipts(for: review.handle)
    let decision: ReleaseDecision
    do {
      decision = try store.releaseDecision(records: review.release.records, receipts: receipts) {
        retired, activeRecords in
        try requireRetiredReleaseEvidence(retired, activeRecords: activeRecords, in: store)
      }
    } catch {
      guard isEvidenceFailure(error) else { throw error }
      let next = try store.saveOwnerOperation(
        entry.record.advanced { $0.outcome = .recoveryRequired(error.localizedDescription) },
        replacing: entry)
      return .recovery(next.record.status)
    }
    if !coordinated, !entry.record.gates.isEmpty {
      switch decision {
      case .admit, .busy, .stale: return .pending(store.repository, entry)
      case .admitted, .archived: break
      }
    }
    switch decision {
    case .admit: return .pending(store.repository, entry)
    case .stale: return try recordOutcome(.stale, entry: entry, in: store)
    case .busy:
      return try recordOutcome(
        .busy("A lifecycle operation protects this selection."), entry: entry, in: store)
    case .admitted, .archived:
      try store.releaseAnchors(receipts) {
        try store.checkIdentity()
        // The exclusive store lock keeps this synchronized confirmation fixed
        // throughout H10's receipt transaction.
      }
      return try recordOutcome(.released, entry: entry, in: store)
    }
  }

  @discardableResult
  private func recordOutcome(
    _ outcome: RecoveryOperationStatus.Outcome,
    entry: WorktreeRecoveryStore.Locked.OwnerEntry, in store: WorktreeRecoveryStore.Locked
  ) throws -> ReleaseProgress {
    guard entry.record.fallbackScratch == nil else { throw invalidRecoveryMetadata() }
    let next = try store.saveOwnerOperation(
      entry.record.advanced { $0.outcome = outcome }, replacing: entry)
    try store.publishOwnerResult(next)
    return .cleanup
  }

  private func finishPendingRelease(
    _ entry: WorktreeRecoveryStore.Locked.OwnerEntry, outcome: RecoveryOperationStatus.Outcome
  ) throws {
    try withStore(entry.record.handle) { store in
      let observed = try store.observeOwnerOperation(
        entry.record.handle, principal: entry.record.principal, synchronizing: true)
      guard observed.result == nil, let active = observed.active, active.bytes == entry.bytes
      else { return }
      if case .pending = try classifyAndReplay(active, in: store) {
        try recordOutcome(outcome, entry: active, in: store)
      }
    }
  }

  private func markReleaseRecovery(
    _ entry: WorktreeRecoveryStore.Locked.OwnerEntry, reason: String
  ) throws {
    try withStore(entry.record.handle) { store in
      let observed = try store.observeOwnerOperation(
        entry.record.handle, principal: entry.record.principal, synchronizing: true)
      guard observed.result == nil, let active = observed.active, active.bytes == entry.bytes
      else { return }
      try store.saveOwnerOperation(
        active.record.advanced { $0.outcome = .recoveryRequired(reason) }, replacing: active)
    }
  }

  private func admitRelease(
    _ review: RecoveryReleaseReview, entry: WorktreeRecoveryStore.Locked.OwnerEntry,
    repository: WorktreeRepositoryIdentity, live: Bool, principal: String
  ) throws {
    var entry = entry
    let handle = review.handle
    let eligible = try withStore(handle) { store in
      let observed = try store.observeOwnerOperation(
        handle, principal: principal, synchronizing: true)
      guard observed.result == nil, let active = observed.active, active.record.handle == handle
      else { return false }
      guard active.record.fallbackScratch == nil else {
        throw WorktreeError.busy("The expected-commit proof is still active.")
      }
      if case .pending = try classifyAndReplay(active, in: store) {
        entry = active
        return true
      }
      return false
    }
    guard eligible else { return }
    let owners = Dictionary(grouping: review.records, by: \.owner)
    let sources = Set(owners.keys.map(\.source))
    let evidence = try dependencies.recoveryEvidence(for: repository, sources: sources)
    let admissions: [(WorktreeRecoveryRecord.Owner, VerifiedWorktreeTopology)]
    do {
      admissions = try releaseTopologies(
        review: review, owners: owners, evidence: evidence, repository: repository, live: live)
    } catch let error as WorktreeError {
      switch error {
      case .busy(let reason): try finishPendingRelease(entry, outcome: .busy(reason))
      case .identityChanged: try finishPendingRelease(entry, outcome: .stale)
      default: throw error
      }
      return
    }
    do {
      if entry.record.gates.isEmpty, !admissions.isEmpty {
        let gates = try zip(review.release.gates, admissions).map { intended, pair in
          let gate = try WorktreeAdmission.prepareRecoveryGate(
            for: pair.1, reviewed: intended.existing, operationID: handle.id, io: io)
          return RecoveryOwnerJournal.Gate(admission: gate)
        }
        let frozen = entry
        let updated = try withStore(handle) { store -> WorktreeRecoveryStore.Locked.OwnerEntry? in
          let observed = try store.observeOwnerOperation(
            handle, principal: principal, synchronizing: true)
          guard observed.result == nil, let active = observed.active, active.bytes == frozen.bytes
          else { return nil }
          return try store.saveOwnerOperation(
            active.record.advanced { $0.gates = gates }, replacing: active)
        }
        guard let updated else { return }
        entry = updated
      }
      for (gate, pair) in zip(entry.record.gates, admissions) {
        guard try WorktreeAdmission.existing(for: pair.1) == gate.admission else {
          throw WorktreeError.identityChanged("Recorded gate was substituted.")
        }
        try gate.admission.holdRecovery(entry.record.hold, io: io)
      }
      try requireReleaseDependencies(
        owners, admissions: admissions, evidence: evidence, repository: repository,
        entry: &entry)
    } catch let error as WorktreeError {
      guard entry.record.fallbackScratch == nil else { throw error }
      switch error {
      case .busy(let reason): try finishPendingRelease(entry, outcome: .busy(reason))
      case .identityChanged: try finishPendingRelease(entry, outcome: .stale)
      default:
        guard isEvidenceFailure(error) else { throw error }
        try markReleaseRecovery(entry, reason: error.localizedDescription)
      }
      return
    } catch let error as DecodingError {
      guard entry.record.fallbackScratch == nil else { throw error }
      try markReleaseRecovery(entry, reason: "Lifecycle evidence cannot be decoded.")
      return
    }
    try withStore(handle) { store in
      let observed = try store.observeOwnerOperation(
        handle, principal: principal, synchronizing: true)
      guard observed.result == nil, let active = observed.active, active.bytes == entry.bytes,
        case .pending = try classifyAndReplay(active, in: store)
      else { return }
      guard try liveSource(repository) == live else {
        try recordOutcome(
          .busy("Source availability changed during admission."), entry: active, in: store)
        return
      }
      let receipts = try review.release.receipts(for: handle)
      var admission: WorktreeRecoveryStore.Locked.ReleaseAdmission?
      let matched: Bool
      do {
        matched = try dependencies.validateRecoveryEvidence(
          evidence, for: repository, sources: sources
        ) {
          admission = try store.admitRelease(receipts)
        }
      } catch {
        // The catalog rename can be visible even when synchronization or the
        // enclosing SQL validation throws. Only the durable intent authorizes replay.
        if case .pending = try classifyAndReplay(active, in: store) { throw error }
        return
      }
      guard case .pending = try classifyAndReplay(active, in: store) else { return }
      switch admission {
      case .capacityRefused(let reason):
        try recordOutcome(.busy(reason), entry: active, in: store)
      case nil where !matched:
        try recordOutcome(
          .busy("Recovery dependency evidence changed during admission."), entry: active, in: store)
      default:
        throw invalidRecoveryMetadata()
      }
    }
  }

  private func releaseTopologies(
    review: RecoveryReleaseReview, owners: [WorktreeRecoveryRecord.Owner: [WorktreeRecoveryRecord]],
    evidence: WorktreeRecoveryDependencyEvidence, repository: WorktreeRepositoryIdentity, live: Bool
  ) throws -> [(WorktreeRecoveryRecord.Owner, VerifiedWorktreeTopology)] {
    let derived = Dictionary(uniqueKeysWithValues: evidence.derived.map { ($0.projectID, $0) })
    let registrations = Set(evidence.registrations)
    var admissions: [(WorktreeRecoveryRecord.Owner, VerifiedWorktreeTopology)] = []
    var current: [DerivedProjectRecord] = []
    for owner in owners.keys.sorted(by: { $0.projectID < $1.projectID }) {
      if let record = derived[owner.projectID] {
        guard live, record.state == .active, registrations.contains(owner.source) else {
          throw WorktreeError.busy("A required live source or active worktree is unavailable.")
        }
        let topology = try reader(repository, owner.source).recoveryTopology(record, owner: owner)
        admissions.append((owner, topology))
        current.append(record)
      }
    }
    guard current == review.release.gates.map(\.record) else {
      throw WorktreeError.identityChanged("The reviewed live worktree set changed.")
    }
    return admissions
  }

  private func requireReleaseDependencies(
    _ owners: [WorktreeRecoveryRecord.Owner: [WorktreeRecoveryRecord]],
    admissions: [(WorktreeRecoveryRecord.Owner, VerifiedWorktreeTopology)],
    evidence: WorktreeRecoveryDependencyEvidence, repository: WorktreeRepositoryIdentity,
    entry: inout WorktreeRecoveryStore.Locked.OwnerEntry
  ) throws {
    guard evidence.unfinishedOperations.isEmpty, evidence.executions.isEmpty else {
      throw WorktreeError.busy("An unfinished host operation or execution protects recovery data.")
    }
    let firstOwner = owners.keys.first!
    let deletions = try reader(repository, firstOwner.source).pendingRecoveryDeletions()
    let live = Dictionary(uniqueKeysWithValues: admissions)
    let records = Dictionary(uniqueKeysWithValues: evidence.derived.map { ($0.projectID, $0) })
    let generation = entry.record.handle.generation
    var fallbackBudget = try WorktreeObjectBudget(limits)
    for (owner, selected) in owners {
      let reader = reader(repository, owner.source)
      guard !deletions.contains(where: owner.matches),
        try !reader.hasPendingRecoveryLifecycle(owner, generation: generation)
      else { throw WorktreeError.busy("An unfinished lifecycle operation protects recovery data.") }
      if let topology = live[owner],
        let expected = records[owner.projectID]?.worktree?.lastPublishedOID
      {
        if selected.contains(where: { $0.oid == expected && $0.objectType == .commit }),
          try !verifyExpectedCommit(
            expected, reader: reader, topology: topology, budget: &fallbackBudget, entry: &entry)
        {
          throw WorktreeError.busy("The worktree needs its retained expected commit.")
        }
      } else {
        let final = try reader.recoveryFinalCapture(owner, generation: generation)
        if let protection = evidence.protections.first(where: owner.matches) {
          guard protection.publishedOID == final.oid else { throw invalidRecoveryMetadata() }
          guard
            !selected.contains(where: { record in
              record.oid == final.oid
                && record.claims.contains {
                  $0.reason == .privateHead && $0.capture == final.capture
                }
            })
          else {
            throw WorktreeError.busy("The protected branch needs its final private HEAD witness.")
          }
        }
      }
    }
  }

  private typealias FallbackScratch = RecoveryOwnerJournal.FallbackScratch
  private typealias OwnerEntry = WorktreeRecoveryStore.Locked.OwnerEntry

  private func verifyExpectedCommit(
    _ oid: String, reader: WorktreeRepository, topology: VerifiedWorktreeTopology,
    budget: inout WorktreeObjectBudget, entry: inout OwnerEntry
  ) throws -> Bool {
    let runtime = topology.runtime
    try budget.check()
    try runtime.verify()
    let lock = try lockFallbackScratch(in: runtime)
    defer { lock.release() }
    let token = UUID()
    let name = FallbackScratch.name(operation: entry.record.handle.id, token: token)
    let lockIdentity = try lock.identity()
    let directory = try runtime.child(name, create: true, exclusive: true)
    let scratch = FallbackScratch(
      token: token, runtime: runtime.identity, directory: directory.identity, lock: lockIdentity)
    do {
      // Ownership is durable before the first copy. A failed reservation can only leave an empty root.
      entry = try replaceFallbackScratch(scratch, entry: entry)
    } catch {
      try? removeFallbackScratch(scratch, in: runtime, holding: lock)
      throw error
    }
    let verified: Bool
    do {
      verified = try reader.hasVerifiedPrivateExpectedCommit(
        oid, topology: topology, scratch: directory, budget: &budget)
    } catch {
      if let cleared = try? retireFallbackScratch(scratch, in: runtime, holding: lock, entry: entry)
      {
        entry = cleared
      }
      throw error
    }
    entry = try retireFallbackScratch(scratch, in: runtime, holding: lock, entry: entry)
    return verified
  }

  private func recoverFallbackScratch(_ scratch: FallbackScratch, entry: OwnerEntry) throws
    -> OwnerEntry
  {
    let runtime: WorktreeDirectory?
    do {
      runtime = try WorktreeDirectory.openIfPresent(URL(fileURLWithPath: scratch.runtime.path))
    } catch let error as POSIXError where [.ENOTDIR, .ELOOP].contains(error.code) {
      throw WorktreeError.recoveryRequired("Expected-commit proof runtime changed.")
    }
    guard let runtime, runtime.identity == scratch.runtime else {
      throw WorktreeError.recoveryRequired("Expected-commit proof runtime changed.")
    }
    let lock = try lockFallbackScratch(in: runtime, expecting: scratch.lock)
    defer { lock.release() }
    return try retireFallbackScratch(scratch, in: runtime, holding: lock, entry: entry)
  }

  private func lockFallbackScratch(
    in runtime: WorktreeDirectory, expecting expected: FileLock.Identity? = nil
  ) throws -> FileLock {
    let path = runtime.url.appendingPathComponent(FallbackScratch.lockName).path
    do {
      if let expected {
        let lock = try FileLock(lockingExisting: path)
        guard try lock.identity() == expected else {
          throw FileLockError.identityChanged(path: path)
        }
        return lock
      }
      return try FileLock(path: path, mode: .exclusive)
    } catch FileLockError.held {
      throw WorktreeError.busy("The expected-commit proof is still active.")
    } catch FileLockError.identityChanged {
      throw WorktreeError.recoveryRequired("Expected-commit proof lock changed.")
    } catch let error as POSIXError where expected != nil && [.ENOENT, .ELOOP].contains(error.code)
    {
      throw WorktreeError.recoveryRequired("Expected-commit proof lock changed.")
    }
  }

  private func retireFallbackScratch(
    _ scratch: FallbackScratch, in runtime: WorktreeDirectory, holding lock: FileLock,
    entry: OwnerEntry
  ) throws -> OwnerEntry {
    try removeFallbackScratch(scratch, in: runtime, holding: lock)
    return try replaceFallbackScratch(nil, entry: entry)
  }

  private func removeFallbackScratch(
    _ scratch: FallbackScratch, in runtime: WorktreeDirectory, holding lock: FileLock
  ) throws {
    try runtime.verify()
    guard (try? lock.identity()) == scratch.lock else {
      throw WorktreeError.recoveryRequired("Expected-commit proof lock changed.")
    }
    do {
      try runtime.removeOwnedTree(scratch.directory, io: WorktreeJournalIO())
    } catch let error as POSIXError where [.ENOTDIR, .ELOOP].contains(error.code) {
      throw WorktreeError.recoveryRequired("Expected-commit proof scratch topology changed.")
    }
    // Also synchronize a previously completed unlink before retiring its ownership record.
    try runtime.synchronize()
  }

  private func replaceFallbackScratch(_ scratch: FallbackScratch?, entry: OwnerEntry) throws
    -> OwnerEntry
  {
    try withStore(entry.record.handle) { store in
      let observed = try store.observeOwnerOperation(
        entry.record.handle, principal: entry.record.principal, synchronizing: true)
      guard observed.result == nil, let active = observed.active, active.bytes == entry.bytes else {
        throw WorktreeError.busy("The release operation changed during the expected-commit proof.")
      }
      return try store.saveOwnerOperation(
        active.record.advanced { $0.fallbackScratch = scratch }, replacing: active)
    }
  }

  private func cleanGates(_ handle: RecoveryOperationHandle, principal: String) throws
    -> RecoveryOperationStatus
  {
    let snapshot = try withStore(handle) { store in
      try store.observeOwnerOperation(handle, principal: principal, synchronizing: true).result
    }
    guard let snapshot else { throw invalidRecoveryMetadata() }
    let progress: [RecoveryOperationStatus.GateCleanup] = snapshot.record.gates.map { gate in
      guard gate.cleanup == .pending else { return gate.cleanup }
      do {
        try gate.admission.clearRecovery(snapshot.record.hold, io: io)
        return .cleared
      } catch WorktreeError.identityChanged {
        return .identityChanged
      } catch {
        return .pending
      }
    }
    guard progress != snapshot.record.gates.map(\.cleanup) else { return snapshot.record.status }
    return try withStore(handle) { store in
      let current = try store.observeOwnerOperation(
        handle, principal: principal, synchronizing: true)
      guard let result = current.result else { throw invalidRecoveryMetadata() }
      guard result.record.gates.map(\.admission) == snapshot.record.gates.map(\.admission)
      else { throw invalidRecoveryMetadata() }
      let next = try result.record.advanced { record in
        for (index, cleanup) in progress.enumerated() where record.gates[index].cleanup == .pending
        {
          record.gates[index].cleanup = cleanup
        }
      }
      guard next.gates != result.record.gates else { return result.record.status }
      try store.updateOwnerCleanup(next, replacing: result)
      return next.status
    }
  }

  func checkSubmission(
    _ request: RecoveryReviewedRequest, principal: String, repository: WorktreeRepositoryIdentity
  ) throws {
    try request.validate(principal: principal, repository: repository)
    // Account for bound gate identities, cleanup states and the longest
    // terminal metadata before allowing a confirmation to own durable holds.
    let bytes = try recoveryJSON(RecoveryOwnerJournal(request: request, principal: principal))
    guard bytes.count <= RecoveryOwnerJournal.byteLimit / 2 else {
      throw WorktreeError.busy("Recovery confirmation exceeds its journal bound.")
    }
  }

  func requirePrincipal(_ principal: String) throws {
    guard !principal.isEmpty, principal.utf8.count <= 1024 else {
      throw WorktreeRecoveryOwnerError.unauthorized
    }
  }

  func validateHandle(_ handle: RecoveryOperationHandle) throws {
    guard handle.storeKey.isRecoveryDigest, handle.requestDigest.isRecoveryDigest else {
      throw WorktreeRecoveryOwnerError.identityConflict
    }
  }

  func withStore<T>(
    _ handle: RecoveryOperationHandle, exclusive: Bool = true,
    _ body: (WorktreeRecoveryStore.Locked) throws -> T
  ) throws -> T {
    try stores.withExisting(
      key: handle.storeKey, generation: handle.generation, exclusive: exclusive, body)
  }

  func reader(_ repository: WorktreeRepositoryIdentity, _ source: DerivedProjectSource)
    -> WorktreeRepository
  {
    .init(
      recoveryRepository: repository, source: source, store: derived, storage: storage,
      git: git, io: io, limits: limits)
  }

  func liveSource(_ repository: WorktreeRepositoryIdentity) throws -> Bool {
    for expected in [repository.source, repository.main, repository.common, repository.objects] {
      guard let directory = try WorktreeDirectory.openIfPresent(URL(fileURLWithPath: expected.path))
      else { return false }
      guard directory.identity == expected else {
        throw WorktreeError.identityChanged("Source repository directory changed.")
      }
    }
    return true
  }

  func coordinate<T>(
    _ repository: WorktreeRepositoryIdentity, deadline: ContinuousClock.Instant? = nil,
    _ body: (Bool) throws -> T
  ) throws -> T {
    let commonURL = URL(fileURLWithPath: repository.common.path)
    guard let common = try WorktreeDirectory.openIfPresent(commonURL) else {
      guard try !liveSource(repository) else { throw invalidRecoveryMetadata() }
      return try body(false)
    }
    guard common.identity == repository.common else {
      throw WorktreeError.identityChanged("Source coordination directory changed.")
    }
    let remaining = deadline.map { ContinuousClock.now.duration(to: $0) } ?? .seconds(30)
    guard remaining > .zero else {
      throw WorktreeError.busy("Recovery coordination deadline exceeded.")
    }
    let lock = try RepositoryLock(
      existingCommonDirectory: commonURL, timeout: min(remaining, .seconds(30)))
    defer { lock.release() }
    try lock.verify()
    try common.verify()
    return try body(liveSource(repository))
  }
}

private enum ReleaseDecision { case admit, stale, busy, admitted, archived }

extension WorktreeRecoveryStore.Locked {
  fileprivate func releaseDecision(
    records: [WorktreeRecoveryRecord], receipts: [WorktreeRecoveryReleaseReceipt],
    verifyRetired: ([WorktreeRecoveryReleaseReceipt], Set<UUID>) throws -> Void
  ) throws -> ReleaseDecision {
    guard let first = receipts.first else { throw invalidRecoveryMetadata() }
    let catalog = try catalog()
    try validateAnchorContents(for: catalog)
    let byID = Dictionary(uniqueKeysWithValues: catalog.records.map { ($0.id, $0) })
    let intents = Dictionary(uniqueKeysWithValues: catalog.intents.map { ($0.id, $0) })
    let admission = intents[first.operationID]
    if let admission {
      guard admission.kind == .release, admission.requestDigest == first.requestDigest,
        admission.selections == receipts.map(\.selection)
      else { throw invalidRecoveryMetadata() }
    }
    var retired: [WorktreeRecoveryReleaseReceipt] = []
    var foreignDigests: [UUID: String] = [:]
    var foreignSelections: [UUID: [UUID: WorktreeRecoveryRecord.Selection]] = [:]
    var exact = 0
    var stale = false
    var busy = false
    for (before, expected) in zip(records, receipts) {
      let receipt = try releaseReceipt(recordID: before.id)
      guard let current = byID[before.id] else {
        guard admission == nil, let receipt else { throw invalidRecoveryMetadata() }
        if receipt.operationID == first.operationID {
          guard receipt == expected else { throw invalidRecoveryMetadata() }
          exact += 1
        } else {
          guard receipt.owner == before.owner, receipt.selection.oid == before.oid,
            receipt.selection.revision >= before.revision,
            intents[receipt.operationID] == nil
          else { throw invalidRecoveryMetadata() }
          retired.append(receipt)
          stale = true
        }
        continue
      }
      if admission != nil {
        guard current == before.admittingRelease(first.operationID),
          receipt.map({ $0 == expected }) ?? true
        else { throw invalidRecoveryMetadata() }
        continue
      }
      var identity = current
      identity.revision = before.revision
      identity.state = before.state
      identity.dependencies = before.dependencies
      identity.claims = before.claims
      identity.acknowledgements = before.acknowledgements
      guard identity == before, current.revision >= before.revision else {
        throw invalidRecoveryMetadata()
      }
      if current.state == .releasing, let foreign = current.dependencies.first {
        guard foreign != first.operationID, let intent = intents[foreign], intent.kind == .release
        else { throw invalidRecoveryMetadata() }
        if let receipt {
          if foreignDigests[foreign] == nil {
            foreignDigests[foreign] = try WorktreeRecoveryReleaseReceipt.digest(
              of: intent.selections)
            foreignSelections[foreign] = Dictionary(
              uniqueKeysWithValues: intent.selections.map { ($0.recordID, $0) })
          }
          guard receipt.owner == before.owner, receipt.operationID == foreign,
            receipt.requestDigest == intent.requestDigest,
            receipt.selection == foreignSelections[foreign]?[before.id],
            receipt.selectionDigest == foreignDigests[foreign]
          else { throw invalidRecoveryMetadata() }
        }
        busy = true
      } else {
        guard current.state == .retained, receipt == nil,
          current.revision > before.revision || current == before
        else { throw invalidRecoveryMetadata() }
        busy = busy || !current.dependencies.isEmpty
        stale = stale || current.revision > before.revision
      }
    }
    if admission != nil { return .admitted }
    if exact > 0 {
      guard exact == receipts.count else { throw invalidRecoveryMetadata() }
      return .archived
    }
    if !retired.isEmpty { try verifyRetired(retired, Set(byID.keys)) }
    if busy { return .busy }
    return stale ? .stale : .admit
  }
}

func isEvidenceFailure(_ error: any Error) -> Bool {
  switch error {
  case WorktreeError.recoveryRequired, WorktreeError.identityChanged, WorktreeError.invalidRequest,
    is DecodingError:
    true
  default: false
  }
}
