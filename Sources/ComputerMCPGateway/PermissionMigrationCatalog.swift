import ComputerMCPCore
import ComputerMCPPermissions
import Crypto
import Foundation

package enum PermissionMigrationError: Error, Equatable {
  case activationRequired
  case invalidCatalog
  case missingManifestProfile(String)
  case stateChanged, revisionExhausted, invalidStoredState
}

/// A classification captured by the host, without probing a process or network service.
package struct PermissionMigrationTool: Codable, Equatable, Sendable {
  package let id: String
  package let risk: CapabilityRisk
  package let projectRequirement: ProjectRequirement
  package let localOnly: Bool
  package let usesNetwork: Bool
  package let access: ToolRequirement.Access
  package let permissions: [PermissionRequirement]
  package let aliases: [String]
  package let serverID: String?
  package let pluginID: String?

  package init(
    id: String, risk: CapabilityRisk, projectRequirement: ProjectRequirement = .none,
    localOnly: Bool = false, usesNetwork: Bool = false, access: ToolRequirement.Access = .none,
    permissions: [PermissionRequirement] = [],
    aliases: [String] = [], serverID: String? = nil, pluginID: String? = nil
  ) {
    self.id = id
    self.risk = risk
    self.projectRequirement = projectRequirement
    self.access = access
    self.localOnly = localOnly
    self.usesNetwork = usesNetwork
    self.permissions = permissions.sorted {
      String(describing: $0.permission) < String(describing: $1.permission)
    }
    self.aliases = Array(Set(aliases)).sorted()
    self.serverID = serverID
    self.pluginID = pluginID
  }

  var descriptor: CapabilityDescriptor {
    CapabilityDescriptor(
      id: id, risk: risk,
      requirement: ToolRequirement(access: access, permissions: permissions),
      projectRequirement: projectRequirement, localOnly: localOnly, usesNetwork: usesNetwork,
      mcpReference: serverID.map { MCPToolReference(serverID: $0, toolName: id) },
      equivalentCapabilityIDs: aliases)
  }
}

/// Version 1 keeps built-in classifications frozen. Dynamic aliases and contribution origins
/// come from an already validated host snapshot, bound to its configuration digest.
package struct PermissionMigrationCatalog: Sendable {
  package let version = 1
  package let tools: [PermissionMigrationTool]
  package let serverIDs: Set<String>
  package let serverPluginIDs: [String: String]
  package let manifestProfiles: [LegacyProfileGrant]
  package let manifestProjects: [ComputerMCPCore.RegisteredProject]
  package let configurationDigest: String
  package let digest: String

  package init(
    configurationDigest: String, availableBuiltinIDs: Set<String>,
    dynamicTools: [PermissionMigrationTool] = [], serverIDs: Set<String>,
    manifestProfiles: [LegacyProfileGrant], serverPluginIDs: [String: String] = [:],
    manifestProjects: [ComputerMCPCore.RegisteredProject] = []
  ) throws {
    let builtins = Self.builtinV1.filter { availableBuiltinIDs.contains($0.id) }
    let tools = (builtins + dynamicTools).sorted {
      [$0.id, $0.serverID ?? "", $0.pluginID ?? ""].lexicographicallyPrecedes([
        $1.id, $1.serverID ?? "", $1.pluginID ?? "",
      ])
    }
    guard Set(manifestProfiles.map(\.id)).count == manifestProfiles.count,
      tools.allSatisfy({
        !$0.id.isEmpty && ($0.serverID == nil || serverIDs.contains($0.serverID!))
      })
    else { throw PermissionMigrationError.invalidCatalog }
    var identities = Set<[String]>()
    var aliasOwners: [String: String] = [:]
    for tool in tools {
      guard identities.insert([tool.id, tool.serverID ?? "", tool.pluginID ?? ""]).inserted else {
        throw PermissionMigrationError.invalidCatalog
      }
      if let server = tool.serverID {
        for alias in [tool.id] + tool.aliases {
          guard aliasOwners[alias] == nil || aliasOwners[alias] == server else {
            throw PermissionMigrationError.invalidCatalog
          }
          aliasOwners[alias] = server
        }
      }
    }
    self.tools = tools
    self.serverIDs = serverIDs
    guard Set(serverPluginIDs.keys).isSubset(of: serverIDs) else {
      throw PermissionMigrationError.invalidCatalog
    }
    self.serverPluginIDs = serverPluginIDs
    self.manifestProfiles = manifestProfiles
    self.manifestProjects = manifestProjects
    self.configurationDigest = configurationDigest
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let payload = CatalogIdentity(
      version: 1, configurationDigest: configurationDigest,
      tools: tools, serverIDs: serverIDs.sorted(), serverPluginIDs: serverPluginIDs,
      manifestProfiles: manifestProfiles.sorted { $0.id.rawValue < $1.id.rawValue }.map(
        LegacyProfileIdentity.init),
      manifestProjects: manifestProjects.sorted { $0.id < $1.id })
    digest = SHA256.hash(data: try encoder.encode(payload)).map { String(format: "%02x", $0) }
      .joined()
  }

  private struct CatalogIdentity: Encodable {
    let version: Int
    let configurationDigest: String
    let tools: [PermissionMigrationTool]
    let serverIDs: [String]
    let serverPluginIDs: [String: String]
    let manifestProfiles: [LegacyProfileIdentity]
    let manifestProjects: [ComputerMCPCore.RegisteredProject]
  }
}

/// Canonical legacy authority for migration fingerprints, including revision-zero defaults.
struct LegacyProfileIdentity: Codable {
  let id: String
  let capabilities: [String]
  let projects: [String]
  let servers: [String]
  let callers: [String]
  let mode: String
  let fullShell: Bool
  let confirmation: String
  let revision: Int64

  init(_ profile: LegacyProfileGrant) {
    id = profile.id.rawValue
    capabilities = profile.capabilityIDs.sorted()
    projects = profile.projectIDs.sorted()
    servers = profile.mcpServerIDs.sorted()
    callers = profile.allowedCallers.map(\.rawValue).sorted()
    mode = profile.mode.rawValue
    fullShell = profile.fullShellEnabled
    confirmation = profile.confirmationPolicy.rawValue
    revision = profile.authorizationRevision
  }
}
