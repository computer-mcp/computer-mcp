import Foundation
import Testing

@testable import ComputerMCP

@Suite(.timeLimit(.minutes(1)))
struct GitHubCatalogHTTPClientTests {
  @Test
  func rejectsAuthenticationChallengesWithoutSendingCredentials() async throws {
    let fixture = try await CatalogHTTPFixture.start()
    defer { fixture.stop() }
    let client = GitHubCatalogHTTPClient(origin: fixture.origin)
    await #expect(throws: PluginCatalogError.httpStatus(401)) {
      let response = try await client.fetch(
        path: "/auth", query: [:], accept: "application/json", maxBytes: 128)
      try response.requireSuccess()
    }
    let stats = try await client.fetch(
      path: "/stats", query: [:], accept: "application/json", maxBytes: 4096)
    #expect(try stats.decode(JSONValue.self).objectValue?["paths"] == .array([.string("/auth")]))
  }

  @Test
  func isolatesHeadersCookiesAndQueryEncoding() async throws {
    let fixture = try await CatalogHTTPFixture.start()
    defer { fixture.stop() }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpAdditionalHeaders = [
      "Authorization": "Bearer fixture-secret", "Cookie": "session=fixture-cookie",
    ]
    let client = GitHubCatalogHTTPClient(configuration: configuration, origin: fixture.origin)
    let query = ["ref": "feature/工具?x=a&b=#%", "empty": ""]
    for _ in 0..<2 {
      let response = try await client.fetch(
        path: "/echo", query: query,
        accept: "application/vnd.github+json", maxBytes: 4096)
      try response.requireSuccess()
      let value = try response.decode(JSONValue.self)
      let headers = value.objectValue?["headers"]?.objectValue
      #expect(headers?["authorization"] == nil)
      #expect(headers?["cookie"] == nil)
      #expect(headers?["x-github-api-version"] == .string("2026-03-10"))
      #expect(headers?["accept"] == .string("application/vnd.github+json"))
      #expect(
        value.objectValue?["query"]
          == .object([
            "ref": .array([.string(query["ref"]!)]), "empty": .array([.string("")]),
          ]))
    }
  }

  @Test
  func refusesRedirectsWithoutRequestingTheirTarget() async throws {
    let fixture = try await CatalogHTTPFixture.start()
    defer { fixture.stop() }
    let client = GitHubCatalogHTTPClient(origin: fixture.origin)
    let response = try await client.fetch(
      path: "/redirect", query: [:], accept: "application/json", maxBytes: 128)
    #expect(throws: PluginCatalogError.httpStatus(302)) { try response.requireSuccess() }
    let stats = try await client.fetch(
      path: "/stats", query: [:], accept: "application/json", maxBytes: 4096)
    #expect(
      try stats.decode(JSONValue.self).objectValue?["paths"] == .array([.string("/redirect")]))
  }

  @Test(arguments: ["/large-length", "/large-stream", "/large-gzip"])
  func boundsDeclaredStreamedAndDecompressedBodies(_ path: String) async throws {
    let fixture = try await CatalogHTTPFixture.start()
    defer { fixture.stop() }
    let client = GitHubCatalogHTTPClient(origin: fixture.origin)
    await #expect(throws: PluginCatalogError.responseTooLarge) {
      _ = try await client.fetch(path: path, query: [:], accept: "application/json", maxBytes: 128)
    }
  }

  @Test
  func largeRateLimitBodyDoesNotHideStatus() async throws {
    let fixture = try await CatalogHTTPFixture.start()
    defer { fixture.stop() }
    let client = GitHubCatalogHTTPClient(origin: fixture.origin)
    let response = try await client.fetch(
      path: "/rate-limit", query: [:], accept: "application/json", maxBytes: 128)
    #expect(response.body.isEmpty)
    #expect(throws: PluginCatalogError.rateLimited(retryAfterSeconds: 42)) {
      try response.requireSuccess()
    }
  }

  @Test
  func cancellingAnActiveBodyReadStopsPromptly() async throws {
    let fixture = try await CatalogHTTPFixture.start()
    defer { fixture.stop() }
    let client = GitHubCatalogHTTPClient(origin: fixture.origin)
    let task = Task {
      try await client.fetch(path: "/slow", query: [:], accept: "application/json", maxBytes: 4096)
    }
    // The fixture blocks until /slow has actually received the request.
    _ = try await client.fetch(
      path: "/wait-slow", query: [:], accept: "application/json", maxBytes: 128)
    let start = ContinuousClock.now
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("Cancelled body read returned success")
    } catch { #expect(error is CancellationError || (error as? URLError)?.code == .cancelled) }
    #expect(ContinuousClock.now - start < .seconds(2))
    let healthy = try await client.fetch(
      path: "/echo", query: [:], accept: "application/json", maxBytes: 4096)
    try healthy.requireSuccess()
  }

  @Test(arguments: ["//evil.example/escape", "/../escape", "/a/../escape", "/bad\0path"])
  func rejectsUnsafeRequestPaths(_ path: String) async {
    let client = GitHubCatalogHTTPClient()
    await #expect(throws: PluginCatalogError.unsafeRequest) {
      _ = try await client.fetch(path: path, query: [:], accept: "application/json", maxBytes: 128)
    }
  }
}

