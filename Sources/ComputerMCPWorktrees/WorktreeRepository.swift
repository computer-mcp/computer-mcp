import Foundation

package enum WorktreeObjectFormat: String, Codable, Sendable {
  case sha1, sha256
  var hexCount: Int { self == .sha1 ? 40 : 64 }

  func contains(_ oid: String) -> Bool {
    oid.utf8.count == hexCount
      && oid.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
}

package struct WorktreeRepositoryIdentity: Codable, Equatable, Sendable {
  let source: WorktreeDirectoryIdentity
  let main: WorktreeDirectoryIdentity
  let common: WorktreeDirectoryIdentity
  let objects: WorktreeDirectoryIdentity
  let format: WorktreeObjectFormat

  init(source: DerivedProjectSource, git: WorktreeGit) throws {
    guard !source.root.unicodeScalars.contains(where: { $0.value < 32 }) else {
      throw WorktreeError.unsupportedRepository("Repository path contains control characters.")
    }
    let root = URL(fileURLWithPath: source.root).standardizedFileURL.resolvingSymlinksInPath()
    guard root.path == source.root,
      try git.text(["rev-parse", "--is-bare-repository"], at: root) == "false",
      try URL(fileURLWithPath: git.text(["rev-parse", "--show-toplevel"], at: root))
        .standardizedFileURL.resolvingSymlinksInPath().path == root.path
    else {
      throw WorktreeError.unsupportedRepository("Source must be a non-bare repository top level.")
    }
    let commonPath = try git.text(
      ["rev-parse", "--path-format=absolute", "--git-common-dir"], at: root)
    guard !commonPath.unicodeScalars.contains(where: { $0.value < 32 }) else {
      throw WorktreeError.unsupportedRepository("Repository path contains control characters.")
    }
    let common = try WorktreeDirectory(URL(fileURLWithPath: commonPath).resolvingSymlinksInPath())
    let entries = try WorktreeInventoryEntry.parse(
      git.run(["worktree", "list", "--porcelain", "-z"], at: root).output)
    guard let mainPath = entries.first?.path, entries.first?.bare == false else {
      throw WorktreeError.unsupportedRepository("A main checkout is required.")
    }
    let main = try WorktreeDirectory(URL(fileURLWithPath: mainPath).resolvingSymlinksInPath())
    guard
      try URL(fileURLWithPath: git.text(["rev-parse", "--absolute-git-dir"], at: main.url))
        .standardizedFileURL.resolvingSymlinksInPath().path == common.url.path,
      let format = try WorktreeObjectFormat(
        rawValue: git.text(["rev-parse", "--show-object-format=storage"], at: root))
    else {
      throw WorktreeError.unsupportedRepository("Unsupported repository layout or object format.")
    }
    self.source = try WorktreeDirectory(root).identity
    self.main = main.identity
    self.common = common.identity
    objects = try common.child("objects").identity
    self.format = format
  }

  func verify() throws {
    for identity in [source, main, common, objects] {
      guard try WorktreeDirectory(URL(fileURLWithPath: identity.path)).identity == identity else {
        throw WorktreeError.identityChanged("Repository directory identity changed.")
      }
    }
  }
}

/// Internal lifecycle API. The adapter owns live source authorization; no tool or
/// program execution route is installed by constructing this service.
package final class WorktreeRepository {
  let source: DerivedProjectSource
  let store: any DerivedProjectStore
  let storage: WorktreeStorage
  let git: WorktreeGit
  let identity: WorktreeRepositoryIdentity
  let projectRoots: [URL]
  let io: WorktreeJournalIO
  let lockTimeout: Duration
  let owner: RepositoryLock.Owner

  package init(
    source: DerivedProjectSource, store: any DerivedProjectStore, storage: WorktreeStorage,
    executor: any WorktreeGitExecuting, registeredProjectRoots: [URL],
    timeoutMilliseconds: Int, maxOutputBytes: Int, lockTimeout: Duration,
    owner: RepositoryLock.Owner = .init(), journalIO: WorktreeJournalIO = .init()
  ) throws {
    self.source = source
    self.store = store
    self.storage = storage
    self.projectRoots = registeredProjectRoots
    self.io = journalIO
    self.lockTimeout = lockTimeout
    self.owner = owner
    guard timeoutMilliseconds > 0, maxOutputBytes > 0, maxOutputBytes < Int.max / 8 else {
      throw WorktreeError.unsafeConfiguration("Git command bounds must be positive.")
    }
    // Git uses the denied global configuration and never executes programs,
    // even before a private home can be created.
    git = WorktreeGit(
      executor: executor, home: storage.journals,
      timeoutMilliseconds: timeoutMilliseconds, maxOutputBytes: maxOutputBytes)
    identity = try WorktreeRepositoryIdentity(source: source, git: git)
    try requireSupportedLayout(identity)
    try withLock { _ in }
  }

  func validateStorage(validateHead: Bool = true) throws -> [WorktreeCreationJournal] {
    // Storage is shared across repositories; only each record's live, verified
    // topology can establish an exception for its exact content root.
    var owned: Set<String> = []
    var activated: [WorktreeCreationJournal] = []
    for record in try store.records() {
      guard case .host = record.provenance,
        record.state == .active, let journal = try readJournal(record.projectID),
        [.branch, .active].contains(journal.phase), try matchesActiveRecord(journal, record)
      else { continue }
      do {
        let repository =
          record.source == source
          ? identity : try WorktreeRepositoryIdentity(source: record.source, git: git)
        // Foreign validation only reads; acquiring its lock while holding this
        // repository's lock would invert ordering for concurrent host operations.
        try requireSupportedLayout(repository)
        _ = try verifyTopology(
          journal, repository: repository, source: record.source, validateHead: validateHead)
        owned.insert(record.root)
        if record.source == source, journal.phase == .branch { activated.append(journal) }
      } catch {
        // Unverified content remains subject to the ordinary overlap denial.
        continue
      }
    }
    try storage.validate(
      projectRoots: projectRoots + [URL(fileURLWithPath: source.root)], ownedRoots: owned)
    return activated
  }

  func withLock<T>(validateHead: Bool = true, _ action: (RepositoryLock) throws -> T) throws -> T {
    let lock = try RepositoryLock(
      commonDirectory: URL(fileURLWithPath: identity.common.path),
      owner: owner, timeout: lockTimeout)
    defer { lock.release() }
    try identity.verify()
    try lock.verify()
    try requireSupportedLayout(identity)
    // Ledger activation and journal publication are separate durable writes.
    // Verify all storage ownership before reconciling this repository's receipt;
    // an active ledger row alone must never authorize writes into overlapping roots.
    for var journal in try validateStorage(validateHead: validateHead) {
      _ = try completeCreation(&journal, lock: lock)
    }
    return try action(lock)
  }

  func requireSupportedLayout(_ repository: WorktreeRepositoryIdentity) throws {
    try repository.verify()
    for suffix in ["objects/info/alternates", "info/grafts", "shallow"] {
      let path = URL(fileURLWithPath: repository.common.path).appendingPathComponent(suffix)
      if (try? FileManager.default.attributesOfItem(atPath: path.path)) != nil {
        throw WorktreeError.unsupportedRepository(
          "Repository alternates, grafts and shallow history are unsupported.")
      }
    }
    let root = URL(fileURLWithPath: repository.source.path)
    let names = try git.configurationNames(at: root).lowercased().split(separator: "\0")
    guard !names.contains(where: { $0 == "extensions.partialclone" || $0.hasSuffix(".promisor") }),
      try git.text(["rev-parse", "--is-shallow-repository"], at: root) == "false",
      try git.text(["config", "--get", "core.sparsecheckout"], at: root, accepting: [0, 1])
        != "true",
      ["", "files"].contains(
        try git.text(["config", "--get", "extensions.refstorage"], at: root, accepting: [0, 1])),
      try git.text(["for-each-ref", "--format=%(refname)", "refs/replace/"], at: root).isEmpty
    else {
      throw WorktreeError.unsupportedRepository(
        "Worktrees require a complete repository with ordinary refs and checkout.")
    }
  }

  func command(_ arguments: [String], input: Data = Data(), accepting: Set<Int32> = [0]) throws
    -> WorktreeGitResult
  {
    try identity.verify()
    return try git.run(
      arguments, at: URL(fileURLWithPath: identity.main.path),
      gitDirectory: URL(fileURLWithPath: identity.common.path), input: input, accepting: accepting)
  }

  func revision(_ ref: String) throws -> String? {
    let result = try command(
      ["rev-parse", "--verify", "--quiet", "--end-of-options", ref + "^{commit}"],
      accepting: [0, 1])
    guard result.exitCode == 0 else { return nil }
    let value = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .newlines)
    guard identity.format.contains(value) else {
      throw WorktreeError.identityChanged("Invalid object ID.")
    }
    return value
  }

  func requireBranch(_ name: String) throws -> String {
    guard !name.isEmpty, name.utf8.count <= 1024, name != "HEAD", !name.hasPrefix("-"),
      !name.contains("\0"), !name.contains("\n"), !name.contains("\r")
    else {
      throw WorktreeError.invalidRequest("Invalid branch name.")
    }
    let ref = "refs/heads/" + name
    guard try command(["check-ref-format", ref], accepting: [0, 1]).exitCode == 0 else {
      throw WorktreeError.invalidRequest("Invalid branch name.")
    }
    return ref
  }
}

