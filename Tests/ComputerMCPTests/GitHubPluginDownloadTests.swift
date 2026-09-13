import Darwin
import Foundation
import Testing

@testable import ComputerMCP

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

private let downloadHTTPFixture = #"""
  import gzip, http.server, json, os, threading, urllib.parse
  threading.Timer(40, lambda: os._exit(0)).start()
  requests = []
  started = threading.Event()
  release = threading.Event()
  class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
      path = urllib.parse.urlsplit(self.path).path
      if path in ['/stats', '/wait']:
        value = requests if path == '/stats' else started.wait(5)
        data = json.dumps(value).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        return
      requests.append({'path': path, 'headers': dict((k.lower(), v) for k, v in self.headers.items())})
      asset = int(path.rsplit('/', 1)[-1]) if path != '/binary' else 11
      origin = 'http://127.0.0.1:' + str(self.server.server_port)
      if asset in [12, 13, 23, 24, 25]:
        location = origin + '/binary'
        if asset == 13: location = 'https://example.invalid/forbidden'
        if asset == 23: location = origin + path
        if asset == 24: location = origin.replace('://', '://user:pass@') + '/binary'
        if asset == 25: location += '#fragment'
        self.send_response(302)
        self.send_header('Location', location)
        self.send_header('Set-Cookie', 'session=fixture-cookie')
        self.send_header('Content-Length', '0')
        self.end_headers()
        return
      body = b'A' * 131083
      if asset == 15: body += b'B'
      if asset == 16: body = body[:-1]
      if asset == 19: body = b'B' * len(body)
      if asset == 18: body = gzip.compress(body)
      self.send_response(429 if asset == 21 else 401 if asset == 22 else 200)
      self.send_header('Content-Type', 'application/json' if asset == 17 else 'application/octet-stream')
      if asset == 21: self.send_header('Retry-After', '42')
      if asset == 22: self.send_header('WWW-Authenticate', 'Basic realm="fixture"')
      if asset == 18: self.send_header('Content-Encoding', 'gzip')
      if asset not in [15, 16]: self.send_header('Content-Length', str(len(body) + (1 if asset == 14 else 0)))
      self.end_headers()
      if asset == 20:
        self.wfile.flush()
        started.set()
        release.wait(15)
      try: self.wfile.write(body)
      except (BrokenPipeError, ConnectionResetError): pass
  server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
  print(server.server_port, flush=True)
  server.serve_forever()
  """#

func pluginDownloadHTTPFixture(bytes: Data) -> String {
  downloadHTTPFixture.replacingOccurrences(of: "import gzip,", with: "import base64, gzip,")
    .replacingOccurrences(
      of: "body = b'A' * 131083", with: "body = base64.b64decode('\(bytes.base64EncodedString())')")
}
