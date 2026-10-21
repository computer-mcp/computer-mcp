import ComputerMCPCore
import ComputerMCPProcess
import Foundation
import Testing

package enum HTTPStreamTestError: Error { case timeout }

package struct HTTPStreamProcessFixture {
  package let root: URL
  private let process: ManagedLineProcess
  package let endpoint: URL

  package init() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mcp-http-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let script = root.appendingPathComponent("server.py")
    try Self.script.write(to: script, atomically: true, encoding: .utf8)
    let process = try ManagedLineProcess(
      configuration: .init(
        executable: "/usr/bin/env", arguments: ["python3", script.path, root.path],
        environment: ProcessInfo.processInfo.environment.merging(["PATH": systemUtilityPath]) {
          $1
        },
        workingDirectory: root, terminationGraceMilliseconds: 100, killGraceMilliseconds: 2_000))
    do {
      let deadline = ContinuousClock.now.advanced(by: .seconds(5))
      let ready = root.appendingPathComponent("port")
      var port: Int?
      while ContinuousClock.now < deadline {
        if let data = FileManager.default.contents(atPath: ready.path),
          let text = String(data: data, encoding: .utf8), let value = Int(text)
        {
          port = value
          break
        }
        guard !(await process.snapshot().hasExited) else { throw HTTPStreamTestError.timeout }
        try await Task.sleep(for: .milliseconds(10))
      }
      guard let port, let endpoint = URL(string: "http://127.0.0.1:\(port)/mcp") else {
        throw HTTPStreamTestError.timeout
      }
      self.root = root
      self.process = process
      self.endpoint = endpoint
    } catch {
      await Self.stop(process, root: root)
      if await process.snapshot().hasExited { try? FileManager.default.removeItem(at: root) }
      throw error
    }
  }

  package func requests() throws -> [[String: JSONValue]] {
    guard
      let data = FileManager.default.contents(
        atPath: root.appendingPathComponent("requests.jsonl").path)
    else { return [] }
    return try data.split(separator: 10).compactMap {
      try JSONDecoder().decode(JSONValue.self, from: Data($0)).objectValue
    }
  }

  package func waitForRequest(id: String) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
      if try requests().contains(where: { $0["id"] == .string(id) }) { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw HTTPStreamTestError.timeout
  }

  package static func withFixture(_ operation: (Self) async throws -> Void) async throws {
    let fixture = try await Self()
    do {
      try await operation(fixture)
      await fixture.cleanup()
    } catch {
      await fixture.cleanup()
      throw error
    }
  }

  package func cleanup() async {
    await Self.stop(process, root: root)
    guard await process.snapshot().hasExited else {
      Issue.record("The owned HTTP fixture did not confirm exit; its directory is preserved.")
      return
    }
    try? FileManager.default.removeItem(at: root)
  }

  private static func stop(_ process: ManagedLineProcess, root: URL) async {
    try? Data().write(to: root.appendingPathComponent("stop"))
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await process.snapshot().hasExited), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    await process.close()
  }

  private static let script = #"""
    import http.server
    import json
    import pathlib
    import signal
    import socket
    import sys
    import threading
    import time

    root = pathlib.Path(sys.argv[1])
    lock = threading.Lock()
    if sys.platform == "linux":
        signal.pthread_sigmask(signal.SIG_SETMASK, [])

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def record(self, message=None):
            message = message or {}
            authorized = self.headers.get("Authorization") == "Bearer fixture-token"
            record = {"method": self.command, "rpc": message.get("method"), "id": message.get("id"), "cursor": self.headers.get("Last-Event-ID"), "session": self.headers.get("Mcp-Session-Id"), "protocol": self.headers.get("Mcp-Protocol-Version"), "authorized": authorized}
            with lock:
                with (root / "requests.jsonl").open("a") as file:
                    file.write(json.dumps(record) + "\n")
            if not authorized:
                self.send_response(401)
                self.send_header("Content-Length", "0")
                self.end_headers()
            return authorized

        def begin(self, content_type):
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Mcp-Session-Id", "fixture-session")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()

        def chunk(self, data):
            if isinstance(data, str):
                data = data.encode("utf-8")
            self.wfile.write(("%x\r\n" % len(data)).encode() + data + b"\r\n")
            self.wfile.flush()

        def finish(self):
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()

        def keep_alive(self, identifier=None):
            try:
                for _ in range(100):
                    self.chunk(": heartbeat\n\n")
                    time.sleep(0.1)
                self.finish()
            except (BrokenPipeError, ConnectionResetError):
                if identifier is not None:
                    with lock:
                        with (root / "closed-streams").open("a") as file:
                            file.write(identifier + "\n")

        def do_DELETE(self):
            if not self.record():
                return
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def do_POST(self):
            message = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
            if not self.record(message):
                return
            if self.path == "/redirect":
                self.send_response(307)
                self.send_header("Location", "/mcp")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if "id" not in message:
                self.send_response(202)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            method, identifier = message["method"], str(message["id"])
            if method == "http-error":
                self.send_response(503)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                self.keep_alive(identifier)
                return
            if method in ("tools/list", "tools/call"):
                result = {"tools": [{"name": "inspect", "inputSchema": {"type": "object"}}]} if method == "tools/list" else {"content": [{"type": "text", "text": "authenticated reply"}], "isError": False}
                self.begin("application/json")
                self.chunk(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}))
                self.finish()
                return
            if method == "json":
                self.begin("application/json")
                self.chunk(json.dumps({"jsonrpc": "2.0", "id": identifier, "result": {"json": True}}))
                self.finish()
                return
            self.begin("text/event-stream")
            if method in ("incremental", "cancel-stream", "server-close", "truncated"):
                event = ("data: " + json.dumps({"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progressToken": identifier, "message": "正在读取"}}, ensure_ascii=False) + "\n\n").encode("utf-8")
                split = event.index("正".encode("utf-8")) + 1
                self.chunk(event[:split])
                self.chunk(event[split:])
                if method == "cancel-stream":
                    self.keep_alive(identifier)
                    return
                if method == "incremental":
                    release = root / ("release-" + identifier)
                    deadline = time.monotonic() + 10
                    while not release.exists() and time.monotonic() < deadline:
                        time.sleep(0.01)
                    if not release.exists():
                        self.close_connection = True
                        return
                    self.chunk("data: " + json.dumps({"jsonrpc": "2.0", "id": identifier, "result": {"completed": True}}) + "\n\n")
                    self.finish()
                    return
                if method == "server-close":
                    self.finish()
                self.close_connection = True
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()
                return
            if method == "ambiguous":
                self.chunk(": response interrupted\n\n")
                self.finish()
                return
            self.chunk("id: request-" + identifier + "\nretry: 10\ndata:\n\n")
            if method == "never":
                self.keep_alive(identifier)
                return
            if method == "initialize":
                result = {"protocolVersion": "2025-03-26", "capabilities": {"tools": {"listChanged": True}}, "serverInfo": {"name": "stream-fixture", "version": "1"}}
                self.chunk("data: " + json.dumps({"jsonrpc": "2.0", "id": identifier, "result": result}) + "\n\n")
            self.finish()

        def do_GET(self):
            if not self.record():
                return
            if self.path in ("/bytes/stalled", "/bytes/ordered"):
                self.begin("application/octet-stream")
                self.connection.settimeout(5)
                payload = bytes(range(256)) * 1024
                ordered = self.path == "/bytes/ordered"
                deadline = time.monotonic() + 40
                try:
                    for index in range(132 if ordered else 256):
                        self.chunk(index.to_bytes(8, "big") + payload[8:])
                        if ordered:
                            receipt = root / "received-blocks"
                            while not receipt.exists() or receipt.read_text() != str(index + 1):
                                if time.monotonic() >= deadline:
                                    self.close_connection = True
                                    return
                                time.sleep(0.001)
                    if ordered:
                        self.finish()
                    else:
                        self.keep_alive("bytes")
                except (BrokenPipeError, ConnectionResetError, TimeoutError):
                    with lock:
                        with (root / "closed-streams").open("a") as file:
                            file.write("bytes\n")
                return
            cursor = self.headers.get("Last-Event-ID")
            self.begin("text/event-stream")
            if cursor and cursor.startswith("request-"):
                identifier = cursor[len("request-"):]
                self.chunk("data: " + json.dumps({"jsonrpc": "2.0", "id": identifier, "result": {"resumed": True}}) + "\n\n")
                self.finish()
                return
            if cursor is None or cursor == "events-1":
                identifier = "events-1" if cursor is None else "events-2"
                self.chunk("id: " + identifier + "\nretry: 10\ndata: " + json.dumps({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"}) + "\n\n")
                if cursor is None:
                    self.finish()
                    return
            self.keep_alive()

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    (root / "port").write_text(str(server.server_address[1]))
    def stop_when_requested():
        while not (root / "stop").exists():
            time.sleep(0.01)
        server.shutdown()
    threading.Thread(target=stop_when_requested, daemon=True).start()
    server.serve_forever(poll_interval=0.01)
    server.server_close()
    """#
}
