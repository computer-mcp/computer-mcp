import Foundation

struct WorktreeMergeJournal: Codable {
  enum Phase: String, Codable {
    case captured, prepared, checkout, ready, published, ledger, finished, abandoned
  }
  let version: Int
  let operationID: UUID
  let repository: WorktreeRepositoryIdentity
  let record: DerivedProjectRecord
  let expectedBase: String
  let target: String
  let paths: [String]
  var phase: Phase
  var staging: WorktreeDirectoryIdentity?
  var before: WorktreeCheckoutSnapshot?
  var after: WorktreeCheckoutSnapshot?
  var base: String { record.worktree!.base }
}

extension WorktreeRepository {
  func mergeDirectory() throws -> WorktreeDirectory {
    try WorktreeDirectory(storage.journals).child("merges", create: true)
  }

  func mergeBytes(_ journal: WorktreeMergeJournal) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(journal)
  }

  func saveMerge(_ journal: WorktreeMergeJournal, replacing previous: Data?) throws {
    let data = try mergeBytes(journal)
    guard data.count <= git.maxOutputBytes * 8 else {
      throw WorktreeError.busy("Checkout journal exceeds its byte bound.")
    }
    try io.write(
      data, name: journal.record.projectID + ".json", in: mergeDirectory(), replacing: previous)
  }

  func readMerge(_ projectID: String) throws -> WorktreeMergeJournal? {
    guard
      let data = try io.read(
        projectID + ".json", in: mergeDirectory(), limit: git.maxOutputBytes * 8)
    else { return nil }
    let journal = try JSONDecoder().decode(WorktreeMergeJournal.self, from: data)
    try journal.record.validate()
    guard journal.version == 1, journal.repository == identity,
      journal.record.source == source, journal.record.projectID == projectID,
      let registration = journal.record.worktree, registration.base != registration.branch,
      journal.target == registration.lastPublishedOID,
      identity.format.contains(journal.expectedBase), identity.format.contains(journal.target),
      journal.paths == Array(Set(journal.paths)).sorted()
    else {
      throw WorktreeError.recoveryRequired("Invalid merge journal identity.")
    }
    for path in journal.paths { try WorktreeCheckoutSnapshot.requirePath(path) }
    if let stage = journal.staging {
      guard
        stage.path
          == (try mergeDirectory()).url.appendingPathComponent(
            journal.operationID.uuidString.lowercased()
          ).path
      else {
        throw WorktreeError.recoveryRequired("Invalid checkout staging identity.")
      }
    }
    return journal
  }

  func advanceMerge(_ journal: inout WorktreeMergeJournal, to phase: WorktreeMergeJournal.Phase)
    throws
  {
    let old = try mergeBytes(journal)
    journal.phase = phase
    try saveMerge(journal, replacing: old)
  }

  func mergeOwner(_ journal: WorktreeMergeJournal) -> Data {
    Data(
      (journal.record.projectID + "\n" + journal.operationID.uuidString.lowercased() + "\n").utf8)
  }

  func mergeStaging(_ journal: WorktreeMergeJournal) throws -> WorktreeDirectory {
    guard let expected = journal.staging else {
      throw WorktreeError.recoveryRequired("Checkout staging ownership is incomplete.")
    }
    let stage = try WorktreeDirectory(URL(fileURLWithPath: expected.path))
    guard stage.identity == expected,
      try io.read("owner.json", in: stage, limit: 4096) == mergeOwner(journal)
    else {
      throw WorktreeError.recoveryRequired("Checkout staging ownership changed.")
    }
    return stage
  }
}
