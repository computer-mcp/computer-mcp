import ComputerMCPMacOS
import ComputerMCPTestSupport
import CryptoKit
import Foundation
import Testing

@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPlatform
@testable import ComputerMCPPlugins

@Suite(.timeLimit(.minutes(1)))
struct GitHubPluginReleasesTests {
  @Test
  func releaseManifestRefusalSurvivesTheMetadataDeadlineBoundary() async throws {
    let artifact = pluginArtifactFixture()
    let http = ReleaseHTTPFake()
    await http.setManifest(
      releaseManifestFixture.replacingOccurrences(
        of: "plugin_api = 1", with: "plugin_api = 2\nfuture = true"))
    let releases = GitHubPluginReleases(http: http)
    let refusal = try #require(
      PluginAPIVersions.supported.refusal(
        pluginID: "combined", version: PluginVersion("1.2.3"), declared: 2))
    await #expect(throws: refusal) { try await releases.revalidate(artifact) }
    #expect(await http.assetPages.isEmpty)
  }

  @Test(arguments: ["correct", "forged", "omitted"])
  func selectedTargetIsRevalidatedAgainstTheExactTag(fault: String) async throws {
    let manifest = PreparationFixture.platformManifest.replacingOccurrences(
      of: "mac.zip", with: "combined.zip")
    let http = ReleaseHTTPFake(manifest: manifest)
    var artifact = pluginArtifactFixture(manifest: manifest)
    if fault != "omitted" {
      artifact.compatibility = try PluginPlatformCompatibility(
        platforms: ["macos"], architectures: [fault == "forged" ? "x86_64" : "arm64"])
    }
    if fault == "correct" {
      try await GitHubPluginReleases(http: http).revalidate(artifact)
    } else {
      await #expect(throws: PluginCatalogError.invalidProvenance) {
        try await GitHubPluginReleases(http: http).revalidate(artifact)
      }
    }
    #expect(await http.manifestRefs == [artifact.declaration.revision])
  }

  @Test
  func cancellationDuringDownloadReclaimsOnlyItsReceiptedStaging() async throws {
    let fixture = try await PreparationFixture.make(
      directoryFactory: MacOSPlatform.services.pluginDirectories, format: "zip")
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
    let store = PluginStore(database: database, platform: MacOSPlatform.services)
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
        try await PluginStore(database: database, platform: MacOSPlatform.services)
          .recoverInstallations(storageRoot: root)
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
    let fixture = try await PreparationFixture.make(
      directoryFactory: MacOSPlatform.services.pluginDirectories, format: "zip")
    defer { fixture.files.remove() }
    let bytes = try Data(contentsOf: fixture.archive)
    let server = try await CatalogHTTPFixture.start(script: pluginDownloadHTTPFixture(bytes: bytes))
    defer { server.stop() }
    let http = ReleaseHTTPFake(manifest: PreparationFixture.manifest, artifactBytes: bytes)
    let artifact = pluginArtifactFixture(bytes: bytes, manifest: PreparationFixture.manifest)
    let database = try GatewayDatabase(
      path: fixture.files.root.appendingPathComponent("download.sqlite").path)
    let store = PluginStore(database: database, platform: MacOSPlatform.services)
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
        path: fixture.files.root.appendingPathComponent("download.sqlite").path),
      platform: MacOSPlatform.services)
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
    let fixture = try await PreparationFixture.make(
      directoryFactory: MacOSPlatform.services.pluginDirectories, format: "zip")
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
    let store = PluginStore(database: database, platform: MacOSPlatform.services)
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
    let artifact = pluginArtifactFixture()
    try await releases.revalidate(artifact)
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

  @Test(arguments: ["digest", "size", "upload"])
  func incompleteSelectedArchivesFailRevalidation(_ fault: String) async throws {
    let http = ReleaseHTTPFake()
    var asset = releaseAssetFixture()
    if fault == "digest" { asset["digest"] = .null }
    if fault == "size" { asset["size"] = .integer(Int64(PluginArchiveLimits().archiveBytes + 1)) }
    if fault == "upload" { asset["state"] = .string("starter") }
    await http.setAssets([asset], page: 1)
    await #expect(throws: PluginCatalogError.self) {
      try await GitHubPluginReleases(http: http).revalidate(pluginArtifactFixture())
    }
  }

  @Test(arguments: [
    "publisher", "repository", "tag", "commit", "removed", "digest", "size", "name",
  ])
  func rejectsChangedSelections(_ change: String) async throws {
    let http = ReleaseHTTPFake()
    let releases = GitHubPluginReleases(http: http)
    let selected = pluginArtifactFixture()
    await http.change(change)
    await #expect(throws: PluginCatalogError.invalidProvenance) {
      try await releases.revalidate(selected)
    }
  }

  @Test
  func explicitPrereleaseIsRevalidatedByImmutableReleaseID() async throws {
    let http = ReleaseHTTPFake()
    await http.setPrerelease()
    let original = pluginArtifactFixture()
    let selected = GitHubPluginArtifact(
      declaration: original.declaration, releaseID: original.releaseID, tag: original.tag,
      prerelease: true, assetID: original.assetID, name: original.name, size: original.size,
      sha256: original.sha256)
    try await GitHubPluginReleases(http: http).revalidate(selected)
    #expect(await http.paths.contains("/repos/computer-mcp/combined/releases/9"))
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
      try await GitHubPluginReleases(http: http).revalidate(pluginArtifactFixture())
    }
  }

  @Test
  func invalidSelectionNeverReachesNetwork() async throws {
    let http = ReleaseHTTPFake()
    await #expect(throws: PluginCatalogError.invalidResponse) {
      try await GitHubPluginReleases(http: http).revalidate(pluginArtifactFixture(assetID: 0))
    }
    #expect(await http.paths.isEmpty)
  }

  @Test
  func deadlineCancelsAndJoinsMetadataRequests() async throws {
    let http = SleepingReleaseHTTP()
    let releases = GitHubPluginReleases(http: http, timeout: .milliseconds(30))
    await #expect(throws: PluginCatalogError.timedOut) {
      try await releases.revalidate(pluginArtifactFixture())
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
