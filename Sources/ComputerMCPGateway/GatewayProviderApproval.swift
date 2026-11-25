import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPPlugins
import Crypto
import Foundation

/// Host-verified input to owner review, pinned to the observed configuration and source.
package struct GatewayProviderReview: Equatable, Sendable {
  package let identity: PluginIdentity
  package let sourceDigest: String
  package let declarations: PluginPermissionDeclarations?
  let configuration: GatewayDatabase.ConfigurationState
  package let pluginIDs: Set<String>
  package let serverIDs: Set<String>

  package var pluginStoreRevision: Int64 { configuration.plugins.revision }

  package init(
    package: PluginPackage, configuration: GatewayDatabase.ConfigurationState,
    knownPluginIDs: Set<String> = [], knownServerIDs: Set<String> = []
  ) throws {
    self.configuration = configuration
    pluginIDs = knownPluginIDs.union(configuration.plugins.installations.map(\.pluginID))
      .union([package.manifest.id])
    serverIDs = knownServerIDs.subtracting(configuration.plugins.knownMCPRegistrationIDs)
    identity = .package(package.manifest.id)
    sourceDigest = try PluginStore.manifestDigest(package.manifest)
    declarations = PluginPermissionDeclarations(package.manifest)
    if let selected = configuration.plugins.selectedInstallations[package.manifest.id] {
      guard
        configuration.plugins.installations.contains(where: {
          $0.id == selected && $0.source.root == package.root && $0.manifestDigest == sourceDigest
        })
      else { throw PluginStoreError.manifestChanged(package.manifest.id) }
    }
  }

  package init(
    server: MCPServerConfig, configuration: GatewayDatabase.ConfigurationState,
    knownPluginIDs: Set<String> = [], knownServerIDs: Set<String> = []
  ) throws {
    guard server.transport == .stdio,
      !configuration.plugins.knownMCPRegistrationIDs.contains(server.id)
    else { throw GatewayPermissionError.invalidBinding }
    identity = .localServer(server.id)
    sourceDigest = try Self.digest(server)
    declarations = nil
    self.configuration = configuration
    pluginIDs = knownPluginIDs.union(configuration.plugins.installations.map(\.pluginID))
    serverIDs = knownServerIDs.union([server.id]).subtracting(
      configuration.plugins.knownMCPRegistrationIDs)
  }

  static func digest(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
  }
}

/// Owner proof and review expectations carried into configuration publication.
package struct GatewayProviderActivation: Sendable {
  let review: GatewayProviderReview
  let permissions: Permissions
  let fullAccess: Bool
  let sandboxSettings: ProviderSandboxSettings
  let owner: GatewayPermissionOwner
  let expectedProviderRevision: Int64?
  let expectedRevision: UInt64
  let expectedEpoch: UUID
  let limits: ManagedLimits

  package init(
    review: GatewayProviderReview, permissions: Permissions, fullAccess: Bool,
    sandboxSettings: ProviderSandboxSettings, owner: GatewayPermissionOwner,
    expectedProviderRevision: Int64?, expectedRevision: UInt64, expectedEpoch: UUID,
    limits: ManagedLimits
  ) {
    self.review = review
    self.permissions = permissions
    self.fullAccess = fullAccess
    self.sandboxSettings = sandboxSettings
    self.owner = owner
    self.expectedProviderRevision = expectedProviderRevision
    self.expectedRevision = expectedRevision
    self.expectedEpoch = expectedEpoch
    self.limits = limits
  }
}

