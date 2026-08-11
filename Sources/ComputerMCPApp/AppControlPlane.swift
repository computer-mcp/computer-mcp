import ComputerMCP
import Foundation

enum AppWorkspace: String, CaseIterable, Identifiable, Sendable {
  case home
  case chatgpt
  case cloudflare
  case workspaces
  case profiles
  case providers
  case tunnels
  case permissions
  case audit
  case diagnostics

  var id: Self { self }

  var title: String {
    let key =
      switch self {
      case .home: "Home"
      case .chatgpt: "ChatGPT"
      case .cloudflare: "Cloudflare"
      case .workspaces: "Workspaces"
      case .profiles: "Profiles"
      case .providers: "Providers"
      case .tunnels: "Tunnels"
      case .permissions: "Permissions"
      case .audit: "Audit"
      case .diagnostics: "Diagnostics"
      }
    return AppLocalization.string(key)
  }

  var systemImage: String {
    switch self {
    case .home: "house"
    case .chatgpt: "bubble.left.and.text.bubble.right"
    case .cloudflare: "cloud"
    case .workspaces: "folder"
    case .profiles: "person.badge.key"
    case .providers: "shippingbox"
    case .tunnels: "point.3.connected.trianglepath.dotted"
    case .permissions: "hand.raised"
    case .audit: "list.bullet.rectangle"
    case .diagnostics: "stethoscope"
    }
  }

  var group: AppWorkspaceGroup {
    switch self {
    case .home, .chatgpt, .cloudflare: .getStarted
    case .workspaces, .profiles, .providers, .tunnels, .permissions: .configure
    case .audit: .activity
    case .diagnostics: .support
    }
  }
}

enum AppWorkspaceGroup: String, CaseIterable, Identifiable, Sendable {
  case getStarted
  case configure
  case activity
  case support

  var id: Self { self }

  var title: String {
    let key =
      switch self {
      case .getStarted: "Get Started"
      case .configure: "Configure"
      case .activity: "Activity"
      case .support: "Support"
      }
    return AppLocalization.string(key)
  }
}

enum ServiceState: String, Sendable {
  case stopped
  case starting
  case running
  case stopping
  case degraded
  case failed

  var label: String {
    let key =
      switch self {
      case .stopped: "Stopped"
      case .starting: "Starting"
      case .running: "Running"
      case .stopping: "Stopping"
      case .degraded: "Degraded"
      case .failed: "Failed"
      }
    return AppLocalization.string(key)
  }
}

enum RiskLevel: String, Sendable {
  case low
  case elevated
  case high

  var label: String {
    AppLocalization.string(rawValue.capitalized)
  }
}

struct AppStatusSnapshot: Sendable {
  var serviceState: ServiceState
  var version: String
  var activeProfileName: String?
  var activeWorkspaceCount: Int
  var providerCount: Int
  var runningProviderCount: Int
  var runningTunnelCount: Int
  var socketPath: String?
  var processIdentifier: Int32?
  var startedAt: Date?
  var lastError: String?
  var launchAtLogin: LoginItemState
}

enum LoginItemState: String, Sendable {
  case disabled
  case enabled
  case requiresApproval
  case unavailable

  var label: String {
    let key =
      switch self {
      case .disabled: "Disabled"
      case .enabled: "Enabled"
      case .requiresApproval: "Requires approval"
      case .unavailable: "Unavailable"
      }
    return AppLocalization.string(key)
  }
}

enum WorkspaceHealth: String, Sendable {
  case available
  case bookmarkStale
  case missing

  var label: String {
    let key =
      switch self {
      case .available: "Available"
      case .bookmarkStale: "Bookmark stale"
      case .missing: "Missing"
      }
    return AppLocalization.string(key)
  }
}

struct WorkspaceSummary: Identifiable, Sendable {
  var id: String
  var displayName: String
  var path: String
  var health: WorkspaceHealth
  var activeProfileID: String
  var isEnabled: Bool
  var isSelected: Bool
  var lastResolvedAt: Date?
}

struct ProfileSummary: Identifiable, Sendable {
  var id: String
  var displayName: String
  var summary: String
  var isActive: Bool
  var isEnabled: Bool
  var riskLevel: RiskLevel
  var permitsRemoteAccess: Bool
  var supportsFullShell: Bool
  var fullShellEnabled: Bool
}

