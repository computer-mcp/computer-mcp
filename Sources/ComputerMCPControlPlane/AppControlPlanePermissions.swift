import ComputerMCPCore
import ComputerMCPGateway
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPPlugins
import Foundation

package enum ProjectAccess: String, CaseIterable, Codable, Sendable {
  case ask, deny, read, write

  package var permissionState: PermissionState? {
    switch self {
    case .ask: nil
    case .deny: .denied
    case .read: .granted(.read)
    case .write: .granted(.write)
    }
  }

  package init(permissionState: PermissionState) throws {
    self =
      switch permissionState {
      case .notGranted: .ask
      case .denied: .deny
      case .granted(.read): .read
      case .granted(.write): .write
      default: throw PermissionModelError.invalidPermissionValue
      }
  }

  package var isGranted: Bool { self == .read || self == .write }
}

package struct PermissionObjectNames: Sendable {
  package let projects: [String: String]
  package let plugins: [String: String]
  package let mcpServers: [String: String]

  package init(
    projects: [String: String] = [:], plugins: [String: String] = [:],
    mcpServers: [String: String] = [:]
  ) {
    self.projects = projects
    self.plugins = plugins
    self.mcpServers = mcpServers
  }
}

package struct ProfilePermissionIntegration: Equatable, Sendable, Identifiable {
  package let id: String
  package let title: String
  package let isEnabled: Bool
}

/// Owner choices and durable revisions captured for an exact permission edit.
package struct ProfilePermissionOptions: Sendable {
  package let grant: ProfileGrant
  package let integrations: [ProfilePermissionIntegration]
  package let plugins: [ProfilePermissionIntegration]
  package let projects: [ComputerMCPCore.RegisteredProject]
  package let permissionRevision: UInt64
  package let permissionEpoch: UUID?
  package let sourceProjects: [String: String]
  let inputs: AppControlPlaneService.GatewayInputs
}

extension AppControlPlaneService {
  func applyRemoteProjectGrant(
    id: String, access: PermissionState, profile: GatewayControlProfile, expectedRevision: Int64,
    inputs: GatewayInputs, authorization: GatewayManagementAuthorization
  ) async throws -> ProfileGrant {
    await manifestStore.publicationLock.acquire()
    defer { manifestStore.publicationLock.release() }
    try Task.checkCancellation()
    try requireCurrentGatewayInputs(inputs)
    guard profile.grant.authorizationRevision == expectedRevision,
      inputs.projects.contains(where: { $0.id == id })
    else { throw GatewayDatabaseError.configurationChanged }
    let service = try requirePermissionControl()
    let view = try service.view()
    guard var grant = view.profiles.first(where: { $0.id == profile.grant.id }),
      grant.authorizationRevision == expectedRevision
    else { throw GatewayDatabaseError.configurationChanged }
    try grant.permissions.set(access, for: .project(id))
    try manifestStore.withCurrentConfiguration(inputs.configuration) {
      try authorization.perform {
        try service.updateProfile(
          grant, expectedProfileRevision: expectedRevision, expectedRevision: view.revision,
          authorization: authorization)
      }
    }
    return try service.view().profiles.first(where: { $0.id == grant.id }) ?? grant
  }

  package func profilePermissionOptions(profileID: GatewayProfileID) async throws
    -> ProfilePermissionOptions
  {
    let inputs = try gatewayInputs()
    let view = try requirePermissionControl().view()
    guard let grant = view.profiles.first(where: { $0.id == profileID }) else {
      throw AppControlPlaneServiceError.unknownGatewayProfile(profileID.rawValue)
    }
    let resolved = try PluginHost.resolve(
      inputs.plugins, bundled: bundledPlugins, applications: platform.applications)
    let composition = try GatewayPluginComposition(
      configuration: inputs.configuration, plugins: resolved.plugins)
    let integrations = composition.runtimeConfiguration.mcp.servers.map { server in
      let origin = composition.origins[.init(kind: .mcp, id: server.id)]
      let plugin = bundledPlugins.packages.first { $0.manifest.id == origin?.pluginID }
      let title = origin.map { "\(plugin?.manifest.name ?? $0.pluginID) · \($0.componentID)" }
      return ProfilePermissionIntegration(
        id: server.id, title: title ?? server.id, isEnabled: server.enabled)
    }.sorted { $0.id < $1.id }
    var pluginNames = Dictionary(
      uniqueKeysWithValues: bundledPlugins.packages.map {
        ($0.manifest.id, $0.manifest.name)
      })
    for installation in inputs.plugins.installations
    where inputs.plugins.selectedInstallations[installation.pluginID] == installation.id {
      if let package = try? PluginPackage.load(at: installation.source.root) {
        pluginNames[installation.pluginID] = package.manifest.name
      }
    }
    let enabledPluginIDs = Set(resolved.plugins.map(\.id))
    let plugins = Set(pluginNames.keys).union(enabledPluginIDs).sorted().map { id in
      ProfilePermissionIntegration(
        id: id, title: pluginNames[id] ?? id, isEnabled: enabledPluginIDs.contains(id))
    }
    try requireCurrentGatewayInputs(inputs)
    return ProfilePermissionOptions(
      grant: grant, integrations: integrations, plugins: plugins,
      projects: inputs.projects, permissionRevision: view.revision, permissionEpoch: view.epoch,
      sourceProjects: view.sourceProjects, inputs: inputs)
  }
}
