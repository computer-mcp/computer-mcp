import AppKit
import ComputerMCP
import Foundation

@MainActor
final class LiveAppControlPlane: AppControlPlane {
  private let controlPlane: AppControlPlaneService
  private let gatewayService: AppGatewayService
  private let controlSocketService: ControlSocketService?
  private let fileLogger: AppFileLogger
  private let permissionRequester: any SystemPermissionRequesting
  private var reconnectAttempts: [String: Int] = [:]
  private var nextReconnectAt: [String: Date] = [:]
  private var maintenanceInProgress = false

  init() throws {
    let controlPlane = try AppControlPlaneService.live(
      openAITunnelGatewayExecutablePath: Self.embeddedGatewayExecutablePath()
    )
    self.controlPlane = controlPlane
    self.gatewayService = AppGatewayService.live(
      controlPlane: controlPlane,
      directories: controlPlane.directories
    )
    self.controlSocketService = ControlSocketService(
      controlPlane: controlPlane,
      gatewayService: gatewayService,
      socketURL: controlPlane.directories.controlSocket
    )
    self.fileLogger = try AppFileLogger(directory: controlPlane.directories.logs)
    self.permissionRequester = MacOSSystemPermissionRequester()
    fileLogger.append(.info, event: "app.control_plane.initialized")
  }

  init(
    controlPlane: AppControlPlaneService,
    gatewayService: AppGatewayService,
    fileLogger: AppFileLogger,
    permissionRequester: any SystemPermissionRequesting = MacOSSystemPermissionRequester()
  ) {
    self.controlPlane = controlPlane
    self.gatewayService = gatewayService
    self.controlSocketService = nil
    self.fileLogger = fileLogger
    self.permissionRequester = permissionRequester
    fileLogger.append(.info, event: "app.control_plane.initialized")
  }

  func startApplication() async throws {
    fileLogger.append(.info, event: "app.start.requested")
    try await controlSocketService?.start()
    guard try await controlPlane.gatewayDesiredRunning() else {
      fileLogger.append(.info, event: "app.start.gateway_disabled")
      return
    }
    let desiredProfiles = try await restoreGatewayRuntime()
    restoreTransportsAfterStartup(profiles: desiredProfiles)
    fileLogger.append(.info, event: "app.start.completed")
  }

  func maintainApplication() async {
    guard !maintenanceInProgress else {
      return
    }
    maintenanceInProgress = true
    defer {
      maintenanceInProgress = false
    }

    do {
      guard try await controlPlane.gatewayDesiredRunning() else {
        return
      }
      let service = await gatewayService.snapshot()
      if service.state != .running && service.state != .starting {
        try await restoreRuntime()
        return
      }
      try await restoreDesiredOpenAITunnels()
      try await restoreDesiredCloudflareTunnels()
    } catch {
      fileLogger.append(
        .warning,
        event: "app.maintenance.failed",
        fields: ["error_type": String(describing: type(of: error))]
      )
      // Runtime snapshots retain stable failure state for Diagnostics and the Tunnel UI.
    }
  }

  func stopApplication() async {
    fileLogger.append(.info, event: "app.stop.requested")
    reconnectAttempts.removeAll()
    nextReconnectAt.removeAll()
    await gatewayService.stop()
    fileLogger.append(.info, event: "app.stop.completed")
  }

  func fetchStatus() async throws -> AppStatusSnapshot {
    let service = await gatewayService.snapshot()
    let snapshot = try await controlPlane.snapshot()
    let providers = try await providerSummaries(service: service)
    let activeProfile = try await controlPlane.activeGatewayProfile()
    return AppStatusSnapshot(
      serviceState: service.state.appState,
      version: ComputerMCPCLI.version,
      activeProfileName: service.profileID?.rawValue ?? activeProfile.rawValue,
      activeWorkspaceCount: try await controlPlane.workspaces().count,
      providerCount: providers.count,
      runningProviderCount: providers.filter { $0.state == .running }.count,
      runningTunnelCount:
        snapshot.openAITunnelStatuses.filter { $0.state == .running }.count
        + snapshot.cloudflareStatuses.filter { $0.state == .running }.count,
      socketPath: service.socketPath,
      processIdentifier: service.processIdentifier,
      startedAt: service.startedAt,
      lastError: service.lastError,
      launchAtLogin: snapshot.launchAtLogin.appState
    )
  }

  func fetchReadiness() async throws -> [ProductReadinessSnapshot] {
    let gateway = await gatewayService.snapshot()
    let cliInstallation = try? EmbeddedCLIInstaller().status()
    var snapshots = [ProductReadinessSnapshot]()
    for journey in ProductJourney.allCases {
      snapshots.append(
        try await controlPlane.readinessSnapshot(
          journey: journey,
          gateway: gateway,
          cliInstallation: cliInstallation
        )
      )
    }
    return snapshots
  }

  func fetchWorkspaces() async throws -> [WorkspaceSummary] {
    let activeProfile = try await controlPlane.activeGatewayProfile()
    let grant = try await controlPlane.profileGrants().first { $0.id == activeProfile }
    return try await controlPlane.workspaces().map { workspace in
      var isDirectory = ObjCBool(false)
      let exists = FileManager.default.fileExists(
        atPath: workspace.rootPath,
        isDirectory: &isDirectory
      )
      let health: WorkspaceHealth
      if !exists || !isDirectory.boolValue {
        health = .missing
      } else if workspace.bookmarkIsStale {
        health = .bookmarkStale
      } else {
        health = .available
      }
      return WorkspaceSummary(
        id: workspace.id,
        displayName: workspace.displayName,
        path: workspace.rootPath,
        health: health,
        activeProfileID: activeProfile.rawValue,
        isEnabled: grant?.capabilityIDs.contains("*") == true
          || grant?.workspaceIDs.contains(workspace.id) == true,
        isSelected: grant?.workspaceIDs.contains(workspace.id) == true,
        lastResolvedAt: workspace.updatedAt
      )
    }
  }

