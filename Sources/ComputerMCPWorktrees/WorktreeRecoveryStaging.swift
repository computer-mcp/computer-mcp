import Crypto
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

final class WorktreeRecoveryStaging {
  enum PackSlot: String, Codable { case supplemental, recovery, source, installation }

  private struct Reservation: Codable {
    var version = 1
    let operationID: UUID
    let generation: UUID
    let directory: WorktreeDirectoryIdentity
    let inputLimit: Int
    let completionBytes: Int
    var capturedBytes: Int?
    var packs: [String: PackReservation] = [:]
    var supplement: SupplementalPlacement?
    var sourceInstallation: SourceInstallation?
    var exposed = false
    var disposing = false
  }

  private struct PackReservation: Codable {
    let bounds: WorktreePackBounds
    let directory: WorktreeDirectoryIdentity
    var indexArmed = false
  }

  private struct SupplementalPlacement: Codable {
    let hash: String
    let pack: WorktreeRecoveryStageFile
    let index: WorktreeRecoveryStageFile
  }

  private struct SourceInstallation: Codable {
    let parent: WorktreeDirectoryIdentity
    let bounds: WorktreePackBounds
    let source: WorktreeRecoveryPackReceipt
    var directory: WorktreeDirectoryIdentity?
    var artifact: WorktreeRecoveryPackReceipt?
    var discarding = false
  }

  let directory: WorktreeDirectory
  private let parent: WorktreeDirectory
  private let format: WorktreeObjectFormat
  private let io: WorktreeJournalIO
  private let verifyStore: () throws -> Void
  private let sourceObjects: WorktreeDirectoryIdentity?
  private var reservation: Reservation
  private var bytes: Data
  private let receiptName = "reservation.json"
  private let receiptLimit = 128 * 1024

  init(
    parent: WorktreeDirectory, operationID: UUID, generation: UUID, format: WorktreeObjectFormat,
    inputLimit: Int, completionBytes: Int, io: WorktreeJournalIO,
    sourceObjects: WorktreeDirectoryIdentity? = nil,
    verifyStore: @escaping () throws -> Void
  ) throws {
    self.parent = parent
    self.format = format
    self.io = io
    self.sourceObjects = sourceObjects
    self.verifyStore = verifyStore
    guard inputLimit >= 0, inputLimit <= WorktreePromotionLimits().inputBytes,
      completionBytes >= 0, completionBytes <= 2 * WorktreePackBounds.metadataLimit
    else { throw invalidRecoveryMetadata() }
    try verifyStore()
    try Self.clearCompletedDisposal(in: parent, generation: generation, io: io)
    try parent.synchronize()
    directory = try parent.child(operationID.uuidString.lowercased(), create: true, exclusive: true)
    reservation = Reservation(
      operationID: operationID, generation: generation, directory: directory.identity,
      inputLimit: inputLimit, completionBytes: completionBytes)
    bytes = try recoveryJSON(reservation)
    guard bytes.count <= receiptLimit else { throw invalidRecoveryMetadata() }
    try io.write(bytes, name: receiptName, in: parent, replacing: nil)
    try verify()
  }

  static func finishRecordedDisposal(
    operationID: UUID, parent: WorktreeDirectory, generation: UUID, io: WorktreeJournalIO,
    verifyStore: () throws -> Void
  ) throws -> Bool {
    try verifyStore()
    let entries = try parent.entries(limit: 2)
    let name = "reservation.json"
    if entries.isEmpty {
      try parent.synchronize()
      return true
    }
    guard let bytes = try io.read(name, in: parent, limit: 128 * 1024) else {
      throw invalidRecoveryMetadata()
    }
    let prior = try JSONDecoder().decode(Reservation.self, from: bytes)
    let stage = operationID.uuidString.lowercased()
    guard prior.version == 1, prior.generation == generation,
      prior.operationID == operationID,
      prior.directory.path == parent.url.appendingPathComponent(stage).path,
      entries == [name] || entries == [name, stage].sorted()
    else { throw invalidRecoveryMetadata() }
    guard prior.disposing else { return false }
    if let installation = prior.sourceInstallation, installation.directory != nil,
      !installation.discarding
    {
      throw invalidRecoveryMetadata()
    }
    try io.synchronize(name, in: parent, expecting: bytes)
    if try parent.hasEntry(stage) { try parent.removeOwnedTree(prior.directory, io: io) }
    try io.remove(name, in: parent, expecting: bytes)
    try verifyStore()
    guard try parent.entries(limit: 0).isEmpty else { throw invalidRecoveryMetadata() }
    return true
  }

