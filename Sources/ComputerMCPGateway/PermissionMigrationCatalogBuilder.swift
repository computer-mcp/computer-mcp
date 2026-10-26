import ComputerMCPCore
import ComputerMCPPlugins

extension PermissionMigrationCatalog {
  /// Inputs are cached, host-validated registration facts. Constructing this
  /// snapshot performs no runtime construction, resolution or downstream calls.
  package static func capture(
    configurationDigest: String, builtinIDs: Set<String>,
    downstream: [CapabilityDescriptor], serverIDs: Set<String>,
    registrations: Set<IntegrationRegistration>, enabledRegistrations: Set<IntegrationRegistration>,
    origins: [IntegrationRegistration: PluginContributionOrigin],
    manifestProfiles: [ProfileGrant], projectedCLI: [String: [CapabilityDescriptor]] = [:]
  ) throws -> Self {
    guard enabledRegistrations.isSubset(of: registrations),
      origins.keys.allSatisfy({ registrations.contains($0) }),
      serverIDs.allSatisfy({ registrations.contains(.init(kind: .mcp, id: $0)) })
    else {
      throw PermissionMigrationError.invalidCatalog
    }
    let enabledServers = serverIDs.filter {
      enabledRegistrations.contains(.init(kind: .mcp, id: $0))
    }
    var dynamic: [PermissionMigrationTool] = []
    for descriptor in downstream {
      guard let reference = descriptor.mcpReference, serverIDs.contains(reference.serverID) else {
        throw PermissionMigrationError.invalidCatalog
      }
      guard enabledServers.contains(reference.serverID) else { continue }
      dynamic.append(
        PermissionMigrationTool(
          id: descriptor.id, risk: descriptor.risk,
          projectRequirement: descriptor.projectRequirement, localOnly: descriptor.localOnly,
          usesNetwork: descriptor.usesNetwork, access: descriptor.requirement.access,
          permissions: descriptor.requirement.permissions,
          aliases: descriptor.equivalentCapabilityIDs ?? [], serverID: reference.serverID,
          pluginID: origins[.init(kind: .mcp, id: reference.serverID)]?.pluginID))
    }
    for (registration, origin) in origins where enabledRegistrations.contains(registration) {
      let ids: Set<String>
      switch registration.kind {
      case .mcp: continue
      case .cli: ids = ["cli.exec", "cli.help"]
      case .skills:
        ids = Set(
          builtinV1.filter { $0.permissions.contains { $0.permission == .skills } }.map(\.id))
      }
      for tool in builtinV1 where builtinIDs.contains(tool.id) && ids.contains(tool.id) {
        // Multiple components of one plugin need only one authority classification.
        if dynamic.contains(where: { $0.id == tool.id && $0.pluginID == origin.pluginID }) {
          continue
        }
        dynamic.append(
          PermissionMigrationTool(
            id: tool.id, risk: tool.risk,
            projectRequirement: tool.projectRequirement, localOnly: tool.localOnly,
            usesNetwork: tool.usesNetwork, access: tool.access, permissions: tool.permissions,
            pluginID: origin.pluginID))
      }
    }
    for (registration, descriptors) in projectedCLI {
      let identity = IntegrationRegistration(kind: .cli, id: registration)
      guard registrations.contains(identity) else {
        throw PermissionMigrationError.invalidCatalog
      }
      guard enabledRegistrations.contains(identity) else { continue }
      let origin = origins[identity]
      for descriptor in descriptors {
        dynamic.append(
          PermissionMigrationTool(
            id: descriptor.id, risk: .fullShell, projectRequirement: .required,
            access: .projectWrite, pluginID: origin?.pluginID))
      }
    }
    let serverPlugins = Dictionary(
      uniqueKeysWithValues: origins.compactMap { registration, origin in
        registration.kind == .mcp && enabledServers.contains(registration.id)
          ? (registration.id, origin.pluginID) : nil
      })
    return try Self(
      configurationDigest: configurationDigest, availableBuiltinIDs: builtinIDs,
      dynamicTools: dynamic, serverIDs: serverIDs, manifestProfiles: manifestProfiles,
      serverPluginIDs: serverPlugins)
  }
}
