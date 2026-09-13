import Foundation
import MCP
import Testing

@testable import ComputerMCP

struct MCPHTTPClientTransportTests {
  @Test
  func protocolCancellationClosesItsResponseStreamWithoutEndingTheSession() async throws {
    try await HTTPStreamProcessFixture.withFixture { fixture in
      let transport = fixture.transport(streaming: false)
      try await transport.connect()
      try await transport.send(Self.request("initialize", id: "init"))
      let first = Task { try await transport.send(Self.request("never", id: "first")) }
      let sibling = Task { try await transport.send(Self.request("never", id: "sibling")) }
      do {
        try await fixture.waitForRequest(id: "first")
        try await fixture.waitForRequest(id: "sibling")
        try await transport.send(
          Data(
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"first"}}"#
              .utf8))
        switch await first.result {
        case .success: Issue.record("Cancelled response stream unexpectedly completed.")
        case .failure(let error):
          #expect(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
        let closed = fixture.root.appendingPathComponent("closed-streams")
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var receipts: [String] = []
        while ContinuousClock.now < deadline {
          receipts =
            (try? String(contentsOf: closed, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
          if receipts.contains("first") { break }
          try await Task.sleep(for: .milliseconds(10))
        }
        #expect(receipts.contains("first"))
        #expect(!receipts.contains("sibling"))
        try await transport.send(Self.request("json", id: "still-connected"))
        let requests = try fixture.requests()
        #expect(requests.filter { $0["id"] == .string("first") }.count == 1)
        #expect(requests.filter { $0["rpc"] == .string("notifications/cancelled") }.count == 1)
        #expect(!requests.contains { $0["method"] == .string("DELETE") })
        sibling.cancel()
        _ = await sibling.result
        await transport.disconnect()
      } catch {
        first.cancel()
        sibling.cancel()
        await transport.disconnect()
        _ = await first.result
        _ = await sibling.result
        throw error
      }
    }
  }

  @Test(arguments: [false, true])
  func gatewayClientSessionTerminatesThroughItsTransportOnce(streaming: Bool) async throws {
    try await HTTPStreamProcessFixture.withFixture { fixture in
      let session = try await GatewayClientSession.connectHTTP(
        endpoint: fixture.endpoint, accessToken: "fixture-token", streaming: streaming)
      do {
        #expect(try await session.listToolNames() == ["inspect"])
        await session.disconnect()
        await session.disconnect()
        let deletions = try fixture.requests().filter { $0["method"] == .string("DELETE") }
        #expect(deletions.count == 1)
        #expect(deletions.first?["authorized"] == .bool(true))
        #expect(deletions.first?["session"] == .string("fixture-session"))
      } catch {
        await session.disconnect()
        throw error
      }
    }
  }

  @Test
  func concurrentDisconnectSendsOneAuthenticatedSessionTermination() async throws {
    try await HTTPStreamProcessFixture.withFixture { fixture in
      let transport = fixture.transport(streaming: false)
      try await transport.connect()
      try await transport.send(Self.request("json", id: "session"))
      async let first: Void = transport.disconnect()
      async let second: Void = transport.disconnect()
      _ = await (first, second)
      await transport.disconnect()
      let deletions = try fixture.requests().filter { $0["method"] == .string("DELETE") }
      #expect(deletions.count == 1)
      #expect(deletions.first?["authorized"] == .bool(true))
      #expect(deletions.first?["session"] == .string("fixture-session"))
      #expect(deletions.first?["protocol"]?.stringValue != nil)
    }
  }

  @Test
  func concurrentPOSTRecoveryAndEventReconnectKeepIndependentCursors() async throws {
    try await HTTPStreamProcessFixture.withFixture { fixture in
      let transport = fixture.transport()
      try await transport.connect()
      let incoming = await transport.receive()
      let collecting = Task { try await Self.collect(incoming, count: 6) }
      do {
        try await transport.send(Self.request("initialize", id: "init"))
        async let first: Void = transport.send(Self.request("resume", id: "a"))
        async let second: Void = transport.send(Self.request("resume", id: "b"))
        async let json: Void = transport.send(Self.request("json", id: "c"))
        _ = try await (first, second, json)
        let messages = try await collecting.value
        #expect(
          Set(messages.compactMap { $0.objectValue?["id"]?.stringValue }) == [
            "init", "a", "b", "c",
          ])
        #expect(
          messages.filter {
            $0.objectValue?["method"]?.stringValue == "notifications/tools/list_changed"
          }.count == 2)
        let requests = try fixture.requests()
        for id in ["a", "b"] {
          #expect(
            requests.filter { $0["method"] == .string("POST") && $0["id"] == .string(id) }.count
              == 1)
          #expect(
            requests.contains {
              $0["method"] == .string("GET") && $0["cursor"] == .string("request-\(id)")
            })
        }
        #expect(
          requests.contains {
            $0["method"] == .string("GET") && $0["cursor"] == .string("events-1")
          })
        #expect(
          !requests.contains {
            $0["method"] == .string("GET") && $0["cursor"] == .string("request-init")
          })
        #expect(requests.allSatisfy { $0["authorized"] == .bool(true) })
        #expect(
          requests.filter { $0["rpc"] != .string("initialize") }.allSatisfy {
            $0["session"] == .string("fixture-session") && $0["protocol"] == .string("2025-03-26")
          })
        await transport.disconnect()
      } catch {
        collecting.cancel()
        await transport.disconnect()
        _ = await collecting.result
        throw error
      }
    }
  }

  @Test
  func cancellationClosesOnlyTheInFlightExchangeWithoutReposting() async throws {
    try await HTTPStreamProcessFixture.withFixture { fixture in
      let transport = fixture.transport(streaming: false)
      try await transport.connect()
      try await transport.send(Self.request("initialize", id: "init"))
      let pending = Task { try await transport.send(Self.request("never", id: "cancelled")) }
      do {
        try await fixture.waitForRequest(id: "cancelled")
        pending.cancel()
        switch await pending.result {
        case .success: Issue.record("Cancelled exchange unexpectedly completed.")
        case .failure(let error):
          #expect(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
        try await transport.send(Self.request("json", id: "still-connected"))
        #expect(try fixture.requests().filter { $0["id"] == .string("cancelled") }.count == 1)
        await transport.disconnect()
      } catch {
        pending.cancel()
        await transport.disconnect()
        _ = await pending.result
        throw error
      }
    }
  }

  @Test
  func rejectedAuthenticationIsReportedWithoutAnAutomaticRetry() async throws {
    try await HTTPStreamProcessFixture.withFixture { fixture in
      let transport = MCPHTTPClientTransport(endpoint: fixture.endpoint, streaming: false)
      try await transport.connect()
      await #expect(throws: MCPHTTPTransportError.httpStatus(401)) {
        try await transport.send(Self.request("initialize", id: "unauthorized"))
      }
      #expect(try fixture.requests().count == 1)
      await transport.disconnect()
    }
  }

  @Test
  func incompleteWriteResponseWithoutCursorIsNotExecutedAgain() async throws {
    try await HTTPStreamProcessFixture.withFixture { fixture in
      let transport = fixture.transport(streaming: false)
      try await transport.connect()
      try await transport.send(Self.request("initialize", id: "init"))
      await #expect(throws: MCPHTTPTransportError.incompleteResponse) {
        try await transport.send(Self.request("ambiguous", id: "write"))
      }
      #expect(try fixture.requests().filter { $0["id"] == .string("write") }.count == 1)
      await transport.disconnect()
    }
  }

  @Test
  func eventListenerDoesNotKeepAnAbandonedTransportAlive() async throws {
    try await HTTPStreamProcessFixture.withFixture { fixture in
      var transport: MCPHTTPClientTransport? = fixture.transport()
      weak var weakTransport: MCPHTTPClientTransport?
      weakTransport = transport
      try await transport?.connect()
      try await transport?.send(Self.request("initialize", id: "init"))
      transport = nil
      let deadline = ContinuousClock.now.advanced(by: .seconds(2))
      while weakTransport != nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(weakTransport == nil)
      await weakTransport?.disconnect()
    }
  }

  private static func request(_ method: String, id: String) -> Data {
    Data("{\"jsonrpc\":\"2.0\",\"id\":\"\(id)\",\"method\":\"\(method)\",\"params\":{}}".utf8)
  }

  private static func collect(_ stream: AsyncThrowingStream<Data, any Error>, count: Int)
    async throws -> [JSONValue]
  {
    try await withThrowingTaskGroup(of: [JSONValue].self) { group in
      group.addTask {
        var result: [JSONValue] = []
        for try await data in stream {
          result.append(try JSONDecoder().decode(JSONValue.self, from: data))
          if result.count == count { return result }
        }
        return result
      }
      group.addTask {
        try await Task.sleep(for: .seconds(10))
        throw HTTPStreamTestError.timeout
      }
      defer { group.cancelAll() }
      return try await group.next() ?? []
    }
  }
}

