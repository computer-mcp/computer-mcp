import Foundation
import Testing

@testable import ComputerMCP

@Suite(.serialized)

final class MCPProxyClientTests {
  @Test
  func testPaginatedCatalogReexportsOnlyAllowedToolsFromLaterPages() async throws {
    try await runBlockingTest {
      let script = try self.fakeLineDelimitedMCPServer(paginated: true)
      defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
      let server = MCPServerConfig(
        id: "paged", transport: .stdio, command: script.path,
        exposure: .reexport, prefix: "paged", allowedTools: ["sample"],
        requestTimeoutMs: 5_000)
      let client = MCPProxyClient()
      let discovered = try client.listTools(server: server)
      #expect(discovered.map(\.name) == ["hidden", "sample"])
      #expect(discovered.last?.title == "Sample Tool")
      #expect(discovered.last?.annotations?.readOnlyHint == true)
      #expect(discovered.last?.outputSchema?.objectValue?["type"] == .string("object"))

      let registry = GatewayToolRegistry(
        configuration: .fixture(mcp: MCPSectionConfig(servers: [server])), mcpClient: client)
      let exposed = try registry.listTools().map(\.name)
      #expect(exposed.contains("paged.sample"))
      #expect(!exposed.contains("paged.hidden"))
      let result = try registry.callTool(name: "paged.sample", arguments: .object([:]))
      #expect(result.objectValue?["structuredContent"] == .object(["answer": .string("called")]))
      expectThrows(
        try registry.callTool(
          name: "mcp.tools.call",
          arguments: .object([
            "server": .string("paged"), "tool": .string("hidden"), "arguments": .object([:]),
          ])))
      expectThrows(try registry.callTool(name: "paged.hidden", arguments: .object([:])))
    }
  }

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
      let fixture = try self.fakePersistentMCPServer(startupDelaySeconds: 0.3)
      let server = MCPServerConfig(
        id: "cancel",
        transport: .stdio,
        command: fixture.script.path,
        args: [fixture.startMarker.path, fixture.cancelMarker.path],
        startupTimeoutMs: 5_000,
        requestTimeoutMs: 150
      )
      let client = MCPProxyClient()

