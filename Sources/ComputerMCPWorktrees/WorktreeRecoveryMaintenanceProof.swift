import Crypto
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

struct WorktreeRecoveryPackPair: Codable, Equatable, Sendable {
  struct File: Codable, Equatable, Sendable {
    let device: Int64
    let inode: UInt64
    let length: Int
    let digest: String
    let allocatedBytes: Int64

    func validate(limit: Int, directory: WorktreeDirectoryIdentity) throws {
      guard device == directory.device, inode != 0, (1...limit).contains(length),
        digest.isRecoveryDigest, allocatedBytes >= 0, allocatedBytes % 512 == 0
      else { throw invalidRecoveryMetadata() }
    }
  }

  let hash: String
  let pack: File
  let index: File

  func validate(format: WorktreeObjectFormat, directory: WorktreeDirectoryIdentity) throws {
    let maximum = try WorktreePackBounds.maximum(format: format)
    guard format.contains(hash), pack.inode != index.inode else { throw invalidRecoveryMetadata() }
    try pack.validate(limit: maximum.packBytes, directory: directory)
    try index.validate(limit: maximum.indexBytes, directory: directory)
  }

  var packName: String { "pack-" + hash + ".pack" }
  var indexName: String { "pack-" + hash + ".idx" }
}

struct WorktreeRecoveryMaintenanceProof: Codable, Equatable, Sendable {
  let catalogDigest: String
  let inventoryDigest: String
  let survivingInventoryDigest: String
  let closureDigest: String
  let parent: WorktreeDirectoryIdentity?
  let candidate: WorktreeRecoveryPackPair?
  let allocatedBytes: Int64

  func validate(format: WorktreeObjectFormat) throws {
    guard
      [catalogDigest, inventoryDigest, survivingInventoryDigest, closureDigest].allSatisfy(
        \.isRecoveryDigest),
      allocatedBytes >= 0, allocatedBytes % 512 == 0
    else { throw invalidRecoveryMetadata() }
    if let candidate {
      guard let parent else { throw invalidRecoveryMetadata() }
      try candidate.validate(format: format, directory: parent)
      let candidateBytes = try checkedAllocation(
        candidate.pack.allocatedBytes, candidate.index.allocatedBytes)
      guard candidateBytes <= allocatedBytes else { throw invalidRecoveryMetadata() }
    } else if inventoryDigest != survivingInventoryDigest {
      throw invalidRecoveryMetadata()
    }
  }
}

final class WorktreeMaintenanceBudget {
  private(set) var objects: WorktreeObjectBudget
  private var commandBytes: Int
  let maximum: WorktreePackBounds

  init(
    limits: WorktreePromotionLimits, format: WorktreeObjectFormat, deadline: ContinuousClock.Instant
  ) throws {
    objects = try .init(limits, deadline: deadline)
    maximum = try .maximum(format: format)
    // Raw output has one payload per object. The allowance for framing
    // covers both inventory and traversal, plus Git diagnostics per call.
    commandBytes = try WorktreePackBounds.sum(
      limits.inflatedBytes, limits.objectCount * (format.hexCount + 256) * 8,
      WorktreeRecoveryCatalog.byteLimit)
  }

  var limits: WorktreePromotionLimits { objects.limits }
  var deadline: ContinuousClock.Instant { objects.deadline }

  func check() throws { try objects.check() }

  func chargeFile(bytes: Int) throws {
    try objects.acquireFile()
    guard bytes >= 0, bytes <= objects.remainingInput else {
      throw WorktreeError.busy("Recovery inventory exceeds its aggregate input bound.")
    }
    objects.input += bytes
  }

  func verifyPack(_ data: Data, name: String, snapshot: WorktreeObjectSnapshot) throws -> Int {
    let previous = objects.objects
    try snapshot.verifyInstalledPack(data, name: name, budget: &objects)
    return objects.objects - previous
  }

