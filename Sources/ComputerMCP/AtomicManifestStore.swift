import CryptoKit
import Darwin
import Foundation

internal enum ManifestChangeReason: String, Codable, Equatable, Sendable {
  case activated
  case rolledBack = "rolled-back"
  case externalReload = "external-reload"
}

internal struct ManifestChange: Codable, Equatable, Sendable {
  internal var revision: ConfigurationRevision
  internal var reason: ManifestChangeReason
}

/// Validated input retained in memory while executable candidates are prepared.
struct PreparedManifestChange: Sendable {
  fileprivate let admissionID: UUID
  fileprivate let previous: Data?
  fileprivate let revision: ConfigurationRevision
  fileprivate let reason: ManifestChangeReason
  let configuration: GatewayConfiguration
  let persisted: GatewayDatabase.ConfigurationState
}

internal protocol ManifestConfigurationLoading: Sendable {
  func load(path: String) throws -> GatewayConfiguration
}

internal struct GatewayManifestConfigurationLoader: ManifestConfigurationLoading {
  var database: GatewayDatabase? = nil
  var bundledPlugins: BundledPlugins = .current
  internal func load(path: String) throws -> GatewayConfiguration {
    let state = try (database?.pluginStoreSnapshot() ?? PluginStoreSnapshot())
      .includingBundledDefaults(bundledPlugins.packages.map(\.manifest))
    let configuration = try GatewayConfiguration.load(
      path: path,
      knownPluginMCPServerIDs: state.knownMCPRegistrationIDs)
    _ = try GatewayPluginComposition(
      configuration: configuration,
      plugins: PluginHost.resolve(state, bundled: bundledPlugins).plugins)
    return configuration
  }
}

internal final class AtomicManifestStore: @unchecked Sendable {
  internal let manifestURL: URL

  private let database: GatewayDatabase
  private let loader: any ManifestConfigurationLoading
  private let fileManager: FileManager
  private let lock = NSLock()
  private let writeLock = NSLock()
  private var continuations: [UUID: AsyncStream<ManifestChange>.Continuation] = [:]
  private var directorySource: DispatchSourceFileSystemObject?
  private var directoryDescriptor: Int32 = -1
  private var knownDigest: String?
  // Protected by writeLock; disk edits become active only after validation.
  private var configuration: GatewayConfiguration?
  private var admissionID = UUID()

  private var files: ManifestFileTransaction {
    ManifestFileTransaction(manifestURL: manifestURL, database: database, fileManager: fileManager)
  }

  internal init(
    manifestURL: URL,
    database: GatewayDatabase,
    loader: (any ManifestConfigurationLoading)? = nil,
    fileManager: FileManager = .default
  ) throws {
    self.manifestURL = manifestURL.standardizedFileURL
    self.database = database
    self.loader = loader ?? GatewayManifestConfigurationLoader(database: database)
    self.fileManager = fileManager
    try Self.ensureDirectory(
      self.manifestURL.deletingLastPathComponent(),
      fileManager: fileManager
    )
    try files.withExclusiveAccess {
      try files.recover()
      if let data = try files.currentData() { knownDigest = try Self.digest(of: data) }
    }
  }

  deinit {
    stopHotReloadMonitoring()
    lock.lock()
    let activeContinuations = Array(continuations.values)
    continuations.removeAll()
    lock.unlock()
    for continuation in activeContinuations {
      continuation.finish()
    }
  }

  internal func changes() -> AsyncStream<ManifestChange> {
    AsyncStream { continuation in
      let id = UUID()
      lock.lock()
      continuations[id] = continuation
      lock.unlock()
      continuation.onTermination = { [weak self] _ in
        self?.removeContinuation(id)
      }
    }
  }

  @discardableResult
  internal func activate(manifest: String, expectedDigest: String? = nil) throws
    -> ConfigurationRevision
  {
    try write(manifest: manifest, reason: .activated, expectedDigest: expectedDigest)
  }

  internal func activeConfiguration() throws -> GatewayConfiguration {
    writeLock.lock()
    defer { writeLock.unlock() }
    if let configuration { return configuration }
    return try files.withExclusiveAccess {
      try files.recover()
      return try admittedConfiguration()
    }
  }

  /// The synchronous publication closure shares the manifest admission lock with
  /// managed activation and external reload; no actor hop may split commit/routing.
  func withCurrentConfiguration<Result>(
    _ expected: GatewayConfiguration, publication: () throws -> Result
  ) throws -> Result {
    writeLock.lock()
    defer { writeLock.unlock() }
    return try files.withExclusiveAccess {
      try files.recover()
      guard try admittedConfiguration() == expected,
        try Self.digest(of: Data(contentsOf: manifestURL)) == currentKnownDigest()
      else { throw AtomicManifestStoreError.staleDigest }
      return try publication()
    }
  }