  func fetchProfiles() async throws -> [ProfileSummary] {
    let activeProfile = try await controlPlane.activeGatewayProfile()
    return try await controlPlane.profileGrants().map { grant in
      ProfileSummary(
        id: grant.id.rawValue,
        displayName: grant.id.displayName,
        summary: grant.id.summary,
        isActive: grant.id == activeProfile,
        isEnabled: grant.id != .localAdmin,
        riskLevel: grant.id.riskLevel,
        permitsRemoteAccess: grant.allowedCallers.contains(where: \.isRemote),
        supportsFullShell: grant.id.supportsFullShell,
        fullShellEnabled: grant.fullShellEnabled
      )
    }
  }

  func fetchProviders() async throws -> [ProviderSummary] {
    try await providerSummaries(service: gatewayService.snapshot())
  }

  func fetchOpenAITunnels() async throws -> [OpenAITunnelSummary] {
    let snapshot = try await controlPlane.snapshot()
    let statusByID = Dictionary(
      uniqueKeysWithValues: snapshot.openAITunnelStatuses.map { ($0.profileID, $0) }
    )
    var summaries: [OpenAITunnelSummary] = []
    for profile in snapshot.openAITunnelConfigurations {
      let status =
        statusByID[profile.id]
        ?? OpenAITunnelStatus(profileID: profile.id, state: .stopped)
      summaries.append(
        OpenAITunnelSummary(
          id: profile.id,
          displayName: profile.tunnelClientProfile,
          profileID: profile.gatewayProfile.rawValue,
          state: status.state.appState,
          tunnelIdentifier: profile.tunnelID,
          endpoint: nil,
          connectedAt: status.startedAt,
          reconnectAttempt: reconnectAttempts[profile.id] ?? 0,
          lastError: status.lastError,
          tunnelClientPath: profile.tunnelClientPath,
          httpProxy: profile.httpProxy
        )
      )
    }
    return summaries
  }

  func fetchCloudflareTunnels() async throws -> [CloudflareTunnelSummary] {
    let profiles = try await controlPlane.cloudflareTunnelConfigurations()
    let statusByID = Dictionary(
      uniqueKeysWithValues: await controlPlane.cloudflareTunnelStatuses().map {
        ($0.profileID, $0)
      }
    )
    var summaries: [CloudflareTunnelSummary] = []
    for profile in profiles {
      let status = statusByID[profile.id]
      summaries.append(
        CloudflareTunnelSummary(
          id: profile.id,
          tunnelName: profile.tunnelName,
          publicHostname: profile.publicHostname,
          profileID: profile.gatewayProfile.rawValue,
          state: (status?.state ?? .stopped).appState,
          localPort: profile.localPort,
          metricsPort: profile.metricsPort,
          processIdentifier: status?.processID,
          connectedAt: status?.startedAt,
          lastError: status?.lastError
        ))
    }
    return summaries
  }

  func fetchPermissions() async throws -> [PermissionSummary] {
    let snapshot = await controlPlane.computerUsePermissions()
    let checkedAt = Date()
    return [
      PermissionSummary(
        id: "accessibility",
        displayName: "Accessibility",
        detail: "Required for pointer, keyboard, scroll, and Accessibility actions.",
        state: snapshot.accessibility.appState,
        settingsURL: URL(
          string:
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        ),
        checkedAt: checkedAt
      ),
      PermissionSummary(
        id: "screen-recording",
        displayName: "Screen Recording",
        detail: "Required for window observation and screenshots.",
        state: snapshot.screenRecording.appState,
        settingsURL: URL(
          string:
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        ),
        checkedAt: checkedAt
      ),
    ]
  }

  func requestPermission(id: String) async throws -> PermissionRequestOutcome {
    fileLogger.append(
      .info,
      event: "app.permission.requested",
      fields: ["permission_id": id]
    )
    let outcome = try permissionRequester.requestPermission(id: id)
    fileLogger.append(
      .info,
      event: "app.permission.request.completed",
      fields: [
        "permission_id": id,
        "state": outcome.state.rawValue,
      ]
    )
    return outcome
  }

  func fetchAudit() async throws -> [AuditEntrySummary] {
    let workspaces = Dictionary(
      uniqueKeysWithValues: try await controlPlane.workspaces().map { ($0.id, $0.displayName) }
    )
    return try await controlPlane.auditEvents().map { event in
      let summary: String
      if let errorCode = event.errorCode {
        summary = errorCode
      } else if let duration = event.durationMilliseconds {
        summary = AppLocalization.formatted("Completed in %@ ms", String(duration))
      } else {
        summary = AppLocalization.string("Capability decision recorded")
      }
      return AuditEntrySummary(
        id: event.id,
        requestID: event.requestID,
        timestamp: event.occurredAt,
        decision: event.decision.appDecision,
        caller: "\(event.caller.rawValue) / \(event.profileID.rawValue)",
        capability: event.capabilityID,
        workspaceName: event.workspaceID.flatMap { workspaces[$0] },
        summary: summary,
        inputDigest: event.inputDigest,
        outputByteCount: event.outputByteCount
      )
    }
  }

