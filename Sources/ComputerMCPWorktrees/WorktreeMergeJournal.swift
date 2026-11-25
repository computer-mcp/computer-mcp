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
  var indexLease: WorktreeRecoveryStageFile?
  var indexReleasing: Bool?
  var sourceGuards: WorktreeSourceGuardJournal?
  var sourceCommit: WorktreeSourceMerge?
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

  func readMerge(_ projectID: String, account: (Int) throws -> Void = { _ in }) throws
    -> WorktreeMergeJournal?
  {
    guard let root = try WorktreeDirectory.openIfPresent(storage.journals),
      let directory = try root.childIfPresent("merges")
    else { return nil }
    guard
      let data = try io.read(
        projectID + ".json", in: directory, limit: git.maxOutputBytes * 8)
    else { return nil }
    try account(data.count)
    let journal = try JSONDecoder().decode(WorktreeMergeJournal.self, from: data)
    try journal.record.validate()
    guard [1, 2].contains(journal.version), journal.repository == identity,
      journal.record.source == source, journal.record.projectID == projectID,
      let registration = journal.record.worktree, registration.base != registration.branch,
      journal.target == registration.lastPublishedOID,
      journal.sourceGuards.map({ $0.operationID == journal.operationID }) ?? true,
      journal.sourceCommit.map({
        $0.operationID == journal.operationID && $0.base == registration.base
          && $0.managed == registration.branch && $0.expected == journal.expectedBase
          && $0.target == journal.target
      }) ?? true,
      identity.format.contains(journal.expectedBase), identity.format.contains(journal.target),
      journal.paths == Array(Set(journal.paths)).sorted()
    else {
      throw WorktreeError.recoveryRequired("Invalid merge journal identity.")
    }
    if journal.version == 2, [.checkout, .ready, .published, .ledger].contains(journal.phase) {
      guard journal.indexLease != nil, journal.indexReleasing == nil,
        journal.sourceGuards?.cleaning == false, journal.sourceCommit != nil, journal.before != nil,
        journal.phase == .checkout || journal.after != nil
      else { throw WorktreeError.recoveryRequired("Guarded merge journal is incomplete.") }
    }
    for path in journal.paths { try WorktreeCheckoutSnapshot.requirePath(path) }
    if let stage = journal.staging {
      guard
        stage.path
          == directory.url.appendingPathComponent(
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

  func synchronizeMerge(_ journal: WorktreeMergeJournal) throws {
    try io.synchronize(
      journal.record.projectID + ".json", in: mergeDirectory(), expecting: mergeBytes(journal))
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
