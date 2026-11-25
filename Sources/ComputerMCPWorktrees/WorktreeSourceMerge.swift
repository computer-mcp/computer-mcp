import Foundation

/// The merge journal owns the checkout/index fingerprints and the index lease.
/// This substate owns the two reflog writes and the single base-ref commit.
struct WorktreeSourceMerge: Codable, Equatable {
  struct Reflog: Codable, Equatable {
    let prefix: WorktreeSourceLogPrefix
    var write: WorktreeSourceReferenceWrite

    init(
      path: String, location: WorktreeSourceMetadata.Location?,
      before: WorktreeSourceMetadata.File?, entry: Data
    ) throws {
      let bytes = before?.contents ?? Data()
      guard bytes.isEmpty || bytes.last == 10 else { throw sourceMetadataChanged() }
      prefix = WorktreeSourceLogPrefix(bytes)
      write = try .init(path: path, at: location, before: before?.proof, content: bytes + entry)
    }
  }

  let operationID: UUID
  let base: String
  let managed: String
  let expected: String
  let target: String
  let head: WorktreeSourceFileProof
  let packed: WorktreeSourceFileProof?
  let entry: Data?
  var headLog: Reflog?
  var baseLog: Reflog?
  var ref: WorktreeSourceReferenceWrite?

  init(
    base: String, managed: String, expected: String, target: String,
    message: String, committer: String?, guards: WorktreeSourceGuards
  ) throws {
    let metadata = guards.metadata
    guard base != managed, metadata.validOID(expected), metadata.validOID(target)
    else { throw sourceMetadataChanged() }
    try guards.verify(covering: ["HEAD", base, managed, "packed-refs"])
    let current = try metadata.direct(base)
    guard current.oid == expected, try metadata.direct(managed).oid == target,
      let symbolic = try metadata.read("HEAD", limit: 4096),
      symbolic.contents == Data(("ref: " + base + "\n").utf8)
    else { throw sourceMetadataChanged() }
    operationID = guards.operationID
    self.base = base
    self.managed = managed
    self.expected = expected
    self.target = target
    head = symbolic.proof
    packed = current.packed?.proof
    if expected == target {
      entry = nil
      return
    }
    guard let committer, validWorktreeReflogIdentity(committer[...]), !message.isEmpty,
      committer.utf8.count <= 4096, message.utf8.count <= 4096,
      !message.utf8.contains(where: { $0 < 32 }),
      let loose = try metadata.location(base)
    else { throw sourceMetadataChanged() }
    let entry = Data((expected + " " + target + " " + committer + "\t" + message + "\n").utf8)
    self.entry = entry
    // Existing update-ref explicitly uses --create-reflog for this operation.
    let headPath = "logs/HEAD"
    let basePath = "logs/" + base
    let headLocation = try metadata.location(headPath)
    let baseLocation = try metadata.location(basePath)
    headLog = try Reflog(
      path: headPath, location: headLocation,
      before: headLocation.flatMap { try metadata.read($0) }, entry: entry)
    baseLog = try Reflog(
      path: basePath, location: baseLocation,
      before: baseLocation.flatMap { try metadata.read($0) }, entry: entry)
    ref = try .init(
      path: base, at: loose, before: current.loose?.proof, content: Data((target + "\n").utf8))
  }

