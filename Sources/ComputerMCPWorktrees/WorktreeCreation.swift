import Foundation

package struct CreatedWorktree: Sendable {
  package let projectID: String
  package let path: URL
  package let branch: String
  package let base: String
  package let warnings: [String]
}

struct WorktreeCreationJournal: Codable {
  enum Phase: String, Codable {
    case reserved, directories, checkout, branch, active, removing, removed
  }
  let version: Int
  let operationID: UUID
  let repository: WorktreeRepositoryIdentity
  let record: DerivedProjectRecord
  let branchID: UUID
  let branch: String
  let base: String
  let baseOID: String
  var phase: Phase
  var contentParent: WorktreeDirectoryIdentity?
  var root: WorktreeDirectoryIdentity?
  var repositoryParent: WorktreeDirectoryIdentity?
  var objects: WorktreeDirectoryIdentity?
  var runtime: WorktreeDirectoryIdentity?
  var gitDirectory: WorktreeDirectoryIdentity?
  var baseHistory: WorktreeRefHistory?
  var warnings: [String] = []

  var id: String { record.projectID }
  var result: CreatedWorktree {
    .init(
      projectID: id, path: URL(fileURLWithPath: record.root),
      branch: String(branch.dropFirst("refs/heads/".count)),
      base: String(base.dropFirst("refs/heads/".count)), warnings: warnings)
  }
}

extension WorktreeRepository {
  package func create(name: String, branch: String? = nil, base: String? = nil) throws
    -> CreatedWorktree
  {
    guard name.utf8.count <= 48,
      name.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) == name
        .startIndex..<name.endIndex
    else {
      throw WorktreeError.invalidRequest(
        "Name must contain lowercase letters, digits and single hyphens, at most 48 characters.")
    }
    return try withLock { lock in
      try recoverLocked(lock)
      let branchRef = try requireBranch(branch ?? "worktree/" + name)
      guard try revision(branchRef) == nil,
        try !hasPendingBranchDeletion(branchRef),
        try !store.protectedBranches().contains(where: {
          $0.repository == identity.common && $0.branch == branchRef
        }),
        try command(["symbolic-ref", "--quiet", branchRef], accepting: [0, 1]).exitCode == 1
      else {
        throw WorktreeError.invalidRequest("The requested branch already exists.")
      }
      let baseRef: String
      if let base {
        baseRef = try requireBranch(base)
      } else {
        let current = try command(["symbolic-ref", "--quiet", "HEAD"], accepting: [0, 1])
        guard current.exitCode == 0 else {
          throw WorktreeError.invalidRequest(
            "An explicit base branch is required for a detached main checkout.")
        }
        baseRef = String(decoding: current.output, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard baseRef.hasPrefix("refs/heads/") else {
          throw WorktreeError.invalidRequest("Invalid main branch.")
        }
      }
      guard let oid = try revision(baseRef),
        try command(["symbolic-ref", "--quiet", baseRef], accepting: [0, 1]).exitCode == 1
      else {
        throw WorktreeError.invalidRequest("Base must be an existing direct branch with a commit.")
      }
      let worktreeID = UUID()
      let component = worktreeID.uuidString.lowercased()
      let repositoryName = URL(fileURLWithPath: identity.main.path).lastPathComponent
      guard !repositoryName.isEmpty, !repositoryName.contains("\n"), !repositoryName.contains("\r")
      else {
        throw WorktreeError.unsupportedRepository("Unsupported repository directory name.")
      }
      let record = DerivedProjectRecord(
        projectID: "worktree-" + component, source: source,
        root: storage.content.appendingPathComponent(component).appendingPathComponent(
          repositoryName
        ).path,
        provenance: .host(worktreeID: worktreeID, storageGeneration: UUID()), state: .creating)
      var journal = WorktreeCreationJournal(
        version: 2, operationID: worktreeID,
        repository: identity, record: record, branchID: UUID(), branch: branchRef,
        base: baseRef, baseOID: oid, phase: .reserved)
      let tree = try command(["ls-tree", "-rz", oid]).output
      if tree.split(separator: 0).contains(where: { $0.starts(with: Data("160000 ".utf8)) }) {
        journal.warnings.append(
          "Submodules are not initialized; submodule update is unavailable in this worktree.")
      }
      let paths = try command(["ls-tree", "-rz", "--name-only", oid]).output
      let attributes = try command(
        ["check-attr", "-z", "--source=" + oid, "--stdin", "filter"], input: paths
      ).output
      if attributes.split(separator: 0).enumerated().contains(where: {
        $0.offset % 3 == 2 && $0.element == Data("lfs".utf8)
      }) {
        journal.warnings.append(
          "Git LFS content remains as pointer files; no LFS filter is configured.")
      }
      journal.baseHistory = try captureRefHistory(baseRef, expectedOID: oid)
      try lock.verify()
      try storage.prepare()
      try saveJournal(journal, replacing: nil)
      try store.commit(record, expecting: nil, protecting: nil)
      // These empty directories are exclusively created, then their identities are
      // durable before Git is allowed to populate any of them.
      let content = try WorktreeDirectory(storage.content).child(
        component, create: true, exclusive: true)
      let root = try content.child(repositoryName, create: true, exclusive: true)
      let repositoryParent = try WorktreeDirectory(storage.repositories).child(
        component, create: true, exclusive: true)
      let privateRepository = try repositoryParent.child(
        "repository", create: true, exclusive: true)
      let objects = try privateRepository.child("objects", create: true, exclusive: true)
      let runtime = try WorktreeDirectory(storage.runtime).child(
        component, create: true, exclusive: true)
      for parent in [content, repositoryParent, runtime] {
        try io.write(ownerMarker(journal), name: "owner.json", in: parent, replacing: nil)
      }
      let previous = try encoded(journal)
      journal.contentParent = content.identity
      journal.root = root.identity
      journal.repositoryParent = repositoryParent.identity
      journal.objects = objects.identity
      journal.gitDirectory = privateRepository.identity
      journal.runtime = runtime.identity
      journal.phase = .directories
      try saveJournal(journal, replacing: previous)
      return try completeCreation(&journal, lock: lock)
    }
  }