struct WorktreeGit {
  let executor: any WorktreeGitExecuting
  let home: URL
  let timeoutMilliseconds: Int
  let maxOutputBytes: Int

  func configurationNames(at root: URL, gitDirectory: URL? = nil) throws -> String {
    let result = try execute(
      ["config", "--null", "--name-only", "--list", "--no-includes"],
      at: root, gitDirectory: gitDirectory,
      environment: HostGitConfiguration.environment(home: home))
    guard result.exitCode == 0 else {
      throw WorktreeError.commandFailed("Cannot inspect Git configuration.")
    }
    return String(decoding: result.output, as: UTF8.self)
  }

  func run(
    _ arguments: [String], at root: URL, gitDirectory: URL? = nil,
    objects: URL? = nil, sharedObjects: URL? = nil, input: Data = Data(),
    accepting: Set<Int32> = [0]
  ) throws -> WorktreeGitResult {
    let names = try configurationNames(at: root, gitDirectory: gitDirectory)
    let overrides = try HostGitConfiguration.overrides(for: names)
    var environment = HostGitConfiguration.environment(home: home)
    if let objects, let sharedObjects {
      environment["GIT_OBJECT_DIRECTORY"] = objects.path
      environment["GIT_ALTERNATE_OBJECT_DIRECTORIES"] =
        "\""
        + sharedObjects.path
        .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        + "\""
    }
    let result = try execute(
      overrides + arguments, at: root, gitDirectory: gitDirectory,
      environment: environment, input: input)
    guard accepting.contains(result.exitCode) else {
      throw WorktreeError.commandFailed(
        "Git operation failed (exit \(result.exitCode)): \(arguments.first ?? "unknown").")
    }
    return result
  }

