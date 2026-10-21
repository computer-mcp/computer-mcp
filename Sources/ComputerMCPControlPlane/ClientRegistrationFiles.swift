import ComputerMCPCore
import Crypto
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// A short-lived file snapshot, never retained by a plan or included in a diagnostic.
struct RegistrationJSONFile {
  let bytes: Data?
  let inode: UInt64?
  let mode: UInt32?
  let size: Int64?
  let object: [String: JSONValue]

  func entry(named name: String) -> JSONValue? { object["mcpServers"]?.objectValue?[name] }

  static func read(_ path: String) throws -> Self {
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else {
      if errno == ENOENT {
        return Self(bytes: nil, inode: nil, mode: nil, size: nil, object: [:])
      }
      throw ClientRegistrationError(.unreadable)
    }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_size >= 0, info.st_size <= 16 * 1_024 * 1_024
    else { throw ClientRegistrationError(.unreadable) }
    var bytes = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
      #if canImport(Darwin)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
      #else
        let count = Glibc.read(descriptor, &buffer, buffer.count)
      #endif
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else { throw ClientRegistrationError(.unreadable) }
      if count == 0 { break }
      bytes.append(contentsOf: buffer.prefix(count))
      guard bytes.count <= 16 * 1_024 * 1_024 else { throw ClientRegistrationError(.unreadable) }
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0, after.st_ino == info.st_ino,
      after.st_mode == info.st_mode, after.st_size == info.st_size,
      bytes.count == Int(info.st_size),
      let value = try? JSONDecoder().decode(JSONValue.self, from: bytes),
      let object = value.objectValue,
      object["mcpServers"] == nil || object["mcpServers"]?.objectValue != nil
    else { throw ClientRegistrationError(.unreadable) }
    return Self(
      bytes: bytes, inode: UInt64(info.st_ino), mode: UInt32(info.st_mode & 0o7777),
      size: Int64(info.st_size), object: object)
  }

  func matches(_ other: Self) -> Bool {
    bytes == other.bytes && inode == other.inode && mode == other.mode && size == other.size
  }
}

struct DesktopRegistrationFileWriter: Sendable {
  var temporaryFileCreated: @Sendable (String) throws -> Void = { _ in }
  var beforeFinalCheck: @Sendable () throws -> Void = {}
  var beforeRename: @Sendable () throws -> Void = {}

  func write(_ plan: RegistrationPlanContents, isRunning: @Sendable () -> Bool) throws {
    guard !isRunning() else { throw ClientRegistrationError(.clientRunning) }
    let path = plan.location.configurationFile
    let original = try RegistrationJSONFile.read(path)
    let fileSHA256 = original.bytes.map {
      SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
    }
    guard fileSHA256 == plan.observation.fileSHA256 else {
      throw ClientRegistrationError(.changedSincePreview)
    }
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw ClientRegistrationError(.supportDirectoryMissing) }

    var object = original.object
    var servers = object["mcpServers"]?.objectValue ?? [:]
    if plan.operation == .remove {
      servers.removeValue(forKey: plan.serverName)
    } else {
      servers[plan.serverName] = .object([
        "command": .string(plan.server.executable),
        "args": .array(plan.server.arguments.map(JSONValue.string)),
      ])
    }
    object["mcpServers"] = .object(servers)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let bytes = try encoder.encode(JSONValue.object(object)) + Data("\n".utf8)
    let temporary = directory.appendingPathComponent(
      ".computer-mcp-registration-\(UUID().uuidString)"
    ).path
    let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw ClientRegistrationError(.writeFailed) }
    defer {
      close(descriptor)
      unlink(temporary)
    }
    guard fchmod(descriptor, 0o600) == 0 else { throw ClientRegistrationError(.writeFailed) }
    try temporaryFileCreated(temporary)
    try bytes.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = systemWrite(
          descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw ClientRegistrationError(.writeFailed) }
        offset += count
      }
    }
    guard fchmod(descriptor, mode_t(original.mode ?? 0o600)) == 0, fsync(descriptor) == 0 else {
      throw ClientRegistrationError(.writeFailed)
    }
    try beforeFinalCheck()
    guard !isRunning() else { throw ClientRegistrationError(.clientRunning) }
    guard let current = try? RegistrationJSONFile.read(path), original.matches(current) else {
      throw ClientRegistrationError(.changedSincePreview)
    }
    try beforeRename()
    let result: Int32
    if original.bytes == nil {
      #if canImport(Darwin)
        result = renamex_np(temporary, path, UInt32(RENAME_EXCL))
      #else
        // Claude Desktop's file writer is supplied only by the macOS host.
        result = -1
        errno = ENOSYS
      #endif
    } else {
      result = rename(temporary, path)
    }
    guard result == 0 else {
      throw ClientRegistrationError(errno == EEXIST ? .changedSincePreview : .writeFailed)
    }
  }

  private func systemWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
      Darwin.write(fd, buffer, count)
    #else
      Glibc.write(fd, buffer, count)
    #endif
  }
}
