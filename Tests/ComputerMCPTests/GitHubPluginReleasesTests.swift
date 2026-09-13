import CryptoKit
import Foundation
import Testing

@testable import ComputerMCP

@Suite(.timeLimit(.minutes(1)))
struct GitHubPluginReleasesTests {
  @Test
  func cancellationDuringDownloadReclaimsOnlyItsReceiptedStaging() async throws {
    let fixture = try await PreparationFixture.make(format: "zip")
    defer { fixture.files.remove() }
    let bytes = try Data(contentsOf: fixture.archive)
    let server = try await CatalogHTTPFixture.start(script: pluginDownloadHTTPFixture(bytes: bytes))
    defer { server.stop() }
    let http = ReleaseHTTPFake(manifest: PreparationFixture.manifest, artifactBytes: bytes)
    let artifact = pluginArtifactFixture(
      bytes: bytes, assetID: 20, manifest: PreparationFixture.manifest)
    await http.setAssets([releaseAssetFixture(id: 20, artifact: artifact)], page: 1)
    let database = try GatewayDatabase(
      path: fixture.files.root.appendingPathComponent("cancel.sqlite").path)
    let store = PluginStore(database: database)
    let root = fixture.files.root.appendingPathComponent("Plugins")
    let download = GitHubPluginDownload(origin: server.origin)
    let task = Task {
      try await store.installGitHubArtifact(
        artifact, hostVersion: PluginVersion("1.0.0"), architecture: "arm64", storageRoot: root,
        workerExecutable: fixture.preparation.workerExecutable, expectedRevision: 0,
        releases: GitHubPluginReleases(http: http), download: download)
    }
    do {
      let ready = try await GitHubCatalogHTTPClient(origin: server.origin).fetch(
        path: "/wait", query: [:], accept: "application/json", maxBytes: 128)
      #expect(try ready.decode(JSONValue.self) == .bool(true))
      #expect(try database.pluginOwnedDirectories().count == 1)
      #expect(try await store.snapshot().installations.isEmpty)
      await #expect(throws: PluginStoreError.installationBusy) {
        try await PluginStore(database: database).recoverInstallations(storageRoot: root)
      }
      task.cancel()
      await #expect(throws: CancellationError.self) { try await task.value }
    } catch {
      task.cancel()
      _ = try? await task.value
      throw error
    }
    #expect(try database.pluginOwnedDirectories().isEmpty)
    #expect(try await store.snapshot().revision == 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["store.lock"])
    #expect(try Data(contentsOf: fixture.archive) == bytes)
  }

  @Test
  func downloadedCompositionUsesTheOwnedInstallationTransaction() async throws {
    let fixture = try await PreparationFixture.make(format: "zip")
    defer { fixture.files.remove() }
    let bytes = try Data(contentsOf: fixture.archive)
    let server = try await CatalogHTTPFixture.start(script: pluginDownloadHTTPFixture(bytes: bytes))
    defer { server.stop() }
    let http = ReleaseHTTPFake(manifest: PreparationFixture.manifest, artifactBytes: bytes)
    let artifact = pluginArtifactFixture(bytes: bytes, manifest: PreparationFixture.manifest)
    let database = try GatewayDatabase(
      path: fixture.files.root.appendingPathComponent("download.sqlite").path)
    let store = PluginStore(database: database)
    let root = fixture.files.root.appendingPathComponent("Plugins")
    let result = try await store.installGitHubArtifact(
      artifact, hostVersion: PluginVersion("1.0.0"), architecture: "arm64", storageRoot: root,
      workerExecutable: fixture.preparation.workerExecutable, expectedRevision: 0,
      releases: GitHubPluginReleases(http: http),
      download: GitHubPluginDownload(origin: server.origin))
    let record = try #require(result.snapshot.installations.first)
    #expect(result.issues.isEmpty && record.source.githubRelease == artifact)
    #expect(record.source.repository == "https://github.com/computer-mcp/combined")
    #expect(
      record.source.revision == artifact.declaration.revision
        && record.source.artifactSHA256 == fixture.digest)
    #expect(result.snapshot.settings["combined"]?.enabled == false)
    #expect(result.snapshot.settings["combined"]?.mcp.keys.sorted() == ["native"])
    #expect(result.snapshot.settings["combined"]?.cli.keys.sorted() == ["commands"])
    #expect(result.snapshot.settings["combined"]?.skills.keys.sorted() == ["guide"])
    #expect(
      !FileManager.default.fileExists(
        atPath: record.source.root.appendingPathComponent("executed").path))
    #expect(
      !FileManager.default.fileExists(
        atPath: record.source.root.deletingLastPathComponent().appendingPathComponent("staging")
          .path))
    #expect(await http.assetPages == ["1", "1"])
    let reopened = PluginStore(
      database: try GatewayDatabase(
        path: fixture.files.root.appendingPathComponent("download.sqlite").path))
    #expect(try await reopened.snapshot() == result.snapshot)
    #expect(try await reopened.recoverInstallations(storageRoot: root).isEmpty)
    let removed = try await reopened.uninstallArtifact(
      installationID: record.id, storageRoot: root, expectedRevision: 1)
    #expect(removed.snapshot.installations.isEmpty && removed.issues.isEmpty)
    #expect(try database.pluginOwnedDirectories().isEmpty)
    #expect(try Data(contentsOf: fixture.archive) == bytes)
  }

  @Test(arguments: ["manifest", "download", "release", "revision"])
  func failedDownloadInstallationPreservesTheSelectedPackage(_ fault: String) async throws {
    let fixture = try await PreparationFixture.make(format: "zip")
    defer { fixture.files.remove() }
    let bytes = try Data(contentsOf: fixture.archive)
    let manifest =
      fault == "manifest" ? PreparationFixture.manifest + "\n" : PreparationFixture.manifest
    let http = ReleaseHTTPFake(manifest: manifest, artifactBytes: bytes)
    if fault == "release" { await http.changeAfterFirstValidation() }
    let server = try await CatalogHTTPFixture.start(script: pluginDownloadHTTPFixture(bytes: bytes))
    defer { server.stop() }
    let database = try GatewayDatabase(
      path: fixture.files.root.appendingPathComponent("failure.sqlite").path)
    let store = PluginStore(database: database)
    let root = fixture.files.root.appendingPathComponent("Plugins")
    let original = try await store.installArchive(
      at: fixture.archive, expectedSHA256: fixture.digest, pluginID: "combined",
      version: PluginVersion("1.2.3"), hostVersion: PluginVersion("1.0.0"), architecture: "arm64",
      storageRoot: root, workerExecutable: fixture.preparation.workerExecutable, expectedRevision: 0
    )
    let artifact = pluginArtifactFixture(
      bytes: bytes, assetID: fault == "download" ? 19 : 11, manifest: manifest)
    if fault == "download" {
      await http.setAssets([releaseAssetFixture(id: 19, artifact: artifact)], page: 1)
    }
    do {
      _ = try await store.installGitHubArtifact(
        artifact, hostVersion: PluginVersion("1.0.0"), architecture: "arm64", storageRoot: root,
        workerExecutable: fixture.preparation.workerExecutable,
        expectedRevision: fault == "revision" ? 0 : 1,
        releases: GitHubPluginReleases(http: http),
        download: GitHubPluginDownload(origin: server.origin))
      Issue.record("Invalid official installation committed")
    } catch {
      if fault == "download" {
        #expect(error as? PluginArchiveError == .checksumMismatch)
      } else if fault == "revision" {
        #expect(error as? PluginStoreError == .staleRevision(expected: 0, actual: 1))
      } else {
        #expect(error as? PluginCatalogError == .invalidProvenance)
      }
    }
    #expect(try await store.snapshot() == original.snapshot)
    #expect(try database.pluginOwnedDirectories().count == 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
    #expect(try Data(contentsOf: fixture.archive) == bytes)
  }

  @Test
  func pinsTheReleasedManifestAndRevalidatesMembershipAcrossPages() async throws {
    let http = ReleaseHTTPFake()
    let releases = GitHubPluginReleases(http: http)
    let page = try await releases.artifacts(repository: "computer-mcp/combined", repositoryID: 7)
    let artifact = try #require(page.artifacts.first)
    #expect(page.tag == "release/1.2.3" && !page.prerelease && page.issues.isEmpty)
    #expect(artifact == pluginArtifactFixture())
    #expect(
      await http.paths.contains("/repos/computer-mcp/combined/commits/refs/tags/release/1.2.3"))
    #expect(await http.manifestRefs == [artifact.declaration.revision])
    #expect(!(await http.paths.contains("/repos/computer-mcp/combined/commits/main")))
    await http.setAssets([], page: 1, next: 2)
    await http.setAssets([releaseAssetFixture()], page: 2)
    try await releases.revalidate(artifact)
    #expect(await http.paths.contains("/repos/computer-mcp/combined/releases/9"))
    #expect(await http.assetPages == ["1", "1", "2"])
    #expect(!(await http.paths.contains(artifact.apiPath)))
  }

  @Test
  func incompleteArchivesAreIssuesAndOtherAssetTypesAreIgnored() async throws {
    let http = ReleaseHTTPFake()
    var missingDigest = releaseAssetFixture(id: 12)
    missingDigest["digest"] = .null
    var oversized = releaseAssetFixture(id: 13)
    oversized["size"] = .number(Double(PluginArchiveLimits().archiveBytes + 1))
    var uploading = releaseAssetFixture(id: 14)
    uploading["state"] = .string("starter")
    var notes = releaseAssetFixture(id: 15)
    notes["name"] = .string("notes.md")
    await http.setAssets([missingDigest, oversized, uploading, notes], page: 1, next: 2)
    let result = try await GitHubPluginReleases(http: http).artifacts(
      repository: "computer-mcp/combined", repositoryID: 7)
    #expect(result.artifacts.isEmpty && result.issues.count == 3 && result.nextPage == 2)
  }

  @Test(arguments: [
    "publisher", "repository", "tag", "commit", "removed", "digest", "size", "name",
  ])
  func rejectsChangedSelections(_ change: String) async throws {
    let http = ReleaseHTTPFake()
    let releases = GitHubPluginReleases(http: http)
    let selected = try #require(
      try await releases.artifacts(repository: "computer-mcp/combined", repositoryID: 7).artifacts
        .first)
    await http.change(change)
    await #expect(throws: PluginCatalogError.invalidProvenance) {
      try await releases.revalidate(selected)
    }
  }

  @Test
  func explicitPrereleaseAndTagArePreserved() async throws {
    let http = ReleaseHTTPFake()
    await http.setPrerelease()
    let result = try await GitHubPluginReleases(http: http).artifacts(
      repository: "computer-mcp/combined", repositoryID: 7, tag: "release/1.2.3")
    #expect(result.prerelease && result.artifacts.first?.prerelease == true)
    #expect(await http.paths.contains("/repos/computer-mcp/combined/releases/tags/release/1.2.3"))
  }

  @Test(arguments: [
    "https://evil.invalid/assets?page=2",
    "https://api.github.com/repos/computer-mcp/combined/releases/8/assets?page=2",
    "https://api.github.com/repos/computer-mcp/combined/releases/9/assets?page=1",
  ])
  func rejectsInvalidContinuation(_ link: String) async throws {
    let http = ReleaseHTTPFake()
    await http.setLink(link)
    await #expect(throws: PluginCatalogError.invalidResponse) {
      try await GitHubPluginReleases(http: http).artifacts(
        repository: "computer-mcp/combined", repositoryID: 7)
    }
  }

  @Test
  func invalidRequestNeverReachesNetwork() async throws {
    let http = ReleaseHTTPFake()
    let releases = GitHubPluginReleases(http: http)
    await #expect(throws: PluginCatalogError.invalidProvenance) {
      try await releases.artifacts(repository: "another/combined", repositoryID: 7)
    }
    await #expect(throws: PluginCatalogError.invalidQuery) {
      try await releases.artifacts(repository: "computer-mcp/combined", repositoryID: 0)
    }
    await #expect(throws: PluginCatalogError.invalidQuery) {
      try await releases.artifacts(repository: "computer-mcp/combined", repositoryID: 7, page: 0)
    }
    #expect(await http.paths.isEmpty)
  }

  @Test
  func deadlineCancelsAndJoinsMetadataRequests() async throws {
    let http = SleepingReleaseHTTP()
    let releases = GitHubPluginReleases(http: http, timeout: .milliseconds(30))
    await #expect(throws: PluginCatalogError.timedOut) {
      try await releases.artifacts(repository: "computer-mcp/combined", repositoryID: 7)
    }
    #expect(await http.finished)
    #expect(await !http.active)
  }
}

