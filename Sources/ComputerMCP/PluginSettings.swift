import Foundation

/// Mutable host choices, independent of installed versions and immutable package declarations.
package struct PluginSettings: Codable, Equatable, Sendable {
  package var enabled = false
  package var mcp: [String: PluginMCPSettings] = [:]
  package var cli: [String: PluginCLISettings] = [:]
  package var skills: [String: PluginSkillSettings] = [:]
  package var dependencyExecutables: [String: String] = [:]

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case enabled, mcp, cli, skills, dependencyExecutables
  }

  package init(from decoder: any Decoder) throws {
    let values = try decoder.pluginContainer(keyedBy: CodingKeys.self)
    enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    mcp = try values.decodeIfPresent([String: PluginMCPSettings].self, forKey: .mcp) ?? [:]
    cli = try values.decodeIfPresent([String: PluginCLISettings].self, forKey: .cli) ?? [:]
    skills = try values.decodeIfPresent([String: PluginSkillSettings].self, forKey: .skills) ?? [:]
    dependencyExecutables =
      try values.decodeIfPresent([String: String].self, forKey: .dependencyExecutables) ?? [:]
    try validate()
  }

  package init(
    enabled: Bool = false,
    mcp: [String: PluginMCPSettings] = [:],
    cli: [String: PluginCLISettings] = [:],
    skills: [String: PluginSkillSettings] = [:],
    dependencyExecutables: [String: String] = [:]
  ) {
    self.enabled = enabled
    self.mcp = mcp
    self.cli = cli
    self.skills = skills
    self.dependencyExecutables = dependencyExecutables
  }

  func validate() throws {
    for (id, path) in dependencyExecutables {
      try validatePluginID(id)
      guard path.hasPrefix("/"), !path.contains("\0") else {
        throw ConfigurationError.invalid(
          "External executable bindings require absolute, NUL-free paths.")
      }
    }
    for id in Array(mcp.keys) + Array(cli.keys) + Array(skills.keys) {
      try validatePluginID(id)
    }
    for choice in mcp.values {
      if let args = choice.args {
        guard args.count <= 1_024, args.allSatisfy({ !$0.contains("\0") }),
          args.reduce(0, { $0 + $1.utf8.count }) <= 262_144
        else {
          throw ConfigurationError.invalid(
            "Plugin MCP launch arguments exceed their limits or contain NUL.")
        }
      }
      guard !choice.allowAnyTool || choice.allowedTools.isEmpty,
        Set(choice.allowedTools).count == choice.allowedTools.count,
        (choice.allowedTools + choice.toolRisks.keys).allSatisfy({
          !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.contains("\0")
        })
      else {
        throw ConfigurationError.invalid("Plugin MCP tool selection or risk names are invalid.")
      }
      if let prefix = choice.prefix, !prefix.isEmpty {
        try validatePluginID(prefix, allowDots: true)
      }
    }
    let ids =
      mcp.values.compactMap(\.registrationID) + cli.values.compactMap(\.registrationID)
      + skills.values.compactMap(\.registrationID)
    guard
      ids.allSatisfy({
        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.contains("\0")
      })
    else {
      throw ConfigurationError.invalid("Plugin registration IDs must be nonempty and NUL-free.")
    }
  }
}

