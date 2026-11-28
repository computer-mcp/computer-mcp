import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPTestSupport
import ComputerMCPTransport
import Darwin
import Foundation
import MCP
import NIOConcurrencyHelpers
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPGateway

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.nativeIntegration, .timeLimit(.minutes(1)))
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
    let nativeServer = MCPServerConfig(
      id: "native", transport: .stdio, command: "/usr/bin/python3",
      args: [script.path, root.path], exposure: .reexport, prefix: "native",
      allowAnyTool: true)
    let authority = try ProxyExecutionFixture(
      server: nativeServer, root: root,
      additionalPermissions: [.localNetwork: .granted(.access)])
    defer { try? authority.close() }
    let providerRoot = try authority.providerMarker(root.appendingPathComponent("pid"))
      .deletingLastPathComponent()
    let profile = try #require(try authority.database.profiles().first { $0.id == .chatGPTOperate })
    let session = try #require(authority.callerContext.controlSession as? GatewayControlSession)
    var configuration = GatewayConfiguration(
      runtime: .init(caller: .localMCP, profileID: profile.id),
      profiles: [.init(grant: profile)], mcp: .init(servers: [nativeServer]),
      tools: [.init(name: "wait_alias", adapter: .mcp, source: "native", tool: "wait")],
      projectDirectory: root)
    let projects = try authority.database.projects()
    let native = try await GatewayRuntime.make(
      configuration: configuration, context: authority.callerContext,
      database: authority.database, registeredProjects: projects,
      platform: MacOSPlatform.services(launcher: authority.launcher))
    _ = try native.makeControlSession()
    try fixtureApproveLocalProvider(
      nativeServer, database: authority.database, runtime: native.permissionRuntime,
      permissions: fixturePermissions([.project("fixture"): .granted(.write)]), fullAccess: true)
    do { try await discover(native) } catch {
      await native.shutdown()
      throw error
    }
    let nativeServing = GatewayControlSessionServing(base: native, session: session)
    let origin =
      overHTTP
      ? GatewayHTTPRuntime(
        configuration: configuration, registry: nativeServing, host: "127.0.0.1", port: 0,
        publicBaseURL: nil) : nil
    let runtime: GatewayRuntime
    let downstreamWait: String
    var forwardingAuthority: ProxyExecutionFixture?
    defer { try? forwardingAuthority?.close() }
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
        let forwardingRoot = root.appendingPathComponent("forwarding")
        try FileManager.default.createDirectory(
          at: forwardingRoot, withIntermediateDirectories: false)
        let forwarding = try ProxyExecutionFixture(
          server: #require(configuration.mcp.servers.first), root: forwardingRoot,
          additionalPermissions: [.localNetwork: .granted(.access)])
        forwardingAuthority = forwarding
        runtime = try await GatewayRuntime.make(
          configuration: configuration, context: forwarding.callerContext,
          database: forwarding.database, registeredProjects: forwarding.database.projects(),
          platform: MacOSPlatform.services(launcher: forwarding.launcher))
        try await discover(runtime)
      } else {
        downstreamWait = "wait"
        runtime = native
      }
    } catch {
      await origin?.stop()
      await native.shutdown()
      throw error
    }
    let servingSession = try #require(
      (forwardingAuthority?.callerContext ?? authority.callerContext).controlSession
        as? GatewayControlSession)
    let serving = GatewayControlSessionServing(base: runtime, session: servingSession)
    let server = await MCPRuntimeAdapter.makeGatewayServer(
      configuration: configuration, registry: serving)
    let pair = await InMemoryTransport.createConnectedPair()
    let http =
      overHTTP
      ? GatewayHTTPRuntime(
        configuration: configuration, registry: serving, host: "127.0.0.1", port: 0,
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
      let outcomes = NIOLockedValueBox<[String: String]>([:])
      observe(first, label: "first", outcomes: outcomes)
      observe(sibling, label: "sibling", outcomes: outcomes)
      let starts = ["started:first", "started:sibling"]
      let observed = try await wait(root: providerRoot, for: starts, timeout: .seconds(10))
      let replies = outcomes.withLockedValue { $0 }
      try #require(
        starts.allSatisfy(observed.contains),
        "Native readiness: markers=\(observed), first=\(replies["first"] ?? "pending"), sibling=\(replies["sibling"] ?? "pending")"
      )
      try await client.cancelRequest(first.requestID, reason: "Cancel the first fixture call.")
      await #expect(throws: CancellationError.self) { _ = try await first.value }
      let afterCancellation = try await wait(
        root: providerRoot, for: ["cancelled:first"], timeout: .seconds(4))
      try #require(
        afterCancellation.contains("cancelled:first"), "Native cancellation: \(afterCancellation)")
      try #require(
        !afterCancellation.contains("cancelled:sibling"),
        "Unexpected sibling cancellation: \(afterCancellation)"
      )
      let release: RequestContext<CallTool.Result> = try await client.callTool(
        name: "native.release", arguments: [:])
      let released = try await release.value
      try #require(released.isError != true, "Sibling release returned a tool error")
      #expect(try await sibling.value.isError != true)
      let receipt = try events(providerRoot)
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
        Int32(String(contentsOf: providerRoot.appendingPathComponent("pid"), encoding: .utf8)))
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

  private func discover(_ runtime: GatewayRuntime) async throws {
    let discovered = try await runtime.callToolAsync(
      name: "mcp.tools.list", arguments: .object(["server": .string("native")]), context: .empty)
    try #require(discovered.objectValue?["isError"] == .bool(false), "\(discovered)")
    try await runtime.refreshTools(context: .empty)
    let tools = try await runtime.listToolsAsync(context: .empty)
    try #require(tools.contains { $0.name == "native.wait" })
  }

  private func events(_ root: URL) throws -> [String] {
    let file = root.appendingPathComponent("events")
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
  }

  private func wait(root: URL, for expected: [String], timeout: Duration) async throws -> [String] {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    var observed = try events(root)
    while !expected.allSatisfy(observed.contains), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
      observed = try events(root)
    }
    return observed
  }

  private func observe(
    _ request: RequestContext<CallTool.Result>, label: String,
    outcomes: NIOLockedValueBox<[String: String]>
  ) {
    Task {
      let outcome: String
      do {
        outcome = try await request.value.isError == true ? "tool error" : "success"
      } catch is CancellationError {
        outcome = "cancelled"
      } catch {
        outcome = "request failed"
      }
      outcomes.withLockedValue { $0[label] = outcome }
    }
  }

  private static let script = #"""
    import json, os, pathlib, sys
    root = pathlib.Path(os.environ["HOME"])
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
