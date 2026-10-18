import Darwin
import Foundation

/// The body and HTTP validators belong to the same successful validation of the fixed endpoint.
struct StaticPluginCatalogCacheRecord: Codable, Sendable {
  let endpoint: String
  let body: Data
  let validators: StaticPluginCatalogValidators
  let validatedAt: Date

  init(body: Data, validators: StaticPluginCatalogValidators, validatedAt: Date) {
    endpoint = StaticPluginCatalogHTTP.endpoint.absoluteString
    self.body = body
    self.validators = validators
    self.validatedAt = validatedAt
  }

  func document() throws -> StaticPluginCatalogDocument {
    guard endpoint == StaticPluginCatalogHTTP.endpoint.absoluteString,
      validatedAt.timeIntervalSince1970.isFinite,
      validators
        == StaticPluginCatalogValidators(
          etag: validators.etag, lastModified: validators.lastModified)
    else { throw PluginCatalogError.invalidResponse }
    return try StaticPluginCatalogDocument.decode(body)
  }
}

struct StaticPluginCatalogCache: Sendable {
  // JSON's base64 representation adds one third to the bounded catalog body.
  static let maximumBytes = 6 * 1_024 * 1_024
  let url: URL
  private let operations = BlockingOperationExecutor(label: "computer-mcp.plugin-catalog-cache")

  func read() async throws -> StaticPluginCatalogCacheRecord? {
    try await operations.perform { try readSynchronously() }
  }

  func write(_ record: StaticPluginCatalogCacheRecord) async throws {
    try await operations.perform {
      let document = try record.document()
      let parent = url.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      guard try parent.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
        throw PluginCatalogError.unsafeRequest
      }
      let lock = open(
        parent.appendingPathComponent("catalog.lock").path,
        O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
      guard lock >= 0 else { throw PluginCatalogError.unsafeRequest }
      defer { close(lock) }
      guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw PluginCatalogError.busy }
      defer { flock(lock, LOCK_UN) }
      // Separate hosts may share a cache directory; a late writer cannot roll it back.
      if let previous = try? readSynchronously(), let previousDocument = try? previous.document() {
        try document.validateSuccessor(of: previousDocument)
        if document == previousDocument && record.validatedAt < previous.validatedAt { return }
      }
      let bytes = try JSONEncoder().encode(record)
      guard bytes.count <= Self.maximumBytes else { throw PluginCatalogError.responseTooLarge }
      if FileManager.default.fileExists(atPath: url.path),
        try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
      {
        throw PluginCatalogError.unsafeRequest
      }
      try bytes.write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
  }

  private func readSynchronously() throws -> StaticPluginCatalogCacheRecord? {
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    if descriptor < 0, errno == ENOENT { return nil }
    guard descriptor >= 0 else { throw PluginCatalogError.unsafeRequest }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? file.close() }
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
      status.st_size <= Self.maximumBytes
    else { throw PluginCatalogError.responseTooLarge }
    let data = try file.read(upToCount: Self.maximumBytes + 1) ?? Data()
    guard data.count <= Self.maximumBytes else { throw PluginCatalogError.responseTooLarge }
    let record = try JSONDecoder().decode(StaticPluginCatalogCacheRecord.self, from: data)
    _ = try record.document()
    return record
  }
}
