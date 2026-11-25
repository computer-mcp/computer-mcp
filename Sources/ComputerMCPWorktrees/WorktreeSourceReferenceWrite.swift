import Foundation

/// The lifecycle journal owns this proof; its nonce names one same-directory temporary.
struct WorktreeSourceReferenceWrite: Codable, Equatable {
  let path: String
  var parent: WorktreeDirectoryIdentity?
  let nonce: UUID
  let before: WorktreeSourceFileProof?
  let contentBytes: Int
  let contentDigest: String
  var staged: WorktreeSourceFileProof?

  init(
    path: String, at location: WorktreeSourceMetadata.Location?, before: WorktreeSourceFileProof?,
    content: Data
  ) throws {
    guard content.count <= WorktreeSourceMetadata.maximumBytes else {
      throw WorktreeError.busy("Source reference write exceeds its byte bound.")
    }
    self.path = path
    parent = location?.parent.identity
    nonce = UUID()
    self.before = before
    contentBytes = content.count
    contentDigest = WorktreeObjectSnapshot.digest(content)
  }
}

extension WorktreeSourceGuards {
  /// The caller revalidates live authority before admitting this synchronous effect.
  /// A witnessed after-image is not durable until the file and ancestry sync again.
  func apply(
    _ write: inout WorktreeSourceReferenceWrite,
    contents: (Data?) throws -> Data,
    persist: (WorktreeSourceReferenceWrite) throws -> Void
  ) throws -> WorktreeSourceFileProof {
    let path = write.path
    let target = path.hasPrefix("logs/") ? String(path.dropFirst(5)) : path
    try verify(covering: [target, "packed-refs"])
    guard (0...WorktreeSourceMetadata.maximumBytes).contains(write.contentBytes),
      write.parent != nil || (path.hasPrefix("logs/") && write.before == nil && write.staged == nil)
    else { throw sourceMetadataChanged() }
    try persist(write)
    guard let location = try metadata.location(path, createParents: write.parent == nil)
    else { throw sourceMetadataChanged() }
    if write.parent == nil {
      try location.verifyAbsent()
      var next = write
      next.parent = location.parent.identity
      try persist(next)
      write = next
    }
    guard location.parent.identity == write.parent else { throw sourceMetadataChanged() }
    let temporary = try location.renamed(".computer-mcp-ref-" + write.nonce.uuidString.lowercased())
    let existing = try metadata.read(location)
    if let expected = write.staged, let existing, existing.proof == expected {
      guard expected.bytes == write.contentBytes, expected.digest == write.contentDigest
      else { throw sourceMetadataChanged() }
      try temporary.verifyAbsent()
      try existing.synchronize(at: location, using: metadata.io)
      try verify()
      return existing.proof
    }
    guard existing?.proof == write.before else { throw sourceMetadataChanged() }
    let bytes = try contents(existing?.contents)
    guard bytes.count == write.contentBytes,
      WorktreeObjectSnapshot.digest(bytes) == write.contentDigest
    else { throw sourceMetadataChanged() }
    let candidate: WorktreeSourceMetadata.File
    if let expected = write.staged {
      guard let found = try metadata.read(temporary, limit: write.contentBytes),
        found.proof == expected, found.contents == bytes
      else { throw sourceMetadataChanged() }
      candidate = found
    } else {
      try temporary.verifyAbsent()
      candidate = try metadata.create(
        bytes, at: temporary, mode: path == "packed-refs" ? 0o444 : 0o666,
        preserving: path.hasPrefix("logs/") || path == "packed-refs" ? write.before?.mode : nil)
      var next = write
      next.staged = candidate.proof
      try persist(next)
      write = next
    }
    try candidate.synchronize(at: temporary, using: metadata.io)
    try verify()
    try metadata.move(candidate, from: temporary, to: location, replacing: existing)
    try verify()
    return candidate.proof
  }
}

struct WorktreeSourceLogPrefix: Codable, Equatable {
  let bytes: Int
  let digest: String

  init(_ contents: Data) {
    bytes = contents.count
    digest = WorktreeObjectSnapshot.digest(contents)
  }

  func matches(_ contents: Data) -> Bool {
    bytes == contents.count && WorktreeObjectSnapshot.digest(contents) == digest
  }
}

struct WorktreeSourcePublicationProof: Codable, Equatable {
  enum Outcome: Equatable { case retryExpectedUpdate, durable }
  let operationID: UUID
  let branch: String
  let expected: String
  let target: String
  let message: String
  let logPrefix: WorktreeSourceLogPrefix?

