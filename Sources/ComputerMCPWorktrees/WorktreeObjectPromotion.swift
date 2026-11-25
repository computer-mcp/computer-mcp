import Foundation

package struct WorktreePublication: Sendable {
  package let projectID: String
  package let operationID: UUID
  package let oid: String
}

struct WorktreeRecoveryCapture {
  let metadata: WorktreePrivateMetadata
  let privateObjects: WorktreeStagedObjects
  let expectedObjects: WorktreeStagedObjects
  let privateManifest: WorktreeObjectManifest
  let headManifest: WorktreeObjectManifest
  let expectedManifest: WorktreeObjectManifest
  let sourceExpectedManifest: WorktreeObjectManifest?
  let recoveryManifest: WorktreeObjectManifest
  let sourceManifest: WorktreeObjectManifest
}

extension WorktreeRepository {
  /// Verified artifacts remain owned by the staging reservation through the consumer.
  func withRecoveryPacks<Result>(
    _ topology: VerifiedWorktreeTopology, expectedOID: String,
    retainedExpectedObjects: WorktreeDirectory? = nil,
    operationID: UUID, store: WorktreeRecoveryStore.Locked, completionMetadataBytes: Int,
    budget: inout WorktreeObjectBudget,
    _ consume: (
      WorktreeRecoveryCapture, WorktreeRecoveryPack, WorktreeRecoveryPack,
      WorktreeRecoveryStaging
    ) throws -> Result
  ) throws -> Result {
    let initialInput = budget.input
    return try store.withStaging(
      operationID: operationID, inputLimit: budget.remainingInput,
      completionMetadataBytes: completionMetadataBytes
    ) { staging in
      let capture = try captureRecoveryObjects(
        topology, expectedOID: expectedOID, in: staging.directory,
        retainedExpectedObjects: retainedExpectedObjects, budget: &budget)
      try staging.sealCapture(bytes: budget.input - initialInput)
      if capture.privateObjects.directory.identity != capture.expectedObjects.directory.identity {
        let additional = try capture.expectedManifest.subtracting(capture.privateManifest)
        if !additional.entries.isEmpty {
          let supplement = try capture.expectedObjects.generatePack(
            additional, slot: .supplemental, staging: staging)
          try staging.attachSupplement(supplement, to: capture.privateObjects.directory)
          try capture.privateObjects.verifyIntegrity()
        }
      }
      let recovery = try capture.privateObjects.generatePack(
        capture.recoveryManifest, slot: .recovery, staging: staging)
      let source = try capture.privateObjects.generatePack(
        capture.sourceManifest, slot: .source, staging: staging)
      try budget.check()
      try staging.exposeArtifacts()
      return try consume(capture, recovery, source, staging)
    }
  }

