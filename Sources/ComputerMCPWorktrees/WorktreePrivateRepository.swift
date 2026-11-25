import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Descriptor-captured metadata is data, never Git configuration or executable input.
struct WorktreePrivateMetadata {
  let head: String
  let refs: [String: String]
  let reflogRoots: [String: [String]]
  let roots: [String]
  let index: Data?
  let fingerprint: String?

  init(
    directory: WorktreeDirectory, format: WorktreeObjectFormat, io: WorktreeJournalIO,
    limit: Int, deadline: ContinuousClock.Instant, recoveryRootLimit: Int? = nil
  ) throws {
    var remaining = limit
    var entriesRemaining = min(limit, 250_000)
    let verifyCapture = recoveryRootLimit != nil
    var observations: [String: FileStamp] = [:]
    var absent: Set<String> = []
    var digests: [String: String] = [:]
    var allRoots: Set<String> = []
    var logsByPath: [String: [String]] = [:]
    let zero = String(repeating: "0", count: format.hexCount)
    func check() throws {
      try Task.checkCancellation()
      guard ContinuousClock.now < deadline else {
        throw WorktreeError.busy("Private metadata capture exceeded its deadline.")
      }
    }
    func read(_ name: String, in parent: WorktreeDirectory) throws -> Data? {
      try check()
      let path =
        parent.url.path == directory.url.path
        ? name : String(parent.url.path.dropFirst(directory.url.path.count + 1)) + "/" + name
      let before = try verifyCapture ? FileStamp.read(parent.descriptor, name) : nil
      let data: Data?
      do {
        data = try io.read(name, in: parent, limit: remaining)
      } catch {
        guard verifyCapture else { throw error }
        switch error {
        case is CancellationError: throw error
        case WorktreeError.identityChanged, is POSIXError:
          throw WorktreeError.busy("Private Git metadata was unavailable during capture.")
        default: throw error
        }
      }
      remaining -= data?.count ?? 0
      if verifyCapture {
        guard try before == FileStamp.read(parent.descriptor, name),
          (before == nil) == (data == nil)
        else { throw WorktreeError.busy("Private Git metadata changed during capture.") }
        if let before, let data {
          observations[path] = before
          digests[path] = WorktreeObjectSnapshot.digest(data)
        } else {
          absent.insert(path)
        }
      }
      return data
    }
    func addRoot(_ oid: String) throws {
      guard oid != zero else { return }
      allRoots.insert(oid)
      if let recoveryRootLimit, allRoots.count > recoveryRootLimit {
        throw WorktreeError.busy("Private root inventory exceeds its object bound.")
      }
    }
    func observeDirectory(_ path: String, _ parent: WorktreeDirectory) throws {
      guard verifyCapture else { return }
      guard let stamp = try FileStamp.read(parent.descriptor, ".") else {
        throw WorktreeError.busy("Private metadata directory disappeared.")
      }
      observations[path] = stamp
    }
    func text(_ data: Data) throws -> String {
      guard let value = String(data: data, encoding: .utf8), value.hasSuffix("\n") else {
        throw WorktreeError.busy("Private reference data is incomplete.")
      }
      return String(value.dropLast())
    }
    try observeDirectory(".", directory)
    if verifyCapture {
      for lock in ["HEAD.lock", "packed-refs.lock"] {
        guard try !directory.hasEntry(lock) else {
          throw WorktreeError.busy("Private reference update is in progress.")
        }
        absent.insert(lock)
      }
    }
    guard let headBytes = try read("HEAD", in: directory) else {
      throw WorktreeError.busy("Missing private HEAD.")
    }
    var values: [String: String] = [:]
    if let bytes = try read("packed-refs", in: directory) {
      for line in try text(bytes).split(separator: "\n") {
        try check()
        if line.hasPrefix("#") || line.hasPrefix("^") { continue }
        let fields = line.split(separator: " ")
        guard fields.count == 2, format.contains(String(fields[0])) else {
          throw WorktreeError.busy("Malformed packed references.")
        }
        try Self.requireRef(String(fields[1]))
        guard values[String(fields[1])] == nil else {
          throw WorktreeError.busy("Duplicate packed reference.")
        }
        values[String(fields[1])] = String(fields[0])
      }
    }
    func walk(_ parent: WorktreeDirectory, prefix: String, logs: Bool) throws {
      guard prefix.utf8.count <= 1024 else {
        throw WorktreeError.busy("Private metadata nesting exceeds its bound.")
      }
      try check()
      try observeDirectory(String(parent.url.path.dropFirst(directory.url.path.count + 1)), parent)
      for name in try parent.entries(limit: entriesRemaining) {
        try check()
        guard entriesRemaining > 0 else {
          throw WorktreeError.busy("Private metadata inventory exceeds its bound.")
        }
        entriesRemaining -= 1
        var status = stat()
        guard fstatat(parent.descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
          throw WorktreeError.busy("Private references changed during capture.")
        }
        let path = prefix + name
        if verifyCapture, name.hasSuffix(".lock") {
          throw WorktreeError.busy("Private reference update is in progress.")
        }
        if status.st_mode & S_IFMT == S_IFDIR {
          try walk(parent.child(name), prefix: path + "/", logs: logs)
        } else {
          guard let bytes = try read(name, in: parent) else {
            throw WorktreeError.busy("Private reference disappeared.")
          }
          if logs {
            var endpoints: Set<String> = []
            for line in (bytes.isEmpty ? "" : try text(bytes)).split(separator: "\n") {
              try check()
              let fields = line.split(separator: " ", maxSplits: 2)
              guard fields.count == 3, fields.prefix(2).allSatisfy({ format.contains(String($0)) })
              else { throw WorktreeError.busy("Malformed private reflog.") }
              for field in fields.prefix(2) where field != zero {
                let oid = String(field)
                try addRoot(oid)
                if verifyCapture { endpoints.insert(oid) }
              }
            }
            if verifyCapture { logsByPath[path] = endpoints.sorted() }
          } else {
            try Self.requireRef(path)
            values[path] = try text(bytes)
          }
        }
      }
    }
    if try directory.hasEntry("refs") {
      try walk(directory.child("refs"), prefix: "refs/", logs: false)
    } else if verifyCapture {
      absent.insert("refs")
    }
    func resolve(_ value: String, seen: Set<String> = []) throws -> String {
      if format.contains(value), !verifyCapture || value != zero { return value }
      guard value.hasPrefix("ref: ") else { throw WorktreeError.busy("Invalid private reference.") }
      let name = String(value.dropFirst(5))
      try Self.requireRef(name)
      guard seen.count < 8, !seen.contains(name), let next = values[name] else {
        throw WorktreeError.busy("Unresolved private reference.")
      }
      return try resolve(next, seen: seen.union([name]))
    }
    head = try resolve(text(headBytes))
    var resolved: [String: String] = [:]
    for (name, value) in values {
      try check()
      // Replacement objects are never consulted, including during closure verification.
      guard !name.hasPrefix("refs/replace/") else {
        throw WorktreeError.unsafeConfiguration("Private replacement references are unsupported.")
      }
      let oid = try resolve(value)
      resolved[name] = oid
      try addRoot(oid)
    }
    if try directory.hasEntry("logs") {
      try walk(directory.child("logs"), prefix: "", logs: true)
    } else if verifyCapture {
      absent.insert("logs")
    }
    try addRoot(head)
    self.refs = resolved
    reflogRoots = logsByPath
    self.roots = allRoots.sorted()
    index = try verifyCapture ? nil : read("index", in: directory)
    if verifyCapture {
      // The index contributes no roots, but must still be canonical owned metadata.
      if let stamp = try FileStamp.read(directory.descriptor, "index") {
        guard stamp.mode & S_IFMT == S_IFREG, stamp.links == 1,
          stamp.size >= 0, stamp.size <= remaining
        else { throw WorktreeError.identityChanged("Invalid private index identity.") }
        observations["index"] = stamp
      } else {
        absent.insert("index")
      }
      for (path, stamp) in observations {
        try check()
        guard try FileStamp.read(directory.descriptor, path) == stamp else {
          throw WorktreeError.busy("Private Git metadata changed during capture.")
        }
      }
      for path in absent {
        try check()
        guard try FileStamp.read(directory.descriptor, path) == nil else {
          throw WorktreeError.busy("Private Git metadata changed during capture.")
        }
      }
      fingerprint = WorktreeObjectSnapshot.digest(try recoveryJSON(digests))
    } else {
      fingerprint = nil
    }
    try directory.verify()
    try check()
  }

