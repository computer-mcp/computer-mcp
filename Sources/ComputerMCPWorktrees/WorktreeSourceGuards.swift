import Foundation

struct WorktreeSourceGuardJournal: Codable, Equatable {
  struct Entry: Codable, Equatable {
    let path: String
    var nonce = UUID()
    var parent: WorktreeDirectoryIdentity?
    var marker: WorktreeSourceFileProof?
    var rollingBack = false
  }

  let operationID: UUID
  let common: WorktreeDirectoryIdentity
  var entries: [Entry]
  var cleaning = false

  init(
    operationID: UUID, common: WorktreeDirectoryIdentity, branches: [String], guardingHead: Bool
  ) throws {
    self.operationID = operationID
    self.common = common
    entries = try Self.paths(branches: branches, guardingHead: guardingHead).map {
      Entry(path: $0)
    }
  }

  fileprivate static func paths(branches: [String], guardingHead: Bool) throws -> [String] {
    for branch in branches { try WorktreeSourceMetadata.requireBranch(branch) }
    let spellings = Set(branches.map { Data($0.utf8) })
    guard spellings.count == Set(branches).count else { throw sourceMetadataChanged() }
    return Array(Set(branches + (guardingHead ? ["HEAD"] : [])))
      .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) } + ["packed-refs"]
  }
}

/// Guards belong to a journaled parent operation, not to any Git child it launches.
/// Dropping descriptors never unlinks a guard. The parent must settle or retain its proof.
final class WorktreeSourceGuards {
  private struct Held {
    let location: WorktreeSourceMetadata.Location
    var file: WorktreeSourceMetadata.File
  }

  let metadata: WorktreeSourceMetadata
  let operationID: UUID
  private let repositoryLock: RepositoryLock
  private var held: [String: Held]

  private init(
    metadata: WorktreeSourceMetadata, operationID: UUID, repositoryLock: RepositoryLock,
    held: [String: Held]
  ) {
    self.metadata = metadata
    self.operationID = operationID
    self.repositoryLock = repositoryLock
    self.held = held
  }

