import Foundation

struct WorktreeRecoveryRecord: Codable, Equatable, Sendable {
  enum ObjectType: String, Codable, Sendable { case commit, tree, blob, tag }
  enum State: String, Codable, Sendable { case retaining, retained, releasing }

  struct Owner: Codable, Equatable, Sendable {
    let source: DerivedProjectSource
    let branchID: UUID
    let branch: String
    let worktreeID: UUID
    let storageGeneration: UUID

    func validate(repository: WorktreeRepositoryIdentity) throws {
      guard source.root == repository.source.path, !source.id.isEmpty, source.id != "*",
        !source.id.contains("\0"), source.registeredAt.timeIntervalSinceReferenceDate.isFinite
      else { throw invalidRecoveryMetadata() }
      try requireRecoveryBranch(branch)
    }
  }

  struct Claim: Codable, Equatable, Sendable {
    enum Reason: String, Codable, Sendable {
      case privateHead, privateReference, privateReflog, publishedReplacement
    }

    struct Capture: Codable, Equatable, Sendable {
      let id: UUID
      let metadataDigest: String
      let storageGeneration: UUID
    }

    let id: UUID
    let operationID: UUID
    let reason: Reason
    let rootOID: String
    let capture: Capture?
  }

  struct Acknowledgement: Codable, Equatable, Sendable {
    let operationID: UUID
    let selectedRevision: Int64
    let claimIDs: [UUID]
  }

  struct Base: Codable, Equatable, Sendable {
    let ref: String
    let oid: String
    let history: WorktreeRefHistory?
  }

  struct Selection: Codable, Equatable, Sendable {
    let recordID: UUID
    let revision: Int64
    let oid: String
  }

  let id: UUID
  let storeGeneration: UUID
  let owner: Owner
  let oid: String
  let objectType: ObjectType
  let base: Base
  var revision: Int64
  var state: State
  var claims: [Claim]
  var acknowledgements: [Acknowledgement]
  var dependencies: [UUID]

  var selection: Selection { .init(recordID: id, revision: revision, oid: oid) }

  func validate(repository: WorktreeRepositoryIdentity, generation: UUID) throws {
    try owner.validate(repository: repository)
    try requireRecoveryBranch(base.ref)
    guard storeGeneration == generation, revision > 0, revision < Int64.max,
      repository.format.containsRecoveryOID(oid), repository.format.containsRecoveryOID(base.oid),
      Set(claims.map(\.id)).count == claims.count,
      Set(acknowledgements.map(\.operationID)).count == acknowledgements.count,
      Set(dependencies).count == dependencies.count
    else { throw invalidRecoveryMetadata() }
    if let history = base.history {
      guard history.bytes > 0, history.digest.isRecoveryDigest,
        repository.format.containsRecoveryOID(history.oid)
      else { throw invalidRecoveryMetadata() }
    }
    for claim in claims {
      guard claim.rootOID == oid, (claim.reason == .publishedReplacement) == (claim.capture == nil)
      else { throw invalidRecoveryMetadata() }
      if let capture = claim.capture {
        guard capture.storageGeneration == owner.storageGeneration,
          capture.metadataDigest.isRecoveryDigest
        else { throw invalidRecoveryMetadata() }
      }
    }
    for acknowledgement in acknowledgements {
      guard acknowledgement.selectedRevision > 0, acknowledgement.selectedRevision < revision,
        !acknowledgement.claimIDs.isEmpty,
        Set(acknowledgement.claimIDs).count == acknowledgement.claimIDs.count
      else { throw invalidRecoveryMetadata() }
    }
  }

  func follows(_ previous: Self) -> Bool {
    guard previous.revision < Int64.max - 1 else { return false }
    return id == previous.id && storeGeneration == previous.storeGeneration
      && owner == previous.owner && oid == previous.oid && objectType == previous.objectType
      && base == previous.base && revision == previous.revision + 1
  }
}

struct WorktreeRecoveryGrowth: Codable, Equatable, Sendable {
  var bytes = 0
  var references = 0

  mutating func add(_ other: Self) throws {
    bytes = try recoverySum(bytes, other.bytes)
    references = try recoverySum(references, other.references)
  }

  mutating func consume(_ growth: Self) throws {
    guard bytes >= growth.bytes, references >= growth.references else {
      throw WorktreeError.busy("Recovery operation exceeded its completion reserve.")
    }
    bytes -= growth.bytes
    references -= growth.references
  }

  static func increase(from previous: WorktreeRecoveryRecord, to next: WorktreeRecoveryRecord)
    throws -> Self
  {
    let bytes = max(
      0, try recoveryJSON(next).count - recoveryJSON(previous).count)
    let references = max(0, try next.referenceCount() - previous.referenceCount())
    return Self(bytes: bytes, references: references)
  }
}

struct WorktreeRecoveryIntent: Codable, Equatable, Sendable {
  enum Kind: String, Codable, Sendable {
    case publication, merge, removal, acknowledgement, reconciliation, branchDeletion, release
  }

  let id: UUID
  let kind: Kind
  let requestDigest: String
  let selections: [WorktreeRecoveryRecord.Selection]
  var completion: WorktreeRecoveryGrowth
}

struct WorktreeRecoveryCatalog: Codable, Equatable, Sendable {
  static let byteLimit = 128 * 1024 * 1024
  static let recordLimit = 250_000
  static let referenceLimit = 250_000

