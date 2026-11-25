import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPGateway
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPPlugins
import Foundation

extension AppControlPlaneService {
  package func providerReview(_ identity: PluginIdentity) throws -> GatewayProviderReview {
    let configuration = try database.configurationState()
    let active = try manifestStore.activeConfiguration()
    let pluginIDs = Set(bundledPlugins.packages.map { $0.manifest.id })
    let serverIDs = Set(active.mcp.servers.map(\.id))
    switch identity {
    case .package(let id):
      let package = try providerPackage(id, configuration: configuration)
      guard package.manifest.id == id else { throw GatewayPermissionError.invalidBinding }
      return try GatewayProviderReview(
        package: package, configuration: configuration,
        knownPluginIDs: pluginIDs, knownServerIDs: serverIDs)
    case .localServer(let id):
      guard let server = active.mcp.servers.first(where: { $0.id == id }) else {
        throw GatewayPermissionError.invalidBinding
      }
      return try GatewayProviderReview(
        server: server, configuration: configuration,
        knownPluginIDs: pluginIDs, knownServerIDs: serverIDs)
    }
  }

  func providerPackage(_ id: String, configuration: GatewayDatabase.ConfigurationState) throws
    -> PluginPackage
  {
    guard
      let (package, _) = try PluginStore.selectedPackage(
        id, in: configuration.plugins, bundled: bundledPlugins.packages)
    else { throw GatewayPermissionError.invalidBinding }
    return package
  }

  package func reviewPluginEnablement(_ change: PluginHostChange, expectedRevision: Int64)
    throws -> ProviderEnablementReview?
  {
    guard !configurationMutationInProgress else { throw PluginHostError.changeInProgress }
    let inputs = try gatewayInputs()
    guard inputs.plugins.revision == expectedRevision else {
      throw PluginStoreError.staleRevision(
        expected: expectedRevision, actual: inputs.plugins.revision)
    }
    guard let target = try pluginEnablementTarget(change, in: inputs.plugins) else { return nil }
    let package = try providerPackage(target.id, configuration: inputs.persisted)
    guard package.manifest.id == target.id else { throw GatewayPermissionError.invalidBinding }
    if let refusal = package.manifest.refusal(
      host: try PluginVersion(ComputerMCPCLI.version), architecture: PluginHost.architecture)
    {
      throw refusal
    }
    let source = try GatewayProviderReview(
      package: package, configuration: inputs.persisted,
      knownPluginIDs: Set(bundledPlugins.packages.map { $0.manifest.id }),
      knownServerIDs: Set(inputs.configuration.mcp.servers.map(\.id)))
    return try enablementReview(
      source: source, name: package.manifest.name, version: package.manifest.version.description,
      inputs: inputs, mcpContributionIDs: package.manifest.mcp.map(\.id),
      target: .plugin(
        expectedRevision: expectedRevision, settings: target.settings,
        manifestDigest: try manifestStore.admittedDigest(for: inputs.configuration)))
  }

  private func pluginEnablementTarget(
    _ change: PluginHostChange, in state: PluginStoreSnapshot
  ) throws -> (id: String, settings: PluginSettings?)? {
    let id: String
    let settings: PluginSettings?
    switch change {
    case .enabled(let pluginID, true):
      id = pluginID
      settings = nil
    case .settings(let pluginID, let proposed)
    where proposed.enabled:
      id = pluginID
      settings = proposed
    default:
      return nil
    }
    guard
      state.selectedInstallations[id] != nil
        || bundledPlugins.packages.contains(where: { $0.manifest.id == id })
    else { return nil }
    if settings != nil, state.settings[id]?.enabled == true,
      try !database.pendingPluginSourceReviews(in: state).contains(id)
    {
      return nil
    }
    return (id, settings)
  }