  /// The caller proves prior execution quiescence and makes even an unchanged
  /// journal image durable before returning from persist.
  static func acquire(
    _ journal: inout WorktreeSourceGuardJournal, metadata: WorktreeSourceMetadata,
    repositoryLock: RepositoryLock,
    branches: [String], guardingHead: Bool,
    deletionReceipts: [String: WorktreeSourceFileProof] = [:],
    persist: (WorktreeSourceGuardJournal) throws -> Void
  ) throws -> WorktreeSourceGuards {
    try repositoryLock.verify()
    try validate(journal, metadata: metadata, branches: branches, guardingHead: guardingHead)
    guard !journal.cleaning, Set(deletionReceipts.keys).isSubset(of: Set(branches))
    else { throw sourceMetadataChanged() }
    try persist(journal)
    var held: [String: Held] = [:]
    var rollback: [Int] = []
    func save(_ entry: WorktreeSourceGuardJournal.Entry, at index: Int) throws {
      var next = journal
      next.entries[index] = entry
      try persist(next)
      journal = next
    }
    do {
      for index in journal.entries.indices {
        try Task.checkCancellation()
        try repositoryLock.verify()
        var entry = journal.entries[index]
        if entry.rollingBack {
          try removeOwned(entry, metadata: metadata, operationID: journal.operationID)
          entry = .init(path: entry.path)
          try save(entry, at: index)
        }
        guard let base = try metadata.location(entry.path, createParents: entry.parent == nil)
        else { throw sourceMetadataChanged() }
        if entry.parent == nil {
          entry.parent = base.parent.identity
          try save(entry, at: index)
        }
        guard entry.parent == base.parent.identity else { throw sourceMetadataChanged() }
        let lock = try base.renamed(base.leaf + ".lock")
        let temporary = try base.renamed(temporaryName(entry))
        let marker = markerBytes(entry, operationID: journal.operationID)
        let receipt = deletionReceipts[entry.path]
        if entry.marker == nil {
          guard try !temporary.parent.hasEntry(temporary.leaf), receipt == nil
          else { throw sourceMetadataChanged() }
          guard try !lock.parent.hasEntry(lock.leaf) else { throw Contention() }
          let prepared = try metadata.create(marker, at: temporary, mode: 0o600)
          entry.marker = prepared.proof
          try save(entry, at: index)
        }
        guard let expected = entry.marker else { throw sourceMetadataChanged() }
        if try temporary.parent.hasEntry(temporary.leaf) {
          guard let prepared = try metadata.read(temporary, limit: 4096),
            prepared.proof == expected, prepared.contents == marker
          else { throw sourceMetadataChanged() }
          rollback.append(index)
          guard try !lock.parent.hasEntry(lock.leaf) else { throw Contention() }
          try prepared.synchronize(at: temporary, using: metadata.io)
          do {
            try metadata.move(prepared, from: temporary, to: lock)
          } catch {
            if try temporary.hasIdentity(expected), try lock.parent.hasEntry(lock.leaf) {
              throw Contention()
            }
            throw error
          }
          held[entry.path] = Held(location: lock, file: prepared)
        } else {
          guard let installed = try metadata.read(lock, limit: 4096),
            installed.proof == expected || installed.proof == receipt,
            installed.proof != expected || installed.contents == marker
          else { throw sourceMetadataChanged() }
          try installed.synchronize(at: lock, using: metadata.io)
          held[entry.path] = Held(location: lock, file: installed)
        }
      }
    } catch is Contention {
      if !rollback.isEmpty {
        var next = journal
        for index in rollback { next.entries[index].rollingBack = true }
        try persist(next)
        journal = next
      }
      for index in rollback.reversed() {
        try repositoryLock.verify()
        let entry = journal.entries[index]
        try removeOwned(entry, metadata: metadata, operationID: journal.operationID)
        try save(.init(path: entry.path), at: index)
      }
      throw WorktreeError.busy("A source reference is locked by another Git operation.")
    }
    let guards = Self(
      metadata: metadata, operationID: journal.operationID, repositoryLock: repositoryLock,
      held: held)
    try guards.verify()
    return guards
  }

  func verify(covering paths: [String] = []) throws {
    try repositoryLock.verify()
    guard !held.isEmpty,
      paths.allSatisfy({ path in
        held.keys.contains { $0.utf8.elementsEqual(path.utf8) }
      })
    else {
      throw sourceMetadataChanged()
    }
    for entry in held.values {
      try entry.file.verify(at: entry.location)
      guard
        try metadata.read(entry.location, limit: entry.file.proof.bytes)?.proof == entry.file.proof
      else { throw sourceMetadataChanged() }
    }
  }

  func guardProof(for path: String) throws -> WorktreeSourceFileProof {
    try verify(covering: [path])
    guard let entry = held[path] else { throw sourceMetadataChanged() }
    return entry.file.proof
  }

  func synchronizeGuard(for path: String) throws {
    try verify(covering: [path])
    guard let entry = held[path] else { throw sourceMetadataChanged() }
    try entry.file.synchronize(at: entry.location, using: metadata.io)
  }

  func moveBranchIntoReceipt(
    _ branch: String, armed: WorktreeSourceFileProof, originalGuard: WorktreeSourceFileProof
  ) throws {
    try verify(covering: [branch, "packed-refs"])
    guard let location = try metadata.location(branch), let entry = held[branch],
      entry.file.proof == originalGuard, entry.location.parent.identity == location.parent.identity,
      let canonical = try metadata.read(location, limit: 1024), canonical.proof == armed
    else { throw sourceMetadataChanged() }
    try metadata.move(canonical, from: location, to: entry.location, replacing: entry.file)
    held[branch]?.file = canonical
    try verify()
  }

