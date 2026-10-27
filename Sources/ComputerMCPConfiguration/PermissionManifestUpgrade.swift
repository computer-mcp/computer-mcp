import ComputerMCPCore
import Foundation
import TOML

/// Explicit conversion of the App-owned manifest during profile activation.
/// Ordinary configuration loading always validates the current profile format.
package enum PermissionManifestUpgrade {
  package static func isRequired(manifest: String) throws -> Bool {
    let shape = try TOMLDecoder().decode(ConfigurationNode.self, from: manifest)
    guard case .object(let root) = shape, case .array(let profiles) = root["profiles"] else {
      return false
    }
    return profiles.contains { profile in
      guard case .object(let fields) = profile else { return false }
      let retired: Set<String> = [
        "capabilities", "workspaces", "mode", "full_shell_enabled", "confirmation_policy",
      ]
      if !retired.isDisjoint(with: fields.keys) { return true }
      for name in ["projects", "mcp_servers"] {
        if case .array = fields[name] { return true }
      }
      return false
    }
  }

  package static func source(
    manifest: String,
    baseURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  ) throws -> (configuration: GatewayConfiguration, profiles: [LegacyProfileGrant]) {
    let normalized = try ProjectManifestUpgrade.upgraded(manifest) ?? manifest
    let decoder = TOMLDecoder()
    let shape = try decoder.decode(ConfigurationNode.self, from: normalized)
    let document = try decoder.decode(MigrationDocument.self, from: normalized)
    var configuration = document.configuration
    configuration.projectDirectory = baseURL.standardizedFileURL
    configuration.projects = configuration.projects.map { $0.resolved(base: baseURL) }
    configuration.skills = configuration.skills.resolved(base: baseURL)
    configuration.profiles = document.profiles.map {
      ProfileGrantConfig(grant: ProfileGrant(id: $0.id, allowedCallers: $0.allowedCallers))
    }
    let canonical = try decoder.decode(ConfigurationNode.self, from: configuration.exportedTOML())
    let unknown = shape.fieldPaths.subtracting(canonical.fieldPaths).filter {
      $0 != "profiles" && !$0.hasPrefix("profiles.")
        && $0 != "policy.shell_termination_grace_ms"
    }.sorted()
    guard unknown.isEmpty else {
      throw ConfigurationError.invalid(
        "Unknown configuration fields: " + unknown.joined(separator: ", "))
    }
    if configuration.projects.isEmpty {
      configuration.projects = [
        ProjectManifestConfig(
          id: "default",
          displayName: baseURL.lastPathComponent.isEmpty
            ? "Default Project" : baseURL.lastPathComponent,
          path: baseURL.path)
      ]
    }
    return (configuration, document.profiles)
  }

  package static func upgraded(
    manifest: String, profiles: [ProfileGrant],
    baseURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  ) throws -> GatewayConfiguration {
    var configuration = try source(manifest: manifest, baseURL: baseURL).configuration
    configuration.profiles = profiles.map { ProfileGrantConfig(grant: $0) }
    try configuration.validate()
    return configuration
  }

  private struct MigrationDocument: Decodable {
    let configuration: GatewayConfiguration
    let profiles: [LegacyProfileGrant]
    private enum Keys: String, CodingKey { case profiles }
    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: Keys.self)
      profiles =
        try container.decodeIfPresent([LegacyProfileGrantConfig].self, forKey: .profiles)?
        .map(\.grant) ?? []
      configuration = try GatewayConfiguration(from: decoder, profileOverride: [])
    }
  }
}

private struct LegacyProfileGrantConfig: Decodable {
  package var id: GatewayProfileID
  package var capabilities: [String]
  package var projects: [String]
  package var allowedCallers: [GatewayCallerKind]
  package var fullShellEnabled: Bool
  package var mcpServers: [String]
  package var mode: LegacyPermissionMode
  package var confirmationPolicy: LegacyConfirmationPolicy

  private enum CodingKeys: String, CodingKey {
    case id
    case capabilities
    case projects
    case allowedCallers = "allowed_callers"
    case fullShellEnabled = "full_shell_enabled"
    case mcpServers = "mcp_servers"
    case mode
    case confirmationPolicy = "confirmation_policy"
  }

  package init(from decoder: any Decoder) throws {
    let shape = try ConfigurationNode(from: decoder)
    if case .object(let fields) = shape {
      let known: Set<String> = [
        "id", "capabilities", "projects", "allowed_callers", "full_shell_enabled",
        "mcp_servers", "mode", "confirmation_policy",
      ]
      let unknown = Set(fields.keys).subtracting(known).sorted()
      guard unknown.isEmpty else {
        throw ConfigurationError.invalid(
          "Unknown legacy profile fields: " + unknown.joined(separator: ", "))
      }
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(GatewayProfileID.self, forKey: .id)
    capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
    projects = try container.decodeIfPresent([String].self, forKey: .projects) ?? []
    if let configured = try container.decodeIfPresent(
      [GatewayCallerKind].self,
      forKey: .allowedCallers
    ) {
      allowedCallers = configured
    } else {
      allowedCallers = container.contains(.mode) ? [] : Self.legacyAllowedCallers(for: id)
    }
    fullShellEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .fullShellEnabled) ?? false
    mcpServers = try container.decodeIfPresent([String].self, forKey: .mcpServers) ?? []
    mode =
      try container.decodeIfPresent(LegacyPermissionMode.self, forKey: .mode)
      ?? .legacy(profileID: id, fullShellEnabled: fullShellEnabled)
    confirmationPolicy =
      try container.decodeIfPresent(LegacyConfirmationPolicy.self, forKey: .confirmationPolicy)
      ?? .riskBased
  }

  package var grant: LegacyProfileGrant {
    LegacyProfileGrant(
      id: id,
      capabilityIDs: Set(capabilities),
      projectIDs: Set(projects),
      allowedCallers: Set(allowedCallers),
      fullShellEnabled: fullShellEnabled,
      mcpServerIDs: Set(mcpServers),
      mode: mode,
      confirmationPolicy: confirmationPolicy
    )
  }

  private static func legacyAllowedCallers(for id: GatewayProfileID) -> [GatewayCallerKind] {
    if id == .chatGPTObserve || id == .chatGPTOperate { return [.secureTunnel] }
    if id == .cloudflareObserve || id == .cloudflareOperate { return [.cloudflareTunnel] }
    if id == .localAdmin { return [.localApp, .localCLI, .localMCP] }
    return []
  }
}
