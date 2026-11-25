import Foundation

struct WorktreePublicationJournal: Codable {
  enum Phase: String, Codable {
    case captured, verified, retaining, retained, sourceInstalling, sourceInstalled
    case sourcePublishing, sourcePublished, ledger, finished, rejected
    // Version one can be read for historical outcomes.
    case copied, installing, installed, publishing, published
  }

  var version = 2
  let operationID: UUID
  let repository: WorktreeRepositoryIdentity
  let record: DerivedProjectRecord
  let expectedOID: String
  var capturedOID: String
  let maxPackBytes: Int
  var roots: [String] = []
  var phase: Phase = .captured
  var removalID: UUID?
  var requiredRoots: [String]?
  var handoff: WorktreeRecoveryHandoff?
  var installationGuards: WorktreeSourceGuardJournal?
  var sourcePublication: WorktreeRecoverySourcePublication?
  var terminal: WorktreeRecoveryTerminal?
  var rejection: String?

  var branch: String { record.worktree!.branch }
  var pack: String? { handoff?.sourceInstallation.map { "pack-" + $0.artifact.hash } }
}

struct WorktreePublishedReplacement: Codable, Equatable {
  let operationID: UUID
  let repository: WorktreeRepositoryIdentity
  let storeGeneration: UUID
  let owner: WorktreeRecoveryRecord.Owner
  let expected: String
  let published: String
  let hadPublishedExpected: Bool
}

extension WorktreeRepository {
  func publicationDirectory() throws -> WorktreeDirectory {
    try WorktreeDirectory(storage.journals).child("publications", create: true)
  }

  func publicationBytes(_ journal: WorktreePublicationJournal) throws -> Data {
    try recoveryJSON(journal)
  }

  func publicationDiskBytes(_ projectID: String) throws -> Data? {
    try io.read(
      projectID + ".json", in: publicationDirectory(), limit: WorktreeRecoveryCatalog.byteLimit)
  }

  func savePublication(_ journal: WorktreePublicationJournal, replacing previous: Data?) throws {
    let bytes = try publicationBytes(journal)
    guard bytes.count <= WorktreeRecoveryCatalog.byteLimit else {
      throw WorktreeError.busy("Publication journal exceeds its byte bound.")
    }
    let directory = try publicationDirectory()
    let name = journal.record.projectID + ".json"
    if bytes == previous {
      try io.synchronize(name, in: directory, expecting: bytes)
    } else {
      try io.write(bytes, name: name, in: directory, replacing: previous)
    }
  }

  func readPublication(_ projectID: String) throws -> WorktreePublicationJournal? {
    guard let bytes = try publicationDiskBytes(projectID) else { return nil }
    let journal = try JSONDecoder().decode(WorktreePublicationJournal.self, from: bytes)
    try journal.record.validate()
    guard [1, 2].contains(journal.version), journal.repository == identity,
      journal.record.source == source, journal.record.projectID == projectID,
      let registration = journal.record.worktree, registration.repository == identity,
      journal.maxPackBytes > 0, journal.maxPackBytes < Int.max / 4,
      identity.format.contains(journal.expectedOID), identity.format.contains(journal.capturedOID),
      journal.expectedOID == registration.lastPublishedOID
    else { throw invalidRecoveryMetadata() }
    if journal.version == 1 { return journal }
    guard journal.removalID.map({ $0 == journal.operationID }) ?? true,
      journal.installationGuards.map({ $0.operationID == journal.operationID }) ?? true,
      journal.requiredRoots?.allSatisfy(identity.format.contains) ?? true
    else { throw invalidRecoveryMetadata() }
    if let handoff = journal.handoff {
      let retention = handoff.retention
      guard retention.operationID == journal.operationID, retention.owner.source == source,
        retention.owner.branchID == registration.branchID, retention.owner.branch == journal.branch,
        retention.owner.worktreeID == journal.record.provenance.worktreeID,
        case .host(_, let storageGeneration) = journal.record.provenance,
        retention.owner.storageGeneration == storageGeneration,
        retention.expectedOID == journal.expectedOID, retention.roots == journal.roots,
        try retention.capturedHead() == journal.capturedOID,
        retention.kind == (journal.removalID == nil ? .publication : .removal)
      else { throw invalidRecoveryMetadata() }
      if journal.sourcePublication == nil, handoff.phase.rawValue != journal.phase.rawValue {
        throw invalidRecoveryMetadata()
      }
    } else if ![.captured, .rejected].contains(journal.phase) {
      throw invalidRecoveryMetadata()
    }
    if let publication = journal.sourcePublication {
      guard publication.operationID == journal.operationID, publication.repository == identity,
        publication.record == journal.record, publication.proof.target == journal.capturedOID,
        journal.handoff?.phase == .sourceInstalled, journal.installationGuards == nil,
        publication.phase.rawValue == journal.phase.rawValue,
        journal.removalID != nil || journal.terminal != nil,
        journal.phase != .finished || journal.removalID != nil || journal.terminal?.receipts != nil
      else { throw invalidRecoveryMetadata() }
    } else if [.sourcePublishing, .sourcePublished, .ledger, .finished].contains(journal.phase) {
      throw invalidRecoveryMetadata()
    }
    if [.copied, .installing, .installed, .publishing, .published].contains(journal.phase) {
      throw invalidRecoveryMetadata()
    }
    return journal
  }