  private struct FileStamp: Equatable {
    let device: Int64
    let inode: UInt64
    let size: Int64
    let mode: mode_t
    let links: UInt64
    let modified: Int64
    let modifiedNanos: Int64
    let changed: Int64
    let changedNanos: Int64

    static func read(_ descriptor: Int32, _ path: String) throws -> Self? {
      var status = stat()
      guard fstatat(descriptor, path, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
        if errno == ENOENT { return nil }
        throw WorktreeError.busy("Private metadata identity could not be read.")
      }
      #if canImport(Darwin)
        let modified = status.st_mtimespec
        let changed = status.st_ctimespec
      #else
        let modified = status.st_mtim
        let changed = status.st_ctim
      #endif
      return Self(
        device: Int64(status.st_dev), inode: UInt64(status.st_ino), size: Int64(status.st_size),
        mode: status.st_mode, links: UInt64(status.st_nlink), modified: Int64(modified.tv_sec),
        modifiedNanos: Int64(modified.tv_nsec), changed: Int64(changed.tv_sec),
        changedNanos: Int64(changed.tv_nsec))
    }
  }

  static func requireRef(_ ref: String) throws {
    guard ref.hasPrefix("refs/"), ref.utf8.count <= 1024, !ref.contains(".."),
      !ref.contains("@{"), !ref.hasSuffix("."),
      !ref.unicodeScalars.contains(where: {
        $0.value <= 32 || $0.value == 127 || "~^:?*[\\".unicodeScalars.contains($0)
      }),
      ref.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
        !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".lock")
      })
    else { throw WorktreeError.busy("Invalid private reference name.") }
  }
}

