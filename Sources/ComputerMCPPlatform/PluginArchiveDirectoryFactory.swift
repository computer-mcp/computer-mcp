import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

/// Owns a private directory; writes and cleanup remain anchored to its open descriptor.
package protocol PluginArchiveStagingDirectory: AnyObject {
  var url: URL { get }
  var descriptor: Int32 { get }
  func createDirectory(_ parts: [String]) throws
  func createFile(
    _ parts: [String], executable: Bool, readOnly: Bool, write: (Int32) throws -> Void
  ) throws
  func finish() throws
  func identity() throws -> PluginDirectoryIdentity
  func removeStaging() throws
  func discard() throws
}

package protocol PluginArchiveDirectoryFactory: Sendable {
  func create(at url: URL) throws -> any PluginArchiveStagingDirectory
  func recover(_ identity: PluginDirectoryIdentity) throws -> any PluginArchiveStagingDirectory
  func identity(url: URL, status: stat, descriptor: Int32) throws -> PluginDirectoryIdentity
  func matches(_ identity: PluginDirectoryIdentity, status: stat, descriptor: Int32) throws -> Bool
  /// Moves a child between open directories without replacing an existing destination.
  func renameExclusively(
    from source: String, in sourceDirectory: Int32,
    to destination: String, in destinationDirectory: Int32
  ) throws
}