  package func approveProvider(
    _ review: GatewayProviderReview, permissions: Permissions, fullAccess: Bool,
    sandboxSettings: ProviderSandboxSettings = .init(),
    expectedProviderRevision: Int64?, expectedRevision: UInt64, expectedEpoch: UUID,
    editingApproval: Bool = false, reviewedLimits: ManagedLimits? = nil
  ) async throws -> GatewayProviderApproval {
    if !editingApproval, case .package = review.identity {
      throw ProviderEnablementError.reviewRequired
    }
    guard !configurationMutationInProgress else { throw PluginHostError.changeInProgress }
    configurationMutationInProgress = true
    defer { configurationMutationInProgress = false }
    await manifestStore.publicationLock.acquire()
    defer { manifestStore.publicationLock.release() }
    try Task.checkCancellation()
    guard (try? providerReview(review.identity)) == review else {
      throw GatewayPermissionError.revisionConflict
    }
    let configuration = try manifestStore.activeConfiguration()
    do {
      return try manifestStore.withCurrentConfiguration(configuration) {
        try requirePermissionControl().approveProvider(
          review, permissions: permissions, fullAccess: fullAccess,
          sandboxSettings: sandboxSettings,
          expectedProviderRevision: expectedProviderRevision, expectedRevision: expectedRevision,
          expectedEpoch: expectedEpoch, editingApproval: editingApproval,
          reviewedLimits: reviewedLimits)
      }
    } catch AtomicManifestStoreError.staleDigest {
      throw GatewayPermissionError.revisionConflict
    }
  }

  package func doctorPlugin(id: String) throws -> PluginDoctorReport {
    try PluginDoctorReport.inspect(
      pluginID: id, state: database.pluginStoreSnapshot(), bundled: bundledPlugins,
      hostVersion: PluginVersion(ComputerMCPCLI.version), architecture: PluginHost.architecture,
      applications: platform.applications)
  }

  package func pluginReleaseArtifacts(
    repository: String, repositoryID: Int64, tag: String?, page: Int
  ) async throws -> GitHubPluginReleaseArtifacts {
    try await pluginCatalog.artifacts(
      repository: repository, repositoryID: repositoryID, tag: tag, page: page)
  }

  package func searchPlugins(query: String, kind: IntegrationKind?, page: Int, refresh: Bool)
    async throws
    -> PluginCatalogSearchResult
  {
    try await pluginCatalog.search(query: query, kind: kind, page: page, refresh: refresh)
  }

  package func pluginSnapshot(includingSourceReviews: Bool = false) throws -> PluginHostSnapshot {
    try pluginSnapshot(
      database.pluginStoreSnapshot(), includingSourceReviews: includingSourceReviews)
  }

  private func pluginSnapshot(
    _ state: PluginStoreSnapshot, includingSourceReviews: Bool
  ) throws -> PluginHostSnapshot {
    var snapshot = try PluginHostSnapshot(
      state: state, issues: pluginRecoveryIssues, recoveryError: pluginRecoveryError,
      bundled: bundledPlugins, applications: platform.applications)
    if includingSourceReviews {
      snapshot.pendingSourceReviews = try database.pendingPluginSourceReviews(in: state)
    }
    return snapshot
  }

  /// Run after the App has claimed its control socket, before admitting gateway clients.
  /// Busy or damaged storage is reported without stopping unrelated integrations.
  package func recoverPluginsAtStartup() async throws {
    guard !configurationMutationInProgress else { throw PluginHostError.changeInProgress }
    guard !pluginRecoveryAttempted else { return }
    pluginRecoveryAttempted = true
    configurationMutationInProgress = true
    defer { configurationMutationInProgress = false }
    await manifestStore.publicationLock.acquire()
    defer { manifestStore.publicationLock.release() }
    try Task.checkCancellation()
    try? await recoverPluginFiles(using: PluginStore(database: database, platform: platform))
  }

  private func recoverPluginFiles(using store: PluginStore, expectedRevision: Int64? = nil)
    async throws
  {
    do {
      pluginRecoveryIssues = try await store.recoverInstallations(
        storageRoot: directories.plugins, expectedRevision: expectedRevision)
      pluginRecoveryError = nil
    } catch {
      if case .staleRevision = error as? PluginStoreError { throw error }
      pluginRecoveryError =
        error as? PluginStoreError == .installationBusy
        ? PluginStoreError.installationBusy.errorDescription
        : "Plugin file recovery could not finish. Check the App-owned storage and retry recovery."
      throw error
    }
  }

