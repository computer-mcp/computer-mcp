import ComputerMCPPlatform
import Foundation

/// Persists plugin selection and local directory ownership without owning gateway configuration.
package protocol PluginStateStore: Sendable {
  var mcpProcessOwnershipRoot: URL? { get }
  func pluginStoreSnapshot() throws -> PluginStoreSnapshot
  /// Publishes or saves a validated snapshot against the host's expected configuration.
  func commit(
    _ snapshot: PluginStoreSnapshot, expectedRevision: Int64,
    storage: PluginInstallationStorage?
  ) async throws
  func pluginOwnedDirectories() throws -> [PluginOwnedDirectory]
  func recordPluginDirectory(_ record: PluginOwnedDirectory) throws
  func forgetPluginDirectory(_ record: PluginOwnedDirectory) throws
  func updatePluginDirectoryIdentity(
    _ identity: PluginDirectoryIdentity, replacing expected: PluginOwnedDirectory
  ) throws -> PluginOwnedDirectory
}
