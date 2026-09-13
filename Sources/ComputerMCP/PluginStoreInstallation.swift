import CryptoKit
import Darwin
import Foundation

extension PluginStore {
  /// The host must quiesce affected runtimes before changing their selected files.
  /// New installs start disabled; updates retain host choices and earlier versions.
  /// `workerExecutable` is the trusted host CLI, never supplied by the plugin.
  package func installArchive(
    at archive: URL, expectedSHA256: String, pluginID: String, version: PluginVersion,
    hostVersion: PluginVersion, architecture: String, storageRoot: URL,
    workerExecutable: URL, expectedRevision: Int64
  ) async throws -> PluginStoreMutation {
    try await installArchive(
      expectedSHA256: expectedSHA256, pluginID: pluginID, version: version,
      hostVersion: hostVersion, architecture: architecture, storageRoot: storageRoot,
      workerExecutable: workerExecutable, expectedRevision: expectedRevision,
      prepareArchive: { _ in archive })
  }

  func installGitHubArtifact(
    _ artifact: GitHubPluginArtifact,
    hostVersion: PluginVersion, architecture: String, storageRoot: URL,
    workerExecutable: URL, expectedRevision: Int64,
    releases: GitHubPluginReleases = GitHubPluginReleases(),
    download: GitHubPluginDownload = GitHubPluginDownload()
  ) async throws -> PluginStoreMutation {
    try artifact.validate()
    return try await installArchive(
      expectedSHA256: artifact.sha256, pluginID: artifact.declaration.pluginID,
      version: artifact.declaration.version, hostVersion: hostVersion, architecture: architecture,
      storageRoot: storageRoot, workerExecutable: workerExecutable,
      expectedRevision: expectedRevision,
      githubRelease: artifact,
      prepareArchive: { identity in
        try await releases.revalidate(artifact)
        let directory = try PluginArchiveDirectory(recovering: identity)
        var descriptor: Int32 = -1
        defer { if descriptor >= 0 { Darwin.close(descriptor) } }
        try directory.createFile(["staging", "download"], executable: false) { file in
          descriptor = fcntl(file, F_DUPFD_CLOEXEC, 0)
          guard descriptor >= 0 else { throw PluginArchiveError.fileSystemFailure }
        }
        try await download.download(artifact, to: descriptor)
        try directory.finish()
        return directory.url.appendingPathComponent("staging/download")
      },
      verifyPackage: { package in
        let bytes = try PluginPackageFiles(root: package.root).read(
          PluginManifest.filename, maximumBytes: 1_048_576)
        guard
          SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined()
            == artifact.declaration.manifestSHA256
        else {
          throw PluginCatalogError.invalidProvenance
        }
        try await releases.revalidate(artifact)
      })
  }

  private func installArchive(
    expectedSHA256: String, pluginID: String, version: PluginVersion,
    hostVersion: PluginVersion, architecture: String, storageRoot: URL,
    workerExecutable: URL, expectedRevision: Int64, githubRelease: GitHubPluginArtifact? = nil,
    prepareArchive: @escaping @Sendable (PluginDirectoryIdentity) async throws -> URL,
    verifyPackage: @escaping @Sendable (PluginPackage) async throws -> Void = { _ in }
  ) async throws -> PluginStoreMutation {
    try Task.checkCancellation()
    try validatePluginID(pluginID)
    try PluginArchiveSnapshot.validateDigest(expectedSHA256)
    _ = try checkedSnapshot(expectedRevision)
    let storage = try PluginInstallationStorage(at: storageRoot)
    defer { storage.finishTransaction() }
    let identity = try storage.createInstallation()
    let owned = PluginOwnedDirectory(
      installationID: identity.url.lastPathComponent, pluginID: pluginID, identity: identity)
    do {
      try database.recordPluginDirectory(owned)
    } catch {
      try storage.clean(identity, keepingPackage: false)
      throw error
    }
    let preparation = PluginArchivePreparation(
      workerExecutable: workerExecutable,
      stagingParent: identity.url.appendingPathComponent("staging"),
      inheritedLockDescriptor: storage.lockDescriptor)
    do {
      let archive = try await prepareArchive(identity)
      let state = try await preparation.withPreparedPackage(
        archive: archive, expectedSHA256: expectedSHA256, pluginID: pluginID, version: version,
        hostVersion: hostVersion, architecture: architecture
      ) { package, receipt in
        try await verifyPackage(package)
        return try await self.commitInstallation(
          package, receipt: receipt, owned: owned, storage: storage,
          expectedRevision: expectedRevision, githubRelease: githubRelease)
      }
      try storage.clean(identity, keepingPackage: true)
      return PluginStoreMutation(snapshot: state, issues: [])
    } catch {
      // A cleanup failure after commit cannot turn success into a destructive rollback.
      // If the database cannot be read, preserve the receipt and files for recovery.
      let current = try snapshot()
      if current.installations.contains(where: { $0.id == owned.installationID }) {
        return PluginStoreMutation(snapshot: current, issues: [cleanupIssue(pluginID)])
      }
      guard !Self.isReferenced(identity, in: current) else { throw PluginStoreError.invalidState }
      try storage.clean(identity, keepingPackage: false)
      try database.forgetPluginDirectory(owned)
      throw error
    }
  }