private enum HTTPStreamTestError: Error { case timeout }

struct HTTPStreamProcessFixture {
  let root: URL
  let process: ManagedLineProcess
  let endpoint: URL

  init() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mcp-http-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let script = root.appendingPathComponent("server.py")
    try Self.script.write(to: script, atomically: true, encoding: .utf8)
    let process = try ManagedLineProcess(
      configuration: .init(
        executable: "/usr/bin/python3", arguments: [script.path, root.path],
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
      await process.close()
      if await process.snapshot().hasExited { try? FileManager.default.removeItem(at: root) }
      throw error
    }
  }

  func transport(streaming: Bool = true) -> MCPHTTPClientTransport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 3
    configuration.timeoutIntervalForResource = 15
    return MCPHTTPClientTransport(
      endpoint: endpoint, configuration: configuration, streaming: streaming,
      requestModifier: { request in
        var request = request
        request.setValue("Bearer fixture-token", forHTTPHeaderField: "Authorization")
        return request
      })
  }

  func requests() throws -> [[String: JSONValue]] {
    guard
      let data = FileManager.default.contents(
        atPath: root.appendingPathComponent("requests.jsonl").path)
    else { return [] }
    return try data.split(separator: 10).compactMap {
      try JSONDecoder().decode(JSONValue.self, from: Data($0)).objectValue
    }
  }

  func waitForRequest(id: String) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
      if try requests().contains(where: { $0["id"] == .string(id) }) { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw HTTPStreamTestError.timeout
  }

  static func withFixture(_ operation: (Self) async throws -> Void) async throws {
    let fixture = try await Self()
    do {
      try await operation(fixture)
      await fixture.cleanup()
    } catch {
      await fixture.cleanup()
      throw error
    }
  }

  func cleanup() async {
    await process.close()
    guard await process.snapshot().hasExited else {
      Issue.record("The owned HTTP fixture did not confirm exit; its directory is preserved.")
      return
    }
    try? FileManager.default.removeItem(at: root)
  }

  private static let script = #"""
    import http.server
    import json
    import pathlib
    import sys
    import threading
    import time

    root = pathlib.Path(sys.argv[1])
    lock = threading.Lock()

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
    server.serve_forever()
    """#
}
