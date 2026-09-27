import Foundation
import Testing

@testable import ComputerMCP

@Suite(.serialized, .timeLimit(.minutes(1)))
struct MCPProviderWorkNativeTests {
  @Test
  func ordinaryProviderRetainsWorkAfterReplyAndRecoversObservation() async throws {
    try await withProvider { client, server, work in
      let started = try await call(client, server, "start")
      #expect(started.objectValue?["host_services"] == .bool(false))
      #expect(
        started.objectValue?["acquired_by"]?.stringValue.flatMap(UUID.init(uuidString:)) != nil)
      #expect(started.objectValue?["acquired_by"] != .string("caller-forged"))
      try await wait { work.snapshot.contains { $0.kind == .mcpResource && !$0.uncertain } }
      #expect(!work.snapshot.contains { $0.kind == .mcpRequest })
      _ = try await call(client, server, "invalid")
      try await wait { work.snapshot.contains { $0.kind == .mcpResource && $0.uncertain } }
      _ = try await call(client, server, "valid")
      try await wait { work.snapshot.contains { $0.kind == .mcpResource && !$0.uncertain } }
      _ = try await call(client, server, "finish")
      try await wait { work.snapshot.isEmpty }
      await client.shutdown()
      #expect(work.snapshot.isEmpty)
    }
  }

  @Test
  func stalledObservationIsSingleFlightAndDoesNotTerminateProvider() async throws {
    try await withProvider { client, server, work in
      let started = try await call(client, server, "start")
      try await wait { work.snapshot.contains { $0.kind == .mcpResource } }
      _ = try await call(client, server, "hold")
      try await wait { work.snapshot.contains { $0.kind == .mcpResource && $0.uncertain } }
      let first = try await call(client, server, "inspect")
      #expect(first.objectValue?["pid"] == started.objectValue?["pid"])
      #expect(first.objectValue?["pending_reads"] == .integer(1))
      try await Task.sleep(for: .milliseconds(1_100))
      let second = try await call(client, server, "inspect")
      #expect(second.objectValue?["pending_reads"] == .integer(1))
      #expect(second.objectValue?["read_count"] == first.objectValue?["read_count"])
      _ = try await call(client, server, "unhold")
      try await wait { work.snapshot.contains { $0.kind == .mcpResource && !$0.uncertain } }
      _ = try await call(client, server, "finish")
      try await wait { work.snapshot.isEmpty }
    }
  }

  @Test
  func confirmedSupervisorExitCannotAssertDetachedWorkCompletion() async throws {
    try await withProvider { client, server, work in
      _ = try await call(client, server, "start")
      try await wait { work.snapshot.contains { $0.kind == .mcpResource } }
      _ = try await call(client, server, "hold")
      try await wait { work.snapshot.contains { $0.kind == .mcpResource && $0.uncertain } }
      await client.shutdown()
      #expect(work.snapshot.contains { $0.kind == .mcpResource && $0.uncertain })
      #expect(work.snapshot.contains { $0.kind == .mcpObservation && $0.uncertain })
      #expect(!work.snapshot.contains { $0.kind == .mcpRequest })
    }
  }

  private func withProvider(
    _ body: (MCPProxyClient, MCPServerConfig, GatewayOwnedWork) async throws -> Void
  ) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("provider.py")
    try Self.provider.write(to: script, atomically: true, encoding: .utf8)
    let work = GatewayOwnedWork()
    var context = MCPHostContext(
      runtimeID: UUID(), context: .init(caller: .localCLI, profileID: .localAdmin),
      workspaceID: "fixture", rootURL: root, readOnly: false)
    context.ownedWork = work
    let client = MCPProxyClient(workingDirectory: root, hostContext: context)
    let server = MCPServerConfig(
      id: "work-provider", transport: .stdio, command: "/usr/bin/python3", args: [script.path],
      startupTimeoutMs: 5_000, requestTimeoutMs: 5_000, hostServices: false)
    do { try await body(client, server, work) } catch {
      await client.shutdown()
      throw error
    }
    await client.shutdown()
  }

  private func call(_ client: MCPProxyClient, _ server: MCPServerConfig, _ name: String)
    async throws
    -> JSONValue
  {
    let result = try await client.callToolAsync(
      server: server, name: name,
      arguments: .object(["acquired_by": .string("caller-forged")]), requestID: nil)
    return result.objectValue?["structuredContent"] ?? .null
  }

  private func wait(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(condition())
  }

  private static let provider = #"""
    import json, os, sys, uuid
    uri = "computer-mcp://runtime/work/v1"
    instance = str(uuid.uuid4())
    revision = 0
    resources = []
    pending = []
    read_count = 0
    holding = False
    invalid = False
    names = ["start", "finish", "hold", "unhold", "invalid", "valid", "inspect"]
    def send(id, result):
        print(json.dumps({"jsonrpc": "2.0", "id": id, "result": result}), flush=True)
    def report():
        body = {"format_version": 1, "instance_id": instance, "revision": revision, "resources": resources}
        text = "malformed" if invalid else json.dumps(body)
        return {"contents": [{"uri": uri, "mimeType": "application/json", "text": text}]}
    for line in sys.stdin:
        request = json.loads(line)
        if "id" not in request:
            continue
        method = request["method"]
        params = request.get("params", {})
        if method == "initialize":
            result = {"protocolVersion": "2025-11-25", "capabilities": {"tools": {}, "resources": {}}, "serverInfo": {"name": "work-fixture", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": [{"name": name, "inputSchema": {"type": "object"}, "_meta": {"io.github.computer-mcp/work": {"format_version": 1, "uri": uri}}} for name in names]}
        elif method == "resources/read":
            assert params["uri"] == uri
            read_count += 1
            result = report()
            if holding:
                pending.append((request["id"], result))
                continue
        elif method == "tools/call":
            name = params["name"]
            invocation = params.get("_meta", {}).get("io.github.computer-mcp/work-invocation")
            if name == "start":
                assert invocation is not None
                resources = [{"kind": "session", "id": 9007199254740993, "acquired_by": invocation, "state": "active"}]
                revision += 1
            elif name == "finish":
                resources = []
                revision += 1
            elif name == "hold": holding = True
            elif name == "unhold":
                holding = False
                for id, snapshot in pending:
                    send(id, snapshot)
                pending.clear()
            elif name == "invalid": invalid = True
            elif name == "valid": invalid = False
            result = {"content": [], "structuredContent": {"acquired_by": invocation, "host_services": "COMPUTER_MCP_HOST_FD" in os.environ, "pid": os.getpid(), "read_count": read_count, "pending_reads": len(pending)}}
        else:
            raise RuntimeError("Unexpected method")
        send(request["id"], result)
    """#
}