enum ProviderKind: String, Sendable {
  case builtin
  case cli
  case mcp
  case codex
  case computerUse
  case external

  var label: String {
    let key =
      switch self {
      case .builtin: "Builtin"
      case .cli: "CLI"
      case .mcp: "MCP"
      case .codex: "Codex"
      case .computerUse: "Computer Use"
      case .external: "External"
      }
    return AppLocalization.string(key)
  }
}

struct ProviderSummary: Identifiable, Sendable {
  var id: String
  var displayName: String
  var kind: ProviderKind
  var state: ServiceState
  var version: String?
  var executablePath: String?
  var toolCount: Int?
  var lastDoctorMessage: String?
  var lastError: String?
  var lifecycleManaged: Bool = false
}

struct OpenAITunnelSummary: Identifiable, Sendable {
  var id: String
  var displayName: String
  var profileID: String
  var state: ServiceState
  var tunnelIdentifier: String?
  var endpoint: String?
  var connectedAt: Date?
  var reconnectAttempt: Int
  var lastError: String?
  var tunnelClientPath: String?
  var httpProxy: String?
}

struct OpenAITunnelConfigurationDraft: Identifiable, Sendable {
  var id: String
  var tunnelClientProfile: String
  var tunnelID: String
  var gatewayProfileID: String
  var tunnelClientPath: String?
  var httpProxy: String?
  var apiKey: String?
}

struct OpenAITunnelLogSnapshot: Sendable {
  var profileID: String
  var state: ServiceState
  var stdout: String
  var stderr: String
}

struct CloudflareTunnelSummary: Identifiable, Sendable {
  var id: String
  var tunnelName: String
  var publicHostname: String
  var profileID: String
  var state: ServiceState
  var localPort: Int
  var metricsPort: Int
  var processIdentifier: Int32?
  var connectedAt: Date?
  var lastError: String?
}

struct LocalMCPConnectionSummary: Sendable {
  var command: String
  var arguments: [String]
  var cliInstallation: EmbeddedCLIInstallationStatus

  var displayCommand: String {
    ([command] + arguments).map(Self.shellToken).joined(separator: " ")
  }

  private static func shellToken(_ value: String) -> String {
    guard !value.isEmpty,
      value.unicodeScalars.allSatisfy({
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/:")).contains($0)
      })
    else {
      return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    return value
  }
}

struct CloudflareTunnelConfigurationDraft: Identifiable, Sendable {
  var id: String
  var tunnelName: String
  var publicHostname: String
  var gatewayProfileID: String
  var localPort: Int
  var metricsPort: Int
  var cloudflaredPath: String?
  var tunnelToken: String?
  var regenerateAccessToken: Bool
}

struct CloudflareTunnelLogSnapshot: Sendable {
  var profileID: String
  var stdout: String
  var stderr: String
  var truncated: Bool
}

enum PermissionState: String, Sendable {
  case granted
  case denied
  case notGranted
  case notDetermined
  case unavailable

  var label: String {
    let key =
      switch self {
      case .granted: "Granted"
      case .denied: "Denied"
      case .notGranted: "Not granted"
      case .notDetermined: "Not determined"
      case .unavailable: "Unavailable"
      }
    return AppLocalization.string(key)
  }
}

struct PermissionSummary: Identifiable, Sendable {
  var id: String
  var displayName: String
  var detail: String
  var state: PermissionState
  var settingsURL: URL?
  var checkedAt: Date
}

struct PermissionRequestOutcome: Sendable {
  var permissionID: String
  var state: PermissionState
  var systemPromptRequested: Bool
}

enum AuditDecision: String, Sendable {
  case allowed
  case denied
  case prepared
  case committed
  case failed