  func release(
    _ journal: inout WorktreeSourceGuardJournal, branches: [String], guardingHead: Bool,
    deletionReceipts: [String: WorktreeSourceFileProof] = [:],
    persist: (WorktreeSourceGuardJournal) throws -> Void
  ) throws {
    try verify()
    try Self.validate(journal, metadata: metadata, branches: branches, guardingHead: guardingHead)
    guard journal.operationID == operationID, !journal.cleaning,
      Set(deletionReceipts.keys).isSubset(of: Set(branches))
    else { throw sourceMetadataChanged() }
    for (branch, receipt) in deletionReceipts {
      guard try guardProof(for: branch) == receipt else { throw sourceMetadataChanged() }
    }
    var next = journal
    next.cleaning = true
    try persist(next)
    journal = next
    try Self.finishCleanup(
      journal, metadata: metadata, repositoryLock: repositoryLock, branches: branches,
      guardingHead: guardingHead,
      deletionReceipts: deletionReceipts)
    held.removeAll()
  }

  /// A durable cleanup intent authorizes only removal of the exact recorded files.
  static func finishCleanup(
    _ journal: WorktreeSourceGuardJournal, metadata: WorktreeSourceMetadata,
    repositoryLock: RepositoryLock,
    branches: [String], guardingHead: Bool,
    deletionReceipts: [String: WorktreeSourceFileProof] = [:]
  ) throws {
    try validate(journal, metadata: metadata, branches: branches, guardingHead: guardingHead)
    guard journal.cleaning, Set(deletionReceipts.keys).isSubset(of: Set(branches))
    else { throw sourceMetadataChanged() }
    for entry in journal.entries.reversed() {
      try repositoryLock.verify()
      try removeOwned(
        entry, metadata: metadata, operationID: journal.operationID,
        receipt: deletionReceipts[entry.path])
    }
  }

  private struct Contention: Error {}

  private static func validate(
    _ journal: WorktreeSourceGuardJournal, metadata: WorktreeSourceMetadata,
    branches: [String], guardingHead: Bool
  ) throws {
    let expected = try WorktreeSourceGuardJournal.paths(
      branches: branches, guardingHead: guardingHead)
    guard journal.common == metadata.common.identity, journal.entries.count == expected.count,
      zip(journal.entries, expected).allSatisfy({ $0.path.utf8.elementsEqual($1.utf8) }),
      Set(journal.entries.map(\.nonce)).count == journal.entries.count
    else { throw sourceMetadataChanged() }
  }

  private static func removeOwned(
    _ entry: WorktreeSourceGuardJournal.Entry, metadata: WorktreeSourceMetadata,
    operationID: UUID, receipt: WorktreeSourceFileProof? = nil
  ) throws {
    guard let expected = entry.marker, let base = try metadata.location(entry.path),
      base.parent.identity == entry.parent
    else { throw sourceMetadataChanged() }
    let marker = markerBytes(entry, operationID: operationID)
    let lock = try base.renamed(base.leaf + ".lock")
    let temporary = try base.renamed(temporaryName(entry))
    if let candidate = try metadata.read(temporary, limit: 4096) {
      guard candidate.proof == expected, candidate.contents == marker else {
        throw sourceMetadataChanged()
      }
      try metadata.remove(candidate, at: temporary)
    }
    let ownsLock =
      try lock.hasIdentity(expected) || receipt.map { try lock.hasIdentity($0) } ?? false
    if ownsLock {
      guard let existing = try metadata.read(lock, limit: 4096) else {
        throw sourceMetadataChanged()
      }
      if existing.proof == receipt || (existing.proof == expected && existing.contents == marker) {
        try metadata.remove(existing, at: lock)
      } else {
        throw sourceMetadataChanged()
      }
    } else if !entry.rollingBack, try lock.parent.hasEntry(lock.leaf) {
      throw sourceMetadataChanged()
    }
    try base.synchronize(using: metadata.io)
  }

  private static func temporaryName(_ entry: WorktreeSourceGuardJournal.Entry) -> String {
    ".computer-mcp-guard-" + entry.nonce.uuidString.lowercased()
  }

  private static func markerBytes(_ entry: WorktreeSourceGuardJournal.Entry, operationID: UUID)
    -> Data
  {
    Data(
      ("computer-mcp source guard v1\n" + operationID.uuidString.lowercased() + "\n"
        + entry.nonce.uuidString.lowercased() + "\n" + entry.path + "\n").utf8)
  }
}
