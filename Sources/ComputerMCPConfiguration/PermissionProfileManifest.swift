import ComputerMCPCore
import ComputerMCPPermissions
import Foundation
import TOML

/// The manifest representation of stored profile permissions and settings.
package enum PermissionProfileManifest {
  package static func decode(_ text: String) throws -> [ProfileGrant] {
    let documents = try TOMLDecoder().decode(Document.self, from: text).profiles
    guard Set(documents.map { $0.profile.id }).count == documents.count else {
      throw ConfigurationError.invalid("profiles contains duplicate IDs.")
    }
    return documents.map(\.profile)
  }

  package static func encode(_ profiles: [ProfileGrant]) throws -> String {
    let encoder = TOMLEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encodeToString(
      Document(
        profiles: profiles.sorted { $0.id.rawValue < $1.id.rawValue }.map(ProfileDocument.init)))
  }

  private struct Document: Codable { let profiles: [ProfileDocument] }
}

struct ProfileDocument: Codable {
  let profile: ProfileGrant
  init(_ profile: ProfileGrant) { self.profile = profile }

  private static let privacy = PermissionManifestVocabulary.privacy
  private static let folders = PermissionManifestVocabulary.folders

  private static let bundleIdentifierCharacters = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-.")

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: ProfileKey.self)
    let replacements = [
      "capabilities": "permissions, projects, plugins and mcp_servers tables",
      "workspaces": "projects table with access and network",
      "mode": "full_access and permission tables",
      "full_shell_enabled": "full_access (with local consent)",
      "confirmation_policy": "permission grants; calls within grants execute directly",
      "authorization_revision": "host-owned authorization revisions",
    ]
    for name in replacements.keys.sorted() where c.contains(ProfileKey(name)) {
      throw ConfigurationError.invalid("profiles.\(name) is obsolete; use \(replacements[name]!).")
    }
    let keys: Set<String> = [
      "id", "allowed_callers", "full_access", "permissions", "projects", "files_and_folders",
      "plugins", "mcp_servers", "automation",
    ]
    for key in c.allKeys where !keys.contains(key.stringValue) {
      throw ConfigurationError.invalid("Unknown profile field: \(key.stringValue).")
    }
    let id = try c.decode(GatewayProfileID.self, forKey: ProfileKey("id"))
    let callers = try c.decode(Set<GatewayCallerKind>.self, forKey: ProfileKey("allowed_callers"))
    if id == .localAdmin && callers.contains(where: \.isRemote) {
      throw GatewayPolicyConfigurationError.localAdminCannotBeRemote
    }
    var permissions = Permissions()
    for (name, value) in try c.decodeIfPresent(
      [String: String].self, forKey: ProfileKey("permissions")) ?? [:]
    {
      guard let permission = Self.privacy[name] else {
        throw ConfigurationError.invalid("Unknown permission: \(name).")
      }
      try permissions.set(Self.state(value, allowed: "allow", value: .access), for: permission)
    }
    var networks: [String: NetworkAccess] = [:]
    if c.contains(ProfileKey("projects")) {
      if (try? c.decode([String].self, forKey: ProfileKey("projects"))) != nil {
        throw ConfigurationError.invalid(
          "profiles.projects must be a table; replace the old array with access and network entries."
        )
      }
      for (id, project) in try c.decode(
        [String: ProjectDocument].self, forKey: ProfileKey("projects"))
      {
        try Self.validateObject(id)
        if let access = project.access {
          let state: PermissionState
          switch access {
          case "read": state = .granted(.read)
          case "write": state = .granted(.write)
          case "deny": state = .denied
          default: throw ConfigurationError.invalid("Project access must be read, write or deny.")
          }
          try permissions.set(state, for: .project(id))
        }
        if let network = project.network { networks[id] = network.value }
      }
    }
    for (name, value) in try c.decodeIfPresent(
      [String: String].self, forKey: ProfileKey("files_and_folders")) ?? [:]
    {
      guard let category = Self.folders[name] else {
        throw ConfigurationError.invalid("Unknown folder category: \(name).")
      }
      try permissions.set(
        Self.state(value, allowed: "read", value: .read), for: .filesAndFolders(category))
    }
    for (id, value) in try c.decodeIfPresent([String: String].self, forKey: ProfileKey("plugins"))
      ?? [:]
    {
      try Self.validateObject(id)
      try permissions.set(Self.state(value, allowed: "use", value: .use), for: .plugin(id))
    }
    if c.contains(ProfileKey("mcp_servers")) {
      if (try? c.decode([String].self, forKey: ProfileKey("mcp_servers"))) != nil {
        throw ConfigurationError.invalid(
          "profiles.mcp_servers must be a table; replace the old array with read, all or deny entries."
        )
      }
      for (id, value) in try c.decode([String: String].self, forKey: ProfileKey("mcp_servers")) {
        try Self.validateObject(id)
        let state: PermissionState
        switch value {
        case "read": state = .granted(.read)
        case "all": state = .granted(.all)
        case "deny": state = .denied
        default: throw ConfigurationError.invalid("MCP server access must be read, all or deny.")
        }
        try permissions.set(state, for: .mcpServer(id))
      }
    }
    let automation =
      try c.decodeIfPresent(
        [String: ProfileGrant.AutomationAccess].self, forKey: ProfileKey("automation")) ?? [:]
    for id in automation.keys {
      guard id != "*", id.utf8.count <= 256, id.contains("."),
        !id.split(separator: ".", omittingEmptySubsequences: false).contains(where: \.isEmpty),
        id.unicodeScalars.allSatisfy(Self.bundleIdentifierCharacters.contains)
      else {
        throw ConfigurationError.invalid(
          "Automation requires a concrete application bundle identifier.")
      }
    }
    profile = ProfileGrant(
      id: id, permissions: permissions, projectNetworks: networks,
      automation: automation,
      fullAccess: try c.decodeIfPresent(Bool.self, forKey: ProfileKey("full_access")) ?? false,
      allowedCallers: callers, authorizationRevision: 1)
  }

  func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: ProfileKey.self)
    try c.encode(profile.id, forKey: ProfileKey("id"))
    try c.encode(
      profile.allowedCallers.map(\.rawValue).sorted(), forKey: ProfileKey("allowed_callers"))
    try c.encode(profile.fullAccess, forKey: ProfileKey("full_access"))
    var privacy: [String: String] = [:]
    var folders: [String: String] = [:]
    var projects: [String: ProjectDocument] = [:]
    var plugins: [String: String] = [:]
    var servers: [String: String] = [:]
    for (permission, state) in profile.permissions.entries {
      let value: String
      switch state {
      case .notGranted:
        throw ConfigurationError.invalid(
          "An explicit not-granted override cannot be represented in a manifest; remove its fallback grant or choose deny."
        )
      case .denied: value = "deny"
      case .granted(let grant): value = grant == .access ? "allow" : grant.rawValue
      }
      switch permission {
      case .project(let id):
        projects[id] = ProjectDocument(
          access: value, network: profile.projectNetworks[id].map(NetworkDocument.init))
      case .plugin(let id): plugins[id] = value
      case .mcpServer(let id): servers[id] = value
      case .filesAndFolders(let category):
        folders[Self.folders.first { $0.value == category }!.key] = value
      case .screen, .desktopControl, .localNetwork, .machineInformation, .unifiedLogs, .skills:
        privacy[Self.privacy.first(where: { $0.value == permission })!.key] = value
      }
    }
    for (id, network) in profile.projectNetworks where projects[id] == nil {
      try Self.validateObject(id)
      projects[id] = ProjectDocument(access: nil, network: NetworkDocument(network))
    }
    try c.encode(privacy, forKey: ProfileKey("permissions"))
    try c.encode(projects, forKey: ProfileKey("projects"))
    try c.encode(folders, forKey: ProfileKey("files_and_folders"))
    try c.encode(plugins, forKey: ProfileKey("plugins"))
    try c.encode(servers, forKey: ProfileKey("mcp_servers"))
    try c.encode(profile.automation, forKey: ProfileKey("automation"))
  }

  private static func state(_ text: String, allowed: String, value: PermissionValue) throws
    -> PermissionState
  {
    switch text {
    case allowed: .granted(value)
    case "deny": .denied
    default: throw ConfigurationError.invalid("Permission value must be \(allowed) or deny.")
    }
  }

  private static func validateObject(_ id: String) throws {
    try PermissionManifestVocabulary.validateObject(id)
  }
}