  func fetchDiagnostics() async throws -> DiagnosticsSnapshot {
    let service = await gatewayService.snapshot()
    let configuration = try await controlPlane.activeConfiguration()
    let snapshot = try await controlPlane.snapshot()
    let providers = try await providerSummaries(service: service)
    var items = [
      DiagnosticItem(
        id: "gateway",
        title: "Gateway",
        value: AppLocalization.string(service.state.rawValue.capitalized),
        detail: service.lastError,
        level: service.state == .failed ? .error : .information
      ),
      DiagnosticItem(
        id: "socket",
        title: "Local socket",
        value: service.socketPath,
        detail: AppLocalization.formatted(
          "%@ active connection(s)",
          String(service.connectionCount)
        ),
        level: .information
      ),
      DiagnosticItem(
        id: "manifest",
        title: "Manifest",
        value: configuration.server.name,
        detail: controlPlane.directories.manifest.path,
        level: .information
      ),
      DiagnosticItem(
        id: "database",
        title: "Database",
        value: AppLocalization.formatted(
          "%@ revision(s)",
          String(snapshot.configurationRevisionCount)
        ),
        detail: controlPlane.directories.database.path,
        level: .information
      ),
    ]
    items.append(
      contentsOf: providers.filter { $0.state == .failed }.map {
        DiagnosticItem(
          id: "provider:\($0.id)",
          title: $0.displayName,
          value: AppLocalization.string("Failed"),
          detail: $0.lastError ?? $0.lastDoctorMessage,
          level: .error
        )
      }
    )
    let manifestContent = try String(
      contentsOf: controlPlane.directories.manifest,
      encoding: .utf8
    )
    var foundCurrentRevision = false
    let revisions = try await controlPlane.configurationHistory().map { revision in
      let isCurrent =
        !foundCurrentRevision
        && revision.manifest == manifestContent
        && revision.activationError == nil
      if isCurrent {
        foundCurrentRevision = true
      }
      return ManifestRevisionSummary(
        id: revision.id,
        digest: revision.digest,
        createdAt: revision.createdAt,
        isCurrent: isCurrent,
        activationError: revision.activationError
      )
    }
    return DiagnosticsSnapshot(
      generatedAt: Date(),
      items: items,
      logDirectory: controlPlane.directories.logs.path,
      applicationSupportDirectory: controlPlane.directories.applicationSupport.path,
      manifest: ManifestSnapshot(
        path: controlPlane.directories.manifest.path,
        content: manifestContent,
        revisions: revisions
      )
    )
  }

  func startGateway() async throws {
    fileLogger.append(.info, event: "gateway.start.requested")
    try await controlPlane.setGatewayDesiredRunning(true)
    try await gatewayService.start()
    fileLogger.append(.info, event: "gateway.start.completed")
  }

  func stopGateway() async throws {
    fileLogger.append(.info, event: "gateway.stop.requested")
    try await controlPlane.setGatewayDesiredRunning(false)
    await gatewayService.stop()
    fileLogger.append(.info, event: "gateway.stop.completed")
  }

  func setLaunchAtLoginEnabled(_ enabled: Bool) async throws {
    _ = try await controlPlane.setLaunchAtLoginEnabled(enabled)
  }

  func registerWorkspace(at url: URL) async throws {
    let workspace = try await controlPlane.registerWorkspace(at: url)
    fileLogger.append(
      .info,
      event: "workspace.registered",
      fields: ["workspace_id": workspace.id]
    )
    try await restartGatewayIfRunning()
  }

  func removeWorkspace(id: String) async throws {
    try await controlPlane.removeWorkspace(id: id)
    fileLogger.append(.info, event: "workspace.removed", fields: ["workspace_id": id])
    try await restartGatewayIfRunning()
  }

  func setWorkspaceEnabled(
    _ enabled: Bool,
    workspaceID: String,
    profileID: String
  ) async throws {
    guard let profile = GatewayProfileID(rawValue: profileID) else {
      throw AppControlPlaneError.unavailable(
        AppLocalization.formatted("Unknown gateway profile: %@", profileID)
      )
    }
    _ = try await controlPlane.setWorkspaceEnabled(
      enabled,
      workspaceID: workspaceID,
      profileID: profile
    )
    fileLogger.append(
      .info,
      event: enabled ? "workspace.granted" : "workspace.revoked",
      fields: [
        "profile_id": profileID,
        "workspace_id": workspaceID,
      ]
    )
    let service = await gatewayService.snapshot()
    if service.state == .running, service.profileID == profile {
      try await restartGatewayIfRunning(profile: profile)
    }
  }

  func activateProfile(id: String) async throws {
    guard let profile = GatewayProfileID(rawValue: id) else {
      throw AppControlPlaneError.unavailable(
        AppLocalization.formatted("Unknown gateway profile: %@", id)
      )
    }
    let previousProfile = try await controlPlane.activeGatewayProfile()
    try await validateDesiredTunnelProfileAlignment(with: profile)
    try await controlPlane.setActiveGatewayProfile(profile)
    do {
      if await gatewayService.snapshot().state == .running {
        try await restartGatewayIfRunning(profile: profile)
      }
    } catch {
      try? await controlPlane.setActiveGatewayProfile(previousProfile)
      if await gatewayService.snapshot().state == .running {
        try? await gatewayService.restart(profile: previousProfile)
      }
      throw error
    }
    fileLogger.append(
      .info,
      event: "profile.activated",
      fields: ["profile_id": profile.rawValue]
    )
  }

  func setFullShellEnabled(_ enabled: Bool, profileID: String) async throws {
    guard let profile = GatewayProfileID(rawValue: profileID) else {
      throw AppControlPlaneError.unavailable(
        AppLocalization.formatted("Unknown gateway profile: %@", profileID)
      )
    }
    _ = try await controlPlane.setFullShellEnabled(enabled, profileID: profile)
    fileLogger.append(
      .warning,
      event: enabled ? "profile.full_shell.enabled" : "profile.full_shell.disabled",
      fields: ["profile_id": profile.rawValue]
    )
    let service = await gatewayService.snapshot()
    if service.state == .running, service.profileID == profile {
      try await restartGatewayIfRunning(profile: profile)
    }
  }

  func startProvider(id: String) async throws {
    throw AppControlPlaneError.unavailable(
      AppLocalization.formatted(
        "Provider '%@' is configuration-driven and starts on demand with the gateway.",
        id
      )
    )
  }

  func stopProvider(id: String) async throws {
    throw AppControlPlaneError.unavailable(
      AppLocalization.formatted(
        "Provider '%@' is configuration-driven. Disable it in the active manifest.",
        id
      )
    )
  }

  func doctorProvider(id: String) async throws {
    let states = try await controlPlane.refreshProviders()
    guard states.contains(where: { $0.id == id }) else {
      throw AppControlPlaneError.unavailable(
        AppLocalization.formatted("Provider '%@' has no independent doctor contract.", id)
      )
    }
  }

