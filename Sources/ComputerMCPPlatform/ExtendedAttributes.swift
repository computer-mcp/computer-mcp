import Foundation

/// Accesses attributes on already-scoped paths, following the final symlink.
/// Value reads retain the observed size and fail if the attribute grows beyond the buffer.
package protocol ExtendedAttributes: Sendable {
  func names(at url: URL) throws -> [String]
  func size(of name: String, at url: URL) throws -> Int
  func value(of name: String, at url: URL, size: Int, maxBytes: Int) throws -> Data
  func remove(_ name: String, descriptor: Int32) throws
}
