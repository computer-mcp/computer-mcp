import Foundation

/// Moves an already-scoped item to the platform's Trash and returns its resulting URL.
package protocol FileTrashing: Sendable {
  func trashItem(at url: URL) throws -> URL?
}