  func sealPublicationLineage(_ outcome: WorktreePublishedReplacement) throws {
    let directory = try publicationDirectory().child("outcomes", create: true)
    let name = outcome.operationID.uuidString.lowercased() + ".json"
    let bytes = try recoveryJSON(outcome)
    if let existing = try io.read(name, in: directory, limit: 131_072) {
      guard existing == bytes else { throw invalidRecoveryMetadata() }
      try io.synchronize(name, in: directory, expecting: bytes)
    } else {
      try io.write(bytes, name: name, in: directory, replacing: nil)
    }
  }

  func readPublicationLineage(_ operationID: UUID) throws -> WorktreePublishedReplacement? {
    let directory = try publicationDirectory()
    guard try directory.hasEntry("outcomes") else { return nil }
    let outcomes = try directory.child("outcomes")
    let name = operationID.uuidString.lowercased() + ".json"
    guard let bytes = try io.read(name, in: outcomes, limit: 131_072) else { return nil }
    let outcome = try JSONDecoder().decode(WorktreePublishedReplacement.self, from: bytes)
    guard outcome.operationID == operationID, outcome.repository == identity,
      outcome.owner.source == source, identity.format.contains(outcome.expected),
      identity.format.contains(outcome.published)
    else { throw invalidRecoveryMetadata() }
    try io.synchronize(name, in: outcomes, expecting: bytes)
    return outcome
  }

}

struct WorktreeReplacementJournal: Codable {
  let operationID: UUID
  let owner: WorktreeRecoveryRecord.Owner
  let repository: WorktreeRepositoryIdentity
  let storeGeneration: UUID
  let publicationID: UUID
  let replaced: String
  let expected: String
  var guardOwnership: WorktreeSourceGuardJournal?
  var change: WorktreeRecoveryAcknowledgement?

  // The OID-only API retries the same request within one publication without
  // enumerating the historical acknowledgements or selecting new claims.
  static func operationID(
    owner: WorktreeRecoveryRecord.Owner, generation: UUID, publicationID: UUID,
    replaced: String, expected: String
  ) throws -> UUID {
    struct Request: Encodable {
      let version = 1
      let owner: WorktreeRecoveryRecord.Owner
      let generation: UUID
      let publicationID: UUID
      let replaced: String
      let expected: String
    }
    let digest = WorktreeObjectSnapshot.digest(
      try recoveryJSON(
        Request(
          owner: owner, generation: generation, publicationID: publicationID,
          replaced: replaced, expected: expected)))
    var bytes = Array(digest.utf8.prefix(32))
    bytes[12] = UInt8(ascii: "8")
    bytes[16] = UInt8(ascii: "a")
    let spelling = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
      .map { String(decoding: bytes[$0], as: UTF8.self) }.joined(separator: "-")
    guard let id = UUID(uuidString: spelling) else { throw invalidRecoveryMetadata() }
    return id
  }
}

extension WorktreeRepository {
  func replacementDirectory(_ owner: WorktreeRecoveryRecord.Owner, create: Bool)
    throws -> WorktreeDirectory?
  {
    let journals = try WorktreeDirectory(storage.journals)
    guard try create || journals.hasEntry("acknowledgements") else { return nil }
    let root = try journals.child("acknowledgements", create: create)
    let name = owner.worktreeID.uuidString.lowercased()
    guard try create || root.hasEntry(name) else { return nil }
    return try root.child(name, create: create)
  }

  func readReplacement(
    _ id: UUID, in directory: WorktreeDirectory, owner: WorktreeRecoveryRecord.Owner,
    generation: UUID
  ) throws -> WorktreeReplacementJournal? {
    let name = id.uuidString.lowercased() + ".json"
    guard let bytes = try io.read(name, in: directory, limit: WorktreeRecoveryCatalog.byteLimit)
    else { return nil }
    let journal = try JSONDecoder().decode(WorktreeReplacementJournal.self, from: bytes)
    guard journal.operationID == id, journal.repository == identity, journal.owner == owner,
      journal.storeGeneration == generation,
      try id
        == WorktreeReplacementJournal.operationID(
          owner: owner, generation: generation, publicationID: journal.publicationID,
          replaced: journal.replaced, expected: journal.expected),
      journal.guardOwnership.map({ $0.operationID == id }) ?? true,
      journal.expected != journal.replaced,
      identity.format.contains(journal.expected), identity.format.contains(journal.replaced),
      journal.change.map({
        $0.operationID == id && $0.owner == owner && $0.generation == generation
          && $0.publicationID == journal.publicationID
          && $0.replacedOID == journal.replaced && $0.expectedPublishedOID == journal.expected
      }) ?? true
    else { throw invalidRecoveryMetadata() }
    try io.synchronize(name, in: directory, expecting: bytes)
    return journal
  }

  func requireAcknowledgementSeal(
    _ recordID: UUID, evidence: WorktreeRecoveryRecord.Acknowledgement,
    owner: WorktreeRecoveryRecord.Owner, generation: UUID
  ) throws -> Bool {
    guard let directory = try replacementDirectory(owner, create: false),
      let journal = try readReplacement(
        evidence.operationID, in: directory, owner: owner, generation: generation),
      let change = journal.change
    else { throw invalidRecoveryMetadata() }
    return change.authorizes(recordID: recordID, eligibility: evidence)
  }
}
