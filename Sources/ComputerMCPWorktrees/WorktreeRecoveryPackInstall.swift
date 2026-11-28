import ComputerMCPPlatformPOSIX
import Crypto
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

struct WorktreeRecoveryPackReceipt: Codable, Equatable {
  let directory: WorktreeDirectoryIdentity
  let hash: String
  let pack: WorktreeRecoveryStageFile
  let index: WorktreeRecoveryStageFile
  let packSHA256: String
  let indexSHA256: String

  init(_ artifact: WorktreeRecoveryPack) {
    directory = artifact.directory.identity
    hash = artifact.hash
    pack = artifact.pack
    index = artifact.index
    packSHA256 = artifact.packSHA256
    indexSHA256 = artifact.indexSHA256
  }

  func validate(format: WorktreeObjectFormat) throws {
    let maximum = try WorktreePackBounds.maximum(format: format)
    guard format.contains(hash), packSHA256.isRecoveryDigest, indexSHA256.isRecoveryDigest,
      (1...maximum.packBytes).contains(pack.bytes), (1...maximum.indexBytes).contains(index.bytes)
    else { throw invalidRecoveryMetadata() }
  }

  func open(in root: WorktreeDirectory) throws -> WorktreeRecoveryPack {
    guard root.identity == directory else { throw invalidRecoveryMetadata() }
    return .init(
      directory: root, hash: hash, pack: pack, index: index,
      packSHA256: packSHA256, indexSHA256: indexSHA256)
  }
}

/// The lifecycle journal and the active staging reservation own an installation
/// until both files are durable and independently reachable from the destination.
struct WorktreeRecoveryPackInstall: Codable, Equatable {
  let operationID: UUID
  let generation: UUID
  let destination: WorktreeDirectoryIdentity
  let artifact: WorktreeRecoveryPackReceipt
  private(set) var ownedKeep: WorktreeRecoveryStageFile?

  init(
    operationID: UUID, generation: UUID, destination: WorktreeDirectory, pack: WorktreeRecoveryPack
  ) {
    self.operationID = operationID
    self.generation = generation
    self.destination = destination.identity
    artifact = WorktreeRecoveryPackReceipt(pack)
  }

  private var packName: String { "pack-" + artifact.hash }
  private var keepBytes: Data {
    Data(
      "computer-mcp recovery \(operationID.uuidString.lowercased()) \(generation.uuidString.lowercased())\n"
        .utf8)
  }

  /// Use the staged pack on the destination filesystem. A source on another
  /// filesystem is supplied through the single accounted installation slot.
  mutating func install(
    from staging: WorktreeDirectory, into packDirectory: WorktreeDirectory,
    format: WorktreeObjectFormat, io: WorktreeJournalIO, deadline: ContinuousClock.Instant,
    verify: () throws -> Void, persist: (Self) throws -> Void
  ) throws {
    try artifact.validate(format: format)
    guard staging.identity == artifact.directory, packDirectory.identity == destination,
      staging.identity.device == destination.device
    else { throw invalidRecoveryMetadata() }
    try verify()
    try persist(self)
    let keep = packName + ".keep"
    let marker = keepBytes
    if let ownedKeep {
      guard try io.read(keep, in: packDirectory, limit: marker.count) == marker,
        try WorktreeRecoveryStageFile.read(keep, in: packDirectory, limit: marker.count)
          == ownedKeep
      else { throw invalidRecoveryMetadata() }
      try io.synchronize(keep, in: packDirectory, expecting: marker)
    } else {
      if try !packDirectory.hasEntry(keep) {
        try io.write(marker, name: keep, in: packDirectory, replacing: nil)
      }
      if try io.read(keep, in: packDirectory, limit: 4096) == marker {
        let proof = try WorktreeRecoveryStageFile.read(keep, in: packDirectory, limit: marker.count)
        try io.synchronize(keep, in: packDirectory, expecting: marker)
        var next = self
        next.ownedKeep = proof
        try persist(next)
        self = next
      } else {
        throw WorktreeError.busy("An independently owned recovery pack keep is present.")
      }
    }
    for (suffix, file, digest) in [
      (".pack", artifact.pack, artifact.packSHA256),
      (".idx", artifact.index, artifact.indexSHA256),
    ] {
      try verify()
      let pendingName = "objects" + suffix
      let installedName = packName + suffix
      if try !packDirectory.hasEntry(installedName) {
        try Self.verifyFile(
          pendingName, in: staging, expected: file, digest: digest, requireInode: true,
          deadline: deadline)
        try io.beforePublication()
        try verify()
        try staging.verify()
        try packDirectory.verify()
        guard
          try WorktreeRecoveryStageFile.read(pendingName, in: staging, limit: file.bytes) == file
        else { throw invalidRecoveryMetadata() }
        #if canImport(Darwin)
          let result = renameatx_np(
            staging.descriptor, pendingName, packDirectory.descriptor, installedName,
            UInt32(RENAME_EXCL))
        #elseif canImport(Glibc)
          let result = LinuxSystemCalls.renameExclusive(
            staging.descriptor, pendingName, packDirectory.descriptor, installedName)
        #endif
        // A concurrent install may reuse precisely the same immutable bytes.
        guard result == 0 || errno == EEXIST else { throw WorktreeDirectory.posixError() }
      }
      let stagedStillExists = try staging.hasEntry(pendingName)
      try Self.verifyFile(
        installedName, in: packDirectory, expected: file, digest: digest,
        requireInode: !stagedStillExists, deadline: deadline)
      try io.beforeDirectorySync()
      try packDirectory.synchronize()
      try staging.synchronize()
    }
    try verify()
  }

