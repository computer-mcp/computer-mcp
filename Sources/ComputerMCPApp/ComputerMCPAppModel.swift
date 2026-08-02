import AppKit
import Combine
import ComputerMCP
import Foundation

enum LoadState<Value> {
  case idle
  case loading
  case loaded(Value)
  case failed(String)
}

struct PresentedAppError: Identifiable {
  let id = UUID()
  let title: String
  let message: String
}

enum ProfileConfirmationKind {
  case activate
  case enableFullShell
}

struct ProfileConfirmation: Identifiable {
  let profile: ProfileSummary
  let kind: ProfileConfirmationKind
  let id = UUID()
}

@MainActor
final class ComputerMCPAppModel: ObservableObject {
  static let profileActivationRefresh: Set<AppWorkspace> = [
    .profiles, .workspaces, .status, .providers, .tunnels,
  ]

  @Published var selectedWorkspace: AppWorkspace? = .status
  @Published var pendingWorkspaceRemoval: WorkspaceSummary?
  @Published var pendingProfileConfirmation: ProfileConfirmation?
  @Published var auditQuery = ""

  @Published private(set) var status: LoadState<AppStatusSnapshot> = .idle
  @Published private(set) var workspaces: LoadState<[WorkspaceSummary]> = .idle
  @Published private(set) var profiles: LoadState<[ProfileSummary]> = .idle
  @Published private(set) var providers: LoadState<[ProviderSummary]> = .idle
  @Published private(set) var openAITunnels: LoadState<[OpenAITunnelSummary]> = .idle
  @Published private(set) var cloudflareTunnels: LoadState<[CloudflareTunnelSummary]> = .idle
  @Published private(set) var permissions: LoadState<[PermissionSummary]> = .idle
  @Published private(set) var audit: LoadState<[AuditEntrySummary]> = .idle
  @Published private(set) var diagnostics: LoadState<DiagnosticsSnapshot> = .idle
  @Published private(set) var openAITunnelLogs: [String: LoadState<OpenAITunnelLogSnapshot>] = [:]
  @Published private(set) var cloudflareTunnelLogs:
    [String: LoadState<CloudflareTunnelLogSnapshot>] = [:]
  @Published private(set) var cliInstallationStatus: EmbeddedCLIInstallationStatus?
  @Published var generatedAccessToken: String?

  @Published private(set) var runningActions: Set<String> = []
  @Published var presentedError: PresentedAppError?
  @Published private(set) var exportedDiagnosticsURL: URL?

  private let controlPlane: any AppControlPlane
  private let permissionCoach = PermissionCoachWindowController()
  private var didStart = false
  private var maintenanceTask: Task<Void, Never>?
  private var permissionPollingTasks: [String: Task<Void, Never>] = [:]

  init(controlPlane: any AppControlPlane) {
    self.controlPlane = controlPlane
  }

  var currentServiceState: ServiceState? {
    guard case .loaded(let snapshot) = status else {
      return nil
    }
    return snapshot.serviceState
  }

  var menuBarSystemImage: String {
    switch currentServiceState {
    case .running: "server.rack"
    case .starting, .stopping: "arrow.triangle.2.circlepath"
    case .degraded: "exclamationmark.triangle"
    case .failed: "xmark.octagon"
    case .stopped, .none: "server.rack"
    }
  }

  var menuBarStatusText: String {
    switch status {
    case .idle: "Not loaded"
    case .loading: "Refreshing"
    case .loaded(let snapshot): snapshot.serviceState.label
    case .failed: "Unavailable"
    }
  }

