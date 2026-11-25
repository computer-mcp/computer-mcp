import CSystemZlib
import Crypto
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

package struct WorktreePromotionLimits: Sendable {
  package var inputBytes = 512 * 1024 * 1024
  package var inflatedBytes = 2 * 1024 * 1024 * 1024
  package var objectBytes = 128 * 1024 * 1024
  package var objectCount = 250_000
  package var duration: Duration = .seconds(120)
  package init() {}

  func validate() throws {
    guard inputBytes > 0, inputBytes < Int.max / 4, inflatedBytes > 0,
      objectBytes > 0, objectBytes < Int.max - 256, objectCount > 0, objectCount < Int.max / 4,
      duration > .zero
    else { throw WorktreeError.invalidRequest("Invalid object promotion bounds.") }
  }

  func validateRecoveryCapture() throws {
    let maximum = Self()
    guard inputBytes <= maximum.inputBytes, inflatedBytes <= maximum.inflatedBytes,
      objectBytes <= maximum.objectBytes, objectCount <= maximum.objectCount,
      duration <= maximum.duration
    else { throw WorktreeError.invalidRequest("Recovery capture limits exceed the host bounds.") }
  }
}

struct WorktreeCopiedObjectFile: Codable, Equatable {
  let name: String
  let device: Int64
  let inode: UInt64
  let bytes: Int
  let digest: String
}

struct WorktreeObjectBudget {
  let limits: WorktreePromotionLimits
  let deadline: ContinuousClock.Instant
  var input = 0
  var inflated = 0
  var objects = 0
  private var files = 0

  var remainingInflated: Int { limits.inflatedBytes - inflated }
  var remainingInput: Int { limits.inputBytes - input }

  init(_ limits: WorktreePromotionLimits, deadline: ContinuousClock.Instant? = nil) throws {
    try limits.validate()
    self.limits = limits
    self.deadline = deadline ?? .now.advanced(by: limits.duration)
  }

  func check() throws {
    try Task.checkCancellation()
    guard ContinuousClock.now < deadline else {
      throw WorktreeError.busy("Object verification deadline exceeded.")
    }
  }

  mutating func object(_ size: Int) throws {
    try check()
    guard size >= 0, size <= limits.objectBytes, objects < limits.objectCount,
      size <= remainingInflated
    else { throw WorktreeError.busy("Object verification exceeds its inflated bounds.") }
    objects += 1
    inflated += size
  }

  mutating func acquireFile() throws {
    try check()
    guard files < limits.objectCount * 2 else {
      throw WorktreeError.busy("Object acquisition exceeds its file inventory bound.")
    }
    files += 1
  }
}

extension WorktreeDirectory {
  func entries(limit: Int) throws -> [String] {
    try verify()
    let duplicate = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard duplicate >= 0 else { throw Self.posixError() }
    guard let stream = fdopendir(duplicate) else {
      close(duplicate)
      throw Self.posixError()
    }
    defer { closedir(stream) }
    var names: [String] = []
    while true {
      errno = 0
      guard let entry = readdir(stream) else {
        guard errno == 0 else { throw Self.posixError() }
        break
      }
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
      }
      if name == "." || name == ".." { continue }
      guard names.count < limit else {
        throw WorktreeError.busy("Object inventory exceeds its bound.")
      }
      names.append(name)
    }
    try verify()
    return names.sorted()
  }
}

/// Copies bytes, never links, from identity-checked regular files. No Git command
/// opens the private object pool: all parsers consume only the exclusive copy.
struct WorktreeObjectSnapshot {
  let io: WorktreeJournalIO
  let format: WorktreeObjectFormat

