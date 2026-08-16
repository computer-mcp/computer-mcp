import Foundation
import Testing

@testable import ComputerMCP

@Suite(.serialized)

final class MCPProxyClientTests {
  @Test
  func testStdioProxyUsesLineDelimitedMCPMessages() async throws {
    try await runBlockingTest {
      let script = try self.fakeLineDelimitedMCPServer()
      let server = MCPServerConfig(
        id: "fake-line",
        transport: .stdio,
        command: script.path,
        requestTimeoutMs: 5_000
      )
      let client = MCPProxyClient()

      let tools = try client.listTools(server: server)
      #expect((tools.map(\.name)) == (["sample"]))
      #expect((tools.first?.title) == ("Sample Tool"))
      #expect(
        (tools.first?.outputSchema)
          == (.object([
            "type": .string("object"),
            "properties": .object(["answer": .object(["type": .string("string")])]),
            "required": .array([.string("answer")]),
          ])))
      #expect((tools.first?.annotations?.readOnlyHint) == (true))
      #expect((tools.first?.annotations?.destructiveHint) == (false))

      let result = try client.callTool(
        server: server,
        name: "sample",
        arguments: .object(["value": .string("x")])
      )
      #expect(
        (result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"])
          == (.string("called")))
      #expect(
        (result.objectValue?["structuredContent"]) == (.object(["answer": .string("called")])))
      #expect((result.objectValue?["_meta"]?.objectValue?["provider"]) == (.string("fake")))
    }
  }

  @Test
  func testPersistentSessionSupportsResourcesPromptsStatusAndListChangedEvents() async throws {
    try await runBlockingTest {
      let fixture = try self.fakePersistentMCPServer()
      let server = MCPServerConfig(
        id: "persistent",
        transport: .stdio,
        command: fixture.script.path,
        args: [fixture.startMarker.path, fixture.cancelMarker.path],
        requestTimeoutMs: 5_000
      )
      let client = MCPProxyClient()

      #expect((try client.listTools(server: server).map(\.name)) == (["sample", "hang"]))

      let resources = try client.listResources(server: server, cursor: nil)
      #expect(
        (resources.objectValue?["resources"]?.arrayValue?.first?.objectValue?["uri"])
          == (.string("memory://sample")))
      let templates = try client.listResourceTemplates(server: server, cursor: nil)
      #expect(
        (templates.objectValue?["resourceTemplates"]?.arrayValue?.first?.objectValue?[
          "uriTemplate"
        ]) == (.string("memory://{name}")))
      let resource = try client.readResource(server: server, uri: "memory://sample")
      #expect(
        (resource.objectValue?["contents"]?.arrayValue?.first?.objectValue?["text"])
          == (.string("resource-body")))

      let prompts = try client.listPrompts(server: server, cursor: nil)
      #expect(
        (prompts.objectValue?["prompts"]?.arrayValue?.first?.objectValue?["name"])
          == (.string("sample-prompt")))
      let prompt = try client.getPrompt(
        server: server,
        name: "sample-prompt",
        arguments: ["value": "x"]
      )
      #expect(
        (prompt.objectValue?["messages"]?.arrayValue?.first?.objectValue?["role"])
          == (.string("user")))

      for _ in 0..<20 {
        let events = try client.readEvents(server: server, afterCursor: 0, maxResults: 100)
        if events.objectValue?["events"]?.arrayValue?.contains(where: {
          $0.objectValue?["kind"] == .string("notifications/tools/list_changed")
        }) == true {
          break
        }
        Thread.sleep(forTimeInterval: 0.01)
      }
      let events = try client.readEvents(server: server, afterCursor: 0, maxResults: 100)
      #expect(
        events.objectValue?["events"]?.arrayValue?.contains(where: {
          $0.objectValue?["kind"] == .string("notifications/tools/list_changed")
        }) == true)

      let status = try client.connectionStatus(server: server)
      #expect((status.objectValue?["state"]) == (.string("connected")))
      #expect((status.objectValue?["persistent_session"]) == (.bool(true)))

      let starts = try String(contentsOf: fixture.startMarker, encoding: .utf8)
      #expect((starts) == ("started\n"))
    }
  }

  @Test
  func testTimedOutToolCallSendsDownstreamCancellation() async throws {
    try await runBlockingTest {
      let fixture = try self.fakePersistentMCPServer()
      let server = MCPServerConfig(
        id: "cancel",
        transport: .stdio,
        command: fixture.script.path,
        args: [fixture.startMarker.path, fixture.cancelMarker.path],
        requestTimeoutMs: 150
      )
      let client = MCPProxyClient()

      expectThrows(
        try client.callTool(
          server: server,
          name: "hang",
          arguments: .object([:]),
          requestID: "cancel-me"
        )
      )

      #expect(
        !(try self.waitForNonemptyFile(at: fixture.cancelMarker)
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .isEmpty))

      #expect((try client.listTools(server: server).map(\.name)) == (["sample", "hang"]))
      let starts = try String(contentsOf: fixture.startMarker, encoding: .utf8)
      #expect((starts) == ("started\nstarted\n"))
    }
  }

  @Test
  func testStartedToolCallCanBeListedCancelledAndConnectionReused() async throws {
    try await runBlockingTest {
      let fixture = try self.fakePersistentMCPServer()
      let server = MCPServerConfig(
        id: "started-cancel",
        transport: .stdio,
        command: fixture.script.path,
        args: [fixture.startMarker.path, fixture.cancelMarker.path],
        requestTimeoutMs: 5_000
      )
      let client = MCPProxyClient()

      let started = try client.startToolCall(
        server: server,
        name: "hang",
        arguments: .object([:]),
        requestID: "started-cancel-me"
      )
      #expect((started.objectValue?["state"]) == (.string("running")))
      #expect((started.objectValue?["request_id"]) == (.string("started-cancel-me")))

      let active = try client.activeRequests(server: server)
      #expect(
        (active.objectValue?["requests"]?.arrayValue?.first?.objectValue?["request_id"])
          == (.string("started-cancel-me")))

      let cancelled = try client.cancelRequest(
        server: server,
        requestID: "started-cancel-me",
        reason: "test cancellation"
      )
      #expect((cancelled.objectValue?["cancelled"]) == (.bool(true)))
      #expect((try client.activeRequests(server: server).objectValue?["requests"]) == (.array([])))

      #expect(
        !(try self.waitForNonemptyFile(at: fixture.cancelMarker)
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .isEmpty))

      let events = try client.readEvents(server: server, afterCursor: 0, maxResults: 100)
      let kinds = events.objectValue?["events"]?.arrayValue?.compactMap {
        $0.objectValue?["kind"]?.stringValue
      }
      #expect(kinds?.contains("request.started") == true)
      #expect(kinds?.contains("request.cancelled") == true)
      #expect((try client.listTools(server: server).map(\.name)) == (["sample", "hang"]))
      #expect((try String(contentsOf: fixture.startMarker, encoding: .utf8)) == ("started\n"))
    }
  }

  @Test
  func testHTTPProxyPreservesNegotiatedSessionAcrossRequests() async throws {
    try await runBlockingTest {
      let fixture = try self.fakeHTTPMCPServer()
      defer {
        fixture.process.terminate()
        fixture.process.waitUntilExit()
      }
      let server = MCPServerConfig(
        id: "http",
        transport: .http,
        url: "http://127.0.0.1:\(fixture.port)/mcp",
        requestTimeoutMs: 5_000
      )
      let client = MCPProxyClient()

      #expect((try client.listTools(server: server).map(\.name)) == (["http-sample"]))
      let result = try client.callTool(
        server: server,
        name: "http-sample",
        arguments: .object([:])
      )
      #expect(
        (result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"])
          == (.string("http-called")))

      let sessions = try String(contentsOf: fixture.sessionMarker, encoding: .utf8)
        .split(separator: "\n")
      #expect((sessions.count) >= (2))
      #expect(sessions.allSatisfy { $0 == "session-1" })
      #expect(
        (try client.connectionStatus(server: server).objectValue?["state"])
          == (.string("connected")))
    }
  }

  @Test
  func testExitedStdioProviderCannotTerminateGatewayAndNextCallReconnects() async throws {
    try await runBlockingTest {
      let fixture = try self.fakeExitingMCPServer()
      let server = MCPServerConfig(
        id: "exiting",
        transport: .stdio,
        command: fixture.script.path,
        args: [fixture.startMarker.path],
        requestTimeoutMs: 5_000
      )
      let client = MCPProxyClient()

      #expect((try client.listTools(server: server).map(\.name)) == (["crash"]))
      _ = try client.callTool(
        server: server,
        name: "crash",
        arguments: .object([:])
      )
      Thread.sleep(forTimeInterval: 0.1)

      expectThrows(try client.listTools(server: server))
      #expect((try client.listTools(server: server).map(\.name)) == (["crash"]))
      #expect(
        (try String(contentsOf: fixture.startMarker, encoding: .utf8)) == ("started\nstarted\n"))
    }
  }

  private func runBlockingTest(_ operation: @escaping () throws -> Void) async throws {
    let operation = BlockingTestOperation(operation)
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(with: Result(catching: operation.run))
      }
    }
  }

  private func fakeLineDelimitedMCPServer() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("fake-mcp.py")
    let text = """
      #!/usr/bin/env python3
      import json
      import sys

      for line in sys.stdin:
          message = json.loads(line)
          method = message.get("method")
          if method == "notifications/initialized":
              continue
          response = {"jsonrpc": "2.0", "id": message.get("id")}
          if method == "initialize":
              response["result"] = {
                  "protocolVersion": "2025-11-25",
                  "capabilities": {"tools": {}},
                  "serverInfo": {"name": "fake", "version": "1"},
              }
          elif method == "tools/list":
              response["result"] = {
                  "tools": [
                      {
                          "name": "sample",
                          "title": "Sample Tool",
                          "description": "Sample",
                          "inputSchema": {"type": "object"},
                          "outputSchema": {
                              "type": "object",
                              "properties": {"answer": {"type": "string"}},
                              "required": ["answer"],
                          },
                          "annotations": {
                              "readOnlyHint": True,
                              "destructiveHint": False,
                              "openWorldHint": False,
                          },
                      }
                  ]
              }
          elif method == "tools/call":
              response["result"] = {
                  "content": [{"type": "text", "text": "called"}],
                  "structuredContent": {"answer": "called"},
                  "isError": False,
                  "_meta": {"provider": "fake"},
              }
          else:
              response["error"] = {"code": -32601, "message": "not found"}
          print(json.dumps(response, separators=(",", ":")), flush=True)
      """
    try text.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: script.path
    )
    return script
  }

  private func fakePersistentMCPServer() throws -> (
    script: URL,
    startMarker: URL,
    cancelMarker: URL
  ) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("persistent-mcp.py")
    let startMarker = directory.appendingPathComponent("starts.txt")
    let cancelMarker = directory.appendingPathComponent("cancelled.txt")
    let text = """
      #!/usr/bin/env python3
      import json
      import sys

      start_marker = sys.argv[1]
      cancel_marker = sys.argv[2]
      with open(start_marker, "a", encoding="utf-8") as marker:
          marker.write("started\\n")

      for line in sys.stdin:
          message = json.loads(line)
          method = message.get("method")
          if method == "notifications/initialized":
              continue
          if method == "notifications/cancelled":
              with open(cancel_marker, "a", encoding="utf-8") as marker:
                  marker.write(str(message.get("params", {}).get("requestId")) + "\\n")
              continue

          response = {"jsonrpc": "2.0", "id": message.get("id")}
          if method == "initialize":
              response["result"] = {
                  "protocolVersion": "2025-11-25",
                  "capabilities": {
                      "tools": {"listChanged": True},
                      "resources": {"listChanged": True},
                      "prompts": {"listChanged": True},
                  },
                  "serverInfo": {"name": "persistent-fake", "version": "1"},
              }
          elif method == "tools/list":
              response["result"] = {
                  "tools": [
                      {"name": "sample", "description": "Sample", "inputSchema": {"type": "object"}},
                      {"name": "hang", "description": "Hangs", "inputSchema": {"type": "object"}},
                  ]
              }
          elif method == "tools/call":
              if message.get("params", {}).get("name") == "hang":
                  continue
              response["result"] = {
                  "content": [{"type": "text", "text": "called"}],
                  "isError": False,
              }
          elif method == "resources/list":
              response["result"] = {
                  "resources": [
                      {"uri": "memory://sample", "name": "sample", "mimeType": "text/plain"}
                  ]
              }
          elif method == "resources/templates/list":
              response["result"] = {
                  "resourceTemplates": [
                      {
                          "uriTemplate": "memory://{name}",
                          "name": "memory",
                          "mimeType": "text/plain",
                      }
                  ]
              }
          elif method == "resources/read":
              response["result"] = {
                  "contents": [
                      {
                          "uri": message.get("params", {}).get("uri"),
                          "mimeType": "text/plain",
                          "text": "resource-body",
                      }
                  ]
              }
          elif method == "prompts/list":
              response["result"] = {
                  "prompts": [
                      {
                          "name": "sample-prompt",
                          "description": "Sample",
                          "arguments": [{"name": "value", "required": False}],
                      }
                  ]
              }
          elif method == "prompts/get":
              response["result"] = {
                  "description": "Sample",
                  "messages": [
                      {"role": "user", "content": {"type": "text", "text": "hello"}}
                  ],
              }
          else:
              response["error"] = {"code": -32601, "message": "not found"}

          print(json.dumps(response, separators=(",", ":")), flush=True)
          if method == "tools/list":
              print(
                  json.dumps(
                      {"jsonrpc": "2.0", "method": "notifications/tools/list_changed"},
                      separators=(",", ":"),
                  ),
                  flush=True,
              )
      """
    try text.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: script.path
    )
    return (script, startMarker, cancelMarker)
  }

  private func waitForNonemptyFile(
    at url: URL,
    timeout: TimeInterval = 1
  ) throws -> String {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let contents = try? String(contentsOf: url, encoding: .utf8),
        !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        return contents
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
    return try String(contentsOf: url, encoding: .utf8)
  }

  private func fakeHTTPMCPServer() throws -> (
    process: Process,
    port: Int,
    sessionMarker: URL
  ) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("http-mcp.py")
    let portFile = directory.appendingPathComponent("port.txt")
    let sessionMarker = directory.appendingPathComponent("sessions.txt")
    let text = """
      #!/usr/bin/env python3
      import json
      import sys
      from http.server import BaseHTTPRequestHandler
      from socketserver import ThreadingTCPServer

      port_file = sys.argv[1]
      session_marker = sys.argv[2]

      class Handler(BaseHTTPRequestHandler):
          protocol_version = "HTTP/1.1"

          def do_POST(self):
              length = int(self.headers.get("Content-Length", "0"))
              message = json.loads(self.rfile.read(length))
              method = message.get("method")
              session = self.headers.get("Mcp-Session-Id")
              if session:
                  with open(session_marker, "a", encoding="utf-8") as marker:
                      marker.write(session + "\\n")

              if method == "notifications/initialized":
                  self.send_response(202)
                  self.send_header("Mcp-Session-Id", "session-1")
                  self.send_header("Content-Length", "0")
                  self.end_headers()
                  return

              response = {"jsonrpc": "2.0", "id": message.get("id")}
              if method == "initialize":
                  response["result"] = {
                      "protocolVersion": "2025-11-25",
                      "capabilities": {"tools": {}},
                      "serverInfo": {"name": "http-fake", "version": "1"},
                  }
              elif method == "tools/list":
                  response["result"] = {
                      "tools": [
                          {
                              "name": "http-sample",
                              "description": "HTTP sample",
                              "inputSchema": {"type": "object"},
                          }
                      ]
                  }
              elif method == "tools/call":
                  response["result"] = {
                      "content": [{"type": "text", "text": "http-called"}],
                      "isError": False,
                  }
              else:
                  response["error"] = {"code": -32601, "message": "not found"}

              body = json.dumps(response, separators=(",", ":")).encode("utf-8")
              self.send_response(200)
              self.send_header("Content-Type", "application/json")
              self.send_header("Mcp-Session-Id", "session-1")
              self.send_header("Content-Length", str(len(body)))
              self.end_headers()
              self.wfile.write(body)
              self.wfile.flush()

          def log_message(self, format, *args):
              pass

      server = ThreadingTCPServer(("127.0.0.1", 0), Handler)
      with open(port_file, "w", encoding="utf-8") as file:
          file.write(str(server.server_address[1]))
      server.serve_forever()
      """
    try text.write(to: script, atomically: true, encoding: .utf8)

    let process = Process()
    let errorPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", script.path, portFile.path, sessionMarker.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errorPipe
    try process.run()

    for _ in 0..<200 where !FileManager.default.fileExists(atPath: portFile.path) {
      Thread.sleep(forTimeInterval: 0.01)
    }
    guard
      let portText = try? String(contentsOf: portFile, encoding: .utf8),
      let port = Int(portText)
    else {
      let wasRunning = process.isRunning
      process.terminate()
      process.waitUntilExit()
      let stderr =
        String(
          data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
          encoding: .utf8
        ) ?? ""
      throw GatewayToolError.executionFailed(
        "Fake HTTP MCP server failed to start (running: \(wasRunning), status: \(process.terminationStatus), directory: \(directory.path)): \(stderr)"
      )
    }
    return (process, port, sessionMarker)
  }

  private func fakeExitingMCPServer() throws -> (
    script: URL,
    startMarker: URL
  ) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("exiting-mcp.py")
    let startMarker = directory.appendingPathComponent("starts.txt")
    let text = """
      #!/usr/bin/env python3
      import json
      import sys

      with open(sys.argv[1], "a", encoding="utf-8") as marker:
          marker.write("started\\n")

      for line in sys.stdin:
          message = json.loads(line)
          method = message.get("method")
          if method == "notifications/initialized":
              continue
          response = {"jsonrpc": "2.0", "id": message.get("id")}
          if method == "initialize":
              response["result"] = {
                  "protocolVersion": "2025-11-25",
                  "capabilities": {"tools": {}},
                  "serverInfo": {"name": "exiting-fake", "version": "1"},
              }
          elif method == "tools/list":
              response["result"] = {
                  "tools": [
                      {"name": "crash", "description": "Exit", "inputSchema": {"type": "object"}}
                  ]
              }
          elif method == "tools/call":
              response["result"] = {
                  "content": [{"type": "text", "text": "exiting"}],
                  "isError": False,
              }
              print(json.dumps(response, separators=(",", ":")), flush=True)
              sys.exit(86)
          else:
              response["error"] = {"code": -32601, "message": "not found"}
          print(json.dumps(response, separators=(",", ":")), flush=True)
      """
    try text.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: script.path
    )
    return (script, startMarker)
  }
}

private final class BlockingTestOperation: @unchecked Sendable {
  private let operation: () throws -> Void

  init(_ operation: @escaping () throws -> Void) {
    self.operation = operation
  }

  func run() throws {
    try operation()
  }
}
