import Foundation

package struct PluginArchiveExtraction: Equatable, Sendable {
  package let root: URL
  package let entries: Int
  package let bytes: Int

  package init(root: URL, entries: Int, bytes: Int) {
    self.root = root
    self.entries = entries
    self.bytes = bytes
  }
}

/// Decodes into a newly owned private directory, reclaiming partial output on failure.
package protocol PluginArchiveExtracting: Sendable {
  func extract(
    _ source: URL, toNewDirectory destination: URL,
    checkCancellation: () throws -> Void
  ) throws -> PluginArchiveExtraction
}