  /// Recovery is explicit and fail-closed. Unknown directories, changed refs or a
  /// corrupt journal are retained; they cannot be adopted or deleted by pathname.
  package func recover() throws {
    try withLock { try recoverLocked($0) }
  }

  func recoverLocked(_ lock: RepositoryLock) throws {
    guard FileManager.default.fileExists(atPath: storage.journals.path) else { return }
    let directory = try WorktreeDirectory(storage.journals)
    let files = try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
    guard files.count <= git.maxOutputBytes else {
      throw WorktreeError.recoveryRequired("Journal inventory exceeds its bound.")
    }
    for name in files.sorted() where name.hasSuffix(".json") {
      let id = String(name.dropLast(5))
      guard var journal = try readJournal(id) else {
        throw WorktreeError.recoveryRequired("Journal disappeared.")
      }
      // A host may manage several repositories with the same durable store.
      if journal.repository.common != identity.common { continue }
      guard journal.record.source == source else {
        throw WorktreeError.recoveryRequired(
          "Source registration changed; retained worktree requires reconciliation.")
      }
      if [.active, .removing, .removed].contains(journal.phase) { continue }
      _ = try completeCreation(&journal, lock: lock)
    }
  }

  func completeCreation(_ journal: inout WorktreeCreationJournal, lock: RepositoryLock)
    throws -> CreatedWorktree
  {
    try checkAuthority()
    try validateJournal(journal)
    let names = try command(["ls-tree", "-rz", "--name-only", journal.baseOID]).output
    guard let text = String(data: names, encoding: .utf8) else {
      throw WorktreeError.unsupportedRepository("Checkout filenames must be valid UTF-8.")
    }
    for path in text.split(separator: "\0").map(String.init) {
      try WorktreeCheckoutSnapshot.requirePath(path)
      try authorizeCreationPath(URL(fileURLWithPath: source.root).appendingPathComponent(path))
    }
    _ = try requireBranch(String(journal.branch.dropFirst("refs/heads/".count)))
    _ = try requireBranch(String(journal.base.dropFirst("refs/heads/".count)))
    guard journal.phase != .reserved else {
      throw WorktreeError.recoveryRequired("Creation has no durable directory ownership evidence.")
    }
    try verifyDirectories(journal, repository: identity, source: source)
    try lock.verify()
    guard try revision(journal.base) == journal.baseOID,
      try command(["symbolic-ref", "--quiet", journal.base], accepting: [0, 1]).exitCode == 1
    else {
      throw WorktreeError.recoveryRequired("The captured base branch changed during creation.")
    }
    if journal.phase == .directories {
      try initializePrivateRepository(journal)
      let previous = try encoded(journal)
      journal.phase = .checkout
      try saveJournal(journal, replacing: previous)
    }
    if journal.phase == .checkout {
      let root = URL(fileURLWithPath: journal.record.root)
      let topology = try verifyTopology(journal, repository: identity, source: source)
      let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
      if files == [".git"] {
        try lock.verify()
        _ = try git.run(
          ["read-tree", "--reset", "-u", journal.baseOID], at: root,
          gitDirectory: topology.gitDirectory.url)
      }
      guard try status(topology).isEmpty,
        try privateMetadata(topology).head
          == journal.baseOID
      else {
        throw WorktreeError.recoveryRequired("Interrupted checkout is not the captured clean tree.")
      }
      try lock.verify()
      if try revision(journal.branch) == nil {
        let transaction =
          "start\ncreate \(journal.branch) \(journal.baseOID)\nverify \(journal.base) \(journal.baseOID)\nprepare\ncommit\n"
        _ = try command(
          ["update-ref", "--no-deref", "--create-reflog", "-m", refMessage(journal), "--stdin"],
          input: Data(transaction.utf8))
      }
      try verifyCreatedBranch(journal)
      let previous = try encoded(journal)
      journal.phase = .branch
      try saveJournal(journal, replacing: previous)
    }
    if journal.phase == .branch {
      _ = try verifyTopology(journal, repository: identity, source: source)
      try verifyCreatedBranch(journal)
      try lock.verify()
      let active = try activeRecord(journal)
      guard let existing = try store.records().first(where: { $0.projectID == journal.id }) else {
        throw WorktreeError.recoveryRequired("The creation reservation is unavailable.")
      }
      if existing != active {
        guard existing == journal.record else { throw DerivedProjectStoreError.revisionConflict }
        try store.commit(
          active, expecting: 1,
          protecting: .init(
            repository: identity.common, branchID: journal.branchID,
            branch: journal.branch, base: journal.base, baseOID: journal.baseOID,
            publishedOID: journal.baseOID, worktreeID: journal.operationID,
            baseHistory: journal.baseHistory))
      }
      let previous = try encoded(journal)
      journal.phase = .active
      try saveJournal(journal, replacing: previous)
    }
    return journal.result
  }

