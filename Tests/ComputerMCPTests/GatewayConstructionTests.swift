import Darwin
import Foundation
import Testing

@testable import ComputerMCP

@Suite(.timeLimit(.minutes(1)))
struct GatewayConstructionTests {
  @Test(arguments: ["catalog", "cli-tree", "duplicate-workspace", "bookmark"])
  func failedConstructionJoinsProcessesBeforeRetry(stage: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("server.py")
    try Data(Self.script.utf8).write(to: script)
    var configuration = GatewayConfiguration(
      runtime: .init(caller: .localMCP, profileID: .localAdmin),
      mcp: .init(servers: [
        .init(
          id: "fixture", transport: .stdio, command: "/usr/bin/python3",
          args: [script.path, root.path, stage == "catalog" ? "workspace.list" : "inspect"],
          exposure: .reexport, prefix: "", allowAnyTool: true,
          startupTimeoutMs: 5000, requestTimeoutMs: 5000)
      ]), workspaceDirectory: root)
    let first = RegisteredWorkspace(id: "first", displayName: "First", rootPath: root.path)
    var workspaces = [first]
    if stage == "duplicate-workspace" { workspaces.append(first) }
    if stage == "bookmark" {
      workspaces.append(
        RegisteredWorkspace(
          id: "missing", displayName: "Missing",
          rootPath: root.appendingPathComponent("missing").path))
    }
    if stage == "cli-tree" {
      configuration.cli.commands = [
        .init(
          id: "tree", executable: "/bin/cat", allowAnyArgs: false,
          tree: .init(kind: .file, path: root.appendingPathComponent("missing-tree.json").path))
      ]
    }
    for _ in 0..<2 {
      do {
        let runtime = try await GatewayRuntime.make(
          configuration: configuration, registeredWorkspaces: workspaces)
        await runtime.shutdown()
        Issue.record("Expected failure at \(stage)")
      } catch {
        if stage == "catalog" {
          #expect(error as? GatewayProviderRouterError == .duplicateTool("workspace.list"))
        } else if stage == "duplicate-workspace" {
          #expect(error as? GatewayRuntimeError == .duplicateWorkspaceID("first"))
        } else if stage == "bookmark" {
          #expect(error is WorkspaceBookmarkError)
        }
      }
      try expectProcessesExited(root)
    }
    configuration.cli.commands = []
    configuration.mcp.servers[0].args = [script.path, root.path, "inspect"]
    let runtime = try await GatewayRuntime.make(
      configuration: configuration, registeredWorkspaces: [first])
    #expect(try runtime.listTools().contains { $0.name == "inspect" })
    await runtime.shutdown()
    try expectProcessesExited(root)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("overlap").path))
    #expect(try pids(root).count == 3)
  }

  @Test(arguments: [false, true])
  func concurrentShutdownCallersJoinTheSameCleanup(routerOnly: Bool) async throws {
    let gate = ConstructionCleanupGate()
    let client = ConstructionMCPClient(gate: gate)
    let configuration = GatewayConfiguration(
      workspaceDirectory: FileManager.default.temporaryDirectory)
    let shutdown: @Sendable () async -> Void
    if routerOnly {
      let router = try GatewayProviderRouter(source: { [] }, shutdownSource: { await gate.close() })
      shutdown = { await router.shutdown() }
    } else {
      let runtime = try await GatewayRuntime.make(
        configuration: configuration,
        registeredWorkspaces: [
          RegisteredWorkspace(
            id: "fixture", displayName: "Fixture", rootPath: configuration.workspaceDirectory.path)
        ],
        mcpClient: client)
      shutdown = { await runtime.shutdown() }
    }
    let entered = gate.entered.stream()
    let first = Task { await shutdown() }
    var events = entered.makeAsyncIterator()
    _ = await events.next()
    let second = Task {
      await shutdown()
      #expect(await gate.released)
    }
    // Cleanup is deliberately held; every completed caller must observe its release.
    try? await Task.sleep(for: .milliseconds(30))
    await gate.release()
    await first.value
    await second.value
    await shutdown()
    #expect(await gate.count == 1)
  }

  @Test
  func cancellationDuringDiscoveryWaitsForCleanupAndDoesNotPublishRuntime() async throws {
    let gate = ConstructionCleanupGate()
    let client = ConstructionMCPClient(gate: gate, pauseDiscovery: true)
    let discovery = client.discovery.stream()
    let cleanup = gate.entered.stream()
    let pending = Task {
      try await GatewayRuntime.make(
        configuration: GatewayConfiguration(
          mcp: .init(servers: [
            .init(
              id: "fixture", transport: .stdio, command: "/unused", exposure: .reexport,
              prefix: "fixture", allowAnyTool: true)
          ])),
        registeredWorkspaces: [
          RegisteredWorkspace(
            id: "fixture", displayName: "Fixture",
            rootPath: FileManager.default.temporaryDirectory.path)
        ],
        mcpClient: client)
    }
    var discoveries = discovery.makeAsyncIterator()
    _ = await discoveries.next()
    pending.cancel()
    client.releaseDiscovery.signal()
    var cleanups = cleanup.makeAsyncIterator()
    _ = await cleanups.next()
    await gate.release()
    switch await pending.result {
    case .success(let runtime):
      await runtime.shutdown()
      Issue.record("A cancelled construction must not publish a runtime")
    case .failure(let error): #expect(error is CancellationError)
    }
    #expect(await gate.count == 1)
  }

  private func pids(_ root: URL) throws -> [Int32] {
    try FileManager.default.contentsOfDirectory(atPath: root.path)
      .filter { $0.hasPrefix("pid-") }.compactMap { Int32($0.dropFirst(4)) }
  }

  private func expectProcessesExited(_ root: URL) throws {
    let processes = try pids(root)
    #expect(!processes.isEmpty)
    for pid in processes { #expect(kill(pid, 0) == -1 && errno == ESRCH) }
  }

  private static let script = #"""
    import json, os, pathlib, signal, sys, time
    root = pathlib.Path(sys.argv[1])
    for path in root.glob("pid-*"):
        try:
            os.kill(int(path.name[4:]), 0)
            (root / "overlap").touch()
        except ProcessLookupError:
            pass
    (root / ("pid-" + str(os.getpid()))).touch()
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    for line in sys.stdin:
        request = json.loads(line)
        if request.get("method") == "initialize":
            result = {"protocolVersion":"2025-11-25", "capabilities":{"tools":{}}, "serverInfo":{"name":"construction", "version":"1"}}
        elif request.get("method") == "tools/list":
            result = {"tools":[{"name":sys.argv[2], "inputSchema":{"type":"object"}}]}
        else:
            continue
        print(json.dumps({"jsonrpc":"2.0", "id":request["id"], "result":result}), flush=True)
    while True:
        time.sleep(1)
    """#
}

private actor ConstructionCleanupGate {
  let entered = GatewayToolChangeBroadcaster()
  private var waiter: CheckedContinuation<Void, Never>?
  private(set) var count = 0
  private(set) var released = false
  func close() async {
    count += 1
    entered.send()
    if !released { await withCheckedContinuation { waiter = $0 } }
  }
  func release() {
    released = true
    waiter?.resume()
    waiter = nil
  }
}

private final class ConstructionMCPClient: DownstreamMCPClient, Sendable {
  let gate: ConstructionCleanupGate
  let pauseDiscovery: Bool
  let discovery = GatewayToolChangeBroadcaster()
  let releaseDiscovery = DispatchSemaphore(value: 0)
  init(gate: ConstructionCleanupGate, pauseDiscovery: Bool = false) {
    self.gate = gate
    self.pauseDiscovery = pauseDiscovery
  }
  func makeScopedClient(
    workingDirectory: URL, environment: [String: String], hostContext: MCPHostContext?
  ) -> any DownstreamMCPClient { self }
  func listTools(server: MCPServerConfig) throws -> [MCPTool] {
    if pauseDiscovery {
      discovery.send()
      _ = releaseDiscovery.wait(timeout: .now() + .seconds(5))
    }
    return []
  }
  func callTool(server: MCPServerConfig, name: String, arguments: JSONValue) throws -> JSONValue {
    .null
  }
  func shutdown() async { await gate.close() }
  func listResources(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func listResourceTemplates(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func readResource(server: MCPServerConfig, uri: String) throws -> JSONValue { .null }
  func listPrompts(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func getPrompt(server: MCPServerConfig, name: String, arguments: [String: String]?) throws
    -> JSONValue
  { .null }
}