  init(
    reopening operationID: UUID, parent: WorktreeDirectory, generation: UUID,
    format: WorktreeObjectFormat, io: WorktreeJournalIO,
    sourceObjects: WorktreeDirectoryIdentity, verifyStore: @escaping () throws -> Void
  ) throws {
    self.parent = parent
    self.format = format
    self.io = io
    self.sourceObjects = sourceObjects
    self.verifyStore = verifyStore
    try verifyStore()
    guard let current = try io.read(receiptName, in: parent, limit: receiptLimit) else {
      throw invalidRecoveryMetadata()
    }
    let decoded = try JSONDecoder().decode(Reservation.self, from: current)
    guard decoded.version == 1, decoded.operationID == operationID,
      decoded.generation == generation,
      decoded.exposed, !decoded.disposing, let capturedBytes = decoded.capturedBytes,
      capturedBytes >= 0, capturedBytes <= decoded.inputLimit
    else { throw invalidRecoveryMetadata() }
    directory = try parent.child(operationID.uuidString.lowercased())
    guard directory.identity == decoded.directory else { throw invalidRecoveryMetadata() }
    reservation = decoded
    bytes = current
    try checkCapacity(decoded, bytes: current.count)
    try io.synchronize(receiptName, in: parent, expecting: current)
    try verify()
  }

  func verify() throws {
    try verifyStore()
    try directory.verify()
    guard !reservation.disposing,
      try parent.entries(limit: 2) == [directory.url.lastPathComponent, receiptName].sorted(),
      try io.read(receiptName, in: parent, limit: receiptLimit) == bytes
    else { throw invalidRecoveryMetadata() }
    for (name, slot) in reservation.packs {
      guard try directory.child(name).identity == slot.directory else {
        throw invalidRecoveryMetadata()
      }
    }
  }

  func sealCapture(bytes capturedBytes: Int) throws {
    try verify()
    guard reservation.capturedBytes == nil, capturedBytes >= 0,
      capturedBytes <= reservation.inputLimit, try capturedObjectBytes() == capturedBytes
    else { throw invalidRecoveryMetadata() }
    var next = reservation
    next.capturedBytes = capturedBytes
    try save(next)
  }

  func reservePack(_ slot: PackSlot, bounds: WorktreePackBounds) throws -> WorktreeDirectory {
    try verify()
    let key = slot.rawValue
    let maximum = try WorktreePackBounds.maximum(format: format)
    guard reservation.capturedBytes != nil, reservation.packs[key] == nil,
      slot != .installation || reservation.sourceInstallation == nil,
      bounds.packBytes > 0, bounds.packBytes <= maximum.packBytes,
      bounds.indexBytes > 0, bounds.indexBytes <= maximum.indexBytes
    else { throw invalidRecoveryMetadata() }
    let created = try directory.child(key, create: true, exclusive: true)
    var next = reservation
    next.packs[key] = .init(bounds: bounds, directory: created.identity)
    try save(next)
    return created
  }

  func armIndex(_ slot: PackSlot) throws {
    try verify()
    let name = slot.rawValue
    guard let item = reservation.packs[name], !item.indexArmed,
      try directory.child(name).entries(limit: 2) == ["objects.pack"]
    else { throw invalidRecoveryMetadata() }
    var next = reservation
    next.packs[name]?.indexArmed = true
    try save(next)
  }