  private func refMessage(_ journal: WorktreeCreationJournal) -> String {
    "computer-mcp worktree " + journal.operationID.uuidString.lowercased()
  }

  private func verifyCreatedBranch(_ journal: WorktreeCreationJournal) throws {
    guard try revision(journal.branch) == journal.baseOID,
      try command(["symbolic-ref", "--quiet", journal.branch], accepting: [0, 1]).exitCode == 1
    else {
      throw WorktreeError.recoveryRequired("The reserved worktree branch changed.")
    }
    // Expected absence and an operation-specific reflog receipt distinguish an
    // interrupted successful transaction from an unrelated same-tip branch.
    let log = try command(["reflog", "show", "-1", "--format=%H%x00%gs", journal.branch]).output
    let expected = journal.baseOID + "\0" + refMessage(journal) + "\n"
    guard log == Data(expected.utf8) else {
      throw WorktreeError.recoveryRequired("Branch creation ownership cannot be proved.")
    }
  }

  func encoded(_ journal: WorktreeCreationJournal) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(journal)
  }

  func saveJournal(_ journal: WorktreeCreationJournal, replacing previous: Data?) throws {
    try io.write(
      encoded(journal), name: journal.id + ".json", in: WorktreeDirectory(storage.journals),
      replacing: previous)
  }

  func readJournal(_ id: String) throws -> WorktreeCreationJournal? {
    guard FileManager.default.fileExists(atPath: storage.journals.path) else { return nil }
    guard
      let data = try io.read(id + ".json", in: WorktreeDirectory(storage.journals), limit: 131_072)
    else { return nil }
    let journal = try JSONDecoder().decode(WorktreeCreationJournal.self, from: data)
    guard journal.id == id else {
      throw WorktreeError.recoveryRequired("Journal identity does not match its filename.")
    }
    try validateJournal(journal)
    return journal
  }

  private func validateJournal(_ journal: WorktreeCreationJournal) throws {
    try journal.record.validate()
    let id = journal.operationID.uuidString.lowercased()
    let refs = [journal.branch, journal.base]
    guard
      refs.allSatisfy({
        $0.hasPrefix("refs/heads/") && $0.utf8.count <= 1035
          && !$0.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 })
      }),
      journal.version == 2, journal.id == "worktree-" + id,
      case .host(let worktreeID, _) = journal.record.provenance, worktreeID == journal.operationID,
      journal.record.state == .creating, journal.record.revision == 1,
      journal.repository.format.contains(journal.baseOID),
      journal.branch.hasPrefix("refs/heads/"), journal.base.hasPrefix("refs/heads/"),
      journal.record.root
        == storage.content.appendingPathComponent(id)
        .appendingPathComponent(
          URL(fileURLWithPath: journal.repository.main.path).lastPathComponent
        ).path
    else { throw WorktreeError.recoveryRequired("Invalid worktree creation journal.") }
  }

  func ownerMarker(_ journal: WorktreeCreationJournal) -> Data {
    guard case .host(_, let generation) = journal.record.provenance else { return Data() }
    return Data((journal.id + "\n" + generation.uuidString + "\n").utf8)
  }

  func verifyDirectories(
    _ journal: WorktreeCreationJournal, repository: WorktreeRepositoryIdentity,
    source: DerivedProjectSource
  ) throws {
    guard journal.repository == repository, journal.record.source == source,
      let content = journal.contentParent, let root = journal.root,
      let repositoryParent = journal.repositoryParent, let objects = journal.objects,
      let privateRepository = journal.gitDirectory,
      let runtime = journal.runtime
    else {
      throw WorktreeError.recoveryRequired("Directory ownership evidence is incomplete.")
    }
    let component = journal.operationID.uuidString.lowercased()
    guard content.path == storage.content.appendingPathComponent(component).path,
      root.path == journal.record.root,
      repositoryParent.path == storage.repositories.appendingPathComponent(component).path,
      privateRepository.path
        == URL(fileURLWithPath: repositoryParent.path).appendingPathComponent("repository").path,
      objects.path
        == URL(fileURLWithPath: repositoryParent.path).appendingPathComponent("repository/objects")
        .path,
      runtime.path == storage.runtime.appendingPathComponent(component).path
    else {
      throw WorktreeError.recoveryRequired("Owned directories differ from configured storage.")
    }
    try repository.verify()
    for expected in [content, root, repositoryParent, privateRepository, objects, runtime] {
      guard try WorktreeDirectory(URL(fileURLWithPath: expected.path)).identity == expected else {
        throw WorktreeError.identityChanged("Worktree directory was moved or replaced.")
      }
    }
    for parent in [content, repositoryParent, runtime] {
      guard
        try io.read(
          "owner.json", in: WorktreeDirectory(URL(fileURLWithPath: parent.path)), limit: 1024)
          == ownerMarker(journal)
      else {
        throw WorktreeError.recoveryRequired("Storage generation ownership changed.")
      }
    }
  }
}