  func startOpenAITunnel(id: String) async throws {
    fileLogger.append(.info, event: "tunnel.start.requested", fields: ["profile_id": id])
    let profile = try await appOpenAITunnelConfiguration(id: id)
    try await ensureGateway(for: profile)
    _ = try await controlPlane.startOpenAITunnel(profileID: id)
    fileLogger.append(.info, event: "tunnel.start.completed", fields: ["profile_id": id])
  }

  func reconnectOpenAITunnel(id: String) async throws {
    let profile = try await appOpenAITunnelConfiguration(id: id)
    try await ensureGateway(for: profile)
    _ = try await controlPlane.reconnectOpenAITunnel(profileID: id)
    reconnectAttempts[id] = 0
    nextReconnectAt[id] = nil
  }

  func stopOpenAITunnel(id: String) async throws {
    _ = try await controlPlane.stopOpenAITunnel(profileID: id)
    fileLogger.append(.info, event: "tunnel.stop.completed", fields: ["profile_id": id])
  }

  func fetchOpenAITunnelLogs(id: String) async throws -> OpenAITunnelLogSnapshot {
    let page = try await controlPlane.openAITunnelLogs(profileID: id)
    return OpenAITunnelLogSnapshot(
      profileID: id,
      state: page.status.state.appState,
      stdout: page.stdout.text ?? "",
      stderr: page.stderr.text ?? ""
    )
  }

  func doctorOpenAITunnel(id: String) async throws {
    _ = try await appOpenAITunnelConfiguration(id: id)
    let report = try await controlPlane.doctorOpenAITunnel(profileID: id)
    guard report.passed else {
      let detail =
        [report.stderr, report.stdout]
        .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        ?? "Tunnel diagnostics failed."
      throw AppControlPlaneError.unavailable(detail)
    }
  }

  func provisionOpenAITunnel(id: String) async throws {
    _ = try await appOpenAITunnelConfiguration(id: id)
    let report = try await controlPlane.provisionOpenAITunnel(profileID: id, force: true)
    guard report.passed else {
      let detail =
        [report.stderr, report.stdout]
        .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        ?? "Tunnel provisioning failed."
      throw AppControlPlaneError.unavailable(detail)
    }
  }

  func saveOpenAITunnelConfiguration(_ draft: OpenAITunnelConfigurationDraft) async throws {
    let id = try Self.requiredField(draft.id, label: "Profile ID")
    let tunnelClientProfile = try Self.requiredField(
      draft.tunnelClientProfile,
      label: "Tunnel client profile"
    )
    let tunnelID = try Self.requiredField(draft.tunnelID, label: "Tunnel ID")
    guard let gatewayProfile = GatewayProfileID(rawValue: draft.gatewayProfileID),
      gatewayProfile != .localAdmin
    else {
      throw AppControlPlaneError.unavailable(
        "Tunnel gateway profile must be chatgpt-observe or chatgpt-operate."
      )
    }

    let existing = try await controlPlane.openAITunnelConfigurations().first { $0.id == id }
    let secretReference: SecretReference
    if let existingReference = existing?.apiKeyReference {
      secretReference = existingReference
    } else {
      secretReference = try SecretReference(account: "tunnel.\(id).openai-api-key")
    }
    let apiKey = draft.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
    if (apiKey == nil || apiKey?.isEmpty == true) && existing == nil {
      throw AppControlPlaneError.unavailable(
        "An OpenAI API key is required when creating a Tunnel profile."
      )
    }

    let profile = OpenAITunnelConfiguration(
      id: id,
      tunnelClientProfile: tunnelClientProfile,
      tunnelID: tunnelID,
      gatewayProfile: gatewayProfile,
      manifestPath: controlPlane.directories.manifest.path,
      gatewayExecutablePath: try Self.embeddedGatewayExecutablePath(),
      gatewaySocketPath: controlPlane.directories.gatewaySocket.path,
      profileDirectory: controlPlane.directories.tunnelClientProfiles.path,
      tunnelClientPath: Self.optionalField(draft.tunnelClientPath),
      httpProxy: Self.optionalField(draft.httpProxy),
      apiKeyReference: secretReference
    )
    try profile.validate()
    let wasDesired = Set(try await controlPlane.desiredOpenAITunnelConfigurationIDs()).contains(id)
    if wasDesired {
      try await validateDesiredTunnelProfileAlignment(
        with: gatewayProfile,
        excludingTunnelID: id
      )
    }
    let keyCheckpoint = try await controlPlane.checkpointOpenAITunnelAPIKey(
      reference: secretReference
    )
    if existing != nil {
      _ = try await controlPlane.suspendOpenAITunnel(profileID: id)
    }
    do {
      try await controlPlane.saveOpenAITunnelConfiguration(profile)
      if let apiKey, !apiKey.isEmpty {
        try await controlPlane.setOpenAITunnelAPIKey(apiKey, reference: secretReference)
      }
      if wasDesired {
        try await ensureGateway(for: profile)
        _ = try await controlPlane.reconnectOpenAITunnel(profileID: id)
        reconnectAttempts[id] = 0
        nextReconnectAt[id] = nil
      }
    } catch {
      if let existing {
        try? await controlPlane.saveOpenAITunnelConfiguration(existing)
      } else {
        try? await controlPlane.deleteOpenAITunnelConfiguration(id: id)
      }
      try? await controlPlane.restoreOpenAITunnelAPIKey(keyCheckpoint)
      if wasDesired, let existing {
        try? await ensureGateway(for: existing)
        _ = try? await controlPlane.reconnectOpenAITunnel(profileID: id)
      }
      throw error
    }
  }

  func deleteOpenAITunnel(id: String) async throws {
    try await controlPlane.deleteOpenAITunnelConfiguration(id: id)
  }

  func startCloudflareTunnel(id: String) async throws {
    fileLogger.append(.info, event: "cloudflare.start.requested", fields: ["profile_id": id])
    _ = try await controlPlane.startCloudflareTunnel(profileID: id)
  }

