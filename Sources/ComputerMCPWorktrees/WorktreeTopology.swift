import Foundation

/// Filesystem evidence only: this value grants neither execution admission nor
/// sandbox access. Those owners must obtain their lease and revalidate it.
package final class VerifiedWorktreeTopology {
  package let projectID: String
  package let generation: UUID
  package let root: WorktreeDirectory
  package let gitDirectory: WorktreeDirectory
  package let objects: WorktreeDirectory
  let common: WorktreeDirectory
  let contentParent: WorktreeDirectory
  let repositoryParent: WorktreeDirectory
  let runtime: WorktreeDirectory

  init(_ journal: WorktreeCreationJournal) throws {
    guard case .host(_, let generation) = journal.record.provenance,
      let root = journal.root, let gitDirectory = journal.gitDirectory,
      let objects = journal.objects, let contentParent = journal.contentParent,
      let repositoryParent = journal.repositoryParent, let runtime = journal.runtime
    else {
      throw WorktreeError.recoveryRequired("Incomplete topology evidence.")
    }
    func open(_ identity: WorktreeDirectoryIdentity) throws -> WorktreeDirectory {
      let directory = try WorktreeDirectory(URL(fileURLWithPath: identity.path))
      guard directory.identity == identity else {
        throw WorktreeError.identityChanged("Worktree topology changed.")
      }
      return directory
    }
    projectID = journal.id
    self.generation = generation
    self.root = try open(root)
    self.gitDirectory = try open(gitDirectory)
    self.objects = try open(objects)
    self.common = try open(journal.repository.common)
    self.contentParent = try open(contentParent)
    self.repositoryParent = try open(repositoryParent)
    self.runtime = try open(runtime)
  }

  package func verifyDirectories() throws {
    for directory in [
      root, gitDirectory, objects, common, contentParent, repositoryParent, runtime,
    ] {
      try directory.verify()
    }
  }
}

extension WorktreeRepository {
  package func topology(projectID: String) throws -> VerifiedWorktreeTopology {
    try withLock { _ in
      guard let record = try store.records().first(where: { $0.projectID == projectID }),
        case .host = record.provenance, record.source == source, record.state == .active,
        let journal = try readJournal(projectID), journal.phase == .active,
        try matchesActiveRecord(journal, record)
      else {
        throw WorktreeError.recoveryRequired("No active host topology for this registration.")
      }
      return try verifyTopology(journal, repository: identity, source: source)
    }
  }

  func activeRecord(_ journal: WorktreeCreationJournal) throws -> DerivedProjectRecord {
    var record = journal.record
    record.state = .active
    record.revision = 2
    record.worktree = try WorktreeRegistration(journal)
    return record
  }

  func matchesActiveRecord(_ journal: WorktreeCreationJournal, _ record: DerivedProjectRecord)
    throws -> Bool
  {
    var expected = try activeRecord(journal)
    guard record.revision >= expected.revision else { return false }
    expected.revision = record.revision
    expected.worktree?.publishedOID = record.worktree?.publishedOID
    expected.worktree?.mergedOID = record.worktree?.mergedOID
    return expected == record
  }

  func verifyTopology(
    _ journal: WorktreeCreationJournal, repository: WorktreeRepositoryIdentity,
    source: DerivedProjectSource, validateHead: Bool = true
  ) throws -> VerifiedWorktreeTopology {
    try verifyDirectories(journal, repository: repository, source: source)
    let topology = try VerifiedWorktreeTopology(journal)
    try verifyPrivateControls(topology, repository: repository)
    if validateHead {
      _ = try WorktreePrivateMetadata(
        directory: topology.gitDirectory, format: repository.format,
        io: io, limit: git.maxOutputBytes * 8,
        deadline: .now.advanced(by: creationLimits.duration))
    }
    try topology.verifyDirectories()
    return topology
  }

  func foreignGitDirectory(root: URL, repository: WorktreeRepositoryIdentity) throws
    -> WorktreeDirectory
  {
    let directory = try WorktreeDirectory(root)
    guard let data = try io.read(".git", in: directory, limit: 16_384),
      let pointer = String(data: data, encoding: .utf8), pointer.hasPrefix("gitdir: "),
      pointer.hasSuffix("\n")
    else {
      throw WorktreeError.identityChanged("Invalid worktree Git indirection.")
    }
    let path = String(pointer.dropFirst(8).dropLast())
    guard !path.contains("\n"), !path.contains("\r"), !path.contains("\0"), path.hasPrefix("/")
    else {
      throw WorktreeError.identityChanged("Unsupported worktree Git indirection.")
    }
    let common = URL(fileURLWithPath: repository.common.path)
    let administrative = try WorktreeDirectory(URL(fileURLWithPath: path))
    guard
      administrative.url.deletingLastPathComponent().path
        == common.appendingPathComponent("worktrees").path,
      let backlinkData = try io.read("gitdir", in: administrative, limit: 16_384),
      let backlink = String(data: backlinkData, encoding: .utf8), backlink.hasSuffix("\n"),
      URL(fileURLWithPath: String(backlink.dropLast())).standardizedFileURL.path
        == root.appendingPathComponent(".git").path,
      let commonData = try io.read("commondir", in: administrative, limit: 16_384),
      let relative = String(data: commonData, encoding: .utf8), relative == "../..\n"
    else {
      throw WorktreeError.identityChanged("Worktree backlinks do not match this repository.")
    }
    try directory.verify()
    return administrative
  }

  func status(_ topology: VerifiedWorktreeTopology) throws -> Data {
    try withPrivateRead(topology) { directory in
      try git.run(
        [
          "--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all",
          "--ignored=matching",
        ], at: topology.root.url, gitDirectory: directory.url
      ).output
    }
  }
}