  init(
    operationID: UUID, branch: String, expected: String, target: String, message: String,
    metadata: WorktreeSourceMetadata
  ) throws {
    try WorktreeSourceMetadata.requireBranch(branch)
    guard metadata.validOID(expected), metadata.validOID(target),
      !message.isEmpty, message.utf8.count <= 4096,
      !message.utf8.contains(where: { $0 < 32 })
    else { throw sourceMetadataChanged() }
    let current = try metadata.direct(branch)
    guard current.oid == expected else { throw sourceMetadataChanged() }
    let history = expected == target ? nil : try metadata.read("logs/" + branch)?.contents
    if let history, !history.isEmpty {
      guard history.last == 10,
        let line = history.dropLast().split(separator: 10, omittingEmptySubsequences: false).last,
        let entry = WorktreeSourceReflogEntry(line), metadata.format.contains(entry.old),
        entry.new == expected
      else { throw sourceMetadataChanged() }
    }
    self.operationID = operationID
    self.branch = branch
    self.expected = expected
    self.target = target
    self.message = message
    logPrefix = history.map(WorktreeSourceLogPrefix.init)
  }

  func proveAndSynchronize(
    guards: WorktreeSourceGuards, revalidate: () throws -> Void
  ) throws -> Outcome {
    let metadata = guards.metadata
    guard guards.operationID == operationID, metadata.validOID(expected), metadata.validOID(target)
    else { throw sourceMetadataChanged() }
    try guards.verify(covering: [branch, "packed-refs"])
    try revalidate()
    let direct = try metadata.direct(branch)
    let logPath = "logs/" + branch
    let log = expected == target ? nil : try metadata.read(logPath)
    if expected != target, direct.oid == expected {
      guard log.map({ WorktreeSourceLogPrefix($0.contents) }) == logPrefix
      else { throw sourceMetadataChanged() }
      return .retryExpectedUpdate
    }
    guard direct.oid == target else { throw sourceMetadataChanged() }
    if expected != target {
      guard let log else { throw sourceMetadataChanged() }
      let prefixBytes = logPrefix?.bytes ?? 0
      guard prefixBytes >= 0, log.contents.count > prefixBytes,
        logPrefix.map({ $0.matches(Data(log.contents.prefix(prefixBytes))) }) ?? true
      else { throw sourceMetadataChanged() }
      let suffix = log.contents.dropFirst(prefixBytes)
      guard suffix.last == 10, let entry = WorktreeSourceReflogEntry(suffix.dropLast()),
        entry.old == expected, entry.new == target, entry.message == Data(message.utf8)
      else { throw sourceMetadataChanged() }
    }
    if let loose = direct.loose, let location = try metadata.location(branch) {
      try loose.synchronize(at: location, using: metadata.io)
    } else {
      guard let packed = direct.packed, let location = try metadata.location("packed-refs")
      else { throw sourceMetadataChanged() }
      try packed.synchronize(at: location, using: metadata.io)
    }
    if let log, let location = try metadata.location(logPath) {
      try log.synchronize(at: location, using: metadata.io)
    }
    try guards.verify()
    try revalidate()
    let synchronized = try metadata.direct(branch)
    let logAfter = expected == target ? nil : try metadata.read(logPath)
    guard synchronized.oid == target, synchronized.loose?.proof == direct.loose?.proof,
      synchronized.loose != nil || synchronized.packed?.proof == direct.packed?.proof,
      logAfter?.proof == log?.proof
    else { throw sourceMetadataChanged() }
    return .durable
  }
}

struct WorktreeSourceReflogEntry {
  let old: String
  let new: String
  let message: Data?

  init?(_ line: Data) {
    let tab = line.firstIndex(of: 9)
    guard !line.contains(10),
      let header = String(data: line[..<(tab ?? line.endIndex)], encoding: .utf8)
    else { return nil }
    let fields = header.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
    guard fields.count == 3, validWorktreeReflogIdentity(fields[2]) else { return nil }
    old = String(fields[0])
    new = String(fields[1])
    message = tab.map { Data(line[($0 + 1)...]) }
  }
}

func validWorktreeReflogIdentity(_ value: Substring) -> Bool {
  guard !value.utf8.contains(where: { $0 < 32 }),
    let end = value.lastIndex(of: ">"), let start = value.lastIndex(of: "<"),
    start < end, start != value.startIndex
  else { return false }
  let parts = value[value.index(after: end)...].split(separator: " ")
  guard parts.count == 2, Int64(parts[0]) != nil else { return false }
  let offset = parts[1].utf8
  return offset.count == 5 && (offset.first == 43 || offset.first == 45)
    && offset.dropFirst().allSatisfy { (48...57).contains($0) }
}
