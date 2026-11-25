import Foundation

/// Source-side substate of the branch deletion journal. The owning lifecycle
/// retains its exact store selections and protection through guard cleanup.
struct WorktreeSourceDeletion: Codable, Equatable {
  enum Phase: String, Codable { case normalizing, armed, removingLog, sourceDeleted }

  let operationID: UUID
  let branch: String
  let expected: String
  let base: String
  let expectedBase: String?
  let head: WorktreeSourceFileProof?
  let packedBefore: WorktreeSourceFileProof?
  let logBefore: WorktreeSourceFileProof?
  let logParent: WorktreeDirectoryIdentity?
  let originalGuard: WorktreeSourceFileProof
  var looseWrite: WorktreeSourceReferenceWrite
  var packedWrite: WorktreeSourceReferenceWrite?
  private(set) var phase: Phase

  var deletionReceipts: [String: WorktreeSourceFileProof] {
    guard phase != .normalizing, let canonical = looseWrite.staged else { return [:] }
    return [branch: canonical]
  }

  init(
    branch: String, expected: String, base: String, expectedBase: String?,
    requireSymbolicHead: Bool,
    guards: WorktreeSourceGuards
  ) throws {
    let metadata = guards.metadata
    guard branch != base, metadata.validOID(expected), expectedBase.map(metadata.validOID) ?? true
    else { throw sourceMetadataChanged() }
    try guards.verify(covering: [branch, base, "packed-refs"])
    if requireSymbolicHead {
      try guards.verify(covering: ["HEAD"])
      guard let symbolic = try metadata.read("HEAD", limit: 4096),
        symbolic.contents == Data(("ref: " + base + "\n").utf8)
      else { throw sourceMetadataChanged() }
      head = symbolic.proof
    } else {
      head = nil
    }
    let subject = try metadata.direct(branch)
    guard subject.oid == expected, try metadata.direct(base).oid == expectedBase,
      let loose = try metadata.location(branch)
    else { throw sourceMetadataChanged() }
    let logLocation = try metadata.location("logs/" + branch)
    let log = try logLocation.flatMap { try metadata.read($0) }
    operationID = guards.operationID
    self.branch = branch
    self.expected = expected
    self.base = base
    self.expectedBase = expectedBase
    packedBefore = subject.packed?.proof
    logBefore = log?.proof
    logParent = logLocation?.parent.identity
    originalGuard = try guards.guardProof(for: branch)
    looseWrite = try .init(
      path: branch, at: loose, before: subject.loose?.proof, content: Data((expected + "\n").utf8))
    if subject.packedRefs.oid(for: branch) != nil {
      guard let packed = try metadata.location("packed-refs") else { throw sourceMetadataChanged() }
      packedWrite = try .init(
        path: "packed-refs", at: packed, before: packedBefore,
        content: subject.packedRefs.removing(branch))
    }
    phase = .normalizing
  }