final class CatalogHTTPFixture {
  let process = Process()
  let origin: URL
  private let termination = DispatchSemaphore(value: 0)

  static func start(script: String? = nil) async throws -> CatalogHTTPFixture {
    // Process launch and the ready-pipe read are blocking I/O, not cooperative-executor work.
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        do { continuation.resume(returning: try CatalogHTTPFixture(script: script)) } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private init(script: String? = nil) throws {
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-u", "-c", script ?? Self.script]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let termination = termination
    process.terminationHandler = { _ in termination.signal() }
    try process.run()
    var line = Data()
    while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
      if byte == Data([10]) { break }
      line.append(byte)
      if line.count > 16 { break }
    }
    guard let port = Int(String(decoding: line, as: UTF8.self)), (1...65535).contains(port),
      let url = URL(string: "http://127.0.0.1:\(port)")
    else {
      if process.isRunning { process.terminate() }
      if termination.wait(timeout: .now() + .seconds(5)) != .success {
        Issue.record("Catalog HTTP fixture did not report termination after startup failure.")
      }
      throw PluginCatalogError.invalidResponse
    }
    origin = url
  }

  func stop() {
    if process.isRunning { process.terminate() }
    // Async tests may resume on a different thread from Process.run(). Arm
    // completion before launch instead of entering a different thread's run
    // loop after the process's termination notification has already arrived.
    if termination.wait(timeout: .now() + .seconds(5)) != .success {
      Issue.record("Catalog HTTP fixture did not report termination before its cleanup deadline.")
    }
  }

  private static let script = #"""
    import gzip, http.server, json, os, threading, urllib.parse
    threading.Timer(40, lambda: os._exit(0)).start()
    paths = []
    slow = threading.Event()
    release = threading.Event()
    class Handler(http.server.BaseHTTPRequestHandler):
      def log_message(self, *args): pass
      def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        path = url.path
        if path != '/stats': paths.append(path)
        if path == '/wait-slow': slow.wait(5)
        body = json.dumps({'headers': dict((k.lower(), v) for k, v in self.headers.items()),
                           'query': urllib.parse.parse_qs(url.query, keep_blank_values=True)}).encode()
        if path == '/stats': body = json.dumps({'paths': paths}).encode()
        if path == '/wait-slow': body = b'{}'
        if path.startswith('/large') or path == '/rate-limit': body = b'x' * 4096
        self.send_response(302 if path == '/redirect' else 429 if path == '/rate-limit' else 401 if path == '/auth' else 200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Set-Cookie', 'session=server-fixture-cookie')
        if path == '/redirect': self.send_header('Location', '/must-not-be-requested')
        if path == '/rate-limit': self.send_header('Retry-After', '42')
        if path == '/auth': self.send_header('WWW-Authenticate', 'Basic realm="fixture"')
        if path == '/large-gzip':
          body = gzip.compress(body)
          self.send_header('Content-Encoding', 'gzip')
        if path == '/slow': body = b'{}'
        if path != '/large-stream': self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        if path == '/slow':
          self.wfile.flush()
          slow.set()
          release.wait(15)
        try: self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError): pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    print(server.server_port, flush=True)
    server.serve_forever()
    """#
}
