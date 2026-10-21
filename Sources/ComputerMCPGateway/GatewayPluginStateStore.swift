import ComputerMCPPlatform
import ComputerMCPPlugins
import Foundation

/// Binds a plugin commit to the gateway configuration and its optional runtime publication.
package struct GatewayPluginStateStore: PluginStateStore {
  package typealias PublishSnapshot =
    @Sendable (
      PluginStoreSnapshot, GatewayDatabase.ConfigurationState, PluginInstallationStorage?
    ) async throws -> Void

  package let database: GatewayDatabase
  var expectedConfiguration: GatewayDatabase.ConfigurationState?
  var publishSnapshot: PublishSnapshot?

  package var mcpProcessOwnershipRoot: URL? { database.mcpProcessOwnershipRoot }

  package func pluginStoreSnapshot() throws -> PluginStoreSnapshot {
    try database.pluginStoreSnapshot()
  }

  package func prepareCommit() throws -> any PluginStateCommit {
    try Commit(
      database: database,
      expectedConfiguration: expectedConfiguration ?? database.configurationState(),
      publishSnapshot: publishSnapshot)
  }

  package func pluginOwnedDirectories() throws -> [PluginOwnedDirectory] {
    try database.pluginOwnedDirectories()
  }

  package func recordPluginDirectory(_ record: PluginOwnedDirectory) throws {
    try database.recordPluginDirectory(record)
  }

  package func forgetPluginDirectory(_ record: PluginOwnedDirectory) throws {
    try database.forgetPluginDirectory(record)
  }

  package func updatePluginDirectoryIdentity(
    _ identity: PluginDirectoryIdentity, replacing expected: PluginOwnedDirectory
  ) throws -> PluginOwnedDirectory {
    try database.updatePluginDirectoryIdentity(identity, replacing: expected)
  }

  private struct Commit: PluginStateCommit {
    let database: GatewayDatabase
    let expectedConfiguration: GatewayDatabase.ConfigurationState
    let publishSnapshot: PublishSnapshot?

    func commit(
      _ snapshot: PluginStoreSnapshot, expectedRevision: Int64,
      storage: PluginInstallationStorage?
    ) async throws {
      if let publishSnapshot {
        try await publishSnapshot(snapshot, expectedConfiguration, storage)
      } else {
        try Task.checkCancellation()
        try database.savePluginStoreSnapshot(
          snapshot, expectedRevision: expectedRevision,
          expectedConfiguration: expectedConfiguration)
      }
    }
  }
}

extension PluginStore {
  package init(
    database: GatewayDatabase, platform: PlatformServices,
    validateSnapshot: @escaping @Sendable (PluginStoreSnapshot) throws -> Void = { _ in }
  ) {
    self.init(
      stateStore: GatewayPluginStateStore(database: database),
      directoryFactory: platform.pluginDirectories, applications: platform.applications,
      validateSnapshot: validateSnapshot)
  }

  package init(
    database: GatewayDatabase, platform: PlatformServices,
    expectedConfiguration: GatewayDatabase.ConfigurationState,
    publishSnapshot: GatewayPluginStateStore.PublishSnapshot? = nil,
    validateSnapshot: @escaping @Sendable (PluginStoreSnapshot) throws -> Void = { _ in }
  ) {
    self.init(
      stateStore: GatewayPluginStateStore(
        database: database, expectedConfiguration: expectedConfiguration,
        publishSnapshot: publishSnapshot),
      directoryFactory: platform.pluginDirectories, applications: platform.applications,
      validateSnapshot: validateSnapshot)
  }
}
