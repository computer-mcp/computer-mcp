import CryptoKit
import Foundation
import Testing

@testable import ComputerMCP

@Suite(.timeLimit(.minutes(1)))
struct StaticPluginCatalogTests {
  @Test
  func decodesPublisherGeneratedCanonicalBytesAndExactIdentity() throws {
    let data = try staticCatalogFixture()
    let document = try StaticPluginCatalogDocument.decode(data)
    #expect(document.revision == "5c751086b1b61120cc2addc21d5a2e3f6d7baa22299774277bddfe762d6f4651")
    let release = try #require(document.releases.first)
    #expect(release.name == "工具 Plugin")
    #expect(release.dependencies.first?.commands == ["python3"])
    #expect(release.matches(host: try PluginVersion("2.0.0"), architecture: "arm64"))
    #expect(!release.matches(host: try PluginVersion("3.0.0"), architecture: "arm64"))
    #expect(!release.matches(host: try PluginVersion("2.0.0"), architecture: "x86_64"))
    let exact = try staticCatalogData { root in
      var values = root["releases"]!.arrayValue!
      var release = values[0].objectValue!
      release["repository_id"] = .integer(9_007_199_254_740_991)
      values[0] = .object(release)
      root["releases"] = .array(values)
    }
    #expect(
      try StaticPluginCatalogDocument.decode(exact).releases[0].declaration.repositoryID
        == 9_007_199_254_740_991)
  }

  @Test(arguments: [
    "schema", "publisher", "unknown", "duplicate", "asset-origin", "asset-id", "range",
    "withdrawal", "contribution", "revision", "truncated", "oversized",
  ])
  func rejectsInvalidDocuments(_ fault: String) throws {
    var bytes = try staticCatalogData { root in
      switch fault {
      case "schema": root["schema_version"] = .integer(2)
      case "publisher":
        root["publisher"] = .object(["login": .string("computer-mcp"), "id": .integer(999)])
      case "unknown": root["extra"] = .bool(true)
      default:
        var release = root["releases"]!.arrayValue![0].objectValue!
        switch fault {
        case "duplicate":
          root["releases"] = .array([.object(release), .object(release)])
          return
        case "asset-origin", "asset-id":
          var asset = release["assets"]!.arrayValue![0].objectValue!
          asset[fault == "asset-origin" ? "url" : "id"] =
            fault == "asset-origin" ? .string("https://evil.example/plugin.zip") : .integer(0)
          release["assets"] = .array([.object(asset)])
        case "range":
          var compatibility = release["compatibility"]!.objectValue!
          compatibility["maximum_host"] = .string("0.5.0")
          release["compatibility"] = .object(compatibility)
        case "withdrawal": release["withdrawn"] = .bool(true)
        case "contribution":
          release["contributions"] = .object([
            "mcp": .array([.string("same")]), "cli": .array([.string("same")]),
            "skills": .array([]),
          ])
        default: break
        }
        root["releases"] = .array([.object(release)])
      }
    }
    if fault == "revision" {
      bytes = Data(
        String(decoding: bytes, as: UTF8.self).replacingOccurrences(
          of: "工具 Plugin", with: "Other Plugin"
        ).utf8)
    } else if fault == "truncated" {
      bytes.removeLast(10)
    } else if fault == "oversized" {
      bytes = Data(repeating: 32, count: StaticPluginCatalogDocument.maximumBytes + 1)
    }
    #expect(throws: PluginCatalogError.self) { try StaticPluginCatalogDocument.decode(bytes) }
  }

  @Test
  func rejectsDuplicateKeysAndNonCanonicalNumbers() throws {
    let string = String(decoding: try staticCatalogFixture(), as: UTF8.self)
    for changed in [
      string.replacingOccurrences(
        of: "\"generation\": 1,", with: "\"generation\": 1,\n  \"generation\": 1,"),
      string.replacingOccurrences(of: "\"generation\": 1,", with: "\"generation\": 1.0,"),
    ] {
      #expect(throws: PluginCatalogError.self) {
        try StaticPluginCatalogDocument.decode(Data(changed.utf8))
      }
    }
  }

  @Test
  func cachedFiltersPagesAndExactReleaseSelectionMakeOneRequest() async throws {
    let http = StaticCatalogHTTPFake([.success(try staticCatalogResponse())])
    let catalog = StaticPluginCatalog(http: http)
    let filter = StaticPluginCatalog.Filter(host: try PluginVersion("2.0.0"), architecture: "arm64")
    let first = try await catalog.search(
      query: "工具", kind: .mcp, page: 1, refresh: false, filter: filter)
    #expect(first.entries.map(\.pluginID) == ["example"] && first.catalog?.stale == false)
    let empty = try await catalog.search(
      query: "absent", kind: .cli, page: 1, refresh: false, filter: filter)
    #expect(empty.entries.isEmpty && empty.cached && empty.nextPage == nil)
    let secondPage = try await catalog.search(
      query: "", kind: nil, page: 2, refresh: false, filter: filter)
    #expect(secondPage.entries.isEmpty && secondPage.nextPage == nil)
    let release = try await catalog.artifacts(
      repository: "computer-mcp/plugin-example", repositoryID: 10, tag: "v1.0.0", page: 1,
      filter: filter)
    #expect(release.artifacts.first?.declaration == first.entries.first)
    #expect(release.versions.map(\.tag) == ["v1.0.0"])
    #expect(release.versions.first?.dependencies.first?.id == "runtime")
    #expect(await http.validators.count == 1)
    await #expect(throws: PluginCatalogError.httpStatus(404)) {
      try await catalog.artifacts(
        repository: "computer-mcp/plugin-example", repositoryID: 11, tag: "v1.0.0", page: 1,
        filter: filter)
    }
    #expect(await http.validators.count == 1)
  }

  @Test
  func latestCompatibleVersionsAreChosenBeforeLocalPaging() async throws {
    let data = try staticCatalogData { root in
      let template = root["releases"]!.arrayValue![0].objectValue!
      func release(_ index: Int, version: String = "1.0.0", sequence: Int = 0) -> JSONValue {
        var value = template
        let name = String(format: "example-%02d", index)
        let repository = "computer-mcp/plugin-\(name)"
        let tag = "v\(version)"
        value["repository"] = .string(repository)
        value["repository_id"] = .integer(Int64(index))
        value["plugin_id"] = .string(name)
        value["version"] = .string(version)
        value["tag"] = .string(tag)
        value["release_id"] = .integer(Int64(index * 10 + sequence))
        var asset = template["assets"]!.arrayValue![0].objectValue!
        asset["id"] = .integer(Int64(index * 10 + sequence))
        asset["url"] = .string(
          "https://github.com/\(repository)/releases/download/\(tag)/example.zip")
        value["assets"] = .array([.object(asset)])
        return .object(value)
      }
      var releases = (1...12).map { release($0) }
      releases.append(release(1, version: "1.1.0", sequence: 1))
      var beta = release(1, version: "2.0.0-beta.1", sequence: 2).objectValue!
      beta["prerelease"] = .bool(true)
      releases.append(.object(beta))
      var incompatible = release(1, version: "3.0.0", sequence: 3).objectValue!
      var compatibility = incompatible["compatibility"]!.objectValue!
      compatibility["minimum_host"] = .string("5.0.0")
      compatibility["maximum_host"] = .null
      incompatible["compatibility"] = .object(compatibility)
      releases.append(.object(incompatible))
      root["releases"] = .array(releases)
    }
    let http = StaticCatalogHTTPFake([.success(staticCatalogResponse(data))])
    let catalog = StaticPluginCatalog(http: http)
    let filter = StaticPluginCatalog.Filter(host: try PluginVersion("2.0.0"), architecture: "arm64")
    let first = try await catalog.search(
      query: "", kind: .mcp, page: 1, refresh: false, filter: filter)
    let second = try await catalog.search(
      query: "", kind: .mcp, page: 2, refresh: false, filter: filter)
    #expect(first.entries.count == 10 && first.nextPage == 2)
    #expect(first.entries.first?.version == (try PluginVersion("1.1.0")))
    #expect(
      second.entries.map(\.pluginID) == ["example-11", "example-12"] && second.nextPage == nil)
    let artifacts = try await catalog.artifacts(
      repository: "computer-mcp/plugin-example-01", repositoryID: 1, tag: nil, page: 1,
      filter: filter)
    #expect(artifacts.tag == "v1.1.0")
    #expect(artifacts.versions.map(\.tag) == ["v3.0.0", "v2.0.0-beta.1", "v1.1.0", "v1.0.0"])
    #expect(artifacts.versions.first?.compatible == false)
    let beta = try await catalog.artifacts(
      repository: "computer-mcp/plugin-example-01", repositoryID: 1, tag: "v2.0.0-beta.1", page: 1,
      filter: filter)
    #expect(beta.prerelease && beta.artifacts.count == 1)
    #expect(await http.validators.count == 1)
  }

  @Test
  func withdrawnAndIncompatibleVersionsRemainVisibleWithoutInstallableArtifacts() async throws {
    for withdrawn in [true, false] {
      let data = try staticCatalogData { root in
        var release = root["releases"]!.arrayValue![0].objectValue!
        if withdrawn {
          release["withdrawn"] = .bool(true)
          release["withdrawal_reason"] = .string("This version was withdrawn by the publisher.")
        }
        root["releases"] = .array([.object(release)])
      }
      let catalog = StaticPluginCatalog(
        http: StaticCatalogHTTPFake([.success(staticCatalogResponse(data))]))
      let filter = StaticPluginCatalog.Filter(
        host: try PluginVersion("2.0.0"), architecture: "x86_64")
      let search = try await catalog.search(
        query: "", kind: nil, page: 1, refresh: false, filter: filter)
      #expect(search.entries.isEmpty)
      let release = try await catalog.artifacts(
        repository: "computer-mcp/plugin-example", repositoryID: 10, tag: "v1.0.0", page: 1,
        filter: filter)
      #expect(release.artifacts.isEmpty && release.versions.count == 1)
      #expect(
        release.issues.first?.code
          == (withdrawn ? "plugin.catalog.withdrawn" : "plugin.catalog.incompatible"))
    }
  }

  @Test
  func conditionalRefreshAndRestartReuseTheSamePersistedSnapshot() async throws {
    let files = try ArchiveFixture()
    defer { files.remove() }
    let cache = files.root.appendingPathComponent("catalog/cache.json")
    let clock = StaticCatalogClock()
    let http = StaticCatalogHTTPFake([
      .success(try staticCatalogResponse()),
      .success(.init(status: 304, headers: [:], body: Data())),
    ])
    let catalog = StaticPluginCatalog(cacheURL: cache, http: http, now: { clock.now })
    let first = try await catalog.load()
    clock.advance(1)
    #expect(try await catalog.load(refresh: true).cached)
    #expect(await http.validators.count == 1)
    clock.advance(StaticPluginCatalog.refreshInterval)
    let revalidated = try await catalog.load()
    #expect(revalidated.value.document == first.value.document && !revalidated.status.stale)
    #expect(revalidated.value.record.validatedAt == clock.now)
    #expect(await http.validators.last?.etag == "\"fixture-v1\"")
    let offline = StaticCatalogHTTPFake([])
    let reopened = StaticPluginCatalog(cacheURL: cache, http: offline, now: { clock.now })
    #expect(try await reopened.load().value.document == first.value.document)
    #expect(await offline.validators.isEmpty)
    clock.advance(StaticPluginCatalog.refreshInterval)
    let stale = try await reopened.load()
    #expect(stale.status.stale && stale.cached && stale.value.document == first.value.document)
    #expect(stale.issues.first?.code == PluginCatalogError.networkUnavailable.code)
    #expect(try await StaticPluginCatalogCache(url: cache).read()?.body == first.value.record.body)
  }

  @Test(arguments: ["invalid", "rollback", "conflict", "server", "rate"])
  func failedRefreshRetainsMemoryAndDiskAndRespectsBackoff(_ fault: String) async throws {
    let files = try ArchiveFixture()
    defer { files.remove() }
    let cacheURL = files.root.appendingPathComponent("cache.json")
    let clock = StaticCatalogClock()
    let data = try staticCatalogData { root in root["generation"] = .integer(2) }
    let failed: PluginCatalogHTTPResponse
    switch fault {
    case "rollback": failed = try staticCatalogResponse()
    case "conflict":
      failed = staticCatalogResponse(
        try staticCatalogData { root in
          root["generation"] = .integer(2)
          root["releases"] = .array([])
        })
    case "server": failed = .init(status: 503, headers: [:], body: Data())
    case "rate": failed = .init(status: 429, headers: ["retry-after": "3600"], body: Data())
    default:
      failed = .init(
        status: 200, headers: ["content-type": "application/json"], body: Data("{truncated".utf8))
    }
    let http = StaticCatalogHTTPFake([.success(staticCatalogResponse(data)), .success(failed)])
    let catalog = StaticPluginCatalog(cacheURL: cacheURL, http: http, now: { clock.now })
    let first = try await catalog.load()
    let disk = try Data(contentsOf: cacheURL)
    clock.advance(601)
    let stale = try await catalog.load()
    #expect(stale.value.document == first.value.document && stale.status.stale)
    clock.advance(fault == "rate" ? 3_599 : 59)
    #expect(try await catalog.load(refresh: true).status.stale)
    #expect(await http.validators.count == 2)
    #expect(try Data(contentsOf: cacheURL) == disk)
  }

  @Test
  func invalidInitialResponseNeverBecomesAnEmptySuccessfulCatalog() async throws {
    let clock = StaticCatalogClock()
    let http = StaticCatalogHTTPFake([.success(.init(status: 304, headers: [:], body: Data()))])
    let catalog = StaticPluginCatalog(http: http, now: { clock.now })
    await #expect(throws: PluginCatalogError.invalidResponse) { try await catalog.load() }
    await #expect(throws: PluginCatalogError.invalidResponse) {
      try await catalog.load(refresh: true)
    }
    #expect(await http.validators.count == 1)
  }

  @Test
  func concurrentReadersShareOneRequestAndOneCancelledReaderDoesNotCancelOthers() async throws {
    let http = GatedStaticCatalogHTTP()
    let catalog = StaticPluginCatalog(http: http)
    let first = Task { try await catalog.load() }
    await http.waitForRequest()
    let second = Task { try await catalog.load() }
    first.cancel()
    await http.finish(try staticCatalogResponse())
    await #expect(throws: CancellationError.self) { try await first.value }
    #expect(try await second.value.value.document.releases.count == 1)
    #expect(await http.calls == 1)
  }

  @Test
  func cacheCannotBeReplacedByOlderGenerationsOrFollowSymlinks() async throws {
    let files = try ArchiveFixture()
    defer { files.remove() }
    let url = files.root.appendingPathComponent("catalog/cache.json")
    let cache = StaticPluginCatalogCache(url: url)
    let current = StaticPluginCatalogCacheRecord(
      body: try staticCatalogData { $0["generation"] = .integer(2) }, validators: .init(),
      validatedAt: .now)
    try await cache.write(current)
    let before = try Data(contentsOf: url)
    await #expect(throws: PluginCatalogError.invalidProvenance) {
      try await cache.write(
        .init(body: staticCatalogFixture(), validators: .init(), validatedAt: .now))
    }
    #expect(try Data(contentsOf: url) == before)
    let target = files.root.appendingPathComponent("unrelated")
    try before.write(to: target)
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    await #expect(throws: PluginCatalogError.unsafeRequest) { try await cache.read() }
    await #expect(throws: PluginCatalogError.unsafeRequest) { try await cache.write(current) }
    #expect(try Data(contentsOf: target) == before)
  }

  @Test
  func newerSnapshotsRetainOldIdentityAndCannotUndoWithdrawal() throws {
    let original = try StaticPluginCatalogDocument.decode(staticCatalogFixture())
    let withdrawn = try StaticPluginCatalogDocument.decode(
      staticCatalogData { root in
        root["generation"] = .integer(2)
        var release = root["releases"]!.arrayValue![0].objectValue!
        release["withdrawn"] = .bool(true)
        release["withdrawal_reason"] = .string("Retired")
        root["releases"] = .array([.object(release)])
      })
    try withdrawn.validateSuccessor(of: original)
    let restored = try StaticPluginCatalogDocument.decode(
      staticCatalogData { $0["generation"] = .integer(3) })
    #expect(throws: PluginCatalogError.invalidProvenance) {
      try restored.validateSuccessor(of: withdrawn)
    }
    let missing = try StaticPluginCatalogDocument.decode(
      staticCatalogData { root in
        root["generation"] = .integer(3)
        root["releases"] = .array([])
      })
    #expect(throws: PluginCatalogError.invalidProvenance) {
      try missing.validateSuccessor(of: original)
    }
  }
}