  package func parseManifest(_ text: String) throws -> GatewayConfiguration {
    let state = try database.pluginStoreSnapshot()
      .includingBundledDefaults(bundledPlugins.packages.map(\.manifest))
    let configuration = try GatewayConfiguration.load(
      text: text, baseURL: directories.configuration,
      knownPluginMCPServerIDs: state.knownMCPRegistrationIDs)
    _ = try GatewayPluginComposition(
      configuration: configuration,
      plugins: PluginHost.resolve(
        state, bundled: bundledPlugins, applications: platform.applications
      ).plugins)
    return configuration
  }

  /// The publisher prepares contributions and commits while holding listener admission.
  func applyPluginChange(
    _ change: PluginHostChange, expectedRevision: Int64,
    approval: ProviderEnablementApproval? = nil, remoteManagement: Bool = false,
    publish: (
      @Sendable (
        GatewayInputs, PluginStoreSnapshot, PluginInstallationStorage?, GatewayProviderActivation?
      ) async throws -> Void
    )? = nil
  ) async throws
    -> PluginHostSnapshot
  {
    guard !configurationMutationInProgress else { throw PluginHostError.changeInProgress }
    configurationMutationInProgress = true
    defer { configurationMutationInProgress = false }
    await manifestStore.publicationLock.acquire()
    defer { manifestStore.publicationLock.release() }
    try Task.checkCancellation()
    let inputs = try gatewayInputs()
    guard inputs.plugins.revision == expectedRevision else {
      throw PluginStoreError.staleRevision(
        expected: expectedRevision, actual: inputs.plugins.revision)
    }
    let activation: GatewayProviderActivation?
    if !remoteManagement, let target = try pluginEnablementTarget(change, in: inputs.plugins) {
      guard let approval else {
        let package = try providerPackage(target.id, configuration: inputs.persisted)
        if let refusal = package.manifest.refusal(
          host: try PluginVersion(ComputerMCPCLI.version), architecture: PluginHost.architecture)
        {
          throw refusal
        }
        throw ProviderEnablementError.reviewRequired
      }
      guard publish != nil,
        approval.target
          == .plugin(
            expectedRevision: expectedRevision, settings: target.settings,
            manifestDigest: try manifestStore.admittedDigest(for: inputs.configuration)),
        approval.provider.identity == .package(target.id),
        let source = approval.provider.sourceReview,
        source == (try? providerReview(.package(target.id)))
      else { throw GatewayPermissionError.revisionConflict }
      activation = try requirePermissionControl().prepareProviderActivation(approval)
    } else {
      guard approval == nil else { throw GatewayPermissionError.revisionConflict }
      activation = nil
    }
    let manifestStore = manifestStore
    let bundledPlugins = bundledPlugins
    let platform = platform
    let publication: GatewayPluginStateStore.PublishSnapshot?
    if let publish {
      publication = { proposed, expected, storage in
        guard expected == inputs.persisted else { throw GatewayDatabaseError.configurationChanged }
        try await publish(inputs, proposed, storage, activation)
      }
    } else {
      publication = nil
    }
    let store = PluginStore(
      database: database, platform: platform, expectedConfiguration: inputs.persisted,
      publishSnapshot: publication
    ) { proposed in
      var configuration = try manifestStore.activeConfiguration()
      configuration.knownPluginMCPServerIDs =
        proposed
        .includingBundledDefaults(bundledPlugins.packages.map(\.manifest)).knownMCPRegistrationIDs
      let resolution = try PluginHost.resolve(
        proposed, bundled: bundledPlugins, applications: platform.applications)
      _ = try GatewayPluginComposition(configuration: configuration, plugins: resolution.plugins)
      // Source failures are diagnosable independently; a newly selected broken source must not be committed.
      if let affected = Self.affectedPluginID(change, in: proposed),
        let issue = resolution.issues.first(where: { $0.pluginID == affected }),
        proposed.selectedInstallations[affected] != nil
      {
        if let refusal = issue.refusal { throw refusal }
        throw PluginHostError.invalidComposition(issue.message)
      }
      if let affected = Self.affectedPluginID(change, in: proposed),
        let refusal = resolution.plugins.flatMap(\.diagnostics)
          .first(where: { $0.pluginID == affected && $0.refusal != nil })?.refusal
      {
        throw refusal
      }
      if let approval, case .package(let id) = approval.provider.identity,
        !resolution.plugins.contains(where: { $0.id == id })
      {
        throw PluginHostError.invalidComposition(
          resolution.issues.first { $0.pluginID == id }?.message
            ?? "The reviewed source is unavailable.")
      }
      try configuration.validate()
    }
    let state: PluginStoreSnapshot
    var issues: [PluginStoreIssue] = []
    switch change {
    case .registerDevelopment(let root):
      state = try await store.registerDevelopment(at: root, expectedRevision: expectedRevision)
    case .settings(let id, let settings):
      state = try await store.setSettings(settings, for: id, expectedRevision: expectedRevision)
    case .enabled(let id, let enabled):
      state = try await store.setEnabled(enabled, for: id, expectedRevision: expectedRevision)
    case .select(let id, let installationID):
      state = try await store.select(
        installationID: installationID, for: id, expectedRevision: expectedRevision)
    case .removeDevelopment(let id):
      state = try await store.removeDevelopment(
        installationID: id, expectedRevision: expectedRevision)
    case .installArchive(let archive, let sha256, let id, let version):
      let mutation = try await store.installArchive(
        at: archive, expectedSHA256: sha256, pluginID: id, version: version,
        hostVersion: PluginVersion(ComputerMCPCLI.version), architecture: PluginHost.architecture,
        storageRoot: directories.plugins,
        workerExecutable: pluginArchiveWorker(),
        expectedRevision: expectedRevision)
      state = mutation.snapshot
      issues = mutation.issues
    case .installRelease(let artifact):
      let mutation = try await store.installGitHubArtifact(
        artifact, hostVersion: PluginVersion(ComputerMCPCLI.version),
        architecture: PluginHost.architecture, storageRoot: directories.plugins,
        workerExecutable: pluginArchiveWorker(), expectedRevision: expectedRevision,
        releases: pluginReleases, download: pluginDownload)
      state = mutation.snapshot
      issues = mutation.issues
    case .uninstallArtifact(let id):
      let mutation = try await store.uninstallArtifact(
        installationID: id, storageRoot: directories.plugins, expectedRevision: expectedRevision)
      state = mutation.snapshot
      issues = mutation.issues
    case .recover:
      try await recoverPluginFiles(using: store, expectedRevision: expectedRevision)
      state = try await store.snapshot()
    }
    for issue in issues where !pluginRecoveryIssues.contains(issue) {
      pluginRecoveryIssues.append(issue)
    }
    return try pluginSnapshot(state, includingSourceReviews: !remoteManagement)
  }

  private func pluginArchiveWorker() throws -> URL {
    guard gatewayExecutablePath.hasPrefix("/"), !gatewayExecutablePath.contains("\0"),
      FileManager.default.isExecutableFile(atPath: gatewayExecutablePath)
    else { throw PluginHostError.workerUnavailable }
    return URL(fileURLWithPath: gatewayExecutablePath)
  }

  private nonisolated static func affectedPluginID(
    _ change: PluginHostChange, in state: PluginStoreSnapshot
  ) -> String? {
    switch change {
    case .enabled(let id, _), .settings(let id, _), .select(let id, _): id
    case .registerDevelopment(let root):
      state.installations.first {
        $0.source.root == root.resolvingSymlinksInPath().standardizedFileURL
      }?.pluginID
    case .installArchive(_, _, let id, _): id
    case .installRelease(let artifact): artifact.declaration.pluginID
    case .removeDevelopment, .uninstallArtifact, .recover: nil
    }
  }
}
