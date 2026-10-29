import ComputerMCPPermissions
import Crypto
import Foundation

/// Portable requests for owner review. These values do not contain grants or object selections.
package struct PluginPermissionDeclaration: Codable, Equatable, Sendable {
  package enum ID: String, Codable, Sendable {
    case project, plugin, screen, machine, skills
    case mcpServer = "mcp-server"
    case filesAndFolders = "files-and-folders"
    case desktopControl = "desktop-control"
    case localNetwork = "local-network"
    case unifiedLogs = "unified-logs"
  }
  package enum Access: String, Codable, Sendable { case read, write, use, all, allow }
  package let id: ID
  package let access: Access
  package let purpose: String
  package let category: PluginFolderCategory?

  private enum CodingKeys: String, CodingKey, CaseIterable { case id, access, purpose, category }

  package init(from decoder: any Decoder) throws {
    let c = try decoder.pluginContainer(keyedBy: CodingKeys.self)
    id = try c.decode(ID.self, forKey: .id)
    access = try c.decode(Access.self, forKey: .access)
    purpose = try pluginPurpose(c.decode(String.self, forKey: .purpose))
    category = try c.decodeIfPresent(PluginFolderCategory.self, forKey: .category)
    let allowed: [Access] =
      switch id {
      case .project: [.read, .write]
      case .plugin: [.use]
      case .mcpServer: [.read, .all]
      case .filesAndFolders: [.read]
      default: [.allow]
      }
    guard allowed.contains(access), (id == .filesAndFolders) == (category != nil) else {
      throw PluginManifestError.invalid("Permission access or category does not match its ID.")
    }
  }

  var identity: String { id.rawValue + ":" + (category?.rawValue ?? "") }
}

package enum PluginFolderCategory: String, Codable, Sendable {
  case desktop, documents, downloads
  case iCloudDrive = "icloud-drive"
  case networkVolumes = "network-volumes"
  case removableVolumes = "removable-volumes"
}

package enum PluginPrivacyPermission: String, Codable, Sendable {
  case screen, machine, skills
  case desktopControl = "desktop-control"
  case localNetwork = "local-network"
  case unifiedLogs = "unified-logs"
}

package struct PluginToolRequirements: Codable, Equatable, Sendable {
  package enum Project: String, Codable, Sendable { case none, read, write }
  package let project: Project
  package let permissions: [PluginPrivacyPermission]
  package let filesAndFolders: [PluginFolderCategory]

  package init(
    project: Project, permissions: [PluginPrivacyPermission] = [],
    filesAndFolders: [PluginFolderCategory] = []
  ) {
    self.project = project
    self.permissions = Array(Set(permissions)).sorted { $0.rawValue < $1.rawValue }
    self.filesAndFolders = Array(Set(filesAndFolders)).sorted { $0.rawValue < $1.rawValue }
  }

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case project, permissions
    case filesAndFolders = "files_and_folders"
  }

  package init(from decoder: any Decoder) throws {
    let c = try decoder.pluginContainer(keyedBy: CodingKeys.self)
    project = try c.decode(Project.self, forKey: .project)
    permissions = try pluginUnique(
      c.decodeIfPresent([PluginPrivacyPermission].self, forKey: .permissions) ?? [])
    filesAndFolders = try pluginUnique(
      c.decodeIfPresent([PluginFolderCategory].self, forKey: .filesAndFolders) ?? [])
  }
}

package struct PluginReadExceptionDeclaration: Codable, Equatable, Sendable {
  package let path: String
  package let purpose: String
  private enum CodingKeys: String, CodingKey, CaseIterable { case path, purpose }

  package init(from decoder: any Decoder) throws {
    let c = try decoder.pluginContainer(keyedBy: CodingKeys.self)
    path = try c.decode(String.self, forKey: .path)
    purpose = try pluginPurpose(c.decode(String.self, forKey: .purpose))
    guard path.hasPrefix("~/"),
      !path.contains(where: { "\0$*?[]{}".contains($0) }),
      path.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false)
        .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else {
      throw PluginManifestError.invalid("Read exceptions require normalized home-relative paths.")
    }
  }
}