extension WorktreeDirectory {
  func hasEntry(_ name: String) throws -> Bool {
    try Self.requireName(name)
    try verify()
    var status = stat()
    if fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 { return true }
    guard errno == ENOENT else { throw Self.posixError() }
    return false
  }
}

extension WorktreeRepository {
  func privateConfiguration(root: URL, repository: WorktreeRepositoryIdentity) -> Data {
    func quoted(_ value: String) -> String {
      "\""
        + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
          of: "\"", with: "\\\"") + "\""
    }
    let format = repository.format == .sha256 ? "[extensions]\n\tobjectFormat = sha256\n" : ""
    return Data(
      ("[core]\n\trepositoryformatversion = \(repository.format == .sha256 ? 1 : 0)\n\tbare = false\n\tlogAllRefUpdates = always\n\tworktree = \(quoted(root.path))\n"
        + format
        + "[remote \"origin\"]\n\turl = \(quoted(repository.source.path))\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n")
        .utf8)
  }

  func verifyPrivateControls(
    _ topology: VerifiedWorktreeTopology, repository: WorktreeRepositoryIdentity
  ) throws {
    let directory = topology.gitDirectory
    guard
      try io.read(".git", in: topology.root, limit: 16_384)
        == Data(("gitdir: " + directory.url.path + "\n").utf8)
    else { throw WorktreeError.identityChanged("Private Git control files changed.") }
    try verifyPrivateControls(
      directory: directory, objects: topology.objects, root: topology.root.url,
      repository: repository)
  }

  func verifyPrivateControls(
    directory: WorktreeDirectory, objects: WorktreeDirectory, root: URL,
    repository: WorktreeRepositoryIdentity
  ) throws {
    guard
      try io.read("config", in: directory, limit: 32_768)
        == privateConfiguration(root: root, repository: repository),
      try directory.child("hooks").entries(limit: 1).isEmpty
    else { throw WorktreeError.identityChanged("Private Git control files changed.") }
    for name in ["commondir", "config.worktree", "shallow"] where try directory.hasEntry(name) {
      throw WorktreeError.unsafeConfiguration("Unsupported private Git control file: " + name)
    }
    if try directory.child("info").hasEntry("grafts") {
      throw WorktreeError.unsafeConfiguration("Private grafts are unsupported.")
    }
    do {
      let info = try objects.child("info")
      for name in ["alternates", "http-alternates"] where try info.hasEntry(name) {
        throw WorktreeError.unsafeConfiguration("Private alternates are unsupported.")
      }
    }
  }

  func privateMetadata(_ topology: VerifiedWorktreeTopology) throws -> WorktreePrivateMetadata {
    try verifyPrivateControls(topology, repository: identity)
    return try WorktreePrivateMetadata(
      directory: topology.gitDirectory, format: identity.format, io: io,
      limit: git.maxOutputBytes * 8, deadline: .now.advanced(by: creationLimits.duration))
  }
}