  private func admittedConfiguration() throws -> GatewayConfiguration {
    if let configuration { return configuration }
    guard fileManager.fileExists(atPath: manifestURL.path) else {
      throw AtomicManifestStoreError.manifestMissing
    }
    let data = try Data(contentsOf: manifestURL)
    let loaded = try loader.load(path: manifestURL.path)
    guard try Data(contentsOf: manifestURL) == data else {
      throw AtomicManifestStoreError.staleDigest
    }
    configuration = loaded
    setKnownDigest(try Self.digest(of: data))
    return loaded
  }

  internal func history(limit: Int = 50) throws -> [ConfigurationRevision] {
    try database.configurationRevisions(limit: limit)
  }

  @discardableResult
  internal func rollback(to revisionID: String) throws -> ConfigurationRevision {
    guard
      let revision = try database.configurationRevisions(limit: 1_000).first(where: {
        $0.id == revisionID
      })
    else {
      throw AtomicManifestStoreError.unknownRevision(revisionID)
    }
    return try write(manifest: revision.manifest, reason: .rolledBack)
  }

  internal func startHotReloadMonitoring() throws {
    lock.lock()
    if directorySource != nil {
      lock.unlock()
      return
    }
    lock.unlock()

    let directory = manifestURL.deletingLastPathComponent()
    let descriptor = open(directory.path, O_EVTONLY)
    guard descriptor >= 0 else {
      throw AtomicManifestStoreError.posix(operation: "open directory", code: errno)
    }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      eventMask: [.write, .rename, .delete],
      queue: DispatchQueue(label: "com.showxu.computer-mcp.manifest-watch")
    )
    source.setEventHandler { [weak self] in
      self?.reloadExternalChange()
    }
    source.setCancelHandler {
      close(descriptor)
    }