  /// The caller owns exclusive staging and any pin on the retained expected-object pool.
  func captureRecoveryObjects(
    _ topology: VerifiedWorktreeTopology, expectedOID: String, in staging: WorktreeDirectory,
    retainedExpectedObjects: WorktreeDirectory? = nil, budget: inout WorktreeObjectBudget
  ) throws -> WorktreeRecoveryCapture {
    try budget.limits.validateRecoveryCapture()
    try budget.check()
    try checkAuthority()
    guard identity.format.contains(expectedOID), expectedOID.utf8.contains(where: { $0 != 48 })
    else { throw WorktreeError.invalidRequest("Invalid expected recovery object ID.") }
    let metadata = try liveRecoveryInput {
      try topology.verifyDirectories()
      try verifyPrivateControls(topology, repository: identity)
      return try WorktreePrivateMetadata(
        directory: topology.gitDirectory, format: identity.format, io: io,
        limit: git.maxOutputBytes * 8, deadline: budget.deadline,
        recoveryRootLimit: budget.limits.objectCount)
    }

    let repository = try prepareCaptureRepository(in: staging, deadline: budget.deadline)
    let snapshot = WorktreeObjectSnapshot(io: io, format: identity.format)
    let privatePool = try acquireRecoveryObjects(
      topology.objects, slot: "private-objects", in: staging, repository: repository,
      snapshot: snapshot, live: true, budget: &budget)
    try liveRecoveryInput { try topology.verifyDirectories() }
    guard let privateManifest = try privatePool.manifest(roots: metadata.roots) else {
      throw WorktreeError.busy("The captured private roots have missing objects.")
    }
    try privatePool.verifyIntegrity()
    guard privateManifest.entries[metadata.head]?.type == .commit,
      let headManifest = try privatePool.manifest(roots: [metadata.head]),
      try privateManifest.union(headManifest) == privateManifest
    else {
      throw WorktreeError.invalidRequest("Captured HEAD has no complete private commit closure.")
    }

    var expectedPool = privatePool
    var expected = try privatePool.manifest(roots: [expectedOID])
    if expected == nil, let retainedExpectedObjects {
      expectedPool = try acquireRecoveryObjects(
        retainedExpectedObjects, slot: "retained-objects", in: staging, repository: repository,
        snapshot: snapshot, live: false, budget: &budget)
      guard let retained = try expectedPool.manifest(roots: [expectedOID]) else {
        throw WorktreeError.recoveryRequired("The pinned expected recovery closure is incomplete.")
      }
      try expectedPool.verifyIntegrity()
      expected = retained
    }

    try budget.check()
    try checkAuthority()
    let sourceObjects = try liveRecoveryInput {
      try identity.verify()
      let sourceObjects = try WorktreeDirectory(URL(fileURLWithPath: identity.objects.path))
      guard sourceObjects.identity == identity.objects else {
        throw WorktreeError.identityChanged("Source object directory was substituted.")
      }
      return sourceObjects
    }
    let sourcePool = try acquireRecoveryObjects(
      sourceObjects, slot: "source-objects", in: staging, repository: repository,
      snapshot: snapshot, live: true, allowLinkedInput: true, budget: &budget)
    try liveRecoveryInput { try identity.verify() }
    let sourceExpected = try sourcePool.manifest(roots: [expectedOID])
    if let sourceExpected {
      guard sourceExpected.entries[expectedOID]?.type == .commit else {
        throw WorktreeError.invalidRequest("The source expected object is not a commit.")
      }
      try sourcePool.verifyIntegrity()
      if let expected {
        guard expected == sourceExpected else {
          throw WorktreeError.invalidRequest("Expected object closures disagree.")
        }
      } else {
        expectedPool = sourcePool
        expected = sourceExpected
      }
    }
    guard let expected, expected.entries[expectedOID]?.type == .commit else {
      throw WorktreeError.recoveryRequired("No complete expected commit closure was acquired.")
    }

    let recovery = try privateManifest.union(expected)
    let source = try sourceExpected.map { try headManifest.subtracting($0) } ?? headManifest
    try budget.check()
    return WorktreeRecoveryCapture(
      metadata: metadata, privateObjects: privatePool, expectedObjects: expectedPool,
      privateManifest: privateManifest, headManifest: headManifest, expectedManifest: expected,
      sourceExpectedManifest: sourceExpected, recoveryManifest: recovery, sourceManifest: source)
  }