  var label: String {
    AppLocalization.string(rawValue.capitalized)
  }
}

struct AuditEntrySummary: Identifiable, Sendable {
  var id: String
  var requestID: String
  var timestamp: Date
  var decision: AuditDecision
  var caller: String
  var capability: String
  var workspaceName: String?
  var summary: String
  var inputDigest: String?
  var outputByteCount: Int?
}

enum DiagnosticLevel: String, Sendable {
  case information
  case warning
  case error
}

struct DiagnosticItem: Identifiable, Sendable {
  var id: String
  var title: String
  var value: String
  var detail: String?
  var level: DiagnosticLevel
}

struct ManifestRevisionSummary: Identifiable, Sendable {
  var id: String
  var digest: String
  var createdAt: Date
  var isCurrent: Bool
  var activationError: String?
}

struct ManifestSnapshot: Sendable {
  var path: String
  var content: String
  var revisions: [ManifestRevisionSummary]
}

struct DiagnosticsSnapshot: Sendable {
  var generatedAt: Date
  var items: [DiagnosticItem]
  var logDirectory: String
  var applicationSupportDirectory: String
  var manifest: ManifestSnapshot
}

@MainActor
protocol AppControlPlane: AnyObject {
  func startApplication() async throws
  func maintainApplication() async
  func stopApplication() async

  func fetchStatus() async throws -> AppStatusSnapshot
  func fetchReadiness() async throws -> [ProductReadinessSnapshot]
  func fetchWorkspaces() async throws -> [WorkspaceSummary]
  func fetchProfiles() async throws -> [ProfileSummary]
  func fetchProviders() async throws -> [ProviderSummary]
  func fetchOpenAITunnels() async throws -> [OpenAITunnelSummary]
  func fetchCloudflareTunnels() async throws -> [CloudflareTunnelSummary]
  func fetchPermissions() async throws -> [PermissionSummary]
  func requestPermission(id: String) async throws -> PermissionRequestOutcome
  func fetchAudit() async throws -> [AuditEntrySummary]
  func fetchDiagnostics() async throws -> DiagnosticsSnapshot

  func startGateway() async throws
  func stopGateway() async throws
  func setLaunchAtLoginEnabled(_ enabled: Bool) async throws

  func registerWorkspace(at url: URL) async throws
  func removeWorkspace(id: String) async throws
  func setWorkspaceEnabled(
    _ enabled: Bool,
    workspaceID: String,
    profileID: String
  ) async throws

  func activateProfile(id: String) async throws
  func setFullShellEnabled(_ enabled: Bool, profileID: String) async throws

  func startProvider(id: String) async throws
  func stopProvider(id: String) async throws
  func doctorProvider(id: String) async throws

  func startOpenAITunnel(id: String) async throws
  func reconnectOpenAITunnel(id: String) async throws
  func stopOpenAITunnel(id: String) async throws
  func fetchOpenAITunnelLogs(id: String) async throws -> OpenAITunnelLogSnapshot
  func doctorOpenAITunnel(id: String) async throws
  func provisionOpenAITunnel(id: String) async throws
  func saveOpenAITunnelConfiguration(_ draft: OpenAITunnelConfigurationDraft) async throws
  func deleteOpenAITunnel(id: String) async throws

  func startCloudflareTunnel(id: String) async throws
  func stopCloudflareTunnel(id: String) async throws
  func doctorCloudflareTunnel(id: String) async throws
  func fetchCloudflareTunnelLogs(id: String) async throws -> CloudflareTunnelLogSnapshot
  func saveCloudflareTunnelConfiguration(
    _ draft: CloudflareTunnelConfigurationDraft
  ) async throws -> String?
  func deleteCloudflareTunnel(id: String) async throws

  func installCommandLineTool() async throws -> EmbeddedCLIInstallationStatus
  func commandLineToolStatus() async throws -> EmbeddedCLIInstallationStatus
  func localMCPConnection() async throws -> LocalMCPConnectionSummary
  func previewCodexRegistration() async throws -> CodexMCPInstallInvocation
  func installCodexRegistration() async throws -> CommandResult

  func saveManifest(_ content: String) async throws
  func rollbackManifest(to revisionID: String) async throws
  func exportDiagnostics(to destination: URL) async throws
}

enum AppControlPlaneError: LocalizedError {
  case unavailable(String)

  var errorDescription: String? {
    switch self {
    case .unavailable(let reason):
      reason
    }
  }
}

@MainActor
final class UnavailableControlPlane: AppControlPlane {
  private let reason: String

  init(
    reason: String =
      "The local Computer MCP control plane is not connected. Runtime integration must inject an AppControlPlane implementation."
  ) {
    self.reason = reason
  }

