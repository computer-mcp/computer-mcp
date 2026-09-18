import Darwin
import Foundation
import Testing

@testable import ComputerMCP

@Suite(.serialized)
struct GatewaySocketPrincipalLifecycleTests {
  @Test
  func disconnectedCallerCanObserveAndCancelItsOriginalExecutionAfterReconnect() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/cm-owner-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let directories = AppControlPlaneServiceDirectories(
      applicationSupport: root.appendingPathComponent("state"),
      logs: root.appendingPathComponent("logs"))
    try directories.prepare()
    let database = try GatewayDatabase(path: directories.database.path)
    let manifest = try AtomicManifestStore(manifestURL: directories.manifest, database: database)
    let secrets = try KeychainSecretStore(adapter: MemoryKeychainAdapter())
    let control = AppControlPlaneService(
      directories: directories, database: database, manifestStore: manifest, secretStore: secrets,
      openAITunnelSupervisor: OpenAITunnelSupervisor(secretStore: secrets),
      bundledPlugins: .init(packages: [], issues: []))
    let script = root.appendingPathComponent("fixture.py")
    try Data(Self.server.utf8).write(to: script)
    let configuration = GatewayConfiguration(
      runtime: .init(caller: .localMCP, profileID: .chatGPTOperate),
      profiles: [
        .init(
          id: .chatGPTOperate,
          capabilities: [
            "mcp.tools.call", "mcp.requests.list", "mcp.requests.read", "mcp.requests.cancel",
          ],
          workspaces: ["fixture"], allowedCallers: [.localMCP], mcpServers: ["fixture"],
          mode: .workspaceOperations, confirmationPolicy: .never)
      ],
      mcp: .init(servers: [
        .init(
          id: "fixture", transport: .stdio, command: "/usr/bin/python3",
          args: [script.path, root.path],
          exposure: .reexport, prefix: "fixture", allowAnyTool: true,
          startupTimeoutMs: 5000, requestTimeoutMs: 5000,
          toolRisks: ["hang": .readOnly, "finish": .readOnly])
      ]), workspaceDirectory: root)
    _ = try await control.activateManifest(configuration.exportedTOML())
    try database.saveWorkspace(.init(id: "fixture", displayName: "Fixture", rootPath: root.path))
    let service = AppGatewayService(
      controlPlane: control,
      socketConfiguration: .init(socketURL: root.appendingPathComponent("gateway.sock")))
    try await service.start(profile: .chatGPTOperate)
    do {
      let first = try await GatewayClientSession.connectSocket(
        socketURL: service.socketConfiguration.socketURL)
      let started = try await first.call(
        toolName: "mcp.tools.call",
        arguments: .object([
          "workspace_id": .string("fixture"), "server": .string("fixture"), "tool": .string("hang"),
          "arguments": .object([:]), "request_id": .string("owned-execution"),
          "wait_for_result": .bool(false),
        ]))
      #expect(started.result.objectValue?["isError"] != .bool(true))
      await first.disconnect()
      let pid = try #require(
        Int32(String(contentsOf: root.appendingPathComponent("pid"), encoding: .utf8)))
      #expect(kill(pid, 0) == 0)

      let reconnected = try await GatewayClientSession.connectSocket(
        socketURL: service.socketConfiguration.socketURL)
      let selector: JSONValue = .object([
        "workspace_id": .string("fixture"), "server": .string("fixture"),
        "request_id": .string("owned-execution"),
      ])
      let active = try await reconnected.call(toolName: "mcp.requests.list", arguments: selector)
      let firstTrace = started.result.objectValue?["structuredContent"]?.objectValue?[
        "gateway_execution"]?.objectValue?["socket_connection_id"]?.stringValue
      let nextTrace = active.result.objectValue?["structuredContent"]?.objectValue?[
        "gateway_execution"]?.objectValue?["socket_connection_id"]?.stringValue
      #expect(firstTrace != nil)
      #expect(nextTrace != nil)
      #expect(firstTrace != nextTrace)
      let requests = try #require(payload(active).objectValue?["requests"]?.arrayValue)
      #expect(requests.contains { $0.objectValue?["request_id"] == .string("owned-execution") })
      let cancelled = try await reconnected.call(
        toolName: "mcp.requests.cancel", arguments: selector)
      #expect(try payload(cancelled).objectValue?["cancellation_requested"] == .bool(true))
      #expect(kill(pid, 0) == 0)
      _ = try await reconnected.call(
        toolName: "mcp.tools.call",
        arguments: .object([
          "workspace_id": .string("fixture"), "server": .string("fixture"),
          "tool": .string("finish"),
          "arguments": .object([:]),
        ]))
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(5))
      var receipt = try await reconnected.call(toolName: "mcp.requests.read", arguments: selector)
      while try payload(receipt).objectValue?["state"] != .string("succeeded"), clock.now < deadline
      {
        try await Task.sleep(for: .milliseconds(10))
        receipt = try await reconnected.call(toolName: "mcp.requests.read", arguments: selector)
      }
      #expect(try payload(receipt).objectValue?["state"] == .string("succeeded"))
      #expect(
        try String(contentsOf: root.appendingPathComponent("dispatches"), encoding: .utf8) == "1")
      #expect(
        try String(contentsOf: root.appendingPathComponent("cancelled"), encoding: .utf8) == "1")
      await reconnected.disconnect()
      await service.stop()
      #expect(kill(pid, 0) == -1 && errno == ESRCH)
    } catch {
      await service.stop()
      throw error
    }
  }

  private func payload(_ report: GatewayCallReport) throws -> JSONValue {
    try #require(report.result.objectValue?["structuredContent"]?.objectValue?["result"])
  }

  private static let server = #"""
    import json, os, sys
    from pathlib import Path
    root = Path(sys.argv[1])
    (root / "pid").write_text(str(os.getpid()))
    pending = []
    for line in sys.stdin:
        message = json.loads(line)
        method = message.get("method")
        if method == "notifications/cancelled":
            (root / "cancelled").write_text("1")
            continue
        if "id" not in message:
            continue
        result = {}
        if method == "initialize":
            result = {"protocolVersion":"2025-11-25", "capabilities":{"tools":{}}, "serverInfo":{"name":"fixture", "version":"1"}}
        elif method == "tools/list":
            result = {"tools":[{"name": name, "inputSchema":{"type":"object"}} for name in ["hang", "finish"]]}
        elif method == "tools/call":
            if message["params"]["name"] == "hang":
                pending.append(message["id"])
                (root / "dispatches").write_text(str(len(pending)))
                continue
            for request_id in pending:
                print(json.dumps({"jsonrpc":"2.0", "id":request_id, "result":{"content":[{"type":"text", "text":"late completion"}]}}), flush=True)
            pending.clear()
            result = {"content":[]}
        print(json.dumps({"jsonrpc":"2.0", "id":message["id"], "result":result}), flush=True)
    """#
}