  /// The release gate protects the live generation while its expected commit
  /// is checked in a host-owned copy with an independent Git object pool.
  func hasVerifiedPrivateExpectedCommit(
    _ oid: String, topology: VerifiedWorktreeTopology, budget: inout WorktreeObjectBudget
  ) throws -> Bool {
    try budget.check()
    try topology.verifyDirectories()
    try verifyPrivateControls(topology, repository: identity)
    let scratch = try topology.runtime.child(
      "release-proof-" + UUID().uuidString.lowercased(), create: true, exclusive: true)
    let scratchIO = WorktreeJournalIO()
    func verify() throws -> Bool {
      let repository = try prepareCaptureRepository(in: scratch, deadline: budget.deadline)
      let snapshot = WorktreeObjectSnapshot(io: scratchIO, format: identity.format)
      do {
        let pool = try acquireRecoveryObjects(
          topology.objects, slot: "private-objects", in: scratch, repository: repository,
          snapshot: snapshot, live: true, budget: &budget)
        try liveRecoveryInput { try topology.verifyDirectories() }
        guard try pool.manifest(roots: [oid])?.entries[oid]?.type == .commit else {
          return false
        }
        try pool.verifyIntegrity()
        try budget.check()
        return true
      } catch WorktreeError.invalidRequest {
        return false
      }
    }

    let verified: Bool
    do {
      verified = try verify()
    } catch {
      try? topology.runtime.removeOwnedTree(scratch.identity, io: scratchIO)
      throw error
    }
    try topology.runtime.removeOwnedTree(scratch.identity, io: scratchIO)
    return verified
  }

  private func prepareCaptureRepository(
    in staging: WorktreeDirectory, deadline: ContinuousClock.Instant
  ) throws -> WorktreeDirectory {
    let repository = try staging.child("capture.git", create: true, exclusive: true)
    _ = try git.run(
      [
        "init", "--bare", "--template=", "--object-format=" + identity.format.rawValue,
        repository.url.path,
      ],
      at: staging.url, deadline: deadline)
    try repository.verify()
    return repository
  }

  private func acquireRecoveryObjects(
    _ input: WorktreeDirectory, slot: String, in staging: WorktreeDirectory,
    repository: WorktreeDirectory, snapshot: WorktreeObjectSnapshot, live: Bool,
    allowLinkedInput: Bool = false, budget: inout WorktreeObjectBudget
  ) throws -> WorktreeStagedObjects {
    try budget.check()
    try checkAuthority()
    let destination = try staging.child(slot, create: true, exclusive: true)
    func copy() throws -> [WorktreeCopiedObjectFile] {
      try snapshot.copy(
        from: input, to: destination, budget: &budget, allowLinkedInput: allowLinkedInput)
    }
    let files = try live ? liveRecoveryInput(copy) : copy()
    try snapshot.validateRaw(files, in: destination, budget: &budget, reportInvalidImport: true)
    let pool = WorktreeStagedObjects(
      directory: destination, repository: repository, git: git, format: identity.format,
      deadline: budget.deadline, limits: budget.limits)
    try pool.verifyIndexes(files)
    return pool
  }

  private func liveRecoveryInput<Value>(_ capture: () throws -> Value) throws -> Value {
    do {
      return try capture()
    } catch WorktreeError.identityChanged {
      throw WorktreeError.busy("Repository input changed during recovery capture.")
    } catch let error as POSIXError where [.ENOENT, .ENOTDIR, .ELOOP, .ESTALE].contains(error.code)
    {
      throw WorktreeError.busy("Repository input disappeared during recovery capture.")
    }
  }

  func requireDirectRef(_ ref: String, oid: String) throws {
    guard try command(["symbolic-ref", "--quiet", ref], accepting: [0, 1]).exitCode == 1,
      try revision(ref) == oid
    else { throw WorktreeError.recoveryRequired("The expected direct branch changed.") }
  }

}

extension WorktreeRepository {
  package func publish(
    projectID: String, preserving roots: [String] = [],
    limits: WorktreePromotionLimits = .init(),
    authorize: (DerivedProjectRecord) throws -> Void
  ) throws -> WorktreePublication {
    try limits.validate()
    return try withLock(validateHead: false) { lock in
      try publishLocked(
        projectID: projectID, preserving: roots, limits: limits, lock: lock, authorize: authorize)
    }
  }

