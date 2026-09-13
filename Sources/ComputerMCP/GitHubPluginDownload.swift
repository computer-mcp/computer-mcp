import CryptoKit
import Darwin
import Foundation

/// Streams a selected public asset into an empty, caller-owned private file.
/// The caller retains the descriptor until this operation, including cancellation, has joined.
final class GitHubPluginDownload: Sendable {
  private let session: URLSession
  private let origin: URL
  private let redirectOrigins: Set<URL>
  private let timeout: Duration

  init(
    configuration: URLSessionConfiguration = .ephemeral,
    origin: URL = URL(string: "https://api.github.com")!,
    redirectOrigins: Set<URL> = [URL(string: "https://release-assets.githubusercontent.com")!],
    timeout: Duration = .seconds(120)
  ) {
    let configuration = configuration.copy() as! URLSessionConfiguration
    configuration.urlCredentialStorage = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpAdditionalHeaders = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 120
    session = URLSession(configuration: configuration)
    self.origin = origin
    self.redirectOrigins = redirectOrigins
    self.timeout = min(max(timeout, .milliseconds(1)), .seconds(120))
  }

  func download(_ artifact: GitHubPluginArtifact, to descriptor: Int32) async throws {
    try artifact.validate()
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o777 == 0o600,
      info.st_size == 0, lseek(descriptor, 0, SEEK_CUR) == 0,
      fcntl(descriptor, F_GETFL) & O_ACCMODE != O_RDONLY
    else { throw PluginArchiveError.invalidInput }
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await self.transfer(artifact, to: descriptor) }
        group.addTask {
          try await Task.sleep(for: self.timeout)
          throw PluginCatalogError.timedOut
        }
        defer { group.cancelAll() }
        try await group.next()
      }
    } catch {
      if Task.isCancelled || error is CancellationError { throw CancellationError() }
      if let error = error as? PluginCatalogError { throw error }
      if let error = error as? PluginArchiveError { throw error }
      if (error as? URLError)?.code == .timedOut { throw PluginCatalogError.timedOut }
      // Foundation errors can contain a signed redirect URL; do not expose them to the host UI/audit.
      throw PluginCatalogError.networkUnavailable
    }
  }

  private func transfer(_ artifact: GitHubPluginArtifact, to descriptor: Int32) async throws {
    guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
      throw PluginCatalogError.unsafeRequest
    }
    components.path = artifact.apiPath
    components.query = nil
    components.fragment = nil
    guard var url = components.url, sameOrigin(url, origin), url.user == nil, url.password == nil
    else {
      throw PluginCatalogError.unsafeRequest
    }
    for hop in 0...3 {
      try Task.checkCancellation()
      var request = URLRequest(url: url)
      request.httpMethod = "GET"
      request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
      request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
      request.setValue("Computer-MCP-Plugin-Download", forHTTPHeaderField: "User-Agent")
      if hop == 0 { request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version") }
      let delegate = GitHubPublicSessionDelegate()
      let bytes: URLSession.AsyncBytes
      let rawResponse: URLResponse
      do { (bytes, rawResponse) = try await session.bytes(for: request, delegate: delegate) } catch
      {
        try Task.checkCancellation()
        if let failure = delegate.authenticationFailure { throw failure }
        throw error
      }
      defer { bytes.task.cancel() }
      guard let response = rawResponse as? HTTPURLResponse, response.url == url else {
        throw PluginCatalogError.invalidResponse
      }
      if response.statusCode == 302 {
        guard hop < 3, let location = response.value(forHTTPHeaderField: "Location"),
          location.utf8.count <= 16_384, let next = URL(string: location),
          next.user == nil, next.password == nil, next.fragment == nil,
          redirectOrigins.contains(where: { sameOrigin(next, $0) })
        else { throw PluginCatalogError.unsafeRequest }
        url = next
        continue
      }
      try PluginCatalogHTTPResponse(
        status: response.statusCode,
        headers: [
          "retry-after": response.value(forHTTPHeaderField: "Retry-After") ?? "",
          "x-ratelimit-remaining": response.value(forHTTPHeaderField: "X-RateLimit-Remaining")
            ?? "",
        ].filter { !$0.value.isEmpty }, body: Data()
      ).requireSuccess()
      let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
      guard encoding == nil || encoding == "identity",
        [
          "application/octet-stream", "application/zip", "application/gzip", "application/x-gzip",
          "application/x-tar",
        ].contains(response.mimeType?.lowercased() ?? ""),
        response.expectedContentLength < 0 || response.expectedContentLength == artifact.size
      else { throw PluginCatalogError.invalidResponse }
      var buffer = Data()
      buffer.reserveCapacity(65_536)
      var count: Int64 = 0
      var hash = SHA256()
      for try await byte in bytes {
        try Task.checkCancellation()
        guard count < artifact.size else { throw PluginArchiveError.limitExceeded }
        buffer.append(byte)
        count += 1
        if buffer.count == 65_536 {
          try write(buffer, to: descriptor)
          hash.update(data: buffer)
          buffer.removeAll(keepingCapacity: true)
        }
      }
      try Task.checkCancellation()
      guard count == artifact.size else { throw PluginCatalogError.invalidResponse }
      if !buffer.isEmpty {
        try write(buffer, to: descriptor)
        hash.update(data: buffer)
      }
      guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == artifact.sha256 else {
        throw PluginArchiveError.checksumMismatch
      }
      guard fsync(descriptor) == 0 else { throw PluginArchiveError.fileSystemFailure }
      return
    }
  }

  private func sameOrigin(_ url: URL, _ origin: URL) -> Bool {
    url.scheme == origin.scheme && url.host == origin.host && url.port == origin.port
  }

  private func write(_ bytes: Data, to descriptor: Int32) throws {
    try bytes.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.write(
          descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw PluginArchiveError.fileSystemFailure }
        offset += count
      }
    }
  }

  deinit { session.invalidateAndCancel() }
}
