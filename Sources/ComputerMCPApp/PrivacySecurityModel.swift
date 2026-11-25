import ComputerMCPControlPlane
import ComputerMCPCore
import ComputerMCPGateway
import ComputerMCPPermissions
import Foundation
import SwiftUI

/// The permissions a principal can hold, in the order Privacy & Security lists them.
enum PrivacyPermissionKind: String, CaseIterable, Identifiable, Hashable, Sendable {
  case projects, filesAndFolders, screen, desktopControl, localNetwork
  case plugins, mcpServers, machineInformation, unifiedLogs, skills, fullAccess

  var id: Self { self }

  var title: String {
    switch self {
    case .projects: "Projects"
    case .filesAndFolders: "Files & Folders"
    case .screen: "Screen"
    case .desktopControl: "Desktop Control"
    case .localNetwork: "Local Network"
    case .plugins: "Plugins"
    case .mcpServers: "MCP Servers"
    case .machineInformation: "Machine Information"
    case .unifiedLogs: "Unified Logs"
    case .skills: "Skills"
    case .fullAccess: "Full Access"
    }
  }

  var systemImage: String {
    switch self {
    case .projects: "folder.fill"
    case .filesAndFolders: "doc.on.doc.fill"
    case .screen: "rectangle.dashed.badge.record"
    case .desktopControl: "cursorarrow.motionlines"
    case .localNetwork: "network"
    case .plugins: "puzzlepiece.extension.fill"
    case .mcpServers: "server.rack"
    case .machineInformation: "desktopcomputer"
    case .unifiedLogs: "list.bullet.rectangle.fill"
    case .skills: "books.vertical.fill"
    case .fullAccess: "lock.open.fill"
    }
  }

  var summary: String {
    switch self {
    case .projects:
      "Clients and plugins with access to a project can read it. With Read & Write they can change it in worktrees and merge their work back."
    case .filesAndFolders:
      "Allow host tools and sandboxed programs to read files in these folders."
    case .screen:
      "Take screenshots and read windows, displays and accessibility information."
    case .desktopControl:
      "Use the keyboard and pointer, perform accessibility actions and open files in apps. This acts on your whole desktop, outside any sandbox."
    case .localNetwork:
      "Connect from the sandbox to devices on your local network."
    case .plugins: "Use the tools and skills that plugins contribute."
    case .mcpServers: "Use the MCP servers you registered."
    case .machineInformation: "Read system, network and service status."
    case .unifiedLogs:
      "Query the macOS unified log, which can reveal activity on this Mac."
    case .skills: "Read the skill library."
    case .fullAccess:
      "Run programs without the sandbox, as you, in any directory. Host tools still check every permission."
    }
  }

  /// The symbol for one object row; Files & Folders rows show their folder.
  func systemImage(for object: PrivacyObject?) -> String {
    guard self == .filesAndFolders, let id = object?.id else { return systemImage }
    switch FolderCategory(rawValue: id) {
    case .desktop: return "menubar.dock.rectangle"
    case .documents: return "doc.fill"
    case .downloads: return "arrow.down.circle.fill"
    case .iCloudDrive: return "icloud.fill"
    case .networkVolumes: return "externaldrive.connected.to.line.below.fill"
    case .removableVolumes: return "externaldrive.fill"
    case nil: return systemImage
    }
  }

  /// Permissions granted per object list each object as its own group.
  var isPerObject: Bool {
    switch self {
    case .projects, .filesAndFolders, .plugins, .mcpServers: true
    default: false
    }
  }

  /// The values the owner can choose besides Ask and Don't Allow.
  var grantedValues: [PrivacyGrantValue.Level] {
    switch self {
    case .projects: [.read, .readWrite]
    case .mcpServers: [.read, .all]
    case .plugins: [.use]
    case .filesAndFolders: [.read]
    default: [.allow]
    }
  }
}

enum PrivacyGrantValue: Hashable, Sendable {
  enum Level: String, Hashable, Sendable {
    case allow, read, readWrite, use, all

    var title: String {
      switch self {
      case .allow: "Allow"
      case .read: "Read"
      case .readWrite: "Read & Write"
      case .use: "Use"
      case .all: "All"
      }
    }
  }

  /// Not granted: a call that needs it produces a request.
  case ask
  case granted(Level)
  /// Denied: no request is produced.
  case denied

  var title: String {
    switch self {
    case .ask: "Ask"
    case .granted(let level): level.title
    case .denied: "Don't Allow"
    }
  }
}

struct PrivacyPrincipal: Identifiable, Hashable, Sendable {
  enum Kind: Hashable, Sendable {
    /// The connection's name, as a localization key.
    case client(connection: String)
    case plugin(version: String)
    case localServer
  }

