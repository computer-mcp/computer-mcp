import ComputerMCPPermissions
import Foundation

package enum PluginDeclarationUpdate: String, Codable, Sendable {
  case unchanged, purposeOnly, narrowing, widening
}

extension PluginPermissionDeclarations {
  /// Admission requirements order authority in the opposite direction to provider requests.
  /// A mixed update waits in its entirety, preserving the previous projection.
  package func update(
    from previous: Self, conservativeEquivalent: PluginToolRequirements? = nil
  ) -> PluginDeclarationUpdate {
    if self == previous { return .unchanged }
    let before = Dictionary(uniqueKeysWithValues: previous.permissions.map { ($0.identity, $0) })
    for permission in permissions {
      guard let old = before[permission.identity],
        PermissionState.granted(old.value).allows(permission.value)
      else { return .widening }
    }
    if sandboxWidens(previous.sandbox) { return .widening }
    for id in Set(mcp.keys).union(previous.mcp.keys) {
      let old = previous.mcp[id]
      let new = mcp[id]
      let names = Set(old?.toolRequirements.keys.map { $0 } ?? [])
        .union(new?.toolRequirements.keys.map { $0 } ?? [])
      let pairs =
        [(old?.requirements, new?.requirements)]
        + names.map {
          (
            old?.toolRequirements[$0] ?? old?.requirements,
            new?.toolRequirements[$0] ?? new?.requirements
          )
        }
      for (prior, proposed) in pairs {
        guard let proposed else { continue }
        if let prior {
          if !proposed.includes(prior) { return .widening }
        } else if proposed != conservativeEquivalent {
          return .widening
        }
      }
    }
    if authorityEquals(previous) { return .purposeOnly }
    return .narrowing
  }

  private func sandboxWidens(_ prior: PluginSandboxDeclaration?) -> Bool {
    if prior?.fullAccess == true { return false }
    if sandbox?.fullAccess == true { return true }
    let oldNetwork = prior?.network?.value ?? .none
    let newNetwork = sandbox?.network?.value ?? .none
    func includesTrusted(_ network: NetworkAccess) -> Bool {
      switch network.configuration {
      case .trusted, .full: true
      case .custom(_, let includes): includes
      case .none: false
      }
    }
    // A trusted-list dependency cannot be inferred from its current host contents.
    if includesTrusted(newNetwork) && !includesTrusted(oldNetwork) { return true }
    guard newNetwork.fits(within: oldNetwork, trustedHosts: []) else { return true }
    // Filesystem containment is not inferred from spelling. Only previously reviewed
    // paths are retained; enablement owns canonical target/identity evidence.
    let oldPaths = Set(prior?.readExceptions?.map(\.path) ?? [])
    return !Set(sandbox?.readExceptions?.map(\.path) ?? []).isSubset(of: oldPaths)
  }

  private func authorityEquals(_ prior: Self) -> Bool {
    permissions.map { ($0.identity, $0.access) }.elementsEqual(
      prior.permissions.map { ($0.identity, $0.access) }, by: { $0 == $1 })
      && (sandbox?.fullAccess ?? false) == (prior.sandbox?.fullAccess ?? false)
      && (sandbox?.network?.value.configuration ?? NetworkAccess.Configuration.none)
        == (prior.sandbox?.network?.value.configuration ?? NetworkAccess.Configuration.none)
      && Set(sandbox?.readExceptions?.map(\.path) ?? [])
        == Set(prior.sandbox?.readExceptions?.map(\.path) ?? [])
      && mcp == prior.mcp
  }
}

extension PluginToolRequirements {
  /// A manifest cannot express the complete set of concrete object grants. Equality
  /// is provable here only for an object-free conservative set; uncertainty needs review.
  package static func conservativeEquivalent(
    permissions: Permissions, limits: ManagedLimits
  ) throws -> Self? {
    guard
      !limits.sources.values.contains(where: {
        if case .unreadable = $0 { return true }
        return false
      })
    else { return nil }
    let policies = limits.sources.values.compactMap { source -> ManagedPolicy? in
      if case .available(let policy) = source { return policy }
      return nil
    }
    let candidates = Set(permissions.entries.keys).union(
      policies.flatMap { $0.permissionCeilings.entries.keys })
    func isEffective(_ permission: Permission) -> Bool {
      let values: [PermissionValue]
      let fallback: Permission?
      switch permission {
      case .project:
        values = [.write, .read]
        fallback = .project("*")
      case .mcpServer:
        values = [.all, .read]
        fallback = .mcpServer("*")
      case .plugin:
        values = [.use]
        fallback = .plugin("*")
      case .filesAndFolders:
        values = [.read]
        fallback = nil
      default:
        values = [.access]
        fallback = nil
      }
      return values.contains { value in
        permissions.state(for: permission).allows(value)
          && policies.allSatisfy { policy in
            let entries = policy.permissionCeilings.entries
            let ceiling = entries[permission] ?? fallback.flatMap { entries[$0] }
            return ceiling?.allows(value) ?? true
          }
      }
    }
    var privacy: [PluginPrivacyPermission] = []
    var folders: [PluginFolderCategory] = []
    for permission in candidates {
      guard permission != .machineInformation, permission != .skills,
        isEffective(permission)
      else { continue }
      switch permission {
      case .project, .plugin, .mcpServer: return nil
      case .screen: privacy.append(.screen)
      case .desktopControl: privacy.append(.desktopControl)
      case .localNetwork: privacy.append(.localNetwork)
      case .unifiedLogs: privacy.append(.unifiedLogs)
      case .filesAndFolders(let category):
        folders.append(PluginFolderCategory.all.first { $0.value == category }!)
      default: break
      }
    }
    return .init(project: .none, permissions: privacy, filesAndFolders: folders)
  }

  package func includes(_ other: Self) -> Bool {
    let rank: [Project: Int] = [.none: 0, .read: 1, .write: 2]
    return rank[project]! >= rank[other.project]!
      && Set(permissions).isSuperset(of: other.permissions)
      && Set(filesAndFolders).isSuperset(of: other.filesAndFolders)
  }
}

extension PluginPermissionDeclaration {
  package var value: PermissionValue {
    switch access {
    case .read: .read
    case .write: .write
    case .use: .use
    case .all: .all
    case .allow: .access
    }
  }

  package func matches(_ permission: Permission) -> Bool {
    switch (id, permission) {
    case (.project, .project), (.plugin, .plugin), (.mcpServer, .mcpServer): true
    case (.screen, .screen), (.desktopControl, .desktopControl),
      (.localNetwork, .localNetwork), (.machine, .machineInformation),
      (.unifiedLogs, .unifiedLogs), (.skills, .skills):
      true
    case (.filesAndFolders, .filesAndFolders(let folder)): category?.value == folder
    default: false
    }
  }
}

extension PluginFolderCategory {
  fileprivate static let all: [Self] = [
    .desktop, .documents, .downloads, .iCloudDrive, .networkVolumes, .removableVolumes,
  ]
  package var value: FolderCategory {
    switch self {
    case .desktop: .desktop
    case .documents: .documents
    case .downloads: .downloads
    case .iCloudDrive: .iCloudDrive
    case .networkVolumes: .networkVolumes
    case .removableVolumes: .removableVolumes
    }
  }
}

extension PluginNetworkDeclaration {
  package var value: NetworkAccess {
    switch self {
    case .none: .none
    case .trusted: .trusted
    case .full: .full
    case .custom(let hosts, let includes): .custom(hosts: Set(hosts), includesTrusted: includes)
    }
  }
}
