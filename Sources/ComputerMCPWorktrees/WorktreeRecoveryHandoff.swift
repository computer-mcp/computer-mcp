import Foundation

/// Shared pack handoff stored in the owning publication or removal journal.
/// Source publication is a later boundary than durable store retention.
struct WorktreeRecoveryHandoff: Codable, Equatable {
  enum Phase: String, Codable {
    case verified, retaining, retained, sourceInstalling, sourceInstalled
  }

  let retention: WorktreeRecoveryRetention
  let recoveryArtifact: WorktreeRecoveryPackReceipt
  let sourceArtifact: WorktreeRecoveryPackReceipt?
  private(set) var phase: Phase = .verified
  private(set) var recoveryInstallation: WorktreeRecoveryPackInstall?
  private(set) var sourceInstallation: WorktreeRecoveryPackInstall?

  init(
    retention: WorktreeRecoveryRetention, capture: WorktreeRecoveryCapture,
    recovery: WorktreeRecoveryPack, source: WorktreeRecoveryPack
  ) {
    self.retention = retention
    recoveryArtifact = .init(recovery)
    if retention.kind == .publication, !capture.sourceManifest.entries.isEmpty {
      sourceArtifact = .init(source)
    } else {
      sourceArtifact = nil
    }
  }

  /// The publication caller holds R/S and supplies its exact expected-source
  /// guard for every source write. Removal completes at the retained boundary.
  mutating func complete(
    repository: WorktreeRepository, store: WorktreeRecoveryStore.Locked,
    staging: WorktreeRecoveryStaging, budget: WorktreeObjectBudget,
    revalidate: () throws -> Void, sourceGuards: () throws -> WorktreeSourceGuards,
    persist: (Self) throws -> Void
  ) throws {
    let format = repository.identity.format
    let io = repository.io
    guard retention.generation == store.generation,
      retention.owner.source == repository.source,
      retention.kind == .publication || sourceArtifact == nil
    else { throw invalidRecoveryMetadata() }
    try revalidate()
    try persist(self)
    if phase == .verified {
      try store.admitRetention(retention)
      try save(persist) { $0.phase = .retaining }
    }
    if phase == .retaining {
      try store.admitRetention(retention)
      let pack = try staging.reopenPack(recoveryArtifact, slot: .recovery)
      let directory = try store.packDirectory()
      var install =
        recoveryInstallation
        ?? .init(
          operationID: retention.operationID, generation: retention.generation,
          destination: directory, pack: pack)
      guard install.artifact == recoveryArtifact, install.operationID == retention.operationID,
        install.generation == retention.generation
      else { throw invalidRecoveryMetadata() }
      try install.install(
        from: pack.directory, into: directory, format: format, io: io, deadline: budget.deadline,
        verify: {
          try staging.verify()
          try revalidate()
        },
        persist: { next in try save(persist) { $0.recoveryInstallation = next } })
      try store.retainInstalledPack(
        retention, installation: install, git: repository.git, budget: budget)
      try save(persist) { $0.phase = .retained }
    }
    try store.requireRetained(retention)
    if phase == .retained, let recoveryInstallation {
      try recoveryInstallation.releaseKeep(in: store.packDirectory(), io: io)
    }
    guard retention.kind == .publication else {
      guard phase == .retained else { throw invalidRecoveryMetadata() }
      return
    }
    let guards = try sourceGuards()
    let branch = retention.owner.branch
    let expected = retention.expectedOID
    guard guards.operationID == retention.operationID,
      guards.metadata.common.identity == repository.identity.common
    else { throw invalidRecoveryMetadata() }
    func verifySource() throws {
      try revalidate()
      try guards.verify(covering: [branch, "packed-refs"])
      guard try guards.metadata.direct(branch).oid == expected else {
        throw sourceMetadataChanged()
      }
    }
    if phase == .retained {
      try verifySource()
      try save(persist) { $0.phase = .sourceInstalling }
    }
    if phase == .sourceInstalling {
      try verifySource()
      if let sourceArtifact {
        let directory = try repository.sourcePackDirectory(create: true)
        let original = try staging.reopenPack(sourceArtifact, slot: .source)
        let placement = try staging.prepareSourceInstallation(
          original, beside: directory, permissions: guards.metadata.permissions,
          deadline: budget.deadline)
        var install =
          sourceInstallation
          ?? .init(
            operationID: retention.operationID, generation: retention.generation,
            destination: directory, pack: placement)
        guard install.artifact == WorktreeRecoveryPackReceipt(placement),
          install.operationID == retention.operationID, install.generation == retention.generation
        else { throw invalidRecoveryMetadata() }
        try install.install(
          from: placement.directory, into: directory, format: format, io: io,
          deadline: budget.deadline,
          verify: {
            try staging.verify()
            try verifySource()
          },
          persist: { next in try save(persist) { $0.sourceInstallation = next } })
      }
      try verifySource()
      try save(persist) { $0.phase = .sourceInstalled }
    }
    guard phase == .sourceInstalled else { throw invalidRecoveryMetadata() }
  }

