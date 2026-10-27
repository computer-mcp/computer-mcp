import AppKit
import ComputerMCPControlPlane
import ComputerMCPCore
import ComputerMCPGateway
import ComputerMCPPermissions
import Foundation

/// Presents the gateway's permission store in Privacy & Security and writes the owner's
/// changes back through the revision-checked control plane.
@MainActor
final class LivePrivacySecurityService: PrivacySecurityService {
  private let controlPlane: any AppControlPlane
  private var view: GatewayPermissionView?
  private var systemPermissions: [PrivacySystemPermission.Kind: PermissionSummary] = [:]
  var requestPermission: ((PermissionSummary) -> Void)?

  init(controlPlane: any AppControlPlane) {
    self.controlPlane = controlPlane
  }

  func privacySnapshot() async throws -> PrivacySnapshot {
    let view = try await controlPlane.fetchPermissionRequests()
    let names = try await controlPlane.fetchPermissionObjectNames()
    let system = (try? await controlPlane.fetchPermissions()) ?? []
    systemPermissions = Dictionary(
      uniqueKeysWithValues: system.compactMap { summary in
        Self.systemPermission(summary).map { ($0.kind, summary) }
      })
    self.view = view
    let paths = Dictionary(
      uniqueKeysWithValues:
        try await controlPlane.fetchProjects().map { ($0.id, $0.path) })
    let principals = view.profiles.map { profile in
      var principal = Self.principal(profile)
      principal.fullAccessLimitSources = Self.fullAccessSources(
        view.subjects.filter { $0.profileID == profile.id }.map(\.limits))
      return principal
    }
    return PrivacySnapshot(
      revision: view.revision,
      profileRevisions: Dictionary(
        uniqueKeysWithValues: view.profiles.map { ($0.id.rawValue, $0.authorizationRevision) }),
      requests: view.requests.compactMap {
        Self.request(
          $0, principals: principals, names: names, paths: paths, subjects: view.subjects)
      },
      principals: principals,
      grants: view.profiles.flatMap { profile in
        Self.grants(
          profile, names: names, paths: paths,
          limits: view.subjects.filter { $0.profileID == profile.id }.map(\.limits))
      },
      managedSources: view.sources.map(Self.source),
      systemPermissions: system.compactMap(Self.systemPermission),
      suspendedForReview: view.suspended || !view.unconfirmedProfileIDs.isEmpty)
  }

  func answer(request id: String, with answer: PrivacyRequestAnswer, reviewed: PrivacySnapshot)
    async throws
  {
    guard let uuid = UUID(uuidString: id) else { return }
    let answer: PermissionAnswer? =
      switch answer {
      case .onlyThisTime: .onlyThisTime
      case .always: .always
      case .dontAllow: nil
      }
    do {
      try await controlPlane.answerPermissionRequest(
        id: uuid, answer: answer, expectedRevision: reviewed.revision)
    } catch GatewayPermissionError.revisionConflict { throw Self.changedPermissions() }
  }

  func setGrant(_ grant: PrivacyGrant, reviewed: PrivacySnapshot) async throws {
    guard let permission = Self.permission(grant) else { return }
    try await edit(grant.principalID, reviewed: reviewed) { profile in
      try profile.permissions.set(Self.state(grant.value), for: permission)
    }
  }

  func revokeAll(principalID: String, reviewed: PrivacySnapshot) async throws {
    try await edit(principalID, reviewed: reviewed) { profile in
      profile.permissions = Permissions()
      profile.projectNetworks = profile.projectNetworks.mapValues { _ in .none }
      profile.fullAccess = false
    }
  }

  func setExecution(
    principalID: String, to execution: PrivacyPrincipal.Execution, reviewed: PrivacySnapshot
  ) async throws {
    try await edit(principalID, reviewed: reviewed) { profile in
      profile.fullAccess = execution != .sandbox
    }
  }

  func confirmRestoredPermissions(reviewed: PrivacySnapshot) async throws {
    guard let view, view.revision == reviewed.revision else { throw Self.changedPermissions() }
    guard let epoch = view.epoch else { return }
    do {
      try await controlPlane.confirmPermissionAuthority(
        epoch: epoch, expectedRevision: view.revision, profiles: view.profiles)
    } catch GatewayPermissionError.revisionConflict { throw Self.changedPermissions() }
  }

  func openSystemSettings(for permission: PrivacySystemPermission.Kind) {
    guard let summary = systemPermissions[permission] else { return }
    requestPermission?(summary)
  }

  func setNetwork(
    _ grant: PrivacyGrant, to network: PrivacyNetworkAccess, reviewed: PrivacySnapshot
  ) async throws {
    guard grant.permission == .projects, let projectID = grant.object?.id else { return }
    let access: NetworkAccess =
      switch try network.validated() {
      case .none: .none
      case .trusted: .trusted
      case .full: .full
      case .custom(let hosts, let includesTrusted):
        .custom(hosts: Set(hosts), includesTrusted: includesTrusted)
      }
    try await edit(grant.principalID, reviewed: reviewed) { profile in
      profile.projectNetworks[projectID] = access
    }
  }