  /// Revalidation covers live authority, I, the derived revision, and the exact
  /// synchronized checkout/index. The caller seals merge only after this returns.
  mutating func completeSource(
    guards: WorktreeSourceGuards, revalidate: () throws -> Void,
    persist: (WorktreeSourceMerge) throws -> Void
  ) throws {
    let metadata = guards.metadata
    guard operationID == guards.operationID, base != managed,
      metadata.validOID(expected), metadata.validOID(target)
    else { throw sourceMetadataChanged() }
    try guards.verify(covering: ["HEAD", base, managed, "packed-refs"])
    try verifySource(metadata)
    try revalidate()
    try persist(self)
    if expected == target {
      guard entry == nil, headLog == nil, baseLog == nil, ref == nil else {
        throw sourceMetadataChanged()
      }
      let source = try metadata.direct(base)
      let path = source.loose == nil ? "packed-refs" : base
      guard let file = source.loose ?? source.packed, let location = try metadata.location(path)
      else { throw sourceMetadataChanged() }
      try file.synchronize(at: location, using: metadata.io)
    } else {
      guard let entry, var headLog, var baseLog, var ref,
        headLog.write.path == "logs/HEAD", baseLog.write.path == "logs/" + base,
        ref.path == base, Self.validEntry(entry, from: expected, to: target)
      else { throw sourceMetadataChanged() }
      let source = try metadata.direct(base)
      let published = source.oid == target
      if published {
        // A published base without both exact completed reflogs is inconsistent.
        try Self.verifyAfter(headLog.write, metadata: metadata)
        try Self.verifyAfter(baseLog.write, metadata: metadata)
      } else {
        try Self.verifyBeforeOrAfter(headLog.write, metadata: metadata)
        try Self.verifyBeforeOrAfter(baseLog.write, metadata: metadata)
      }
      let headPrefix = headLog.prefix
      _ = try guards.apply(
        &headLog.write,
        contents: { previous in try Self.append(entry, to: previous, prefix: headPrefix) },
        persist: { next in try save(persist) { $0.headLog?.write = next } })
      try revalidate()
      let basePrefix = baseLog.prefix
      _ = try guards.apply(
        &baseLog.write,
        contents: { previous in try Self.append(entry, to: previous, prefix: basePrefix) },
        persist: { next in try save(persist) { $0.baseLog?.write = next } })
      try verifySource(metadata)
      try revalidate()
      let targetBytes = Data((target + "\n").utf8)
      _ = try guards.apply(
        &ref, contents: { _ in targetBytes },
        persist: { next in try save(persist) { $0.ref = next } })
      try Self.verifyAfter(headLog.write, metadata: metadata)
      try Self.verifyAfter(baseLog.write, metadata: metadata)
    }
    try guards.verify()
    try verifySource(metadata)
    guard try metadata.direct(base).oid == target else { throw sourceMetadataChanged() }
    try revalidate()
  }

  private func verifySource(_ metadata: WorktreeSourceMetadata) throws {
    let current = try metadata.direct(base)
    guard let symbolic = try metadata.read("HEAD", limit: 4096), symbolic.proof == head,
      symbolic.contents == Data(("ref: " + base + "\n").utf8),
      try metadata.direct(managed).oid == target,
      current.packed?.proof == packed
    else { throw sourceMetadataChanged() }
    if expected == target {
      guard current.oid == expected else { throw sourceMetadataChanged() }
    } else if current.oid == expected {
      guard let ref, current.loose?.proof == ref.before else { throw sourceMetadataChanged() }
    } else {
      guard current.oid == target, let after = ref?.staged, current.loose?.proof == after
      else { throw sourceMetadataChanged() }
    }
  }

  private static func verifyAfter(
    _ write: WorktreeSourceReferenceWrite, metadata: WorktreeSourceMetadata
  ) throws {
    guard let expected = write.staged, try metadata.read(write.path)?.proof == expected
    else { throw sourceMetadataChanged() }
  }

  private static func verifyBeforeOrAfter(
    _ write: WorktreeSourceReferenceWrite, metadata: WorktreeSourceMetadata
  ) throws {
    let found = try metadata.read(write.path)?.proof
    guard found == write.before || (write.staged != nil && found == write.staged)
    else { throw sourceMetadataChanged() }
  }

  private static func validEntry(_ entry: Data, from expected: String, to target: String) -> Bool {
    guard entry.count <= 16 * 1024, entry.last == 10,
      let line = WorktreeSourceReflogEntry(entry.dropLast()), let message = line.message
    else { return false }
    return line.old == expected && line.new == target && !message.isEmpty
      && !message.contains(where: { $0 < 32 })
  }

  private static func append(_ entry: Data, to previous: Data?, prefix: WorktreeSourceLogPrefix)
    throws -> Data
  {
    let bytes = previous ?? Data()
    guard prefix.matches(bytes) else { throw sourceMetadataChanged() }
    return bytes + entry
  }

  private mutating func save(
    _ persist: (WorktreeSourceMerge) throws -> Void, change: (inout Self) -> Void
  ) throws {
    var next = self
    change(&next)
    try persist(next)
    self = next
  }
}

extension WorktreeRepository {
  func sourceMergeCommitter() throws -> String {
    let result = try command(["var", "GIT_COMMITTER_IDENT"])
    guard let line = String(data: result.output, encoding: .utf8), line.last == "\n",
      validWorktreeReflogIdentity(line.dropLast())
    else { throw sourceMetadataChanged() }
    return String(line.dropLast())
  }
}
