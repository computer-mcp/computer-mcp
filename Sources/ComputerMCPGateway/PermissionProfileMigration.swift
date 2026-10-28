import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPPermissions
import Crypto
import Foundation
import GRDB

package struct PermissionMigrationProjects: Sendable {
  package let registered: [ComputerMCPCore.RegisteredProject]
  package let aliases: [String: String]
  package let canonicalRoots: [String: Set<String>]
  package let derived: [MCPDerivedProjectRegistration]

  package init(
    registered: [ComputerMCPCore.RegisteredProject], aliases: [String: String] = [:],
    canonicalRoots: [String: Set<String>] = [:],
    derived: [MCPDerivedProjectRegistration] = []
  ) {
    self.registered = registered
    self.aliases = aliases
    self.canonicalRoots = canonicalRoots
    self.derived = derived
  }
}

package struct PermissionMigrationReport: Equatable, Sendable {
  package struct DroppedGrant: Equatable, Sendable {
    package let profileID: GatewayProfileID
    package let grant: String
    package let reason: String
  }
  package let dropped: [DroppedGrant]
  package let omittedCount: Int
  package var removedBuiltinIDs: [String] = []
}

package struct PermissionMigrationPlan: Sendable {
  package let profiles: [ProfileGrant]
  package let projects: [ComputerMCPCore.RegisteredProject]
  package let derived: [MCPDerivedProjectRegistration]
  package let report: PermissionMigrationReport
  package let inputDigest: String
  package let catalogDigest: String
}