  func publishLocked(
    projectID: String, preserving roots: [String], limits: WorktreePromotionLimits,
    lock: RepositoryLock, removalID: UUID? = nil, authorize: (DerivedProjectRecord) throws -> Void
  ) throws -> WorktreePublication {
    let removal = try readRemoval(projectID)
    if let removal, removal.phase != .abandoned {
      guard removal.operationID == removalID, removal.phase == .closing else {
        throw WorktreeError.busy("The worktree has a pending removal.")
      }
    } else if removalID != nil {
      throw invalidRecoveryMetadata()
    }
    if var previous = try readPublication(projectID) {
      if previous.removalID == removalID, removalID != nil, previous.phase == .finished,
        previous.sourcePublication?.guards == nil
      {
        try authorize(previous.record)
        return publicationResult(previous)
      }
      if ![.finished, .rejected].contains(previous.phase)
        || previous.sourcePublication?.guards != nil
      {
        let recovered = try recoverPublication(&previous, lock: lock, authorize: authorize)
        if removalID == nil || previous.removalID == removalID { return recovered }
      }
    }
    guard let record = try store.records().first(where: { $0.projectID == projectID }),
      record.state == .active, let registration = record.worktree,
      let creation = try readJournal(projectID), creation.phase == .active,
      try matchesActiveRecord(creation, record), roots.allSatisfy(identity.format.contains)
    else { throw WorktreeError.recoveryRequired("No active publication registration.") }
    try authorize(record)
    try lock.verify()
    let topology = try verifyTopology(
      creation, repository: identity, source: source, validateHead: false)
    let expected = registration.lastPublishedOID
    guard try sourceMetadata().direct(registration.branch).oid == expected else {
      throw sourceMetadataChanged()
    }
    let id = removalID ?? UUID()
    var journal = WorktreePublicationJournal(
      operationID: id, repository: identity, record: record, expectedOID: expected,
      capturedOID: expected, maxPackBytes: limits.inputBytes, removalID: removalID,
      requiredRoots: roots.isEmpty ? nil : Array(Set(roots)).sorted())
    return try WorktreeRecoveryStore(storage: storage, io: io)
      .withExclusive(repository: identity, create: true) { recovery in
        try savePublication(journal, replacing: try publicationDiskBytes(projectID))
        return try finishPublication(
          &journal, topology: topology, limits: limits, recovery: recovery, lock: lock,
          authorize: authorize)
      }
  }

  func recoverPublication(
    _ journal: inout WorktreePublicationJournal, lock: RepositoryLock,
    authorize: (DerivedProjectRecord) throws -> Void
  ) throws -> WorktreePublication {
    guard journal.version == 2 else {
      throw WorktreeError.recoveryRequired("The publication predates recovery-store ownership.")
    }
    return try WorktreeRecoveryStore(storage: storage, io: io)
      .withExclusive(repository: identity, create: journal.handoff == nil) { recovery in
        try finishPublication(
          &journal, topology: nil, limits: .init(), recovery: recovery, lock: lock,
          authorize: authorize)
      }
  }