private actor SleepingReleaseHTTP: PluginCatalogHTTPFetching {
  private(set) var active = false
  private(set) var finished = false
  func fetch(path: String, query: [String: String], accept: String, maxBytes: Int) async throws
    -> PluginCatalogHTTPResponse
  {
    active = true
    defer {
      active = false
      finished = true
    }
    try await Task.sleep(for: .seconds(20))
    throw PluginCatalogError.invalidResponse
  }
}

actor ReleaseHTTPFake: PluginCatalogHTTPFetching {
  private(set) var paths: [String] = []
  private(set) var manifestRefs: [String] = []
  private(set) var assetPages: [String] = []
  private var publisherID = 315_005_910
  private var repositoryID = 7
  private var tag = "release/1.2.3"
  private var revision = String(repeating: "a", count: 40)
  private var prerelease = false
  private var changeAfterValidation = false
  private let manifest: String
  private let artifactBytes: Data
  private var pages: [Int: [[String: JSONValue]]]
  private var links: [Int: String] = [:]

  init(
    manifest: String = releaseManifestFixture, artifactBytes: Data = Data("archive fixture".utf8)
  ) {
    self.manifest = manifest
    self.artifactBytes = artifactBytes
    pages = [
      1: [
        releaseAssetFixture(
          artifact: pluginArtifactFixture(bytes: artifactBytes, manifest: manifest))
      ]
    ]
  }

  func setAssets(_ values: [[String: JSONValue]], page: Int, next: Int? = nil) {
    pages[page] = values
    links[page] = next.map {
      "https://api.github.com/repos/computer-mcp/combined/releases/9/assets?page=\($0)"
    }
  }
  func setLink(_ link: String) { links[1] = link }
  func setPrerelease() { prerelease = true }
  func changeAfterFirstValidation() { changeAfterValidation = true }
  func change(_ kind: String) {
    switch kind {
    case "publisher": publisherID = 99
    case "repository": repositoryID = 8
    case "tag": tag = "different"
    case "commit": revision = String(repeating: "b", count: 40)
    case "removed": pages[1] = []
    case "digest": pages[1]![0]["digest"] = .string("sha256:" + String(repeating: "0", count: 64))
    case "size": pages[1]![0]["size"] = .number(123)
    case "name": pages[1]![0]["name"] = .string("changed.zip")
    default: break
    }
  }

  func fetch(path: String, query: [String: String], accept: String, maxBytes: Int) async throws
    -> PluginCatalogHTTPResponse
  {
    paths.append(path)
    let prefix = "/repos/computer-mcp/combined"
    if path == prefix {
      if changeAfterValidation && !assetPages.isEmpty { repositoryID = 8 }
      return json(
        .object([
          "id": .number(Double(repositoryID)), "name": .string("combined"),
          "full_name": .string("computer-mcp/combined"),
          "private": .bool(false), "archived": .bool(false), "disabled": .bool(false),
          "default_branch": .string("main"),
          "owner": .object([
            "id": .number(Double(publisherID)), "login": .string("computer-mcp"),
            "type": .string("Organization"),
          ]),
        ]))
    }
    if path.hasSuffix("/assets") {
      assetPages.append(query["page"] ?? "")
      let page = Int(query["page"] ?? "") ?? 1
      return json(.array((pages[page] ?? []).map(JSONValue.object)), link: links[page])
    }
    if path.hasPrefix(prefix + "/releases/") {
      return json(
        .object([
          "id": .number(9), "tag_name": .string(tag), "draft": .bool(false),
          "prerelease": .bool(prerelease),
          "published_at": .string("2026-09-08T00:00:00Z"),
        ]))
    }
    if path.hasPrefix(prefix + "/commits/") {
      return .init(status: 200, headers: [:], body: Data(revision.utf8))
    }
    if path.hasSuffix("/contents/" + PluginManifest.filename) {
      manifestRefs.append(query["ref"] ?? "")
      let bytes = Data(manifest.utf8)
      return json(
        .object([
          "type": .string("file"), "path": .string(PluginManifest.filename),
          "encoding": .string("base64"),
          "size": .number(Double(bytes.count)), "content": .string(bytes.base64EncodedString()),
          "sha": .string(pluginArtifactFixture(manifest: manifest).declaration.manifestBlobSHA),
        ]))
    }
    return .init(status: 404, headers: [:], body: Data())
  }

  private func json(_ value: JSONValue, link: String? = nil) -> PluginCatalogHTTPResponse {
    var headers = ["content-type": "application/json"]
    headers["link"] = link.map { "<\($0)>; rel=\"next\"" }
    return .init(status: 200, headers: headers, body: try! JSONEncoder().encode(value))
  }
}

