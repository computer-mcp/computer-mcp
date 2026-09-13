import CryptoKit
import Foundation

package enum PluginStoreError: Error, Equatable, LocalizedError, Sendable {
  case staleRevision(expected: Int64, actual: Int64)
  case unknownInstallation(String)
  case invalidState
  case manifestChanged(String)
  case installationBusy

  package var errorDescription: String? {
    switch self {
    case .staleRevision: "Plugin settings changed. Reload before applying this change."
    case .unknownInstallation(let id): "Unknown plugin installation: \(id)."
    case .invalidState: "Plugin installation state is invalid."
    case .manifestChanged(let id):
      "Plugin '\(id)' changed on disk. Explicitly refresh its development registration before activation."
    case .installationBusy:
      "A plugin installation or recovery is still running. Retry when it finishes."
    }
  }
}

package struct PluginInstallationRecord: Codable, Equatable, Sendable, Identifiable {
  package let id: String
  package let pluginID: String
  package let version: PluginVersion
  package let source: PluginSource
  /// Fingerprint of the parsed declaration; not an artifact signature or package content hash.
  package let manifestDigest: String
  package let registeredAt: Date
}

package struct PluginStoreSnapshot: Codable, Equatable, Sendable {
  package var revision: Int64 = 0
  package var installations: [PluginInstallationRecord] = []
  package var selectedInstallations: [String: String] = [:]
  package var settings: [String: PluginSettings] = [:]

  package var knownMCPRegistrationIDs: Set<String> {
    Set(
      settings.flatMap { pluginID, settings in
        settings.mcp.map { componentID, choice in
          PluginResolver.registrationID(
            pluginID: pluginID, componentID: componentID, override: choice.registrationID)
        }
      })
  }

  func validate() throws {
    let byID = Dictionary(grouping: installations, by: \.id)
    guard revision >= 0, byID.values.allSatisfy({ $0.count == 1 }),
      installations.allSatisfy({
        !$0.id.isEmpty && !$0.id.contains("\0") && $0.source.root.isFileURL
          && $0.source.root.host.map({ $0.isEmpty || $0 == "localhost" }) != false
          && $0.source.root.query == nil && $0.source.root.fragment == nil
          && !$0.source.root.path.contains("\0")
          && $0.manifestDigest.utf8.count == 64
          && $0.manifestDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }
          )
      }),
      selectedInstallations.allSatisfy({ key, value in byID[value]?.first?.pluginID == key })
    else {
      throw PluginStoreError.invalidState
    }
    for id in installations.map(\.pluginID) + Array(settings.keys)
      + Array(selectedInstallations.keys)
    {
      try validatePluginID(id)
    }
    for choice in settings.values { try choice.validate() }
    for record in installations {
      if let release = record.source.githubRelease {
        try release.validate()
        guard record.source.kind == .artifact, record.pluginID == release.declaration.pluginID,
          record.version == release.declaration.version,
          record.source.repository == release.declaration.repositoryURL.absoluteString,
          record.source.revision == release.declaration.revision,
          record.source.artifactSHA256 == release.sha256
        else { throw PluginStoreError.invalidState }
      }
    }
  }
}

package struct PluginStoreIssue: Codable, Equatable, Sendable {
  package let pluginID: String
  package let message: String
}

/// A committed mutation can succeed while owned-file cleanup remains pending.
package struct PluginStoreMutation: Sendable {
  package let snapshot: PluginStoreSnapshot
  package let issues: [PluginStoreIssue]
}

struct PluginOwnedDirectory: Codable, Equatable, Sendable {
  let installationID: String
  let pluginID: String
  let identity: PluginDirectoryIdentity

  func validate() throws {
    try validatePluginID(pluginID)
    guard UUID(uuidString: installationID)?.uuidString == installationID,
      identity.url.lastPathComponent == installationID,
      identity.url.isFileURL, identity.url.query == nil, identity.url.fragment == nil,
      identity.url.host.map({ $0.isEmpty || $0 == "localhost" }) != false,
      !identity.url.path.contains("\0"), !identity.url.pathComponents.contains("..")
    else { throw PluginStoreError.invalidState }
  }
}

package struct PluginStoreResolution: Sendable {
  package let revision: Int64
  package let plugins: [ResolvedPlugin]
  package let issues: [PluginStoreIssue]
}