  /// Revalidation checks live authority, unused-branch policy, history and the
  /// exact store and protection revisions; it must allow the recorded branch
  /// to be absent following the decisive rename.
  mutating func completeSource(
    guards: WorktreeSourceGuards, revalidate: (_ deleted: Bool) throws -> Void,
    persist: (WorktreeSourceDeletion) throws -> Void
  ) throws {
    let metadata = guards.metadata
    guard guards.operationID == operationID, branch != base,
      metadata.validOID(expected), expectedBase.map(metadata.validOID) ?? true,
      looseWrite.path == branch, packedWrite?.path ?? "packed-refs" == "packed-refs",
      packedWrite == nil || packedWrite?.before == packedBefore
    else { throw sourceMetadataChanged() }
    try guards.verify(covering: [branch, base, "packed-refs"])
    let checkBase = { [base, expectedBase, head] in
      guard try metadata.direct(base).oid == expectedBase
      else { throw sourceMetadataChanged() }
      if let head {
        try guards.verify(covering: ["HEAD"])
        guard let symbolic = try metadata.read("HEAD", limit: 4096), symbolic.proof == head,
          symbolic.contents == Data(("ref: " + base + "\n").utf8)
        else { throw sourceMetadataChanged() }
      }
    }
    try checkBase()
    try persist(self)

    if phase == .normalizing {
      let subject = try metadata.direct(branch)
      guard try guards.guardProof(for: branch) == originalGuard, subject.oid == expected,
        subject.packed?.proof == packedBefore
          || (packedWrite?.staged != nil && subject.packed?.proof == packedWrite?.staged)
      else { throw sourceMetadataChanged() }
      try revalidate(false)
      try verifyLog(metadata)
      var write = looseWrite
      let canonical = Data((expected + "\n").utf8)
      _ = try guards.apply(
        &write, contents: { _ in canonical },
        persist: { next in try save(persist) { $0.looseWrite = next } })
      if var packed = packedWrite {
        try revalidate(false)
        let branch = branch
        _ = try guards.apply(
          &packed,
          contents: { bytes in
            guard let bytes else { throw sourceMetadataChanged() }
            let image = try WorktreePackedRefs(bytes, format: metadata.format)
            guard image.oid(for: branch) != nil else { throw sourceMetadataChanged() }
            return image.removing(branch)
          },
          persist: { next in try save(persist) { $0.packedWrite = next } })
      }
      try checkBase()
      try verifyLog(metadata)
      try verifyPackedAfter(metadata)
      try save(persist) { $0.phase = .armed }
    }

    guard let canonical = looseWrite.staged,
      canonical.bytes == expected.utf8.count + 1,
      canonical.digest == WorktreeObjectSnapshot.digest(Data((expected + "\n").utf8))
    else { throw sourceMetadataChanged() }
    try verifyPackedAfter(metadata)
    if phase == .armed {
      try verifyLog(metadata)
      let subject = try metadata.direct(branch)
      let lock = try guards.guardProof(for: branch)
      if subject.oid == expected, subject.loose?.proof == canonical, lock == originalGuard {
        try revalidate(false)
        try guards.moveBranchIntoReceipt(branch, armed: canonical, originalGuard: originalGuard)
      } else if subject.oid == nil, lock == canonical {
        try revalidate(true)
      } else {
        throw sourceMetadataChanged()
      }
    }
    try checkBase()
    try verifyPackedAfter(metadata)
    guard try metadata.direct(branch).oid == nil,
      try guards.guardProof(for: branch) == canonical
    else { throw sourceMetadataChanged() }
    try guards.synchronizeGuard(for: branch)
    try revalidate(true)

    let logLocation = try checkedLogLocation(metadata)
    let log = try logLocation.flatMap { try metadata.read($0) }
    if phase == .sourceDeleted {
      guard log == nil else { throw sourceMetadataChanged() }
      try logLocation?.synchronize(using: metadata.io)
      return
    }
    if phase == .armed {
      guard log?.proof == logBefore else { throw sourceMetadataChanged() }
      try save(persist) { $0.phase = .removingLog }
    }
    if let log, let logLocation {
      guard log.proof == logBefore else { throw sourceMetadataChanged() }
      try guards.verify()
      try metadata.remove(log, at: logLocation)
    }
    try logLocation?.synchronize(using: metadata.io)
    try guards.verify()
    try checkBase()
    try revalidate(true)
    guard try metadata.read("logs/" + branch) == nil else { throw sourceMetadataChanged() }
    try save(persist) { $0.phase = .sourceDeleted }
  }

  private func verifyPackedAfter(_ metadata: WorktreeSourceMetadata) throws {
    let subject = try metadata.direct(branch)
    guard subject.packedRefs.oid(for: branch) == nil,
      packedWrite == nil || packedWrite?.staged != nil,
      subject.packed?.proof == (packedWrite?.staged ?? packedBefore)
    else { throw sourceMetadataChanged() }
    if let packed = subject.packed, let location = try metadata.location("packed-refs") {
      try packed.synchronize(at: location, using: metadata.io)
    }
  }

  private func checkedLogLocation(_ metadata: WorktreeSourceMetadata) throws
    -> WorktreeSourceMetadata.Location?
  {
    let location = try metadata.location("logs/" + branch)
    guard location?.parent.identity == logParent else { throw sourceMetadataChanged() }
    return location
  }

  private func verifyLog(_ metadata: WorktreeSourceMetadata) throws {
    let location = try checkedLogLocation(metadata)
    guard try location.flatMap({ try metadata.read($0) })?.proof == logBefore
    else { throw sourceMetadataChanged() }
  }

  private mutating func save(
    _ persist: (WorktreeSourceDeletion) throws -> Void, change: (inout Self) -> Void
  ) throws {
    var next = self
    change(&next)
    try persist(next)
    self = next
  }
}
