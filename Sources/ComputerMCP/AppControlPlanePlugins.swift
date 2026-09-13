import Foundation

extension AppControlPlaneService {
  package func doctorPlugin(id: String) throws -> PluginDoctorReport {
    try PluginDoctorReport.inspect(
      pluginID: id, state: database.pluginStoreSnapshot(), bundled: bundledPlugins,
      hostVersion: PluginVersion(ComputerMCPCLI.version), architecture: PluginHost.architecture)
  }

  package func pluginReleaseArtifacts(
    repository: String, repositoryID: Int64, tag: String?, page: Int
  ) async throws -> GitHubPluginReleaseArtifacts {
    try await pluginReleases.artifacts(
      repository: repository, repositoryID: repositoryID, tag: tag, page: page)
  }

  package func searchPlugins(query: String, kind: IntegrationKind?, page: Int, refresh: Bool)
    async throws
    -> PluginCatalogSearchResult
  {
    try await pluginCatalog.search(query: query, kind: kind, page: page, refresh: refresh)
  }

  package func pluginSnapshot() throws -> PluginHostSnapshot {
    try PluginHostSnapshot(
      state: database.pluginStoreSnapshot(), issues: pluginRecoveryIssues,
      recoveryError: pluginRecoveryError, bundled: bundledPlugins)
  }

  /// Run after the App has claimed its control socket, before admitting gateway clients.
  /// Busy or damaged storage is reported without stopping unrelated integrations.
  package func recoverPluginsAtStartup() async throws {
    guard !pluginMutationInProgress else { throw PluginHostError.changeInProgress }
    guard !pluginRecoveryAttempted else { return }
    pluginRecoveryAttempted = true
    pluginMutationInProgress = true
    defer { pluginMutationInProgress = false }
    try? await recoverPluginFiles(using: PluginStore(database: database))
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
      plugins: PluginHost.resolve(state, bundled: bundledPlugins).plugins)
    return configuration
  }

  /// Configuration preflight precedes the database CAS. Only artifact installation
  /// launches the host's bounded archive worker; contributions are never executed here.
  func applyPluginChange(_ change: PluginHostChange, expectedRevision: Int64) async throws
    -> PluginHostSnapshot
  {
    guard !pluginMutationInProgress else { throw PluginHostError.changeInProgress }
    pluginMutationInProgress = true
    defer { pluginMutationInProgress = false }
    let manifestStore = manifestStore
    let bundledPlugins = bundledPlugins
    let store = PluginStore(database: database) { proposed in
      var configuration = try manifestStore.activeConfiguration()
      configuration.knownPluginMCPServerIDs =
        proposed
        .includingBundledDefaults(bundledPlugins.packages.map(\.manifest)).knownMCPRegistrationIDs
      let resolution = try PluginHost.resolve(proposed, bundled: bundledPlugins)
      _ = try GatewayPluginComposition(configuration: configuration, plugins: resolution.plugins)
      // Source failures are diagnosable independently; a newly selected broken source must not be committed.
      if let affected = Self.affectedPluginID(change, in: proposed),
        let issue = resolution.issues.first(where: { $0.pluginID == affected }),
        proposed.selectedInstallations[affected] != nil
      {
        throw PluginHostError.invalidComposition(issue.message)
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
    return try PluginHostSnapshot(
      state: state, issues: pluginRecoveryIssues, recoveryError: pluginRecoveryError,
      bundled: bundledPlugins)
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
