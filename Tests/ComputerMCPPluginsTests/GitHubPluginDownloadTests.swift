import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPCore
@testable import ComputerMCPPlatform
@testable import ComputerMCPPlugins

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@Suite(.timeLimit(.minutes(1)))
struct GitHubPluginDownloadTests {
  private let bytes = Data(repeating: 65, count: 131_083)

  @Test(arguments: [11, 12])
  func downloadsDirectAndRedirectedContentWithoutAmbientCredentials(_ id: Int64) async throws {
    let fixture = try await CatalogHTTPFixture.start(script: downloadHTTPFixture)
    defer { fixture.stop() }
    let file = try DownloadFile()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpAdditionalHeaders = [
      "Authorization": "Bearer fixture-secret", "Cookie": "fixture-cookie",
    ]
    let client = GitHubPluginDownload(
      configuration: configuration, origin: fixture.origin, redirectOrigins: [fixture.origin])
    try await client.download(pluginArtifactFixture(bytes: bytes, assetID: id), to: file.descriptor)
    #expect(try Data(contentsOf: file.url) == bytes)
    let stats = try await GitHubCatalogHTTPClient(origin: fixture.origin).fetch(
      path: "/stats", query: [:], accept: "application/json", maxBytes: 8192)
    let requests = try #require(try stats.decode(JSONValue.self).arrayValue)
    #expect(requests.count == (id == 11 ? 1 : 2))
    for request in requests {
      let headers = try #require(request.objectValue?["headers"]?.objectValue)
      #expect(headers["authorization"] == nil && headers["cookie"] == nil)
      #expect(headers["accept"] == .string("application/octet-stream"))
    }
    if id == 12 {
      #expect(requests.last?.objectValue?["headers"]?.objectValue?["x-github-api-version"] == nil)
    }
  }

  @Test(arguments: [
    (Int64(14), PluginCatalogError.invalidResponse),
    (16, .invalidResponse), (17, .invalidResponse), (18, .invalidResponse),
    (21, .rateLimited(retryAfterSeconds: 42)), (22, .httpStatus(401)),
  ])
  func rejectsInvalidHTTPBodies(_ id: Int64, _ expected: PluginCatalogError) async throws {
    let fixture = try await CatalogHTTPFixture.start(script: downloadHTTPFixture)
    defer { fixture.stop() }
    let file = try DownloadFile()
    let client = GitHubPluginDownload(origin: fixture.origin)
    await #expect(throws: expected) {
      try await client.download(
        pluginArtifactFixture(bytes: bytes, assetID: id), to: file.descriptor)
    }
  }

  @Test(arguments: [(Int64(15), PluginArchiveError.limitExceeded), (19, .checksumMismatch)])
  func validatesStreamLengthAndDigest(_ id: Int64, _ expected: PluginArchiveError) async throws {
    let fixture = try await CatalogHTTPFixture.start(script: downloadHTTPFixture)
    defer { fixture.stop() }
    let file = try DownloadFile()
    await #expect(throws: expected) {
      try await GitHubPluginDownload(origin: fixture.origin).download(
        pluginArtifactFixture(bytes: bytes, assetID: id), to: file.descriptor)
    }
    #expect(try Data(contentsOf: file.url).count <= bytes.count)
  }

  @Test(arguments: [13, 23, 24, 25])
  func refusesUnsafeRedirectsAndBoundsLoops(_ id: Int64) async throws {
    let fixture = try await CatalogHTTPFixture.start(script: downloadHTTPFixture)
    defer { fixture.stop() }
    let file = try DownloadFile()
    let client = GitHubPluginDownload(origin: fixture.origin, redirectOrigins: [fixture.origin])
    await #expect(throws: PluginCatalogError.unsafeRequest) {
      try await client.download(
        pluginArtifactFixture(bytes: bytes, assetID: id), to: file.descriptor)
    }
    let stats = try await GitHubCatalogHTTPClient(origin: fixture.origin).fetch(
      path: "/stats", query: [:], accept: "application/json", maxBytes: 8192)
    let requests = try #require(try stats.decode(JSONValue.self).arrayValue)
    #expect(requests.count == (id == 23 ? 4 : 1))
    #expect(try Data(contentsOf: file.url).isEmpty)
  }

  @Test
  func cancelsAnActiveStreamAndJoinsBeforeReturningTheDescriptor() async throws {
    let fixture = try await CatalogHTTPFixture.start(script: downloadHTTPFixture)
    defer { fixture.stop() }
    let file = try DownloadFile()
    let descriptor = file.descriptor
    let artifact = pluginArtifactFixture(bytes: bytes, assetID: 20)
    let client = GitHubPluginDownload(origin: fixture.origin)
    let task = Task { try await client.download(artifact, to: descriptor) }
    let response = try await GitHubCatalogHTTPClient(origin: fixture.origin).fetch(
      path: "/wait", query: [:], accept: "application/json", maxBytes: 128)
    #expect(try response.decode(JSONValue.self) == .bool(true))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try Data(contentsOf: file.url).isEmpty)
    #expect(ftruncate(descriptor, 0) == 0 && lseek(descriptor, 0, SEEK_SET) == 0)
    try await client.download(pluginArtifactFixture(bytes: bytes), to: descriptor)
    #expect(try Data(contentsOf: file.url) == bytes)
  }

  @Test
  func enforcesWholeTransferDeadline() async throws {
    let fixture = try await CatalogHTTPFixture.start(script: downloadHTTPFixture)
    defer { fixture.stop() }
    let file = try DownloadFile()
    let client = GitHubPluginDownload(origin: fixture.origin, timeout: .milliseconds(100))
    await #expect(throws: PluginCatalogError.timedOut) {
      try await client.download(
        pluginArtifactFixture(bytes: bytes, assetID: 20), to: file.descriptor)
    }
    #expect(try Data(contentsOf: file.url).isEmpty)
  }

  @Test
  func refusesNonemptyOrPublicOutputFilesBeforeNetworking() async throws {
    let file = try DownloadFile()
    let client = GitHubPluginDownload()
    #expect(ftruncate(file.descriptor, 1) == 0)
    await #expect(throws: PluginArchiveError.invalidInput) {
      try await client.download(pluginArtifactFixture(), to: file.descriptor)
    }
    #expect(ftruncate(file.descriptor, 0) == 0 && fchmod(file.descriptor, 0o644) == 0)
    await #expect(throws: PluginArchiveError.invalidInput) {
      try await client.download(pluginArtifactFixture(), to: file.descriptor)
    }
  }
}

private final class DownloadFile {
  let root: URL
  let url: URL
  let descriptor: Int32
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "plugin-download-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    url = root.appendingPathComponent("archive")
    descriptor = open(url.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else {
      try? FileManager.default.removeItem(at: root)
      throw PluginArchiveError.fileSystemFailure
    }
  }
  deinit {
    close(descriptor)
    try? FileManager.default.removeItem(at: root)
  }
}
