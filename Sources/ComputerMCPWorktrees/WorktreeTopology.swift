import Foundation

/// Filesystem evidence only: this value grants neither execution admission nor
/// sandbox access. Those owners must obtain their lease and revalidate it.
package final class VerifiedWorktreeTopology {
  package let projectID: String
  package let generation: UUID
  package let root: WorktreeDirectory
  package let gitDirectory: WorktreeDirectory
  package let objects: WorktreeDirectory
  package let sharedObjects: WorktreeDirectory
  let common: WorktreeDirectory
  let contentParent: WorktreeDirectory
  let objectParent: WorktreeDirectory
  let runtime: WorktreeDirectory

  init(_ journal: WorktreeCreationJournal) throws {
    guard case .host(_, let generation) = journal.record.provenance,
      let root = journal.root, let gitDirectory = journal.gitDirectory,
      let objects = journal.objects, let contentParent = journal.contentParent,
      let objectParent = journal.objectParent, let runtime = journal.runtime
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
    self.sharedObjects = try open(journal.repository.objects)
    self.common = try open(journal.repository.common)
    self.contentParent = try open(contentParent)
    self.objectParent = try open(objectParent)
    self.runtime = try open(runtime)
  }

  package func verifyDirectories() throws {
    for directory in [
      root, gitDirectory, objects, sharedObjects, common, contentParent, objectParent, runtime,
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
        try activeRecord(journal) == record
      else {
        throw WorktreeError.recoveryRequired("No active host topology for this registration.")
      }
      return try verifyTopology(journal)
    }
  }

  func activeRecord(_ journal: WorktreeCreationJournal) throws -> DerivedProjectRecord {
    var record = journal.record
    record.state = .active
    record.revision = 2
    record.worktree = try WorktreeRegistration(journal)
    return record
  }

  func verifyTopology(_ journal: WorktreeCreationJournal) throws -> VerifiedWorktreeTopology {
    try verifyDirectories(journal)
    let topology = try VerifiedWorktreeTopology(journal)
    let administrative = try administrativeDirectory(root: topology.root.url)
    guard administrative.identity == topology.gitDirectory.identity else {
      throw WorktreeError.identityChanged("Worktree administration was replaced.")
    }
    // A writable alternate file could extend the readable object universe. Only
    // the host-selected shared alternate is allowed in this private view.
    if FileManager.default.fileExists(
      atPath: topology.objects.url.appendingPathComponent("info/alternates").path)
    {
      throw WorktreeError.unsafeConfiguration("Private alternate files are unsupported.")
    }
    let head = try directHead(
      root: topology.root.url, administrative: administrative.url, objects: topology.objects.url)
    let entries = try WorktreeInventoryEntry.parse(
      command(["worktree", "list", "--porcelain", "-z"]).output)
    guard let entry = entries.first(where: { $0.path == topology.root.url.path }),
      entry.detached, entry.head == head, !entry.bare, !entry.prunable
    else {
      throw WorktreeError.identityChanged("Worktree registration and private HEAD disagree.")
    }
    try topology.verifyDirectories()
    return topology
  }

  func administrativeDirectory(root: URL) throws -> WorktreeDirectory {
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
    let common = URL(fileURLWithPath: identity.common.path)
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

  func directHead(root: URL, administrative: URL, objects: URL) throws -> String {
    let headDirectory = try WorktreeDirectory(administrative)
    guard let head = try io.read("HEAD", in: headDirectory, limit: 1024),
      head
        == Data(
          (String(decoding: head, as: UTF8.self).trimmingCharacters(in: .newlines) + "\n").utf8),
      identity.format.contains(
        String(decoding: head, as: UTF8.self).trimmingCharacters(in: .newlines))
    else {
      throw WorktreeError.identityChanged("Host worktree HEAD must be a direct regular ref file.")
    }
    let shared = URL(fileURLWithPath: identity.objects.path)
    guard
      try git.run(
        ["symbolic-ref", "--quiet", "HEAD"], at: root, gitDirectory: administrative,
        objects: objects, sharedObjects: shared, accepting: [0, 1]
      ).exitCode == 1
    else {
      throw WorktreeError.identityChanged("Host worktree HEAD must remain detached.")
    }
    let result = try git.run(
      ["rev-parse", "--verify", "HEAD^{commit}"], at: root,
      gitDirectory: administrative, objects: objects, sharedObjects: shared)
    let oid = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .newlines)
    guard identity.format.contains(oid) else {
      throw WorktreeError.identityChanged("Invalid private HEAD.")
    }
    return oid
  }

  func status(_ topology: VerifiedWorktreeTopology) throws -> Data {
    try topology.verifyDirectories()
    return try git.run(
      [
        "--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all",
        "--ignored=matching",
      ],
      at: topology.root.url, gitDirectory: topology.gitDirectory.url,
      objects: topology.objects.url, sharedObjects: topology.sharedObjects.url
    ).output
  }
}