  func stopCloudflareTunnel(id: String) async throws {
    _ = try await controlPlane.stopCloudflareTunnel(profileID: id)
    fileLogger.append(.info, event: "cloudflare.stop.completed", fields: ["profile_id": id])
  }

  func doctorCloudflareTunnel(id: String) async throws {
    let report = try await controlPlane.doctorCloudflareTunnel(profileID: id)
    guard report.passed else {
      throw AppControlPlaneError.unavailable(
        report.diagnostics.joined(separator: "\n")
      )
    }
  }

  func fetchCloudflareTunnelLogs(id: String) async throws -> CloudflareTunnelLogSnapshot {
    let logs = try await controlPlane.cloudflareTunnelLogs(profileID: id)
    return CloudflareTunnelLogSnapshot(
      profileID: id,
      stdout: logs.stdout,
      stderr: logs.stderr,
      truncated: logs.truncated
    )
  }

  func saveCloudflareTunnelConfiguration(
    _ draft: CloudflareTunnelConfigurationDraft
  ) async throws -> String? {
    let id = try Self.requiredField(draft.id, label: "Profile ID")
    let tunnelName = try Self.requiredField(draft.tunnelName, label: "Named tunnel")
    let publicHostname = try Self.requiredField(draft.publicHostname, label: "Public hostname")
    guard let gatewayProfile = GatewayProfileID(rawValue: draft.gatewayProfileID),
      gatewayProfile != .localAdmin
    else {
      throw AppControlPlaneError.unavailable("A remote Cloudflare gateway profile is required.")
    }
    let existing = try await controlPlane.cloudflareTunnelConfigurations().first { $0.id == id }
    let tunnelTokenReference =
      try existing?.tunnelTokenReference
      ?? SecretReference(account: "cloudflare.\(id).tunnel-token")
    let accessTokenReference =
      try existing?.accessTokenReference
      ?? SecretReference(account: "cloudflare.\(id).access-token")
    let token = draft.tunnelToken?.trimmingCharacters(in: .whitespacesAndNewlines)
    if existing == nil && (token == nil || token?.isEmpty == true) {
      throw AppControlPlaneError.unavailable(
        "A remotely managed named-tunnel token is required. Quick Tunnel and noauth are not supported."
      )
    }
    let normalizedCloudflaredPath = draft.cloudflaredPath?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines)
    let result = try await controlPlane.saveCloudflareTunnelConfiguration(
      CloudflareTunnelConfiguration(
        id: id,
        tunnelName: tunnelName,
        publicHostname: publicHostname,
        gatewayProfile: gatewayProfile,
        localPort: draft.localPort,
        metricsPort: draft.metricsPort,
        cloudflaredPath: normalizedCloudflaredPath?.isEmpty == true
          ? nil : normalizedCloudflaredPath,
        tunnelTokenReference: tunnelTokenReference,
        accessTokenReference: accessTokenReference
      ),
      tunnelToken: normalizedToken?.isEmpty == true ? nil : normalizedToken,
      regenerateAccessToken: draft.regenerateAccessToken
    )
    return result.generatedAccessToken
  }

  func deleteCloudflareTunnel(id: String) async throws {
    try await controlPlane.deleteCloudflareTunnelConfiguration(id: id)
  }

  func installCommandLineTool() async throws -> EmbeddedCLIInstallationStatus {
    try EmbeddedCLIInstaller().install(
      source: URL(fileURLWithPath: try Self.embeddedGatewayExecutablePath()),
      replaceInvalidLink: true
    )
  }

  func commandLineToolStatus() async throws -> EmbeddedCLIInstallationStatus {
    try EmbeddedCLIInstaller().status()
  }

  func localMCPConnection() async throws -> LocalMCPConnectionSummary {
    let installation = try EmbeddedCLIInstaller().status()
    let executable: String
    if installation.state == .installed {
      executable = installation.destination
    } else {
      executable = try Self.embeddedGatewayExecutablePath()
    }
    return LocalMCPConnectionSummary(
      command: executable,
      arguments: ["bridge", "--client-identity", "local-mcp"],
      cliInstallation: installation
    )
  }

  func previewCodexRegistration() async throws -> CodexMCPInstallInvocation {
    let connection = try await localMCPConnection()
    return try await Task.detached {
      try CodexMCPInstaller().planApp(
        codexCLI: nil,
        serverName: "computer-mcp",
        executablePath: connection.command
      )
    }.value
  }

  func installCodexRegistration() async throws -> CommandResult {
    let connection = try await localMCPConnection()
    let result = try await Task.detached {
      try CodexMCPInstaller().installApp(
        codexCLI: nil,
        serverName: "computer-mcp",
        executablePath: connection.command
      )
    }.value
    guard result.exitCode == 0 else {
      let message =
        [result.stderr, result.stdout]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
        ?? "Codex MCP registration exited without a diagnostic message."
      throw AppControlPlaneError.unavailable(message)
    }
    return result
  }

  func saveManifest(_ content: String) async throws {
    let previous = try String(
      contentsOf: controlPlane.directories.manifest,
      encoding: .utf8
    )
    _ = try await controlPlane.activateManifest(content)
    do {
      try await restartGatewayIfRunning()
    } catch {
      _ = try? await controlPlane.activateManifest(previous)
      try? await restartGatewayIfRunning()
      throw error
    }
  }

  func rollbackManifest(to revisionID: String) async throws {
    let previous = try String(
      contentsOf: controlPlane.directories.manifest,
      encoding: .utf8
    )
    _ = try await controlPlane.rollbackManifest(to: revisionID)
    do {
      try await restartGatewayIfRunning()
    } catch {
      _ = try? await controlPlane.activateManifest(previous)
      try? await restartGatewayIfRunning()
      throw error
    }
  }

  func exportDiagnostics(to destination: URL) async throws {
    let diagnostics = try await fetchDiagnostics()
    let audit = try await fetchAudit()
    let text = Self.diagnosticText(diagnostics: diagnostics, audit: audit)
    try await Task.detached {
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      defer { try? FileManager.default.removeItem(at: root) }
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try text.write(
        to: root.appendingPathComponent("diagnostics.txt"),
        atomically: true,
        encoding: .utf8
      )
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      let result = try ProcessCommandRunner().run(
        executable: "/usr/bin/ditto",
        arguments: ["-c", "-k", "--sequesterRsrc", root.path, destination.path],
        workingDirectory: nil,
        environment: [:],
        timeoutMilliseconds: 30_000,
        maxOutputBytes: 65_536
      )
      guard result.exitCode == 0, !result.timedOut else {
        throw AppControlPlaneError.unavailable(
          result.stderr.isEmpty ? "Could not create diagnostics archive." : result.stderr
        )
      }
    }.value
  }

  private func restartGatewayIfRunning(
    profile requestedProfile: GatewayProfileID? = nil
  ) async throws {
    let snapshot = await gatewayService.snapshot()
    if snapshot.state == .running {
      let profile = requestedProfile ?? snapshot.profileID
      if let profile {
        try await validateDesiredTunnelProfileAlignment(with: profile)
      }
      let desiredProfiles = try await desiredOpenAITunnelConfigurations()
      try await gatewayService.restart(profile: profile)
      await reconnectDesiredOpenAITunnels(desiredProfiles)
    }
  }

  private func validateDesiredTunnelProfileAlignment(
    with profile: GatewayProfileID,
    excludingTunnelID: String? = nil
  ) async throws {
    if let conflicting = try await desiredOpenAITunnelConfigurations().first(where: {
      $0.id != excludingTunnelID && $0.gatewayProfile != profile
    }) {
      throw AppControlPlaneError.unavailable(
        AppLocalization.formatted(
          "Tunnel '%@' is configured to stay running with profile %@. Stop it before activating %@.",
          conflicting.id,
          conflicting.gatewayProfile.rawValue,
          profile.rawValue
        )
      )
    }
  }

  private func reconnectDesiredOpenAITunnels(
    _ profiles: [OpenAITunnelConfiguration]
  ) async {
    for profile in profiles {
      do {
        _ = try await controlPlane.reconnectOpenAITunnel(
          profileID: profile.id,
          allowKeychainAuthenticationUI: false
        )
        reconnectAttempts[profile.id] = 0
        nextReconnectAt[profile.id] = nil
      } catch {
        reconnectAttempts[profile.id] = 1
        nextReconnectAt[profile.id] = Date().addingTimeInterval(2)
        fileLogger.append(
          .warning,
          event: "tunnel.reconnect.deferred",
          fields: ["profile_id": profile.id]
        )
      }
    }
  }

  private func appOpenAITunnelConfiguration(id: String) async throws -> OpenAITunnelConfiguration {
    guard
      let profile = try await controlPlane.openAITunnelConfigurations().first(where: { $0.id == id }
      )
    else {
      throw AppControlPlaneError.unavailable(
        AppLocalization.formatted("Unknown Tunnel profile: %@", id)
      )
    }
    return profile
  }

  private func ensureGateway(for profile: OpenAITunnelConfiguration) async throws {
    let runningTunnels = try await controlPlane.snapshot().openAITunnelStatuses.filter {
      $0.profileID != profile.id && $0.state == .running
    }
    if !runningTunnels.isEmpty {
      let profiles = try await controlPlane.openAITunnelConfigurations()
      let conflicting = runningTunnels.compactMap { status in
        profiles.first { $0.id == status.profileID }
      }.first { $0.gatewayProfile != profile.gatewayProfile }
      if let conflicting {
        throw AppControlPlaneError.unavailable(
          AppLocalization.formatted(
            "Tunnel '%@' is already running with profile %@. Stop it before starting %@.",
            conflicting.id,
            conflicting.gatewayProfile.rawValue,
            profile.gatewayProfile.rawValue
          )
        )
      }
    }

    let previousDesiredRunning = try await controlPlane.gatewayDesiredRunning()
    let previousProfile = try await controlPlane.activeGatewayProfile()
    let service = await gatewayService.snapshot()
    try await controlPlane.setGatewayDesiredRunning(true)
    do {
      try await controlPlane.setActiveGatewayProfile(profile.gatewayProfile)
      if service.state == .running {
        if service.profileID != profile.gatewayProfile {
          try await gatewayService.restart(profile: profile.gatewayProfile)
        }
      } else {
        try await gatewayService.start(profile: profile.gatewayProfile)
      }
    } catch {
      try? await controlPlane.setActiveGatewayProfile(previousProfile)
      try? await controlPlane.setGatewayDesiredRunning(previousDesiredRunning)
      if service.state == .running {
        try? await gatewayService.restart(profile: previousProfile)
      } else {
        await gatewayService.stop()
      }
      throw error
    }
  }

  private func restoreRuntime() async throws {
    let desiredProfiles = try await restoreGatewayRuntime()
    try await restoreDesiredOpenAITunnels(profiles: desiredProfiles)
    try await restoreDesiredCloudflareTunnels()
  }

  private func restoreGatewayRuntime() async throws -> [OpenAITunnelConfiguration] {
    let desiredProfiles = try await desiredOpenAITunnelConfigurations()
    let gatewayProfiles = Set(desiredProfiles.map(\.gatewayProfile))
    guard gatewayProfiles.count <= 1 else {
      throw AppControlPlaneError.unavailable(
        "Saved Tunnel profiles require different gateway profiles. Start only compatible Tunnels."
      )
    }

    let selectedProfile: GatewayProfileID
    if let profile = gatewayProfiles.first {
      selectedProfile = profile
    } else {
      selectedProfile = try await controlPlane.activeGatewayProfile()
    }
    try await controlPlane.setActiveGatewayProfile(selectedProfile)
    try await gatewayService.start(profile: selectedProfile)
    return desiredProfiles
  }

  private func restoreTransportsAfterStartup(
    profiles: [OpenAITunnelConfiguration]
  ) {
    Task { [weak self] in
      guard let self else {
        return
      }
      do {
        try await restoreDesiredOpenAITunnels(profiles: profiles)
        try await restoreDesiredCloudflareTunnels()
      } catch {
        fileLogger.append(
          .warning,
          event: "app.transport_restore.failed",
          fields: ["error_type": String(describing: type(of: error))]
        )
      }
    }
  }

  private func restoreDesiredCloudflareTunnels() async throws {
    let desired = try await controlPlane.desiredCloudflareProfileIDs()
    let statusByID = Dictionary(
      uniqueKeysWithValues: await controlPlane.cloudflareTunnelStatuses().map {
        ($0.profileID, $0.state)
      }
    )
    for id in desired where statusByID[id] != .running && statusByID[id] != .starting {
      _ = try await controlPlane.startCloudflareTunnel(profileID: id)
    }
  }

  private func restoreDesiredOpenAITunnels(
    profiles suppliedProfiles: [OpenAITunnelConfiguration]? = nil
  ) async throws {
    let profiles: [OpenAITunnelConfiguration]
    if let suppliedProfiles {
      profiles = suppliedProfiles
    } else {
      profiles = try await desiredOpenAITunnelConfigurations()
    }
    let statuses = Dictionary(
      uniqueKeysWithValues: try await controlPlane.snapshot().openAITunnelStatuses.map {
        ($0.profileID, $0)
      }
    )
    for profile in profiles {
      if statuses[profile.id]?.state == .running || statuses[profile.id]?.state == .starting {
        reconnectAttempts[profile.id] = 0
        nextReconnectAt[profile.id] = nil
        continue
      }
      if let nextAttempt = nextReconnectAt[profile.id], nextAttempt > Date() {
        continue
      }
      let attempt = min((reconnectAttempts[profile.id] ?? 0) + 1, 10)
      fileLogger.append(
        .info,
        event: "tunnel.reconnect.requested",
        fields: [
          "attempt": String(attempt),
          "profile_id": profile.id,
        ]
      )
      do {
        try await ensureGateway(for: profile)
        _ = try await controlPlane.reconnectOpenAITunnel(
          profileID: profile.id,
          allowKeychainAuthenticationUI: false
        )
        reconnectAttempts[profile.id] = 0
        nextReconnectAt[profile.id] = nil
        fileLogger.append(
          .info,
          event: "tunnel.reconnect.completed",
          fields: ["profile_id": profile.id]
        )
      } catch {
        reconnectAttempts[profile.id] = attempt
        nextReconnectAt[profile.id] = Date().addingTimeInterval(
          Self.reconnectDelay(for: attempt)
        )
        fileLogger.append(
          .warning,
          event: "tunnel.reconnect.failed",
          fields: [
            "attempt": String(attempt),
            "error_type": String(describing: type(of: error)),
            "profile_id": profile.id,
          ]
        )
      }
    }
  }

  private func desiredOpenAITunnelConfigurations() async throws -> [OpenAITunnelConfiguration] {
    let desiredIDs = Set(try await controlPlane.desiredOpenAITunnelConfigurationIDs())
    var profiles: [OpenAITunnelConfiguration] = []
    for profile in try await controlPlane.openAITunnelConfigurations()
    where desiredIDs.contains(profile.id) {
      profiles.append(try await appOpenAITunnelConfiguration(id: profile.id))
    }
    return profiles.sorted { $0.id < $1.id }
  }

  private static func reconnectDelay(for attempt: Int) -> TimeInterval {
    min(pow(2, Double(max(0, attempt - 1))), 60)
  }

  private static func embeddedGatewayExecutablePath() throws -> String {
    var candidates: [URL] = []
    if let resourceURL = Bundle.main.resourceURL {
      candidates.append(resourceURL.appendingPathComponent("computer-mcp"))
    }
    if let executableURL = Bundle.main.executableURL {
      candidates.append(
        executableURL.deletingLastPathComponent().appendingPathComponent("computer-mcp")
      )
      candidates.append(
        executableURL
          .deletingLastPathComponent()
          .deletingLastPathComponent()
          .appendingPathComponent("Resources/computer-mcp")
      )
    }
    guard
      let executable = candidates.first(where: {
        FileManager.default.isExecutableFile(atPath: $0.path)
      })
    else {
      throw AppControlPlaneError.unavailable(
        "The embedded computer-mcp bridge executable is missing. Reinstall Computer MCP.app."
      )
    }
    return executable.standardizedFileURL.path
  }

  private static func requiredField(_ value: String, label: String) throws -> String {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, !normalized.contains("\0") else {
      throw AppControlPlaneError.unavailable(
        AppLocalization.formatted("%@ must not be empty.", AppLocalization.string(label))
      )
    }
    return normalized
  }

  private static func optionalField(_ value: String?) -> String? {
    let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return normalized.isEmpty ? nil : normalized
  }

  private func providerSummaries(
    service: AppGatewayServiceSnapshot
  ) async throws -> [ProviderSummary] {
    let configuration = try await controlPlane.activeConfiguration()
    let inProcessState: ServiceState = service.state == .running ? .running : .stopped
    var summaries: [ProviderSummary] = []

    if !configuration.builtin.enabled.isEmpty {
      summaries.append(
        ProviderSummary(
          id: "builtin",
          displayName: "Built-in Tools",
          kind: .builtin,
          state: inProcessState,
          version: ComputerMCPCLI.version,
          executablePath: nil,
          toolCount: configuration.builtin.enabled.count,
          lastDoctorMessage: "Hosted in the gateway process.",
          lastError: nil,
          lifecycleManaged: false
        )
      )
    }
    if configuration.skills.enabled {
      summaries.append(
        ProviderSummary(
          id: "skills",
          displayName: "Skills",
          kind: .builtin,
          state: inProcessState,
          version: nil,
          executablePath: nil,
          toolCount: 6,
          lastDoctorMessage: AppLocalization.formatted(
            "%@ registered root(s)",
            String(configuration.skills.roots.count)
          ),
          lastError: nil,
          lifecycleManaged: false
        )
      )
    }
    for command in configuration.cli.commands {
      summaries.append(
        ProviderSummary(
          id: "cli:\(command.id)",
          displayName: command.id,
          kind: .cli,
          state: inProcessState,
          version: nil,
          executablePath: command.executable,
          toolCount: nil,
          lastDoctorMessage: "Executed on demand through cli.exec.",
          lastError: nil,
          lifecycleManaged: false
        )
      )
    }
    for server in configuration.mcp.servers {
      summaries.append(
        ProviderSummary(
          id: "mcp:\(server.id)",
          displayName: server.id,
          kind: .mcp,
          state: inProcessState,
          version: nil,
          executablePath: server.command ?? server.url,
          toolCount: nil,
          lastDoctorMessage: "Connected on demand through the MCP proxy.",
          lastError: nil,
          lifecycleManaged: false
        )
      )
    }
    if configuration.codex.enabled {
      summaries.append(
        ProviderSummary(
          id: "codex",
          displayName: "Codex",
          kind: .codex,
          state: inProcessState,
          version: nil,
          executablePath: configuration.codex.executable,
          toolCount: nil,
          lastDoctorMessage: "App Server, Exec, and MCP paths are independently isolated.",
          lastError: nil,
          lifecycleManaged: false
        )
      )
    }
    summaries.append(
      ProviderSummary(
        id: "computer-use",
        displayName: "Computer Use",
        kind: .computerUse,
        state: inProcessState,
        version: nil,
        executablePath: nil,
        toolCount: 12,
        lastDoctorMessage: "TCC permissions are checked without prompting.",
        lastError: nil,
        lifecycleManaged: false
      )
    )

    for provider in try await controlPlane.providerStates() {
      if provider.id == "codex",
        let index = summaries.firstIndex(where: { $0.id == "codex" })
      {
        summaries[index].state = provider.health.appState
        summaries[index].version = provider.observedVersion
        summaries[index].executablePath = provider.executablePath
        summaries[index].lastDoctorMessage = provider.detail
        summaries[index].lastError = provider.health == "failed" ? provider.detail : nil
        continue
      }
      summaries.append(
        ProviderSummary(
          id: provider.id,
          displayName: provider.id,
          kind: .external,
          state: provider.health.appState,
          version: provider.observedVersion,
          executablePath: provider.executablePath,
          toolCount: nil,
          lastDoctorMessage: provider.detail,
          lastError: provider.health == "failed" ? provider.detail : nil,
          lifecycleManaged: false
        )
      )
    }
    return summaries.sorted {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
  }

  private static func diagnosticText(
    diagnostics: DiagnosticsSnapshot,
    audit: [AuditEntrySummary]
  ) -> String {
    var lines = [
      "Computer MCP Diagnostics",
      "Generated: \(diagnostics.generatedAt)",
      "Application Support: \(diagnostics.applicationSupportDirectory)",
      "Logs: \(diagnostics.logDirectory)",
      "",
      "Checks:",
    ]
    lines.append(
      contentsOf: diagnostics.items.map {
        "- [\($0.level)] \($0.title): \($0.value)"
          + ($0.detail.map { " (\($0))" } ?? "")
      }
    )
    lines.append("")
    lines.append("Recent redacted audit:")
    lines.append(
      contentsOf: audit.prefix(200).map {
        "- \($0.timestamp) [\($0.decision.rawValue)] \($0.capability) \($0.summary)"
      }
    )
    return lines.joined(separator: "\n") + "\n"
  }
}