/// Pure conversion of a host snapshot. It never opens a provider or discovers tools.
package enum PermissionProfileMigration {
  package static func plan(
    profiles: [LegacyProfileGrant], catalog: PermissionMigrationCatalog,
    projects: PermissionMigrationProjects
  ) throws -> PermissionMigrationPlan {
    guard Set(profiles.map(\.id)).count == profiles.count,
      Set(projects.registered.map(\.id)).count == projects.registered.count,
      Set(projects.derived.map { $0.project.id }).count == projects.derived.count
    else { throw PermissionMigrationError.invalidStoredState }
    let inputDigest = try fingerprint(profiles: profiles, projects: projects, catalog: catalog)
    let defaults = Dictionary(uniqueKeysWithValues: catalog.manifestProfiles.map { ($0.id, $0) })
    var effective = try profiles.map { profile in
      guard profile.authorizationRevision >= 0, profile.authorizationRevision < Int64.max else {
        throw PermissionMigrationError.revisionExhausted
      }
      if profile.authorizationRevision != 0 { return profile }
      guard let original = defaults[profile.id] else {
        throw PermissionMigrationError.missingManifestProfile(profile.id.rawValue)
      }
      var merged = original.applyingPersistedRuntimeState(profile)
      if merged.capabilityIDs.contains("*"), !merged.projectIDs.contains("*") {
        merged.projectIDs = Set(projects.registered.map(\.id))
      }
      return merged
    }
    let registered = Dictionary(uniqueKeysWithValues: projects.registered.map { ($0.id, $0) })
    // The receipt proves which profile entry the old registration injected. Another
    // explicit holder or alias is independent authority and cannot silently become inheritance.
    for row in projects.derived {
      guard let child = registered[row.project.id], sameStoredProject(child, row.project) else {
        throw PermissionMigrationError.ownershipConflict(
          row.project.id, reason: "Derived registration metadata changed.")
      }
      guard let source = registered[row.sourceProjectID],
        (projects.canonicalRoots[source.id] ?? [source.rootPath]).contains(row.sourceRoot)
      else {
        throw PermissionMigrationError.ownershipConflict(
          row.project.id, reason: "Source registration or canonical root changed.")
      }
      guard !row.origin.isEmpty, !row.receiptID.isEmpty, !row.receiptDigest.isEmpty,
        row.project.id != row.sourceProjectID,
        !projects.aliases.values.contains(row.project.id),
        let index = effective.firstIndex(where: { $0.id == row.profileID }),
        profiles.first(where: { $0.id == row.profileID })?.projectIDs.contains(row.project.id)
          == true,
        effective[index].projectIDs.contains(row.sourceProjectID)
          || effective[index].projectIDs.contains("*"),
        !effective.contains(where: {
          $0.id != row.profileID && $0.projectIDs.contains(row.project.id)
        }),
        !projects.derived.contains(where: { $0.project.id == row.sourceProjectID })
      else {
        throw PermissionMigrationError.ownershipConflict(
          row.project.id,
          reason: "Receipt ownership, source grant, or independent derived grant conflicts.")
      }
      effective[index].projectIDs.remove(row.project.id)
    }
    var dropped: [PermissionMigrationReport.DroppedGrant] = []
    var omitted = 0
    func report(_ profile: LegacyProfileGrant, _ grant: String, _ reason: String) {
      if dropped.count < 256 {
        dropped.append(
          .init(profileID: profile.id, grant: String(grant.prefix(128)), reason: reason))
      } else {
        omitted += 1
      }
    }
    var converted: [ProfileGrant] = []
    for profile in effective.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
      let projectIDs = Set(
        profile.projectIDs.sorted().compactMap { id -> String? in
          let canonical = projects.aliases[id] ?? id
          guard canonical == "*" || registered[canonical] != nil else {
            report(profile, id, "Project is not registered.")
            return nil
          }
          return canonical
        })
      let tools = catalog.tools.filter { tool in
        profile.grants(tool.descriptor) && profile.permitsRisk(tool.risk)
          && (tool.risk != .fullShell || profile.fullShellEnabled)
          && (!tool.localOnly || profile.allowedCallers.contains(where: { !$0.isRemote }))
          && (tool.projectRequirement != .required || !projectIDs.isEmpty)
      }
      let fullAccess = profile.mode == .localFullAccess && profile.fullShellEnabled
      let writes =
        fullAccess
        || (profile.mode != .readOnly
          && tools.contains { $0.access == .projectWrite || $0.access == .sourceProjectWrite })
      var permissions = Permissions()
      var networks: [String: NetworkAccess] = [:]
      for id in projectIDs.sorted() {
        try permissions.set(.granted(writes ? .write : .read), for: .project(id))
        networks[id] = NetworkAccess.none
      }
      for tool in tools {
        for requirement in tool.permissions {
          let permission = requirement.permission
          let allowed: Bool
          switch permission {
          case .screen, .machineInformation, .unifiedLogs, .skills: allowed = true
          case .desktopControl: allowed = profile.mode != .readOnly
          default: allowed = false
          }
          if allowed { try permissions.set(.granted(.access), for: permission) }
        }
      }
      let serverLevel: PermissionValue = profile.mode == .readOnly ? .read : .all
      // tools.call resolves the target before the old risk check; its wrapper's
      // destructive annotation does not erase read-only downstream authority.
      let genericCall =
        catalog.tools.contains { $0.id == "mcp.tools.call" && $0.serverID == nil }
        && (profile.capabilityIDs.contains("mcp.tools.call") || profile.capabilityIDs.contains("*"))
      if genericCall {
        try permissions.set(.granted(serverLevel), for: .mcpServer("*"))
      } else if tools.contains(where: {
        $0.serverID == nil && LegacyProfileGrant.mcpSurfaceCapabilities.contains($0.id)
          && $0.risk == .readOnly
          && (profile.capabilityIDs.contains($0.id) || profile.capabilityIDs.contains("*"))
      }) {
        try permissions.set(.granted(.read), for: .mcpServer("*"))
      }
      for id in profile.mcpServerIDs.sorted() {
        guard catalog.serverIDs.contains(id) else {
          report(profile, id, "MCP server is not registered.")
          continue
        }
        try permissions.set(.granted(serverLevel), for: .mcpServer(id))
      }
      for tool in tools
      where tool.serverID != nil
        && !profile.capabilityIDs.isDisjoint(with: Set([tool.id] + tool.aliases))
      {
        let server = tool.serverID!
        let grantedTools = tools.filter {
          $0.serverID == server
            && !profile.capabilityIDs.isDisjoint(with: Set([$0.id] + $0.aliases))
        }
        let level: PermissionValue = grantedTools.allSatisfy { $0.risk == .readOnly } ? .read : .all
        let existing = permissions.state(for: .mcpServer(server))
        if existing != .granted(.all) {
          try permissions.set(.granted(level), for: .mcpServer(server))
        }
      }
      if tools.contains(where: { $0.pluginID != nil })
        || catalog.serverPluginIDs.keys.contains(where: {
          if case .granted = permissions.state(for: .mcpServer($0)) { return true }
          return false
        })
      {
        try permissions.set(.granted(.use), for: .plugin("*"))
      }
      for id in profile.capabilityIDs.sorted() where id != "*" {
        if genericCall && id == "mcp.tools.call" { continue }
        let matching = tools.filter { $0.id == id || $0.aliases.contains(id) }
        if matching.isEmpty {
          report(profile, id, "No effective registered tool resolves this grant.")
        } else if !genericCall && (id == "mcp.requests.cancel" || id == "mcp.connections.close") {
          report(profile, id, "Control-only MCP grants have no permission equivalent.")
        }
      }
      converted.append(
        ProfileGrant(
          id: profile.id, permissions: permissions, projectNetworks: networks,
          fullAccess: fullAccess, allowedCallers: profile.allowedCallers,
          authorizationRevision: profile.authorizationRevision + 1))
    }
    return PermissionMigrationPlan(
      profiles: converted, projects: projects.registered.sorted { $0.id < $1.id },
      derived: projects.derived.sorted { $0.project.id < $1.project.id },
      report: .init(dropped: dropped, omittedCount: omitted), inputDigest: inputDigest,
      catalogDigest: catalog.digest)
  }

  private static func sameStoredProject(
    _ lhs: ComputerMCPCore.RegisteredProject, _ rhs: ComputerMCPCore.RegisteredProject
  ) -> Bool {
    lhs.id == rhs.id && lhs.displayName == rhs.displayName && lhs.rootPath == rhs.rootPath
      && lhs.bookmarkData == rhs.bookmarkData && lhs.bookmarkIsStale == rhs.bookmarkIsStale
      && lhs.createdAt.databaseValue == rhs.createdAt.databaseValue
      && lhs.updatedAt.databaseValue == rhs.updatedAt.databaseValue
  }

  static func fingerprint(
    profiles: [LegacyProfileGrant], projects: PermissionMigrationProjects,
    catalog: PermissionMigrationCatalog
  ) throws -> String {
    struct Snapshot: Encodable {
      let profiles: [LegacyProfileIdentity]
      let projects: [ComputerMCPCore.RegisteredProject]
      let aliases: [String: String]
      let canonicalRoots: [String: [String]]
      let derived: [MCPDerivedProjectRegistration]
      let catalog: String
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let snapshot = Snapshot(
      profiles: profiles.sorted { $0.id.rawValue < $1.id.rawValue }.map(LegacyProfileIdentity.init),
      projects: projects.registered.sorted { $0.id < $1.id }, aliases: projects.aliases,
      canonicalRoots: projects.canonicalRoots.mapValues { $0.sorted() },
      derived: projects.derived.sorted { $0.project.id < $1.project.id }, catalog: catalog.digest)
    return SHA256.hash(data: try encoder.encode(snapshot)).map { String(format: "%02x", $0) }
      .joined()
  }
}
