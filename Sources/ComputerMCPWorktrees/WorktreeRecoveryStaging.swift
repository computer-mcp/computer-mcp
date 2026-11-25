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

  let directory: WorktreeDirectory
  private let parent: WorktreeDirectory
  private let format: WorktreeObjectFormat
  private let io: WorktreeJournalIO
  private let verifyStore: () throws -> Void
  private var reservation: Reservation
  private var bytes: Data
  private let receiptName = "reservation.json"
  private let receiptLimit = 128 * 1024

  init(
    parent: WorktreeDirectory, operationID: UUID, generation: UUID, format: WorktreeObjectFormat,
    inputLimit: Int, completionBytes: Int, io: WorktreeJournalIO,
    verifyStore: @escaping () throws -> Void
  ) throws {
    self.parent = parent
    self.format = format
    self.io = io
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
        destination.descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard targetFD >= 0 else { throw WorktreeDirectory.posixError() }
      let target = FileHandle(fileDescriptor: targetFD, closeOnDealloc: true)
      defer { try? target.close() }
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
    try armIndex(.installation)
    let index = try copy("objects.idx", expected: artifact.index, digest: artifact.indexSHA256)
    try destination.synchronize()
    try verify()
    return WorktreeRecoveryPack(
      directory: destination, hash: artifact.hash, pack: pack, index: index,
      packSHA256: artifact.packSHA256, indexSHA256: artifact.indexSHA256)
  }

  func finishAfterFailure() throws {
    if !reservation.exposed { try finish() }
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
    var total = try WorktreePackBounds.sum(
      next.inputLimit, next.completionBytes, WorktreePackBounds.metadataLimit,
      receiptLimit, receiptLimit)
    for slot in next.packs.values {
      total = try WorktreePackBounds.sum(total, slot.bounds.packBytes, slot.bounds.indexBytes)
    }
    guard contents.count <= receiptLimit, next.packs.count <= 4,
      total <= (try WorktreePackBounds.stagingMaximum(format: format))
    else { throw invalidRecoveryMetadata() }
    try io.write(contents, name: receiptName, in: parent, replacing: bytes)
    reservation = next
    bytes = contents
  }

  private func capturedObjectBytes() throws -> Int {
    let slots = ["private-objects", "source-objects", "retained-objects"]
    let names = try directory.entries(limit: 8)
    guard names.contains("capture.git"), names.contains("private-objects"),
      names.contains("source-objects"),
      names.allSatisfy({ $0 == "capture.git" || slots.contains($0) || reservation.packs[$0] != nil }
      )
    else { throw invalidRecoveryMetadata() }
    try verifyCaptureRepository(directory.child("capture.git"))
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

  private func verifyCaptureRepository(_ repo: WorktreeDirectory) throws {
    let objectDirectory = try repo.child("objects")
    let refs = try repo.child("refs")
    guard try repo.entries(limit: 4) == ["HEAD", "config", "objects", "refs"],
      try objectDirectory.entries(limit: 2) == ["info", "pack"],
      try refs.entries(limit: 2) == ["heads", "tags"]
    else { throw invalidRecoveryMetadata() }
    for name in ["info", "pack"] where try !objectDirectory.child(name).entries(limit: 0).isEmpty {
      throw invalidRecoveryMetadata()
    }
    for name in ["heads", "tags"] where try !refs.child(name).entries(limit: 0).isEmpty {
      throw invalidRecoveryMetadata()
    }
    let head = try WorktreeRecoveryStageFile.read("HEAD", in: repo, limit: 1_024)
    _ = try WorktreeRecoveryStageFile.read(
      "config", in: repo, limit: WorktreePackBounds.metadataLimit - head.bytes)
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