  func attachSupplement(_ artifact: WorktreeRecoveryPack, to privateObjects: WorktreeDirectory)
    throws
  {
    try verify()
    guard reservation.supplement == nil, format.contains(artifact.hash),
      artifact.directory.identity == (try directory.child(PackSlot.supplemental.rawValue)).identity,
      privateObjects.identity == (try directory.child("private-objects")).identity
    else { throw invalidRecoveryMetadata() }
    let packs = try privateObjects.child("pack", create: true)
    let names = [("objects.pack", ".pack", artifact.pack), ("objects.idx", ".idx", artifact.index)]
    for (name, suffix, expected) in names {
      guard try !packs.hasEntry("pack-" + artifact.hash + suffix),
        try WorktreeRecoveryStageFile.read(name, in: artifact.directory, limit: expected.bytes)
          == expected
      else { throw invalidRecoveryMetadata() }
    }
    var next = reservation
    next.supplement = .init(hash: artifact.hash, pack: artifact.pack, index: artifact.index)
    try save(next)
    for (name, suffix, expected) in names {
      let target = "pack-" + artifact.hash + suffix
      try artifact.directory.verify()
      try packs.verify()
      guard try !packs.hasEntry(target),
        try WorktreeRecoveryStageFile.read(name, in: artifact.directory, limit: expected.bytes)
          == expected,
        renameat(artifact.directory.descriptor, name, packs.descriptor, target) == 0,
        try WorktreeRecoveryStageFile.read(target, in: packs, limit: expected.bytes) == expected
      else { throw invalidRecoveryMetadata() }
    }
    try packs.synchronize()
    try artifact.directory.synchronize()
  }

  func exposeArtifacts() throws {
    try verify()
    var next = reservation
    next.exposed = true
    try save(next)
  }

  func reopenPack(
    _ receipt: WorktreeRecoveryPackReceipt, slot: PackSlot
  ) throws -> WorktreeRecoveryPack {
    try verify()
    try receipt.validate(format: format)
    guard reservation.exposed, let planned = reservation.packs[slot.rawValue], planned.indexArmed,
      planned.directory == receipt.directory, receipt.pack.bytes <= planned.bounds.packBytes,
      receipt.index.bytes <= planned.bounds.indexBytes
    else { throw invalidRecoveryMetadata() }
    return try receipt.open(in: directory.child(slot.rawValue))
  }

  func copyForInstallation(
    _ artifact: WorktreeRecoveryPack, deadline: ContinuousClock.Instant
  ) throws -> WorktreeRecoveryPack {
    try verify()
    guard reservation.packs.values.contains(where: { $0.directory == artifact.directory.identity }),
      artifact.pack.bytes > 0, artifact.index.bytes > 0
    else { throw invalidRecoveryMetadata() }
    let destination = try reservePack(
      .installation, bounds: .init(packBytes: artifact.pack.bytes, indexBytes: artifact.index.bytes)
    )
    return try copyInstallation(artifact, to: destination, deadline: deadline) {
      try armIndex(.installation)
    }
  }

  /// Cross-filesystem publication consumes the same installation slot as a
  /// regular copy. The charge lands before creating any source-side file.
  func prepareSourceInstallation(
    _ artifact: WorktreeRecoveryPack, beside packDirectory: WorktreeDirectory,
    permissions: WorktreeSourcePermissions, deadline: ContinuousClock.Instant
  ) throws -> WorktreeRecoveryPack {
    try verify()
    let receipt = WorktreeRecoveryPackReceipt(artifact)
    _ = try reopenPack(receipt, slot: .source)
    try requireSourcePackDirectory(packDirectory)
    let name = sourceInstallationName
    if reservation.sourceInstallation == nil {
      guard reservation.packs[PackSlot.installation.rawValue] == nil,
        try !packDirectory.hasEntry(name)
      else { throw invalidRecoveryMetadata() }
      var next = reservation
      next.sourceInstallation = .init(
        parent: packDirectory.identity,
        bounds: .init(packBytes: artifact.pack.bytes, indexBytes: artifact.index.bytes),
        source: receipt)
      try save(next)
    }
    guard let placement = reservation.sourceInstallation, !placement.discarding,
      placement.parent == packDirectory.identity, placement.source == receipt
    else { throw invalidRecoveryMetadata() }
    let scratch: WorktreeDirectory
    if let expected = placement.directory {
      scratch = try packDirectory.child(name)
      guard scratch.identity == expected else { throw invalidRecoveryMetadata() }
    } else {
      scratch = try packDirectory.child(name, create: true, exclusive: true)
      var next = reservation
      next.sourceInstallation?.directory = scratch.identity
      try save(next)
    }
    if let existing = placement.artifact { return try existing.open(in: scratch) }
    try discardUnexposedCopy(in: scratch, bounds: placement.bounds)
    let copy = try copyInstallation(
      artifact, to: scratch, permissions: permissions, deadline: deadline, beforeIndex: {})
    var next = reservation
    next.sourceInstallation?.artifact = WorktreeRecoveryPackReceipt(copy)
    try save(next)
    return copy
  }

