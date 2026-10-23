import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPGateway
import ComputerMCPPersistence
import ComputerMCPPlatform
import ComputerMCPPlugins
import ComputerMCPProcess
import ComputerMCPToolsProject
import ComputerMCPTransport
import ComputerMCPTunnels
import Foundation
import MCP

package protocol ControlPlaneProviderDiscovering: Sendable {
  func discover(configuration: GatewayConfiguration) throws -> [ExternalProviderDiscoveryResult]
}

internal struct AppControlPlaneProviderDiscovery: ControlPlaneProviderDiscovering {
  private let commandRunner: any CommandRunning
  private let executableSearchDirectories: [String]

  internal init(
    executableSearchDirectories: [String],
    commandRunner: any CommandRunning = ManagedCommandRunner()
  ) {
    self.commandRunner = commandRunner
    self.executableSearchDirectories = executableSearchDirectories
  }

  internal func discover(configuration: GatewayConfiguration) throws
    -> [ExternalProviderDiscoveryResult]
  {
    try ExternalProviderDiscovery(
      configuration: configuration,
      commandRunner: commandRunner,
      systemSearchDirectories: executableSearchDirectories
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
  private let gatewayOperations = BlockingOperationExecutor(
    label: "computer-mcp.control-plane-gateways", serial: false)
  let providerProbeOperations = BlockingOperationExecutor(
    label: "computer-mcp.provider-probes")
  package nonisolated let directories: AppControlPlaneServiceDirectories
  /// Host-selected CLI used by owned workers and tunnel bridges, never supplied by plugin metadata.
  package nonisolated let gatewayExecutablePath: String

  let database: GatewayDatabase
  let manifestStore: AtomicManifestStore
  package nonisolated let defaultManifest: String
  let secretStore: any SecretStore
  private let openAITunnelSupervisor: OpenAITunnelSupervisor
  private let providerDiscovery: any ControlPlaneProviderDiscovering
  private let launchAtLoginController: any LaunchAtLoginControlling
  private let computerUsePermissionReader: any ComputerUsePermissionReading
  private let launchAtLoginOperations = BlockingOperationExecutor(
    label: "com.showxu.computer-mcp.launch-at-login",
    serial: false
  )
  package nonisolated let platform: PlatformServices
  var cloudflareRuntimes: [String: CloudflareRuntimeState] = [:]
  var cloudflareAccessCredentials: [String: HTTPAccessTokenCredential] = [:]
  /// A profile keeps its mutation slot through secret reads, activation and rollback.
  var cloudflareCredentialMutationWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
  var cloudflareOAuthSessions: [String: GatewayOAuthSessions] = [:]
  let oauthApprovalWillCommit: @Sendable () throws -> Void
  let cloudflareAccessTokenDidRead: @Sendable () async throws -> Void
  var cloudflareStartTasks: [String: Task<CloudflareTunnelStatus, Error>] = [:]
  var cloudflareStopTasks: [String: Task<CloudflareTunnelStatus, Error>] = [:]
  private var cachedLaunchAtLoginState: LaunchAtLoginState = .unavailable
  private var launchAtLoginRefreshInProgress = false
  private var launchAtLoginGeneration: UInt64 = 0
  var configurationMutationInProgress = false
  var pluginRecoveryAttempted = false
  var pluginRecoveryIssues: [PluginStoreIssue] = []
  var pluginRecoveryError: String?
  let pluginCatalog: any PluginCatalogBrowsing
  let pluginReleases: GitHubPluginReleases
  let pluginDownload: GitHubPluginDownload
  let bundledPlugins: BundledPlugins

  package init(
    directories: AppControlPlaneServiceDirectories,
    database: GatewayDatabase,
    manifestStore: AtomicManifestStore,
    defaultManifest: String,
    secretStore: any SecretStore,
    openAITunnelSupervisor: OpenAITunnelSupervisor,
    gatewayExecutablePath: String = "computer-mcp",
    providerDiscovery: (any ControlPlaneProviderDiscovering)? = nil,
    launchAtLoginController: any LaunchAtLoginControlling,
    computerUsePermissionReader: any ComputerUsePermissionReading,
    platform: PlatformServices,
    pluginCatalog: (any PluginCatalogBrowsing)? = nil,
    pluginReleases: GitHubPluginReleases = GitHubPluginReleases(),
    pluginDownload: GitHubPluginDownload = GitHubPluginDownload(),
    bundledPlugins: BundledPlugins = .current,
    oauthApprovalWillCommit: @escaping @Sendable () throws -> Void = {},
    cloudflareAccessTokenDidRead: @escaping @Sendable () async throws -> Void = {}
  ) {
    self.directories = directories
    self.gatewayExecutablePath = gatewayExecutablePath
    self.database = database
    self.manifestStore = manifestStore
    self.defaultManifest = defaultManifest
    self.secretStore = secretStore
    self.openAITunnelSupervisor = openAITunnelSupervisor
    self.providerDiscovery =
      providerDiscovery
      ?? AppControlPlaneProviderDiscovery(
        executableSearchDirectories: platform.executableSearchDirectories)
    self.launchAtLoginController = launchAtLoginController
    self.computerUsePermissionReader = computerUsePermissionReader
    self.platform = platform
    self.pluginCatalog =
      pluginCatalog
      ?? StaticPluginCatalog(
        cacheURL: directories.applicationSupport.appendingPathComponent(
          "Cache/PluginCatalog/index.json"))
    self.pluginReleases = pluginReleases
    self.pluginDownload = pluginDownload
    self.bundledPlugins = bundledPlugins
    self.oauthApprovalWillCommit = oauthApprovalWillCommit
    self.cloudflareAccessTokenDidRead = cloudflareAccessTokenDidRead
  }

  package func start() async throws {
    try directories.prepare()
    try directories.secureDatabaseFiles()
    await manifestStore.publicationLock.acquire()
    do {
      defer { manifestStore.publicationLock.release() }
      let activeIDs: Set<String>
      do {
        activeIDs = Set(try manifestStore.activeConfiguration().transports.cloudflare.map(\.id))
      } catch AtomicManifestStoreError.manifestMissing {
        activeIDs = []
      }
      try database.reconcileOAuthTunnels(activeIDs: activeIDs)
    }
    try await recoverPluginsAtStartup()

  }

  package func stop() async throws {
    let cloudflareIDs = Set(cloudflareRuntimes.keys)
      .union(cloudflareStartTasks.keys).union(cloudflareStopTasks.keys)
    for profileID in cloudflareIDs.sorted() {
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
  func activateManifest(_ manifest: String, expectedDigest: String? = nil) async throws
    -> ConfigurationRevision
  {
    guard !configurationMutationInProgress else { throw PluginHostError.changeInProgress }
    await manifestStore.publicationLock.acquire()
    defer { manifestStore.publicationLock.release() }
    try Task.checkCancellation()
    let configuration =
      try FileManager.default.fileExists(atPath: directories.manifest.path)
      ? manifestStore.activeConfiguration() : nil
    let prepared = try manifestStore.prepare(
      manifest: manifest, expectedDigest: expectedDigest, expectedConfiguration: configuration)
    if let configuration {
      try await drainRemovedCloudflareTunnels(from: configuration, to: prepared.configuration)
    }
    return try manifestStore.commit(prepared)
  }

  package func configurationDigest() throws -> String {
    try manifestStore.admittedDigest(for: manifestStore.activeConfiguration())
  }

  func applyManifestChange(
    _ manifest: String, reason: ManifestChangeReason, expectedDigest: String,
    publish: @Sendable (GatewayInputs, PreparedManifestChange) async throws -> ConfigurationRevision
  ) async throws -> ConfigurationRevision {
    guard !configurationMutationInProgress else { throw PluginHostError.changeInProgress }
    configurationMutationInProgress = true
    defer { configurationMutationInProgress = false }
    await manifestStore.publicationLock.acquire()
    defer { manifestStore.publicationLock.release() }
    try Task.checkCancellation()
    let inputs = try gatewayInputs()
    let prepared = try manifestStore.prepare(
      manifest: manifest, reason: reason,
      expectedDigest: expectedDigest,
      expectedConfiguration: inputs.configuration)
    guard prepared.persisted == inputs.persisted else {
      throw GatewayDatabaseError.configurationChanged
    }
    try await drainRemovedCloudflareTunnels(from: inputs.configuration, to: prepared.configuration)
    return try await publish(inputs, prepared)
  }

  package func activeConfiguration() throws -> GatewayConfiguration {
    var configuration = try manifestStore.activeConfiguration()
    configuration.knownPluginMCPServerIDs = try database.pluginStoreSnapshot()
      .includingBundledDefaults(bundledPlugins.packages.map(\.manifest)).knownMCPRegistrationIDs
    return configuration
  }

  package func effectiveConfigurationForExport() async throws -> GatewayConfiguration {
    let grants = try await profileGrants()
    var configuration = try activeConfiguration()
    configuration.projects = try projects().map { project in
      ProjectManifestConfig(
        id: project.id,
        displayName: project.displayName,
        path: project.rootPath
      )
    }.sorted { $0.id < $1.id }
    configuration.profiles = grants.map { grant in
      ProfileGrantConfig(
        id: grant.id,
        capabilities: grant.capabilityIDs.sorted(),
        projects: grant.projectIDs.sorted(),
        allowedCallers: grant.allowedCallers.sorted { $0.rawValue < $1.rawValue },
        fullShellEnabled: grant.fullShellEnabled,
        mcpServers: grant.mcpServerIDs.sorted(),
        mode: grant.mode,
        confirmationPolicy: grant.confirmationPolicy
      )
    }.sorted { $0.id.rawValue < $1.id.rawValue }
    try configuration.validate()
    return configuration
  }

  package func projects() throws -> [RegisteredProject] {
    try database.projects()
  }

  package func projectAccessReports() throws -> [ProjectAccessReport] {
    try database.projects().map { try platform.projectGrants.inspect($0) }
  }

  @discardableResult
  package func registerProject(
    at url: URL,
    displayName: String? = nil
  ) async throws -> RegisteredProject {
    await manifestStore.publicationLock.acquire()
    defer { manifestStore.publicationLock.release() }
    try Task.checkCancellation()
    let proposed = try platform.projectGrants.registerFolder(at: url, displayName: displayName)
    let registration = try database.registerProjectIdempotently(proposed)
    if !registration.created,
      displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
      registration.project.displayName != proposed.displayName
    {
      throw AppControlPlaneServiceError.projectMetadataConflict(
        projectID: registration.project.id,
        existingDisplayName: registration.project.displayName,
        requestedDisplayName: proposed.displayName
      )
    }
    return registration.project
  }

  package func projectDeduplicationPlan() throws -> ProjectDeduplicationPlan {
    try database.projectDeduplicationPlan()
  }

  package func applyProjectDeduplication(
    expectedPlanDigest: String,
    allowMetadataConflicts: Bool
  ) async throws -> ProjectDeduplicationResult {
    await manifestStore.publicationLock.acquire()
    defer { manifestStore.publicationLock.release() }
    try Task.checkCancellation()
    let expected = try database.configurationState()
    let plan = try database.projectDeduplicationPlan()
    let resolved = try await resolveLegacyProjectProfiles(
      expected, projectIDs: Set(plan.groups.flatMap(\.duplicateProjectIDs)))
    try Task.checkCancellation()
    let commit = {
      try self.database.applyProjectDeduplication(
        expectedPlanDigest: expectedPlanDigest, allowMetadataConflicts: allowMetadataConflicts,
        expectedConfiguration: expected, resolvedProfiles: resolved.profiles)
    }
    if let configuration = resolved.configuration {
      return try manifestStore.withCurrentConfiguration(configuration, publication: commit)
    }
    return try commit()
  }

  package func removeProject(id: String) async throws {
    await manifestStore.publicationLock.acquire()
    defer { manifestStore.publicationLock.release() }
    try Task.checkCancellation()
    let expected = try database.configurationState()
    let canonicalID = expected.projectAliases[id] ?? id
    guard expected.projects.contains(where: { $0.id == canonicalID }) else {
      throw AppControlPlaneServiceError.unknownProject(id)
    }
    let removedIDs = Set(
      expected.projectAliases.filter { $0.value == canonicalID }.map(\.key) + [canonicalID])
    let resolved = try await resolveLegacyProjectProfiles(expected, projectIDs: removedIDs)
    try Task.checkCancellation()
    let commit = {
      try self.database.removeProject(
        id: canonicalID, expectedConfiguration: expected, resolvedProfiles: resolved.profiles)
    }
    if let configuration = resolved.configuration {
      try manifestStore.withCurrentConfiguration(configuration, publication: commit)
    } else {
      try commit()
    }
  }

  private func resolveLegacyProjectProfiles(
    _ expected: GatewayDatabase.ConfigurationState, projectIDs: Set<String>,
    includeWildcard: Bool = false
  ) async throws -> (profiles: [ProfileGrant], configuration: GatewayConfiguration?) {
    guard
      expected.profiles.contains(where: {
        $0.authorizationRevision == 0
          && (!$0.projectIDs.isDisjoint(with: projectIDs)
            || (includeWildcard && $0.projectIDs.contains("*")))
      })
    else { return ([], nil) }
    let inputs = try gatewayInputs()
    guard inputs.persisted == expected else { throw GatewayDatabaseError.configurationChanged }
    let profiles = try await profileGrants()
    try requireCurrentGatewayInputs(inputs)
    return (profiles, inputs.configuration)
  }

  func applyProjectChange(
    _ change: ProjectHostChange,
    publish:
      @Sendable (GatewayInputs, PreparedProjectChange<GatewayDatabase.ConfigurationState>)
      async throws ->
      GatewayDatabase.ConfigurationState
  ) async throws -> ProjectChangeResult {
    guard !configurationMutationInProgress else { throw PluginHostError.changeInProgress }
    configurationMutationInProgress = true
    defer { configurationMutationInProgress = false }
    await manifestStore.publicationLock.acquire()
    defer { manifestStore.publicationLock.release() }
    try Task.checkCancellation()
    let inputs = try gatewayInputs()
    let mutation: ProjectConfigurationMutation
    let affectedProjectIDs: Set<String>
    var requestedDisplayName: String?
    var includeWildcard = false
    switch change {
    case .register(let url, let displayName):
      let project = try platform.projectGrants.registerFolder(at: url, displayName: displayName)
      mutation = .register(project)
      affectedProjectIDs = []
      if displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
        requestedDisplayName = project.displayName
      }
    case .repair(let id, let root, let displayName):
      let canonicalID = inputs.persisted.projectAliases[id] ?? id
      guard let original = inputs.projects.first(where: { $0.id == canonicalID }) else {
        throw AppControlPlaneServiceError.unknownProject(id)
      }
      let bookmarks = platform.projectGrants
      let (selected, identity) = try await gatewayOperations.perform {
        let selected = try bookmarks.registerFolder(
          at: root, displayName: displayName ?? original.displayName)
        let identity = try ProjectRootIdentity(URL(fileURLWithPath: selected.rootPath))
        let access = try bookmarks.resolve(selected)
        defer { access.close() }
        guard access.rootIdentity == identity else {
          throw ProjectBookmarkError.rootChanged(projectID: original.id)
        }
        return (access.project, identity)
      }
      var repaired = selected
      repaired.id = original.id
      repaired.createdAt = original.createdAt
      if displayName == nil { repaired.displayName = original.displayName }
      mutation = .repair(repaired, root: identity)
      affectedProjectIDs = Set(
        inputs.persisted.projectAliases.filter { $0.value == canonicalID }.map(\.key) + [
          canonicalID
        ])
      includeWildcard = true
    case .remove(let id):
      let canonicalID = inputs.persisted.projectAliases[id] ?? id
      guard inputs.projects.contains(where: { $0.id == canonicalID }) else {
        throw AppControlPlaneServiceError.unknownProject(id)
      }
      mutation = .remove(canonicalID)
      affectedProjectIDs = Set(
        inputs.persisted.projectAliases.filter { $0.value == canonicalID }.map(\.key) + [
          canonicalID
        ])
    case .deduplicate(let digest, let allowMetadataConflicts):
      mutation = .deduplicate(
        expectedPlanDigest: digest, allowMetadataConflicts: allowMetadataConflicts)
      let plan = try database.projectDeduplicationPlan()
      guard plan.planDigest == digest else {
        throw ProjectDeduplicationError.planChanged(expected: digest, actual: plan.planDigest)
      }
      affectedProjectIDs = Set(plan.groups.flatMap(\.duplicateProjectIDs))
    }
    let resolved = try await resolveLegacyProjectProfiles(
      inputs.persisted, projectIDs: affectedProjectIDs, includeWildcard: includeWildcard)
    try requireCurrentGatewayInputs(inputs)
    let prepared = try database.prepareProjectChange(
      mutation, expected: inputs.persisted, resolvedProfiles: resolved.profiles)
    if case .registered(let project, false) = prepared.result,
      let requestedDisplayName, project.displayName != requestedDisplayName
    {
      throw AppControlPlaneServiceError.projectMetadataConflict(
        projectID: project.id, existingDisplayName: project.displayName,
        requestedDisplayName: requestedDisplayName)
    }
    let committed = try await publish(inputs, prepared)
    if case .registered(let project, let created) = prepared.result,
      let published = committed.projects.first(where: { $0.id == project.id })
    {
      return .registered(published, created: created)
    }
    if case .repaired(let project) = prepared.result,
      let published = committed.projects.first(where: { $0.id == project.id })
    {
      return .repaired(published)
    }
    return prepared.result
  }

  package func profileGrants() async throws -> [ProfileGrant] {
    let inputs = try gatewayInputs()
    var grants = Dictionary(
      uniqueKeysWithValues: try await baseProfileGrants(inputs: inputs).map { ($0.id, $0) })
    for persisted in inputs.profiles {
      guard let configured = grants[persisted.id] else { continue }
      var effective = configured.applyingPersistedRuntimeState(persisted)
      if persisted.authorizationRevision == 0, effective.capabilityIDs.contains("*") {
        effective.projectIDs.formUnion(inputs.projects.map(\.id))
      }
      grants[persisted.id] = effective
    }
    try requireCurrentGatewayInputs(inputs)
    return grants.values.sorted { $0.id.rawValue < $1.id.rawValue }
  }

  func baseProfileGrants(inputs: GatewayInputs) async throws -> [ProfileGrant] {
    let configuration = inputs.configuration
    let configuredProfileIDs = Set(configuration.profiles.map(\.id))
    let profileIDs = Array(
      Set(GatewayProfileID.builtIns + configuration.profiles.map(\.id))
    ).sorted { $0.rawValue < $1.rawValue }
    var grants = Dictionary(
      uniqueKeysWithValues: profileIDs.map {
        var grant = configuration.profileGrant(for: $0)
        grant.authorizationRevision = 0
        return ($0, grant)
      }
    )
    for (profileID, caller) in [
      (GatewayProfileID.chatGPTObserve, GatewayCallerKind.secureTunnel),
      (GatewayProfileID.cloudflareObserve, GatewayCallerKind.cloudflareTunnel),
    ] where !configuredProfileIDs.contains(profileID) {
      let gateway = try await makeGateway(
        inputs: inputs, caller: caller, profileID: profileID, persistentState: false)
      let tools: [MCPTool]
      do {
        // Profile administration inventories the host catalog without a caller invocation.
        tools = try gateway.listTools(context: .empty)
      } catch {
        await gateway.shutdown()
        throw error
      }
      await gateway.shutdown()
      try requireCurrentGatewayInputs(inputs)
      grants[profileID] = ProfileGrant(
        id: profileID,
        capabilityIDs: Set(tools.map(\.name)),
        projectIDs: Set(inputs.projects.map(\.id)),
        allowedCallers: [caller],
        mode: .readOnly,
        authorizationRevision: 0
      )
    }
    try requireCurrentGatewayInputs(inputs)
    return profileIDs.compactMap { grants[$0] }
  }

  @discardableResult
  package func setProjectEnabled(
    _ enabled: Bool,
    projectID: String,
    profileID: GatewayProfileID
  ) async throws -> ProfileGrant {
    let inputs = try gatewayInputs()
    guard try database.projects().contains(where: { $0.id == projectID }) else {
      throw AppControlPlaneServiceError.unknownProject(projectID)
    }
    let grants = try await profileGrants()
    await manifestStore.publicationLock.acquire()
    defer { manifestStore.publicationLock.release() }
    try Task.checkCancellation()
    try requireCurrentGatewayInputs(inputs)
    let configuration = try manifestStore.activeConfiguration()
    guard var grant = grants.first(where: { $0.id == profileID }) else {
      throw AppControlPlaneServiceError.unknownGatewayProfile(profileID.rawValue)
    }
    if enabled {
      grant.projectIDs.insert(projectID)
    } else {
      if grant.projectIDs.remove("*") != nil {
        grant.projectIDs.formUnion(try database.projects().map(\.id))
      }
      grant.projectIDs.remove(projectID)
    }
    try grant.validate()
    try manifestStore.withCurrentConfiguration(configuration) {
      try database.saveProfile(grant, expectedRevision: grant.authorizationRevision)
    }
    return try database.profiles().first { $0.id == profileID } ?? grant
  }

  package func activeGatewayProfile() throws -> GatewayProfileID {
    guard
      let rawValue = try database.runtimeSetting(key: Self.activeProfileSettingKey)
    else {
      return .chatGPTObserve
    }
    do {
      return try GatewayDatabase.decodeActiveGatewayProfile(rawValue)
    } catch {
      throw AppControlPlaneServiceError.invalidStoredProfile(rawValue)
    }
  }

  package func gatewayTunnelPrincipalID() throws -> String {
    let key = "gateway-tunnel-registration"
    if let value = try database.runtimeSetting(key: key) {
      let id = try GatewayDatabase.decodeGatewayTunnelRegistration(value)
      return "tunnel-bridge:\(id.uuidString.lowercased())"
    }
    let id = UUID().uuidString.lowercased()
    try database.saveRuntimeSetting(key: key, value: id)
    return "tunnel-bridge:\(id)"
  }

  package func setActiveGatewayProfile(_ profile: GatewayProfileID) throws {
    guard profile != .localAdmin else {
      throw AppControlPlaneServiceError.localAdminCannotBeSocketProfile
    }
    let configuration = try manifestStore.activeConfiguration()
    guard
      GatewayProfileID.builtIns.contains(profile)
        || configuration.profiles.contains(where: { $0.id == profile })
    else {
      throw AppControlPlaneServiceError.unknownGatewayProfile(profile.rawValue)
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
  ) async throws -> ProfileGrant {
    let inputs = try gatewayInputs()
    if enabled {
      guard try manifestStore.activeConfiguration().policy.shellEnabled else {
        throw AppControlPlaneServiceError.fullShellManifestDisabled
      }
    }
    let grants = try await profileGrants()
    await manifestStore.publicationLock.acquire()
    defer { manifestStore.publicationLock.release() }
    try Task.checkCancellation()
    try requireCurrentGatewayInputs(inputs)
    let configuration = try manifestStore.activeConfiguration()
    if enabled && !configuration.policy.shellEnabled {
      throw AppControlPlaneServiceError.fullShellManifestDisabled
    }
    guard var grant = grants.first(where: { $0.id == profileID }) else {
      throw AppControlPlaneServiceError.unknownGatewayProfile(profileID.rawValue)
    }
    guard !enabled || grant.supportsFullShell else {
      throw GatewayPolicyConfigurationError.fullShellRequiresFullAccess
    }
    grant.fullShellEnabled = enabled
    if enabled {
      grant.capabilityIDs.formUnion(ProfileGrant.fullShellCapabilities)
    }
    try grant.validate()
    try manifestStore.withCurrentConfiguration(configuration) {
      try database.saveProfile(grant, expectedRevision: grant.authorizationRevision)
    }
    return try database.profiles().first { $0.id == profileID } ?? grant
  }

  @discardableResult
  package func updateProfilePermissions(
    profileID: GatewayProfileID,
    mode: GatewayPermissionMode? = nil,
    confirmationPolicy: GatewayConfirmationPolicy? = nil,
    fullShellEnabled: Bool? = nil,
    capabilityIDs: Set<String>? = nil,
    projectIDs: Set<String>? = nil,
    mcpServerIDs: Set<String>? = nil,
    allowedCallers: Set<GatewayCallerKind>? = nil,
    expectedRevision: Int64? = nil,
    reviewedOptions: ProfilePermissionOptions? = nil
  ) async throws -> ProfileGrant {
    let inputs = try gatewayInputs()
    guard var grant = try await profileGrants().first(where: { $0.id == profileID }) else {
      throw AppControlPlaneServiceError.unknownGatewayProfile(profileID.rawValue)
    }
    await manifestStore.publicationLock.acquire()
    defer { manifestStore.publicationLock.release() }
    try Task.checkCancellation()
    try requireCurrentGatewayInputs(inputs)
    if let reviewedOptions {
      try requireCurrentGatewayInputs(reviewedOptions.inputs)
      guard reviewedOptions.grant == grant else {
        throw AppControlPlaneServiceError.gatewayInputsChanged
      }
    }
    let revision = expectedRevision ?? grant.authorizationRevision
    if let mode {
      grant.mode = mode
      if mode != .localFullAccess, fullShellEnabled == nil { grant.fullShellEnabled = false }
    }
    if let confirmationPolicy { grant.confirmationPolicy = confirmationPolicy }
    if let fullShellEnabled { grant.fullShellEnabled = fullShellEnabled }
    if let capabilityIDs { grant.capabilityIDs = capabilityIDs }
    if let projectIDs { grant.projectIDs = projectIDs }
    if let mcpServerIDs { grant.mcpServerIDs = mcpServerIDs }
    if let allowedCallers { grant.allowedCallers = allowedCallers }
    let configuration = try manifestStore.activeConfiguration()
    if grant.fullShellEnabled && !configuration.policy.shellEnabled {
      throw AppControlPlaneServiceError.fullShellManifestDisabled
    }
    let knownProjectIDs = Set(try database.projects().map(\.id))
    if let unknown = grant.projectIDs.subtracting(knownProjectIDs).subtracting(["*"]).sorted()
      .first
    {
      throw AppControlPlaneServiceError.unknownProject(unknown)
    }
    let pluginState = try database.pluginStoreSnapshot()
      .includingBundledDefaults(bundledPlugins.packages.map(\.manifest))
    let composition = try GatewayPluginComposition(
      configuration: configuration,
      plugins: PluginHost.resolve(
        pluginState, bundled: bundledPlugins, applications: platform.applications
      ).plugins)
    try ProfileGrantConfig(
      id: grant.id, capabilities: grant.capabilityIDs.sorted(),
      projects: grant.projectIDs.sorted(), allowedCallers: Array(grant.allowedCallers),
      fullShellEnabled: grant.fullShellEnabled, mcpServers: grant.mcpServerIDs.sorted(),
      mode: grant.mode, confirmationPolicy: grant.confirmationPolicy
    ).validate(
      knownProjectIDs: knownProjectIDs,
      knownMCPServerIDs: Set(composition.runtimeConfiguration.mcp.servers.map(\.id)))
    if let reviewedOptions {
      try manifestStore.withCurrentConfiguration(configuration) {
        guard try database.configurationState() == reviewedOptions.inputs.persisted else {
          throw AppControlPlaneServiceError.gatewayInputsChanged
        }
        try database.saveProfile(grant, expectedRevision: revision)
      }
    } else {
      try manifestStore.withCurrentConfiguration(configuration) {
        try database.saveProfile(grant, expectedRevision: revision)
      }
    }
    return try database.profiles().first { $0.id == profileID } ?? grant
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
    computerUsePermissionReader.permissionSnapshot()
  }

  package func operationApprovals(limit: Int = 100) throws -> [OperationTicket] {
    try database.operationApprovals(limit: limit)
  }

  @discardableResult
  package func resolveOperationApproval(
    id: String, approved: Bool, resolver: GatewayCallerKind
  ) throws -> OperationTicket {
    let ticket = try database.resolveOperationApproval(
      id: id, approved: approved, resolver: resolver)
    try database.recordAudit(
      AuditEvent(
        requestID: UUID().uuidString, ticketID: ticket.id, caller: resolver,
        profileID: .localAdmin, projectID: ticket.projectID,
        capabilityID: approved ? "approvals.approve" : "approvals.deny",
        decision: .allowed, inputDigest: ticket.inputDigest))
    return ticket
  }

  package func makeGatewaySocketSession(
    caller: GatewayCallerKind,
    profileID: GatewayProfileID,
    transportTrace: GatewayTransportTrace? = nil,
    trustedPrincipalID: String? = nil
  ) async throws -> GatewaySocketServerSession {
    let (inputs, gateway) = try await makeGatewaySessionRuntime(
      caller: caller, profileID: profileID, transportTrace: transportTrace,
      trustedPrincipalID: trustedPrincipalID)
    let server = await MCPRuntimeAdapter.makeGatewayServer(
      configuration: inputs.configuration, registry: gateway)
    do {
      try requireCurrentGatewayInputs(inputs)
    } catch {
      await server.stop()
      await gateway.shutdown()
      throw error
    }
    return GatewaySocketServerSession(server: server) { await gateway.shutdown() }
  }

  func makeGatewaySessionRuntime(
    caller: GatewayCallerKind,
    profileID: GatewayProfileID,
    transportTrace: GatewayTransportTrace? = nil,
    trustedPrincipalID: String? = nil,
    terminalSessions: GatewayTerminalSessions = GatewayTerminalSessions(),
    requiresControlSession: Bool = false,
    remoteManagement: GatewayRemoteManagement? = nil
  ) async throws -> (inputs: GatewayInputs, gateway: GatewayRuntime) {
    if caller.isRemote && profileID == .localAdmin {
      throw AppControlPlaneServiceError.localAdminCannotBeSocketProfile
    }
    let inputs = try gatewayInputs()
    let gateway = try await makeGateway(
      inputs: inputs, caller: caller, profileID: profileID, transportTrace: transportTrace,
      trustedPrincipalID: trustedPrincipalID, terminalSessions: terminalSessions,
      requiresControlSession: requiresControlSession, remoteManagement: remoteManagement)
    return (inputs, gateway)
  }

  func prepareGateway(
    inputs: GatewayInputs, caller: GatewayCallerKind, profileID: GatewayProfileID,
    trustedPrincipalID: String?, terminalSessions: GatewayTerminalSessions,
    artifactStorage: PluginInstallationStorage?, requiresControlSession: Bool = false,
    remoteManagement: GatewayRemoteManagement? = nil
  ) async throws -> GatewayRuntimePreparation {
    var context = inputs.configuration.executionContext(caller: caller, profileID: profileID)
    context.trustedPrincipalID = trustedPrincipalID
    return try await GatewayRuntime.prepare(
      configuration: inputs.configuration, context: context, database: database,
      state: inputs.persisted,
      platform: platform, mcpClient: MCPProxyClient(secretStore: secretStore),
      bundledPlugins: bundledPlugins, terminalSessions: terminalSessions,
      artifactStorage: artifactStorage, requiresControlSession: requiresControlSession,
      remoteManagement: remoteManagement)
  }

  /// Values whose changes invalidate a pending catalog or session construction.
  struct GatewayInputs: Equatable, Sendable {
    let configuration: GatewayConfiguration
    let persisted: GatewayDatabase.ConfigurationState
    var projects: [RegisteredProject] { persisted.projects }
    var profiles: [ProfileGrant] { persisted.profiles }
    var plugins: PluginStoreSnapshot { persisted.plugins }
  }

  func gatewayInputs() throws -> GatewayInputs {
    try GatewayInputs(
      configuration: manifestStore.activeConfiguration(), persisted: database.configurationState())
  }

  func requireCurrentGatewayInputs(_ inputs: GatewayInputs) throws {
    try Task.checkCancellation()
    guard try gatewayInputs() == inputs else {
      throw AppControlPlaneServiceError.gatewayInputsChanged
    }
  }

  func makeGateway(
    inputs: GatewayInputs, caller: GatewayCallerKind, profileID: GatewayProfileID,
    transportTrace: GatewayTransportTrace? = nil, persistentState: Bool = true,
    trustedPrincipalID: String? = nil,
    terminalSessions: GatewayTerminalSessions = GatewayTerminalSessions(),
    requiresControlSession: Bool = false,
    remoteManagement: GatewayRemoteManagement? = nil
  ) async throws -> GatewayRuntime {
    try requireCurrentGatewayInputs(inputs)
    let database = persistentState ? database : nil
    let platform = platform
    let bundledPlugins = bundledPlugins
    let secretStore = secretStore
    let plugins: [ResolvedPlugin]? = try await gatewayOperations.perform {
      try persistentState
        ? nil
        : PluginHost.resolve(
          inputs.plugins, bundled: bundledPlugins, applications: platform.applications
        ).plugins
    }
    var context = inputs.configuration.executionContext(
      caller: caller, profileID: profileID, transportTrace: transportTrace)
    context.trustedPrincipalID = trustedPrincipalID
    let gateway = try await GatewayRuntime.make(
      configuration: inputs.configuration,
      context: context,
      database: database, registeredProjects: inputs.projects,
      platform: platform, mcpClient: MCPProxyClient(secretStore: secretStore),
      plugins: plugins, pluginState: inputs.plugins, bundledPlugins: bundledPlugins,
      terminalSessions: terminalSessions, requiresControlSession: requiresControlSession,
      remoteManagement: remoteManagement)
    do {
      try requireCurrentGatewayInputs(inputs)
      return gateway
    } catch {
      await gateway.shutdown()
      throw error
    }
  }

  package func configurationHistory(limit: Int = 50) throws -> [ConfigurationRevision] {
    try manifestStore.history(limit: limit)
  }

  @discardableResult
  package func refreshProviders() async throws -> [ProviderState] {
    try Task.checkCancellation()
    let configuration = try manifestStore.activeConfiguration()
    let discovery = providerDiscovery
    let results = try await providerProbeOperations.perform {
      try discovery.discover(configuration: configuration)
    }
    try Task.checkCancellation()
    guard try manifestStore.activeConfiguration() == configuration else {
      throw AtomicManifestStoreError.staleDigest
    }
    let states = results.map {
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
        gatewayExecutablePath: gatewayExecutablePath,
        gatewaySocketPath: directories.gatewaySocket.path,
        profileDirectory: definition.profileDirectory ?? directories.tunnelClientProfiles.path,
        tunnelClientPath: definition.tunnelClientPath,
        httpProxy: definition.httpProxy,
        apiKeyReference: apiKeyReference
      )
    }.sorted { $0.id < $1.id }
  }

  package func saveOpenAITunnelConfiguration(_ profile: OpenAITunnelConfiguration) async throws {
    var configuration = try manifestStore.activeConfiguration()
    let digest = try manifestStore.admittedDigest(for: configuration)
    await manifestStore.publicationLock.acquire()
    defer { manifestStore.publicationLock.release() }
    try Task.checkCancellation()
    try profile.validate()
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
    try activateTransportConfiguration(configuration, expectedDigest: digest)
  }

  package func deleteOpenAITunnelConfiguration(id: String) async throws {
    var configuration = try manifestStore.activeConfiguration()
    let digest = try manifestStore.admittedDigest(for: configuration)
    _ = try requireOpenAITunnelConfiguration(id)
    _ = try await openAITunnelSupervisor.stop(profileID: id)
    try setOpenAITunnelDesiredRunning(false, profileID: id)
    await manifestStore.publicationLock.acquire()
    defer { manifestStore.publicationLock.release() }
    try Task.checkCancellation()
    configuration.transports.openAI.removeAll { $0.id == id }
    try activateTransportConfiguration(configuration, expectedDigest: digest)
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
    try await validateOpenAITunnelSurface(profile)
    return try await openAITunnelSupervisor.provision(
      profile,
      configuration: manifestStore.activeConfiguration(),
      force: force
    )
  }

  package func doctorOpenAITunnel(profileID: String) async throws -> OpenAITunnelDoctorReport {
    let profile = try requireOpenAITunnelConfiguration(profileID)
    try await validateOpenAITunnelSurface(profile)
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
    try await validateOpenAITunnelSurface(profile)
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
    try await validateOpenAITunnelSurface(profile)
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
    guard let value = try database.runtimeSetting(key: Self.desiredOpenAITunnelsSettingKey) else {
      return []
    }
    do {
      return try GatewayDatabase.decodeDesiredOpenAITunnelConfigurationIDs(value)
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

  /// Caller holds the publication lock and supplies the digest of its merge base.
  func activateTransportConfiguration(_ configuration: GatewayConfiguration, expectedDigest: String)
    throws
  {
    try configuration.validate()
    _ = try manifestStore.commit(
      manifestStore.prepare(
        manifest: configuration.exportedTOML(), expectedDigest: expectedDigest))
  }

  private func validateOpenAITunnelSurface(_ profile: OpenAITunnelConfiguration) async throws {
    let inputs = try gatewayInputs()
    let gateway = try await makeGateway(
      inputs: inputs, caller: .secureTunnel, profileID: profile.gatewayProfile)
    do {
      _ = try ChatGPTProfileAuditor().audit(
        configuration: inputs.configuration, registry: gateway,
        allowWriteTools: profile.gatewayProfile == .chatGPTOperate)
      await gateway.shutdown()
      try requireCurrentGatewayInputs(inputs)
      guard try requireOpenAITunnelConfiguration(profile.id) == profile else {
        throw AppControlPlaneServiceError.gatewayInputsChanged
      }
    } catch {
      await gateway.shutdown()
      throw error
    }
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
    try await secretStore.containsAsynchronously(reference, authenticationUI: .fail)
  }

  func keychainSecretValue(for reference: SecretReference) async throws -> String? {
    try await secretStore.valueAsynchronously(for: reference, authenticationUI: .allow)
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

package enum AppControlPlaneServiceError: ControlErrorClassifying, LocalizedError, Equatable {
  case invalidDirectory(String)
  case symbolicLinkDirectory(String)
  case directoryOwnedByAnotherUser(String)
  case unknownOpenAITunnelConfiguration(String)
  case unknownGatewayProfile(String)
  case unknownProject(String)
  case projectMetadataConflict(
    projectID: String,
    existingDisplayName: String,
    requestedDisplayName: String
  )
  case invalidStoredProfile(String)
  case localAdminCannotBeSocketProfile
  case fullShellManifestDisabled
  case invalidDesiredOpenAITunnelState
  case gatewayInputsChanged

  package var controlAuditClassification: (decision: AuditDecision, code: String)? {
    guard case .localAdminCannotBeSocketProfile = self else { return nil }
    return (.denied, "policy.local_admin_remote")
  }

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
    case .unknownProject(let id):
      return "Unknown project: \(id)"
    case .projectMetadataConflict(
      let projectID,
      let existingDisplayName,
      let requestedDisplayName
    ):
      return
        "Project '\(projectID)' already registers this canonical root as '\(existingDisplayName)'; requested display name '\(requestedDisplayName)' conflicts."
    case .invalidStoredProfile(let id):
      return "The stored active gateway profile is invalid: \(id)"
    case .localAdminCannotBeSocketProfile:
      return "local-admin cannot be bound to the Tunnel-facing local socket."
    case .fullShellManifestDisabled:
      return "Enable policy.shell_enabled in the active manifest before enabling Full Shell."
    case .invalidDesiredOpenAITunnelState:
      return "The persisted Tunnel runtime state is invalid."
    case .gatewayInputsChanged:
      return
        "Gateway configuration, projects, profiles, or plugins changed during discovery. Refresh before trying again."
    }
  }
}
