import Foundation
import Testing

@testable import ComputerMCP

@Suite(.nativeIntegration, .serialized, .timeLimit(.minutes(1)))
struct MCPHostInvocationTests {
  @Test
  func backgroundWorkKeepsExactContextThroughDerivedWorkAndReleasesItAtCompletion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("provider.py")
    try Self.provider.write(to: script, atomically: true, encoding: .utf8)
    let names = ["background", "derive", "finish", "replay"]
    let database = try GatewayDatabase(path: root.appendingPathComponent("host.db").path)
    let runtime = try await GatewayRuntime.make(
      configuration: .init(
        runtime: .init(caller: .localMCP, profileID: .localAdmin),
        profiles: [
          .init(
            id: .localAdmin, capabilities: ["mcp.tools.call"], workspaces: ["fixture"],
            allowedCallers: [.localMCP], mode: .readOnly)
        ],
        mcp: .init(servers: [
          .init(
            id: "provider", transport: .stdio, command: "/usr/bin/python3",
            args: [script.path, "work"], allowedTools: names,
            startupTimeoutMs: 5_000, requestTimeoutMs: 5_000,
            toolRisks: Dictionary(uniqueKeysWithValues: names.map { ($0, .readOnly) }),
            hostServices: true)
        ])),
      database: database,
      registeredWorkspaces: [.init(id: "fixture", displayName: "Fixture", rootPath: root.path)])
    do {
      // Retained contexts must not exhaust the independent 256 active-call slots.
      for _ in 0..<257 {
        _ = try await runtime.callToolAsync(
          name: "mcp.tools.call", arguments: Self.arguments(tool: "background"))
      }
      try await Self.waitForResourceCount(257, runtime: runtime)
      let replay = try await runtime.callToolAsync(
        name: "mcp.tools.call", arguments: Self.arguments(tool: "replay"))
      let original = try #require(
        Self.payload(replay).objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue)
      #expect(original["tool"] == .string("background"))
      #expect(original["registration_id"] == .string("provider"))
      #expect(original["host_action"] == .string("diagnostics.snapshot"))
      _ = try await runtime.callToolAsync(
        name: "mcp.tools.call", arguments: Self.arguments(tool: "derive"))
      try await Self.waitForResourceCount(1, runtime: runtime)
      let derived = try await runtime.callToolAsync(
        name: "mcp.tools.call", arguments: Self.arguments(tool: "replay"))
      #expect(
        Self.payload(derived).objectValue?["structuredContent"]?.objectValue?["result"]
          == .object(original))
      let retainedID = try #require(
        original["invocation_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
      #expect(
        try runtime.requireHostInvocation(
          workspaceID: "fixture", origin: "provider", id: retainedID
        ).reference.toolName == "background")
      // Background context is not an active operation-ticket mutation window.
      #expect(throws: (any Error).self) {
        try runtime.requireHostInvocation(
          workspaceID: "fixture", origin: "provider", action: .diagnosticsSnapshot)
      }
      #expect(throws: (any Error).self) {
        try runtime.requireHostInvocation(workspaceID: "fixture", origin: "other", id: retainedID)
      }
      var grant = ProfileGrant(
        id: .localAdmin, capabilityIDs: ["mcp.tools.call"], workspaceIDs: [],
        allowedCallers: [.localMCP], mcpServerIDs: ["provider"])
      try database.saveProfile(grant)
      #expect(throws: (any Error).self) {
        try runtime.requireHostInvocation(
          workspaceID: "fixture", origin: "provider", id: retainedID)
      }
      grant.workspaceIDs = ["fixture"]
      try database.saveProfile(grant)
      #expect(
        try runtime.requireHostInvocation(
          workspaceID: "fixture", origin: "provider", id: retainedID
        ).id == retainedID)
      _ = try await runtime.callToolAsync(
        name: "mcp.tools.call", arguments: Self.arguments(tool: "finish"))
      try await Self.waitForResourceCount(0, runtime: runtime)
      let expired = try await runtime.callToolAsync(
        name: "mcp.tools.call", arguments: Self.arguments(tool: "replay"))
      #expect(Self.payload(expired).objectValue?["isError"] == .bool(true))
      #expect(throws: (any Error).self) {
        try runtime.requireHostInvocation(
          workspaceID: "fixture", origin: "provider", id: retainedID)
      }
      // The final replay also creates an observation barrier, even when it fails.
      try await Self.waitForResourceCount(0, runtime: runtime)
    } catch {
      await runtime.shutdown()
      throw error
    }
    await runtime.shutdown()
    #expect(runtime.ownedWork.snapshot.isEmpty)
  }

  private static func waitForResourceCount(_ count: Int, runtime: GatewayRuntime) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
      let snapshot = runtime.ownedWork.snapshot
      if snapshot.filter({ $0.kind == .mcpResource }).count == count,
        !snapshot.contains(where: { $0.kind == .mcpObservation })
      {
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Provider work did not settle to \(count) resources.")
  }

  @Test(arguments: [false, true], ["sync", "async", "detached"])
  func nativeProviderReceivesOnlyItsHostBoundInvocation(hostServices: Bool, mode: String)
    async throws
  {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("provider.py")
    try Self.provider.write(to: script, atomically: true, encoding: .utf8)
    let names = ["inspect", "deferred", "release", "replay"]
    let runtime = try await GatewayRuntime.make(
      configuration: .init(
        runtime: .init(caller: .localMCP, profileID: .localAdmin),
        profiles: [
          .init(
            id: .localAdmin, capabilities: ["mcp.tools.call", "mcp.requests.read"],
            workspaces: ["fixture"], allowedCallers: [.localMCP], mode: .readOnly)
        ],
        mcp: .init(servers: [
          .init(
            id: "provider", transport: .stdio, command: "/usr/bin/python3", args: [script.path],
            allowedTools: names, startupTimeoutMs: 5_000, requestTimeoutMs: 5_000,
            toolRisks: Dictionary(uniqueKeysWithValues: names.map { ($0, .readOnly) }),
            hostServices: hostServices)
        ])),
      database: try GatewayDatabase(path: root.appendingPathComponent("host.db").path),
      registeredWorkspaces: [.init(id: "fixture", displayName: "Fixture", rootPath: root.path)])
    do {
      let arguments = Self.arguments(tool: mode == "detached" ? "deferred" : "inspect")
      let result: JSONValue
      if mode == "sync" {
        result = try await BlockingOperationExecutor(label: "host-invocation-test").perform {
          try runtime.callTool(name: "mcp.tools.call", arguments: arguments)
        }
      } else if mode == "async" {
        result = try await runtime.callToolAsync(name: "mcp.tools.call", arguments: arguments)
      } else {
        var startedArguments = try #require(arguments.objectValue)
        startedArguments["wait_for_result"] = .bool(false)
        startedArguments["request_id"] = .string("detached")
        let started = try await runtime.callToolAsync(
          name: "mcp.tools.call", arguments: .object(startedArguments))
        #expect(Self.payload(started).objectValue?["state"] == .string("running"))
        startedArguments["request_id"] = .string("second")
        _ = try await runtime.callToolAsync(
          name: "mcp.tools.call", arguments: .object(startedArguments))
        #expect(runtime.ownedWork.snapshot.filter { $0.kind == .mcpRequest }.count == 2)
        _ = try await runtime.callToolAsync(
          name: "mcp.tools.call", arguments: Self.arguments(tool: "release"))
        let first = try await Self.readResult(runtime, id: "detached")
        let second = try await Self.readResult(runtime, id: "second")
        if hostServices {
          let firstID = first.objectValue?["structuredContent"]?.objectValue?["result"]?
            .objectValue?["invocation_id"]
          let secondID = second.objectValue?["structuredContent"]?.objectValue?["result"]?
            .objectValue?["invocation_id"]
          #expect(firstID != nil && secondID != nil && firstID != secondID)
        }
        result = .object([
          "structuredContent": .object([
            "result": first
          ])
        ])
      }
      let context = try #require(
        Self.payload(result).objectValue?["structuredContent"]?.objectValue)
      if hostServices {
        let bound = try #require(context["result"]?.objectValue)
        #expect(bound["registration_id"] == .string("provider"))
        #expect(bound["workspace_id"] == .string("fixture"))
        #expect(bound["tool"] == .string(mode == "detached" ? "deferred" : "inspect"))
        #expect(bound["capability_id"] == .string("mcp.tools.call"))
        #expect(bound["invocation_id"]?.stringValue.flatMap(UUID.init(uuidString:)) != nil)
        let replay = try await runtime.callToolAsync(
          name: "mcp.tools.call", arguments: Self.arguments(tool: "replay"))
        #expect(Self.payload(replay).objectValue?["isError"] == .bool(true))
      } else {
        #expect(context["host_metadata"] == .null)
      }
    } catch {
      await runtime.shutdown()
      throw error
    }
    await runtime.shutdown()
    #expect(runtime.ownedWork.snapshot.isEmpty)
  }

  private static func arguments(tool: String) -> JSONValue {
    .object([
      "workspace_id": .string("fixture"), "server": .string("provider"), "tool": .string(tool),
      "arguments": .object(["invocation_id": .string("caller-forged-id")]),
    ])
  }

  private static func readResult(_ runtime: GatewayRuntime, id: String) async throws -> JSONValue {
    let deadline = ContinuousClock.now + .seconds(2)
    var receipt: JSONValue = .null
    repeat {
      receipt = try await runtime.callToolAsync(
        name: "mcp.requests.read",
        arguments: .object([
          "workspace_id": .string("fixture"), "server": .string("provider"),
          "request_id": .string(id),
        ]))
      if Self.payload(receipt).objectValue?["state"] == .string("succeeded") { break }
      try await Task.sleep(for: .milliseconds(10))
    } while ContinuousClock.now < deadline
    return try #require(Self.payload(receipt).objectValue?["result"])
  }

  private static func payload(_ value: JSONValue) -> JSONValue {
    value.objectValue?["structuredContent"]?.objectValue?["result"] ?? .null
  }

  private static let provider = #"""
    import json, os, socket, sys, uuid
    channel = None
    sequence = 0
    pending = []
    previous = None
    work_enabled = len(sys.argv) > 1
    resources = []
    revision = 0
    instance = str(uuid.uuid4())
    work_uri = "computer-mcp://runtime/work/v1"
    def send(id, result):
        print(json.dumps({"jsonrpc": "2.0", "id": id, "result": result}), flush=True)
    def host(method, params):
        global sequence
        sequence += 1
        channel.write((json.dumps({"jsonrpc": "2.0", "id": sequence, "method": method, "params": params}) + "\n").encode())
        channel.flush()
        while True:
            response = json.loads(channel.readline())
            if response.get("id") == sequence:
                return response
    def describe(invocation):
        global channel
        if invocation is None:
            return {"content": [], "structuredContent": {"host_metadata": None}}
        if channel is None:
            connection = socket.socket(fileno=int(os.environ["COMPUTER_MCP_HOST_FD"]))
            connection.settimeout(5)
            channel = connection.makefile("rwb")
            host("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "generic-fixture", "version": "1"}})
            channel.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
            channel.flush()
        return host("tools/call", {"name": "host.invocations.describe", "arguments": {"invocation_id": invocation}})["result"]
    for line in sys.stdin:
        request = json.loads(line)
        if "id" not in request:
            continue
        method = request["method"]
        params = request.get("params", {})
        if method == "initialize":
            result = {"protocolVersion": "2025-11-25", "capabilities": {"tools": {}}, "serverInfo": {"name": "generic-fixture", "version": "1"}}
            if work_enabled:
                result["capabilities"]["resources"] = {}
        elif method == "tools/list":
            result = {"tools": [{"name": name, "inputSchema": {"type": "object"}} for name in ["inspect", "deferred", "release", "replay", "background", "derive", "finish"]]}
            if work_enabled:
                for tool in result["tools"]:
                    tool["_meta"] = {"io.github.computer-mcp/work": {"format_version": 1, "uri": work_uri}}
                    if tool["name"] == "background":
                        tool["_meta"]["io.github.computer-mcp/host-action"] = "diagnostics.snapshot"
        elif method == "resources/read":
            assert work_enabled and params["uri"] == work_uri
            result = {"contents": [{"uri": work_uri, "mimeType": "application/json", "text": json.dumps({"format_version": 1, "instance_id": instance, "revision": revision, "resources": resources})}]}
        elif method == "tools/call":
            invocation = params.get("_meta", {}).get("io.github.computer-mcp/host-invocation")
            if params["name"] == "deferred":
                pending.append((request["id"], invocation))
                continue
            if params["name"] == "background":
                previous = invocation
                resources.append({"kind": "fixture", "id": str(request["id"]), "acquired_by": params["_meta"]["io.github.computer-mcp/work-invocation"], "state": "active"})
                revision += 1
                result = {"content": []}
            elif params["name"] == "derive":
                resources = [{**resources[-1], "id": "derived"}]
                revision += 1
                result = {"content": []}
            elif params["name"] == "finish":
                resources.clear()
                revision += 1
                result = {"content": []}
            elif params["name"] == "release":
                for id, binding in pending:
                    send(id, describe(binding))
                    previous = binding
                pending.clear()
                result = {"content": []}
            elif params["name"] == "replay":
                result = describe(previous)
            else:
                result = describe(invocation)
                previous = invocation
        else:
            raise RuntimeError("Unexpected method")
        send(request["id"], result)
    """#
}