    lock.lock()
    guard directorySource == nil else {
      lock.unlock()
      source.cancel()
      return
    }
    directoryDescriptor = descriptor
    directorySource = source
    lock.unlock()
    source.resume()
  }

  internal func stopHotReloadMonitoring() {
    lock.lock()
    let source = directorySource
    directorySource = nil
    directoryDescriptor = -1
    lock.unlock()
    source?.cancel()
  }

  private func write(manifest: String, reason: ManifestChangeReason, expectedDigest: String? = nil)
    throws
    -> ConfigurationRevision
  {
    try commit(prepare(manifest: manifest, reason: reason, expectedDigest: expectedDigest))
  }

  func prepare(
    manifest: String, reason: ManifestChangeReason = .activated, expectedDigest: String? = nil,
    expectedConfiguration: GatewayConfiguration? = nil
  ) throws -> PreparedManifestChange {
    writeLock.lock()
    defer { writeLock.unlock() }
    return try files.withExclusiveAccess {
      try files.recover()
      if let expectedConfiguration, try admittedConfiguration() != expectedConfiguration {
        throw AtomicManifestStoreError.staleDigest
      }
      let previous = try files.currentData()
      let persisted = try database.configurationState()
      if let expectedDigest {
        guard let previous, try Self.digest(of: previous) == expectedDigest else {
          throw AtomicManifestStoreError.staleDigest
        }
      }
      guard let data = manifest.data(using: .utf8), !data.isEmpty else {
        throw AtomicManifestStoreError.invalidManifestEncoding
      }
      let directory = manifestURL.deletingLastPathComponent()
      try Self.ensureDirectory(directory, fileManager: fileManager)
      let stagedURL = directory.appendingPathComponent(
        ".\(manifestURL.lastPathComponent).staged.\(UUID().uuidString)")
      defer { try? fileManager.removeItem(at: stagedURL) }
      try ManifestFileTransaction.writeAndSynchronize(data, to: stagedURL)
      let loaded = try loader.load(path: stagedURL.path)
      guard try Data(contentsOf: stagedURL) == data else {
        throw AtomicManifestStoreError.staleDigest
      }
      return PreparedManifestChange(
        admissionID: admissionID, previous: previous,
        revision: ConfigurationRevision(digest: try Self.digest(of: data), manifest: manifest),
        reason: reason, configuration: loaded, persisted: persisted)
    }
  }

  func commit(
    _ prepared: PreparedManifestChange, resolution: GatewayConfigurationResolution = .init(),
    install: (GatewayDatabase.ConfigurationState) -> Void = { _ in }
  ) throws -> ConfigurationRevision {
    writeLock.lock()
    defer { writeLock.unlock() }
    return try files.withExclusiveAccess {
      try files.recover()
      guard prepared.admissionID == admissionID,
        try files.currentData() == prepared.previous
      else { throw AtomicManifestStoreError.staleDigest }
      let stagedURL = manifestURL.deletingLastPathComponent().appendingPathComponent(
        ".\(manifestURL.lastPathComponent).staged.\(UUID().uuidString)")
      defer { try? fileManager.removeItem(at: stagedURL) }
      var revision = prepared.revision
      revision.activatedAt = Date()
      try ManifestFileTransaction.writeAndSynchronize(Data(revision.manifest.utf8), to: stagedURL)
      let persisted = try files.commit(
        stagedURL: stagedURL, previous: prepared.previous, revision: revision,
        expected: prepared.persisted, resolution: resolution)
      configuration = prepared.configuration
      admissionID = UUID()
      setKnownDigest(revision.digest)
      install(persisted)
      publish(ManifestChange(revision: revision, reason: prepared.reason))
      return revision
    }
  }

  private func reloadExternalChange() {
    writeLock.lock()
    defer { writeLock.unlock() }
    do {
      try files.withExclusiveAccess {
        try files.recover()
        guard let data = try files.currentData() else { return }
        let digest = try Self.digest(of: data)
        guard digest != currentKnownDigest() else { return }
        let manifest = String(decoding: data, as: UTF8.self)
        let loaded = try loader.load(path: manifestURL.path)
        guard try Data(contentsOf: manifestURL) == data else { return }
        let revision = ConfigurationRevision(
          digest: digest, manifest: manifest, activatedAt: Date())
        try database.saveConfigurationRevision(revision)
        configuration = loaded
        admissionID = UUID()
        setKnownDigest(digest)
        publish(ManifestChange(revision: revision, reason: .externalReload))
      }
    } catch {
      // External invalid changes never become active control-plane state.
    }
  }

  private func publish(_ change: ManifestChange) {
    lock.lock()
    let activeContinuations = Array(continuations.values)
    lock.unlock()
    for continuation in activeContinuations {
      continuation.yield(change)
    }
  }

  private func removeContinuation(_ id: UUID) {
    lock.lock()
    continuations.removeValue(forKey: id)
    lock.unlock()
  }

  private func currentKnownDigest() -> String? {
    lock.lock()
    defer { lock.unlock() }
    return knownDigest
  }

  private func setKnownDigest(_ digest: String) {
    lock.lock()
    knownDigest = digest
    lock.unlock()
  }

  private static func digest(of data: Data) throws -> String {
    guard !data.isEmpty else {
      throw AtomicManifestStoreError.invalidManifestEncoding
    }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func ensureDirectory(_ url: URL, fileManager: FileManager) throws {
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
      guard isDirectory.boolValue else {
        throw AtomicManifestStoreError.notDirectory(url.path)
      }
      let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
      guard values.isSymbolicLink != true else {
        throw AtomicManifestStoreError.symbolicLinkRejected(url.path)
      }
    } else {
      try fileManager.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
      )
    }
    try fileManager.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o700))],
      ofItemAtPath: url.path
    )
  }

}

internal enum AtomicManifestStoreError: Error, LocalizedError, Equatable {
  case staleDigest
  case changeInProgress
  case invalidRecoveryJournal
  case recoveryConflict(String)
  case invalidManifestEncoding
  case manifestMissing
  case unknownRevision(String)
  case notDirectory(String)
  case symbolicLinkRejected(String)
  case posix(operation: String, code: Int32)

  internal var errorDescription: String? {
    switch self {
    case .changeInProgress:
      return "Another manifest transaction is running. Retry when it finishes."
    case .invalidRecoveryJournal:
      return
        "The manifest recovery record is invalid. Preserve the record and configuration for repair."
    case .recoveryConflict(let path):
      return
        "Manifest recovery found an external edit at \(path). The edit and recovery record were preserved."
    case .staleDigest:
      return "The active manifest changed after preview; refresh and review the change again."
    case .invalidManifestEncoding:
      return "The manifest must be non-empty UTF-8."
    case .manifestMissing:
      return "No active manifest exists."
    case .unknownRevision(let id):
      return "Unknown configuration revision: \(id)"
    case .notDirectory(let path):
      return "Expected a directory at: \(path)"
    case .symbolicLinkRejected(let path):
      return "Control-plane directory symbolic links are not allowed: \(path)"
    case .posix(let operation, let code):
      return "\(operation) failed with POSIX error \(code)."
    }
  }
}
