import Foundation
import Testing

@testable import ComputerMCP

@Suite(.timeLimit(.minutes(1)))
struct StaticPluginCatalogHTTPTests {
  @Test
  func oneConditionalRequestOmitsCredentialsCookiesAndGitHubAPIHeaders() async throws {
    let server = try await CatalogHTTPFixture.start(script: Self.script)
    defer { server.stop() }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpAdditionalHeaders = [
      "Authorization": "Bearer fixture-only", "Cookie": "private=fixture",
    ]
    let client = StaticPluginCatalogHTTP(
      configuration: configuration, endpoint: server.origin.appendingPathComponent("echo"))
    let response = try await client.fetch(
      validators: .init(etag: "\"fixture\"", lastModified: "Mon, 28 Sep 2026 01:00:00 GMT"))
    let headers = try #require(response.decode(JSONValue.self).objectValue)
    #expect(headers["if-none-match"] == .string("\"fixture\""))
    #expect(headers["if-modified-since"] == nil)
    #expect(headers["authorization"] == nil && headers["cookie"] == nil)
    #expect(headers["x-github-api-version"] == nil)
    let fallback = try await client.fetch(
      validators: .init(lastModified: "Mon, 28 Sep 2026 01:00:00 GMT"))
    #expect(
      try fallback.decode(JSONValue.self).objectValue?["if-modified-since"]
        == .string("Mon, 28 Sep 2026 01:00:00 GMT"))
    #expect(StaticPluginCatalogValidators(etag: "bad\r\nAuthorization: injected").etag == nil)
    #expect(StaticPluginCatalogValidators(etag: String(repeating: "x", count: 2049)).etag == nil)
  }

  @Test(arguments: ["length", "stream", "gzip"])
  func boundsCompressedAndUncompressedCatalogBytes(_ path: String) async throws {
    let server = try await CatalogHTTPFixture.start(script: Self.script)
    defer { server.stop() }
    let client = StaticPluginCatalogHTTP(endpoint: server.origin.appendingPathComponent(path))
    await #expect(throws: PluginCatalogError.responseTooLarge) {
      try await client.fetch(validators: .init())
    }
  }

  @Test
  func redirectAndAuthenticationCannotExpandTheFixedEndpoint() async throws {
    let server = try await CatalogHTTPFixture.start(script: Self.script)
    defer { server.stop() }
    let redirect = try await StaticPluginCatalogHTTP(
      endpoint: server.origin.appendingPathComponent("redirect")
    ).fetch(validators: .init())
    #expect(redirect.status == 302 && redirect.body.isEmpty)
    let client = StaticPluginCatalogHTTP(endpoint: server.origin.appendingPathComponent("auth"))
    await #expect(throws: PluginCatalogError.httpStatus(401)) {
      try await client.fetch(validators: .init())
    }
    let stats = try await StaticPluginCatalogHTTP(
      endpoint: server.origin.appendingPathComponent("stats")
    ).fetch(validators: .init())
    #expect(try stats.decode([String].self) == ["/redirect", "/auth"])
  }

  @Test
  func notModifiedHasNoBodyAndCancellationStopsAnOwnedRequest() async throws {
    let server = try await CatalogHTTPFixture.start(script: Self.script)
    defer { server.stop() }
    let response = try await StaticPluginCatalogHTTP(
      endpoint: server.origin.appendingPathComponent("conditional")
    ).fetch(validators: .init(etag: "\"fixture\""))
    #expect(response.status == 304 && response.body.isEmpty)
    let slowEndpoint = server.origin.appendingPathComponent("slow")
    let task = Task {
      try await StaticPluginCatalogHTTP(endpoint: slowEndpoint)
        .fetch(validators: .init())
    }
    _ = try await StaticPluginCatalogHTTP(endpoint: server.origin.appendingPathComponent("wait"))
      .fetch(validators: .init())
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("Cancelled catalog body returned success")
    } catch { #expect(error is CancellationError || (error as? URLError)?.code == .cancelled) }
  }

  private static let script = #"""
    import gzip, http.server, json, os, threading
    threading.Timer(40, lambda: os._exit(0)).start()
    paths, slow = [], threading.Event()
    class Handler(http.server.BaseHTTPRequestHandler):
      def log_message(self, *args): pass
      def do_GET(self):
        path = self.path
        if path != '/stats': paths.append(path)
        if path == '/wait': slow.wait(5)
        body = json.dumps({k.lower():v for k,v in self.headers.items()}).encode()
        if path == '/stats': body = json.dumps(paths).encode()
        if path in ['/length','/stream','/gzip']: body = b'x' * (4*1024*1024+1)
        status = 302 if path == '/redirect' else 401 if path == '/auth' else 304 if path == '/conditional' else 200
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Set-Cookie', 'server=fixture')
        if path == '/redirect': self.send_header('Location', '/must-not-be-requested')
        if path == '/auth': self.send_header('WWW-Authenticate', 'Basic realm="fixture"')
        if path == '/conditional': body = b''
        if path == '/gzip':
          body = gzip.compress(body)
          self.send_header('Content-Encoding', 'gzip')
        if path != '/stream': self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        if path == '/slow':
          self.wfile.flush()
          slow.set()
          threading.Event().wait(20)
        try: self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError): pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
    print(server.server_port, flush=True)
    server.serve_forever()
    """#
}