extension AppGatewayServiceState {
  fileprivate var appState: ServiceState {
    switch self {
    case .stopped: .stopped
    case .starting: .starting
    case .running: .running
    case .stopping: .stopping
    case .failed: .failed
    }
  }
}

extension LaunchAtLoginState {
  fileprivate var appState: LoginItemState {
    switch self {
    case .disabled: .disabled
    case .enabled: .enabled
    case .requiresApproval: .requiresApproval
    case .unavailable: .unavailable
    }
  }
}

extension GatewayProfileID {
  fileprivate var displayName: String {
    if self == .chatGPTObserve { return "ChatGPT Observe" }
    if self == .chatGPTOperate { return "ChatGPT Operate" }
    if self == .cloudflareObserve { return "Cloudflare Observe" }
    if self == .cloudflareOperate { return "Cloudflare Operate" }
    if self == .localAdmin { return "Local Admin" }
    return rawValue
  }

  fileprivate var summary: String {
    if self == .chatGPTObserve || self == .cloudflareObserve {
      return "Read-only observation, Skills, system state, and workspace inspection."
    }
    if self == .chatGPTOperate || self == .cloudflareOperate {
      return "Locally enabled workspace writes, Codex, and reviewed providers."
    }
    if self == .localAdmin {
      return "Local App and CLI administration. Never exposed through a Tunnel."
    }
    return "Custom manifest-defined profile."
  }

