import Foundation

protocol PluginCatalogHTTPFetching: Sendable {
  func fetch(path: String, query: [String: String], accept: String, maxBytes: Int) async throws
    -> PluginCatalogHTTPResponse
}

struct PluginCatalogHTTPResponse: Sendable {
  let status: Int
  let headers: [String: String]
  let body: Data

  func requireSuccess() throws {
    if status == 429
      || (status == 403
        && (headers["x-ratelimit-remaining"] == "0" || headers["retry-after"] != nil))
    {
      throw PluginCatalogError.rateLimited(
        retryAfterSeconds: headers["retry-after"].flatMap(Int.init))
    }
    guard status == 200 else { throw PluginCatalogError.httpStatus(status) }
  }

  func decode<T: Decodable>(_ type: T.Type) throws -> T {
    let mime = headers["content-type"]?.lowercased().split(separator: ";").first?
      .trimmingCharacters(in: .whitespaces)
    guard mime == "application/json" || mime == "application/vnd.github+json"
    else {
      throw PluginCatalogError.invalidResponse
    }
    do { return try JSONDecoder().decode(type, from: body) } catch {
      throw PluginCatalogError.invalidResponse
    }
  }
}

/// An isolated, credential-free session. Redirects cannot extend the catalog's network scope.
final class GitHubCatalogHTTPClient: PluginCatalogHTTPFetching, Sendable {
  private let session: URLSession
  private let origin: URL

  init(
    configuration: URLSessionConfiguration = .ephemeral,
    origin: URL = URL(string: "https://api.github.com")!
  ) {
    let configuration = configuration.copy() as! URLSessionConfiguration
    configuration.urlCredentialStorage = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpAdditionalHeaders = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 8
    configuration.timeoutIntervalForResource = 10
    self.origin = origin
    session = URLSession(configuration: configuration)
  }

  func fetch(path: String, query: [String: String], accept: String, maxBytes: Int) async throws
    -> PluginCatalogHTTPResponse
  {
    guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\0"),
      (1...2_097_152).contains(maxBytes),
      var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)
    else { throw PluginCatalogError.unsafeRequest }
    components.path = path
    components.queryItems = query.sorted { $0.key < $1.key }.map {
      URLQueryItem(name: $0.key, value: $0.value)
    }
    guard let url = components.url, url.scheme == origin.scheme, url.host == origin.host,
      url.port == origin.port, url.user == nil, url.password == nil, url.fragment == nil,
      !url.pathComponents.contains("..")
    else { throw PluginCatalogError.unsafeRequest }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue(accept, forHTTPHeaderField: "Accept")
    request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue("Computer-MCP-Plugin-Catalog", forHTTPHeaderField: "User-Agent")
    try Task.checkCancellation()
    let delegate = GitHubPublicSessionDelegate()
    let bytes: URLSession.AsyncBytes
    let rawResponse: URLResponse
    do { (bytes, rawResponse) = try await session.bytes(for: request, delegate: delegate) } catch {
      try Task.checkCancellation()
      if let authenticationFailure = delegate.authenticationFailure { throw authenticationFailure }
      throw error
    }
    defer { bytes.task.cancel() }
    guard let response = rawResponse as? HTTPURLResponse, response.url == url else {
      throw PluginCatalogError.invalidResponse
    }
    var headers: [String: String] = [:]
    for (key, value) in response.allHeaderFields {
      if let key = key as? String, let value = value as? String {
        headers[key.lowercased()] = value
      }
    }
    // Error bodies are not metadata and may exceed a small successful SHA response's bound.
    if response.statusCode != 200 {
      return PluginCatalogHTTPResponse(status: response.statusCode, headers: headers, body: Data())
    }
    guard response.expectedContentLength <= maxBytes else {
      throw PluginCatalogError.responseTooLarge
    }
    var data = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      guard data.count < maxBytes else { throw PluginCatalogError.responseTooLarge }
      data.append(byte)
    }
    return PluginCatalogHTTPResponse(status: response.statusCode, headers: headers, body: data)
  }

  deinit { session.invalidateAndCancel() }
}

/// Each request owns its delegate; authentication failure is accessed only under the lock.
final class GitHubPublicSessionDelegate: NSObject, URLSessionTaskDelegate,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var failure: PluginCatalogError?
  var authenticationFailure: PluginCatalogError? { lock.withLock { failure } }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler:
      @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
      completionHandler(.performDefaultHandling, nil)
    } else {
      // Challenge cancellation can surface as a generic URL error. Preserve the cause per request.
      lock.withLock {
        failure =
          (challenge.failureResponse as? HTTPURLResponse).map {
            PluginCatalogError.httpStatus($0.statusCode)
          } ?? .authenticationRequired
      }
      completionHandler(.cancelAuthenticationChallenge, nil)
    }
  }
}
