import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPPlugins
import Foundation

extension PermissionMigrationCatalog {
  /// Inputs are cached, host-validated registration facts. Constructing this
  /// snapshot performs no runtime construction, resolution or downstream calls.
  package static func capture(
    configurationDigest: String, builtinIDs: Set<String>,
    downstream: [CapabilityDescriptor], serverIDs: Set<String>,
    registrations: Set<IntegrationRegistration>, enabledRegistrations: Set<IntegrationRegistration>,
    origins: [IntegrationRegistration: PluginContributionOrigin],
    manifestProfiles: [LegacyProfileGrant], projectedCLI: [String: [CapabilityDescriptor]] = [:],
    manifestProjects: [ComputerMCPCore.RegisteredProject] = []
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
      serverPluginIDs: serverPlugins, manifestProjects: manifestProjects)
  }
}

extension PermissionMigrationCatalog {
  /// A source snapshot uses registration documents and cached classifications.
  /// Resolving plugin declarations inspects files; no provider, helper, program,
  /// or downstream connection is constructed for permission conversion.
  package static func capture(
    configuration: GatewayConfiguration, manifestProfiles: [LegacyProfileGrant],
    configurationDigest: String, plugins: PluginStoreSnapshot,
    applications: any ApplicationBundleLocating, bundledPlugins: BundledPlugins = .current,
    manifestProjects: [ComputerMCPCore.RegisteredProject] = []
  ) throws -> Self {
    let state = plugins.includingBundledDefaults(bundledPlugins.packages.map(\.manifest))
    let resolution = try PluginHost.resolve(
      state, bundled: bundledPlugins, applications: applications)
    var source = configuration
    source.knownPluginMCPServerIDs.formUnion(state.knownMCPRegistrationIDs)
    let composition = try GatewayPluginComposition(
      configuration: source, plugins: resolution.plugins)
    let configuration = composition.runtimeConfiguration
    let knownServers = Set(configuration.mcp.servers.map(\.id)).union(state.knownMCPRegistrationIDs)
    var registrations = Set(
      configuration.mcp.servers.map { IntegrationRegistration(kind: .mcp, id: $0.id) }
        + configuration.cli.commands.map { IntegrationRegistration(kind: .cli, id: $0.id) }
        + configuration.skills.roots.map { IntegrationRegistration(kind: .skills, id: $0.id) })
    registrations.formUnion(knownServers.map { .init(kind: .mcp, id: $0) })
    let enabled = Set(
      configuration.mcp.servers.filter(\.enabled).map {
        IntegrationRegistration(kind: .mcp, id: $0.id)
      }
        + configuration.cli.commands.map { IntegrationRegistration(kind: .cli, id: $0.id) }
        + (configuration.skills.enabled
          ? configuration.skills.roots.map { IntegrationRegistration(kind: .skills, id: $0.id) }
          : []))
    let builtins = Set(
      builtinV1.filter { tool in
        let domain = tool.id.split(separator: ".").first.map(String.init) ?? ""
        switch domain {
        case "cli": return !configuration.cli.commands.isEmpty
        case "mcp": return !knownServers.isEmpty
        case "skills": return configuration.skills.enabled
        case "shell": return configuration.policy.shellEnabled
        case "process", "profile", "policy": return true
        case "computer":
          #if os(macOS)
            return true
          #else
            return false
          #endif
        default:
          return tool.id == "project.list" || tool.id == "project.describe"
            || configuration.builtin.enabled.contains(tool.id)
        }
      }.map(\.id))
    var downstream: [CapabilityDescriptor] = []
    for server in configuration.mcp.servers where server.enabled {
      let mapped = configuration.tools.filter { $0.source == server.id }.compactMap(\.tool)
      let knownTools = Set(mapped).union(server.allowedTools).union(server.toolRisks.keys)
      for name in knownTools.sorted()
      where server.allowAnyTool || server.allowedTools.contains(name) {
        let reference = MCPToolReference(serverID: server.id, toolName: name)
        let aliases = configuration.mcpCapabilityIDs(for: reference)
        guard let id = aliases.sorted().first else { continue }
        downstream.append(
          CapabilityDescriptor(
            id: id, risk: configuration.mcpRisk(for: reference),
            requirement: .none, projectRequirement: .optional,
            usesNetwork: server.transport != .stdio, mcpReference: reference,
            equivalentCapabilityIDs: aliases))
      }
    }
    return try capture(
      configurationDigest: configurationDigest, builtinIDs: builtins,
      downstream: downstream, serverIDs: knownServers, registrations: registrations,
      enabledRegistrations: enabled, origins: composition.origins,
      manifestProfiles: manifestProfiles, manifestProjects: manifestProjects)
  }
}
