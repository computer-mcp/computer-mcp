import Foundation

/// Exact records admitted by one captured publication or removal. The
/// lifecycle journal stores this value before either catalog or anchor writes.
struct WorktreeRecoveryRetention: Codable, Equatable {
  let operationID: UUID
  let generation: UUID
  let kind: WorktreeRecoveryIntent.Kind
  let owner: WorktreeRecoveryRecord.Owner
  let capture: WorktreeRecoveryRecord.Claim.Capture
  let roots: [String]
  let expectedOID: String
  let closureDigest: String
  let admitted: [WorktreeRecoveryRecord]

  init(
    operationID: UUID, kind: WorktreeRecoveryIntent.Kind, record: DerivedProjectRecord,
    objects: WorktreeRecoveryCapture, expectedOID: String, catalog: WorktreeRecoveryCatalog
  ) throws {
    guard [.publication, .removal].contains(kind), let registration = record.worktree,
      case .host(let worktreeID, let storageGeneration) = record.provenance,
      let fingerprint = objects.metadata.fingerprint, fingerprint.isRecoveryDigest
    else { throw invalidRecoveryMetadata() }
    let owner = WorktreeRecoveryRecord.Owner(
      source: record.source, branchID: registration.branchID, branch: registration.branch,
      worktreeID: worktreeID, storageGeneration: storageGeneration)
    let base = WorktreeRecoveryRecord.Base(
      ref: registration.base, oid: registration.baseOID, history: registration.baseHistory)
    let capture = WorktreeRecoveryRecord.Claim.Capture(
      id: operationID, metadataDigest: fingerprint, storageGeneration: storageGeneration)
    self.operationID = operationID
    generation = catalog.generation
    self.kind = kind
    self.owner = owner
    self.capture = capture
    roots = objects.metadata.roots
    self.expectedOID = expectedOID
    closureDigest = try Self.digest(objects.recoveryManifest)
    guard expectedOID == (registration.publishedOID ?? registration.baseOID) else {
      throw invalidRecoveryMetadata()
    }

    var reasons: [String: Set<WorktreeRecoveryRecord.Claim.Reason>] = [
      objects.metadata.head: [.privateHead]
    ]
    for oid in objects.metadata.refs.values { reasons[oid, default: []].insert(.privateReference) }
    for oids in objects.metadata.reflogRoots.values {
      for oid in oids { reasons[oid, default: []].insert(.privateReflog) }
    }
    guard Set(roots) == Set(reasons.keys) else { throw invalidRecoveryMetadata() }
    if kind == .publication, registration.publishedOID != nil, expectedOID != objects.metadata.head
    {
      reasons[expectedOID, default: []].insert(.publishedReplacement)
    }
    let matching = Dictionary(
      grouping: catalog.records.filter {
        $0.state == .retained && $0.owner == owner && $0.base == base
      }, by: \.oid)
    admitted = try Set(roots).union([expectedOID]).sorted().map { oid in
      guard let type = objects.recoveryManifest.entries[oid]?.type else {
        throw invalidRecoveryMetadata()
      }
      let claims: [WorktreeRecoveryRecord.Claim] = reasons[oid, default: []]
        .sorted { $0.rawValue < $1.rawValue }
        .map {
          .init(
            id: UUID(), operationID: operationID, reason: $0, rootOID: oid,
            capture: $0 == .publishedReplacement ? nil : capture)
        }
      if var existing = matching[oid]?.first(where: { $0.objectType == type }) {
        guard existing.revision < Int64.max - 2, !existing.dependencies.contains(operationID)
        else { throw invalidRecoveryMetadata() }
        existing.revision += 1
        existing.claims += claims
        existing.dependencies.append(operationID)
        return existing
      }
      return WorktreeRecoveryRecord(
        id: UUID(), storeGeneration: catalog.generation, owner: owner, oid: oid,
        objectType: type, base: base, revision: 1, state: .retaining, claims: claims,
        acknowledgements: [], dependencies: [operationID])
    }
  }

  var retained: [WorktreeRecoveryRecord] {
    admitted.map { record in
      guard record.state == .retaining else { return record }
      var retained = record
      retained.revision += 1
      retained.state = .retained
      return retained
    }
  }

  func requestDigest() throws -> String {
    let bytes = try recoveryJSON(self)
    guard bytes.count <= WorktreeRecoveryCatalog.byteLimit else {
      throw WorktreeError.busy("Recovery retention selection exceeds its journal bound.")
    }
    return WorktreeObjectSnapshot.digest(bytes)
  }

  func verifyManifest(_ manifest: WorktreeObjectManifest) throws {
    guard try Self.digest(manifest) == closureDigest,
      admitted.allSatisfy({ manifest.entries[$0.oid]?.type == $0.objectType })
    else { throw invalidRecoveryMetadata() }
  }

