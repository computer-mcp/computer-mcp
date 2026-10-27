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
  /// The store revision the last snapshot was read at; answers must match it.
  private var revision: UInt64 = 0
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
    revision = view.revision
    let principals = view.profiles.map(Self.principal)
    return PrivacySnapshot(
      requests: view.requests.compactMap { Self.request($0, principals: principals, names: names) },
      principals: principals,
      grants: view.profiles.flatMap { Self.grants($0, names: names) },
      managedSources: view.sources.map(Self.source),
      systemPermissions: system.compactMap(Self.systemPermission),
      suspendedForReview: view.suspended || !view.unconfirmedProfileIDs.isEmpty)
  }

  func answer(request id: String, with answer: PrivacyRequestAnswer) async throws {
    guard let uuid = UUID(uuidString: id) else { return }
    let answer: PermissionAnswer? =
      switch answer {
      case .onlyThisTime: .onlyThisTime
      case .always: .always
      case .dontAllow: nil
      }
    try await controlPlane.answerPermissionRequest(
      id: uuid, answer: answer, expectedRevision: revision)
  }

  func setGrant(_ grant: PrivacyGrant) async throws {
    guard let permission = Self.permission(grant) else { return }
    try await edit(grant.principalID) { profile in
      try profile.permissions.set(Self.state(grant.value), for: permission)
    }
  }

  func revokeAll(principalID: String) async throws {
    try await edit(principalID) { profile in
      profile.permissions = Permissions()
      profile.projectNetworks = profile.projectNetworks.mapValues { _ in .none }
      profile.fullAccess = false
    }
  }

  func setExecution(principalID: String, to execution: PrivacyPrincipal.Execution) async throws {
    try await edit(principalID) { profile in profile.fullAccess = execution != .sandbox }
  }

  func confirmRestoredPermissions() async throws {
    guard let view, let epoch = view.epoch else { return }
    try await controlPlane.confirmPermissionAuthority(
      epoch: epoch, expectedRevision: view.revision, profiles: view.profiles)
  }

  func openSystemSettings(for permission: PrivacySystemPermission.Kind) {
    guard let summary = systemPermissions[permission] else { return }
    requestPermission?(summary)
  }

  func setNetwork(_ grant: PrivacyGrant, to network: PrivacyNetworkAccess) async throws {
    guard grant.permission == .projects, let projectID = grant.object?.id else { return }
    let access: NetworkAccess =
      switch try network.validated() {
      case .none: .none
      case .trusted: .trusted
      case .full: .full
      case .custom(let hosts, let includesTrusted):
        .custom(hosts: Set(hosts), includesTrusted: includesTrusted)
      }
    try await edit(grant.principalID) { profile in
      profile.projectNetworks[projectID] = access
    }
  }

  /// Saves one profile against the choices it was read with, so a concurrent change fails
  /// instead of being overwritten.
  private func edit(_ principalID: String, _ change: (inout ProfileGrant) throws -> Void)
    async throws
  {
    guard let id = GatewayProfileID(rawValue: principalID) else { return }
    let options = try await controlPlane.fetchProfilePermissionOptions(id: id)
    var profile = options.grant
    try change(&profile)
    try await controlPlane.saveProfilePermissions(profile, reviewed: options)
  }

  private static func principal(_ profile: ProfileGrant) -> PrivacyPrincipal {
    let connection =
      if profile.allowedCallers.contains(.secureTunnel) {
        "Secure tunnel"
      } else if profile.allowedCallers.contains(.cloudflareTunnel) {
        "Cloudflare tunnel"
      } else {
        "This Mac"
      }
    return PrivacyPrincipal(
      id: profile.id.rawValue, name: AppLocalization.string(profile.id.displayName),
      kind: .client(connection: AppLocalization.string(connection)),
      execution: profile.fullAccess ? .fullAccessSaved : .sandbox)
  }

  private static func grants(_ profile: ProfileGrant, names: PermissionObjectNames)
    -> [PrivacyGrant]
  {
    profile.permissions.entries.compactMap { permission, state in
      guard let (kind, object) = classify(permission, names: names) else { return nil }
      var network: PrivacyNetworkAccess?
      if case .project(let id) = permission, let access = profile.projectNetworks[id] {
        network = Self.network(access.configuration)
      }
      return PrivacyGrant(
        principalID: profile.id.rawValue, permission: kind, object: object,
        value: value(state), network: network)
    }
    .sorted {
      ($0.permission.rawValue, $0.object?.name ?? "") < (
        $1.permission.rawValue, $1.object?.name ?? ""
      )
    }
  }

  private static func request(
    _ item: GatewayPermissionRequestView, principals: [PrivacyPrincipal],
    names: PermissionObjectNames
  ) -> PrivacyRequest? {
    let request = item.request
    guard request.status == .pending,
      let principal = principals.first(where: { $0.id == item.profileID?.rawValue })
    else { return nil }
    switch request.content {
    case .permission(let content):
      guard let (kind, object) = classify(content.requirement.permission, names: names) else {
        return nil
      }
      return PrivacyRequest(
        id: request.id.uuidString, principal: principal, permission: kind, object: object,
        level: level(content.requirement.value), purpose: content.pluginPurpose,
        tool: request.invocation.tool, expires: request.expiresAt)
    case .network(let content):
      return PrivacyRequest(
        id: request.id.uuidString, principal: principal, permission: .projects,
        object: project(content.projectID, names: names), level: .read, host: content.host,
        purpose: content.pluginPurpose, tool: request.invocation.tool,
        expires: request.expiresAt)
    case .projectRegistration(let content):
      return PrivacyRequest(
        id: request.id.uuidString, principal: principal, permission: .projects,
        object: PrivacyObject(
          id: content.projectID,
          name: URL(fileURLWithPath: content.path.string).lastPathComponent,
          detail: content.path.string),
        level: level(content.access), purpose: nil, tool: request.invocation.tool,
        expires: request.expiresAt)
    }
  }

  private static func source(_ source: GatewayManagedPolicyView) -> PrivacyManagedSource {
    let name =
      switch source.source {
      case .owner: "Owner policy"
      case .machine: "Machine policy"
      case .managedPreferences: "Configuration profile"
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
          id: category.rawValue, name: AppLocalization.string(category.title), detail: nil)
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
    id == "*" ? AppLocalization.string(all) : names[id] ?? id
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