  private func commitInstallation(
    _ package: PluginPackage, receipt: PluginArchiveReceipt, owned: PluginOwnedDirectory,
    storage: PluginInstallationStorage, expectedRevision: Int64,
    githubRelease: GitHubPluginArtifact?
  ) throws -> PluginStoreSnapshot {
    try Task.checkCancellation()
    // Archive preparation suspends the actor; never reuse its preflight snapshot.
    var state = try checkedSnapshot(expectedRevision)
    let root = try storage.promote(package, into: owned.identity)
    let record = PluginInstallationRecord(
      id: owned.installationID, pluginID: package.manifest.id, version: package.manifest.version,
      source: PluginSource(
        kind: .artifact, root: root,
        repository: githubRelease?.declaration.repositoryURL.absoluteString,
        revision: githubRelease?.declaration.revision, artifactSHA256: receipt.sha256,
        githubRelease: githubRelease),
      manifestDigest: try Self.manifestDigest(package.manifest), registeredAt: .now)
    state.installations.append(record)
    state.selectedInstallations[record.pluginID] = record.id
    Self.addMissingSettings(for: package.manifest, to: &state)
    return try commit(state, expectedRevision: expectedRevision)
  }

  /// Revokes only this artifact's registration. Host overrides and other versions survive.
  /// Callers must finish affected tasks and release their processes before this operation.
  package func uninstallArtifact(
    installationID: String, storageRoot: URL, expectedRevision: Int64
  ) throws -> PluginStoreMutation {
    let storage = try PluginInstallationStorage(at: storageRoot)
    defer { storage.finishTransaction() }
    var state = try checkedSnapshot(expectedRevision)
    guard let record = state.installations.first(where: { $0.id == installationID }),
      record.source.kind == .artifact,
      let owned = try database.pluginOwnedDirectories().first(where: {
        $0.installationID == installationID
      }),
      owned.pluginID == record.pluginID,
      record.source.root.path == owned.identity.url.appendingPathComponent("package").path
    else { throw PluginStoreError.unknownInstallation(installationID) }
    try storage.validate(owned.identity)
    state.installations.removeAll { $0.id == installationID }
    if state.selectedInstallations[record.pluginID] == installationID {
      state.selectedInstallations.removeValue(forKey: record.pluginID)
    }
    // Preserve files if another registration explicitly references the managed directory.
    guard !Self.isReferenced(owned.identity, in: state) else { throw PluginStoreError.invalidState }
    let committed = try commit(state, expectedRevision: expectedRevision)
    do {
      try storage.clean(owned.identity, keepingPackage: false)
      try database.forgetPluginDirectory(owned)
      return PluginStoreMutation(snapshot: committed, issues: [])
    } catch {
      return PluginStoreMutation(snapshot: committed, issues: [cleanupIssue(record.pluginID)])
    }
  }

  /// Reconciles receipted directories only. Unknown files are never adopted or removed.
  /// The inherited installation lock prevents cleanup while an orphan worker is live.
  package func recoverInstallations(storageRoot: URL, expectedRevision: Int64? = nil) throws
    -> [PluginStoreIssue]
  {
    let storage = try PluginInstallationStorage(at: storageRoot)
    defer { storage.finishTransaction() }
    let state = try expectedRevision.map(checkedSnapshot) ?? snapshot()
    var issues: [PluginStoreIssue] = []
    let ownedDirectories = try database.pluginOwnedDirectories()
    for owned in ownedDirectories {
      do {
        try storage.validate(owned.identity)
        if let record = state.installations.first(where: { $0.id == owned.installationID }) {
          guard record.pluginID == owned.pluginID, record.source.kind == .artifact,
            record.source.root.path == owned.identity.url.appendingPathComponent("package").path
          else { throw PluginStoreError.invalidState }
          try storage.clean(owned.identity, keepingPackage: true)
        } else {
          guard !Self.isReferenced(owned.identity, in: state) else {
            throw PluginStoreError.invalidState
          }
          try storage.clean(owned.identity, keepingPackage: false)
          try database.forgetPluginDirectory(owned)
        }
      } catch {
        issues.append(cleanupIssue(owned.pluginID))
      }
    }
    return issues
  }

  private static func isReferenced(
    _ identity: PluginDirectoryIdentity, in state: PluginStoreSnapshot
  ) -> Bool {
    state.installations.contains {
      $0.source.root.pathComponents.starts(with: identity.url.pathComponents)
    }
  }

  private func cleanupIssue(_ pluginID: String) -> PluginStoreIssue {
    PluginStoreIssue(
      pluginID: pluginID,
      message:
        "Plugin file recovery is incomplete. Missing, unverified or still-referenced directories require attention."
    )
  }
}
