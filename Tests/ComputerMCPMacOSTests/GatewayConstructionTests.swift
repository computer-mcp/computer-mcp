import ComputerMCPDownstream
import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPTestSupport
import Darwin
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPlatform

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.nativeIntegration, .timeLimit(.minutes(1)))
struct GatewayConstructionTests {
  @Test(arguments: ["catalog", "cli-tree", "duplicate-project"])
  func failedConstructionJoinsCachedOwnersBeforeRetry(stage: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var configuration = GatewayConfiguration(
      runtime: .init(caller: .localMCP, profileID: .localAdmin),
      mcp: .init(servers: [
        .init(
          id: "fixture", transport: .stdio, command: "/unused", exposure: .reexport,
          prefix: "", allowAnyTool: true)
      ]), projectDirectory: root)
    let first = RegisteredProject(id: "first", displayName: "First", rootPath: root.path)
    var projects = [first]
    if stage == "duplicate-project" { projects.append(first) }
    if stage == "cli-tree" {
      configuration.cli.commands = [
        .init(
          id: "tree", executable: "/bin/cat", allowAnyArgs: false,
          tree: .init(kind: .file, path: root.appendingPathComponent("missing-tree.json").path))
      ]
    }
    var platform = fixtureHostedPlatform()
    platform.permissionPolicyReader = TestManagedPolicyReader()
    let context = ExecutionContext(
      caller: .localMCP, profileID: .localAdmin, trustedPrincipalID: "construction-fixture")
    for _ in 0..<2 {
      let gate = ConstructionCleanupGate()
      await gate.release()
      let client = ConstructionMCPClient(
        gate: gate, cachedName: stage == "catalog" ? "project.list" : "inspect")
      do {
        let runtime = try await GatewayRuntime.make(
          configuration: configuration, context: context, registeredProjects: projects,
          platform: platform, mcpClient: client)
        await runtime.shutdown()
        Issue.record("Expected failure at \(stage)")
      } catch {
        if stage == "catalog" {
          #expect(error as? GatewayProviderRouterError == .duplicateTool("project.list"))
        } else if stage == "duplicate-project" {
          #expect(error as? GatewayRuntimeError == .duplicateProjectID("first"))
        }
      }
      #expect(await gate.count == 1)
      #expect(client.discoveryCount == 0)
    }
    configuration.cli.commands = []
    let gate = ConstructionCleanupGate()
    await gate.release()
    let client = ConstructionMCPClient(gate: gate, cachedName: "inspect")
    let runtime = try await GatewayRuntime.make(
      configuration: configuration, context: context, registeredProjects: [first],
      platform: platform, mcpClient: client)
    #expect(try runtime.listTools(context: .empty).contains { $0.name == "inspect" })
    await runtime.shutdown()
    #expect(await gate.count == 1)
    #expect(client.discoveryCount == 0)
    #expect(try pids(root).isEmpty)
  }