  private func finishPublication(
    _ journal: inout WorktreePublicationJournal, topology: VerifiedWorktreeTopology?,
    limits: WorktreePromotionLimits, recovery: WorktreeRecoveryStore.Locked, lock: RepositoryLock,
    authorize: (DerivedProjectRecord) throws -> Void
  ) throws -> WorktreePublication {
    var state = journal
    defer { journal = state }
    let record = state.record
    let branch = state.branch
    let id = state.operationID
    let project = record.projectID
    let kind: WorktreeRecoveryIntent.Kind = state.removalID == nil ? .publication : .removal
    try authorize(record)
    try lock.verify()
    try savePublication(state, replacing: publicationBytes(state))
    var budget = try WorktreeObjectBudget(limits)
    func save(_ change: (inout WorktreePublicationJournal) throws -> Void) throws {
      let previous = try publicationBytes(state)
      var next = state
      try change(&next)
      try savePublication(next, replacing: previous)
      state = next
    }
    func revalidateOriginal() throws {
      try Task.checkCancellation()
      try lock.verify()
      try identity.verify()
      try authorize(record)
      guard try store.records().first(where: { $0.projectID == project }) == record else {
        throw DerivedProjectStoreError.revisionConflict
      }
    }
    func admissionGuards() throws -> WorktreeSourceGuards {
      let metadata = try sourceMetadata()
      var owned =
        try state.installationGuards
        ?? .init(
          operationID: id, common: identity.common, branches: [branch], guardingHead: false)
      return try WorktreeSourceGuards.acquire(
        &owned, metadata: metadata, repositoryLock: lock, branches: [branch], guardingHead: false,
        persist: { value in try save { $0.installationGuards = value } })
    }
    func persistHandoff(_ value: WorktreeRecoveryHandoff) throws {
      let captured = try value.retention.capturedHead()
      let roots = value.retention.roots
      guard Set(state.requiredRoots ?? []).isSubset(of: roots),
        let phase = WorktreePublicationJournal.Phase(rawValue: value.phase.rawValue)
      else {
        throw WorktreeError.invalidRequest("Required root was absent from the private capture.")
      }
      try save {
        $0.handoff = value
        $0.capturedOID = captured
        $0.roots = roots
        $0.phase = phase
      }
    }
    if state.sourcePublication == nil {
      if var handoff = state.handoff {
        try resumeRecoveryHandoff(
          &handoff, store: recovery, budget: budget, persist: persistHandoff,
          revalidate: revalidateOriginal, sourceGuards: admissionGuards)
      } else {
        guard let topology else {
          try recovery.finishStagingDisposal(operationID: id)
          try save {
            $0.phase = .rejected
            $0.rejection = "Capture was interrupted before retention."
          }
          throw WorktreeError.busy("Incomplete object capture was discarded; retry publication.")
        }
        do {
          _ = try beginRecoveryHandoff(
            operationID: id, kind: kind, record: record, topology: topology, store: recovery,
            budget: &budget, persist: persistHandoff, revalidate: revalidateOriginal,
            sourceGuards: admissionGuards)
        } catch {
          if state.handoff == nil {
            // A visible first handoff save may have failed directory sync.
            // Resume that exact intent instead of discarding its artifacts.
            let pending = try readPublication(project)
            if pending?.handoff == nil {
              try recovery.finishStagingDisposal(operationID: id)
              try save {
                $0.rejection = String(error.localizedDescription.prefix(512))
                $0.phase = .rejected
              }
            }
          }
          throw error
        }
      }
      let protection = try admissionGuards()
      guard let ownership = state.installationGuards else { throw invalidRecoveryMetadata() }
      let sourcePhase = try WorktreeRecoverySourcePublication(
        repository: identity, record: record, target: state.capturedOID,
        protectedBy: protection, guardOwnership: ownership)
      try save {
        $0.sourcePublication = sourcePhase
        $0.installationGuards = nil
        $0.phase = .sourcePublishing
        if kind == .publication { $0.terminal = WorktreeRecoveryTerminal() }
      }
    }
    guard var sourcePhase = state.sourcePublication, let handoff = state.handoff,
      handoff.retention.generation == recovery.generation
    else { throw invalidRecoveryMetadata() }
    let retention = handoff.retention
    func persistSource(_ value: WorktreeRecoverySourcePublication) throws {
      guard let phase = WorktreePublicationJournal.Phase(rawValue: value.phase.rawValue)
      else { throw invalidRecoveryMetadata() }
      try save {
        $0.sourcePublication = value
        $0.phase = phase
      }
    }
    return try sourcePhase.complete(
      in: self, lock: lock, authorize: authorize,
      verifyRetention: {
        if topology == nil {
          try handoff.verifyRecoveryPack(repository: self, store: recovery, budget: budget)
        } else {
          try recovery.requireRetained(retention)
        }
      },
      completeCatalog: { protection in
        func verifyTerminal() throws {
          try protection.verify()
          try authorize(record)
          guard state.phase == .ledger, state.sourcePublication?.phase == .ledger,
            try protection.metadata.direct(branch).oid == state.capturedOID
          else { throw sourceMetadataChanged() }
          try savePublication(state, replacing: publicationBytes(state))
        }
        try verifyTerminal()
        try sealPublicationLineage(
          .init(
            operationID: id, repository: identity, storeGeneration: recovery.generation,
            owner: retention.owner, expected: state.expectedOID, published: state.capturedOID,
            hadPublishedExpected: record.worktree?.publishedOID != nil))
        try handoff.releaseSourceKeep(repository: self, verifyTerminalOutcome: verifyTerminal)
        if kind == .publication {
          guard var terminal = state.terminal else { throw invalidRecoveryMetadata() }
          try terminal.complete(
            retention, store: recovery, verifyTerminalOutcome: verifyTerminal,
            sealed: { recordID, evidence in
              try requireAcknowledgementSeal(
                recordID, evidence: evidence, owner: retention.owner,
                generation: retention.generation)
            },
            persist: { value in try save { $0.terminal = value } })
        }
      },
      persist: persistSource)
  }