  func startApplication() async throws { throw unavailable() }
  func maintainApplication() async {}
  func stopApplication() async {}
  func fetchStatus() async throws -> AppStatusSnapshot { throw unavailable() }
  func fetchReadiness() async throws -> [ProductReadinessSnapshot] { throw unavailable() }
  func fetchWorkspaces() async throws -> [WorkspaceSummary] { throw unavailable() }
  func fetchProfiles() async throws -> [ProfileSummary] { throw unavailable() }
  func fetchProviders() async throws -> [ProviderSummary] { throw unavailable() }
  func fetchOpenAITunnels() async throws -> [OpenAITunnelSummary] { throw unavailable() }
  func fetchCloudflareTunnels() async throws -> [CloudflareTunnelSummary] { throw unavailable() }
  func fetchPermissions() async throws -> [PermissionSummary] { throw unavailable() }
  func requestPermission(id: String) async throws -> PermissionRequestOutcome {
    throw unavailable()
  }
  func fetchAudit() async throws -> [AuditEntrySummary] { throw unavailable() }
  func fetchDiagnostics() async throws -> DiagnosticsSnapshot { throw unavailable() }

  func startGateway() async throws { throw unavailable() }
  func stopGateway() async throws { throw unavailable() }
  func setLaunchAtLoginEnabled(_ enabled: Bool) async throws { throw unavailable() }
  func registerWorkspace(at url: URL) async throws { throw unavailable() }
  func removeWorkspace(id: String) async throws { throw unavailable() }
  func setWorkspaceEnabled(
    _ enabled: Bool,
    workspaceID: String,
    profileID: String
  ) async throws {
    throw unavailable()
  }
  func activateProfile(id: String) async throws { throw unavailable() }
  func setFullShellEnabled(_ enabled: Bool, profileID: String) async throws {
    throw unavailable()
  }
  func startProvider(id: String) async throws { throw unavailable() }
  func stopProvider(id: String) async throws { throw unavailable() }
  func doctorProvider(id: String) async throws { throw unavailable() }
  func startOpenAITunnel(id: String) async throws { throw unavailable() }
  func reconnectOpenAITunnel(id: String) async throws { throw unavailable() }
  func stopOpenAITunnel(id: String) async throws { throw unavailable() }
  func fetchOpenAITunnelLogs(id: String) async throws -> OpenAITunnelLogSnapshot {
    throw unavailable()
  }
  func doctorOpenAITunnel(id: String) async throws { throw unavailable() }
  func provisionOpenAITunnel(id: String) async throws { throw unavailable() }
  func saveOpenAITunnelConfiguration(_ draft: OpenAITunnelConfigurationDraft) async throws {
    throw unavailable()
  }
  func deleteOpenAITunnel(id: String) async throws { throw unavailable() }
  func startCloudflareTunnel(id: String) async throws { throw unavailable() }
  func stopCloudflareTunnel(id: String) async throws { throw unavailable() }
  func doctorCloudflareTunnel(id: String) async throws { throw unavailable() }
  func fetchCloudflareTunnelLogs(id: String) async throws -> CloudflareTunnelLogSnapshot {
    throw unavailable()
  }
  func saveCloudflareTunnelConfiguration(
    _ draft: CloudflareTunnelConfigurationDraft
  ) async throws -> String? { throw unavailable() }
  func deleteCloudflareTunnel(id: String) async throws { throw unavailable() }
  func installCommandLineTool() async throws -> EmbeddedCLIInstallationStatus {
    throw unavailable()
  }
  func commandLineToolStatus() async throws -> EmbeddedCLIInstallationStatus {
    throw unavailable()
  }
  func localMCPConnection() async throws -> LocalMCPConnectionSummary { throw unavailable() }
  func previewCodexRegistration() async throws -> CodexMCPInstallInvocation {
    throw unavailable()
  }
  func installCodexRegistration() async throws -> CommandResult { throw unavailable() }
  func saveManifest(_ content: String) async throws { throw unavailable() }
  func rollbackManifest(to revisionID: String) async throws { throw unavailable() }
  func exportDiagnostics(to destination: URL) async throws { throw unavailable() }

  private func unavailable() -> AppControlPlaneError {
    .unavailable(reason)
  }
}
