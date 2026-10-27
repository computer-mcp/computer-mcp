import ComputerMCPControlPlane
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
    case fullAccessSaved
    case fullAccessConnection
  }

  let id: String
  let name: String
  let kind: Kind
  var execution: Execution

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
  /// The name of the managed source, as a localization key.
  case managedLimit(String)
}

struct PrivacyGrant: Identifiable, Hashable, Sendable {
  let principalID: String
  let permission: PrivacyPermissionKind
  /// The project, folder, app, plugin or server; nil for per-principal permissions.
  let object: PrivacyObject?
  var value: PrivacyGrantValue
  var network: PrivacyNetworkAccess?
  var source: PrivacyGrantSource = .owner

  var id: String { [principalID, permission.rawValue, object?.id ?? ""].joined(separator: "/") }
}

struct PrivacyObject: Hashable, Sendable {
  let id: String
  let name: String
  let detail: String?
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

struct PrivacySnapshot: Hashable, Sendable {
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
  func answer(request id: String, with answer: PrivacyRequestAnswer) async throws
  func setGrant(_ grant: PrivacyGrant) async throws
  func setNetwork(_ grant: PrivacyGrant, to network: PrivacyNetworkAccess) async throws
  func revokeAll(principalID: String) async throws
  func setExecution(principalID: String, to execution: PrivacyPrincipal.Execution) async throws
  func confirmRestoredPermissions() async throws
  func openSystemSettings(for permission: PrivacySystemPermission.Kind)
}

@MainActor
final class PrivacySecurityModel: ObservableObject {
  @Published var path: [PrivacyRoute] = []
  @Published private(set) var snapshot = PrivacySnapshot()
  @Published private(set) var loading = false
  @Published var failure: String?
  private let service: any PrivacySecurityService

  init(service: any PrivacySecurityService) {
    self.service = service
  }

  func refresh() async {
    loading = true
    defer { loading = false }
    do { snapshot = try await service.privacySnapshot() } catch {
      failure = AppLocalization.errorDescription(error)
    }
  }

  func answer(_ request: PrivacyRequest, _ answer: PrivacyRequestAnswer) async {
    await perform { try await self.service.answer(request: request.id, with: answer) }
  }

  func set(_ grant: PrivacyGrant, to value: PrivacyGrantValue) async {
    var changed = grant
    changed.value = value
    await perform { try await self.service.setGrant(changed) }
  }

  @discardableResult
  func setNetwork(_ grant: PrivacyGrant, to network: PrivacyNetworkAccess) async -> Bool {
    do {
      try await service.setNetwork(grant, to: network.validated())
      snapshot = try await service.privacySnapshot()
      return true
    } catch {
      failure = AppLocalization.errorDescription(error)
      return false
    }
  }

  func revokeAll(_ principal: PrivacyPrincipal) async {
    await perform { try await self.service.revokeAll(principalID: principal.id) }
  }

  func setExecution(_ principal: PrivacyPrincipal, _ execution: PrivacyPrincipal.Execution) async {
    await perform { try await self.service.setExecution(principalID: principal.id, to: execution) }
  }

  func confirmRestoredPermissions() async {
    await perform { try await self.service.confirmRestoredPermissions() }
  }

  func openSystemSettings(for kind: PrivacySystemPermission.Kind) {
    service.openSystemSettings(for: kind)
  }

  func principal(_ id: String) -> PrivacyPrincipal? {
    snapshot.principals.first { $0.id == id }
  }

  func grants(for permission: PrivacyPermissionKind) -> [PrivacyGrant] {
    snapshot.grants.filter { $0.permission == permission }
  }

  func grants(for principal: PrivacyPrincipal) -> [PrivacyGrant] {
    snapshot.grants.filter { $0.principalID == principal.id }
  }

  /// Principals currently holding any granted value of the permission.
  func holders(of permission: PrivacyPermissionKind) -> Int {
    if permission == .fullAccess {
      return snapshot.principals.filter { $0.execution != .sandbox }.count
    }
    return Set(
      grants(for: permission).filter {
        if case .granted = $0.value { true } else { false }
      }.map(\.principalID)
    ).count
  }

  private func perform(_ operation: @escaping () async throws -> Void) async {
    do {
      try await operation()
      snapshot = try await service.privacySnapshot()
    } catch {
      failure = AppLocalization.errorDescription(error)
    }
  }
}
