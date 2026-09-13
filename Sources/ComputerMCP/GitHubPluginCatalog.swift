import CryptoKit
import Foundation

package struct PluginCatalogEntry: Codable, Equatable, Identifiable, Sendable {
  package let repositoryID: Int64
  package let repository: String
  package let publisherID: Int64
  package let revision: String
  package let manifestBlobSHA: String
  package let manifestSHA256: String
  package let pluginID: String
  package let name: String
  package let version: PluginVersion
  package let summary: String?
  package let mcp: [String]
  package let cli: [String]
  package let skills: [String]
  package var id: String { "\(repositoryID)@\(revision)" }
  package var repositoryURL: URL { URL(string: "https://github.com/\(repository)")! }
  package var manifestURL: URL {
    repositoryURL.appendingPathComponent("blob").appendingPathComponent(revision)
      .appendingPathComponent(PluginManifest.filename)
  }

  func matches(query: String, kind: IntegrationKind?) -> Bool {
    if let kind {
      switch kind {
      case .mcp: guard !mcp.isEmpty else { return false }
      case .cli: guard !cli.isEmpty else { return false }
      case .skills: guard !skills.isEmpty else { return false }
      }
    }
    let text = [repository, pluginID, name, summary ?? ""].joined(separator: "\n").lowercased()
    return query.lowercased().split(whereSeparator: \.isWhitespace).allSatisfy { text.contains($0) }
  }
}

package struct PluginCatalogIssue: Codable, Equatable, Sendable {
  package let repository: String
  package let code: String
  package let message: String
  package var httpStatus: Int? = nil
}

package struct PluginCatalogSearchResult: Codable, Sendable {
  package let publisher: String
  package let publisherID: Int64
  package let query: String
  package let kind: IntegrationKind?
  package let page: Int
  package let nextPage: Int?
  package let checkedRepositories: Int
  package let fetchedAt: Date
  package let cached: Bool
  package let entries: [PluginCatalogEntry]
  package let issues: [PluginCatalogIssue]
}

package enum PluginCatalogError: Error, Equatable, LocalizedError, Sendable {
  case invalidQuery
  case busy
  case invalidResponse
  case invalidManifest
  case invalidProvenance
  case responseTooLarge
  case unsafeRequest
  case authenticationRequired
  case httpStatus(Int)
  case rateLimited(retryAfterSeconds: Int?)
  case timedOut
  case networkUnavailable

  package var code: String {
    switch self {
    case .invalidQuery: "plugin.catalog.invalid_query"
    case .busy: "plugin.catalog.busy"
    case .invalidResponse: "plugin.catalog.invalid_response"
    case .invalidManifest: "plugin.catalog.invalid_manifest"
    case .invalidProvenance: "plugin.catalog.invalid_provenance"
    case .responseTooLarge: "plugin.catalog.response_too_large"
    case .unsafeRequest: "plugin.catalog.unsafe_request"
    case .authenticationRequired: "plugin.catalog.authentication_required"
    case .httpStatus: "plugin.catalog.http_error"
    case .rateLimited: "plugin.catalog.rate_limited"
    case .timedOut: "plugin.catalog.timed_out"
    case .networkUnavailable: "plugin.catalog.network_unavailable"
    }
  }

  package var errorDescription: String? {
    switch self {
    case .invalidQuery:
      "Invalid plugin request. Check repository identity, tag, query length and page bounds."
    case .busy: "Another official plugin search is in progress. Try again when it finishes."
    case .invalidResponse: "GitHub returned an invalid plugin catalog response."
    case .invalidManifest: "The repository's plugin declaration is invalid."
    case .invalidProvenance:
      "The plugin's GitHub publisher, repository or release does not match the selected source."
    case .responseTooLarge: "The plugin catalog response exceeded its size limit."
    case .unsafeRequest: "The plugin request was refused because its destination is not allowed."
    case .authenticationRequired:
      "GitHub requested authentication. Public plugin requests do not use host credentials."
    case .httpStatus(let status): "GitHub request failed with HTTP \(status)."
    case .rateLimited: "GitHub has limited plugin requests. Wait before trying again."
    case .timedOut: "GitHub plugin request timed out. Check the connection and try again."
    case .networkUnavailable: "GitHub is unavailable. Check the connection and try again."
    }
  }
}

package protocol PluginCatalogSearching: Sendable {
  func search(query: String, kind: IntegrationKind?, page: Int, refresh: Bool) async throws
    -> PluginCatalogSearchResult
}