  func text(_ arguments: [String], at root: URL, accepting: Set<Int32> = [0]) throws -> String {
    String(decoding: try run(arguments, at: root, accepting: accepting).output, as: UTF8.self)
      .trimmingCharacters(in: .newlines)
  }

  private func execute(
    _ arguments: [String], at root: URL, gitDirectory: URL?,
    environment: [String: String], input: Data = Data()
  ) throws -> WorktreeGitResult {
    let binding = gitDirectory.map { ["--git-dir=\($0.path)", "--work-tree=\(root.path)"] } ?? []
    let result = try executor.execute(
      .init(
        arguments: binding + ["--no-replace-objects"] + HostGitConfiguration.arguments
          + ["-c", "core.attributesFile=/dev/null", "-c", "core.excludesFile=/dev/null"]
          + arguments,
        directory: root, environment: environment, input: input,
        timeoutMilliseconds: timeoutMilliseconds, maxOutputBytes: maxOutputBytes))
    guard result.output.count <= maxOutputBytes, result.error.count <= maxOutputBytes else {
      throw WorktreeError.commandFailed("Git output exceeded its bound.")
    }
    return result
  }
}

extension WorktreeGit {
  func transaction(
    _ input: String, at root: URL, gitDirectory: URL, dereference: Bool = false,
    message: String, _ body: () throws -> Void
  ) throws {
    let names = try configurationNames(at: root, gitDirectory: gitDirectory)
    let overrides = try HostGitConfiguration.overrides(for: names)
    let arguments =
      ["--git-dir=\(gitDirectory.path)", "--work-tree=\(root.path)", "--no-replace-objects"]
      + HostGitConfiguration.arguments + overrides
      + ["update-ref"] + (dereference ? [] : ["--no-deref"])
      + ["--create-reflog", "-m", message, "--stdin"]
    try executor.withPreparedTransaction(
      .init(
        arguments: arguments, directory: root,
        environment: HostGitConfiguration.environment(home: home), input: Data(input.utf8),
        timeoutMilliseconds: timeoutMilliseconds, maxOutputBytes: maxOutputBytes), body)
  }
}