/// Network declarations omit authority identities; approval creates those separately.
package enum PluginNetworkDeclaration: Codable, Equatable, Sendable {
  case none, trusted, full
  case custom(hosts: [String], includeTrusted: Bool)

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case level, hosts
    case includeTrusted = "include_trusted"
  }

  package init(from decoder: any Decoder) throws {
    if let value = try? decoder.singleValueContainer().decode(String.self) {
      switch value {
      case "none": self = .none
      case "trusted": self = .trusted
      case "full": self = .full
      default: throw PluginManifestError.invalid("Invalid sandbox network level.")
      }
      return
    }
    let c = try decoder.pluginContainer(keyedBy: CodingKeys.self)
    guard try c.decode(String.self, forKey: .level) == "custom" else {
      throw PluginManifestError.invalid("Network tables require level = custom.")
    }
    let hosts = try c.decode([String].self, forKey: .hosts)
    guard hosts.allSatisfy({ NetworkHost.contains($0, rule: $0) }) else {
      throw PluginManifestError.invalid("Invalid custom network host rule.")
    }
    let canonical = hosts.map(NetworkHost.canonical)
    guard Set(canonical).count == canonical.count else {
      throw PluginManifestError.invalid("Duplicate canonical network host rule.")
    }
    self = .custom(
      hosts: canonical.sorted(), includeTrusted: try c.decode(Bool.self, forKey: .includeTrusted))
  }

  package func encode(to encoder: any Encoder) throws {
    switch self {
    case .none, .trusted, .full:
      var c = encoder.singleValueContainer()
      try c.encode(self == .none ? "none" : self == .trusted ? "trusted" : "full")
    case .custom(let hosts, let includeTrusted):
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode("custom", forKey: .level)
      try c.encode(hosts, forKey: .hosts)
      try c.encode(includeTrusted, forKey: .includeTrusted)
    }
  }
}

package struct PluginSandboxDeclaration: Codable, Equatable, Sendable {
  package let network: PluginNetworkDeclaration?
  package let purpose: String?
  package let readExceptions: [PluginReadExceptionDeclaration]?
  package let fullAccess: Bool

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case network, purpose
    case readExceptions = "read_exceptions"
    case fullAccess = "full_access"
  }

  package init(from decoder: any Decoder) throws {
    let c = try decoder.pluginContainer(keyedBy: CodingKeys.self)
    network = try c.decodeIfPresent(PluginNetworkDeclaration.self, forKey: .network)
    purpose = try c.decodeIfPresent(String.self, forKey: .purpose).map(pluginPurpose)
    readExceptions = try c.decodeIfPresent(
      [PluginReadExceptionDeclaration].self, forKey: .readExceptions)?.sorted { $0.path < $1.path }
    fullAccess = try c.decodeIfPresent(Bool.self, forKey: .fullAccess) ?? false
    guard (purpose != nil) == (network != nil || fullAccess),
      !fullAccess || (network == nil && readExceptions == nil)
    else {
      throw PluginManifestError.invalid(
        "Sandbox purposes or Full access settings are incompatible.")
    }
  }
}

/// The authority review identity excludes package presentation and protocol compatibility markers.
package struct PluginPermissionDeclarations: Codable, Equatable, Sendable {
  package let permissions: [PluginPermissionDeclaration]
  package let sandbox: PluginSandboxDeclaration?
  package let mcp: [String: Contribution]

  package struct Contribution: Codable, Equatable, Sendable {
    package let requirements: PluginToolRequirements?
    package let toolRequirements: [String: PluginToolRequirements]
  }

  package init(_ manifest: PluginManifest) {
    permissions = (manifest.permissions ?? []).sorted { $0.identity < $1.identity }
    sandbox = manifest.sandbox
    mcp = Dictionary(
      uniqueKeysWithValues: manifest.mcp.compactMap { contribution in
        guard contribution.requirements != nil || !(contribution.toolRequirements ?? [:]).isEmpty
        else {
          return nil
        }
        return (
          contribution.id,
          Contribution(
            requirements: contribution.requirements,
            toolRequirements: contribution.toolRequirements ?? [:])
        )
      })
  }

  package func digest() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
  }
}

private func pluginPurpose(_ value: String) throws -> String {
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty, !trimmed.contains("\0") else {
    throw PluginManifestError.invalid("Declaration purposes must be nonempty and NUL-free.")
  }
  return trimmed
}

private func pluginUnique<T: RawRepresentable & Hashable>(_ values: [T]) throws -> [T]
where T.RawValue == String {
  guard Set(values).count == values.count else {
    throw PluginManifestError.invalid("Duplicate requirement value.")
  }
  return values.sorted { $0.rawValue < $1.rawValue }
}
