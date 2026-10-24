import ComputerMCPPlatformPOSIX
import ComputerMCPSandbox
import Foundation

/// Serialized by GatewayTerminalSessions. Each lifecycle owner has a distinct directory and lease.
internal final class TerminalSessionJournal {
  struct Record: Codable {
    let recoveryKey: String?
    let bootSessionID: String?
    let scope: GatewayTerminalSessions.Scope
    let isRegisteredProcess: Bool
    let snapshot: ShellSessionSnapshot
    let members: [ExecutionMember]
  }

  let bootSessionID: String?
  private let directory: URL
  private let lease: FileLock

  init(directory: URL, bootSessionID: String?) throws {
    self.bootSessionID = bootSessionID
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    lease = try FileLock(
      path: directory.appendingPathComponent("owner.lock").path, mode: .exclusive)
    self.directory = directory
  }

  func load() throws -> [Record] {
    try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "json" }.map {
      try JSONDecoder().decode(Record.self, from: Data(contentsOf: $0))
    }
  }

  func save(_ record: Record) throws {
    let url = try file(record.snapshot.sessionID)
    try JSONEncoder().encode(record).write(to: url, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  func remove(_ id: String) throws {
    let url = try file(id)
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }

  private func file(_ id: String) throws -> URL {
    guard UUID(uuidString: id) != nil else {
      throw ShellRuntimeError.invalidRequest("Invalid execution journal identity")
    }
    return directory.appendingPathComponent(id + ".json")
  }
}