private struct ProfileKey: CodingKey {
  let stringValue: String
  var intValue: Int? { nil }
  init(_ value: String) { stringValue = value }
  init?(stringValue: String) { self.init(stringValue) }
  init?(intValue: Int) { return nil }
}

private struct ProjectDocument: Codable {
  let access: String?
  let network: NetworkDocument?
  init(access: String?, network: NetworkDocument?) {
    self.access = access
    self.network = network
  }
  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: ProfileKey.self)
    guard c.allKeys.allSatisfy({ ["access", "network"].contains($0.stringValue) }) else {
      throw ConfigurationError.invalid("Project entries accept access and network.")
    }
    guard c.contains(ProfileKey("access")) || c.contains(ProfileKey("network")) else {
      throw ConfigurationError.invalid("Project entries require access or network.")
    }
    access = try c.decodeIfPresent(String.self, forKey: ProfileKey("access"))
    network = try c.decodeIfPresent(NetworkDocument.self, forKey: ProfileKey("network"))
  }
}

struct NetworkDocument: Codable {
  let value: NetworkAccess
  init(_ value: NetworkAccess) { self.value = value }
  init(from decoder: any Decoder) throws {
    if let string = try? decoder.singleValueContainer().decode(String.self) {
      switch string {
      case "none": value = .none
      case "trusted": value = .trusted
      case "full": value = .full
      default:
        throw ConfigurationError.invalid("Network must be none, trusted, full or a custom table.")
      }
    } else {
      let c = try decoder.container(keyedBy: ProfileKey.self)
      guard
        c.allKeys.allSatisfy({ ["level", "hosts", "include_trusted"].contains($0.stringValue) }),
        (try? c.decode(String.self, forKey: ProfileKey("level"))) == "custom",
        (try? c.decode([String].self, forKey: ProfileKey("hosts"))) != nil,
        (try? c.decode(Bool.self, forKey: ProfileKey("include_trusted"))) != nil
      else {
        throw ConfigurationError.invalid(
          "Custom network requires level = custom, hosts and include_trusted.")
      }
      let hosts = try c.decode([String].self, forKey: ProfileKey("hosts"))
      for host in hosts {
        guard NetworkHost.contains(host, rule: host) else {
          throw ConfigurationError.invalid("Invalid custom network host rule.")
        }
      }
      value = .custom(
        hosts: Set(hosts.map(NetworkHost.canonical)),
        includesTrusted: try c.decode(Bool.self, forKey: ProfileKey("include_trusted")))
    }
  }
  func encode(to encoder: any Encoder) throws {
    switch value.configuration {
    case .none, .trusted, .full:
      var c = encoder.singleValueContainer()
      let name =
        value.configuration == .none ? "none" : value.configuration == .trusted ? "trusted" : "full"
      try c.encode(name)
    case .custom(let hosts, let includesTrusted):
      var c = encoder.container(keyedBy: ProfileKey.self)
      try c.encode("custom", forKey: ProfileKey("level"))
      try c.encode(hosts.sorted(), forKey: ProfileKey("hosts"))
      try c.encode(includesTrusted, forKey: ProfileKey("include_trusted"))
    }
  }
}
