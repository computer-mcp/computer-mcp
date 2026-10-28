import Foundation

extension WorktreeRepository {
  func removalRoots(_ topology: VerifiedWorktreeTopology) throws -> [String] {
    try privateMetadata(topology).roots
  }

  func objectRevision(_ ref: String) throws -> String? {
    let result = try command(
      ["rev-parse", "--verify", "--quiet", "--end-of-options", ref], accepting: [0, 1])
    guard result.exitCode == 0 else { return nil }
    let oid = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .newlines)
    guard identity.format.contains(oid) else {
      throw WorktreeError.identityChanged("Invalid reference object ID.")
    }
    return oid
  }

  func requireObjectRef(_ ref: String, oid: String) throws {
    guard try command(["symbolic-ref", "--quiet", ref], accepting: [0, 1]).exitCode == 1,
      try objectRevision(ref) == oid
    else { throw WorktreeError.recoveryRequired("Expected recovery reference changed.") }
  }
}