  func start() {
    guard !didStart else {
      return
    }
    didStart = true
    maintenanceTask = Task { [weak self] in
      guard let self else {
        return
      }
      do {
        try await controlPlane.startApplication()
      } catch {
        presentedError = PresentedAppError(
          title: "Unable to start Computer MCP",
          message: error.localizedDescription
        )
      }
      refreshAll()

      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(5))
        guard !Task.isCancelled else {
          return
        }
        await controlPlane.maintainApplication()
        refresh(.status)
        refresh(.tunnels)
      }
    }
  }

  func prepareForTermination() async {
    permissionCoach.dismiss()
    for task in permissionPollingTasks.values {
      task.cancel()
    }
    permissionPollingTasks.removeAll()
    let task = maintenanceTask
    maintenanceTask = nil
    task?.cancel()
    await task?.value
    await controlPlane.stopApplication()
  }

  func refreshAll() {
    for workspace in AppWorkspace.allCases {
      refresh(workspace)
    }
  }

  func refresh(_ workspace: AppWorkspace) {
    switch workspace {
    case .status:
      Task { await loadStatus() }
    case .workspaces:
      Task { await loadWorkspaces() }
    case .profiles:
      Task { await loadProfiles() }
    case .providers:
      Task { await loadProviders() }
    case .tunnels:
      Task {
        await loadOpenAITunnels()
        await loadCloudflareTunnels()
      }
    case .permissions:
      Task { await loadPermissions() }
    case .audit:
      Task { await loadAudit() }
    case .diagnostics:
      Task { await loadDiagnostics() }
    }
  }

  func isActionRunning(_ key: String) -> Bool {
    runningActions.contains(key)
  }

  func startGateway() {
    performAction(key: "gateway.start", title: "Unable to start gateway", refresh: [.status]) {
      try await self.controlPlane.startGateway()
    }
  }

  func stopGateway() {
    performAction(key: "gateway.stop", title: "Unable to stop gateway", refresh: [.status]) {
      try await self.controlPlane.stopGateway()
    }
  }

  func setLaunchAtLoginEnabled(_ enabled: Bool) {
    performAction(
      key: "launch-at-login",
      title: "Unable to update launch at login",
      refresh: [.status, .diagnostics]
    ) {
      try await self.controlPlane.setLaunchAtLoginEnabled(enabled)
    }
  }

  func addWorkspace(at url: URL) {
    performAction(
      key: "workspace.add",
      title: "Unable to register workspace",
      refresh: [.workspaces, .status]
    ) {
      try await self.controlPlane.registerWorkspace(at: url)
    }
  }

  func requestWorkspaceRemoval(_ workspace: WorkspaceSummary) {
    pendingWorkspaceRemoval = workspace
  }

  func removeWorkspace(id: String) {
    performAction(
      key: "workspace.remove.\(id)",
      title: "Unable to remove workspace",
      refresh: [.workspaces, .status]
    ) {
      try await self.controlPlane.removeWorkspace(id: id)
    }
  }

  func setWorkspaceEnabled(_ enabled: Bool, workspace: WorkspaceSummary) {
    performAction(
      key: "workspace.grant.\(workspace.id)",
      title: "Unable to update workspace access",
      refresh: [.workspaces, .status]
    ) {
      try await self.controlPlane.setWorkspaceEnabled(
        enabled,
        workspaceID: workspace.id,
        profileID: workspace.activeProfileID
      )
    }
  }

  func activateProfile(id: String) {
    performAction(
      key: "profile.activate.\(id)",
      title: "Unable to activate profile",
      refresh: Self.profileActivationRefresh
    ) {
      try await self.controlPlane.activateProfile(id: id)
    }
  }

  func requestProfileActivation(_ profile: ProfileSummary) {
    if profile.riskLevel == .low {
      activateProfile(id: profile.id)
    } else {
      pendingProfileConfirmation = ProfileConfirmation(profile: profile, kind: .activate)
    }
  }

  func requestFullShellChange(_ enabled: Bool, profile: ProfileSummary) {
    if enabled {
      pendingProfileConfirmation = ProfileConfirmation(
        profile: profile,
        kind: .enableFullShell
      )
    } else {
      setFullShellEnabled(false, profileID: profile.id)
    }
  }

  func setFullShellEnabled(_ enabled: Bool, profileID: String) {
    performAction(
      key: "profile.shell.\(profileID)",
      title: "Unable to update Full Shell",
      refresh: [.profiles, .status]
    ) {
      try await self.controlPlane.setFullShellEnabled(enabled, profileID: profileID)
    }
  }

  func startProvider(id: String) {
    performAction(
      key: "provider.start.\(id)",
      title: "Unable to start provider",
      refresh: [.providers, .status]
    ) {
      try await self.controlPlane.startProvider(id: id)
    }
  }

  func stopProvider(id: String) {
    performAction(
      key: "provider.stop.\(id)",
      title: "Unable to stop provider",
      refresh: [.providers, .status]
    ) {
      try await self.controlPlane.stopProvider(id: id)
    }
  }

  func doctorProvider(id: String) {
    performAction(
      key: "provider.doctor.\(id)",
      title: "Provider diagnostics failed",
      refresh: [.providers, .diagnostics]
    ) {
      try await self.controlPlane.doctorProvider(id: id)
    }
  }

  func startOpenAITunnel(id: String) {
    performAction(
      key: "tunnel.start.\(id)",
      title: "Unable to start tunnel",
      refresh: [.tunnels, .status]
    ) {
      try await self.controlPlane.startOpenAITunnel(id: id)
    }
  }

  func stopOpenAITunnel(id: String) {
    performAction(
      key: "tunnel.stop.\(id)",
      title: "Unable to stop tunnel",
      refresh: [.tunnels, .status]
    ) {
      try await self.controlPlane.stopOpenAITunnel(id: id)
    }
  }

  func reconnectOpenAITunnel(id: String) {
    performAction(
      key: "tunnel.reconnect.\(id)",
      title: "Unable to reconnect tunnel",
      refresh: [.tunnels, .status]
    ) {
      try await self.controlPlane.reconnectOpenAITunnel(id: id)
    }
  }

  func loadOpenAITunnelLogs(id: String) {
    openAITunnelLogs[id] = .loading
    Task {
      do {
        openAITunnelLogs[id] = .loaded(try await controlPlane.fetchOpenAITunnelLogs(id: id))
      } catch {
        openAITunnelLogs[id] = .failed(error.localizedDescription)
      }
    }
  }

  func doctorOpenAITunnel(id: String) {
    performAction(
      key: "tunnel.doctor.\(id)",
      title: "OpenAI Tunnel diagnostics failed",
      refresh: [.tunnels, .diagnostics]
    ) {
      try await self.controlPlane.doctorOpenAITunnel(id: id)
    }
  }

  func provisionOpenAITunnel(id: String) {
    performAction(
      key: "tunnel.provision.\(id)",
      title: "Unable to provision tunnel",
      refresh: [.tunnels, .diagnostics]
    ) {
      try await self.controlPlane.provisionOpenAITunnel(id: id)
    }
  }

  func saveOpenAITunnelConfiguration(_ draft: OpenAITunnelConfigurationDraft) {
    performAction(
      key: "tunnel.save.\(draft.id)",
      title: "Unable to save tunnel",
      refresh: [.tunnels, .diagnostics]
    ) {
      try await self.controlPlane.saveOpenAITunnelConfiguration(draft)
    }
  }

  func deleteOpenAITunnel(id: String) {
    performAction(
      key: "tunnel.delete.\(id)",
      title: "Unable to delete tunnel",
      refresh: [.tunnels, .status, .diagnostics]
    ) {
      try await self.controlPlane.deleteOpenAITunnel(id: id)
    }
  }

  func startCloudflareTunnel(id: String) {
    performAction(
      key: "cloudflare.start.\(id)",
      title: "Unable to start Cloudflare Tunnel",
      refresh: [.tunnels, .status]
    ) {
      try await self.controlPlane.startCloudflareTunnel(id: id)
    }
  }

  func stopCloudflareTunnel(id: String) {
    performAction(
      key: "cloudflare.stop.\(id)",
      title: "Unable to stop Cloudflare Tunnel",
      refresh: [.tunnels, .status]
    ) {
      try await self.controlPlane.stopCloudflareTunnel(id: id)
    }
  }

  func doctorCloudflareTunnel(id: String) {
    performAction(
      key: "cloudflare.doctor.\(id)",
      title: "Cloudflare Tunnel diagnostics failed",
      refresh: [.tunnels, .diagnostics]
    ) {
      try await self.controlPlane.doctorCloudflareTunnel(id: id)
    }
  }

  func loadCloudflareTunnelLogs(id: String) {
    cloudflareTunnelLogs[id] = .loading
    Task {
      do {
        cloudflareTunnelLogs[id] = .loaded(
          try await controlPlane.fetchCloudflareTunnelLogs(id: id)
        )
      } catch {
        cloudflareTunnelLogs[id] = .failed(error.localizedDescription)
      }
    }
  }

  func saveCloudflareTunnelConfiguration(_ draft: CloudflareTunnelConfigurationDraft) {
    performAction(
      key: "cloudflare.save.\(draft.id)",
      title: "Unable to save Cloudflare Tunnel",
      refresh: [.tunnels, .diagnostics]
    ) {
      self.generatedAccessToken = try await self.controlPlane
        .saveCloudflareTunnelConfiguration(draft)
    }
  }

  func deleteCloudflareTunnel(id: String) {
    performAction(
      key: "cloudflare.delete.\(id)",
      title: "Unable to delete Cloudflare Tunnel",
      refresh: [.tunnels, .status, .diagnostics]
    ) {
      try await self.controlPlane.deleteCloudflareTunnel(id: id)
    }
  }

  func installCommandLineTool() {
    performAction(
      key: "cli.install",
      title: "Unable to install command line tool",
      refresh: [.status]
    ) {
      self.cliInstallationStatus = try await self.controlPlane.installCommandLineTool()
    }
  }

  func saveManifest(_ content: String) {
    performAction(
      key: "manifest.save",
      title: "Unable to activate manifest",
      refresh: [.diagnostics, .status, .profiles, .providers, .tunnels]
    ) {
      try await self.controlPlane.saveManifest(content)
    }
  }

  func rollbackManifest(to revisionID: String) {
    performAction(
      key: "manifest.rollback.\(revisionID)",
      title: "Unable to roll back manifest",
      refresh: [.diagnostics, .status, .profiles, .providers, .tunnels]
    ) {
      try await self.controlPlane.rollbackManifest(to: revisionID)
    }
  }

  func exportDiagnostics(to destination: URL) {
    performAction(
      key: "diagnostics.export",
      title: "Unable to export diagnostics",
      refresh: []
    ) {
      try await self.controlPlane.exportDiagnostics(to: destination)
      self.exportedDiagnosticsURL = destination
    }
  }

  func openPermissionSettings(_ permission: PermissionSummary) {
    guard let url = permission.settingsURL else {
      presentedError = PresentedAppError(
        title: "Settings link unavailable",
        message: "This permission does not provide a System Settings deep link."
      )
      return
    }
    guard NSWorkspace.shared.open(url) else {
      presentedError = PresentedAppError(
        title: "Unable to open System Settings",
        message: url.absoluteString
      )
      return
    }
  }

  func requestPermission(_ permission: PermissionSummary) {
    let actionKey = "permission.request.\(permission.id)"
    guard !runningActions.contains(actionKey) else {
      return
    }
    runningActions.insert(actionKey)
    permissionPollingTasks[permission.id]?.cancel()

    Task {
      defer {
        runningActions.remove(actionKey)
      }
      do {
        let outcome = try await controlPlane.requestPermission(id: permission.id)
        refresh(.permissions)
        guard outcome.state != .granted else {
          permissionCoach.dismiss()
          return
        }

        openPermissionSettings(permission)
        try? await Task.sleep(for: .milliseconds(700))
        permissionCoach.show(permission: permission)
        startPermissionPolling(permissionID: permission.id)
      } catch {
        presentedError = PresentedAppError(
          title: "Unable to request \(permission.displayName)",
          message: error.localizedDescription
        )
      }
    }
  }

  func revealWorkspace(_ workspace: WorkspaceSummary) {
    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: workspace.path)
  }

  private func loadStatus() async {
    status = .loading
    do {
      status = .loaded(try await controlPlane.fetchStatus())
      cliInstallationStatus = try? await controlPlane.commandLineToolStatus()
    } catch {
      status = .failed(error.localizedDescription)
    }
  }

  private func loadWorkspaces() async {
    workspaces = .loading
    do {
      workspaces = .loaded(try await controlPlane.fetchWorkspaces())
    } catch {
      workspaces = .failed(error.localizedDescription)
    }
  }

  private func loadProfiles() async {
    profiles = .loading
    do {
      profiles = .loaded(try await controlPlane.fetchProfiles())
    } catch {
      profiles = .failed(error.localizedDescription)
    }
  }

  private func loadProviders() async {
    providers = .loading
    do {
      providers = .loaded(try await controlPlane.fetchProviders())
    } catch {
      providers = .failed(error.localizedDescription)
    }
  }

  private func loadOpenAITunnels() async {
    openAITunnels = .loading
    do {
      openAITunnels = .loaded(try await controlPlane.fetchOpenAITunnels())
    } catch {
      openAITunnels = .failed(error.localizedDescription)
    }
  }

  private func loadCloudflareTunnels() async {
    cloudflareTunnels = .loading
    do {
      cloudflareTunnels = .loaded(try await controlPlane.fetchCloudflareTunnels())
    } catch {
      cloudflareTunnels = .failed(error.localizedDescription)
    }
  }

  private func loadPermissions() async {
    permissions = .loading
    do {
      permissions = .loaded(try await controlPlane.fetchPermissions())
    } catch {
      permissions = .failed(error.localizedDescription)
    }
  }

  private func startPermissionPolling(permissionID: String) {
    permissionPollingTasks[permissionID]?.cancel()
    permissionPollingTasks[permissionID] = Task { [weak self] in
      guard let self else {
        return
      }
      defer {
        permissionPollingTasks.removeValue(forKey: permissionID)
      }

      for _ in 0..<90 {
        guard !Task.isCancelled else {
          return
        }
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else {
          return
        }
        guard
          let permission = try? await controlPlane.fetchPermissions().first(
            where: { $0.id == permissionID }
          )
        else {
          continue
        }
        if permission.state == .granted {
          permissionCoach.dismiss()
          refresh(.permissions)
          return
        }
      }
    }
  }

  private func loadAudit() async {
    audit = .loading
    do {
      audit = .loaded(try await controlPlane.fetchAudit())
    } catch {
      audit = .failed(error.localizedDescription)
    }
  }

  private func loadDiagnostics() async {
    diagnostics = .loading
    do {
      diagnostics = .loaded(try await controlPlane.fetchDiagnostics())
    } catch {
      diagnostics = .failed(error.localizedDescription)
    }
  }

  private func performAction(
    key: String,
    title: String,
    refresh workspaces: Set<AppWorkspace>,
    operation: @escaping @MainActor () async throws -> Void
  ) {
    guard !runningActions.contains(key) else {
      return
    }
    runningActions.insert(key)
    Task {
      defer {
        runningActions.remove(key)
      }
      do {
        try await operation()
        for workspace in workspaces {
          refresh(workspace)
        }
      } catch {
        presentedError = PresentedAppError(title: title, message: error.localizedDescription)
      }
    }
  }
}
