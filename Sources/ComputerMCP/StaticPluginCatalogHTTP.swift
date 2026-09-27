import Foundation

struct StaticPluginCatalogValidators: Codable, Equatable, Sendable {
  let etag: String?
  let lastModified: String?

  init(etag: String? = nil, lastModified: String? = nil) {
    self.etag = Self.header(etag, limit: 2_048)
    self.lastModified = Self.header(lastModified, limit: 128)
  }

  private static func header(_ value: String?, limit: Int) -> String? {
    guard let value, !value.isEmpty, value.utf8.count <= limit,
      value.utf8.allSatisfy({ (32...126).contains($0) })
    else { return nil }
    return value
  }
}

protocol StaticPluginCatalogFetching: Sendable {
  func fetch(validators: StaticPluginCatalogValidators) async throws -> PluginCatalogHTTPResponse
}

/// One fixed public endpoint, with no cookies, credentials, URL cache or redirect authority.
final class StaticPluginCatalogHTTP: StaticPluginCatalogFetching, Sendable {
  static let endpoint = URL(string: "https://computer-mcp.github.io/plugins/index.json")!
  private let endpoint: URL
  private let session: URLSession

  init(configuration: URLSessionConfiguration = .ephemeral, endpoint: URL = endpoint) {
    let configuration = configuration.copy() as! URLSessionConfiguration
    configuration.urlCredentialStorage = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpAdditionalHeaders = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 8
    configuration.timeoutIntervalForResource = 10
    session = URLSession(configuration: configuration)
    self.endpoint = endpoint
  }

  func fetch(validators: StaticPluginCatalogValidators) async throws -> PluginCatalogHTTPResponse {
    // Validate again because decoded cache values do not pass through the member initializer.
    let validators = StaticPluginCatalogValidators(
      etag: validators.etag, lastModified: validators.lastModified)
    var request = URLRequest(url: endpoint)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Computer-MCP-Plugin-Catalog", forHTTPHeaderField: "User-Agent")
    if let etag = validators.etag {
      request.setValue(etag, forHTTPHeaderField: "If-None-Match")
    } else if let modified = validators.lastModified {
      request.setValue(modified, forHTTPHeaderField: "If-Modified-Since")
    }
    try Task.checkCancellation()
    let delegate = GitHubPublicSessionDelegate()
    let bytes: URLSession.AsyncBytes
    let raw: URLResponse
    do { (bytes, raw) = try await session.bytes(for: request, delegate: delegate) } catch {
      try Task.checkCancellation()
      if let failure = delegate.authenticationFailure { throw failure }
      throw error
    }
    defer { bytes.task.cancel() }
    guard let response = raw as? HTTPURLResponse, response.url == endpoint else {
      throw PluginCatalogError.invalidResponse
    }
    var headers: [String: String] = [:]
    for (key, value) in response.allHeaderFields {
      if let key = key as? String, let value = value as? String {
        headers[key.lowercased()] = value
      }
    }
    guard response.statusCode == 200 else {
      return .init(status: response.statusCode, headers: headers, body: Data())
    }
    let limit = StaticPluginCatalogDocument.maximumBytes
    guard response.expectedContentLength <= limit else { throw PluginCatalogError.responseTooLarge }
    var body = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      guard body.count < limit else { throw PluginCatalogError.responseTooLarge }
      body.append(byte)
    }
    return .init(status: response.statusCode, headers: headers, body: body)
  }

  deinit { session.invalidateAndCancel() }
}