      #expect(throws: GatewayToolError.executionFailed("MCP server 'cancel' request timed out.")) {
        try client.callTool(
          server: server,
          name: "hang",
          arguments: .object([:]),
          requestID: "cancel-me"
        )
      }

      #expect(
        !(try self.waitForNonemptyFile(at: fixture.cancelMarker)
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .isEmpty))

      var recoveryServer = server
      recoveryServer.requestTimeoutMs = 5_000
      #expect((try client.listTools(server: recoveryServer).map(\.name)) == (["sample", "hang"]))
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
      #expect(cancelled.objectValue?["cancellation_requested"] == .bool(true))
      #expect(cancelled.objectValue?["execution_stopped"] == .null)
      #expect(cancelled.objectValue?["cancelled"] == nil)
      let pending = try client.activeRequests(server: server).objectValue?["requests"]?.arrayValue
      #expect(pending?.count == 1)
      #expect(pending?.first?.objectValue?["state"] == .string("cancellation_requested"))
      #expect(throws: (any Error).self) {
        try client.startToolCall(
          server: server, name: "sample", arguments: .object([:]), requestID: "started-cancel-me")
      }

      #expect(
        !(try self.waitForNonemptyFile(at: fixture.cancelMarker)
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .isEmpty))

      let events = try client.readEvents(server: server, afterCursor: 0, maxResults: 100)
      let kinds = events.objectValue?["events"]?.arrayValue?.compactMap {
        $0.objectValue?["kind"]?.stringValue
      }
      #expect(kinds?.contains("request.started") == true)
      #expect(kinds?.contains("request.cancellation_requested") == true)
      #expect(kinds?.contains("request.cancellation_sent") == true)
      #expect(kinds?.contains("request.cancelled") == false)
      #expect(
        events.objectValue?["events"]?.arrayValue?.filter {
          $0.objectValue?["kind"]?.stringValue?.hasPrefix("request.") == true
        }.allSatisfy { $0.objectValue?["request_id"] == .string("started-cancel-me") } == true)
      #expect((try client.listTools(server: server).map(\.name)) == (["sample", "hang"]))
      #expect((try String(contentsOf: fixture.startMarker, encoding: .utf8)) == ("started\n"))
    }
  }

  @Test
  func testLateCompletionAfterStopRequestRemainsObservable() async throws {
    let fixture = try fakePersistentMCPServer()
    defer { try? FileManager.default.removeItem(at: fixture.script.deletingLastPathComponent()) }
    let server = MCPServerConfig(
      id: "late-completion", transport: .stdio, command: fixture.script.path,
      args: [fixture.startMarker.path, fixture.cancelMarker.path], requestTimeoutMs: 5_000)
    let client = MCPProxyClient()
    do {
      try await runBlockingTest {
        _ = try client.startToolCall(
          server: server, name: "hang", arguments: .object([:]), requestID: "late")
        _ = try client.cancelRequest(server: server, requestID: "late", reason: "stop")
        _ = try client.cancelRequest(server: server, requestID: "late", reason: "stop again")
        #expect(
          try client.activeRequests(server: server).objectValue?["requests"]?.arrayValue?.count == 1
        )

        // The fixture only sends the original result after this explicit checkpoint.
        _ = try client.callTool(
          server: server, name: "sample", arguments: .object(["complete_pending": .bool(true)]))
        let deadline = ContinuousClock.now + .seconds(2)
        var completed = false
        repeat {
          let events = try client.readEvents(server: server, afterCursor: 0, maxResults: 100)
          completed =
            events.objectValue?["events"]?.arrayValue?.contains {
              $0.objectValue?["kind"] == .string("request.completed")
                && $0.objectValue?["request_id"] == .string("late")
            } == true
          if !completed { Thread.sleep(forTimeInterval: 0.01) }
        } while !completed && ContinuousClock.now < deadline
        #expect(completed)
        let receipt = try client.readRequest(
          server: server, requestID: "late", offset: 0, maxBytes: 4096)
        #expect(receipt.objectValue?["state"] == .string("succeeded"))
        #expect(receipt.objectValue?["output_state"] == .string("available"))
        #expect(receipt.objectValue?["result"] != nil)
        #expect(
          try client.startToolCall(
            server: server, name: "hang", arguments: .object([:]), requestID: "late") == receipt)
        #expect(
          try client.callTool(
            server: server, name: "hang", arguments: .object([:]), requestID: "late")
            == receipt.objectValue?["result"])
        #expect(throws: (any Error).self) {
          try client.callTool(
            server: server, name: "sample", arguments: .object([:]), requestID: "late")
        }
        #expect(try client.activeRequests(server: server).objectValue?["requests"] == .array([]))
        #expect(
          try String(contentsOf: fixture.cancelMarker, encoding: .utf8).split(separator: "\n").count
            == 1)
        #expect(try String(contentsOf: fixture.startMarker, encoding: .utf8) == "started\n")
      }
    } catch {
      await client.shutdown()
      throw error
    }
    await client.shutdown()
  }

  @Test
  func testStartupDeadlineIsIndependentOfLongRequestBudget() async throws {
    try await runBlockingTest {
      let fixture = try self.fakePersistentMCPServer(startupDelaySeconds: 0.5)
      let server = MCPServerConfig(
        id: "slow-startup", transport: .stdio, command: fixture.script.path,
        args: [fixture.startMarker.path, fixture.cancelMarker.path],
        startupTimeoutMs: 100, requestTimeoutMs: 5_000)
      let client = MCPProxyClient()
      #expect(
        throws: GatewayToolError.executionFailed("MCP server 'slow-startup' startup timed out.")
      ) {
        try client.listTools(server: server)
      }
      let state = try client.connectionStatus(server: server).objectValue?["state"]
      #expect(state == .string("retiring") || state == .string("not_started"))
      #expect(!FileManager.default.fileExists(atPath: fixture.cancelMarker.path))
    }
  }

  @Test func testSynchronousDeduplicationAndReadAfterRestartDoNotDispatchAgain() async throws {
    let fixture = try fakePersistentMCPServer()
    defer { try? FileManager.default.removeItem(at: fixture.script.deletingLastPathComponent()) }
    let databasePath = fixture.script.deletingLastPathComponent().appendingPathComponent(
      "receipts.sqlite"
    ).path
    let database = try GatewayDatabase(path: databasePath)
    let server = MCPServerConfig(
      id: "retained", transport: .stdio, command: fixture.script.path,
      args: [fixture.startMarker.path, fixture.cancelMarker.path], requestTimeoutMs: 5_000)
    let client = MCPProxyClient(executionDatabase: database, executionScope: "owner/workspace")
    do {
      try await runBlockingTest {
        let result = try client.callTool(
          server: server, name: "counter", arguments: .object([:]), requestID: "once")
        #expect(result.objectValue?["structuredContent"]?.objectValue?["dispatches"] == .number(1))
        #expect(
          try client.callTool(
            server: server, name: "counter", arguments: .object([:]), requestID: "once") == result)
        #expect(
          try client.startToolCall(
            server: server, name: "counter", arguments: .object([:]), requestID: "once"
          ).objectValue?["result"] == result)
        let next = try client.callTool(
          server: server, name: "counter", arguments: .object([:]), requestID: "second")
        #expect(next.objectValue?["structuredContent"]?.objectValue?["dispatches"] == .number(2))
        _ = try client.startToolCall(
          server: server, name: "hang", arguments: .object([:]), requestID: "unresolved")
      }
    } catch {
      await client.shutdown()
      throw error
    }
    await client.shutdown()
    let restored = MCPProxyClient(
      executionDatabase: try GatewayDatabase(path: databasePath), executionScope: "owner/workspace")
    do {
      try await runBlockingTest {
        let read = try restored.readRequest(
          server: server, requestID: "once", offset: 0, maxBytes: 4096)
        #expect(read.objectValue?["state"] == .string("succeeded"))
        #expect(
          try restored.callTool(
            server: server, name: "counter", arguments: .object([:]), requestID: "once")
            == read.objectValue?["result"])
        let unknown = try restored.startToolCall(
          server: server, name: "hang", arguments: .object([:]), requestID: "unresolved")
        #expect(unknown.objectValue?["state"] == .string("outcome_unknown"))
        #expect(unknown.objectValue?["cleanup"] == .string("confirmed"))
        #expect(
          try restored.connectionStatus(server: server).objectValue?["state"]
            == .string("not_started"))
        #expect(try String(contentsOf: fixture.startMarker, encoding: .utf8) == "started\n")
      }
    } catch {
      await restored.shutdown()
      throw error
    }
    await restored.shutdown()
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
    let fixture = try fakeExitingMCPServer()
    defer { try? FileManager.default.removeItem(at: fixture.script.deletingLastPathComponent()) }
    let client = MCPProxyClient()
    do {
      let server = MCPServerConfig(
        id: "exiting",
        transport: .stdio,
        command: fixture.script.path,
        args: [fixture.startMarker.path],
        requestTimeoutMs: 5_000
      )
      let evidence = try await BlockingOperationExecutor(label: "exiting-provider-test").perform {
        let initialCatalog = try client.listTools(server: server).map(\.name)
        let response = try client.callTool(server: server, name: "crash", arguments: .object([:]))
        let deadline = ContinuousClock.now + .seconds(2)
        var state = try client.connectionStatus(server: server).objectValue?["state"]
        while state == .string("connected"), ContinuousClock.now < deadline {
          Thread.sleep(forTimeInterval: 0.02)
          state = try client.connectionStatus(server: server).objectValue?["state"]
        }
        let reconnectedCatalog = try client.listTools(server: server).map(\.name)
        let starts = try String(contentsOf: fixture.startMarker, encoding: .utf8)
        return (initialCatalog, response, state, reconnectedCatalog, starts)
      }
      #expect(evidence.0 == ["crash"])
      #expect(
        evidence.1.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]
          == .string("exiting"))
      #expect(evidence.2 != .string("connected"))
      #expect(evidence.3 == ["crash"])
      #expect(evidence.4 == "started\nstarted\n")
    } catch {
      await client.shutdown()
      throw error
    }
    await client.shutdown()
  }

  private func runBlockingTest(_ operation: @escaping () throws -> Void) async throws {
    let operation = BlockingTestOperation(operation)
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(with: Result(catching: operation.run))
      }
    }
  }

  private func fakeLineDelimitedMCPServer(paginated: Bool = false) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("fake-mcp.py")
    let text = """
      #!/usr/bin/env python3
      import json
      import sys

      paginated = \(paginated ? "True" : "False")
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
              cursor = message.get("params", {}).get("cursor")
              if paginated and cursor is None:
                  response["result"] = {
                      "tools": [{"name": "hidden", "inputSchema": {"type": "object"}}],
                      "nextCursor": "",
                  }
                  print(json.dumps(response), flush=True)
                  continue
              if paginated and cursor == "":
                  response["result"] = {"tools": [], "nextCursor": "page-two"}
                  print(json.dumps(response), flush=True)
                  continue
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

  private func fakePersistentMCPServer(startupDelaySeconds: Double = 0) throws -> (
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
      import time

      start_marker = sys.argv[1]
      cancel_marker = sys.argv[2]
      with open(start_marker, "a", encoding="utf-8") as marker:
          marker.write("started\\n")
      pending = []
      dispatches = 0

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
              time.sleep(\(startupDelaySeconds))
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
              dispatches += 1
              if message.get("params", {}).get("name") == "hang":
                  pending.append(message["id"])
                  continue
              if message.get("params", {}).get("arguments", {}).get("complete_pending"):
                  for pending_id in pending:
                      print(json.dumps({"jsonrpc": "2.0", "id": pending_id, "result": {
                          "content": [{"type": "text", "text": "completed after stop request"}]
                      }}), flush=True)
                  pending.clear()
              response["result"] = {
                  "content": [{"type": "text", "text": "called"}],
                  "isError": False,
              }
              if message.get("params", {}).get("name") == "counter":
                  response["result"]["structuredContent"] = {"dispatches": dispatches}
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

  @Test
  func failedCancellationDeliveryRetainsUnknownReceiptAndCannotReplayTheWrite() async throws {
    let fixture = try fakeHTTPMCPServer(failCancellation: true)
    let directory = fixture.sessionMarker.deletingLastPathComponent()
    defer {
      if fixture.process.isRunning { fixture.process.terminate() }
      fixture.process.waitUntilExit()
      try? FileManager.default.removeItem(at: directory)
    }
    let database = try GatewayDatabase(inMemory: ())
    let client = MCPProxyClient(executionDatabase: database, executionScope: "cancel-failure")
    let server = MCPServerConfig(
      id: "cancel-failure", transport: .http,
      url: "http://127.0.0.1:\(fixture.port)/mcp", requestTimeoutMs: 5_000)
    let waiting = Task {
      try await client.callToolAsync(
        server: server, name: "http-sample", arguments: .object([:]), requestID: "write-once")
    }
    do {
      let marker = directory.appendingPathComponent("call-started.txt")
      let deadline = ContinuousClock.now + .seconds(5)
      while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(FileManager.default.fileExists(atPath: marker.path))
      waiting.cancel()
      await #expect(throws: (any Error).self) { _ = try await waiting.value }
      let receipt = try client.readRequest(
        server: server, requestID: "write-once", offset: 0, maxBytes: 4096)
      #expect(receipt.objectValue?["state"] == .string("outcome_unknown"))
      #expect(receipt.objectValue?["cancellation"] == .string("failed"))
      #expect(receipt.objectValue?["cleanup"] != .string("confirmed"))
      #expect(receipt.objectValue?["output_state"] == .string("unavailable"))
      #expect(throws: (any Error).self) {
        try client.callTool(
          server: server, name: "http-sample", arguments: .object([:]), requestID: "write-once")
      }
      let repeated = try client.startToolCall(
        server: server, name: "http-sample", arguments: .object([:]), requestID: "write-once")
      #expect(repeated.objectValue?["state"] == .string("outcome_unknown"))
      #expect(try String(contentsOf: marker, encoding: .utf8) == "called\n")
      try Data().write(to: directory.appendingPathComponent("release.txt"))
      await client.shutdown()
    } catch {
      waiting.cancel()
      try? Data().write(to: directory.appendingPathComponent("release.txt"))
      await client.shutdown()
      _ = await waiting.result
      throw error
    }
  }

  private func fakeHTTPMCPServer(failCancellation: Bool = false) throws -> (
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
      import pathlib
      import time
      from http.server import BaseHTTPRequestHandler
      from socketserver import ThreadingTCPServer

      port_file = sys.argv[1]
      session_marker = sys.argv[2]
      fail_cancellation = sys.argv[3] == "true"
      root = pathlib.Path(session_marker).parent

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

              if method == "notifications/cancelled" and fail_cancellation:
                  self.send_response(500)
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
                  if fail_cancellation:
                      with (root / "call-started.txt").open("a") as marker:
                          marker.write("called\\n")
                      deadline = time.monotonic() + 10
                      while not (root / "release.txt").exists() and time.monotonic() < deadline:
                          time.sleep(0.01)
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
    process.arguments = [
      "python3", script.path, portFile.path, sessionMarker.path,
      failCancellation ? "true" : "false",
    ]
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