  /// Keep ownership survives staging disposal and is retired only after the
  /// publication's guarded durable source outcome.
  func releaseSourceKeep(
    repository: WorktreeRepository, verifyTerminalOutcome: () throws -> Void
  ) throws {
    try verifyTerminalOutcome()
    guard phase == .sourceInstalled else { throw invalidRecoveryMetadata() }
    if let sourceInstallation {
      try sourceInstallation.releaseKeep(
        in: repository.sourcePackDirectory(create: false), io: repository.io)
    }
  }

  private mutating func save(_ persist: (Self) throws -> Void, change: (inout Self) -> Void) throws
  {
    var next = self
    change(&next)
    try persist(next)
    self = next
  }
}

extension WorktreeRepository {
  /// The present repository instance already holds R. Lifecycle callers
  /// persist their operation ID before capture, and the handoff before import.
  func beginRecoveryHandoff(
    operationID: UUID, kind: WorktreeRecoveryIntent.Kind, record: DerivedProjectRecord,
    topology: VerifiedWorktreeTopology, store: WorktreeRecoveryStore.Locked,
    budget: inout WorktreeObjectBudget, persist: (WorktreeRecoveryHandoff) throws -> Void,
    revalidate: () throws -> Void, sourceGuards: () throws -> WorktreeSourceGuards
  ) throws -> WorktreeRecoveryHandoff {
    guard let registration = record.worktree, record.source == source,
      case .host(let worktreeID, let storageGeneration) = record.provenance,
      topology.projectID == record.projectID, topology.generation == storageGeneration,
      topology.common.identity == identity.common,
      [.publication, .removal].contains(kind)
    else { throw invalidRecoveryMetadata() }
    try revalidate()
    let expected = registration.lastPublishedOID
    let catalog = try store.catalog()
    let owner = WorktreeRecoveryRecord.Owner(
      source: record.source, branchID: registration.branchID, branch: registration.branch,
      worktreeID: worktreeID, storageGeneration: storageGeneration)
    let expectedObjects = try store.objectsForExpected(oid: expected, owner: owner)
    let deadlineBudget = budget
    return try withRecoveryPacks(
      topology, expectedOID: expected, retainedExpectedObjects: expectedObjects,
      operationID: operationID, store: store,
      completionMetadataBytes: 2 * WorktreePackBounds.metadataLimit, budget: &budget
    ) { capture, recovery, source, staging in
      let retention = try WorktreeRecoveryRetention(
        operationID: operationID, kind: kind, record: record, objects: capture,
        expectedOID: expected, catalog: catalog)
      var handoff = WorktreeRecoveryHandoff(
        retention: retention, capture: capture, recovery: recovery, source: source)
      try handoff.complete(
        repository: self, store: store, staging: staging, budget: deadlineBudget,
        revalidate: revalidate, sourceGuards: sourceGuards, persist: persist)
      return handoff
    }
  }

  func resumeRecoveryHandoff(
    _ handoff: inout WorktreeRecoveryHandoff, store: WorktreeRecoveryStore.Locked,
    budget: WorktreeObjectBudget, persist: (WorktreeRecoveryHandoff) throws -> Void,
    revalidate: () throws -> Void, sourceGuards: () throws -> WorktreeSourceGuards
  ) throws {
    let id = handoff.retention.operationID
    if handoff.phase == .sourceInstalled
      || (handoff.retention.kind == .removal && handoff.phase == .retained)
    {
      try revalidate()
      try persist(handoff)
      try store.requireRetained(handoff.retention)
      if let install = handoff.recoveryInstallation {
        try install.releaseKeep(in: store.packDirectory(), io: io)
      }
      try store.finishStagingDisposal(operationID: id)
      return
    }
    try store.resumeStaging(operationID: id) { staging in
      try handoff.complete(
        repository: self, store: store, staging: staging, budget: budget,
        revalidate: revalidate, sourceGuards: sourceGuards, persist: persist)
    }
  }

  fileprivate func sourcePackDirectory(create: Bool) throws -> WorktreeDirectory {
    try identity.verify()
    let objects = try WorktreeDirectory(URL(fileURLWithPath: identity.objects.path))
    guard objects.identity == identity.objects else { throw invalidRecoveryMetadata() }
    return try objects.child("pack", create: create)
  }
}