  enum Execution: Hashable, Sendable {
    case sandbox
    case fullAccessAllowed
  }

  let id: String
  let name: String
  let kind: Kind
  var execution: Execution
  var fullAccessLimitSources: [String] = []
  var providerAvailability: ProviderPermissionOptions.Availability?
  var clientAvailability: GatewayPermissionSubjectView.Availability?
  /// Verified clients share the saved profile. The profile row owns edits.
  var sharedProfileID: GatewayProfileID?
  var effectiveExecution: Execution?

  var systemImage: String {
    switch kind {
    case .client: "bubble.left.and.text.bubble.right.fill"
    case .plugin: "puzzlepiece.extension.fill"
    case .localServer: "server.rack"
    }
  }

  var kindTitle: String {
    switch kind {
    case .client: "Client"
    case .plugin: "Plugin"
    case .localServer: "Local MCP Server"
    }
  }
}

/// A project's network access level in the sandbox.
enum PrivacyNetworkAccess: Hashable, Sendable {
  case none, trusted, full
  case custom(hosts: [String], includesTrusted: Bool)

  var permissionAccess: NetworkAccess {
    switch self {
    case .none: .none
    case .trusted: .trusted
    case .full: .full
    case .custom(let hosts, let includesTrusted):
      .custom(hosts: Set(hosts), includesTrusted: includesTrusted)
    }
  }

  func validated() throws -> Self {
    guard case .custom(let hosts, let includesTrusted) = self else { return self }
    do {
      let normalized = try hosts.map { host in
        let wildcard = host.hasPrefix("*.")
        return (wildcard ? "*." : "")
          + (try NetworkHost.normalize(wildcard ? String(host.dropFirst(2)) : host))
      }
      return .custom(hosts: Array(Set(normalized)).sorted(), includesTrusted: includesTrusted)
    } catch {
      throw AppControlPlaneError.unavailable(
        "Enter valid host names or IP addresses for custom network access.")
    }
  }
}

struct PrivacyNetworkDraft {
  var hosts: String
  var includesTrusted: Bool

  init(_ access: PrivacyNetworkAccess) {
    switch access {
    case .custom(let hosts, let includesTrusted):
      self.hosts = hosts.joined(separator: "\n")
      self.includesTrusted = includesTrusted
    default:
      hosts = ""
      includesTrusted = access == .trusted
    }
  }

  func network() throws -> PrivacyNetworkAccess {
    let hosts = hosts.components(
      separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: ","))
    )
    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    .filter { !$0.isEmpty }
    return try PrivacyNetworkAccess.custom(hosts: hosts, includesTrusted: includesTrusted)
      .validated()
  }
}

/// The source of an effective value, shown so the owner knows where to change it.
enum PrivacyGrantSource: Hashable, Sendable {
  case owner
  case pluginDeclaration
}

struct PrivacyLimitNotice: Hashable, Sendable {
  enum Effect: Hashable, Sendable {
    case unreadable
    case permission(PrivacyGrantValue.Level?)
    case network(PrivacyNetworkAccess)
  }
  let source: String
  let effect: Effect
}

enum PrivacyGrantChoice: Hashable {
  case inherited
  case explicit(PrivacyGrantValue)
}

struct PrivacyGrant: Identifiable, Hashable, Sendable {
  let principalID: String
  let permission: PrivacyPermissionKind
  /// The project, folder, app, plugin or server; nil for per-principal permissions.
  let object: PrivacyObject?
  /// The explicit or inherited value resolved by the permission library.
  var value: PrivacyGrantValue
  var network: PrivacyNetworkAccess?
  /// Standing authority after ceilings and provider availability are applied.
  var effectiveValue: PrivacyGrantValue?
  var effectiveNetwork: PrivacyNetworkAccess?
  /// A worktree uses this source project's standing permission and sandbox settings.
  var sourceProjectID: String?
  var inheritsProjectAuthority: Bool {
    sourceProjectID.map { $0 != object?.id } ?? false
  }
  var source: PrivacyGrantSource = .owner
  var isStored = true
  var isNetworkStored = false
  /// The library-resolved value after removing this object's explicit entry.
  var inheritedValue: PrivacyGrantValue?
  var allowedLevels: [PrivacyGrantValue.Level]? = nil
  var networkLimits: [PrivacyNetworkAccess] = []
  var trustedHosts: Set<String> = []
  var limitNotices: [PrivacyLimitNotice] = []
  var networkLimitNotices: [PrivacyLimitNotice] = []