  private func copyInstallation(
    _ artifact: WorktreeRecoveryPack, to destination: WorktreeDirectory,
    permissions: WorktreeSourcePermissions? = nil, deadline: ContinuousClock.Instant,
    beforeIndex: () throws -> Void
  ) throws -> WorktreeRecoveryPack {
    func copy(_ name: String, expected: WorktreeRecoveryStageFile, digest: String) throws
      -> WorktreeRecoveryStageFile
    {
      try verify()
      let sourceFD = openat(
        artifact.directory.descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
      guard sourceFD >= 0 else { throw WorktreeDirectory.posixError() }
      let source = FileHandle(fileDescriptor: sourceFD, closeOnDealloc: true)
      defer { try? source.close() }
      guard
        try WorktreeRecoveryStageFile.read(
          name, in: artifact.directory, limit: expected.bytes, opened: source) == expected
      else { throw invalidRecoveryMetadata() }
      let targetFD = openat(
        destination.descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        permissions == nil ? 0o600 : 0o444)
      guard targetFD >= 0 else { throw WorktreeDirectory.posixError() }
      let target = FileHandle(fileDescriptor: targetFD, closeOnDealloc: true)
      defer { try? target.close() }
      if let permissions {
        var status = stat()
        guard fstat(targetFD, &status) == 0,
          fchmod(targetFD, permissions.adjusted(status.st_mode & 0o7777)) == 0
        else { throw WorktreeDirectory.posixError() }
      }
      var remaining = expected.bytes
      var hash = SHA256()
      while remaining > 0 {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else {
          throw WorktreeError.busy("Recovery installation copy deadline exceeded.")
        }
        guard let chunk = try source.read(upToCount: min(remaining, 65_536)), !chunk.isEmpty,
          chunk.count <= remaining
        else { throw invalidRecoveryMetadata() }
        try target.write(contentsOf: chunk)
        hash.update(data: chunk)
        remaining -= chunk.count
      }
      guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest,
        try WorktreeRecoveryStageFile.read(
          name, in: artifact.directory, limit: expected.bytes, opened: source) == expected
      else { throw invalidRecoveryMetadata() }
      try target.synchronize()
      let copy = try WorktreeRecoveryStageFile.read(
        name, in: destination, limit: expected.bytes, opened: target)
      guard copy.bytes == expected.bytes else { throw invalidRecoveryMetadata() }
      return copy
    }
    let pack = try copy("objects.pack", expected: artifact.pack, digest: artifact.packSHA256)
    try beforeIndex()
    let index = try copy("objects.idx", expected: artifact.index, digest: artifact.indexSHA256)
    try destination.synchronize()
    try verify()
    return WorktreeRecoveryPack(
      directory: destination, hash: artifact.hash, pack: pack, index: index,
      packSHA256: artifact.packSHA256, indexSHA256: artifact.indexSHA256)
  }

  func finishAfterFailure() throws {
    guard !reservation.exposed else { return }
    if reservation.capturedBytes == nil {
      try verify()
      guard reservation.packs.isEmpty, reservation.sourceInstallation == nil else {
        throw invalidRecoveryMetadata()
      }
      // An in-process capture error is observed after its writers quiesce.
      // Account for the owned partial input before returning the reservation.
      _ = try capturedObjectBytes(complete: false)
      try dispose()
    } else {
      try finish()
    }
  }

  func finish() throws {
    try verify()
    guard let captured = reservation.capturedBytes, try capturedObjectBytes() == captured
    else { throw invalidRecoveryMetadata() }
    for (name, item) in reservation.packs {
      let bounds = item.bounds
      if try directory.hasEntry(name) {
        let slot = try directory.child(name)
        for file in try slot.entries(limit: 2) {
          guard file == "objects.pack" || file == "objects.idx" && item.indexArmed else {
            throw invalidRecoveryMetadata()
          }
          let staged = try WorktreeRecoveryStageFile.read(
            file, in: slot, limit: file == "objects.pack" ? bounds.packBytes : bounds.indexBytes)
          if name == PackSlot.supplemental.rawValue, let placement = reservation.supplement {
            let expected = file == "objects.pack" ? placement.pack : placement.index
            guard staged == expected else { throw invalidRecoveryMetadata() }
          }
        }
      }
    }
    try discardSourceInstallation()
    try dispose()
  }

  private func dispose() throws {
    var next = reservation
    next.disposing = true
    try save(next)
    try parent.removeOwnedTree(reservation.directory, io: io)
    try io.remove(receiptName, in: parent, expecting: bytes)
    guard try parent.entries(limit: 2).isEmpty else { throw invalidRecoveryMetadata() }
  }

  private func save(_ next: Reservation) throws {
    try verify()
    let contents = try recoveryJSON(next)
    try checkCapacity(next, bytes: contents.count)
    try io.write(contents, name: receiptName, in: parent, replacing: bytes)
    reservation = next
    bytes = contents
  }

  private func checkCapacity(_ next: Reservation, bytes: Int) throws {
    var total = try WorktreePackBounds.sum(
      next.inputLimit, next.completionBytes, WorktreePackBounds.metadataLimit,
      receiptLimit, receiptLimit)
    for slot in next.packs.values {
      total = try WorktreePackBounds.sum(total, slot.bounds.packBytes, slot.bounds.indexBytes)
    }
    if let installation = next.sourceInstallation {
      guard next.packs[PackSlot.installation.rawValue] == nil else {
        throw invalidRecoveryMetadata()
      }
      total = try WorktreePackBounds.sum(
        total, installation.bounds.packBytes, installation.bounds.indexBytes)
    }
    guard bytes <= receiptLimit, next.packs.count + (next.sourceInstallation == nil ? 0 : 1) <= 4,
      total <= (try WorktreePackBounds.stagingMaximum(format: format))
    else { throw invalidRecoveryMetadata() }
  }

  private var sourceInstallationName: String {
    ".computer-mcp-install-" + reservation.operationID.uuidString.lowercased()
  }

  private func discardUnexposedCopy(in scratch: WorktreeDirectory, bounds: WorktreePackBounds)
    throws
  {
    let files = try scratch.entries(limit: 2)
    for name in files {
      guard name == "objects.pack" || name == "objects.idx" else { throw invalidRecoveryMetadata() }
      let limit = name == "objects.pack" ? bounds.packBytes : bounds.indexBytes
      let observed = try WorktreeRecoveryStageFile.read(name, in: scratch, limit: limit)
      try scratch.verify()
      guard try WorktreeRecoveryStageFile.read(name, in: scratch, limit: limit) == observed,
        unlinkat(scratch.descriptor, name, 0) == 0
      else { throw invalidRecoveryMetadata() }
    }
    try scratch.synchronize()
  }

  private func discardSourceInstallation() throws {
    guard let placement = reservation.sourceInstallation else { return }
    let packDirectory = try WorktreeDirectory(URL(fileURLWithPath: placement.parent.path))
    guard packDirectory.identity == placement.parent else { throw invalidRecoveryMetadata() }
    try requireSourcePackDirectory(packDirectory)
    let name = sourceInstallationName
    if try packDirectory.hasEntry(name) {
      let scratch = try packDirectory.child(name)
      guard scratch.identity == placement.directory else { throw invalidRecoveryMetadata() }
      for file in try scratch.entries(limit: 2) {
        guard file == "objects.pack" || file == "objects.idx" else {
          throw invalidRecoveryMetadata()
        }
        let isPack = file == "objects.pack"
        let proof = try WorktreeRecoveryStageFile.read(
          file, in: scratch,
          limit: isPack ? placement.bounds.packBytes : placement.bounds.indexBytes)
        if let artifact = placement.artifact {
          guard proof == (isPack ? artifact.pack : artifact.index)
          else { throw invalidRecoveryMetadata() }
        }
      }
      if !placement.discarding {
        var next = reservation
        next.sourceInstallation?.discarding = true
        try save(next)
      }
      try packDirectory.removeOwnedTree(scratch.identity, io: io)
    } else if placement.directory != nil, !placement.discarding {
      throw invalidRecoveryMetadata()
    }
    try packDirectory.synchronize()
  }

  private func requireSourcePackDirectory(_ directory: WorktreeDirectory) throws {
    guard let sourceObjects else { throw invalidRecoveryMetadata() }
    let objects = try WorktreeDirectory(URL(fileURLWithPath: sourceObjects.path))
    guard objects.identity == sourceObjects,
      try objects.child("pack").identity == directory.identity
    else { throw invalidRecoveryMetadata() }
    try directory.verify()
  }

  private func capturedObjectBytes(complete: Bool = true) throws -> Int {
    let slots = ["private-objects", "source-objects", "retained-objects"]
    let names = try directory.entries(limit: 8)
    guard
      !complete || Set(["capture.git", "private-objects", "source-objects"]).isSubset(of: names),
      names.allSatisfy({ $0 == "capture.git" || slots.contains($0) || reservation.packs[$0] != nil }
      )
    else { throw invalidRecoveryMetadata() }
    if names.contains("capture.git") {
      try verifyCaptureRepository(directory.child("capture.git"), complete: complete)
    }
    var total = 0
    var filesRemaining = WorktreePromotionLimits().objectCount * 2 + 2
    for name in slots where names.contains(name) {
      let pool = try directory.child(name)
      for component in try pool.entries(limit: 257) {
        let packed = component == "pack"
        guard packed || (component.utf8.count == 2 && component.utf8.allSatisfy(Self.isHex))
        else { throw invalidRecoveryMetadata() }
        let child = try pool.child(component)
        for file in try child.entries(limit: filesRemaining) {
          filesRemaining -= 1
          if packed {
            let parts = file.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].hasPrefix("pack-"),
              format.contains(String(parts[0].dropFirst(5))), ["pack", "idx"].contains(parts[1])
            else { throw invalidRecoveryMetadata() }
            if name == "private-objects", let placement = reservation.supplement,
              parts[0] == "pack-" + placement.hash,
              let bounds = reservation.packs[PackSlot.supplemental.rawValue]?.bounds
            {
              let placed = try WorktreeRecoveryStageFile.read(
                file, in: child, limit: parts[1] == "pack" ? bounds.packBytes : bounds.indexBytes)
              guard placed == (parts[1] == "pack" ? placement.pack : placement.index) else {
                throw invalidRecoveryMetadata()
              }
              continue
            }
          } else {
            guard format.contains(component + file) else { throw invalidRecoveryMetadata() }
          }
          let captured = try WorktreeRecoveryStageFile.read(
            file, in: child, limit: reservation.inputLimit - total)
          total = try WorktreePackBounds.sum(total, captured.bytes)
        }
      }
    }
    return total
  }