/// The approved projection stays intact while a wider source waits for owner review.
package struct GatewayProviderApproval: Codable, Equatable, Sendable {
  package let identity: PluginIdentity
  package var revision: Int64
  package let epoch: UUID
  package var enabled: Bool
  package var sourceDigest: String
  package var declarations: PluginPermissionDeclarations?
  package var declarationDigest: String?
  package var permissions: Permissions
  package var fullAccessConsent: ModeConsent?
  package var sandboxSettings: ProviderSandboxSettings?
  package var pendingSourceDigest: String?
  package var pendingDeclarations: PluginPermissionDeclarations?
  package var update: PluginDeclarationUpdate

  package var principal: Principal { .plugin(identity) }
  var requirementDigest: String {
    declarationDigest.map { sourceDigest + ":" + $0 } ?? sourceDigest
  }

  func validate() throws {
    guard revision > 0, sourceDigest.count == 64,
      declarationDigest == (try declarations?.digest()),
      fullAccessConsent == nil || fullAccessConsent?.mode == .fullAccess(.standing)
    else { throw GatewayPermissionError.invalidBinding }
    switch identity {
    case .package: guard declarations != nil else { throw GatewayPermissionError.invalidBinding }
    case .localServer:
      guard declarations == nil else { throw GatewayPermissionError.invalidBinding }
    }
    if let declarations {
      try Self.validate(permissions, declarations: declarations)
      if let settings = sandboxSettings {
        guard
          settings.defaults.networkCeiling?.configuration
            == (declarations.sandbox?.network?.value ?? .none).configuration
        else {
          throw GatewayPermissionError.invalidBinding
        }
        let requested = Set(declarations.sandbox?.readExceptions?.map(\.path) ?? [])
        for value in [settings.defaults]
          + settings.projects.keys.map({ settings.settings(sourceProjectID: $0) })
        {
          guard Set(value.readExceptions.map(\.declaredPath)).isSubset(of: requested) else {
            throw GatewayPermissionError.invalidBinding
          }
        }
      }
    }
  }

  static func validate(_ permissions: Permissions, declarations: PluginPermissionDeclarations)
    throws
  {
    for (permission, state) in permissions.entries {
      guard case .granted(let value) = state else { continue }
      if permission == .machineInformation || permission == .skills { continue }
      guard
        declarations.permissions.contains(where: {
          $0.matches(permission) && PermissionState.granted($0.value).allows(value)
        })
      else { throw GatewayPermissionError.invalidBinding }
    }
  }

  /// Narrowing never removes an explicit deny or promotes an unselected object.
  mutating func narrow(to declarations: PluginPermissionDeclarations) throws {
    var requested: [String: String] = [:]
    for exception in declarations.sandbox?.readExceptions ?? [] {
      guard requested.updateValue(exception.purpose, forKey: exception.path) == nil else {
        throw GatewayPermissionError.invalidBinding
      }
    }
    for (permission, state) in permissions.entries {
      guard case .granted(let prior) = state,
        permission != .machineInformation, permission != .skills
      else { continue }
      if let declaration = declarations.permissions.first(where: { $0.matches(permission) }) {
        if !PermissionState.granted(declaration.value).allows(prior) {
          try permissions.set(.granted(declaration.value), for: permission)
        }
      } else {
        try permissions.set(.notGranted, for: permission)
      }
    }
    if declarations.sandbox?.fullAccess != true { fullAccessConsent = nil }
    if var settings = sandboxSettings {
      func retained(_ values: Set<ApprovedReadException>) -> Set<ApprovedReadException> {
        Set(
          values.compactMap { original in
            guard let purpose = requested[original.declaredPath] else { return nil }
            var value = original
            value.purpose = purpose
            return value
          })
      }
      settings.defaults.readExceptions = retained(settings.defaults.readExceptions)
      let ceiling = declarations.sandbox?.network?.value ?? .none
      if settings.defaults.networkCeiling?.configuration != ceiling.configuration {
        settings.defaults.networkCeiling = ceiling
      }
      for id in settings.projects.keys {
        if let values = settings.projects[id]?.readExceptions {
          settings.projects[id]!.readExceptions = retained(values)
        }
      }
      sandboxSettings = settings
    }
    self.declarations = declarations
    declarationDigest = try declarations.digest()
  }
}
