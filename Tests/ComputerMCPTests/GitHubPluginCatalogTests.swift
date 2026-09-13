import CryptoKit
import Foundation
import Testing

@testable import ComputerMCP

@Suite(.timeLimit(.minutes(1)))
struct GitHubPluginCatalogTests {
  @Test
  func cacheExpiresAndEvictsWithoutTreatingRefreshAsAnotherPage() async throws {
    let clock = CatalogClock()
    let http = CatalogHTTPFake(repositories: [])
    for page in 1...9 { await http.setPage(page, repositories: []) }
    let catalog = GitHubPluginCatalog(http: http, now: { clock.now })
    for page in 1...8 {
      clock.advance(1)
      _ = try await catalog.search(page: page)
    }
    #expect(await http.requests.count == 8)
    _ = try await catalog.search(page: 8, refresh: true)
    #expect(try await catalog.search(page: 1).cached)
    clock.advance(1)
    _ = try await catalog.search(page: 9)
    #expect(!(try await catalog.search(page: 1).cached))
    clock.advance(60)
    #expect(!(try await catalog.search(page: 1).cached))
    #expect(await http.requests.count == 12)
  }

  @Test(arguments: [
    (URLError.Code.timedOut, PluginCatalogError.timedOut),
    (.notConnectedToInternet, .networkUnavailable),
    (.userCancelledAuthentication, .authenticationRequired),
  ])
  func transportErrorsAreExplicit(_ code: URLError.Code, _ expected: PluginCatalogError) async {
    await #expect(throws: expected) {
      try await GitHubPluginCatalog(http: FailingCatalogHTTP(code: code)).search()
    }
  }

  @Test
  func combinesContributionSearchAndPinsSourceIndependentlyOfManifestClaims() async throws {
    let http = CatalogHTTPFake(repositories: [catalogRepository("combined", id: 1)])
    await http.setManifest(catalogManifest, repository: "combined")
    let catalog = GitHubPluginCatalog(http: http)
    let result = try await catalog.search(query: "工具", kind: .mcp, page: 1, refresh: false)
    let entry = try #require(result.entries.first)
    #expect(result.entries.count == 1 && result.issues.isEmpty && result.nextPage == nil)
    #expect(entry.repository == "computer-mcp/combined")
    #expect(entry.publisherID == 315_005_910)
    #expect(entry.repositoryURL.absoluteString == "https://github.com/computer-mcp/combined")
    #expect(entry.manifestURL.absoluteString.contains("/blob/" + catalogCommit + "/"))
    #expect(entry.revision == catalogCommit)
    #expect(entry.mcp == ["native"] && entry.cli == ["command"] && entry.skills == ["guidance"])
    #expect(entry.manifestSHA256.count == 64 && entry.manifestBlobSHA.count == 40)
    let requests = await http.requests
    #expect(requests.count == 3)
    #expect(requests[1].accept == "application/vnd.github.sha")
    #expect(requests[2].query == ["ref": catalogCommit])
    let filtered = try await catalog.search(query: "absent", kind: .skills, page: 1, refresh: false)
    #expect(filtered.entries.isEmpty && filtered.cached)
    #expect(await http.requests.count == 3)
    #expect(filtered.fetchedAt == result.fetchedAt)
    _ = try await catalog.search(query: "", kind: .cli, page: 1, refresh: true)
    #expect(await http.requests.count == 6)
  }

  @Test
  func emptyFilteredPagesStillExposeSafeContinuation() async throws {
    let http = CatalogHTTPFake(repositories: [catalogRepository("other", id: 1)])
    await http.setPage(
      1, repositories: [catalogRepository("other", id: 1)],
      link:
        "<https://api.github.com/orgs/computer-mcp/repos?per_page=10&page=2>; rel=\"next\"")
    await http.setPage(2, repositories: [catalogRepository("combined", id: 2)])
    await http.setManifest(catalogManifest, repository: "combined")
    let catalog = GitHubPluginCatalog(http: http)
    let first = try await catalog.search(query: "工具", kind: .mcp, page: 1, refresh: false)
    #expect(first.entries.isEmpty && first.issues.isEmpty)
    #expect(first.nextPage == 2 && first.checkedRepositories == 1)
    let second = try await catalog.search(query: "工具", kind: .mcp, page: 2, refresh: false)
    #expect(second.entries.map(\.pluginID) == ["combined"])
    #expect(second.nextPage == nil)
  }

  @Test(arguments: [
    "https://evil.example/orgs/computer-mcp/repos?page=2",
    "https://api.github.com/orgs/other/repos?page=2",
    "https://api.github.com/orgs/computer-mcp/repos?page=1",
  ])
  func rejectsInvalidPaginationWithoutFollowingItsURL(_ link: String) async throws {
    let http = CatalogHTTPFake(repositories: [])
    await http.setPage(1, repositories: [], link: "<\(link)>; rel=\"next\"")
    await #expect(throws: PluginCatalogError.invalidResponse) {
      try await GitHubPluginCatalog(http: http).search()
    }
    #expect(await http.requests.count == 1)
  }

  @Test
  func invalidDeclarationsAndPublishersDoNotHideValidNeighbors() async throws {
    var forged = catalogRepository("forged", id: 1)
    forged["owner"] = .object([
      "id": .number(99), "login": .string("computer-mcp"), "type": .string("Organization"),
    ])
    let http = CatalogHTTPFake(repositories: [
      forged, catalogRepository("broken", id: 2), catalogRepository("combined", id: 3),
    ])
    await http.setManifest("invalid [[[", repository: "broken")
    await http.setManifest(catalogManifest, repository: "combined")
    let result = try await GitHubPluginCatalog(http: http).search()
    #expect(result.entries.map(\.repository) == ["computer-mcp/combined"])
    #expect(
      Set(result.issues.map(\.code)) == [
        "plugin.catalog.invalid_provenance", "plugin.catalog.invalid_manifest",
      ])
    #expect(await http.requests.allSatisfy { !$0.path.contains("forged") })
  }

  @Test
  func mismatchedBlobDigestIsNotAcceptedAsADeclaration() async throws {
    let http = CatalogHTTPFake(repositories: [catalogRepository("combined", id: 1)])
    await http.setManifest(
      catalogManifest, repository: "combined", digest: String(repeating: "0", count: 40))
    let result = try await GitHubPluginCatalog(http: http).search()
    #expect(result.entries.isEmpty)
    #expect(result.issues.map(\.code) == ["plugin.catalog.invalid_response"])
  }

  @Test
  func rateLimitIsAFailureAndIsNotCachedAsAnEmptyPage() async throws {
    let http = CatalogHTTPFake(repositories: [])
    await http.setResponse(
      PluginCatalogHTTPResponse(status: 429, headers: ["retry-after": "17"], body: Data()),
      key: "page:1")
    let catalog = GitHubPluginCatalog(http: http)
    await #expect(throws: PluginCatalogError.rateLimited(retryAfterSeconds: 17)) {
      try await catalog.search()
    }
    await http.setPage(1, repositories: [])
    let result = try await catalog.search()
    #expect(!result.cached && result.entries.isEmpty && result.issues.isEmpty)
    #expect(await http.requests.count == 2)
  }

  @Test
  func malformedRepositoryResponsesAreNotEmptySuccess() async throws {
    let http = CatalogHTTPFake(repositories: [])
    await http.setResponse(
      PluginCatalogHTTPResponse(
        status: 200, headers: ["content-type": "text/html"], body: Data("[]".utf8)), key: "page:1")
    await #expect(throws: PluginCatalogError.invalidResponse) {
      try await GitHubPluginCatalog(http: http).search()
    }
    await http.setPage(
      1, repositories: [catalogRepository("same", id: 1), catalogRepository("same", id: 2)])
    await #expect(throws: PluginCatalogError.invalidResponse) {
      try await GitHubPluginCatalog(http: http).search()
    }
  }

  @Test
  func invalidInputsDoNotReachTheNetwork() async throws {
    let http = CatalogHTTPFake(repositories: [])
    let catalog = GitHubPluginCatalog(http: http)
    await #expect(throws: PluginCatalogError.invalidQuery) {
      try await catalog.search(query: String(repeating: "a", count: 257))
    }
    await #expect(throws: PluginCatalogError.invalidQuery) { try await catalog.search(page: 0) }
    #expect(await http.requests.isEmpty)
  }
}