  /// Saves one profile against the choices it was read with, so a concurrent change fails
  /// instead of being overwritten.
  private func edit(
    _ principalID: String, reviewed: PrivacySnapshot, _ change: (inout ProfileGrant) throws -> Void
  )
    async throws
  {
    guard let id = GatewayProfileID(rawValue: principalID) else { return }
    let options = try await controlPlane.fetchProfilePermissionOptions(id: id)
    guard options.permissionRevision == reviewed.revision,
      options.grant.authorizationRevision == reviewed.profileRevisions[principalID]
    else { throw Self.changedPermissions() }
    var profile = options.grant
    try change(&profile)
    do {
      try await controlPlane.saveProfilePermissions(profile, reviewed: options)
    } catch GatewayPermissionError.revisionConflict { throw Self.changedPermissions() }
  }

  private static func principal(_ profile: ProfileGrant) -> PrivacyPrincipal {
    let connection =
      if profile.allowedCallers.contains(.secureTunnel) {
        "Secure Tunnel"
      } else if profile.allowedCallers.contains(.cloudflareTunnel) {
        "Cloudflare Tunnel"
      } else {
        "This Mac"
      }
    return PrivacyPrincipal(
      id: profile.id.rawValue, name: AppLocalization.string(profile.id.displayName),
      kind: .client(connection: connection),
      execution: profile.fullAccess ? .fullAccessAllowed : .sandbox)
  }

  static func changedPermissions() -> AppControlPlaneError {
    .unavailable("The permissions changed while you were editing. Review them and try again.")
  }

  static func grants(
    _ profile: ProfileGrant, names: PermissionObjectNames,
    paths: [String: String] = [:], limits: [ManagedLimits] = []
  ) -> [PrivacyGrant] {
    var permissions = Set(profile.permissions.entries.keys)
    permissions.formUnion([
      .screen, .desktopControl, .localNetwork, .machineInformation, .unifiedLogs, .skills,
    ])
    permissions.formUnion(FolderCategory.allCases.map(Permission.filesAndFolders))
    permissions.formUnion((Array(names.projects.keys) + ["*"]).map(Permission.project))
    permissions.formUnion((Array(names.plugins.keys) + ["*"]).map(Permission.plugin))
    permissions.formUnion((Array(names.mcpServers.keys) + ["*"]).map(Permission.mcpServer))
    return permissions.compactMap { permission in
      guard let (kind, original) = classify(permission, names: names) else { return nil }
      let object = original.map { object in
        PrivacyObject(
          id: object.id, name: object.name,
          detail: kind == .projects ? paths[object.id] : object.detail)
      }
      var grant = PrivacyGrant(
        principalID: profile.id.rawValue, permission: kind,
        object: object, value: value(profile.permissions.entries[permission] ?? .notGranted),
        isStored: profile.permissions.entries[permission] != nil)
      var deniedSources: Set<PolicySource> = []
      grant.allowedLevels = kind.grantedValues.filter { level in
        guard case .granted(let value) = state(.granted(level)),
          let requirement = try? PermissionRequirement(permission, value)
        else { return false }
        var sources = limits.reduce(into: Set<PolicySource>()) {
          $0.formUnion($1.restrictingSources(for: requirement))
        }
        if let path = object?.detail, let canonical = try? CanonicalPath(path) {
          for limit in limits { sources.formUnion(limit.denying(canonical)) }
        }
        deniedSources.formUnion(sources)
        return sources.isEmpty
      }
      if grant.availableLevels.isEmpty, !deniedSources.isEmpty {
        grant.value = .denied
        grant.source = .managedLimit(sourceNames(deniedSources).joined(separator: " · "))
      } else if case .granted(let level) = grant.value, !grant.availableLevels.contains(level) {
        grant.value = grant.availableLevels.last.map(PrivacyGrantValue.granted) ?? .denied
      }
      if case .project(let id) = permission {
        grant.network = Self.network((profile.projectNetworks[id] ?? .none).configuration)
        for limit in limits {
          for (source, availability) in limit.sources {
            let cap: PrivacyNetworkAccess
            switch availability {
            case .absent: continue
            case .unreadable: cap = .none
            case .available(let policy): cap = network(policy.network.configuration)
            }
            if cap != .full {
              grant.networkLimits.append(cap)
              grant.networkLimitSources.append(sourceName(source))
            }
          }
        }
      }
      return grant
    }.sorted { order($0) < order($1) }
  }

