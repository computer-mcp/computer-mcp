import Foundation

package struct PluginArchiveReceipt: Codable, Equatable, Sendable {
  package let sha256: String
  package let archiveBytes: Int
  package let extractedBytes: Int
  package let entries: Int

  private enum CodingKeys: String, CodingKey {
    case sha256, entries
    case archiveBytes = "archive_bytes"
    case extractedBytes = "extracted_bytes"
  }
}

/// The CLI invokes this only after establishing child-process resource limits.
/// The host owns the private job root and reclaims it after the worker exits,
/// including when termination prevents normal Swift cleanup from running.
package enum PluginArchiveWorker {
  package static func prepare(
    input: Int32, inJobDirectory root: URL, expectedSHA256: String
  ) throws -> PluginArchiveReceipt {
    try PluginArchiveSnapshot.withVerifiedCopy(
      from: input, inNewDirectory: root.appendingPathComponent("input"),
      expectedSHA256: expectedSHA256
    ) { snapshot in
      let extracted = try PluginArchiveExtractor().extract(
        snapshot.url, toNewDirectory: root.appendingPathComponent("payload"))
      return PluginArchiveReceipt(
        sha256: snapshot.sha256, archiveBytes: snapshot.bytes,
        extractedBytes: extracted.bytes, entries: extracted.entries)
    }
  }
}