  private func publicationResult(_ journal: WorktreePublicationJournal) -> WorktreePublication {
    .init(
      projectID: journal.record.projectID, operationID: journal.operationID,
      oid: journal.capturedOID)
  }
}

extension WorktreeRepository {
  package func acknowledgeReplacement(
    projectID: String, replacedOID: String, expectedPublishedOID: String,
    authorize: (DerivedProjectRecord) throws -> Void
  ) throws {
    try withLock(validateHead: false) { lock in
      guard identity.format.contains(replacedOID), replacedOID != expectedPublishedOID,
        let record = try store.records().first(where: { $0.projectID == projectID }),
        record.source == source, record.state == .active, let registration = record.worktree,
        registration.publishedOID == expectedPublishedOID,
        let publication = try readPublication(projectID), publication.version == 2,
        publication.phase == .finished, publication.capturedOID == expectedPublishedOID,
        publication.sourcePublication?.guards == nil, let handoff = publication.handoff
      else { throw WorktreeError.recoveryRequired("Replacement acknowledgement is stale.") }
      if let removal = try readRemoval(projectID), removal.phase != .abandoned {
        throw WorktreeError.busy("The worktree has a pending removal.")
      }
      try authorize(record)
      let owner = handoff.retention.owner
      let branch = owner.branch
      let publicationID = publication.operationID
      guard registration.branchID == owner.branchID, registration.branch == branch,
        case .host(let worktreeID, let storageGeneration) = record.provenance,
        owner.worktreeID == worktreeID, owner.storageGeneration == storageGeneration,
        let outcome = try readPublicationLineage(publicationID),
        outcome.owner == owner, outcome.published == expectedPublishedOID
      else { throw invalidRecoveryMetadata() }
      try WorktreeRecoveryStore(storage: storage, io: io)
        .withExclusive(repository: identity) { recovery in
          guard recovery.generation == handoff.retention.generation,
            outcome.storeGeneration == recovery.generation,
            let directory = try replacementDirectory(owner, create: true)
          else { throw invalidRecoveryMetadata() }
          let operationID = try WorktreeReplacementJournal.operationID(
            owner: owner, generation: recovery.generation, publicationID: publicationID,
            replaced: replacedOID, expected: expectedPublishedOID)
          let matching = try readReplacement(
            operationID, in: directory, owner: owner, generation: recovery.generation)
          guard
            matching.map({
              $0.publicationID == publicationID && $0.replaced == replacedOID
                && $0.expected == expectedPublishedOID
            }) ?? true
          else { throw invalidRecoveryMetadata() }
          var journal =
            matching
            ?? .init(
              operationID: operationID, owner: owner, repository: identity,
              storeGeneration: recovery.generation, publicationID: publicationID,
              replaced: replacedOID, expected: expectedPublishedOID)
          let name = journal.operationID.uuidString.lowercased() + ".json"
          var bytes = try matching.map { try recoveryJSON($0) }
          func save(_ change: (inout WorktreeReplacementJournal) -> Void) throws {
            var next = journal
            change(&next)
            let updated = try recoveryJSON(next)
            guard updated.count <= WorktreeRecoveryCatalog.byteLimit else {
              throw WorktreeError.busy("Acknowledgement journal exceeds its byte bound.")
            }
            if updated == bytes {
              try io.synchronize(name, in: directory, expecting: updated)
            } else {
              try io.write(updated, name: name, in: directory, replacing: bytes)
            }
            journal = next
            bytes = updated
          }
          var planned: WorktreeRecoveryAcknowledgement?
          if journal.change == nil {
            guard try sourceMetadata().direct(branch).oid == expectedPublishedOID else {
              throw sourceMetadataChanged()
            }
            let catalog = try recovery.catalog()
            let operations = Set(
              catalog.records.lazy.filter {
                $0.owner == owner && $0.state == .retained && $0.oid == replacedOID
              }.flatMap { record in
                record.claims.lazy.filter { $0.reason == .publishedReplacement }.map(\.operationID)
              })
            var lineage: Set<UUID> = []
            for operation in operations {
              guard let prior = try readPublicationLineage(operation),
                prior.owner == owner, prior.storeGeneration == recovery.generation,
                prior.expected == replacedOID, prior.published != replacedOID,
                prior.hadPublishedExpected
              else { throw invalidRecoveryMetadata() }
              lineage.insert(operation)
            }
            planned = try WorktreeRecoveryAcknowledgement(
              operationID: journal.operationID, publicationID: publicationID, owner: owner,
              replacedOID: replacedOID, expectedPublishedOID: expectedPublishedOID,
              lineage: lineage, catalog: catalog)
          }
          let metadata = try sourceMetadata()
          if journal.guardOwnership?.cleaning == true {
            guard let owned = journal.guardOwnership else { throw invalidRecoveryMetadata() }
            try WorktreeSourceGuards.finishCleanup(
              owned, metadata: metadata, repositoryLock: lock, branches: [branch],
              guardingHead: false)
            try save { $0.guardOwnership = nil }
          }
          if journal.change?.phase == .finished, journal.guardOwnership == nil { return }
          try save { _ in }
          var owned =
            try journal.guardOwnership
            ?? .init(
              operationID: journal.operationID, common: identity.common, branches: [branch],
              guardingHead: false)
          let protection = try WorktreeSourceGuards.acquire(
            &owned, metadata: metadata, repositoryLock: lock, branches: [branch],
            guardingHead: false, persist: { next in try save { $0.guardOwnership = next } })
          func verifySealed() throws {
            try lock.verify()
            try protection.verify()
            try authorize(record)
            let expectedProtection = ProtectedWorktreeBranch(
              repository: identity.common, branchID: registration.branchID, branch: branch,
              base: registration.base, baseOID: registration.baseOID,
              publishedOID: expectedPublishedOID,
              worktreeID: worktreeID, mergedOID: registration.mergedOID,
              baseHistory: registration.baseHistory)
            guard try store.records().first(where: { $0.projectID == projectID }) == record,
              try store.protectedBranches().contains(expectedProtection)
            else { throw DerivedProjectStoreError.revisionConflict }
          }
          func verifyLive() throws {
            try verifySealed()
            guard try metadata.direct(branch).oid == expectedPublishedOID,
              try readPublication(projectID)?.operationID == publicationID
            else { throw sourceMetadataChanged() }
          }
          if let planned {
            try verifyLive()
            try save { $0.change = planned }
          }
          guard var change = journal.change else { throw invalidRecoveryMetadata() }
          try change.complete(
            store: recovery, verifyLive: verifyLive, verifySealed: verifySealed,
            persist: { next in try save { $0.change = next } })
          try protection.release(
            &owned, branches: [branch], guardingHead: false,
            persist: { next in try save { $0.guardOwnership = next } })
          try save { $0.guardOwnership = nil }
        }
    }
  }
}