  /// Wildcard rows first, folder categories in Finder's order, other objects by name.
  private static func order(_ grant: PrivacyGrant) -> (String, Int, Int, String) {
    let id = grant.object?.id ?? ""
    let category = FolderCategory.allCases.firstIndex { $0.rawValue == id } ?? 0
    return (grant.permission.rawValue, id == "*" ? 0 : 1, category, grant.object?.name ?? "")
  }

  static func fullAccessSources(_ limits: [ManagedLimits]) -> [String] {
    let sources = limits.reduce(into: Set<PolicySource>()) { sources, limit in
      for (source, availability) in limit.sources {
        switch availability {
        case .unreadable: sources.insert(source)
        case .available(let policy) where !policy.allowsFullAccess: sources.insert(source)
        default: break
        }
      }
    }
    return sourceNames(sources)
  }

  private static func sourceNames(_ sources: Set<PolicySource>) -> [String] {
    sources.map(sourceName).sorted()
  }

  private static func sourceName(_ source: PolicySource) -> String {
    switch source {
    case .owner: "Owner Policy"
    case .machine: "Machine Policy"
    case .managedPreferences: "Configuration Profile"
    case .connection: "Connection"
    }
  }

  static func request(
    _ item: GatewayPermissionRequestView, principals: [PrivacyPrincipal],
    names: PermissionObjectNames, paths: [String: String] = [:],
    subjects: [GatewayPermissionSubjectView] = []
  ) -> PrivacyRequest? {
    let request = item.request
    guard request.status == .pending else { return nil }
    var principal =
      principals.first(where: { $0.id == item.profileID?.rawValue })
      ?? invocationPrincipal(request.invocation.principal, names: names)
    if case .client = request.invocation.principal,
      let subject = subjects.first(where: { $0.principal == request.invocation.principal })
    {
      principal = PrivacyPrincipal(
        id: principal.id, name: principal.name,
        kind: .client(connection: connectionName(subject.caller)), execution: principal.execution)
    }
    switch request.content {
    case .permission(let content):
      guard let (kind, classifiedObject) = classify(content.requirement.permission, names: names)
      else {
        return nil
      }
      var object = classifiedObject
      if let current = object {
        let path: String?
        if case .path(let location) = content.scope {
          path = location.string
        } else {
          path = kind == .projects ? paths[current.id] : current.detail
        }
        object = PrivacyObject(id: current.id, name: current.name, detail: path)
      }
      return PrivacyRequest(
        id: request.id.uuidString, principal: principal, permission: kind, object: object,
        level: level(content.requirement.value), purpose: content.pluginPurpose,
        tool: request.invocation.tool, expires: request.expiresAt)
    case .network(let content):
      return PrivacyRequest(
        id: request.id.uuidString, principal: principal, permission: .projects,
        object: PrivacyObject(
          id: content.projectID, name: project(content.projectID, names: names).name,
          detail: paths[content.projectID]), level: .read, host: content.host,
        purpose: content.pluginPurpose, tool: request.invocation.tool,
        expires: request.expiresAt)
    case .projectRegistration(let content):
      let root = item.registrationGrantRoot ?? content.path
      return PrivacyRequest(
        id: request.id.uuidString, principal: principal, permission: .projects,
        object: PrivacyObject(
          id: content.projectID,
          name: item.registrationGrantName ?? URL(fileURLWithPath: root.string).lastPathComponent,
          detail: root.string),
        level: level(content.access),
        registration: item.registrationGrantRoot == nil ? .newProject : .existingProject,
        purpose: nil, tool: request.invocation.tool, expires: request.expiresAt)
    }
  }

  static func invocationPrincipal(_ principal: Principal, names: PermissionObjectNames)
    -> PrivacyPrincipal
  {
    switch principal {
    case .client(let id):
      PrivacyPrincipal(
        id: "client/" + id, name: clientAccessIdentity(id),
        kind: .client(connection: "Connection"), execution: .sandbox)
    case .plugin(.package(let id)):
      PrivacyPrincipal(
        id: "plugin/" + id, name: names.plugins[id] ?? id,
        kind: .plugin(version: ""), execution: .sandbox)
    case .plugin(.localServer(let id)):
      PrivacyPrincipal(
        id: "server/" + id, name: names.mcpServers[id] ?? id,
        kind: .localServer, execution: .sandbox)
    }
  }

  static func connectionName(_ caller: GatewayCallerKind) -> String {
    switch caller {
    case .secureTunnel: "Secure Tunnel"
    case .cloudflareTunnel: "Cloudflare Tunnel"
    case .localApp, .localCLI, .localMCP: "This Mac"
    }
  }

  private static func source(_ source: GatewayManagedPolicyView) -> PrivacyManagedSource {
    let name =
      switch source.source {
      case .owner: "Owner Policy"
      case .machine: "Machine Policy"
      case .managedPreferences: "Configuration Profile"
      case .connection: "Connection"
      }
    return PrivacyManagedSource(
      id: source.source.rawValue + source.location, name: name, location: source.location,
      state: source.failure == nil ? .active : .unreadable)
  }

