import ComputerMCPPlatform
import Darwin
import Foundation

package struct DarwinPluginArchiveDirectoryFactory: PluginArchiveDirectoryFactory {
  package init() {}

  package func create(at url: URL) throws -> any PluginArchiveStagingDirectory {
    try PluginArchiveDirectory(at: url)
  }

  package func recover(_ identity: PluginDirectoryIdentity) throws
    -> any PluginArchiveStagingDirectory
  {
    try PluginArchiveDirectory(recovering: identity)
  }

  package func identity(url: URL, status: stat, descriptor: Int32) throws -> PluginDirectoryIdentity
  {
    try PluginDirectoryIdentity(url: url, status: status, descriptor: descriptor)
  }

  package func matches(_ identity: PluginDirectoryIdentity, status: stat, descriptor: Int32) throws
    -> Bool
  {
    try identity.matches(status, descriptor: descriptor)
  }

  package func renameExclusively(
    from source: String, in sourceDirectory: Int32,
    to destination: String, in destinationDirectory: Int32
  ) throws {
    guard
      renameatx_np(sourceDirectory, source, destinationDirectory, destination, UInt32(RENAME_EXCL))
        == 0
    else {
      throw PluginArchiveError.fileSystemFailure
    }
  }
}
