import ComputerMCPPlatform
import ComputerMCPPlugins
import Foundation

/// Binds a plugin commit to the gateway configuration and its optional runtime publication.
struct GatewayPluginStateStore: PluginStateStore {
  typealias PublishSnapshot =
    @Sendable (
      PluginStoreSnapshot, GatewayDatabase.ConfigurationState, PluginInstallationStorage?
    ) async throws -> Void

  let database: GatewayDatabase
  var expectedConfiguration: GatewayDatabase.ConfigurationState?
  var publishSnapshot: PublishSnapshot?

  var mcpProcessOwnershipRoot: URL? { database.mcpProcessOwnershipRoot }

  func pluginStoreSnapshot() throws -> PluginStoreSnapshot {
    try database.pluginStoreSnapshot()
  }

  func commit(
    _ snapshot: PluginStoreSnapshot, expectedRevision: Int64,
    storage: PluginInstallationStorage?
  ) async throws {
    let configuration = try expectedConfiguration ?? database.configurationState()
    if let publishSnapshot {
      try await publishSnapshot(snapshot, configuration, storage)
    } else {
      try Task.checkCancellation()
      try database.savePluginStoreSnapshot(
        snapshot, expectedRevision: expectedRevision, expectedConfiguration: configuration)
    }
  }

  func pluginOwnedDirectories() throws -> [PluginOwnedDirectory] {
    try database.pluginOwnedDirectories()
  }

  func recordPluginDirectory(_ record: PluginOwnedDirectory) throws {
    try database.recordPluginDirectory(record)
  }

  func forgetPluginDirectory(_ record: PluginOwnedDirectory) throws {
    try database.forgetPluginDirectory(record)
  }

  func updatePluginDirectoryIdentity(
    _ identity: PluginDirectoryIdentity, replacing expected: PluginOwnedDirectory
  ) throws -> PluginOwnedDirectory {
    try database.updatePluginDirectoryIdentity(identity, replacing: expected)
  }
}

extension PluginStore {
  init(
    database: GatewayDatabase, platform: PlatformServices,
    validateSnapshot: @escaping @Sendable (PluginStoreSnapshot) throws -> Void = { _ in }
  ) {
    self.init(
      stateStore: GatewayPluginStateStore(database: database),
      directoryFactory: platform.pluginDirectories, applications: platform.applications,
      validateSnapshot: validateSnapshot)
  }

  init(
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
