import Foundation

package struct ProfilePermissionCapability: Equatable, Sendable, Identifiable {
  package let id: String
  package let title: String
  package let summary: String
  package let descriptor: CapabilityDescriptor
}

package struct ProfilePermissionIntegration: Equatable, Sendable, Identifiable {
  package let id: String
  package let title: String
  package let isEnabled: Bool
}

/// Owner presentation data bound to the configuration that was reviewed.
package struct ProfilePermissionOptions: Sendable {
  package let grant: ProfileGrant
  package let capabilities: [ProfilePermissionCapability]
  package let integrations: [ProfilePermissionIntegration]
  package let workspaces: [RegisteredWorkspace]
  let inputs: AppControlPlaneService.GatewayInputs
}

extension AppControlPlaneService {
  func applyRemoteWorkspaceGrant(
    id: String, enabled: Bool, profile: GatewayControlProfile, expectedRevision: Int64,
    inputs: GatewayInputs, authorization: GatewayManagementAuthorization
  ) throws -> ProfileGrant {
    try requireCurrentGatewayInputs(inputs)
    guard profile.grant.authorizationRevision == expectedRevision,
      inputs.workspaces.contains(where: { $0.id == id })
    else { throw GatewayDatabaseError.configurationChanged }
    var grant = profile.grant
    if enabled {
      grant.workspaceIDs.insert(id)
    } else {
      if grant.workspaceIDs.remove("*") != nil {
        grant.workspaceIDs.formUnion(inputs.workspaces.map(\.id))
      }
      grant.workspaceIDs.remove(id)
    }
    try grant.validate()
    return try manifestStore.withCurrentConfiguration(inputs.configuration) {
      try authorization.perform {
        try database.saveProfile(
          grant, expectedRevision: profile.persisted ? expectedRevision : 0,
          expectedConfiguration: inputs.persisted, authorization: authorization)
        return try database.profiles().first { $0.id == grant.id } ?? grant
      }
    }
  }

  package func profilePermissionOptions(profileID: GatewayProfileID) async throws
    -> ProfilePermissionOptions
  {
    let inputs = try gatewayInputs()
    guard let grant = try await profileGrants().first(where: { $0.id == profileID }) else {
      throw AppControlPlaneServiceError.unknownGatewayProfile(profileID.rawValue)
    }
    let resolved = try PluginHost.resolve(inputs.plugins, bundled: bundledPlugins)
    let composition = try GatewayPluginComposition(
      configuration: inputs.configuration, plugins: resolved.plugins)
    let integrations = composition.runtimeConfiguration.mcp.servers.map { server in
      let origin = composition.origins[.init(kind: .mcp, id: server.id)]
      let plugin = bundledPlugins.packages.first { $0.manifest.id == origin?.pluginID }
      let title = origin.map { "\(plugin?.manifest.name ?? $0.pluginID) · \($0.componentID)" }
      return ProfilePermissionIntegration(
        id: server.id, title: title ?? server.id,
        isEnabled: server.enabled)
    }.sorted { $0.id < $1.id }
    let gateway = try await makeGateway(
      inputs: inputs, caller: .localApp, profileID: .localAdmin, persistentState: false)
    let capabilities: [ProfilePermissionCapability]
    do {
      capabilities = try (gateway.listTools() + GatewayRemoteManagement.tools).compactMap { tool in
        let descriptor =
          try GatewayRemoteManagement.byName[tool.name]?.descriptor
          ?? gateway.capabilityDescriptor(named: tool.name)
        guard descriptor.risk != .fullShell,
          !ProfileGrant.mcpSurfaceCapabilities.contains(tool.name),
          !ProfilePermissionSelection.supportCapabilities.contains(tool.name)
        else { return nil }
        return ProfilePermissionCapability(
          id: tool.name, title: tool.title, summary: tool.description, descriptor: descriptor)
      }.sorted { $0.id < $1.id }
    } catch {
      await gateway.shutdown()
      throw error
    }
    await gateway.shutdown()
    try requireCurrentGatewayInputs(inputs)
    return ProfilePermissionOptions(
      grant: grant, capabilities: capabilities, integrations: integrations,
      workspaces: inputs.workspaces, inputs: inputs)
  }
}

/// Normal selection grants the reviewed scope; routing and approval helpers still
/// admit every target against that scope and cannot authorize an additional effect.
package enum ProfilePermissionSelection {
  package static let supportCapabilities: Set<String> = [
    "policy.probe", "operations.prepare", "operations.commit",
  ]
}
