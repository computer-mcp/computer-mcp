import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPSandbox
import Foundation

/// Ownership receipts are separate from permission database backups. A receipt is
/// durable before the bootstrap releases code; confirmed receipts remain for the
/// boot so restoring an older SQL copy cannot resurrect their cleanup obligation.
final class ExecutionRecoveryJournal: @unchecked Sendable {
  struct Entry: Codable {
    let child: UUID
    let execution: UUID
    let owner: UUID
    let boot: String
    let recovery: ExecutionRecoveryState
    var completed = false
    var released = false
  }
  private let directory: URL
  private let lock = NSLock()

  init(directory: URL) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    self.directory = try ProjectPathResolver.canonicalProject(directory)
  }

  func all() throws -> [Entry] {
    try lock.withLock {
      try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }.map { url in
          guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else {
            throw ExecutionEnvironmentError.unavailable("Invalid ownership receipt name")
          }
          return try read(url)
        }
    }
  }

  func save(_ entry: Entry) throws { try lock.withLock { try write(entry) } }

  func confirm(_ child: UUID) throws {
    try update(child) { $0.completed = true }
  }

  func release(_ child: UUID) throws {
    try update(child) {
      guard $0.completed else {
        throw ExecutionEnvironmentError.unavailable("Execution exit is unconfirmed")
      }
      $0.released = true
    }
  }

  private func update(_ child: UUID, _ body: (inout Entry) throws -> Void) throws {
    try lock.withLock {
      let url = file(child)
      guard FileManager.default.fileExists(atPath: url.path) else { return }
      var entry = try read(url)
      try body(&entry)
      try write(entry)
    }
  }

  private func read(_ url: URL) throws -> Entry {
    let bytes = try Data(contentsOf: url)
    guard bytes.count <= 131_072 else {
      throw ExecutionEnvironmentError.unavailable("Invalid ownership receipt")
    }
    let entry = try JSONDecoder().decode(Entry.self, from: bytes)
    guard file(entry.child) == url, !entry.released || entry.completed else {
      throw ExecutionEnvironmentError.unavailable("Invalid ownership receipt identity")
    }
    return entry
  }

  private func write(_ entry: Entry) throws {
    let url = file(entry.child)
    try JSONEncoder().encode(entry).write(to: url, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    let file = try FileHandle(forWritingTo: url)
    defer { try? file.close() }
    try file.synchronize()
    try DurableDirectory.synchronize(directory)
  }

  private func file(_ child: UUID) -> URL {
    directory.appendingPathComponent(child.uuidString + ".json")
  }
}
