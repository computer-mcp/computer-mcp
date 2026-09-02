import Foundation
import MCP

internal protocol ControlPlaneProviderDiscovering: Sendable {
  func discover(configuration: GatewayConfiguration) throws -> [ExternalProviderDiscoveryResult]
}

internal struct AppControlPlaneProviderDiscovery: ControlPlaneProviderDiscovering {
  private let commandRunner: any CommandRunning

  internal init(commandRunner: any CommandRunning = ProcessCommandRunner()) {
    self.commandRunner = commandRunner
  }

  internal func discover(configuration: GatewayConfiguration) throws
    -> [ExternalProviderDiscoveryResult]
  {
    try ExternalProviderDiscovery(
      configuration: configuration,
      commandRunner: commandRunner
    ).discover()
  }
}

package struct AppControlPlaneServiceSnapshot: Codable, Equatable, Sendable {
  package var directories: AppControlPlaneServiceDirectories
  package var launchAtLogin: LaunchAtLoginState
  package var configurationRevisionCount: Int
  package var providerStates: [ProviderState]
  package var openAITunnelConfigurations: [OpenAITunnelConfiguration]
  package var openAITunnelStatuses: [OpenAITunnelStatus]
  package var cloudflareProfiles: [CloudflareTunnelConfiguration]
  package var cloudflareStatuses: [CloudflareTunnelStatus]

}

