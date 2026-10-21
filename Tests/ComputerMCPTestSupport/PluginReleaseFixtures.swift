import ComputerMCPCore
import ComputerMCPPlugins
import Crypto
import Foundation

package let releaseManifestFixture = """
  id = 'combined'
  name = 'Combined'
  version = '1.2.3'
  plugin_api = 1
  [[mcp]]
  id = 'native'
  transport = 'http'
  url = 'https://example.invalid/mcp'
  """

package func pluginArtifactFixture(
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

package func releaseAssetFixture(
  id: Int = 11, artifact: GitHubPluginArtifact = pluginArtifactFixture()
) -> [String: JSONValue] {
  return [
    "id": .number(Double(id)), "name": .string(artifact.name),
    "size": .number(Double(artifact.size)),
    "state": .string("uploaded"), "digest": .string("sha256:" + artifact.sha256),
    "url": .string("https://api.github.com/repos/computer-mcp/combined/releases/assets/\(id)"),
  ]
}

package let downloadHTTPFixture = #"""
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

package func pluginDownloadHTTPFixture(bytes: Data) -> String {
  downloadHTTPFixture.replacingOccurrences(of: "import gzip,", with: "import base64, gzip,")
    .replacingOccurrences(
      of: "body = b'A' * 131083", with: "body = base64.b64decode('\(bytes.base64EncodedString())')")
}