  fileprivate var riskLevel: RiskLevel {
    if self == .chatGPTObserve || self == .cloudflareObserve { return .low }
    if self == .localAdmin { return .high }
    return .elevated
  }
}

extension OpenAITunnelLifecycleState {
  fileprivate var appState: ServiceState {
    switch self {
    case .stopped: .stopped
    case .starting: .starting
    case .running: .running
    case .stopping: .stopping
    case .failed: .failed
    }
  }
}

extension CloudflareTunnelLifecycleState {
  fileprivate var appState: ServiceState {
    switch self {
    case .stopped: .stopped
    case .starting: .starting
    case .running: .running
    case .stopping: .stopping
    case .failed: .failed
    }
  }
}

extension ComputerUsePermissionStatus {
  fileprivate var appState: PermissionState {
    switch self {
    case .granted: .granted
    case .notGranted: .notGranted
    }
  }
}

extension ComputerMCP.AuditDecision {
  fileprivate var appDecision: AuditDecision {
    switch self {
    case .allowed: .allowed
    case .denied: .denied
    case .failed: .failed
    }
  }
}

extension String {
  fileprivate var appState: ServiceState {
    switch self {
    case "ready": .running
    case "failed": .failed
    case "unavailable": .stopped
    default: .degraded
    }
  }
}
