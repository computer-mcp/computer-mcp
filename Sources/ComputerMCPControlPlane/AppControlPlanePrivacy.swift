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
  fileprivate let sourceReview: GatewayProviderReview?
  package var sourceDigest: String? { sourceReview?.sourceDigest }
  package var declarations: PluginPermissionDeclarations? { sourceReview?.declarations }
  package let declarationDigest: String?
  package let limits: ManagedLimits
  package let effectiveMode: ExecutionMode?
  package let permissionRevision: UInt64
  package let epoch: UUID?
}

package struct PrivacyPermissionInventory: Sendable {
  package let permissions: GatewayPermissionView
  package let names: PermissionObjectNames
  package let projects: [ComputerMCPCore.RegisteredProject]
  package let providers: [ProviderPermissionOptions]
}

extension AppControlPlaneService {
  package func privacyPermissionInventory() throws -> PrivacyPermissionInventory {
    guard !configurationMutationInProgress else { throw PluginHostError.changeInProgress }
    let inputs = try gatewayInputs()
    let packages = inputs.plugins.includingBundledDefaults(bundledPlugins.packages.map(\.manifest))
    let resolved = try PluginHost.resolve(
      packages, bundled: bundledPlugins, applications: platform.applications)
    let composition = try GatewayPluginComposition(
      configuration: inputs.configuration, plugins: resolved.plugins)
    var pluginIDs = Set(bundledPlugins.packages.map { $0.manifest.id })
    pluginIDs.formUnion(packages.installations.map(\.pluginID))
    let knownServers = Set(inputs.configuration.mcp.servers.map(\.id))
    let directServers = inputs.configuration.mcp.servers.filter {
      $0.transport == .stdio && !packages.knownMCPRegistrationIDs.contains($0.id)
    }
    let configured = Set(pluginIDs.map(PluginIdentity.package))
      .union(directServers.map { .localServer($0.id) })
    let view = try requirePermissionControl().view(providerIDs: configured)
    let saved = Dictionary(uniqueKeysWithValues: view.providers.map { ($0.identity, $0) })
    let identities = configured.union(saved.keys)
    var pluginNames: [String: String] = [:]
    let serverNames = Dictionary(
      uniqueKeysWithValues: composition.runtimeConfiguration.mcp.servers.map {
        let origin = composition.origins[.init(kind: .mcp, id: $0.id)]
        let manifest = bundledPlugins.packages.first { $0.manifest.id == origin?.pluginID }?
          .manifest
        return (
          $0.id, origin.map { "\(manifest?.name ?? $0.pluginID) · \($0.componentID)" } ?? $0.id
        )
      })
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
        review = try server.map {
          try GatewayProviderReview(
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
        permissionRevision: view.revision, epoch: view.epoch)
    }.sorted {
      (String(describing: $0.identity), $0.name) < (String(describing: $1.identity), $1.name)
    }
    try requireCurrentGatewayInputs(inputs)
    return PrivacyPermissionInventory(
      permissions: view,
      names: .init(
        projects: Dictionary(uniqueKeysWithValues: inputs.projects.map { ($0.id, $0.displayName) }),
        plugins: pluginNames, mcpServers: serverNames),
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