private struct FailingCatalogHTTP: PluginCatalogHTTPFetching {
  let code: URLError.Code
  func fetch(path: String, query: [String: String], accept: String, maxBytes: Int) async throws
    -> PluginCatalogHTTPResponse
  { throw URLError(code) }
}

private final class CatalogClock: @unchecked Sendable {
  private let lock = NSLock()
  private var instant = Date(timeIntervalSince1970: 1_788_846_000)
  var now: Date { lock.withLock { instant } }
  func advance(_ seconds: TimeInterval) { lock.withLock { instant.addTimeInterval(seconds) } }
}

private let catalogCommit = String(repeating: "a", count: 40)
private let catalogManifest = """
  id = 'combined'
  name = 'Combined 工具'
  version = '1.0.0'
  repository = 'https://github.com/someone-else/claim'
  [[dependencies]]
  id = 'vendor'
  commands = ['vendor']
  instructions = 'Install separately.'
  [[mcp]]
  id = 'native'
  transport = 'http'
  url = 'https://example.invalid/mcp'
  [[cli]]
  id = 'command'
  executable = { dependency = 'vendor' }
  [[skills]]
  id = 'guidance'
  path = 'skills'
  """

private func catalogRepository(_ name: String, id: Int) -> [String: JSONValue] {
  [
    "id": .number(Double(id)), "name": .string(name), "full_name": .string("computer-mcp/\(name)"),
    "private": .bool(false), "archived": .bool(false), "disabled": .bool(false),
    "default_branch": .string("main"),
    "owner": .object([
      "id": .number(315_005_910), "login": .string("computer-mcp"), "type": .string("Organization"),
    ]),
  ]
}