  func copy(
    from source: WorktreeDirectory, to destination: WorktreeDirectory,
    budget: inout WorktreeObjectBudget, clone: Bool = false, allowLinkedInput: Bool = false
  ) throws -> [WorktreeCopiedObjectFile] {
    var result: [WorktreeCopiedObjectFile] = []
    for name in try source.entries(limit: 258) {
      try budget.check()
      if name == "info" {
        let info = try source.child(name)
        // Commit graphs are acceleration data only; alternate pools change authority.
        for entry in try info.entries(limit: budget.limits.objectCount) {
          guard ["commit-graph", "commit-graphs", "packs"].contains(entry) else {
            throw WorktreeError.busy("Unsupported private object control data.")
          }
        }
        continue
      }
      let isPack = name == "pack"
      guard isPack || (name.count == 2 && name.utf8.allSatisfy(Self.hex)) else {
        throw WorktreeError.busy("Invalid private object directory.")
      }
      let input = try source.child(name)
      let output = try destination.child(name, create: true, exclusive: true)
      for entry in try input.entries(limit: budget.limits.objectCount * 4) {
        try budget.check()
        guard result.count < budget.limits.objectCount * 2 else {
          throw WorktreeError.busy("Private object file inventory exceeds its bound.")
        }
        if isPack {
          if ["multi-pack-index", "multi-pack-index.d"].contains(entry) { continue }
          let pieces = entry.split(separator: ".", omittingEmptySubsequences: false)
          guard pieces.count == 2, pieces[0].hasPrefix("pack-"),
            format.contains(String(pieces[0].dropFirst(5))),
            ["pack", "idx", "rev", "bitmap", "keep", "mtimes"].contains(String(pieces[1]))
          else { throw WorktreeError.busy("Unsupported private pack entry.") }
          if !["pack", "idx"].contains(String(pieces[1])) { continue }
        } else {
          guard format.contains(name + entry) else {
            throw WorktreeError.busy("Invalid loose object filename.")
          }
        }
        try budget.acquireFile()
        let file = try copyFile(
          entry, from: input, to: output, relative: name + "/" + entry, budget: &budget,
          clone: clone, allowLinkedInput: clone || allowLinkedInput)
        result.append(file)
      }
    }
    return result
  }

