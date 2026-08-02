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

internal protocol ManifestConfigurationLoading: Sendable {
  func load(path: String) throws -> GatewayConfiguration
}

internal struct GatewayManifestConfigurationLoader: ManifestConfigurationLoading {
  internal func load(path: String) throws -> GatewayConfiguration {
    try GatewayConfiguration.load(path: path)
  }
}

internal final class AtomicManifestStore: @unchecked Sendable {
  internal let manifestURL: URL

  private let database: GatewayDatabase
  private let loader: any ManifestConfigurationLoading
  private let fileManager: FileManager
  private let lock = NSLock()
  private var continuations: [UUID: AsyncStream<ManifestChange>.Continuation] = [:]
  private var directorySource: DispatchSourceFileSystemObject?
  private var directoryDescriptor: Int32 = -1
  private var knownDigest: String?

  internal init(
    manifestURL: URL,
    database: GatewayDatabase,
    loader: any ManifestConfigurationLoading = GatewayManifestConfigurationLoader(),
    fileManager: FileManager = .default
  ) throws {
    self.manifestURL = manifestURL.standardizedFileURL
    self.database = database
    self.loader = loader
    self.fileManager = fileManager
    try Self.ensureDirectory(
      self.manifestURL.deletingLastPathComponent(),
      fileManager: fileManager
    )
    if fileManager.fileExists(atPath: self.manifestURL.path) {
      knownDigest = try Self.digest(of: Data(contentsOf: self.manifestURL))
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
  internal func activate(manifest: String) throws -> ConfigurationRevision {
    try write(manifest: manifest, reason: .activated)
  }

  internal func activeConfiguration() throws -> GatewayConfiguration {
    guard fileManager.fileExists(atPath: manifestURL.path) else {
      throw AtomicManifestStoreError.manifestMissing
    }
    return try loader.load(path: manifestURL.path)
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

  private func write(manifest: String, reason: ManifestChangeReason) throws
    -> ConfigurationRevision
  {
    guard let data = manifest.data(using: .utf8), !data.isEmpty else {
      throw AtomicManifestStoreError.invalidManifestEncoding
    }

    let directory = manifestURL.deletingLastPathComponent()
    try Self.ensureDirectory(directory, fileManager: fileManager)
    let stagedURL = directory.appendingPathComponent(
      ".\(manifestURL.lastPathComponent).staged.\(UUID().uuidString)"
    )
    var revision = ConfigurationRevision(
      digest: try Self.digest(of: data),
      manifest: manifest
    )

    do {
      try Self.writeAndSynchronize(data, to: stagedURL)
      _ = try loader.load(path: stagedURL.path)
      revision.activatedAt = Date()
      try database.saveConfigurationRevision(revision)
      guard rename(stagedURL.path, manifestURL.path) == 0 else {
        throw AtomicManifestStoreError.posix(operation: "replace manifest", code: errno)
      }
      try Self.synchronizeDirectory(directory)
      try fileManager.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))],
        ofItemAtPath: manifestURL.path
      )
      setKnownDigest(revision.digest)
      publish(ManifestChange(revision: revision, reason: reason))
      return revision
    } catch {
      try? fileManager.removeItem(at: stagedURL)
      if revision.activatedAt != nil {
        revision.activatedAt = nil
        revision.activationError = Self.stableFailureDescription(error)
        try? database.saveConfigurationRevision(revision)
      }
      throw error
    }
  }

  private func reloadExternalChange() {
    do {
      guard fileManager.fileExists(atPath: manifestURL.path) else {
        return
      }
      let data = try Data(contentsOf: manifestURL)
      let digest = try Self.digest(of: data)
      guard digest != currentKnownDigest() else {
        return
      }
      let manifest = String(decoding: data, as: UTF8.self)
      _ = try loader.load(path: manifestURL.path)
      let revision = ConfigurationRevision(
        digest: digest,
        manifest: manifest,
        activatedAt: Date()
      )
      try database.saveConfigurationRevision(revision)
      setKnownDigest(digest)
      publish(ManifestChange(revision: revision, reason: .externalReload))
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

  private static func writeAndSynchronize(_ data: Data, to url: URL) throws {
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      throw AtomicManifestStoreError.posix(operation: "create staged manifest", code: errno)
    }
    var operationError: Error?
    data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else {
        return
      }
      var offset = 0
      while offset < rawBuffer.count {
        let written = Darwin.write(
          descriptor,
          baseAddress.advanced(by: offset),
          rawBuffer.count - offset
        )
        if written < 0 {
          operationError = AtomicManifestStoreError.posix(
            operation: "write staged manifest",
            code: errno
          )
          break
        }
        offset += written
      }
    }
    if operationError == nil, fsync(descriptor) != 0 {
      operationError = AtomicManifestStoreError.posix(
        operation: "synchronize staged manifest",
        code: errno
      )
    }
    let closeResult = close(descriptor)
    if operationError == nil, closeResult != 0 {
      operationError = AtomicManifestStoreError.posix(
        operation: "close staged manifest",
        code: errno
      )
    }
    if let operationError {
      throw operationError
    }
  }

  private static func synchronizeDirectory(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY)
    guard descriptor >= 0 else {
      throw AtomicManifestStoreError.posix(operation: "open manifest directory", code: errno)
    }
    let syncResult = fsync(descriptor)
    let syncError = errno
    _ = close(descriptor)
    guard syncResult == 0 else {
      throw AtomicManifestStoreError.posix(
        operation: "synchronize manifest directory",
        code: syncError
      )
    }
  }

  private static func stableFailureDescription(_ error: Error) -> String {
    if let localized = error as? any LocalizedError, let description = localized.errorDescription {
      return description
    }
    return String(describing: type(of: error))
  }
}

internal enum AtomicManifestStoreError: Error, LocalizedError, Equatable {
  case invalidManifestEncoding
  case manifestMissing
  case unknownRevision(String)
  case notDirectory(String)
  case symbolicLinkRejected(String)
  case posix(operation: String, code: Int32)

  internal var errorDescription: String? {
    switch self {
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