private actor CatalogHTTPFake: PluginCatalogHTTPFetching {
  struct Request: Sendable {
    let path: String
    let query: [String: String]
    let accept: String
  }
  private(set) var requests: [Request] = []
  private var responses: [String: PluginCatalogHTTPResponse] = [:]

  init(repositories: [[String: JSONValue]]) {
    responses["page:1"] = Self.json(.array(repositories.map(JSONValue.object)))
  }

  func setPage(_ page: Int, repositories: [[String: JSONValue]], link: String? = nil) {
    var headers = ["content-type": "application/json"]
    headers["link"] = link
    responses["page:\(page)"] = Self.json(
      .array(repositories.map(JSONValue.object)), headers: headers)
  }

  func setResponse(_ response: PluginCatalogHTTPResponse, key: String) { responses[key] = response }

  func setManifest(_ text: String, repository: String, digest: String? = nil) {
    let bytes = Data(text.utf8)
    let hash =
      digest
      ?? Insecure.SHA1.hash(data: Data("blob \(bytes.count)\0".utf8) + bytes).map {
        String(format: "%02x", $0)
      }.joined()
    responses["/repos/computer-mcp/\(repository)/contents/\(PluginManifest.filename)"] = Self.json(
      .object([
        "type": .string("file"), "path": .string(PluginManifest.filename),
        "encoding": .string("base64"),
        "size": .number(Double(bytes.count)), "sha": .string(hash),
        "content": .string(bytes.base64EncodedString()),
      ]))
  }

  func fetch(path: String, query: [String: String], accept: String, maxBytes: Int) async throws
    -> PluginCatalogHTTPResponse
  {
    requests.append(Request(path: path, query: query, accept: accept))
    if path.contains("/commits/") {
      return PluginCatalogHTTPResponse(
        status: 200, headers: ["content-type": "text/plain"], body: Data(catalogCommit.utf8))
    }
    let key = path == "/orgs/computer-mcp/repos" ? "page:\(query["page"] ?? "")" : path
    return responses[key] ?? PluginCatalogHTTPResponse(status: 404, headers: [:], body: Data())
  }

  private static func json(
    _ value: JSONValue, headers: [String: String] = ["content-type": "application/json"]
  ) -> PluginCatalogHTTPResponse {
    PluginCatalogHTTPResponse(status: 200, headers: headers, body: try! JSONEncoder().encode(value))
  }
}