package actor AppControlPlaneService {
  package nonisolated let directories: AppControlPlaneServiceDirectories
  package nonisolated let openAITunnelGatewayExecutablePath: String

  let database: GatewayDatabase
  let manifestStore: AtomicManifestStore
  let secretStore: KeychainSecretStore
  private let openAITunnelSupervisor: OpenAITunnelSupervisor
  private let providerDiscovery: any ControlPlaneProviderDiscovering
  private let launchAtLoginController: any LaunchAtLoginControlling
  private let launchAtLoginOperations = BlockingOperationExecutor(
    label: "com.showxu.computer-mcp.launch-at-login",
    serial: false
  )
  let bookmarkService: any WorkspaceBookmarkServicing
  var cloudflareRuntimes: [String: CloudflareRuntimeState] = [:]
  private var cachedLaunchAtLoginState: LaunchAtLoginState = .unavailable
  private var launchAtLoginRefreshInProgress = false
  private var launchAtLoginGeneration: UInt64 = 0
  private var ownershipReconciliationTask: Task<Void, Never>?

  internal init(
    directories: AppControlPlaneServiceDirectories,
    database: GatewayDatabase,
    manifestStore: AtomicManifestStore,
    secretStore: KeychainSecretStore,
    openAITunnelSupervisor: OpenAITunnelSupervisor,
    openAITunnelGatewayExecutablePath: String = "computer-mcp",
    providerDiscovery: any ControlPlaneProviderDiscovering =
      AppControlPlaneProviderDiscovery(),
    launchAtLoginController: any LaunchAtLoginControlling =
      SMAppServiceLaunchAtLoginController(),
    bookmarkService: any WorkspaceBookmarkServicing = WorkspaceBookmarkService()
  ) {
    self.directories = directories
    self.openAITunnelGatewayExecutablePath = openAITunnelGatewayExecutablePath
    self.database = database
    self.manifestStore = manifestStore
    self.secretStore = secretStore
    self.openAITunnelSupervisor = openAITunnelSupervisor
    self.providerDiscovery = providerDiscovery
    self.launchAtLoginController = launchAtLoginController
    self.bookmarkService = bookmarkService
  }

  package static func live(
    directories: AppControlPlaneServiceDirectories? = nil,
    openAITunnelGatewayExecutablePath: String = "computer-mcp",
    keychainService: String,
    keychainAccessGroup: String
  ) throws -> AppControlPlaneService {
    let resolvedDirectories = try directories ?? .standard()
    try resolvedDirectories.prepare()
    let database = try GatewayDatabase(path: resolvedDirectories.database.path)
    try resolvedDirectories.secureDatabaseFiles()
    let manifestStore = try AtomicManifestStore(
      manifestURL: resolvedDirectories.manifest,
      database: database
    )
    let secretStore = try KeychainSecretStore(
      service: keychainService,
      accessGroup: keychainAccessGroup
    )
    let openAITunnelSupervisor = OpenAITunnelSupervisor(secretStore: secretStore)
    if !FileManager.default.fileExists(atPath: resolvedDirectories.manifest.path) {
      _ = try manifestStore.activate(manifest: defaultManifest)
    }
    return AppControlPlaneService(
      directories: resolvedDirectories,
      database: database,
      manifestStore: manifestStore,
      secretStore: secretStore,
      openAITunnelSupervisor: openAITunnelSupervisor,
      openAITunnelGatewayExecutablePath: openAITunnelGatewayExecutablePath
    )
  }

  package static let defaultManifest = DefaultGatewayConfiguration.manifest

  package func start() throws {
    try directories.prepare()
    try directories.secureDatabaseFiles()
    try manifestStore.startHotReloadMonitoring()
    _ = try CodexThreadOwnershipReconciliation.reconcileSafely(database: database)
    if ownershipReconciliationTask == nil {
      let database = database
      ownershipReconciliationTask = Task {
        while !Task.isCancelled {
          do {
            try await Task.sleep(for: .seconds(60))
          } catch {
            return
          }
          _ = try? CodexThreadOwnershipReconciliation.reconcileSafely(database: database)
        }
      }
    }
  }

  package func stop() async throws {
    ownershipReconciliationTask?.cancel()
    ownershipReconciliationTask = nil
    manifestStore.stopHotReloadMonitoring()
    for profileID in cloudflareRuntimes.keys.sorted() {
      _ = try? await stopCloudflareTunnel(profileID: profileID)
    }
    for status in await openAITunnelSupervisor.statusesSnapshot()
    where status.state == .running || status.state == .starting {
      _ = try await openAITunnelSupervisor.stop(profileID: status.profileID)
    }
  }

  package func snapshot() async throws -> AppControlPlaneServiceSnapshot {
    scheduleLaunchAtLoginRefreshIfNeeded()
    return AppControlPlaneServiceSnapshot(
      directories: directories,
      launchAtLogin: cachedLaunchAtLoginState,
      configurationRevisionCount: try database.configurationRevisions(limit: 1_000).count,
      providerStates: try database.providerStates(),
      openAITunnelConfigurations: try openAITunnelConfigurations(),
      openAITunnelStatuses: await openAITunnelSupervisor.statusesSnapshot(),
      cloudflareProfiles: try cloudflareTunnelConfigurations(),
      cloudflareStatuses: cloudflareTunnelStatuses()
    )
  }

  internal func manifestChanges() -> AsyncStream<ManifestChange> {
    manifestStore.changes()
  }

  @discardableResult
  package func activateManifest(_ manifest: String) throws -> ConfigurationRevision {
    try manifestStore.activate(manifest: manifest)
  }

  package func activeConfiguration() throws -> GatewayConfiguration {
    try manifestStore.activeConfiguration()
  }

  package func effectiveConfigurationForExport() throws -> GatewayConfiguration {
    var configuration = try manifestStore.activeConfiguration()
    configuration.workspaces = try workspaces().map { workspace in
      WorkspaceManifestConfig(
        id: workspace.id,
        displayName: workspace.displayName,
        path: workspace.rootPath
      )
    }.sorted { $0.id < $1.id }
    configuration.profiles = try profileGrants().map { grant in
      ProfileGrantConfig(
        id: grant.id,
        capabilities: grant.capabilityIDs.sorted(),
        workspaces: grant.workspaceIDs.sorted(),
        allowedCallers: grant.allowedCallers.sorted { $0.rawValue < $1.rawValue },
        fullShellEnabled: grant.fullShellEnabled
      )
    }.sorted { $0.id.rawValue < $1.id.rawValue }
    try configuration.validate()
    return configuration
  }

  package func workspaces() throws -> [RegisteredWorkspace] {
    try database.workspaces()
  }

  @discardableResult
  package func registerWorkspace(
    at url: URL,
    displayName: String? = nil
  ) throws -> RegisteredWorkspace {
    let proposed = try bookmarkService.registerFolder(at: url, displayName: displayName)
    let registration = try database.registerWorkspaceIdempotently(proposed)
    if !registration.created,
      displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
      registration.workspace.displayName != proposed.displayName
    {
      throw AppControlPlaneServiceError.workspaceMetadataConflict(
        workspaceID: registration.workspace.id,
        existingDisplayName: registration.workspace.displayName,
        requestedDisplayName: proposed.displayName
      )
    }
    return registration.workspace
  }

  package func workspaceDeduplicationPlan() throws -> WorkspaceDeduplicationPlan {
    try database.workspaceDeduplicationPlan()
  }

  package func applyWorkspaceDeduplication(
    expectedPlanDigest: String,
    allowMetadataConflicts: Bool
  ) throws -> WorkspaceDeduplicationResult {
    try database.applyWorkspaceDeduplication(
      expectedPlanDigest: expectedPlanDigest,
      allowMetadataConflicts: allowMetadataConflicts
    )
  }

  package func removeWorkspace(id: String) throws {
    guard let workspace = try database.workspace(id: id) else {
      throw AppControlPlaneServiceError.unknownWorkspace(id)
    }
    let canonicalID = workspace.id
    try database.invalidateCodexElevationGrants(
      workspaceID: canonicalID,
      reason: "The registered workspace was removed."
    )
    for var profile in try database.profiles() where profile.workspaceIDs.contains(canonicalID) {
      profile.workspaceIDs.remove(canonicalID)
      try database.saveProfile(profile)
    }
    try database.deleteWorkspace(id: canonicalID)
  }

  package func profileGrants() throws -> [ProfileGrant] {
    let configuration = try manifestStore.activeConfiguration()
    let configuredProfileIDs = Set(configuration.profiles.map(\.id))
    let profileIDs = Array(
      Set(GatewayProfileID.builtIns + configuration.profiles.map(\.id))
    ).sorted { $0.rawValue < $1.rawValue }
    var grants = Dictionary(
      uniqueKeysWithValues: profileIDs.map {
        ($0, configuration.profileGrant(for: $0))
      }
    )
    let persistedProfiles = try database.profiles()
    if !configuredProfileIDs.contains(.chatGPTObserve) {
      let workspaces = try database.workspaces()
      let gateway = try GatewayRuntime(
        configuration: configuration,
        context: configuration.executionContext(
          caller: .secureTunnel,
          profileID: .chatGPTObserve
        ),
        registeredWorkspaces: workspaces,
        bookmarkService: bookmarkService
      )
      grants[.chatGPTObserve] = ProfileGrant(
        id: .chatGPTObserve,
        capabilityIDs: Set(try gateway.listTools().map(\.name)),
        workspaceIDs: Set(workspaces.map(\.id)),
        allowedCallers: [.secureTunnel]
      )
    }
    for (profileID, caller) in [
      (GatewayProfileID.cloudflareObserve, GatewayCallerKind.cloudflareTunnel)
    ] where !configuredProfileIDs.contains(profileID) {
      let workspaces = try database.workspaces()
      let gateway = try GatewayRuntime(
        configuration: configuration,
        context: configuration.executionContext(caller: caller, profileID: profileID),
        registeredWorkspaces: workspaces,
        bookmarkService: bookmarkService
      )
      grants[profileID] = ProfileGrant(
        id: profileID,
        capabilityIDs: Set(try gateway.listTools().map(\.name)),
        workspaceIDs: Set(workspaces.map(\.id)),
        allowedCallers: [caller]
      )
    }
    for persisted in persistedProfiles {
      guard let configured = grants[persisted.id] else {
        continue
      }
      grants[persisted.id] = configured.applyingPersistedRuntimeState(persisted)
    }
    return profileIDs.compactMap { grants[$0] }
  }

  @discardableResult
  package func setWorkspaceEnabled(
    _ enabled: Bool,
    workspaceID: String,
    profileID: GatewayProfileID
  ) throws -> ProfileGrant {
    guard try database.workspaces().contains(where: { $0.id == workspaceID }) else {
      throw AppControlPlaneServiceError.unknownWorkspace(workspaceID)
    }
    guard var grant = try profileGrants().first(where: { $0.id == profileID }) else {
      throw AppControlPlaneServiceError.unknownGatewayProfile(profileID.rawValue)
    }
    if enabled {
      grant.workspaceIDs.insert(workspaceID)
    } else {
      grant.workspaceIDs.remove(workspaceID)
      try database.invalidateCodexElevationGrants(
        workspaceID: workspaceID,
        profileID: profileID.rawValue,
        reason: "The workspace was disabled for this profile."
      )
    }
    try grant.validate()
    try database.saveProfile(grant)
    return grant
  }

  package func activeGatewayProfile() throws -> GatewayProfileID {
    guard
      let rawValue = try database.runtimeSetting(key: Self.activeProfileSettingKey)
    else {
      return .chatGPTObserve
    }
    guard let profile = GatewayProfileID(rawValue: rawValue) else {
      throw AppControlPlaneServiceError.invalidStoredProfile(rawValue)
    }
    return profile
  }

  package func setActiveGatewayProfile(_ profile: GatewayProfileID) throws {
    guard profile != .localAdmin else {
      throw AppControlPlaneServiceError.localAdminCannotBeSocketProfile
    }
    guard try profileGrants().contains(where: { $0.id == profile }) else {
      throw AppControlPlaneServiceError.unknownGatewayProfile(profile.rawValue)
    }
    let previous = try activeGatewayProfile()
    if previous != profile {
      try database.invalidateCodexElevationGrants(
        profileID: previous.rawValue,
        reason: "The active gateway profile changed."
      )
    }
    try database.saveRuntimeSetting(
      key: Self.activeProfileSettingKey,
      value: profile.rawValue
    )
  }

  package func gatewayDesiredRunning() throws -> Bool {
    guard let value = try database.runtimeSetting(key: Self.gatewayDesiredRunningSettingKey) else {
      return true
    }
    return value == "true"
  }

  package func setGatewayDesiredRunning(_ desiredRunning: Bool) throws {
    try database.saveRuntimeSetting(
      key: Self.gatewayDesiredRunningSettingKey,
      value: desiredRunning ? "true" : "false"
    )
  }

  @discardableResult
  package func setFullShellEnabled(
    _ enabled: Bool,
    profileID: GatewayProfileID
  ) throws -> ProfileGrant {
    guard profileID.supportsFullShell else {
      throw AppControlPlaneServiceError.fullShellProfileNotAllowed(profileID.rawValue)
    }
    let configuration = try manifestStore.activeConfiguration()
    if enabled && !configuration.policy.shellEnabled {
      throw AppControlPlaneServiceError.fullShellManifestDisabled
    }
    guard var grant = try profileGrants().first(where: { $0.id == profileID }) else {
      throw AppControlPlaneServiceError.unknownGatewayProfile(profileID.rawValue)
    }
    grant.fullShellEnabled = enabled
    if enabled {
      grant.capabilityIDs.formUnion(ProfileGrant.fullShellCapabilities)
    }
    try grant.validate()
    try database.saveProfile(grant)
    return grant
  }

  package func auditEvents(limit: Int = 200) throws -> [AuditEvent] {
    try database.auditEvents(limit: limit)
  }

  func recordControlAudit(_ event: AuditEvent) throws {
    try database.recordAudit(event)
  }

  package func correlateMCPResponse(
    _ data: Data,
    identity: GatewaySocketConnectionIdentity
  ) throws {
    guard
      let correlation = GatewaySocketMCPResponseCorrelation.parse(data)
    else {
      return
    }
    _ = try database.bindMCPRequestID(
      correlation.mcpRequestID,
      toGatewayRequestID: correlation.gatewayRequestID,
      socketConnectionID: identity.connectionID
    )
  }

  package func computerUsePermissions() -> ComputerUsePermissionSnapshot {
    ComputerUseService().permissionSnapshot()
  }

  package func makeGatewaySocketSession(
    caller: GatewayCallerKind,
    profileID: GatewayProfileID,
    transportTrace: GatewayTransportTrace? = nil
  ) async throws -> GatewaySocketServerSession {
    if caller.isRemote && profileID == .localAdmin {
      throw AppControlPlaneServiceError.localAdminCannotBeSocketProfile
    }
    let configuration = try manifestStore.activeConfiguration()
    let gateway = try GatewayRuntime(
      configuration: configuration,
      context: configuration.executionContext(
        caller: caller,
        profileID: profileID,
        transportTrace: transportTrace
      ),
      database: database,
      registeredWorkspaces: try database.workspaces(),
      bookmarkService: bookmarkService
    )
    let server = await MCPRuntimeAdapter.makeGatewayServer(
      configuration: configuration,
      registry: gateway
    )
    return GatewaySocketServerSession(server: server) {
      await gateway.shutdown()
    }
  }

  func localAdminTools(
    transportTrace: GatewayTransportTrace
  ) throws -> [MCPTool] {
    try makeLocalAdminGateway(transportTrace: transportTrace).listTools()
  }

  func callLocalAdminTool(
    name: String,
    arguments: JSONValue?,
    transportTrace: GatewayTransportTrace
  ) async throws -> JSONValue {
    let gateway = try makeLocalAdminGateway(transportTrace: transportTrace)
    do {
      let result = try await gateway.callToolForMCPAsync(name: name, arguments: arguments)
      await gateway.shutdown()
      return result
    } catch {
      await gateway.shutdown()
      throw error
    }
  }

  private func makeLocalAdminGateway(
    transportTrace: GatewayTransportTrace
  ) throws -> GatewayRuntime {
    let configuration = try manifestStore.activeConfiguration()
    return try GatewayRuntime(
      configuration: configuration,
      context: configuration.executionContext(
        caller: .localCLI,
        profileID: .localAdmin,
        transportTrace: transportTrace
      ),
      database: database,
      registeredWorkspaces: try database.workspaces(),
      bookmarkService: bookmarkService
    )
  }

  package func configurationHistory(limit: Int = 50) throws -> [ConfigurationRevision] {
    try manifestStore.history(limit: limit)
  }

  @discardableResult
  package func rollbackManifest(to revisionID: String) throws -> ConfigurationRevision {
    try manifestStore.rollback(to: revisionID)
  }

  @discardableResult
  package func refreshProviders() throws -> [ProviderState] {
    let configuration = try manifestStore.activeConfiguration()
    let states = try providerDiscovery.discover(configuration: configuration).map {
      ProviderState(
        id: $0.providerID,
        kind: $0.kind.rawValue,
        executablePath: $0.resolvedPath,
        observedVersion: $0.version,
        health: Self.health(for: $0.doctorStatus.state),
        detail: Self.providerDetail($0),
        checkedAt: Date()
      )
    }
    for state in states {
      try database.saveProviderState(state)
    }
    return states.sorted { $0.id < $1.id }
  }

  package func providerStates() throws -> [ProviderState] {
    try database.providerStates()
  }

  package func providerCount() throws -> Int {
    let configuration = try manifestStore.activeConfiguration()
    var identifiers: Set<String> = ["computer-use"]
    if !configuration.builtin.enabled.isEmpty {
      identifiers.insert("builtin")
    }
    if configuration.skills.enabled {
      identifiers.insert("skills")
    }
    identifiers.formUnion(configuration.cli.commands.map { "cli:\($0.id)" })
    identifiers.formUnion(configuration.mcp.servers.map { "mcp:\($0.id)" })
    if configuration.codex.enabled {
      identifiers.insert("codex")
    }
    identifiers.formUnion(try database.providerStates().map(\.id))
    return identifiers.count
  }

  package func openAITunnelConfigurations() throws -> [OpenAITunnelConfiguration] {
    let configured = try manifestStore.activeConfiguration().transports.openAI
    return try configured.map { definition in
      let apiKeyReference =
        definition.requiresAPIKey
        ? try SecretReference(account: "tunnel.\(definition.id).openai-api-key") : nil
      return OpenAITunnelConfiguration(
        id: definition.id,
        tunnelClientProfile: definition.tunnelClientProfile,
        tunnelID: definition.tunnelID,
        gatewayProfile: definition.gatewayProfile,
        manifestPath: directories.manifest.path,
        gatewayExecutablePath: openAITunnelGatewayExecutablePath,
        gatewaySocketPath: directories.gatewaySocket.path,
        profileDirectory: definition.profileDirectory ?? directories.tunnelClientProfiles.path,
        tunnelClientPath: definition.tunnelClientPath,
        httpProxy: definition.httpProxy,
        apiKeyReference: apiKeyReference
      )
    }.sorted { $0.id < $1.id }
  }

  package func saveOpenAITunnelConfiguration(_ profile: OpenAITunnelConfiguration) throws {
    try profile.validate()
    var configuration = try manifestStore.activeConfiguration()
    configuration.transports.openAI.removeAll { $0.id == profile.id }
    configuration.transports.openAI.append(
      OpenAITunnelTransportConfig(
        id: profile.id,
        tunnelClientProfile: profile.tunnelClientProfile,
        tunnelID: profile.tunnelID,
        gatewayProfile: profile.gatewayProfile,
        profileDirectory: profile.profileDirectory == directories.tunnelClientProfiles.path
          ? nil : profile.profileDirectory,
        tunnelClientPath: profile.tunnelClientPath,
        httpProxy: profile.httpProxy,
        requiresAPIKey: profile.apiKeyReference != nil
      )
    )
    configuration.transports.openAI.sort { $0.id < $1.id }
    try activateTransportConfiguration(configuration)
  }

  package func deleteOpenAITunnelConfiguration(id: String) async throws {
    _ = try requireOpenAITunnelConfiguration(id)
    _ = try await openAITunnelSupervisor.stop(profileID: id)
    try setOpenAITunnelDesiredRunning(false, profileID: id)
    var configuration = try manifestStore.activeConfiguration()
    configuration.transports.openAI.removeAll { $0.id == id }
    try activateTransportConfiguration(configuration)
    try await deleteKeychainSecret(
      SecretReference(account: "tunnel.\(id).openai-api-key")
    )
  }

  package func setOpenAITunnelAPIKey(_ value: String, reference: SecretReference) async throws {
    try await setKeychainSecret(value, for: reference)
  }

  package func checkpointOpenAITunnelAPIKey(
    reference: SecretReference
  ) async throws -> OpenAITunnelAPIKeyCheckpoint {
    OpenAITunnelAPIKeyCheckpoint(
      reference: reference,
      value: try await keychainSecretValue(for: reference)
    )
  }

  package func restoreOpenAITunnelAPIKey(
    _ checkpoint: OpenAITunnelAPIKeyCheckpoint
  ) async throws {
    if let value = checkpoint.value {
      try await setKeychainSecret(value, for: checkpoint.reference)
    } else {
      try await deleteKeychainSecret(checkpoint.reference)
    }
  }

  package func hasOpenAITunnelAPIKey(reference: SecretReference) async throws -> Bool {
    try await keychainContainsSecret(reference)
  }

  package func deleteOpenAITunnelAPIKey(reference: SecretReference) async throws {
    try await deleteKeychainSecret(reference)
  }

  package func provisionOpenAITunnel(profileID: String, force: Bool = false) async throws
    -> OpenAITunnelDoctorReport
  {
    let profile = try requireOpenAITunnelConfiguration(profileID)
    try validateOpenAITunnelSurface(profile)
    return try await openAITunnelSupervisor.provision(
      profile,
      configuration: manifestStore.activeConfiguration(),
      force: force
    )
  }

  package func doctorOpenAITunnel(profileID: String) async throws -> OpenAITunnelDoctorReport {
    let profile = try requireOpenAITunnelConfiguration(profileID)
    try validateOpenAITunnelSurface(profile)
    return try await openAITunnelSupervisor.doctor(
      profile,
      configuration: manifestStore.activeConfiguration()
    )
  }

  package func startOpenAITunnel(
    profileID: String,
    allowKeychainAuthenticationUI: Bool = true
  ) async throws -> OpenAITunnelStatus {
    let profile = try requireOpenAITunnelConfiguration(profileID)
    try validateOpenAITunnelSurface(profile)
    let status = try await openAITunnelSupervisor.start(
      profile,
      configuration: manifestStore.activeConfiguration(),
      authenticationUI: allowKeychainAuthenticationUI ? .allow : .fail
    )
    do {
      try setOpenAITunnelDesiredRunning(true, profileID: profileID)
    } catch {
      _ = try? await openAITunnelSupervisor.stop(profileID: profileID)
      throw error
    }
    return status
  }

  package func reconnectOpenAITunnel(
    profileID: String,
    allowKeychainAuthenticationUI: Bool = true
  ) async throws -> OpenAITunnelStatus {
    let profile = try requireOpenAITunnelConfiguration(profileID)
    try validateOpenAITunnelSurface(profile)
    let status = try await openAITunnelSupervisor.reconnect(
      profile,
      configuration: manifestStore.activeConfiguration(),
      authenticationUI: allowKeychainAuthenticationUI ? .allow : .fail
    )
    do {
      try setOpenAITunnelDesiredRunning(true, profileID: profileID)
    } catch {
      _ = try? await openAITunnelSupervisor.stop(profileID: profileID)
      throw error
    }
    return status
  }

  package func stopOpenAITunnel(profileID: String) async throws -> OpenAITunnelStatus {
    try setOpenAITunnelDesiredRunning(false, profileID: profileID)
    do {
      return try await openAITunnelSupervisor.stop(profileID: profileID)
    } catch {
      try? setOpenAITunnelDesiredRunning(true, profileID: profileID)
      throw error
    }
  }

  package func suspendOpenAITunnel(profileID: String) async throws -> OpenAITunnelStatus {
    _ = try requireOpenAITunnelConfiguration(profileID)
    return try await openAITunnelSupervisor.stop(profileID: profileID)
  }

  package func desiredOpenAITunnelConfigurationIDs() throws -> [String] {
    guard let value = try database.runtimeSetting(key: Self.desiredOpenAITunnelsSettingKey),
      let data = value.data(using: .utf8)
    else {
      return []
    }
    do {
      let identifiers = try JSONDecoder().decode([String].self, from: data)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      return Array(Set(identifiers)).sorted()
    } catch {
      throw AppControlPlaneServiceError.invalidDesiredOpenAITunnelState
    }
  }

  package func openAITunnelLogs(
    profileID: String,
    stdoutCursor: Int64 = 0,
    stderrCursor: Int64 = 0,
    maxReadBytes: Int = 65_536
  ) async throws -> OpenAITunnelLogPage {
    let profile = try requireOpenAITunnelConfiguration(profileID)
    return try await openAITunnelSupervisor.logs(
      profileID: profileID,
      stdoutCursor: stdoutCursor,
      stderrCursor: stderrCursor,
      maxReadBytes: maxReadBytes,
      secretReference: profile.apiKeyReference
    )
  }

  package func launchAtLoginState() -> LaunchAtLoginState {
    scheduleLaunchAtLoginRefreshIfNeeded()
    return cachedLaunchAtLoginState
  }

  private func refreshLaunchAtLoginState() async -> LaunchAtLoginState {
    launchAtLoginRefreshInProgress = true
    let generation = launchAtLoginGeneration
    let controller = launchAtLoginController
    let observedState: LaunchAtLoginState
    do {
      observedState = try await launchAtLoginOperations.perform {
        controller.state()
      }
    } catch {
      observedState = .unavailable
    }
    if generation == launchAtLoginGeneration {
      cachedLaunchAtLoginState = observedState
    }
    launchAtLoginRefreshInProgress = false
    return cachedLaunchAtLoginState
  }

  package func setLaunchAtLoginEnabled(_ enabled: Bool) async throws -> LaunchAtLoginState {
    launchAtLoginGeneration &+= 1
    let generation = launchAtLoginGeneration
    let controller = launchAtLoginController
    let updatedState = try await launchAtLoginOperations.perform {
      try controller.setEnabled(enabled)
      return controller.state()
    }
    if generation == launchAtLoginGeneration {
      cachedLaunchAtLoginState = updatedState
    }
    return cachedLaunchAtLoginState
  }

  private func scheduleLaunchAtLoginRefreshIfNeeded() {
    guard !launchAtLoginRefreshInProgress else {
      return
    }
    launchAtLoginRefreshInProgress = true
    Task { [weak self] in
      _ = await self?.refreshLaunchAtLoginState()
    }
  }

  private func requireOpenAITunnelConfiguration(_ id: String) throws -> OpenAITunnelConfiguration {
    guard let profile = try openAITunnelConfigurations().first(where: { $0.id == id }) else {
      throw AppControlPlaneServiceError.unknownOpenAITunnelConfiguration(id)
    }
    return profile
  }

  func activateTransportConfiguration(_ configuration: GatewayConfiguration) throws {
    try configuration.validate()
    _ = try manifestStore.activate(manifest: configuration.exportedTOML())
  }

  private func validateOpenAITunnelSurface(_ profile: OpenAITunnelConfiguration) throws {
    let configuration = try manifestStore.activeConfiguration()
    let gateway = try GatewayRuntime(
      configuration: configuration,
      context: configuration.executionContext(
        caller: .secureTunnel,
        profileID: profile.gatewayProfile
      ),
      database: database,
      registeredWorkspaces: try database.workspaces(),
      bookmarkService: bookmarkService
    )
    _ = try ChatGPTProfileAuditor().audit(
      configuration: configuration,
      registry: gateway,
      allowWriteTools: profile.gatewayProfile == .chatGPTOperate
    )
  }

  private func setOpenAITunnelDesiredRunning(_ desiredRunning: Bool, profileID: String) throws {
    var profileIDs = Set(try desiredOpenAITunnelConfigurationIDs())
    if desiredRunning {
      profileIDs.insert(profileID)
    } else {
      profileIDs.remove(profileID)
    }
    let data = try JSONEncoder().encode(profileIDs.sorted())
    guard let value = String(data: data, encoding: .utf8) else {
      throw AppControlPlaneServiceError.invalidDesiredOpenAITunnelState
    }
    try database.saveRuntimeSetting(key: Self.desiredOpenAITunnelsSettingKey, value: value)
  }

  private static func health(for state: ExternalProviderDoctorState) -> String {
    switch state {
    case .passed, .notApplicable:
      return "ready"
    case .unavailable:
      return "unavailable"
    case .failed, .contractIncomplete:
      return "failed"
    }
  }

  private static func providerDetail(_ result: ExternalProviderDiscoveryResult) -> String? {
    let messages = ([result.doctorStatus.message] + result.diagnostics.map(\.message))
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return messages.isEmpty ? nil : messages.joined(separator: " ")
  }

  private static let activeProfileSettingKey = "active-gateway-profile"
  private static let gatewayDesiredRunningSettingKey = "gateway-desired-running"
  private static let desiredOpenAITunnelsSettingKey = "desired-running-openai-tunnels"

  func keychainContainsSecret(_ reference: SecretReference) async throws -> Bool {
    try await secretStore.containsAsynchronously(reference)
  }

  func keychainSecretValue(for reference: SecretReference) async throws -> String? {
    try await secretStore.valueAsynchronously(for: reference)
  }

  func setKeychainSecret(_ value: String, for reference: SecretReference) async throws {
    try await secretStore.setAsynchronously(value, for: reference)
  }

  func deleteKeychainSecret(_ reference: SecretReference) async throws {
    try await secretStore.deleteAsynchronously(reference)
  }
}