  func run(
    _ git: WorktreeGit, arguments: [String], repository: WorktreeDirectory,
    objects: WorktreeDirectory,
    input: Data, outputBytes: Int
  ) throws -> Data {
    try check()
    // The adapter independently bounds stdout and stderr.
    let needed = try WorktreePackBounds.sum(input.count, outputBytes, outputBytes)
    guard needed <= commandBytes else {
      throw WorktreeError.busy("Recovery proof exceeds its subprocess byte bound.")
    }
    commandBytes -= input.count
    let result = try git.runInRecoveryStore(
      arguments, repository: repository, objects: objects, input: input, deadline: deadline,
      outputBytes: outputBytes)
    commandBytes -= try WorktreePackBounds.sum(result.output.count, result.error.count)
    return result.output
  }
}

struct WorktreeRecoveryPackInventory {
  let pairs: [WorktreeRecoveryPackPair]
  let contents: [[String: WorktreeObjectManifest.Entry]]
  let allocatedBytes: Int64

  func digest(excluding hash: String? = nil) throws -> String {
    try WorktreeObjectSnapshot.digest(recoveryJSON(pairs.filter { $0.hash != hash }))
  }

  func candidate(for manifest: WorktreeObjectManifest) throws -> WorktreeRecoveryPackPair? {
    var counts: [String: Int] = [:]
    for inventory in contents {
      for (oid, entry) in inventory {
        guard let required = manifest.entries[oid] else { continue }
        guard entry == required else { throw invalidRecoveryMetadata() }
        counts[oid, default: 0] += 1
      }
    }
    guard counts.count == manifest.entries.count else { throw invalidRecoveryMetadata() }
    return zip(pairs, contents).first { _, inventory in
      !inventory.keys.contains { counts[$0] == 1 }
    }?.0
  }
}

extension WorktreeRecoveryStore.Locked {
  func maintenanceNamespace() throws -> WorktreeDirectory? {
    try checkIdentity()
    try validateAnchorContents(for: observedCatalog().catalog)
    guard try stagingDirectory.entries(limit: 0).isEmpty,
      try gitDirectory.entries(limit: 4) == ["HEAD", "config", "objects", "refs"],
      try Set(objectsDirectory.entries(limit: 2)).isSubset(of: ["pack", "info"])
    else { throw WorktreeError.busy("Recovery store has an unsettled or unsupported layout.") }
    if let info = try objectsDirectory.childIfPresent("info") {
      _ = try info.entries(limit: 0)
    }
    return try objectsDirectory.childIfPresent("pack")
  }

  func packInventory(
    _ parent: WorktreeDirectory?, pool: WorktreeStagedObjects?, budget: WorktreeMaintenanceBudget,
    quarantined: Set<String> = []
  ) throws -> WorktreeRecoveryPackInventory {
    guard let parent else { return .init(pairs: [], contents: [], allocatedBytes: 0) }
    let names = try Set(
      parent.entries(limit: min(budget.limits.objectCount * 2, WorktreeRecoveryCatalog.recordLimit))
    )
    guard quarantined.isSubset(of: names) else { throw invalidRecoveryMetadata() }
    let installed = names.subtracting(quarantined)
    let hashes = installed.filter { $0.hasSuffix(".pack") }.sorted()
    guard installed.count == hashes.count * 2 else {
      throw WorktreeError.busy("Recovery pack inventory is unsettled.")
    }
    let snapshot = WorktreeObjectSnapshot(io: journalIO, format: repository.format)
    var pairs: [WorktreeRecoveryPackPair] = []
    var inventories: [[String: WorktreeObjectManifest.Entry]] = []
    var allocation: Int64 = 0
    var inodes: Set<UInt64> = []
    for packName in hashes {
      try budget.check()
      guard packName.hasPrefix("pack-") else { throw invalidRecoveryMetadata() }
      let hash = String(packName.dropFirst(5).dropLast(5))
      let indexName = "pack-" + hash + ".idx"
      guard repository.format.contains(hash), installed.contains(indexName) else {
        throw invalidRecoveryMetadata()
      }
      var count = 0
      let pack = try packFile(packName, in: parent, limit: budget.maximum.packBytes, budget: budget)
      { bytes in
        if pool != nil { count = try budget.verifyPack(bytes, name: packName, snapshot: snapshot) }
      }
      let index = try packFile(
        indexName, in: parent, limit: budget.maximum.indexBytes, budget: budget
      ) { bytes in
        if pool != nil { try verifyIndexTrailer(bytes, hash: hash, format: repository.format) }
      }
      for file in [pack, index] {
        guard file.device == parent.identity.device, inodes.insert(file.inode).inserted
        else { throw invalidRecoveryMetadata() }
        allocation = try checkedAllocation(allocation, file.allocatedBytes)
      }
      pairs.append(.init(hash: hash, pack: pack, index: index))
      if let pool {
        let url = parent.url.appendingPathComponent(indexName)
        inventories.append(try pool.packEntries(index: url, count: count))
        try requirePackFile(pack, named: packName, in: parent)
        try requirePackFile(index, named: indexName, in: parent)
      }
    }
    try parent.verify()
    guard try Set(parent.entries(limit: names.count)) == names else {
      throw invalidRecoveryMetadata()
    }
    return .init(pairs: pairs, contents: inventories, allocatedBytes: allocation)
  }