  var choice: PrivacyGrantChoice {
    inheritedValue != nil && !isStored ? .inherited : .explicit(value)
  }

  var showsNetwork: Bool {
    guard permission == .projects else { return false }
    if case .granted = value { return true }
    return isNetworkStored
  }

  var allowsInheritance: Bool {
    guard let inheritedValue else { return false }
    if case .granted(let level) = inheritedValue { return availableLevels.contains(level) }
    return true
  }

  var availableLevels: [PrivacyGrantValue.Level] { allowedLevels ?? permission.grantedValues }

  func allowsNetwork(_ value: PrivacyNetworkAccess) -> Bool {
    networkLimits.allSatisfy {
      value.permissionAccess.fits(within: $0.permissionAccess, trustedHosts: trustedHosts)
    }
  }

  var id: String { [principalID, permission.rawValue, object?.id ?? ""].joined(separator: "/") }
}

struct PrivacyObject: Hashable, Sendable {
  let id: String
  let name: String
  let detail: String?
  var isRegistered = true
}

struct PrivacyRequest: Identifiable, Hashable, Sendable {
  let id: String
  let principal: PrivacyPrincipal
  let permission: PrivacyPermissionKind
  let object: PrivacyObject?
  let level: PrivacyGrantValue.Level
  /// A network host the principal's program tried to reach from the project in `object`.
  var host: String? = nil
  /// Set when allowing registers a folder; such a request is answered Allow or Don't Allow.
  var registration: Registration? = nil
  let purpose: String?
  let tool: String
  let expires: Date
}

extension PrivacyRequest {
  enum Registration: Hashable, Sendable {
    /// The folder becomes a new project.
    case newProject
    /// The folder is already a registered project; allowing grants access to it.
    case existingProject
  }
}

struct PrivacyManagedSource: Identifiable, Hashable, Sendable {
  enum State: Hashable, Sendable { case active, unreadable }

  let id: String
  let name: String
  let location: String
  let state: State
  var profileID: GatewayProfileID?
  var provider: PluginIdentity?
  var revision: String?
}

struct PrivacySystemPermission: Identifiable, Hashable, Sendable {
  enum Kind: Hashable, Sendable {
    case screenRecording, accessibility
  }

  enum State: Hashable, Sendable { case allowed, notAllowed, notDetermined }

  let kind: Kind
  let state: State

  var id: String {
    switch kind {
    case .screenRecording: "screen-recording"
    case .accessibility: "accessibility"
    }
  }
}

struct PrivacySnapshot: Equatable, Sendable {
  var revision: UInt64 = 0
  var epoch: UUID?
  var reviewedProfiles: [ProfileGrant] = []
  var reviewedProviders: [String: ProviderPermissionOptions] = [:]
  var clientSubjects: [String: GatewayPermissionSubjectView] = [:]
  var sourceProjects: [String: String] = [:]
  var profileRevisions: [String: Int64] {
    Dictionary(
      uniqueKeysWithValues: reviewedProfiles.map { ($0.id.rawValue, $0.authorizationRevision) })
  }
  func plugins(forUseOf objectID: String) -> [PrivacyPrincipal] {
    principals.filter { principal in
      guard case .plugin = principal.kind else { return false }
      return objectID == "*" || principal.id == "plugin/" + objectID
    }
  }

  var requests: [PrivacyRequest] = []
  var principals: [PrivacyPrincipal] = []
  var grants: [PrivacyGrant] = []
  var managedSources: [PrivacyManagedSource] = []
  var systemPermissions: [PrivacySystemPermission] = []
  /// Set when a restored store started a new authorization epoch.
  var suspendedForReview = false
}

enum PrivacyRequestAnswer: Hashable, Sendable {
  case dontAllow, onlyThisTime, always
}

@MainActor
protocol PrivacySecurityService: AnyObject {
  func privacySnapshot() async throws -> PrivacySnapshot
  func answer(request id: String, with answer: PrivacyRequestAnswer, reviewed: PrivacySnapshot)
    async throws
  func setGrant(_ grant: PrivacyGrant, reviewed: PrivacySnapshot) async throws
  func setNetwork(
    _ grant: PrivacyGrant, to network: PrivacyNetworkAccess, reviewed: PrivacySnapshot) async throws
  func revokeAll(principalID: String, reviewed: PrivacySnapshot) async throws
  func setExecution(
    principalID: String, to execution: PrivacyPrincipal.Execution, reviewed: PrivacySnapshot)
    async throws
  func confirmRestoredPermissions(reviewed: PrivacySnapshot) async throws
  func openSystemSettings(for permission: PrivacySystemPermission.Kind)
}