  @Test
  func admittedNativeCatalogJoinsItsProcessBeforeRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
    let script = root.appendingPathComponent("server.py")
    try Data(Self.script.utf8).write(to: script)
    let launcher = fixtureProtocolExecutionLauncher(
      root: root, scripts: [Self.script], arguments: [[root.path, "inspect"]])
    var platform = MacOSPlatform.services(launcher: launcher)
    platform.permissionPolicyReader = TestManagedPolicyReader()
    let first = RegisteredProject(id: "first", displayName: "First", rootPath: project.path)
    let grant = ProfileGrant(
      id: .localAdmin,
      permissions: fixturePermissions([
        .project("first"): .granted(.write), .mcpServer("fixture"): .granted(.all),
      ]), fullAccess: true, allowedCallers: [.localMCP])
    let configuration = GatewayConfiguration(
      runtime: .init(caller: .localMCP, profileID: grant.id), profiles: [.init(grant: grant)],
      mcp: .init(servers: [
        .init(
          id: "fixture", transport: .stdio, command: "/usr/bin/python3",
          args: [script.path, root.path, "inspect"], exposure: .reexport, prefix: "",
          allowAnyTool: true, startupTimeoutMs: 5000, requestTimeoutMs: 5000,
          toolRisks: ["inspect": .readOnly])
      ]), projectDirectory: project)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("host"), withIntermediateDirectories: false)
    let database = try fixturePermissionDatabase(
      path: root.appendingPathComponent("host/state.sqlite").path)
    try database.saveProject(first)
    try database.saveProfile(grant)
    for attempt in 0..<3 {
      let context = try fixtureConsentedContext(
        database: database, grant: grant, caller: .localMCP,
        principalID: "construction-native-fixture", platform: platform)
      let runtime = try await GatewayRuntime.make(
        configuration: configuration, context: context, database: database,
        registeredProjects: [first], platform: platform)
      let permissionRuntime = try database.permissionRuntime(platform: platform)
      try fixtureApproveLocalProvider(
        configuration.mcp.servers[0], database: database, runtime: permissionRuntime,
        permissions: .newPrincipal, fullAccess: false)
      let home = URL(
        fileURLWithPath: try database.prepareProviderContainer(.localServer("fixture")).sandbox.home
          .value)
      do {
        #expect(try pids(home).count == attempt)
        let discovered = try await runtime.callToolAsync(
          name: "mcp.tools.list",
          arguments: .object([
            "project_id": .string(first.id), "server": .string("fixture"),
          ]), context: .empty)
        #expect(discovered.objectValue?["isError"] != .bool(true))
        try await runtime.refreshTools(context: .empty)
        #expect(try runtime.listTools(context: .empty).contains { $0.name == "inspect" })
        await runtime.shutdown()
        try expectProcessesExited(home)
        #expect(try pids(home).count == attempt + 1)
        #expect(
          !FileManager.default.fileExists(atPath: home.appendingPathComponent("overlap").path))
      } catch {
        await runtime.shutdown()
        throw error
      }
    }
  }

  @Test(arguments: [false, true])
  func concurrentShutdownCallersJoinTheSameCleanup(routerOnly: Bool) async throws {
    let gate = ConstructionCleanupGate()
    let client = ConstructionMCPClient(gate: gate)
    let configuration = GatewayConfiguration(
      projectDirectory: FileManager.default.temporaryDirectory)
    let shutdown: @Sendable () async -> Void
    if routerOnly {
      let router = try GatewayProviderRouter(source: { [] }, shutdownSource: { await gate.close() })
      shutdown = { await router.shutdown() }
    } else {
      let runtime = try await GatewayRuntime.make(
        configuration: configuration,
        registeredProjects: [
          RegisteredProject(
            id: "fixture", displayName: "Fixture", rootPath: configuration.projectDirectory.path)
        ],
        platform: metadataPlatform(), mcpClient: client)
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
  func cancellationDuringCachedCatalogPreparationJoinsCleanupAndDoesNotPublishRuntime() async throws
  {
    let gate = ConstructionCleanupGate()
    let client = ConstructionMCPClient(gate: gate, pauseCatalog: true)
    let catalog = client.catalogRequested.stream()
    let cleanup = gate.entered.stream()
    let pending = Task {
      try await GatewayRuntime.make(
        configuration: GatewayConfiguration(
          mcp: .init(servers: [
            .init(
              id: "fixture", transport: .stdio, command: "/unused", exposure: .reexport,
              prefix: "fixture", allowAnyTool: true)
          ])),
        registeredProjects: [
          RegisteredProject(
            id: "fixture", displayName: "Fixture",
            rootPath: FileManager.default.temporaryDirectory.path)
        ],
        platform: metadataPlatform(), mcpClient: client)
    }
    var snapshots = catalog.makeAsyncIterator()
    _ = await snapshots.next()
    pending.cancel()
    client.releaseCatalog.signal()
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
    #expect(client.discoveryCount == 0)
  }

  private func metadataPlatform() -> PlatformServices {
    var platform = fixtureHostedPlatform()
    platform.permissionPolicyReader = TestManagedPolicyReader()
    return platform
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
    root = pathlib.Path(os.environ["HOME"])
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
            result = {"tools":[{"name":sys.argv[2], "inputSchema":{"type":"object"}, "annotations":{"readOnlyHint":True}}]}
        else:
            continue
        print(json.dumps({"jsonrpc":"2.0", "id":request["id"], "result":result}), flush=True)
    while True:
        time.sleep(1)
    """#
}

private actor ConstructionCleanupGate {
  let entered = GatewayToolChangeBroadcaster()
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private(set) var count = 0
  private(set) var released = false
  func close() async {
    if count == 0 {
      count = 1
      entered.send()
    }
    if !released { await withCheckedContinuation { waiters.append($0) } }
  }
  func release() {
    released = true
    for waiter in waiters { waiter.resume() }
    waiters = []
  }
}

private final class ConstructionMCPClient: DownstreamMCPClient, @unchecked Sendable {
  private let lock = NSLock()
  private var paused = false
  private var discoveries = 0
  var discoveryCount: Int { lock.withLock { discoveries } }
  func cachedTools(server: MCPServerConfig, context: InvocationContext) -> [MCPTool]? {
    let shouldPause = lock.withLock {
      guard pauseCatalog && !paused else { return false }
      paused = true
      return true
    }
    if shouldPause {
      catalogRequested.send()
      _ = releaseCatalog.wait(timeout: .now() + .seconds(5))
    }
    return cachedName.map {
      [
        MCPTool(
          name: $0, description: "Cached construction fixture",
          inputSchema: .object(["type": .string("object")]),
          annotations: .init(readOnlyHint: true))
      ]
    } ?? []
  }

  let gate: ConstructionCleanupGate
  let pauseCatalog: Bool
  let cachedName: String?
  let catalogRequested = GatewayToolChangeBroadcaster()
  let releaseCatalog = DispatchSemaphore(value: 0)
  init(gate: ConstructionCleanupGate, pauseCatalog: Bool = false, cachedName: String? = nil) {
    self.gate = gate
    self.pauseCatalog = pauseCatalog
    self.cachedName = cachedName
  }
  // Project and unscoped facades share one downstream owner.
  func makeScopedClient(
    workingDirectory: URL, environment: [String: String], hostContext: (any MCPHostEnvironment)?
  ) -> any DownstreamMCPClient { self }
  func listTools(server: MCPServerConfig, context: InvocationContext) throws -> [MCPTool] {
    lock.withLock { discoveries += 1 }
    Issue.record("Construction must read cached metadata without downstream discovery")
    return []
  }
  func callTool(
    server: MCPServerConfig, name: String, arguments: JSONValue, context: InvocationContext
  ) throws -> JSONValue {
    .null
  }
  func shutdown() async { await gate.close() }
  func listResources(server: MCPServerConfig, cursor: String?, context: InvocationContext) throws
    -> JSONValue
  { .null }
  func listResourceTemplates(server: MCPServerConfig, cursor: String?, context: InvocationContext)
    throws -> JSONValue
  { .null }
  func readResource(server: MCPServerConfig, uri: String, context: InvocationContext) throws
    -> JSONValue
  { .null }
  func listPrompts(server: MCPServerConfig, cursor: String?, context: InvocationContext) throws
    -> JSONValue
  { .null }
  func getPrompt(
    server: MCPServerConfig, name: String, arguments: [String: String]?, context: InvocationContext
  ) throws
    -> JSONValue
  { .null }
}
