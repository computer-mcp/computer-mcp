import Foundation

extension GatewayRuntime {
  static func retainPluginArtifacts(
    state: PluginStoreSnapshot, plugins: [ResolvedPlugin]?, database: GatewayDatabase?
  ) throws -> [PluginArtifactLease] {
    let records: [PluginInstallationRecord]
    if let plugins {
      let roots = Set(
        plugins.flatMap { $0.origins.values }.filter { $0.source.kind == .artifact }
          .map { $0.source.root })
      records = state.installations.filter { roots.contains($0.source.root) }
      guard Set(records.map { $0.source.root }) == roots else {
        throw PluginStoreError.invalidState
      }
    } else {
      records = state.installations.filter {
        $0.source.kind == .artifact && state.settings[$0.pluginID]?.enabled == true
          && state.selectedInstallations[$0.pluginID] == $0.id
      }
    }
    let owned = try database?.pluginOwnedDirectories() ?? []
    var leases: [PluginArtifactLease] = []
    for record in records {
      guard let directory = owned.first(where: { $0.installationID == record.id }),
        directory.pluginID == record.pluginID,
        directory.identity.url.appendingPathComponent("package").path == record.source.root.path
      else { throw PluginStoreError.invalidState }
      let storage = try PluginInstallationStorage(
        at: directory.identity.url.deletingLastPathComponent())
      defer { storage.finishTransaction() }
      leases.append(try storage.retainArtifact(directory.identity))
    }
    return leases
  }
}