@MainActor
final class PrivacySecurityModel: ObservableObject {
  @Published var path: [PrivacyRoute] = []
  @Published private(set) var snapshot = PrivacySnapshot()
  @Published private(set) var loading = false
  @Published var failure: String?
  let clientAccess: ClientAccessModel?
  private let service: any PrivacySecurityService

  init(service: any PrivacySecurityService, clientAccess: ClientAccessModel? = nil) {
    self.clientAccess = clientAccess
    self.service = service
  }

  func refresh() async {
    loading = true
    defer { loading = false }
    do { snapshot = try await service.privacySnapshot() } catch {
      failure = AppLocalization.errorDescription(error)
    }
  }

  func answer(
    _ request: PrivacyRequest, _ answer: PrivacyRequestAnswer, reviewed: PrivacySnapshot? = nil
  ) async {
    let reviewed = reviewed ?? snapshot
    await perform {
      try await self.service.answer(request: request.id, with: answer, reviewed: reviewed)
    }
  }

  func set(_ grant: PrivacyGrant, to value: PrivacyGrantValue, reviewed: PrivacySnapshot? = nil)
    async
  {
    await set(grant, choice: .explicit(value), reviewed: reviewed)
  }

  func set(_ grant: PrivacyGrant, choice: PrivacyGrantChoice, reviewed: PrivacySnapshot? = nil)
    async
  {
    var changed = grant
    switch choice {
    case .inherited:
      guard let inherited = grant.inheritedValue else { return }
      changed.value = inherited
      changed.isStored = false
    case .explicit(let value):
      changed.value = value
      changed.isStored = true
    }
    let reviewed = reviewed ?? snapshot
    await perform { try await self.service.setGrant(changed, reviewed: reviewed) }
  }

  @discardableResult
  func setNetwork(
    _ grant: PrivacyGrant, to network: PrivacyNetworkAccess,
    reviewed: PrivacySnapshot? = nil
  ) async -> Bool {
    let reviewed = reviewed ?? snapshot
    return await perform {
      try await self.service.setNetwork(grant, to: network.validated(), reviewed: reviewed)
    }
  }

  func revokeAll(_ principal: PrivacyPrincipal, reviewed: PrivacySnapshot? = nil) async {
    let reviewed = reviewed ?? snapshot
    await perform {
      try await self.service.revokeAll(principalID: principal.id, reviewed: reviewed)
    }
  }

  func setExecution(
    _ principal: PrivacyPrincipal, _ execution: PrivacyPrincipal.Execution,
    reviewed: PrivacySnapshot? = nil
  ) async {
    let reviewed = reviewed ?? snapshot
    await perform {
      try await self.service.setExecution(
        principalID: principal.id, to: execution, reviewed: reviewed)
    }
  }

  func confirmRestoredPermissions(reviewed: PrivacySnapshot? = nil) async {
    let reviewed = reviewed ?? snapshot
    await perform { try await self.service.confirmRestoredPermissions(reviewed: reviewed) }
  }

  func openSystemSettings(for kind: PrivacySystemPermission.Kind) {
    service.openSystemSettings(for: kind)
  }

  func principal(_ id: String) -> PrivacyPrincipal? {
    snapshot.principals.first { $0.id == id }
  }

  func grants(for permission: PrivacyPermissionKind) -> [PrivacyGrant] {
    snapshot.grants.filter { $0.permission == permission && ($0.isStored || $0.isNetworkStored) }
  }

  func grants(for principal: PrivacyPrincipal) -> [PrivacyGrant] {
    snapshot.grants.filter { $0.principalID == principal.id }
  }

  /// Count effective authority once per verified subject, or per unbound profile.
  func holders(of permission: PrivacyPermissionKind) -> Int {
    let boundProfiles = Set(snapshot.principals.compactMap(\.sharedProfileID).map(\.rawValue))
    let principals = snapshot.principals.filter { !boundProfiles.contains($0.id) }
    if permission == .fullAccess {
      return principals.filter { $0.effectiveExecution == .fullAccessAllowed }.count
    }
    let ids = Set(principals.map(\.id))
    return Set(
      snapshot.grants.filter {
        guard $0.permission == permission, ids.contains($0.principalID),
          $0.object?.isRegistered != false
        else { return false }
        if case .granted = $0.effectiveValue { return true }
        return false
      }.map(\.principalID)
    ).count
  }

  @discardableResult
  private func perform(_ operation: @escaping () async throws -> Void) async -> Bool {
    var succeeded = false
    do {
      try await operation()
      succeeded = true
    } catch {
      failure = AppLocalization.errorDescription(error)
    }
    await refresh()
    await clientAccess?.reload()
    return succeeded
  }
}