  func maintenanceClosure(
    _ catalog: WorktreeRecoveryCatalog, pool: WorktreeStagedObjects
  ) throws -> (manifest: WorktreeObjectManifest, digest: String) {
    struct Closure: Encodable {
      let roots: [String: WorktreeRecoveryRecord.ObjectType]
      let objects: [String: WorktreeObjectManifest.Entry]
    }
    var roots: [String: WorktreeRecoveryRecord.ObjectType] = [:]
    for record in catalog.records {
      if let previous = roots.updateValue(record.objectType, forKey: record.oid),
        previous != record.objectType
      {
        throw invalidRecoveryMetadata()
      }
    }
    guard roots.count <= pool.limits.objectCount else {
      throw WorktreeError.busy("Recovery roots exceed the union traversal bound.")
    }
    let manifest: WorktreeObjectManifest
    if roots.isEmpty {
      manifest = .init(entries: [:])
    } else {
      guard let observed = try pool.manifest(roots: roots.keys.sorted()),
        roots.allSatisfy({ observed.entries[$0.key]?.type == $0.value })
      else { throw invalidRecoveryMetadata() }
      manifest = observed
      try pool.verifyRawObjects(manifest)
    }
    let proof = Closure(roots: roots, objects: manifest.entries)
    return (manifest, try WorktreeObjectSnapshot.digest(recoveryJSON(proof)))
  }
}

extension WorktreeStagedObjects {
  fileprivate func verifyRawObjects(_ manifest: WorktreeObjectManifest) throws {
    let batchTarget = 4 * 1024 * 1024
    let ordered = manifest.entries.sorted { $0.key < $1.key }
    var start = ordered.startIndex
    while start < ordered.endIndex {
      try maintenanceBudget?.check()
      var end = start
      var bytes = 0
      while end < ordered.endIndex {
        let entry = ordered[end]
        let frame = try WorktreePackBounds.sum(
          entry.key.utf8.count, entry.value.type.rawValue.utf8.count,
          String(entry.value.size).utf8.count, entry.value.size, 4)
        if end > start && frame > batchTarget - bytes { break }
        bytes = try WorktreePackBounds.sum(bytes, frame)
        end += 1
      }
      let batch = ordered[start..<end]
      let input = Data((batch.map(\.key).joined(separator: "\n") + "\n").utf8)
      let output = try run(["cat-file", "--batch"], input: input, outputBytes: bytes)
      var offset = 0
      for (oid, entry) in batch {
        try maintenanceBudget?.check()
        let description = "\(entry.type.rawValue) \(entry.size)"
        let header = Data("\(oid) \(description)\n".utf8)
        let payloadStart = offset + header.count
        let payloadEnd = payloadStart + entry.size
        guard payloadEnd < output.count, output[offset..<payloadStart] == header,
          output[payloadEnd] == 10
        else { throw invalidRecoveryMetadata() }
        let canonicalHeader = Data((description + "\0").utf8)
        let payload = output[payloadStart..<payloadEnd]
        let digest: [UInt8]
        switch format {
        case .sha1:
          var hash = Insecure.SHA1()
          hash.update(data: canonicalHeader)
          hash.update(data: payload)
          digest = Array(hash.finalize())
        case .sha256:
          var hash = SHA256()
          hash.update(data: canonicalHeader)
          hash.update(data: payload)
          digest = Array(hash.finalize())
        }
        guard digest.map({ String(format: "%02x", $0) }).joined() == oid else {
          throw WorktreeError.recoveryRequired("Recovery object payload does not match its Git ID.")
        }
        offset = payloadEnd + 1
      }
      guard offset == output.count else { throw invalidRecoveryMetadata() }
      start = end
    }
  }
}

