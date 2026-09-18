import Darwin
import Foundation
import MCP
import Testing

@testable import ComputerMCP

@Suite(.timeLimit(.minutes(1)))
struct MCPUpstreamCancellationTests {
  @Test(arguments: ["reexport", "alias", "generic"], [false, true])
  func cancellationReachesOnlyItsNativeRequestAndKeepsTheSibling(
    route: String, overHTTP: Bool
  ) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("server.py")
    try Data(Self.script.utf8).write(to: script)
    var configuration = GatewayConfiguration(
      runtime: .init(caller: .localMCP, profileID: .localAdmin),
      profiles: [
        .init(
          id: .localAdmin, capabilities: ["*"], workspaces: ["fixture"],
          allowedCallers: [.localMCP], mode: .workspaceOperations, confirmationPolicy: .never)
      ],
      mcp: .init(servers: [
        .init(
          id: "native", transport: .stdio, command: "/usr/bin/python3",
          args: [script.path, root.path], exposure: .reexport, prefix: "native",
          allowAnyTool: true)
      ]), tools: [.init(name: "wait_alias", adapter: .mcp, source: "native", tool: "wait")],
      workspaceDirectory: root)
    let workspaces = [
      RegisteredWorkspace(id: "fixture", displayName: "Fixture", rootPath: root.path)
    ]
    let native = try await GatewayRuntime.make(
      configuration: configuration, registeredWorkspaces: workspaces)
    let origin =
      overHTTP
      ? GatewayHTTPRuntime(
        configuration: configuration, registry: native, host: "127.0.0.1", port: 0,
        publicBaseURL: nil) : nil
    let runtime: GatewayRuntime
    let downstreamWait: String
    do {
      if let origin {
        try await origin.startListening()
        let port = try #require(await origin.boundPort())
        configuration.mcp.servers = [
          .init(
            id: "native", transport: .streamableHTTP, url: "http://127.0.0.1:\(port)/mcp",
            exposure: .reexport, prefix: "", allowedTools: ["native.wait", "native.release"])
        ]
        downstreamWait = "native.wait"
        configuration.tools = [
          .init(name: "wait_alias", adapter: .mcp, source: "native", tool: downstreamWait)
        ]
        runtime = try await GatewayRuntime.make(
          configuration: configuration, registeredWorkspaces: workspaces)
      } else {
        downstreamWait = "wait"
        runtime = native
      }
    } catch {
      await origin?.stop()
      await native.shutdown()
      throw error
    }
    let server = await MCPRuntimeAdapter.makeGatewayServer(
      configuration: configuration, registry: runtime)
    let pair = await InMemoryTransport.createConnectedPair()
    let http =
      overHTTP
      ? GatewayHTTPRuntime(
        configuration: configuration, registry: runtime, host: "127.0.0.1", port: 0,
        publicBaseURL: nil) : nil
    let client = MCP.Client(name: "cancel-upstream", version: "1")
    do {
      if let http {
        try await http.startListening()
        let port = try #require(await http.boundPort())
        _ = try await client.connect(
          transport: MCPHTTPClientTransport(
            endpoint: URL(string: "http://127.0.0.1:\(port)/mcp")!, streaming: true))
      } else {
        try await server.start(transport: pair.server)
        _ = try await client.connect(transport: pair.client)
      }
      let name =
        route == "generic" ? "mcp.tools.call" : route == "alias" ? "wait_alias" : "native.wait"
      let firstArguments: [String: Value] =
        route == "generic"
        ? [
          "server": .string("native"), "tool": .string(downstreamWait),
          "arguments": .object(["label": .string("first")]),
          "request_id": .string("caller-selected"),
        ]
        : ["label": .string("first")]
      let first: RequestContext<CallTool.Result> = try await client.callTool(
        name: name, arguments: firstArguments)
      let sibling: RequestContext<CallTool.Result> = try await client.callTool(
        name: "native.wait", arguments: ["label": .string("sibling")])
      try await wait(root: root, for: "started:sibling")
      try await wait(root: root, for: "started:first")
      try await client.cancelRequest(first.requestID, reason: "Cancel the first fixture call.")
      await #expect(throws: CancellationError.self) { _ = try await first.value }
      try await wait(root: root, for: "cancelled:first")
      let afterCancellation = try events(root)
      #expect(!afterCancellation.contains("cancelled:sibling"))
      let release: RequestContext<CallTool.Result> = try await client.callTool(
        name: "native.release", arguments: [:])
      #expect(try await release.value.isError != true)
      #expect(try await sibling.value.isError != true)
      let receipt = try events(root)
      #expect(receipt.filter { $0 == "started:first" }.count == 1)
      #expect(receipt.filter { $0 == "cancelled:first" }.count == 1)
      #expect(receipt.contains("completed:sibling"))
      #expect(!receipt.contains("completed:first"))
      await client.disconnect()
      await server.stop()
      await http?.stop()
      await runtime.shutdown()
      await origin?.stop()
      await native.shutdown()
      let pid = try #require(
        Int32(String(contentsOf: root.appendingPathComponent("pid"), encoding: .utf8)))
      #expect(kill(pid, 0) == -1 && errno == ESRCH)
    } catch {
      await client.disconnect()
      await server.stop()
      await http?.stop()
      await runtime.shutdown()
      await origin?.stop()
      await native.shutdown()
      throw error
    }
  }

  private func events(_ root: URL) throws -> [String] {
    let file = root.appendingPathComponent("events")
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
  }

  private func wait(root: URL, for event: String) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while ContinuousClock.now < deadline {
      if try events(root).contains(event) { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw CancellationFixtureError.missing(event)
  }

  private enum CancellationFixtureError: Error { case missing(String) }

  private static let script = #"""
    import json, os, pathlib, sys
    root = pathlib.Path(sys.argv[1])
    (root / "pid").write_text(str(os.getpid()))
    waiting = {}
    def record(event):
        with (root / "events").open("a") as file:
            file.write(event + "\n")
    def reply(identifier, result):
        print(json.dumps({"jsonrpc":"2.0", "id":identifier, "result":result}), flush=True)
    for line in sys.stdin:
        request = json.loads(line)
        method = request.get("method")
        if method == "notifications/cancelled":
            label = waiting.pop(request["params"]["requestId"], None)
            if label is not None: record("cancelled:" + label)
        elif method == "initialize":
            reply(request["id"], {"protocolVersion":request["params"]["protocolVersion"], "capabilities":{"tools":{}}, "serverInfo":{"name":"cancellation-fixture", "version":"1"}})
        elif method == "tools/list":
            reply(request["id"], {"tools":[{"name":name, "inputSchema":{"type":"object"}} for name in ["wait", "release"]]})
        elif method == "tools/call":
            if request["params"]["name"] == "wait":
                label = request["params"]["arguments"]["label"]
                waiting[request["id"]] = label
                record("started:" + label)
            else:
                for identifier, label in waiting.items():
                    record("completed:" + label)
                    reply(identifier, {"content":[{"type":"text", "text":label}], "isError":False})
                waiting.clear()
                reply(request["id"], {"content":[], "isError":False})
    """#
}