func staticCatalogFixture() throws -> Data {
  let url = try #require(
    Bundle.module.url(
      forResource: "plugin-catalog-v1", withExtension: "json", subdirectory: "Fixtures"))
  return try Data(contentsOf: url)
}

func staticCatalogData(_ edit: (inout [String: JSONValue]) -> Void) throws -> Data {
  var root = try #require(
    JSONDecoder().decode(JSONValue.self, from: staticCatalogFixture()).objectValue)
  edit(&root)
  let content = root.filter { !["generation", "revision", "generated_at"].contains($0.key) }
  let digest = SHA256.hash(data: try StaticPluginCatalogDocument.canonical(.object(content)))
    .map { String(format: "%02x", $0) }.joined()
  root["revision"] = .string(digest)
  return try StaticPluginCatalogDocument.canonical(.object(root))
}

func staticCatalogResponse(_ data: Data) -> PluginCatalogHTTPResponse {
  .init(
    status: 200, headers: ["content-type": "application/json", "etag": "\"fixture-v1\""], body: data
  )
}

func staticCatalogResponse() throws -> PluginCatalogHTTPResponse {
  staticCatalogResponse(try staticCatalogFixture())
}

actor StaticCatalogHTTPFake: StaticPluginCatalogFetching {
  var replies: [Result<PluginCatalogHTTPResponse, PluginCatalogError>]
  private(set) var validators: [StaticPluginCatalogValidators] = []
  init(_ replies: [Result<PluginCatalogHTTPResponse, PluginCatalogError>]) {
    self.replies = replies
  }
  func fetch(validators: StaticPluginCatalogValidators) async throws -> PluginCatalogHTTPResponse {
    self.validators.append(validators)
    guard !replies.isEmpty else { throw PluginCatalogError.networkUnavailable }
    return try replies.removeFirst().get()
  }
}

private actor GatedStaticCatalogHTTP: StaticPluginCatalogFetching {
  private var response: CheckedContinuation<PluginCatalogHTTPResponse, any Error>?
  private var started: CheckedContinuation<Void, Never>?
  private(set) var calls = 0
  func fetch(validators: StaticPluginCatalogValidators) async throws -> PluginCatalogHTTPResponse {
    calls += 1
    return try await withCheckedThrowingContinuation {
      response = $0
      started?.resume()
      started = nil
    }
  }
  func waitForRequest() async {
    if calls == 0 { await withCheckedContinuation { started = $0 } }
  }
  func finish(_ value: PluginCatalogHTTPResponse) {
    response?.resume(returning: value)
    response = nil
  }
}

final class StaticCatalogClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value = Date(timeIntervalSince1970: 1_790_559_000)
  var now: Date { lock.withLock { value } }
  func advance(_ interval: TimeInterval) { lock.withLock { value.addTimeInterval(interval) } }
}
