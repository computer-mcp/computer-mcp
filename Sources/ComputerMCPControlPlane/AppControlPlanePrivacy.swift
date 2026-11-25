import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPGateway
import ComputerMCPPermissions
import ComputerMCPPlugins
import Foundation

package struct ProviderPermissionOptions: Equatable, Sendable {
  package enum Availability: Equatable, Sendable {
    case unavailable, disabled, needsApproval, needsSourceReview, needsRestoreReview, active
  }

  package let identity: PluginIdentity
  package let name: String
  package let version: String?
  package let availability: Availability
  package let approval: GatewayProviderApproval?
  let sourceReview: GatewayProviderReview?
  package var sourceDigest: String? { sourceReview?.sourceDigest }
  package var declarations: PluginPermissionDeclarations? { sourceReview?.declarations }
  package let declarationDigest: String?
  package let limits: ManagedLimits
  package let effectiveMode: ExecutionMode?
  package let permissionRevision: UInt64
  package let epoch: UUID?
  let manifestDigest: String?
}

package struct PrivacyPermissionInventory: Sendable {
  package let permissions: GatewayPermissionView
  package let names: PermissionObjectNames
  package let projects: [ComputerMCPCore.RegisteredProject]
  package let providers: [ProviderPermissionOptions]
}

extension AppControlPlaneService {
  package func privacyPermissionInventory(additionalProvider: PluginIdentity? = nil) throws
    -> PrivacyPermissionInventory
  {
    guard !configurationMutationInProgress else { throw PluginHostError.changeInProgress }
    let inputs = try gatewayInputs()
    let manifestDigest = try? manifestStore.admittedDigest(for: inputs.configuration)
    let packages = inputs.plugins.includingBundledDefaults(bundledPlugins.packages.map(\.manifest))
    let resolved = try PluginHost.resolve(
      packages, bundled: bundledPlugins, applications: platform.applications)
    let composition = try GatewayPluginComposition(
      configuration: inputs.configuration, plugins: resolved.plugins)
    var pluginIDs = Set(bundledPlugins.packages.map { $0.manifest.id })
    pluginIDs.formUnion(packages.installations.map(\.pluginID))
    let knownServers = Set(inputs.configuration.mcp.servers.map(\.id))
    let directServers = inputs.configuration.mcp.servers.filter { $0.transport == .stdio }
    let configured = Set(pluginIDs.map(PluginIdentity.package))
      .union(directServers.map { .localServer($0.id) })
    let view = try requirePermissionControl().view(
      providerIDs: configured.union(additionalProvider.map { [$0] } ?? []))
    let saved = Dictionary(uniqueKeysWithValues: view.providers.map { ($0.identity, $0) })
    let identities = configured.union(saved.keys)
    var pluginNames: [String: String] = [:]
    // Gateway admission resolves package contributions through their owning plugin.
    let serverObjects = composition.runtimeConfiguration.mcp.servers.filter {
      composition.origins[.init(kind: .mcp, id: $0.id)] == nil
    }
    let providers = try identities.map { identity in
      let review: GatewayProviderReview?
      let name: String
      let version: String?
      let enabled: Bool
      switch identity {
      case .package(let id):
        let package = try? providerPackage(id, configuration: inputs.persisted)
        review = package.flatMap { package -> GatewayProviderReview? in
          guard package.manifest.id == id else { return nil }
          return try? GatewayProviderReview(
            package: package, configuration: inputs.persisted, knownPluginIDs: pluginIDs,
            knownServerIDs: knownServers)
        }
        name = package?.manifest.name ?? id
        version = package?.manifest.version.description
        enabled = resolved.plugins.contains { $0.id == id }
        if pluginIDs.contains(id) { pluginNames[id] = name }
      case .localServer(let id):
        let server = directServers.first { $0.id == id }
        review = server.flatMap {
          try? GatewayProviderReview(
            server: $0, configuration: inputs.persisted, knownPluginIDs: pluginIDs,
            knownServerIDs: knownServers)
        }
        name = id
        version = nil
        enabled = server?.enabled == true
      }
      let approval = saved[identity]
      let availability: ProviderPermissionOptions.Availability
      if review == nil {
        availability = .unavailable
      } else if view.suspended || (approval.map { $0.epoch != view.epoch } ?? false) {
        availability = .needsRestoreReview
      } else if let approval {
        if approval.sourceDigest != review?.sourceDigest {
          availability = .needsSourceReview
        } else {
          availability = enabled && approval.enabled ? .active : .disabled
        }
      } else {
        availability = .needsApproval
      }
      let mode: ExecutionMode? =
        if availability != .active { nil } else if let consent = approval?.fullAccessConsent {
          view.providerFullAccess.contains(identity) ? consent.mode : nil
        } else { .sandbox }
      return ProviderPermissionOptions(
        identity: identity, name: name, version: version, availability: availability,
        approval: approval,
        sourceReview: review,
        declarationDigest: try review?.declarations?.digest(),
        limits: view.providerLimits[identity] ?? .init(), effectiveMode: mode,
        permissionRevision: view.revision, epoch: view.epoch, manifestDigest: manifestDigest)
    }.sorted {
      (String(describing: $0.identity), $0.name) < (String(describing: $1.identity), $1.name)
    }
    try requireCurrentGatewayInputs(inputs)
    return PrivacyPermissionInventory(
      permissions: view,
      names: .init(
        projects: Dictionary(uniqueKeysWithValues: inputs.projects.map { ($0.id, $0.displayName) }),
        plugins: pluginNames,
        mcpServers: Dictionary(uniqueKeysWithValues: serverObjects.map { ($0.id, $0.id) }),
        enabledMCPServerIDs: Set(serverObjects.filter(\.enabled).map(\.id))),
      projects: inputs.projects, providers: providers)
  }