private let releaseManifestFixture = """
  id = 'combined'
  name = 'Combined'
  version = '1.2.3'
  [[mcp]]
  id = 'native'
  transport = 'http'
  url = 'https://example.invalid/mcp'
  """

func pluginArtifactFixture(
  bytes: Data = Data("archive fixture".utf8), assetID: Int64 = 11,
  manifest text: String = releaseManifestFixture
)
  -> GitHubPluginArtifact
{
  let parsed = try! PluginManifest.parse(text)
  let manifest = Data(text.utf8)
  let blob = Data("blob \(manifest.count)\0".utf8) + manifest
  return GitHubPluginArtifact(
    declaration: PluginCatalogEntry(
      repositoryID: 7, repository: "computer-mcp/combined", publisherID: 315_005_910,
      revision: String(repeating: "a", count: 40),
      manifestBlobSHA: Insecure.SHA1.hash(data: blob).map { String(format: "%02x", $0) }.joined(),
      manifestSHA256: SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined(),
      pluginID: parsed.id, name: parsed.name, version: parsed.version,
      summary: parsed.description, mcp: parsed.mcp.map(\.id), cli: parsed.cli.map(\.id),
      skills: parsed.skills.map(\.id)),
    releaseID: 9, tag: "release/1.2.3", prerelease: false,
    assetID: assetID, name: "combined.zip", size: Int64(bytes.count),
    sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
}

func releaseAssetFixture(
  id: Int = 11, artifact: GitHubPluginArtifact = pluginArtifactFixture()
) -> [String: JSONValue] {
  return [
    "id": .number(Double(id)), "name": .string(artifact.name),
    "size": .number(Double(artifact.size)),
    "state": .string("uploaded"), "digest": .string("sha256:" + artifact.sha256),
    "url": .string("https://api.github.com/repos/computer-mcp/combined/releases/assets/\(id)"),
  ]
}