package struct PluginMCPSettings: Codable, Equatable, Sendable {
  package var enabled = true
  package var hostServices = false
  package var authentication: MCPHTTPAuthentication?
  /// Nil follows package defaults; an empty array explicitly starts without arguments.
  package var args: [String]?
  package var registrationID: String?
  package var exposure: MCPExposure = .gateway
  /// Nil follows the package/registration default; empty explicitly preserves native tool names.
  package var prefix: String?
  package var allowAnyTool = false
  package var allowedTools: [String] = []
  package var toolRisks: [String: CapabilityRisk] = [:]

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case enabled, args, registrationID, exposure, prefix, allowAnyTool, allowedTools, toolRisks
    case hostServices, authentication
  }

  package init(from decoder: any Decoder) throws {
    let values = try decoder.pluginContainer(keyedBy: CodingKeys.self)
    enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    hostServices = try values.decodeIfPresent(Bool.self, forKey: .hostServices) ?? false
    authentication = try values.decodeIfPresent(MCPHTTPAuthentication.self, forKey: .authentication)
    args = try values.decodeIfPresent([String].self, forKey: .args)
    registrationID = try values.decodeIfPresent(String.self, forKey: .registrationID)
    exposure = try values.decodeIfPresent(MCPExposure.self, forKey: .exposure) ?? .gateway
    prefix = try values.decodeIfPresent(String.self, forKey: .prefix)
    allowAnyTool = try values.decodeIfPresent(Bool.self, forKey: .allowAnyTool) ?? false
    allowedTools = try values.decodeIfPresent([String].self, forKey: .allowedTools) ?? []
    toolRisks = try values.decodeIfPresent([String: CapabilityRisk].self, forKey: .toolRisks) ?? [:]
  }

  package init(
    enabled: Bool = true, registrationID: String? = nil, exposure: MCPExposure = .gateway,
    prefix: String? = nil, allowAnyTool: Bool = false, allowedTools: [String] = [],
    toolRisks: [String: CapabilityRisk] = [:], args: [String]? = nil, hostServices: Bool = false,
    authentication: MCPHTTPAuthentication? = nil
  ) {
    self.enabled = enabled
    self.hostServices = hostServices
    self.authentication = authentication
    self.registrationID = registrationID
    self.exposure = exposure
    self.prefix = prefix
    self.allowAnyTool = allowAnyTool
    self.allowedTools = allowedTools
    self.toolRisks = toolRisks
    self.args = args
  }
}

package struct PluginCLISettings: Codable, Equatable, Sendable {
  package var enabled = true
  package var registrationID: String?
  package var allowAnyArgs = false

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case enabled, registrationID, allowAnyArgs
  }

  package init(from decoder: any Decoder) throws {
    let values = try decoder.pluginContainer(keyedBy: CodingKeys.self)
    enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    registrationID = try values.decodeIfPresent(String.self, forKey: .registrationID)
    allowAnyArgs = try values.decodeIfPresent(Bool.self, forKey: .allowAnyArgs) ?? false
  }

  package init(enabled: Bool = true, registrationID: String? = nil, allowAnyArgs: Bool = false) {
    self.enabled = enabled
    self.registrationID = registrationID
    self.allowAnyArgs = allowAnyArgs
  }
}

package struct PluginSkillSettings: Codable, Equatable, Sendable {
  package var enabled = true
  package var registrationID: String?

  private enum CodingKeys: String, CodingKey, CaseIterable { case enabled, registrationID }

  package init(from decoder: any Decoder) throws {
    let values = try decoder.pluginContainer(keyedBy: CodingKeys.self)
    enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    registrationID = try values.decodeIfPresent(String.self, forKey: .registrationID)
  }

  package init(enabled: Bool = true, registrationID: String? = nil) {
    self.enabled = enabled
    self.registrationID = registrationID
  }
}

package enum PluginSourceKind: String, Codable, Sendable {
  case bundled
  case artifact
  case development
}

/// Host-owned provenance. It is never decoded from a plugin manifest.
package struct PluginSource: Codable, Equatable, Sendable {
  package let kind: PluginSourceKind
  package let root: URL
  package let repository: String?
  package let revision: String?
  package let artifactSHA256: String?
  /// Public GitHub metadata verified during installation, not a code-signing assertion.
  package let githubRelease: GitHubPluginArtifact?

  package init(
    kind: PluginSourceKind, root: URL, repository: String? = nil, revision: String? = nil,
    artifactSHA256: String? = nil, githubRelease: GitHubPluginArtifact? = nil
  ) {
    self.kind = kind
    self.root = root
    self.repository = repository
    self.revision = revision
    self.artifactSHA256 = artifactSHA256
    self.githubRelease = githubRelease
  }
}