  package func saveProviderPermissions(
    reviewed: ProviderPermissionOptions, permissions: Permissions, fullAccess: Bool,
    sandboxSettings: ProviderSandboxSettings, editingApproval: Bool = false
  ) async throws -> GatewayProviderApproval {
    guard let epoch = reviewed.epoch, let review = reviewed.sourceReview else {
      throw GatewayPermissionError.invalidBinding
    }
    return try await approveProvider(
      review, permissions: permissions, fullAccess: fullAccess, sandboxSettings: sandboxSettings,
      expectedProviderRevision: reviewed.approval?.revision,
      expectedRevision: reviewed.permissionRevision, expectedEpoch: epoch,
      editingApproval: editingApproval, reviewedLimits: reviewed.limits)
  }

  package func revokeProviderPermissions(reviewed: ProviderPermissionOptions) throws {
    guard let epoch = reviewed.epoch, let approval = reviewed.approval else {
      throw GatewayPermissionError.invalidBinding
    }
    _ = try requirePermissionControl().revokeProvider(
      reviewed.identity, expectedProviderRevision: approval.revision,
      expectedRevision: reviewed.permissionRevision, expectedEpoch: epoch,
      expectedSourceDigest: approval.sourceDigest)
  }
}

extension AppControlPlaneOperations {
  package func saveProviderPermissions(
    reviewed: ProviderPermissionOptions, permissions: Permissions, fullAccess: Bool,
    sandboxSettings: ProviderSandboxSettings, editingApproval: Bool
  ) async throws {
    if !editingApproval, case .package(let id) = reviewed.identity {
      guard let source = reviewed.sourceReview, let digest = reviewed.manifestDigest else {
        throw GatewayPermissionError.revisionConflict
      }
      let revision = source.pluginStoreRevision
      let approval = ProviderEnablementApproval(
        provider: reviewed,
        target: .plugin(expectedRevision: revision, settings: nil, manifestDigest: digest),
        selection: .init(
          permissions: permissions, sandboxSettings: sandboxSettings, fullAccess: fullAccess))
      _ = try await changePlugins(
        .enabled(pluginID: id, true), expectedRevision: revision,
        approval: approval)
    } else {
      _ = try await controlPlane.saveProviderPermissions(
        reviewed: reviewed, permissions: permissions, fullAccess: fullAccess,
        sandboxSettings: sandboxSettings, editingApproval: editingApproval)
    }
  }
}

extension AppControlPlaneService {
  package func projectWorktreeInventory() async throws -> [ProjectWorktreeInventory] {
    _ = try requirePermissionControl().view()
    let database = database
    let platform = platform
    let task = Task.detached { try database.projectWorktreeInventory(platform: platform) }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
}
