import Foundation

/// Durable host topology and branch identity. The ledger owns active registration;
/// the creation journal is its expected-input recovery evidence.
package struct WorktreeRegistration: Codable, Equatable, Sendable {
  let repository: WorktreeRepositoryIdentity
  let branchID: UUID
  let branch: String
  let base: String
  let baseOID: String
  let baseHistory: WorktreeRefHistory?
  let root: WorktreeDirectoryIdentity
  let gitDirectory: WorktreeDirectoryIdentity
  let contentParent: WorktreeDirectoryIdentity
  let objects: WorktreeDirectoryIdentity
  let objectParent: WorktreeDirectoryIdentity
  let runtime: WorktreeDirectoryIdentity
  var publishedOID: String?
  var mergedOID: String?

  package var lastPublishedOID: String { publishedOID ?? baseOID }
  package var lastMergedOID: String? { mergedOID }

  init(_ journal: WorktreeCreationJournal) throws {
    guard let root = journal.root, let gitDirectory = journal.gitDirectory,
      let contentParent = journal.contentParent, let objects = journal.objects,
      let objectParent = journal.objectParent, let runtime = journal.runtime
    else {
      throw WorktreeError.recoveryRequired("Cannot activate incomplete worktree topology.")
    }
    repository = journal.repository
    branchID = journal.branchID
    branch = journal.branch
    base = journal.base
    baseOID = journal.baseOID
    baseHistory = journal.baseHistory
    self.root = root
    self.gitDirectory = gitDirectory
    self.contentParent = contentParent
    self.objects = objects
    self.objectParent = objectParent
    self.runtime = runtime
  }

  /// Content classification is separate from permission and writable Git admission.
  /// The source, exclusive parent and content directory must retain their recorded identity.
  package func verifyContent() throws {
    guard URL(fileURLWithPath: root.path).deletingLastPathComponent().path == contentParent.path
    else {
      throw DerivedProjectStoreError.invalidRecord
    }
    for expected in [repository.source, contentParent, root] {
      let directory = try WorktreeDirectory(URL(fileURLWithPath: expected.path))
      guard directory.identity == expected else {
        throw WorktreeError.identityChanged("Worktree content registration changed.")
      }
      try directory.verify()
    }
  }

  func validate(record: DerivedProjectRecord) throws {
    guard case .host = record.provenance, root.path == record.root,
      repository.source.path == record.source.root,
      repository.format.contains(baseOID),
      publishedOID.map(repository.format.contains) ?? true,
      mergedOID.map(repository.format.contains) ?? true,
      [branch, base].allSatisfy({
        $0.hasPrefix("refs/heads/") && $0.utf8.count <= 1035
          && !$0.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 })
      })
    else {
      throw DerivedProjectStoreError.invalidRecord
    }
  }
}
