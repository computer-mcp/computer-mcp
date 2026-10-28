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

  init(_ limits: WorktreePromotionLimits) throws {
    try limits.validate()
    self.limits = limits
    deadline = .now.advanced(by: limits.duration)
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
      size <= limits.inflatedBytes - inflated
    else { throw WorktreeError.busy("Object verification exceeds its inflated bounds.") }
    objects += 1
    inflated += size
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
    budget: inout WorktreeObjectBudget, clone: Bool = false
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
        let file = try copyFile(
          entry, from: input, to: output, relative: name + "/" + entry, budget: &budget,
          clone: clone)
        result.append(file)
      }
    }
    return result
  }

  private func copyFile(
    _ name: String, from source: WorktreeDirectory, to destination: WorktreeDirectory,
    relative: String, budget: inout WorktreeObjectBudget, clone: Bool
  ) throws -> WorktreeCopiedObjectFile {
    try source.verify()
    let fd = openat(source.descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw WorktreeError.busy("Private object disappeared or changed.") }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    var before = stat()
    guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
      clone || before.st_nlink == 1, before.st_size >= 0,
      before.st_size <= budget.limits.inputBytes - budget.input
    else {
      throw WorktreeError.busy("Private object is linked, special or exceeds its byte bound.")
    }
    let data = try handle.read(upToCount: Int(before.st_size) + 1) ?? Data()
    var after = stat()
    var named = stat()
    guard data.count == before.st_size, fstat(fd, &after) == 0,
      fstatat(source.descriptor, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
      after.st_dev == before.st_dev, after.st_ino == before.st_ino,
      named.st_dev == before.st_dev, named.st_ino == before.st_ino,
      named.st_mode & S_IFMT == S_IFREG, clone || after.st_nlink == 1,
      after.st_size == before.st_size
    else { throw WorktreeError.busy("Private object changed during capture.") }
    // Same-length writes are detected by content verification of this copy.
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
        try validatePack(data, name: parts[1], budget: &budget)
      } else {
        let inflated = try inflate(data, at: 0, limit: budget.limits.objectBytes + 128)
        guard inflated.consumed == data.count,
          let zero = inflated.prefix.firstIndex(of: 0),
          let header = String(data: inflated.prefix[..<zero], encoding: .utf8)
        else { throw WorktreeError.busy("Invalid loose object stream.") }
        let fields = header.split(separator: " ")
        guard fields.count == 2, ["blob", "tree", "commit", "tag"].contains(fields[0]),
          let size = Int(fields[1]), size == inflated.produced - zero - 1
        else { throw WorktreeError.busy("Invalid loose object header.") }
        try budget.object(size)
      }
    }
  }

  private func validatePack(
    _ data: Data, name: String, budget: inout WorktreeObjectBudget
  ) throws {
    let hashBytes = format.hexCount / 2
    guard data.count >= 12 + hashBytes, data.prefix(4) == Data("PACK".utf8),
      [2, 3].contains(Self.bigEndian(data, at: 4)),
      Self.bigEndian(data, at: 8) <= budget.limits.objectCount - budget.objects
    else { throw WorktreeError.busy("Invalid or excessive pack header.") }
    let content = data.dropLast(hashBytes)
    let digest =
      format == .sha1
      ? Array(Insecure.SHA1.hash(data: content)) : Array(SHA256.hash(data: content))
    guard data.suffix(hashBytes) == Data(digest),
      name == "pack-" + digest.map { String(format: "%02x", $0) }.joined() + ".pack"
    else { throw WorktreeError.busy("Pack digest does not match its content and name.") }
    var offset = 12
    for _ in 0..<Self.bigEndian(data, at: 8) {
      try budget.check()
      guard offset < content.count else { throw WorktreeError.busy("Truncated pack.") }
      var byte = data[offset]
      offset += 1
      let type = (byte >> 4) & 7
      var size = Int(byte & 15)
      var shift = 4
      while byte & 128 != 0 {
        guard offset < content.count, shift < 56 else {
          throw WorktreeError.busy("Invalid pack object length.")
        }
        byte = data[offset]
        offset += 1
        size |= Int(byte & 127) << shift
        shift += 7
      }
      guard [1, 2, 3, 4, 6, 7].contains(type), size <= budget.limits.objectBytes else {
        throw WorktreeError.busy("Pack object exceeds its type or size bound.")
      }
      if type == 6 {
        repeat {
          guard offset < content.count else { throw WorktreeError.busy("Truncated delta base.") }
          byte = data[offset]
          offset += 1
        } while byte & 128 != 0
      } else if type == 7 {
        offset += hashBytes
      }
      let stream = try inflate(data, at: offset, limit: budget.limits.objectBytes)
      guard stream.produced == size else { throw WorktreeError.busy("Pack object size mismatch.") }
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
      throw WorktreeError.busy("Unexpected pack trailing data.")
    }
  }

  private func inflate(_ data: Data, at offset: Int, limit: Int) throws
    -> (consumed: Int, produced: Int, prefix: Data)
  {
    guard offset < data.count else { throw WorktreeError.busy("Truncated compressed object.") }
    var prefix = [UInt8](repeating: 0, count: 128)
    var consumed = 0
    var produced = 0
    let status = data.withUnsafeBytes { bytes in
      cmcp_inflate_bounded(
        bytes.bindMemory(to: UInt8.self).baseAddress! + offset, data.count - offset, limit,
        &prefix, prefix.count, &consumed, &produced)
    }
    guard status == 0 else { throw WorktreeError.busy("Invalid or excessive compressed object.") }
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
    throw WorktreeError.busy("Invalid delta size.")
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