  private static func systemPermission(_ summary: PermissionSummary) -> PrivacySystemPermission? {
    let kind: PrivacySystemPermission.Kind
    switch summary.id {
    case "screen-recording": kind = .screenRecording
    case "accessibility": kind = .accessibility
    default: return nil
    }
    let state: PrivacySystemPermission.State =
      switch summary.state {
      case .granted: .allowed
      case .notDetermined: .notDetermined
      case .denied, .notGranted, .unavailable: .notAllowed
      }
    return PrivacySystemPermission(kind: kind, state: state)
  }

  private static func classify(_ permission: Permission, names: PermissionObjectNames)
    -> (PrivacyPermissionKind, PrivacyObject?)?
  {
    switch permission {
    case .project(let id): (.projects, project(id, names: names))
    case .filesAndFolders(let category):
      (
        .filesAndFolders,
        PrivacyObject(
          id: category.rawValue, name: category.title, detail: category.directory?.path)
      )
    case .plugin(let id):
      (.plugins, PrivacyObject(id: id, name: object(id, names.plugins, "All Plugins"), detail: nil))
    case .mcpServer(let id):
      (
        .mcpServers,
        PrivacyObject(id: id, name: object(id, names.mcpServers, "All MCP Servers"), detail: nil)
      )
    case .screen: (.screen, nil)
    case .desktopControl: (.desktopControl, nil)
    case .localNetwork: (.localNetwork, nil)
    case .machineInformation: (.machineInformation, nil)
    case .unifiedLogs: (.unifiedLogs, nil)
    case .skills: (.skills, nil)
    }
  }

  private static func project(_ id: String, names: PermissionObjectNames) -> PrivacyObject {
    PrivacyObject(id: id, name: object(id, names.projects, "All Projects"), detail: nil)
  }

  private static func object(_ id: String, _ names: [String: String], _ all: String) -> String {
    id == "*" ? all : names[id] ?? id
  }

  private static func permission(_ grant: PrivacyGrant) -> Permission? {
    let id = grant.object?.id ?? ""
    switch grant.permission {
    case .projects: return .project(id)
    case .filesAndFolders: return FolderCategory(rawValue: id).map(Permission.filesAndFolders)
    case .plugins: return .plugin(id)
    case .mcpServers: return .mcpServer(id)
    case .screen: return .screen
    case .desktopControl: return .desktopControl
    case .localNetwork: return .localNetwork
    case .machineInformation: return .machineInformation
    case .unifiedLogs: return .unifiedLogs
    case .skills: return .skills
    case .fullAccess: return nil
    }
  }

  private static func value(_ state: ComputerMCPPermissions.PermissionState) -> PrivacyGrantValue {
    switch state {
    case .notGranted: .ask
    case .denied: .denied
    case .granted(let value): .granted(level(value))
    }
  }

  private static func state(_ value: PrivacyGrantValue) -> ComputerMCPPermissions.PermissionState {
    switch value {
    case .ask: .notGranted
    case .denied: .denied
    case .granted(let level):
      switch level {
      case .allow: .granted(.access)
      case .read: .granted(.read)
      case .readWrite: .granted(.write)
      case .use: .granted(.use)
      case .all: .granted(.all)
      }
    }
  }

  private static func level(_ value: PermissionValue) -> PrivacyGrantValue.Level {
    switch value {
    case .read: .read
    case .write: .readWrite
    case .use: .use
    case .all: .all
    case .access: .allow
    }
  }

  private static func network(_ configuration: NetworkAccess.Configuration) -> PrivacyNetworkAccess
  {
    switch configuration {
    case .none: .none
    case .trusted: .trusted
    case .full: .full
    case .custom(let hosts, let includesTrusted):
      .custom(hosts: hosts.sorted(), includesTrusted: includesTrusted)
    }
  }
}

extension FolderCategory {
  fileprivate var directory: URL? {
    let directory: FileManager.SearchPathDirectory
    switch self {
    case .desktop: directory = .desktopDirectory
    case .documents: directory = .documentDirectory
    case .downloads: directory = .downloadsDirectory
    case .iCloudDrive, .networkVolumes, .removableVolumes: return nil
    }
    return FileManager.default.urls(for: directory, in: .userDomainMask).first?
      .resolvingSymlinksInPath()
  }

  fileprivate var title: String {
    switch self {
    case .desktop: "Desktop"
    case .documents: "Documents"
    case .downloads: "Downloads"
    case .iCloudDrive: "iCloud Drive"
    case .networkVolumes: "Network Volumes"
    case .removableVolumes: "Removable Volumes"
    }
  }
}
