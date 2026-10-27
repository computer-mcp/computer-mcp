import Foundation

/// A retained reflog prefix identifies the base registration. Expiration or
/// replacement loses proof and retains protection; it never proves integration.
package struct WorktreeRefHistory: Codable, Equatable, Sendable {
  let bytes: Int
  let digest: String
  let oid: String
}

extension WorktreeRepository {
  func refHistory(_ ref: String) throws -> Data? {
    guard ref.hasPrefix("refs/heads/") else {
      throw WorktreeError.invalidRequest("Expected a branch reference.")
    }
    let components = ("logs/" + ref).split(separator: "/").map(String.init)
    var directory = try WorktreeDirectory(URL(fileURLWithPath: identity.common.path))
    for name in components.dropLast() {
      let path = directory.url.appendingPathComponent(name)
      guard FileManager.default.fileExists(atPath: path.path) else { return nil }
      directory = try directory.child(name)
    }
    return try io.read(components.last!, in: directory, limit: git.maxOutputBytes * 8)
  }

  func captureRefHistory(_ ref: String, expectedOID: String) throws -> WorktreeRefHistory? {
    guard let bytes = try refHistory(ref), !bytes.isEmpty else { return nil }
    guard bytes.last == 10,
      let line = String(data: bytes, encoding: .utf8)?.split(separator: "\n").last,
      line.split(separator: " ", maxSplits: 2).dropFirst().first == Substring(expectedOID)
    else { throw WorktreeError.recoveryRequired("Base history does not match its reference.") }
    return .init(bytes: bytes.count, digest: WorktreeObjectSnapshot.digest(bytes), oid: expectedOID)
  }

  func requireRefHistory(_ ref: String, history: WorktreeRefHistory, expectedOID: String) throws {
    guard history.bytes > 0, let data = try refHistory(ref), data.count >= history.bytes,
      WorktreeObjectSnapshot.digest(data.prefix(history.bytes)) == history.digest,
      data.last == 10,
      let suffix = String(data: data.dropFirst(history.bytes), encoding: .utf8)
    else { throw WorktreeError.recoveryRequired("Recorded base history changed or was expired.") }
    var previous = history.oid
    for line in suffix.split(separator: "\n") {
      let fields = line.split(separator: " ", maxSplits: 2)
      guard fields.count == 3, fields[0] == previous,
        identity.format.contains(String(fields[1])),
        try isAncestor(previous, of: String(fields[1]))
      else { throw WorktreeError.recoveryRequired("Recorded base was reset or replaced.") }
      previous = String(fields[1])
    }
    guard previous == expectedOID else {
      throw WorktreeError.recoveryRequired("Recorded base history and tip disagree.")
    }
  }

  func isAncestor(_ old: String, of new: String) throws -> Bool {
    guard identity.format.contains(old), identity.format.contains(new) else {
      throw WorktreeError.recoveryRequired("Invalid ancestry object ID.")
    }
    return try command(["merge-base", "--is-ancestor", old, new], accepting: [0, 1]).exitCode == 0
  }
}