  private func verifyCaptureRepository(_ repo: WorktreeDirectory, complete: Bool) throws {
    func entries(_ directory: WorktreeDirectory, allowed: Set<String>) throws -> Set<String> {
      let found = try Set(directory.entries(limit: allowed.count))
      guard complete ? found == allowed : found.isSubset(of: allowed)
      else { throw invalidRecoveryMetadata() }
      return found
    }
    let root = try entries(repo, allowed: ["HEAD", "config", "objects", "refs"])
    for (name, allowed) in [("objects", Set(["info", "pack"])), ("refs", Set(["heads", "tags"]))]
    where root.contains(name) {
      let child = try repo.child(name)
      for entry in try entries(child, allowed: allowed) {
        guard try child.child(entry).entries(limit: 0).isEmpty else {
          throw invalidRecoveryMetadata()
        }
      }
    }
    if root.contains("HEAD") {
      _ = try WorktreeRecoveryStageFile.read("HEAD", in: repo, limit: 1_024)
    }
    if root.contains("config") {
      _ = try WorktreeRecoveryStageFile.read(
        "config", in: repo, limit: WorktreePackBounds.metadataLimit - 1_024)
    }
  }

  private static func isHex(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (97...102).contains(byte)
  }

  private static func clearCompletedDisposal(
    in parent: WorktreeDirectory, generation: UUID, io: WorktreeJournalIO
  ) throws {
    let entries = try parent.entries(limit: 2)
    if entries.isEmpty { return }
    let name = "reservation.json"
    guard entries == [name], let bytes = try io.read(name, in: parent, limit: 128 * 1024),
      let prior = try? JSONDecoder().decode(Reservation.self, from: bytes),
      prior.version == 1, prior.disposing, prior.generation == generation,
      prior.directory.path
        == parent.url.appendingPathComponent(prior.operationID.uuidString.lowercased()).path
    else {
      throw WorktreeError.recoveryRequired(
        "An existing recovery staging reservation needs reconciliation.")
    }
    try io.synchronize(name, in: parent, expecting: bytes)
    try io.remove(name, in: parent, expecting: bytes)
  }
}
