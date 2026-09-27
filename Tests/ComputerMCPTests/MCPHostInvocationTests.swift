import Foundation
import Testing

@testable import ComputerMCP

@Suite(.serialized, .timeLimit(.minutes(1)))
struct MCPHostInvocationTests {
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
    import json, os, socket, sys
    channel = None
    sequence = 0
    pending = []
    previous = None
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
        elif method == "tools/list":
            result = {"tools": [{"name": name, "inputSchema": {"type": "object"}} for name in ["inspect", "deferred", "release", "replay"]]}
        elif method == "tools/call":
            invocation = params.get("_meta", {}).get("io.github.computer-mcp/host-invocation")
            if params["name"] == "deferred":
                pending.append((request["id"], invocation))
                continue
            if params["name"] == "release":
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