  private func copyFile(
    _ name: String, from source: WorktreeDirectory, to destination: WorktreeDirectory,
    relative: String, budget: inout WorktreeObjectBudget, clone: Bool, allowLinkedInput: Bool
  ) throws -> WorktreeCopiedObjectFile {
    try source.verify()
    let fd = openat(source.descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw WorktreeError.busy("Private object disappeared or changed.") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    var before = stat()
    guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
      allowLinkedInput || before.st_nlink == 1, before.st_size >= 0,
      before.st_size <= budget.remainingInput
    else {
      throw WorktreeError.busy("Private object is linked, special or exceeds its byte bound.")
    }
    let data = try handle.read(upToCount: Int(before.st_size)) ?? Data()
    var after = stat()
    var named = stat()
    guard data.count == before.st_size, fstat(fd, &after) == 0,
      fstatat(source.descriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
      after.st_dev == before.st_dev, after.st_ino == before.st_ino,
      named.st_dev == before.st_dev, named.st_ino == before.st_ino,
      named.st_mode & S_IFMT == S_IFREG, allowLinkedInput || after.st_nlink == 1,
      after.st_size == before.st_size, Self.sameModification(before, after),
      Self.sameModification(after, named)
    else { throw WorktreeError.busy("Private object changed during capture.") }
    try budget.check()
    budget.input += data.count
    var cloned = false
    #if canImport(Darwin)
      if clone {
        try destination.verify()
        if fclonefileat(fd, destination.descriptor, name, 0) == 0 {
          cloned = true
          guard try io.read(name, in: destination, limit: data.count, synchronize: true) == data
          else {
            throw WorktreeError.busy("Source changed during object clone.")
          }
          try destination.synchronize()
        } else if ![EXDEV, ENOTSUP, EINVAL, ENOSYS].contains(errno) {
          throw WorktreeError.busy("Object clone failed.")
        }
      }
    #endif
    if !cloned { try io.write(data, name: name, in: destination, replacing: nil) }
    try source.verify()
    return .init(
      name: relative, device: Int64(before.st_dev), inode: UInt64(before.st_ino),
      bytes: data.count, digest: Self.digest(data))
  }

  func validateRaw(
    _ files: [WorktreeCopiedObjectFile], in directory: WorktreeDirectory,
    budget: inout WorktreeObjectBudget, reportInvalidImport: Bool = false
  ) throws {
    do {
      try validateFiles(files, in: directory, budget: &budget)
    } catch let failure as InvalidImport {
      if reportInvalidImport {
        throw WorktreeError.invalidRequest(failure.message)
      }
      throw WorktreeError.busy(failure.message)
    }
  }

  private struct InvalidImport: Error {
    let message: String
    init(_ message: String) { self.message = message }
  }

  private func validateFiles(
    _ files: [WorktreeCopiedObjectFile], in directory: WorktreeDirectory,
    budget: inout WorktreeObjectBudget
  ) throws {
    let names = Set(files.map(\.name))
    for file in files {
      try budget.check()
      let parts = file.name.split(separator: "/").map(String.init)
      guard parts.count == 2,
        let data = try io.read(parts[1], in: directory.child(parts[0]), limit: file.bytes),
        data.count == file.bytes, Self.digest(data) == file.digest
      else { throw WorktreeError.recoveryRequired("Staged object bytes changed.") }
      if parts[0] == "pack" {
        if parts[1].hasSuffix(".idx") {
          guard names.contains(String(file.name.dropLast(4)) + ".pack") else {
            throw WorktreeError.busy("Pack index has no corresponding pack.")
          }
          continue
        }
        guard names.contains(String(file.name.dropLast(5)) + ".idx") else {
          throw WorktreeError.busy("Private pack has no corresponding index.")
        }
        _ = try validatePack(data, name: parts[1], budget: &budget)
      } else {
        let limit = min(budget.limits.objectBytes, budget.remainingInflated) + 128
        let inflated = try inflate(data, at: 0, limit: limit)
        guard inflated.consumed == data.count,
          let zero = inflated.prefix.firstIndex(of: 0),
          let header = String(data: inflated.prefix[..<zero], encoding: .utf8)
        else { throw InvalidImport("Invalid loose object stream.") }
        let fields = header.split(separator: " ")
        guard fields.count == 2, ["blob", "tree", "commit", "tag"].contains(fields[0]),
          let size = Int(fields[1]), size == inflated.produced - zero - 1
        else { throw InvalidImport("Invalid loose object header.") }
        try budget.object(size)
      }
    }
  }

  func verifyGeneratedPack(
    _ data: Data, manifest: WorktreeObjectManifest, deadline: ContinuousClock.Instant
  ) throws -> String {
    var verification = try WorktreeObjectBudget(.init(), deadline: deadline)
    do {
      return try validatePack(data, name: nil, budget: &verification, expected: manifest)
    } catch let failure as InvalidImport {
      throw WorktreeError.invalidRequest(failure.message)
    }
  }

  private func validatePack(
    _ data: Data, name: String?, budget: inout WorktreeObjectBudget,
    expected: WorktreeObjectManifest? = nil
  ) throws -> String {
    let hashBytes = format.hexCount / 2
    guard data.count >= 12 + hashBytes, data.prefix(4) == Data("PACK".utf8),
      [2, 3].contains(Self.bigEndian(data, at: 4))
    else { throw InvalidImport("Invalid pack header.") }
    let count = Self.bigEndian(data, at: 8)
    guard count <= budget.limits.objectCount - budget.objects
    else { throw WorktreeError.busy("Pack exceeds the remaining object count.") }
    if let expected, count != expected.entries.count {
      throw InvalidImport("Generated pack object count differs from the manifest.")
    }
    var expectedSizes: [WorktreeObjectManifest.Entry: Int] = [:]
    if let expected {
      for entry in expected.entries.values { expectedSizes[entry, default: 0] += 1 }
    }
    let content = data.dropLast(hashBytes)
    let digest =
      format == .sha1
      ? Array(Insecure.SHA1.hash(data: content)) : Array(SHA256.hash(data: content))
    let hex = digest.map({ String(format: "%02x", $0) }).joined()
    guard data.suffix(hashBytes) == Data(digest), name == nil || name == "pack-" + hex + ".pack"
    else { throw InvalidImport("Pack digest does not match its content and name.") }
    var offset = 12
    for _ in 0..<count {
      try budget.check()
      guard offset < content.count else { throw InvalidImport("Truncated pack.") }
      var byte = data[offset]
      offset += 1
      let type = (byte >> 4) & 7
      var size = Int(byte & 15)
      var shift = 4
      while byte & 128 != 0 {
        guard offset < content.count, shift < 56 else {
          throw InvalidImport("Invalid pack object length.")
        }
        byte = data[offset]
        offset += 1
        size |= Int(byte & 127) << shift
        shift += 7
      }
      guard [1, 2, 3, 4, 6, 7].contains(type) else {
        throw InvalidImport("Invalid pack object type.")
      }
      if expected != nil {
        let kinds: [UInt8: WorktreeRecoveryRecord.ObjectType] = [
          1: .commit, 2: .tree, 3: .blob, 4: .tag,
        ]
        guard let kind = kinds[type] else {
          throw InvalidImport("Generated pack contains a delta.")
        }
        let entry = WorktreeObjectManifest.Entry(type: kind, size: size)
        guard let remaining = expectedSizes[entry], remaining > 0 else {
          throw InvalidImport("Generated pack object type or size differs from the manifest.")
        }
        expectedSizes[entry] = remaining - 1
      }
      let limit = min(budget.limits.objectBytes, budget.remainingInflated)
      guard size <= limit else { throw WorktreeError.busy("Pack object exceeds its size bound.") }
      if type == 6 {
        repeat {
          guard offset < content.count else { throw InvalidImport("Truncated delta base.") }
          byte = data[offset]
          offset += 1
        } while byte & 128 != 0
      } else if type == 7 {
        offset += hashBytes
      }
      let stream = try inflate(data, at: offset, limit: size)
      guard stream.produced == size else { throw InvalidImport("Pack object size mismatch.") }
      offset += stream.consumed
      if type == 6 || type == 7 {
        var cursor = 0
        let baseSize = try Self.deltaSize(stream.prefix, cursor: &cursor)
        let resultSize = try Self.deltaSize(stream.prefix, cursor: &cursor)
        guard baseSize <= budget.limits.objectBytes else {
          throw WorktreeError.busy("Delta base exceeds its inflated bound.")
        }
        try budget.object(max(size, resultSize))
      } else {
        try budget.object(size)
      }
    }
    guard offset == content.count else {
      throw InvalidImport("Unexpected pack trailing data.")
    }
    try budget.check()
    return hex
  }

  private func inflate(_ data: Data, at offset: Int, limit: Int) throws
    -> (consumed: Int, produced: Int, prefix: Data)
  {
    guard offset < data.count else { throw InvalidImport("Truncated compressed object.") }
    var prefix = [UInt8](repeating: 0, count: 128)
    var consumed = 0
    var produced = 0
    let status = data.withUnsafeBytes { bytes in
      cmcp_inflate_bounded(
        bytes.bindMemory(to: UInt8.self).baseAddress! + offset, data.count - offset, limit,
        &prefix, prefix.count, &consumed, &produced)
    }
    guard status == 0 else { throw InvalidImport("Invalid or excessive compressed object.") }
    return (consumed, produced, Data(prefix.prefix(min(produced, prefix.count))))
  }

  private static func deltaSize(_ bytes: Data, cursor: inout Int) throws -> Int {
    var value = 0
    var shift = 0
    while cursor < bytes.count, shift < 56 {
      let byte = bytes[cursor]
      cursor += 1
      value |= Int(byte & 127) << shift
      if byte & 128 == 0 { return value }
      shift += 7
    }
    throw InvalidImport("Invalid delta size.")
  }

  private static func sameModification(_ first: stat, _ second: stat) -> Bool {
    #if canImport(Darwin)
      let firstModified = first.st_mtimespec
      let secondModified = second.st_mtimespec
      let firstChanged = first.st_ctimespec
      let secondChanged = second.st_ctimespec
    #else
      let firstModified = first.st_mtim
      let secondModified = second.st_mtim
      let firstChanged = first.st_ctim
      let secondChanged = second.st_ctim
    #endif
    return firstModified.tv_sec == secondModified.tv_sec
      && firstModified.tv_nsec == secondModified.tv_nsec
      && firstChanged.tv_sec == secondChanged.tv_sec
      && firstChanged.tv_nsec == secondChanged.tv_nsec
  }

  private static func bigEndian(_ data: Data, at offset: Int) -> Int {
    data[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
  }

  static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func hex(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (97...102).contains(byte)
  }
}

struct WorktreeObjectManifest: Equatable {
  struct Entry: Codable, Hashable {
    let type: WorktreeRecoveryRecord.ObjectType
    let size: Int
  }

  let entries: [String: Entry]
  var oids: [String] { entries.keys.sorted() }

  func union(_ other: Self) throws -> Self {
    var combined = entries
    for (oid, entry) in other.entries {
      if let previous = combined.updateValue(entry, forKey: oid), previous != entry {
        throw WorktreeError.invalidRequest("Object manifests disagree about an object identity.")
      }
    }
    return Self(entries: combined)
  }

  func subtracting(_ other: Self) throws -> Self {
    var remaining = entries
    for (oid, entry) in other.entries {
      if let previous = remaining.removeValue(forKey: oid), previous != entry {
        throw WorktreeError.invalidRequest("Object manifests disagree about an object identity.")
      }
    }
    return Self(entries: remaining)
  }
}

struct WorktreeStagedObjects {
  let directory: WorktreeDirectory
  let repository: WorktreeDirectory
  let git: WorktreeGit
  let format: WorktreeObjectFormat
  let deadline: ContinuousClock.Instant
  let limits: WorktreePromotionLimits

  func run(
    _ arguments: [String], input: Data = Data(), outputBytes: Int? = nil,
    fileOutput: WorktreeGitFileOutput? = nil, fileSizeLimit: Int? = nil
  )
    throws -> Data
  {
    try directory.verify()
    try repository.verify()
    let result = try git.run(
      arguments, at: repository.url, gitDirectory: repository.url, objects: directory.url,
      input: input, deadline: deadline, commandOutputBytes: outputBytes,
      fileOutput: fileOutput, fileSizeLimit: fileSizeLimit)
    try directory.verify()
    try repository.verify()
    return result.output
  }

  func verifyIndexes(_ files: [WorktreeCopiedObjectFile]) throws {
    for file in files where file.name.hasSuffix(".idx") {
      try validate(["verify-pack", directory.url.appendingPathComponent(file.name).path])
    }
  }

  func verifyIntegrity() throws {
    try validate(["fsck", "--full", "--strict", "--no-reflogs", "--no-dangling"])
  }

  private func validate(_ arguments: [String]) throws {
    do {
      _ = try run(arguments)
    } catch WorktreeError.commandFailed {
      throw WorktreeError.invalidRequest("Staged object import failed Git integrity verification.")
    }
  }

  /// Nil is an incomplete closure, never permission to fill a private root from another pool.
  func manifest(roots: [String]) throws -> WorktreeObjectManifest? {
    let maxCount = min(limits.objectCount, 250_000)
    guard !roots.isEmpty, roots.count <= maxCount, roots.allSatisfy(validOID)
    else { throw WorktreeError.invalidRequest("Invalid object manifest roots.") }
    let rootsSet = Set(roots)
    guard rootsSet.count == roots.count else {
      throw WorktreeError.invalidRequest("Duplicate object manifest roots.")
    }
    guard try describe(roots) != nil else { return nil }
    let result: Data
    do {
      result = try run(
        ["rev-list", "--objects", "--no-object-names", "--missing=print", "--stdin"],
        input: oidInput(roots), outputBytes: (maxCount + 1) * (format.hexCount + 2))
    } catch WorktreeError.commandFailed {
      throw WorktreeError.invalidRequest("Cannot traverse the imported object closure.")
    }
    let lines = try lines(in: result)
    guard lines.count <= maxCount else {
      throw WorktreeError.busy("Object manifest exceeds its count bound.")
    }
    var oids: Set<String> = []
    var missing = false
    for line in lines {
      try check()
      let oid = String(line.hasPrefix("?") ? line.dropFirst() : line)
      guard validOID(oid), oids.insert(oid).inserted else {
        throw WorktreeError.invalidRequest("Malformed or duplicate object in closure inventory.")
      }
      missing = missing || line.hasPrefix("?")
    }
    guard rootsSet.isSubset(of: oids) else {
      throw WorktreeError.invalidRequest("Closure inventory omitted an original root.")
    }
    guard !missing else { return nil }
    return try describe(oids.sorted())
  }

  private func describe(_ oids: [String]) throws -> WorktreeObjectManifest? {
    let output = try run(
      ["cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)"],
      input: oidInput(oids), outputBytes: oids.count * (format.hexCount + 32))
    let lines = try lines(in: output)
    guard lines.count == oids.count else {
      throw WorktreeError.invalidRequest("Object metadata does not match the closure inventory.")
    }
    var entries: [String: WorktreeObjectManifest.Entry] = [:]
    var total = 0
    var missing = false
    for (oid, line) in zip(oids, lines) {
      try check()
      let fields = line.split(separator: " ", omittingEmptySubsequences: false)
      if fields.count == 2, fields[0] == oid, fields[1] == "missing" {
        missing = true
        continue
      }
      guard fields.count == 3, fields[0] == oid,
        let type = WorktreeRecoveryRecord.ObjectType(rawValue: String(fields[1])),
        let size = Int(fields[2]), size >= 0, size <= limits.objectBytes,
        size <= limits.inflatedBytes - total
      else { throw WorktreeError.invalidRequest("Invalid imported object type or size.") }
      total += size
      entries[oid] = .init(type: type, size: size)
    }
    try check()
    return missing ? nil : WorktreeObjectManifest(entries: entries)
  }

  private func validOID(_ value: String) -> Bool {
    format.contains(value) && value.utf8.contains { $0 != 48 }
  }

  private func oidInput(_ oids: [String]) -> Data {
    Data((oids.joined(separator: "\n") + "\n").utf8)
  }

  private func lines(in data: Data) throws -> [Substring] {
    guard data.last == 10, let text = String(data: data, encoding: .utf8) else {
      throw WorktreeError.invalidRequest("Invalid Git object inventory output.")
    }
    return text.dropLast().split(separator: "\n", omittingEmptySubsequences: false)
  }

  private func check() throws {
    try Task.checkCancellation()
    guard ContinuousClock.now < deadline else {
      throw WorktreeError.busy("Object verification deadline exceeded.")
    }
  }
}
