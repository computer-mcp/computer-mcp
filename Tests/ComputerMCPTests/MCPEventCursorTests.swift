import Foundation
import Testing

@testable import ComputerMCP

struct MCPEventCursorTests {
  @Test
  func initialReadsAndUnavailableContinuationsDoNotStartAProvider() async throws {
    let fixture = try EventFixture()
    defer { fixture.remove() }
    let client = MCPProxyClient(workingDirectory: fixture.root)
    do {
      let initial = try client.readEvents(server: fixture.server, afterCursor: 0, maxResults: 10)
      #expect(initial.objectValue?["cursor_state"] == .string("not_started"))
      #expect(initial.objectValue?["session_id"] == .null)
      #expect(initial.objectValue?["missed_events"] == .null)
      #expect(initial.objectValue?["events"] == .array([]))
      #expect(throws: (any Error).self) {
        try client.readEvents(server: fixture.server, afterCursor: 1, maxResults: 10)
      }
      #expect(throws: (any Error).self) {
        try client.readEvents(
          server: fixture.server, afterCursor: 0, maxResults: 10, sessionID: "old-session")
      }
      #expect(!FileManager.default.fileExists(atPath: fixture.starts.path))
      await client.shutdown()
    } catch {
      await client.shutdown()
      throw error
    }
  }

  @Test
  func longEventStreamReportsEvictionAndPaginatesWithinOneVerifiedSession() async throws {
    let fixture = try EventFixture()
    defer { fixture.remove() }
    let client = MCPProxyClient(workingDirectory: fixture.root)
    do {
      // Responses drain each burst below the transport queue bound before sending more events.
      for _ in 0..<100 {
        _ = try client.callTool(server: fixture.server, name: "stream", arguments: .object([:]))
      }
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(5))
      var page = try client.readEvents(server: fixture.server, afterCursor: 0, maxResults: 7)
      while page.objectValue?["latest_event_cursor"]?.intValue ?? 0 < 701, clock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
        page = try client.readEvents(server: fixture.server, afterCursor: 0, maxResults: 7)
      }
      let object = try #require(page.objectValue)
      let sessionID = try #require(object["session_id"]?.stringValue)
      let latest = try #require(object["latest_event_cursor"]?.intValue)
      let oldest = try #require(object["oldest_available_cursor"]?.intValue)
      #expect(latest >= 701)
      #expect(latest - oldest + 1 == 512)
      #expect(object["missed_events"] == .number(Double(oldest - 1)))
      #expect(object["cursor_state"] == .string("truncated"))
      #expect(object["events"]?.arrayValue?.count == 7)
      #expect(object["has_more"] == .bool(true))
      let next = try #require(object["next_cursor"]?.intValue)
      let verified = try client.readEvents(
        server: fixture.server, afterCursor: next, maxResults: 500, sessionID: sessionID)
      #expect(verified.objectValue?["session_verified"] == .bool(true))
      #expect(verified.objectValue?["events"]?.arrayValue?.count == 500)
      #expect(verified.objectValue?["missed_events"] == .number(0))
      let tail = try client.readEvents(
        server: fixture.server,
        afterCursor: try #require(verified.objectValue?["next_cursor"]?.intValue),
        maxResults: 500, sessionID: sessionID)
      #expect(tail.objectValue?["has_more"] == .bool(false))
      #expect(tail.objectValue?["events"]?.arrayValue?.count == 5)
      let unbound = try client.readEvents(
        server: fixture.server, afterCursor: latest, maxResults: 1)
      #expect(unbound.objectValue?["cursor_state"] == .string("unbound"))
      #expect(unbound.objectValue?["session_verified"] == .bool(false))
      #expect(throws: (any Error).self) {
        try client.readEvents(
          server: fixture.server, afterCursor: Int.max, maxResults: 1, sessionID: sessionID)
      }
      #expect(throws: (any Error).self) {
        try client.readEvents(
          server: fixture.server, afterCursor: latest, maxResults: 501, sessionID: sessionID)
      }
      #expect(try String(contentsOf: fixture.starts, encoding: .utf8) == "started\n")
      await client.shutdown()
    } catch {
      await client.shutdown()
      throw error
    }
  }

  @Test
  func sameNumericCursorFromAnotherInstanceIsRejectedThroughAuthorizationWrapper() async throws {
    let fixture = try EventFixture()
    defer { fixture.remove() }
    let first = MCPProxyClient(workingDirectory: fixture.root)
    let replacement = MCPProxyClient(workingDirectory: fixture.root)
    do {
      _ = try first.listTools(server: fixture.server)
      let original = try first.readEvents(server: fixture.server, afterCursor: 0, maxResults: 10)
      let oldSession = try #require(original.objectValue?["session_id"]?.stringValue)
      let cursor = try #require(original.objectValue?["next_cursor"]?.intValue)
      await first.shutdown()
      #expect(throws: (any Error).self) {
        try replacement.readEvents(
          server: fixture.server, afterCursor: cursor, maxResults: 10, sessionID: oldSession)
      }
      #expect(try String(contentsOf: fixture.starts, encoding: .utf8) == "started\n")
      _ = try replacement.listTools(server: fixture.server)
      let authorized: any DownstreamMCPClient = AuthorizedMCPClient(
        base: replacement,
        policy: .init(
          configuration: .init(mcp: .init(servers: [fixture.server])),
          grant: .init(
            id: .chatGPTObserve, capabilityIDs: ["mcp.events.read"], allowedCallers: [.localMCP]),
          derivesObserveGrant: false))
      #expect(throws: (any Error).self) {
        try authorized.readEvents(
          server: fixture.server, afterCursor: cursor, maxResults: 10, sessionID: oldSession)
      }
      let current = try authorized.readEvents(
        server: fixture.server, afterCursor: 0, maxResults: 10, sessionID: nil)
      #expect(current.objectValue?["session_id"]?.stringValue != oldSession)
      #expect(try String(contentsOf: fixture.starts, encoding: .utf8) == "started\nstarted\n")
      await replacement.shutdown()
    } catch {
      await first.shutdown()
      await replacement.shutdown()
      throw error
    }
  }
}

private struct EventFixture {
  let root: URL
  let starts: URL
  let server: MCPServerConfig

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    starts = root.appendingPathComponent("starts")
    let script = root.appendingPathComponent("events.py")
    try Data(Self.script.utf8).write(to: script)
    server = .init(
      id: "fixture", transport: .stdio, command: "/usr/bin/python3",
      args: [script.path, starts.path],
      startupTimeoutMs: 5000, requestTimeoutMs: 10_000)
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  private static let script = #"""
    import json, sys
    with open(sys.argv[1], "a") as marker:
        marker.write("started\n")
    for line in sys.stdin:
        message = json.loads(line)
        if "id" not in message:
            continue
        method = message.get("method")
        result = {}
        if method == "initialize":
            result = {"protocolVersion":"2025-11-25", "capabilities":{"tools":{"listChanged":True}}, "serverInfo":{"name":"events", "version":"1"}}
        elif method == "tools/list":
            result = {"tools":[{"name":"stream", "inputSchema":{"type":"object"}}]}
        elif method == "tools/call":
            for _ in range(7):
                print(json.dumps({"jsonrpc":"2.0", "method":"notifications/tools/list_changed"}), flush=True)
            result = {"content":[]}
        print(json.dumps({"jsonrpc":"2.0", "id":message["id"], "result":result}), flush=True)
    """#
}
