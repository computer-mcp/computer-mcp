import Foundation

struct WorktreePublicationJournal: Codable {
  enum Phase: String, Codable {
    case captured, copied, verified, installing, installed, publishing, published, ledger, finished
    case rejected
  }
  let version: Int
  let operationID: UUID
  let repository: WorktreeRepositoryIdentity
  let record: DerivedProjectRecord
  let expectedOID: String
  let capturedOID: String
  let maxPackBytes: Int
  let roots: [String]
  let preservationRef: String
  var phase: Phase
  var staging: WorktreeDirectoryIdentity?
  var files: [WorktreeCopiedObjectFile] = []
  var manifest: [String] = []
  var pack: String?
  var packDigest: String?
  var indexDigest: String?
  var replacementAcknowledgements: [String]?
  var protectionsBefore: [String: String]?
  var rejection: String?

  var branch: String { record.worktree!.branch }
}

extension WorktreeRepository {
  func publicationDirectory() throws -> WorktreeDirectory {
    try WorktreeDirectory(storage.journals).child("publications", create: true)
  }

  func publicationBytes(_ journal: WorktreePublicationJournal) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(journal)
  }

  func savePublication(_ journal: WorktreePublicationJournal, replacing previous: Data?) throws {
    let bytes = try publicationBytes(journal)
    guard bytes.count <= git.maxOutputBytes * 8 else {
      throw WorktreeError.busy("Publication journal exceeds its byte bound.")
    }
    try io.write(
      bytes, name: journal.record.projectID + ".json",
      in: publicationDirectory(), replacing: previous)
  }

  func readPublication(_ projectID: String) throws -> WorktreePublicationJournal? {
    guard
      let bytes = try io.read(
        projectID + ".json", in: publicationDirectory(), limit: git.maxOutputBytes * 8)
    else { return nil }
    let journal = try JSONDecoder().decode(WorktreePublicationJournal.self, from: bytes)
    try journal.record.validate()
    guard journal.version == 1, journal.repository == identity,
      journal.record.source == source, journal.record.projectID == projectID,
      journal.record.worktree != nil, journal.maxPackBytes > 0, journal.maxPackBytes < Int.max / 4,
      !journal.roots.isEmpty, journal.roots.contains(journal.capturedOID),
      journal.roots.allSatisfy(identity.format.contains),
      identity.format.contains(journal.expectedOID),
      identity.format.contains(journal.capturedOID),
      journal.preservationRef == preservationRef(journal.record, oid: journal.expectedOID)
    else { throw WorktreeError.recoveryRequired("Invalid publication journal identity.") }
    if let staging = journal.staging {
      guard
        staging.path
          == (try publicationDirectory()).url.appendingPathComponent(
            journal.operationID.uuidString.lowercased()
          ).path
      else { throw WorktreeError.recoveryRequired("Invalid publication staging path.") }
    }
    if let pack = journal.pack {
      guard pack.hasPrefix("pack-"), identity.format.contains(String(pack.dropFirst(5))) else {
        throw WorktreeError.recoveryRequired("Invalid publication pack name.")
      }
    }
    return journal
  }

  func preservationRef(_ record: DerivedProjectRecord, oid: String) -> String {
    "refs/computer-mcp/recovery/" + record.worktree!.branchID.uuidString.lowercased() + "/" + oid
  }

  func publicationStaging(_ journal: WorktreePublicationJournal) throws -> WorktreeDirectory {
    guard let expected = journal.staging,
      expected.path
        == (try publicationDirectory()).url.appendingPathComponent(
          journal.operationID.uuidString.lowercased()
        ).path
    else { throw WorktreeError.recoveryRequired("Publication staging ownership is missing.") }
    let directory = try WorktreeDirectory(URL(fileURLWithPath: expected.path))
    guard directory.identity == expected,
      try io.read("owner.json", in: directory, limit: 4096) == publicationOwner(journal)
    else {
      throw WorktreeError.identityChanged("Publication staging identity changed.")
    }
    return directory
  }

  func publicationOwner(_ journal: WorktreePublicationJournal) -> Data {
    Data(
      (journal.record.projectID + "\n" + journal.operationID.uuidString.lowercased() + "\n"
        + journal.record.worktree!.branchID.uuidString.lowercased() + "\n").utf8)
  }

  func advancePublication(
    _ journal: inout WorktreePublicationJournal, to phase: WorktreePublicationJournal.Phase
  ) throws {
    let previous = try publicationBytes(journal)
    journal.phase = phase
    try savePublication(journal, replacing: previous)
  }
}