extension WorktreeRepository {
  func initializePrivateRepository(_ journal: WorktreeCreationJournal) throws {
    guard let repositoryIdentity = journal.gitDirectory, let objectIdentity = journal.objects,
      let rootIdentity = journal.root
    else { throw WorktreeError.recoveryRequired("Missing private repository reservation.") }
    let directory = try WorktreeDirectory(URL(fileURLWithPath: repositoryIdentity.path))
    let objects = try WorktreeDirectory(URL(fileURLWithPath: objectIdentity.path))
    let root = try WorktreeDirectory(URL(fileURLWithPath: rootIdentity.path))
    let files = try root.entries(limit: 2)
    let pointer = Data(("gitdir: " + directory.url.path + "\n").utf8)
    guard
      try files.isEmpty
        || (files == [".git"] && io.read(".git", in: root, limit: 16_384) == pointer)
    else {
      throw WorktreeError.recoveryRequired("Unrecorded checkout content is retained.")
    }
    // This journal phase has never admitted a client. Its descriptor-owned Git
    // directories are construction scratch, including an interrupted copy.
    try directory.clearCreationScratch(preserving: "objects", io: io)
    try objects.clearCreationScratch(io: io)
    do {
      var budget = try WorktreeObjectBudget(creationLimits)
      let snapshot = WorktreeObjectSnapshot(io: io, format: identity.format)
      let copied = try snapshot.copy(
        from: WorktreeDirectory(URL(fileURLWithPath: identity.objects.path)),
        to: objects, budget: &budget, clone: cloneCreationObjects)
      try snapshot.validateRaw(copied, in: objects, budget: &budget)
      _ = try git.run(
        [
          "init", "--bare", "--template=", "--object-format=" + identity.format.rawValue,
          directory.url.path,
        ], at: root.url)
      let config = try io.read("config", in: directory, limit: 32_768)
      try io.write(
        privateConfiguration(root: root.url, repository: identity), name: "config", in: directory,
        replacing: config)
      _ = try directory.child("hooks", create: true)
      _ = try directory.child("info", create: true)
      _ = try objects.child("info", create: true)
      // The initial local fetch copies data, not configuration or linked refs.
      // Read source ref values once and initialize only those verified in the copy.
      let output = try command([
        "for-each-ref", "--format=%(objectname) %(refname)", "refs/heads/", "refs/tags/",
      ]).output
      var refs: [String: String] = [:]
      for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
        let fields = line.split(separator: " ")
        guard fields.count == 2, identity.format.contains(String(fields[0])) else {
          throw WorktreeError.busy("Source refs changed during creation.")
        }
        let name = String(fields[1])
        try WorktreePrivateMetadata.requireRef(name)
        refs[name.hasPrefix("refs/heads/") ? "refs/remotes/origin/" + name.dropFirst(11) : name] =
          String(fields[0])
      }
      let roots = Array(Set([journal.baseOID] + refs.values)).sorted()
      try budget.check()
      _ = try git.run(
        ["fsck", "--full", "--strict", "--no-reflogs", "--no-dangling"] + roots,
        at: root.url, gitDirectory: directory.url)
      var input = "start\n"
      for (name, oid) in refs.sorted(by: { $0.key < $1.key }) { input += "create \(name) \(oid)\n" }
      input += "prepare\ncommit\n"
      _ = try git.run(
        ["update-ref", "--no-deref", "--stdin"], at: root.url, gitDirectory: directory.url,
        input: Data(input.utf8))
      try io.write(
        Data((journal.baseOID + "\n").utf8), name: "HEAD", in: directory,
        replacing: io.read("HEAD", in: directory, limit: 1024))
      if files.isEmpty { try io.write(pointer, name: ".git", in: root, replacing: nil) }
      try budget.check()
    } catch {
      try directory.clearCreationScratch(preserving: "objects", io: io)
      try objects.clearCreationScratch(io: io)
      if error is CancellationError { throw error }
      throw WorktreeError.busy(
        "Private repository copy was incomplete or exceeded its creation budget; retry creation recovery."
      )
    }
  }

  /// Git parses only verified host-owned objects and descriptor-captured metadata.
  /// Nothing writes into the program-owned repository after activation.
  func withPrivateRead<T>(
    _ topology: VerifiedWorktreeTopology,
    _ body: (WorktreeDirectory) throws -> T
  ) throws -> T {
    try topology.verifyDirectories()
    let metadata = try privateMetadata(topology)
    let parent = try WorktreeDirectory(storage.journals).child("reads", create: true)
    let stage = try parent.child(UUID().uuidString.lowercased(), create: true, exclusive: true)
    defer { try? parent.removeOwnedTree(stage.identity, io: .init()) }
    let objects = try stage.child("objects", create: true, exclusive: true)
    var budget = try WorktreeObjectBudget(creationLimits)
    let snapshot = WorktreeObjectSnapshot(io: io, format: identity.format)
    let files = try snapshot.copy(from: topology.objects, to: objects, budget: &budget)
    try snapshot.validateRaw(files, in: objects, budget: &budget)
    _ = try git.run(
      [
        "init", "--bare", "--template=", "--object-format=" + identity.format.rawValue,
        stage.url.path,
      ], at: parent.url)
    _ = try git.run(
      ["fsck", "--full", "--strict", "--no-reflogs", "--no-dangling"] + metadata.roots,
      at: topology.root.url, gitDirectory: stage.url)
    try io.write(
      Data((metadata.head + "\n").utf8), name: "HEAD", in: stage,
      replacing: io.read("HEAD", in: stage, limit: 1024))
    if let index = metadata.index {
      // Only entry identities cross the trust boundary. Stat data, validity bits
      // and cache extensions can conceal changes and never authorize a clean tree.
      try io.write(index, name: "captured-index", in: stage, replacing: nil)
      let entries = try git.run(
        ["ls-files", "--stage", "-z"], at: topology.root.url, gitDirectory: stage.url,
        index: stage.url.appendingPathComponent("captured-index")
      ).output
      _ = try git.run(
        ["update-index", "-z", "--index-info"], at: topology.root.url, gitDirectory: stage.url,
        input: entries)
    }
    try budget.check()
    return try body(stage)
  }
}

extension WorktreeDirectory {
  func clearCreationScratch(preserving name: String? = nil, io: WorktreeJournalIO) throws {
    for entry in try entries(limit: 1_000_000) where entry != name {
      var status = stat()
      guard fstatat(descriptor, entry, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw Self.posixError()
      }
      if status.st_mode & S_IFMT == S_IFDIR {
        let directory = try child(entry)
        try removeOwnedTree(directory.identity, io: io)
      } else {
        try verify()
        guard unlinkat(descriptor, entry, 0) == 0 else { throw Self.posixError() }
      }
    }
    try synchronize()
  }
}