/// Host-owned state changes are synchronous database transactions inside this actor.
/// Revision comparison in the database also protects against other store instances/processes.
package actor PluginStore {
  let database: GatewayDatabase
  private let validateSnapshot: @Sendable (PluginStoreSnapshot) throws -> Void

  package init(
    database: GatewayDatabase,
    validateSnapshot: @escaping @Sendable (PluginStoreSnapshot) throws -> Void = { _ in }
  ) {
    self.database = database
    self.validateSnapshot = validateSnapshot
  }

  package func snapshot() throws -> PluginStoreSnapshot { try database.pluginStoreSnapshot() }

  @discardableResult
  package func registerDevelopment(at root: URL, expectedRevision: Int64) throws
    -> PluginStoreSnapshot
  {
    let plugin = try PluginPackage.load(at: root)
    let digest = try Self.manifestDigest(plugin.manifest)
    var state = try checkedSnapshot(expectedRevision)
    let existing = state.installations.first {
      $0.pluginID == plugin.manifest.id && $0.source.kind == .development
        && $0.source.root == plugin.root && $0.manifestDigest == digest
    }
    let record =
      existing
      ?? PluginInstallationRecord(
        id: UUID().uuidString,
        pluginID: plugin.manifest.id, version: plugin.manifest.version,
        source: PluginSource(kind: .development, root: plugin.root), manifestDigest: digest,
        registeredAt: .now)
    if existing == nil { state.installations.append(record) }
    state.selectedInstallations[record.pluginID] = record.id
    Self.addMissingSettings(for: plugin.manifest, to: &state)
    return try commit(state, expectedRevision: expectedRevision)
  }

  static func addMissingSettings(for manifest: PluginManifest, to state: inout PluginStoreSnapshot)
  {
    var settings = state.settings[manifest.id] ?? PluginSettings()
    for contribution in manifest.mcp where settings.mcp[contribution.id] == nil {
      settings.mcp[contribution.id] = PluginMCPSettings()
    }
    for contribution in manifest.cli where settings.cli[contribution.id] == nil {
      settings.cli[contribution.id] = PluginCLISettings()
    }
    for contribution in manifest.skills where settings.skills[contribution.id] == nil {
      settings.skills[contribution.id] = PluginSkillSettings()
    }
    state.settings[manifest.id] = settings
  }

  @discardableResult
  package func setSettings(
    _ settings: PluginSettings, for pluginID: String, expectedRevision: Int64
  )
    throws -> PluginStoreSnapshot
  {
    try validatePluginID(pluginID)
    var state = try checkedSnapshot(expectedRevision)
    state.settings[pluginID] = settings
    return try commit(state, expectedRevision: expectedRevision)
  }

  @discardableResult
  package func setEnabled(_ enabled: Bool, for pluginID: String, expectedRevision: Int64)
    throws -> PluginStoreSnapshot
  {
    try validatePluginID(pluginID)
    var state = try checkedSnapshot(expectedRevision)
    state.settings[pluginID, default: PluginSettings()].enabled = enabled
    return try commit(state, expectedRevision: expectedRevision)
  }

  /// A nil selection restores bundled fallback; it does not alter the user's enabled state or grants.
  @discardableResult
  package func select(installationID: String?, for pluginID: String, expectedRevision: Int64)
    throws -> PluginStoreSnapshot
  {
    try validatePluginID(pluginID)
    var state = try checkedSnapshot(expectedRevision)
    if let installationID {
      guard
        state.installations.contains(where: { $0.id == installationID && $0.pluginID == pluginID })
      else {
        throw PluginStoreError.unknownInstallation(installationID)
      }
    }
    state.selectedInstallations[pluginID] = installationID
    return try commit(state, expectedRevision: expectedRevision)
  }

  /// Remove an installation reference, never the user-owned development checkout or external binaries.
  @discardableResult
  package func removeDevelopment(installationID: String, expectedRevision: Int64) throws
    -> PluginStoreSnapshot
  {
    var state = try checkedSnapshot(expectedRevision)
    guard let record = state.installations.first(where: { $0.id == installationID }),
      record.source.kind == .development
    else {
      throw PluginStoreError.unknownInstallation(installationID)
    }
    state.installations.removeAll { $0.id == installationID }
    if state.selectedInstallations[record.pluginID] == installationID {
      state.selectedInstallations.removeValue(forKey: record.pluginID)
    }
    return try commit(state, expectedRevision: expectedRevision)
  }

  package func resolve(
    bundled: [PluginPackage] = [],
    dependencyExecutables: [String: [String: URL]] = [:],
    hostVersion: PluginVersion,
    architecture: String
  ) throws -> PluginStoreResolution {
    let state = try snapshot()
    return try Self.resolve(
      snapshot: state, bundled: bundled, dependencyExecutables: dependencyExecutables,
      hostVersion: hostVersion, architecture: architecture)
  }

  package static func resolve(
    snapshot state: PluginStoreSnapshot,
    bundled: [PluginPackage] = [],
    dependencyExecutables: [String: [String: URL]] = [:],
    hostVersion: PluginVersion,
    architecture: String,
    searchDirectories: [URL] = [],
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> PluginStoreResolution {
    try state.validate()
    let byID = Dictionary(grouping: bundled, by: { $0.manifest.id })
    guard byID.values.allSatisfy({ $0.count == 1 }) else {
      throw ConfigurationError.invalid("Multiple bundled sources have the same plugin ID.")
    }
    let ids = Set(byID.keys).union(state.selectedInstallations.keys).union(state.settings.keys)
      .sorted()
    var plugins: [ResolvedPlugin] = []
    var issues: [PluginStoreIssue] = []
    for id in ids {
      let settings = state.settings[id] ?? PluginSettings()
      guard settings.enabled else { continue }
      do {
        guard let (plugin, source) = try selectedPackage(id, in: state, bundled: bundled) else {
          issues.append(
            PluginStoreIssue(
              pluginID: id,
              message: "No selected or bundled source is available for this enabled plugin."))
          continue
        }
        let bindings = dependencyBindings(
          for: plugin, settings: settings, overrides: dependencyExecutables[id] ?? [:],
          searchDirectories: searchDirectories)
        plugins.append(
          try PluginResolver.resolve(
            package: plugin, source: source, settings: settings,
            dependencyExecutables: bindings, hostVersion: hostVersion,
            architecture: architecture, environment: environment))
      } catch {
        // A selected source failure is visible; it does not silently activate another version.
        issues.append(PluginStoreIssue(pluginID: id, message: error.localizedDescription))
      }
    }
    return PluginStoreResolution(revision: state.revision, plugins: plugins, issues: issues)
  }

  /// Source precedence and declaration identity are shared by activation and non-activating diagnostics.
  static func selectedPackage(
    _ id: String, in state: PluginStoreSnapshot, bundled: [PluginPackage]
  ) throws -> (PluginPackage, PluginSource)? {
    if let selected = state.selectedInstallations[id] {
      guard let record = state.installations.first(where: { $0.id == selected }) else {
        throw PluginStoreError.unknownInstallation(selected)
      }
      let plugin = try PluginPackage.load(at: record.source.root)
      guard plugin.manifest.id == record.pluginID, plugin.manifest.version == record.version,
        try manifestDigest(plugin.manifest) == record.manifestDigest
      else { throw PluginStoreError.manifestChanged(id) }
      return (plugin, record.source)
    }
    let candidates = bundled.filter { $0.manifest.id == id }
    guard candidates.count <= 1 else {
      throw ConfigurationError.invalid("Multiple bundled sources have the same plugin ID.")
    }
    guard let fallback = candidates.first else { return nil }
    let plugin = try PluginPackage.load(at: fallback.root)
    guard plugin.manifest == fallback.manifest else {
      throw PluginManifestError.invalid(
        "Bundled declaration does not match the loaded App inventory. Verify the App installation.")
    }
    return (plugin, PluginSource(kind: .bundled, root: plugin.root))
  }

  static func dependencyBindings(
    for plugin: PluginPackage, settings: PluginSettings, overrides: [String: URL] = [:],
    searchDirectories: [URL]
  ) -> [String: URL] {
    PluginDependencyResolver.resolve(
      for: plugin, settings: settings, overrides: overrides, searchDirectories: searchDirectories
    ).mapValues(\.executable)
  }

  func checkedSnapshot(_ expected: Int64) throws -> PluginStoreSnapshot {
    let state = try snapshot()
    guard state.revision == expected else {
      throw PluginStoreError.staleRevision(expected: expected, actual: state.revision)
    }
    return state
  }

  func commit(_ proposed: PluginStoreSnapshot, expectedRevision: Int64) throws
    -> PluginStoreSnapshot
  {
    var next = proposed
    guard expectedRevision >= 0, expectedRevision < Int64.max else {
      throw PluginStoreError.invalidState
    }
    next.revision = expectedRevision + 1
    try next.validate()
    try validateSnapshot(next)
    try database.savePluginStoreSnapshot(next, expectedRevision: expectedRevision)
    return next
  }

  static func manifestDigest(_ manifest: PluginManifest) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return SHA256.hash(data: try encoder.encode(manifest)).map { String(format: "%02x", $0) }
      .joined()
  }
}