  func synchronizeInstalled(
    in directory: WorktreeDirectory, format: WorktreeObjectFormat, io: WorktreeJournalIO,
    deadline: ContinuousClock.Instant
  ) throws {
    try artifact.validate(format: format)
    guard directory.identity == destination else { throw invalidRecoveryMetadata() }
    try Self.verifyFile(
      packName + ".pack", in: directory, expected: artifact.pack, digest: artifact.packSHA256,
      requireInode: false, deadline: deadline)
    try Self.verifyFile(
      packName + ".idx", in: directory, expected: artifact.index, digest: artifact.indexSHA256,
      requireInode: false, deadline: deadline)
    try io.beforeDirectorySync()
    try directory.synchronize()
  }

  /// Only a terminal lifecycle outcome authorizes retiring this operation's keep.
  func releaseKeep(in directory: WorktreeDirectory, io: WorktreeJournalIO) throws {
    guard directory.identity == destination else { throw invalidRecoveryMetadata() }
    guard let ownedKeep else { return }
    let name = packName + ".keep"
    if try directory.hasEntry(name) {
      guard
        try WorktreeRecoveryStageFile.read(name, in: directory, limit: keepBytes.count) == ownedKeep
      else { throw invalidRecoveryMetadata() }
      try io.remove(name, in: directory, expecting: keepBytes)
    }
    try io.beforeDirectorySync()
    try directory.synchronize()
  }

  private static func verifyFile(
    _ name: String, in directory: WorktreeDirectory, expected: WorktreeRecoveryStageFile,
    digest: String, requireInode: Bool, deadline: ContinuousClock.Instant
  ) throws {
    try directory.verify()
    let fd = openat(directory.descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw WorktreeDirectory.posixError() }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    let found = try WorktreeRecoveryStageFile.read(
      name, in: directory, limit: expected.bytes, opened: handle)
    guard found.bytes == expected.bytes, !requireInode || found == expected
    else { throw invalidRecoveryMetadata() }
    var remaining = found.bytes
    var hash = SHA256()
    while remaining > 0 {
      try Task.checkCancellation()
      guard ContinuousClock.now < deadline else {
        throw WorktreeError.busy("Recovery pack installation exceeded its deadline.")
      }
      guard let chunk = try handle.read(upToCount: min(remaining, 65_536)), !chunk.isEmpty
      else { throw invalidRecoveryMetadata() }
      hash.update(data: chunk)
      remaining -= chunk.count
    }
    guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest,
      try WorktreeRecoveryStageFile.read(name, in: directory, limit: expected.bytes, opened: handle)
        == found
    else { throw invalidRecoveryMetadata() }
    try handle.synchronize()
  }
}
