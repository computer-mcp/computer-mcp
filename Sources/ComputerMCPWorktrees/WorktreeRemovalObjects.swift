import Foundation

extension WorktreeRepository {
  /// Reflogs identify commits displaced by amend/rebase. Missing provenance never
  /// authorizes discarding another private commit: coverage is checked on the copy.
  func removalRoots(_ topology: VerifiedWorktreeTopology) throws -> [String] {
    let logs = topology.gitDirectory.url.appendingPathComponent("logs")
    guard FileManager.default.fileExists(atPath: logs.path) else { return [] }
    let directory = try WorktreeDirectory(logs)
    guard let bytes = try io.read("HEAD", in: directory, limit: git.maxOutputBytes * 8) else {
      return []
    }
    guard bytes.isEmpty || bytes.last == 10,
      let text = String(data: bytes, encoding: .utf8)
    else { throw WorktreeError.recoveryRequired("Private reflog provenance is unreadable.") }
    let zero = String(repeating: "0", count: identity.format.hexCount)
    var roots: Set<String> = []
    for line in text.split(separator: "\n") {
      let fields = line.split(separator: " ", maxSplits: 2)
      guard fields.count == 3,
        identity.format.contains(String(fields[0])), identity.format.contains(String(fields[1]))
      else { throw WorktreeError.recoveryRequired("Private reflog provenance is malformed.") }
      roots.formUnion(fields.prefix(2).map(String.init).filter { $0 != zero })
    }
    return roots.sorted()
  }

  func requirePrivateCommitCoverage(
    _ journal: WorktreePublicationJournal, manifest: Set<String>, acknowledgements: [String],
    run: ([String], Data) throws -> Data
  ) throws {
    var privateObjects: Set<String> = []
    let objects = try publicationStaging(journal).child("objects")
    for file in journal.files {
      if !file.name.hasPrefix("pack/") {
        privateObjects.insert(file.name.replacingOccurrences(of: "/", with: ""))
      } else if file.name.hasSuffix(".idx") {
        let output = try run(
          ["verify-pack", "-v", objects.url.appendingPathComponent(file.name).path], Data())
        for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
          let fields = line.split(separator: " ")
          if let oid = fields.first, identity.format.contains(String(oid)) {
            privateObjects.insert(String(oid))
          }
        }
      }
    }
    var permitted = manifest
    if !acknowledgements.isEmpty {
      guard acknowledgements.allSatisfy(identity.format.contains) else {
        throw WorktreeError.recoveryRequired("Invalid replacement acknowledgement.")
      }
      let output = try run(["rev-list"] + acknowledgements, Data())
      permitted.formUnion(
        String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init))
    }
    guard !privateObjects.isEmpty else { return }
    let ordered = privateObjects.sorted()
    let types = try run(
      ["cat-file", "--batch-check=%(objectname) %(objecttype)"],
      Data((ordered.joined(separator: "\n") + "\n").utf8))
    let lines = String(decoding: types, as: UTF8.self).split(separator: "\n")
    guard lines.count == ordered.count else {
      throw WorktreeError.recoveryRequired("Private object inventory is incomplete.")
    }
    for (oid, line) in zip(ordered, lines) {
      let fields = line.split(separator: " ")
      guard fields.count == 2, fields[0] == oid,
        ["commit", "tree", "blob", "tag"].contains(fields[1])
      else { throw WorktreeError.recoveryRequired("Private object type is unresolved.") }
      guard fields[1] != "commit" || permitted.contains(oid) else {
        throw WorktreeError.recoveryRequired(
          "An unpreserved private commit requires reconciliation.")
      }
    }
  }
}