/// Public GitHub discovery only. Source provenance does not establish artifact integrity or grants.
package actor GitHubPluginCatalog: PluginCatalogSearching {
  package static let publisher = "computer-mcp"
  package static let publisherID: Int64 = 315_005_910
  static let pageSize = 10
  private let http: any PluginCatalogHTTPFetching
  private let now: @Sendable () -> Date
  private var searching = false
  private var cache: [Int: Page] = [:]

  private struct Page: Sendable {
    let next: Int?
    let checked: Int
    let fetchedAt: Date
    let entries: [PluginCatalogEntry]
    let issues: [PluginCatalogIssue]
  }

  package init() {
    http = GitHubCatalogHTTPClient()
    now = { .now }
  }

  init(http: any PluginCatalogHTTPFetching, now: @escaping @Sendable () -> Date = { .now }) {
    self.http = http
    self.now = now
  }

  package func search(
    query: String = "", kind: IntegrationKind? = nil, page: Int = 1, refresh: Bool = false
  ) async throws
    -> PluginCatalogSearchResult
  {
    guard query.utf8.count <= 256, !query.contains("\0"), (1...100_000).contains(page) else {
      throw PluginCatalogError.invalidQuery
    }
    try Task.checkCancellation()
    let result: Page
    let cached: Bool
    if !refresh, let found = cache[page],
      (0..<60).contains(now().timeIntervalSince(found.fetchedAt))
    {
      result = found
      cached = true
    } else {
      guard !searching else { throw PluginCatalogError.busy }
      searching = true
      defer { searching = false }
      do {
        result = try await withThrowingTaskGroup(of: Page.self) { group in
          group.addTask { try await self.fetchPage(page) }
          group.addTask {
            try await Task.sleep(for: .seconds(25))
            throw PluginCatalogError.timedOut
          }
          defer { group.cancelAll() }
          return try await group.next()!
        }
      } catch {
        if Task.isCancelled || error is CancellationError { throw CancellationError() }
        if let error = error as? PluginCatalogError { throw error }
        if (error as? URLError)?.code == .timedOut { throw PluginCatalogError.timedOut }
        if let error = error as? URLError,
          [.userAuthenticationRequired, .userCancelledAuthentication].contains(error.code)
        {
          throw PluginCatalogError.authenticationRequired
        }
        throw PluginCatalogError.networkUnavailable
      }
      if cache[page] == nil, cache.count >= 8,
        let oldest = cache.min(by: { $0.value.fetchedAt < $1.value.fetchedAt })?.key
      {
        cache.removeValue(forKey: oldest)
      }
      cache[page] = result
      cached = false
    }
    return PluginCatalogSearchResult(
      publisher: Self.publisher, publisherID: Self.publisherID, query: query, kind: kind,
      page: page, nextPage: result.next, checkedRepositories: result.checked,
      fetchedAt: result.fetchedAt, cached: cached,
      entries: result.entries.filter { $0.matches(query: query, kind: kind) }, issues: result.issues
    )
  }

  private func fetchPage(_ page: Int) async throws -> Page {
    let response = try await http.fetch(
      path: "/orgs/\(Self.publisher)/repos",
      query: [
        "type": "public", "sort": "full_name", "direction": "asc",
        "per_page": String(Self.pageSize), "page": String(page),
      ],
      accept: "application/vnd.github+json", maxBytes: 2_097_152)
    try response.requireSuccess()
    let repositories = try response.decode([Repository].self)
    guard repositories.count <= Self.pageSize,
      Set(repositories.map(\.id)).count == repositories.count,
      Set(repositories.map(\.fullName)).count == repositories.count
    else {
      throw PluginCatalogError.invalidResponse
    }
    let next = try Self.nextPage(response.headers["link"], current: page)
    var entries: [PluginCatalogEntry] = []
    var issues: [PluginCatalogIssue] = []
    for repository in repositories {
      try Task.checkCancellation()
      do {
        try repository.validate()
        guard !repository.archived, !repository.disabled else { continue }
        if let entry = try await discover(repository) { entries.append(entry) }
      } catch let error as PluginCatalogError {
        switch error {
        case .rateLimited, .networkUnavailable, .timedOut: throw error
        default:
          let status: Int?
          if case .httpStatus(let value) = error { status = value } else { status = nil }
          issues.append(
            PluginCatalogIssue(
              repository: String(repository.fullName.prefix(256)), code: error.code,
              message: error.localizedDescription, httpStatus: status))
        }
      }
    }
    return Page(
      next: next, checked: repositories.count, fetchedAt: now(), entries: entries, issues: issues)
  }

  private func discover(_ repository: Repository) async throws -> PluginCatalogEntry? {
    let prefix = "/repos/\(repository.fullName)"
    // Resolve the mutable default branch once; every declaration read uses the resulting commit.
    let commitResponse = try await http.fetch(
      path: prefix + "/commits/" + repository.defaultBranch,
      query: [:], accept: "application/vnd.github.sha", maxBytes: 128)
    try commitResponse.requireSuccess()
    guard
      let revision = String(data: commitResponse.body, encoding: .utf8)?.trimmingCharacters(
        in: .whitespacesAndNewlines),
      Self.isGitSHA(revision)
    else { throw PluginCatalogError.invalidResponse }
    return try await Self.entry(repository: repository, revision: revision, http: http)
  }

  static func entry(
    repository: Repository, revision: String, http: any PluginCatalogHTTPFetching
  ) async throws -> PluginCatalogEntry? {
    try repository.validate()
    guard isGitSHA(revision) else { throw PluginCatalogError.invalidResponse }
    let prefix = "/repos/\(repository.fullName)"
    let response = try await http.fetch(
      path: prefix + "/contents/" + PluginManifest.filename,
      query: ["ref": revision], accept: "application/vnd.github+json", maxBytes: 2_097_152)
    if response.status == 404 { return nil }
    try response.requireSuccess()
    let file = try response.decode(Content.self)
    guard file.type == "file", file.path == PluginManifest.filename, file.encoding == "base64",
      (1...1_048_576).contains(file.size), Self.isGitSHA(file.sha),
      let bytes = Data(base64Encoded: file.content.filter { !$0.isWhitespace }),
      bytes.count == file.size,
      let text = String(data: bytes, encoding: .utf8)
    else { throw PluginCatalogError.invalidResponse }
    let gitObject = Data("blob \(bytes.count)\0".utf8) + bytes
    let blobSHA =
      file.sha.count == 40
      ? Insecure.SHA1.hash(data: gitObject).map { String(format: "%02x", $0) }.joined()
      : SHA256.hash(data: gitObject).map { String(format: "%02x", $0) }.joined()
    guard blobSHA == file.sha else { throw PluginCatalogError.invalidResponse }
    let manifest: PluginManifest
    do { manifest = try PluginManifest.parse(text) } catch {
      throw PluginCatalogError.invalidManifest
    }
    guard manifest.name.utf8.count <= 4_096, (manifest.description?.utf8.count ?? 0) <= 16_384
    else {
      throw PluginCatalogError.responseTooLarge
    }
    return PluginCatalogEntry(
      repositoryID: repository.id, repository: repository.fullName, publisherID: Self.publisherID,
      revision: revision, manifestBlobSHA: file.sha,
      manifestSHA256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
      pluginID: manifest.id, name: manifest.name, version: manifest.version,
      summary: manifest.description,
      mcp: manifest.mcp.map(\.id), cli: manifest.cli.map(\.id), skills: manifest.skills.map(\.id))
  }

  struct Repository: Decodable {
    struct Owner: Decodable {
      let id: Int64
      let login: String
      let type: String
    }
    let id: Int64
    let name: String
    let fullName: String
    let owner: Owner
    let isPrivate: Bool
    let archived: Bool
    let disabled: Bool
    let defaultBranch: String
    enum CodingKeys: String, CodingKey {
      case id, name, owner, archived, disabled
      case fullName = "full_name"
      case isPrivate = "private"
      case defaultBranch = "default_branch"
    }
    func validate() throws {
      guard id > 0, id <= 9_007_199_254_740_991, owner.id == GitHubPluginCatalog.publisherID,
        owner.login.lowercased() == GitHubPluginCatalog.publisher, owner.type == "Organization",
        !isPrivate,
        fullName == "\(owner.login)/\(name)", !name.isEmpty, name != ".", name != "..",
        name.utf8.count <= 100,
        name.utf8.allSatisfy({
          (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
            || [45, 46, 95].contains($0)
        }),
        !defaultBranch.isEmpty, defaultBranch.utf8.count <= 256, !defaultBranch.contains("\0")
      else { throw PluginCatalogError.invalidProvenance }
    }

    static func validateName(_ fullName: String) throws {
      let parts = fullName.split(separator: "/", omittingEmptySubsequences: false)
      guard parts.count == 2, parts[0].lowercased() == GitHubPluginCatalog.publisher,
        !parts[1].isEmpty, parts[1] != ".", parts[1] != "..", parts[1].utf8.count <= 100,
        parts[1].utf8.allSatisfy({
          (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
            || [45, 46, 95].contains($0)
        })
      else { throw PluginCatalogError.invalidProvenance }
    }
  }

  private struct Content: Decodable {
    let type: String
    let path: String
    let encoding: String
    let size: Int
    let sha: String
    let content: String
  }

  static func isGitSHA(_ value: String) -> Bool {
    [40, 64].contains(value.utf8.count)
      && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  private static func nextPage(_ link: String?, current: Int) throws -> Int? {
    guard let link else { return nil }
    let nextLinks = link.split(separator: ",").filter { $0.contains("rel=\"next\"") }
    guard nextLinks.count <= 1 else { throw PluginCatalogError.invalidResponse }
    guard let next = nextLinks.first else { return nil }
    guard let start = next.firstIndex(of: "<"), let end = next.firstIndex(of: ">"), start < end,
      let url = URLComponents(string: String(next[next.index(after: start)..<end])),
      url.scheme == "https", url.host == "api.github.com", url.port == nil,
      url.user == nil, url.password == nil, url.fragment == nil,
      url.path == "/orgs/\(publisher)/repos",
      url.queryItems?.filter({ $0.name == "page" }).map(\.value) == [String(current + 1)],
      current < 100_000
    else { throw PluginCatalogError.invalidResponse }
    return current + 1
  }
}