  var version = 1
  let generation: UUID
  var records: [WorktreeRecoveryRecord] = []
  var intents: [WorktreeRecoveryIntent] = []

  func validate(repository: WorktreeRepositoryIdentity, generation: UUID, byteCount: Int) throws {
    guard version == 1, self.generation == generation else { throw invalidRecoveryMetadata() }
    guard records.count <= Self.recordLimit, intents.count <= Self.referenceLimit else {
      throw WorktreeError.busy("Recovery catalog exceeds its record limit.")
    }
    var byID: [UUID: WorktreeRecoveryRecord] = [:]
    var claimIDs: Set<UUID> = []
    var usage = WorktreeRecoveryGrowth(bytes: byteCount)
    for record in records {
      try record.validate(repository: repository, generation: generation)
      guard byID.updateValue(record, forKey: record.id) == nil,
        record.claims.allSatisfy({ claimIDs.insert($0.id).inserted })
      else { throw invalidRecoveryMetadata() }
      try usage.add(.init(references: record.referenceCount()))
    }
    var operationIDs: Set<UUID> = []
    var dependencies: [UUID: Set<UUID>] = [:]
    var releases: Set<UUID> = []
    for intent in intents {
      guard operationIDs.insert(intent.id).inserted, intent.requestDigest.isRecoveryDigest,
        !intent.selections.isEmpty
      else { throw invalidRecoveryMetadata() }
      try usage.add(intent.completion)
      for selection in intent.selections {
        guard let record = byID[selection.recordID], selection.oid == record.oid,
          selection.revision > 0, selection.revision <= record.revision,
          dependencies[record.id, default: []].insert(intent.id).inserted
        else { throw invalidRecoveryMetadata() }
        if intent.kind == .release {
          guard record.state == .releasing, selection.revision == record.revision - 1,
            releases.insert(record.id).inserted
          else { throw invalidRecoveryMetadata() }
        }
      }
    }
    for record in records {
      guard Set(record.dependencies) == (dependencies[record.id] ?? []),
        (record.state == .releasing) == releases.contains(record.id),
        record.state != .releasing || record.dependencies.count == 1,
        record.state != .retaining || !record.dependencies.isEmpty
      else { throw invalidRecoveryMetadata() }
    }
    guard usage.bytes <= Self.byteLimit, usage.references <= Self.referenceLimit else {
      throw WorktreeError.busy("Recovery catalog exceeds its reserved capacity.")
    }
  }
}

struct WorktreeRecoveryReleaseReceipt: Codable, Equatable, Sendable {
  enum Outcome: String, Codable, Sendable { case released }

  static let byteLimit = 128 * 1024
  static let operationByteLimit = WorktreeRecoveryCatalog.byteLimit

  var version = 1
  let storeGeneration: UUID
  let owner: WorktreeRecoveryRecord.Owner
  let selection: WorktreeRecoveryRecord.Selection
  let operationID: UUID
  let requestDigest: String
  let selectionDigest: String
  var outcome: Outcome = .released

  func validate(repository: WorktreeRepositoryIdentity, generation: UUID, recordID: UUID) throws {
    try owner.validate(repository: repository)
    guard version == 1, storeGeneration == generation, selection.recordID == recordID,
      selection.revision > 0, selection.revision < Int64.max - 1,
      repository.format.containsRecoveryOID(selection.oid), requestDigest.isRecoveryDigest,
      selectionDigest.isRecoveryDigest
    else { throw invalidRecoveryMetadata() }
  }

  func encoded() throws -> Data {
    let bytes = try recoveryJSON(self)
    guard bytes.count <= Self.byteLimit else {
      throw WorktreeError.busy("Recovery release receipt exceeds its byte limit.")
    }
    return bytes
  }

  static func digest(of selections: [WorktreeRecoveryRecord.Selection]) throws -> String {
    let sorted = selections.sorted { $0.recordID.uuidString < $1.recordID.uuidString }
    return WorktreeObjectSnapshot.digest(try recoveryJSON(sorted))
  }
}

extension WorktreeRecoveryRecord {
  fileprivate func referenceCount() throws -> Int {
    try acknowledgements.reduce(dependencies.count) {
      try recoverySum($0, $1.claimIDs.count)
    }
  }
}

extension WorktreeObjectFormat {
  func containsRecoveryOID(_ oid: String) -> Bool {
    contains(oid) && oid.utf8.contains { $0 != 48 }
  }
}

extension String {
  var isRecoveryDigest: Bool { WorktreeObjectFormat.sha256.contains(self) }
}

func recoveryJSON(_ value: some Encodable) throws -> Data {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  return try encoder.encode(value)
}

func recoverySum(_ first: Int, _ second: Int) throws -> Int {
  let (sum, overflow) = first.addingReportingOverflow(second)
  guard first >= 0, second >= 0, !overflow else { throw invalidRecoveryMetadata() }
  return sum
}

func invalidRecoveryMetadata() -> WorktreeError {
  .recoveryRequired("Invalid recovery store metadata.")
}

private func requireRecoveryBranch(_ ref: String) throws {
  guard ref.hasPrefix("refs/heads/"), ref.count > "refs/heads/".count
  else { throw invalidRecoveryMetadata() }
  do { try WorktreePrivateMetadata.requireRef(ref) } catch { throw invalidRecoveryMetadata() }
}