  func capturedHead() throws -> String {
    let heads = admitted.flatMap { record in
      record.claims.filter { $0.capture == capture && $0.reason == .privateHead }.map(\.rootOID)
    }
    guard heads.count == 1, let head = heads.first else { throw invalidRecoveryMetadata() }
    return head
  }

  func verifyFinalCapture(_ metadata: WorktreePrivateMetadata) throws {
    guard kind == .removal, metadata.fingerprint == capture.metadataDigest,
      metadata.roots == roots, try metadata.head == capturedHead()
    else {
      throw WorktreeError.recoveryRequired("Private roots changed after final retention capture.")
    }
  }

  func validate(in catalog: WorktreeRecoveryCatalog, repository: WorktreeRepositoryIdentity) throws
  {
    let roots = Set(roots)
    let captured = Set(
      admitted.flatMap { record in
        record.claims.filter { $0.capture == capture }.map(\.rootOID)
      })
    guard generation == catalog.generation, [.publication, .removal].contains(kind),
      capture.id == operationID, capture.storageGeneration == owner.storageGeneration,
      capture.metadataDigest.isRecoveryDigest, closureDigest.isRecoveryDigest,
      !roots.isEmpty, roots.count == self.roots.count,
      Set(admitted.map(\.id)).count == admitted.count,
      Set(admitted.map(\.oid)) == roots.union([expectedOID]),
      admitted.count == Set(admitted.map(\.oid)).count, captured == roots,
      try roots.contains(capturedHead())
    else { throw invalidRecoveryMetadata() }
    for record in admitted {
      try record.validate(repository: repository, generation: generation)
      guard record.owner == owner, record.dependencies.contains(operationID),
        record.revision < Int64.max - 2, record.state != .releasing,
        record.claims.filter({ $0.operationID == operationID }).allSatisfy({
          $0.reason == .publishedReplacement
            ? kind == .publication && $0.capture == nil && $0.rootOID == expectedOID
            : $0.capture == capture && roots.contains($0.rootOID)
        })
      else { throw invalidRecoveryMetadata() }
    }
  }

  private static func digest(_ manifest: WorktreeObjectManifest) throws -> String {
    WorktreeObjectSnapshot.digest(try recoveryJSON(manifest.entries))
  }
}

/// The lifecycle journal freezes the temporary-root release before any anchor
/// deletion. An empty selection records that every root still has an owner.
struct WorktreeRecoveryTerminal: Codable, Equatable {
  let releaseOperationID: UUID
  private(set) var receipts: [WorktreeRecoveryReleaseReceipt]?

  init() { releaseOperationID = UUID() }

  mutating func complete(
    _ retention: WorktreeRecoveryRetention, store: WorktreeRecoveryStore.Locked,
    verifyTerminalOutcome: () throws -> Void, sealed: WorktreeAcknowledgementSealCheck,
    persist: (Self) throws -> Void
  ) throws {
    try verifyTerminalOutcome()
    if receipts == nil {
      let records = try store.endRetention(retention, verifyTerminalOutcome: verifyTerminalOutcome)
      let temporary = retention.admitted.first {
        $0.oid == retention.expectedOID && $0.claims.isEmpty
      }
      let releases = try records.filter { record in
        guard record.claims.isEmpty, record.dependencies.isEmpty else { return false }
        if record.id == temporary?.id { return true }
        for acknowledgement in record.acknowledgements {
          if try sealed(record.id, acknowledgement) { return true }
        }
        return false
      }
      let selection = try WorktreeRecoveryReleaseReceipt.digest(of: releases.map(\.selection))
      let digest = try retention.requestDigest()
      var next = self
      next.receipts = releases.map {
        .init(
          storeGeneration: retention.generation, owner: $0.owner, selection: $0.selection,
          operationID: releaseOperationID, requestDigest: digest, selectionDigest: selection)
      }
      try persist(next)
      self = next
    }
    try persist(self)
    if let receipts, !receipts.isEmpty {
      var allowed: [UUID: String] = [:]
      for record in retention.admitted {
        guard allowed.updateValue(record.oid, forKey: record.id) == nil
        else { throw invalidRecoveryMetadata() }
      }
      let digest = try retention.requestDigest()
      guard
        receipts.allSatisfy({
          $0.storeGeneration == retention.generation && $0.owner == retention.owner
            && $0.operationID == releaseOperationID && $0.requestDigest == digest
            && allowed[$0.selection.recordID] == $0.selection.oid
        })
      else { throw invalidRecoveryMetadata() }
      try store.releaseAnchors(receipts, verifyAuthority: verifyTerminalOutcome)
    }
  }
}