func packFile(
  _ name: String, in directory: WorktreeDirectory, limit: Int,
  budget: WorktreeMaintenanceBudget? = nil,
  verify: (Data) throws -> Void = { _ in }
) throws -> WorktreeRecoveryPackPair.File {
  try WorktreeDirectory.requireName(name)
  try directory.verify()
  let fd = openat(directory.descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
  guard fd >= 0 else { throw WorktreeDirectory.posixError() }
  defer { close(fd) }
  var status = stat()
  guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1,
    let length = Int(exactly: status.st_size), length > 0, length <= limit,
    let blocks = Int64(exactly: status.st_blocks), blocks >= 0
  else { throw invalidRecoveryMetadata() }
  try budget?.chargeFile(bytes: length)
  let (allocated, overflow) = blocks.multipliedReportingOverflow(by: 512)
  guard !overflow else { throw invalidRecoveryMetadata() }
  // Read through the descriptor with a fixed bound so concurrent truncation
  // registers as a short read even for a substituted pack.
  let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
  let bytes = try handle.read(upToCount: length + 1) ?? Data()
  guard bytes.count == length else { throw invalidRecoveryMetadata() }
  try verify(bytes)
  let file = WorktreeRecoveryPackPair.File(
    device: Int64(status.st_dev), inode: UInt64(status.st_ino), length: length,
    digest: WorktreeObjectSnapshot.digest(bytes), allocatedBytes: allocated)
  try requirePackFile(file, named: name, in: directory)
  try budget?.check()
  return file
}

func requirePackFile(
  _ file: WorktreeRecoveryPackPair.File, named name: String, in directory: WorktreeDirectory
) throws {
  try directory.verify()
  var current = stat()
  guard fstatat(directory.descriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
    current.st_mode & S_IFMT == S_IFREG, current.st_nlink == 1,
    Int64(current.st_dev) == file.device, UInt64(current.st_ino) == file.inode,
    current.st_size == file.length, Int64(current.st_blocks) == file.allocatedBytes / 512
  else { throw invalidRecoveryMetadata() }
}

private func verifyIndexTrailer(_ data: Data, hash: String, format: WorktreeObjectFormat) throws {
  let width = format.hexCount / 2
  guard data.count >= 8 + 1024 + 2 * width,
    data.prefix(8) == Data([255, 116, 79, 99, 0, 0, 0, 2]),
    data.suffix(2 * width).prefix(width).map({ String(format: "%02x", $0) }).joined() == hash
  else { throw invalidRecoveryMetadata() }
  let content = data.dropLast(width)
  let digest =
    format == .sha1 ? Array(Insecure.SHA1.hash(data: content)) : Array(SHA256.hash(data: content))
  guard data.suffix(width) == Data(digest) else { throw invalidRecoveryMetadata() }
}

func checkedAllocation(_ first: Int64, _ second: Int64) throws -> Int64 {
  let (sum, overflow) = first.addingReportingOverflow(second)
  guard first >= 0, second >= 0, !overflow else { throw invalidRecoveryMetadata() }
  return sum
}
