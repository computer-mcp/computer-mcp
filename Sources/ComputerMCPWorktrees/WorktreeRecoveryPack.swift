import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

struct WorktreeRecoveryPack {
  let directory: WorktreeDirectory
  let hash: String
  let pack: WorktreeRecoveryStageFile
  let index: WorktreeRecoveryStageFile
  let packSHA256: String
  let indexSHA256: String
}

struct WorktreeRecoveryStageFile: Codable, Equatable {
  let bytes: Int
  let device: Int64
  let inode: UInt64

  static func read(
    _ name: String, in directory: WorktreeDirectory, limit: Int, opened: FileHandle? = nil
  ) throws -> Self {
    try directory.verify()
    var named = stat()
    guard fstatat(directory.descriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
      named.st_mode & S_IFMT == S_IFREG, named.st_nlink == 1,
      let bytes = Int(exactly: named.st_size), bytes >= 0, bytes <= limit
    else { throw invalidRecoveryMetadata() }
    if let opened {
      var status = stat()
      guard fstat(opened.fileDescriptor, &status) == 0, status.st_dev == named.st_dev,
        status.st_ino == named.st_ino, status.st_size == named.st_size
      else { throw invalidRecoveryMetadata() }
    }
    return Self(bytes: bytes, device: Int64(named.st_dev), inode: UInt64(named.st_ino))
  }
}

extension WorktreeStagedObjects {
  func generatePack(
    _ manifest: WorktreeObjectManifest, slot: WorktreeRecoveryStaging.PackSlot,
    staging: WorktreeRecoveryStaging
  ) throws -> WorktreeRecoveryPack {
    let bounds = try WorktreePackBounds.manifest(manifest, format: format)
    let destination = try staging.reservePack(slot, bounds: bounds)
    let packName = "objects.pack"
    let indexName = "objects.idx"
    let packURL = destination.url.appendingPathComponent(packName)
    let indexURL = destination.url.appendingPathComponent(indexName)
    let fd = openat(
      destination.descriptor, packName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw WorktreeDirectory.posixError() }
    let packHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? packHandle.close() }
    let oids = manifest.oids
    let input = oids.isEmpty ? Data() : Data((oids.joined(separator: "\n") + "\n").utf8)
    try staging.verify()
    _ = try run(
      [
        "pack-objects", "--stdout", "--no-reuse-object", "--no-reuse-delta", "--window=0",
        "--threads=1", "--compression=6",
      ], input: input, fileOutput: .init(descriptor: fd, byteLimit: bounds.packBytes))
    try packHandle.synchronize()
    let pack = try WorktreeRecoveryStageFile.read(
      packName, in: destination, limit: bounds.packBytes, opened: packHandle)
    guard pack.bytes > 0, try destination.entries(limit: 2) == [packName] else {
      throw invalidRecoveryMetadata()
    }
    let snapshot = WorktreeObjectSnapshot(io: .init(), format: format)
    let (hash, originalBytesDigest) = try withPackBytes(packHandle, bytes: pack.bytes) { data in
      (
        try snapshot.verifyGeneratedPack(data, manifest: manifest, deadline: deadline),
        WorktreeObjectSnapshot.digest(data)
      )
    }
    try staging.verify()
    guard try !destination.hasEntry(indexName),
      try WorktreeRecoveryStageFile.read(
        packName, in: destination, limit: bounds.packBytes, opened: packHandle) == pack
    else { throw invalidRecoveryMetadata() }
    try staging.armIndex(slot)
    _ = try run(
      [
        "index-pack", "--strict", "--index-version=2", "--no-rev-index", "-o", indexURL.path,
        packURL.path,
      ], fileSizeLimit: bounds.indexBytes)
    guard try destination.entries(limit: 2) == [indexName, packName],
      try WorktreeRecoveryStageFile.read(
        packName, in: destination, limit: bounds.packBytes, opened: packHandle) == pack
    else { throw invalidRecoveryMetadata() }

    let indexFD = openat(
      destination.descriptor, indexName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard indexFD >= 0 else { throw WorktreeDirectory.posixError() }
    let indexHandle = FileHandle(fileDescriptor: indexFD, closeOnDealloc: true)
    defer { try? indexHandle.close() }
    let index = try WorktreeRecoveryStageFile.read(
      indexName, in: destination, limit: bounds.indexBytes, opened: indexHandle)
    guard index.bytes > 0 else { throw invalidRecoveryMetadata() }
    let indexDigest = try withPackBytes(
      indexHandle, bytes: index.bytes, WorktreeObjectSnapshot.digest)
    try verifyPackInventory(indexURL, manifest: manifest)
    guard
      try WorktreeRecoveryStageFile.read(
        indexName, in: destination, limit: bounds.indexBytes, opened: indexHandle) == index,
      try withPackBytes(indexHandle, bytes: index.bytes, WorktreeObjectSnapshot.digest)
        == indexDigest,
      try withPackBytes(packHandle, bytes: pack.bytes, WorktreeObjectSnapshot.digest)
        == originalBytesDigest
    else { throw invalidRecoveryMetadata() }
    try indexHandle.synchronize()
    try destination.synchronize()
    try staging.verify()
    return WorktreeRecoveryPack(
      directory: destination, hash: hash, pack: pack, index: index,
      packSHA256: originalBytesDigest, indexSHA256: indexDigest)
  }

  private func withPackBytes<Result>(
    _ handle: FileHandle, bytes: Int, _ body: (Data) throws -> Result
  ) throws -> Result {
    guard let mapping = mmap(nil, bytes, PROT_READ, MAP_PRIVATE, handle.fileDescriptor, 0),
      mapping != MAP_FAILED
    else { throw WorktreeDirectory.posixError() }
    defer { munmap(mapping, bytes) }
    let data = Data(bytesNoCopy: mapping, count: bytes, deallocator: .none)
    return try body(data)
  }

  private func verifyPackInventory(_ index: URL, manifest: WorktreeObjectManifest) throws {
    guard try packEntries(index: index, count: manifest.entries.count) == manifest.entries else {
      throw invalidRecoveryMetadata()
    }
  }

  func packEntries(index: URL, count: Int) throws -> [String: WorktreeObjectManifest.Entry] {
    let limit = try WorktreePackBounds.sum(count * (format.hexCount + 64), 4096)
    let output = try run(["verify-pack", "-v", index.path], outputBytes: limit)
    guard let text = String(data: output, encoding: .utf8), text.hasSuffix("\n"),
      text.hasSuffix(index.deletingPathExtension().appendingPathExtension("pack").path + ": ok\n")
    else { throw invalidRecoveryMetadata() }
    var entries: [String: WorktreeObjectManifest.Entry] = [:]
    for line in text.split(separator: "\n") {
      try Task.checkCancellation()
      guard ContinuousClock.now < deadline else {
        throw WorktreeError.busy("Recovery pack verification deadline exceeded.")
      }
      let fields = line.split(whereSeparator: \.isWhitespace)
      guard let oid = fields.first.map(String.init), format.containsRecoveryOID(oid) else {
        continue
      }
      guard fields.count == 5, entries.count < count,
        let type = WorktreeRecoveryRecord.ObjectType(rawValue: String(fields[1])),
        let size = Int(fields[2]), size >= 0, size <= limits.objectBytes,
        entries.updateValue(.init(type: type, size: size), forKey: oid) == nil
      else { throw invalidRecoveryMetadata() }
    }
    guard entries.count == count else { throw invalidRecoveryMetadata() }
    return entries
  }
}
