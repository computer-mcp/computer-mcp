import ComputerMCPPlatform
import Foundation

/// Persists plugin selection and local directory ownership without owning gateway configuration.
package protocol PluginStateStore: Sendable {
  var mcpProcessOwnershipRoot: URL? { get }
  func pluginStoreSnapshot() throws -> PluginStoreSnapshot
  /// Captures the host's expected configuration before snapshot preflight.
  func prepareCommit() throws -> any PluginStateCommit
  func pluginOwnedDirectories() throws -> [PluginOwnedDirectory]
  func recordPluginDirectory(_ record: PluginOwnedDirectory) throws
  func forgetPluginDirectory(_ record: PluginOwnedDirectory) throws
  func updatePluginDirectoryIdentity(
    _ identity: PluginDirectoryIdentity, replacing expected: PluginOwnedDirectory
  ) throws -> PluginOwnedDirectory
}

/// Publishes or saves a validated snapshot against the configuration captured during preparation.
package protocol PluginStateCommit: Sendable {
  func commit(
    _ snapshot: PluginStoreSnapshot, expectedRevision: Int64,
    storage: PluginInstallationStorage?
  ) async throws
}