package struct OpenAITunnelAPIKeyCheckpoint: Sendable {
  package let reference: SecretReference
  fileprivate let value: String?
}

package enum AppControlPlaneServiceError: Error, LocalizedError, Equatable {
  case invalidDirectory(String)
  case symbolicLinkDirectory(String)
  case directoryOwnedByAnotherUser(String)
  case unknownOpenAITunnelConfiguration(String)
  case unknownGatewayProfile(String)
  case unknownWorkspace(String)
  case workspaceMetadataConflict(
    workspaceID: String,
    existingDisplayName: String,
    requestedDisplayName: String
  )
  case invalidStoredProfile(String)
  case localAdminCannotBeSocketProfile
  case fullShellProfileNotAllowed(String)
  case fullShellManifestDisabled
  case invalidDesiredOpenAITunnelState

  package var errorDescription: String? {
    switch self {
    case .invalidDirectory(let path):
      return "The control-plane path is not a directory: \(path)"
    case .symbolicLinkDirectory(let path):
      return "Control-plane directories must not be symbolic links: \(path)"
    case .directoryOwnedByAnotherUser(let path):
      return "The control-plane directory is owned by another user: \(path)"
    case .unknownOpenAITunnelConfiguration(let id):
      return "Unknown tunnel profile: \(id)"
    case .unknownGatewayProfile(let id):
      return "Unknown gateway profile: \(id)"
    case .unknownWorkspace(let id):
      return "Unknown workspace: \(id)"
    case .workspaceMetadataConflict(
      let workspaceID,
      let existingDisplayName,
      let requestedDisplayName
    ):
      return
        "Workspace '\(workspaceID)' already registers this canonical root as '\(existingDisplayName)'; requested display name '\(requestedDisplayName)' conflicts."
    case .invalidStoredProfile(let id):
      return "The stored active gateway profile is invalid: \(id)"
    case .localAdminCannotBeSocketProfile:
      return "local-admin cannot be bound to the Tunnel-facing local socket."
    case .fullShellProfileNotAllowed(let id):
      return "Full Shell cannot be enabled for profile '\(id)'."
    case .fullShellManifestDisabled:
      return "Enable policy.shell_enabled in the active manifest before enabling Full Shell."
    case .invalidDesiredOpenAITunnelState:
      return "The persisted Tunnel runtime state is invalid."
    }
  }
}
