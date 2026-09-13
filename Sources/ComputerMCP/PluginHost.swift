import Foundation

/// The host resolves registrations using its launch environment, without changing PATH or installing dependencies.
package enum PluginHost {
  package static var architecture: String {
    #if arch(arm64)
      "arm64"
    #else
      "x86_64"
    #endif
  }

  package static func resolve(_ state: PluginStoreSnapshot, bundled: BundledPlugins = .current)
    throws -> PluginStoreResolution
  {
    let resolution = try PluginStore.resolve(
      snapshot: state.includingBundledDefaults(bundled.packages.map(\.manifest)),
      bundled: bundled.packages,
      hostVersion: PluginVersion(ComputerMCPCLI.version), architecture: architecture,
      searchDirectories: searchDirectories(environment: ProcessInfo.processInfo.environment))
    return PluginStoreResolution(
      revision: resolution.revision, plugins: resolution.plugins,
      issues: bundled.issues + resolution.issues)
  }

  static func searchDirectories(environment: [String: String]) -> [URL] {
    (environment["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }
      .map { URL(fileURLWithPath: String($0), isDirectory: true) }
  }
}

package struct PluginHostSnapshot: Codable, Sendable {
  package let state: PluginStoreSnapshot
  package let bundled: [BundledPluginDescription]
  /// Read-only host defaults merged with saved overrides; `state` remains the exact persisted snapshot.
  package let effectiveSettings: [String: PluginSettings]
  package let contributions: [PluginContributionOrigin]
  package let diagnostics: [PluginResolutionDiagnostic]
  package let issues: [PluginStoreIssue]
  /// A store-wide recovery failure, independent of any one plugin's resolution.
  package let recoveryError: String?

  package init(
    state: PluginStoreSnapshot, issues: [PluginStoreIssue] = [], recoveryError: String? = nil,
    bundled: BundledPlugins = .current
  ) throws {
    let resolution = try PluginHost.resolve(state, bundled: bundled)
    self.state = state
    self.bundled = bundled.packages.map {
      BundledPluginDescription(root: $0.root, manifest: $0.manifest)
    }
    effectiveSettings = state.includingBundledDefaults(bundled.packages.map(\.manifest)).settings
    contributions = resolution.plugins.flatMap { $0.origins.values }.sorted {
      ($0.pluginID, $0.componentID) < ($1.pluginID, $1.componentID)
    }
    diagnostics = resolution.plugins.flatMap(\.diagnostics)
    self.issues = resolution.issues + issues.filter { !resolution.issues.contains($0) }
    self.recoveryError = recoveryError
  }

  package func settings(for pluginID: String) -> PluginSettings {
    effectiveSettings[pluginID] ?? PluginSettings()
  }

  init(filtering snapshot: Self, pluginID: String) {
    var state = snapshot.state
    state.installations.removeAll { $0.pluginID != pluginID }
    state.selectedInstallations = state.selectedInstallations.filter { $0.key == pluginID }
    state.settings = state.settings.filter { $0.key == pluginID }
    self.state = state
    bundled = snapshot.bundled.filter { $0.manifest.id == pluginID }
    effectiveSettings = snapshot.effectiveSettings.filter { $0.key == pluginID }
    contributions = snapshot.contributions.filter { $0.pluginID == pluginID }
    diagnostics = snapshot.diagnostics.filter { $0.pluginID == pluginID }
    issues = snapshot.issues.filter { $0.pluginID == pluginID }
    recoveryError = snapshot.recoveryError
  }
}

package enum PluginHostChange: Sendable {
  case registerDevelopment(URL)
  case settings(pluginID: String, PluginSettings)
  case enabled(pluginID: String, Bool)
  case select(pluginID: String, installationID: String?)
  case removeDevelopment(installationID: String)
  case installArchive(archive: URL, sha256: String, pluginID: String, version: PluginVersion)
  case installRelease(GitHubPluginArtifact)
  case uninstallArtifact(installationID: String)
  case recover
}

package enum PluginHostError: Error, LocalizedError, Equatable, Sendable {
  case changeInProgress
  case connectedClients
  case invalidComposition(String)
  case workerUnavailable

  package var errorDescription: String? {
    switch self {
    case .changeInProgress:
      "Another gateway configuration change is in progress. Retry after it finishes."
    case .connectedClients:
      "Gateway clients are connected or connecting. Disconnect them before changing plugin registrations; active tasks were not interrupted."
    case .invalidComposition(let message): "Plugin configuration was not changed: \(message)"
    case .workerUnavailable:
      "The App's embedded plugin archive worker is unavailable. Check the App installation; no PATH executable was used."
    }
  }
}
