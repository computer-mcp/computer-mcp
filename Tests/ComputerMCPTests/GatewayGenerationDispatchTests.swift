import Darwin
import Foundation
import Testing

@testable import ComputerMCP

@Suite(.serialized, .timeLimit(.minutes(1)))
struct GatewayGenerationDispatchTests {
  @Test
  func connectedClientUsesNewConfigurationWhileOldNativeWorkKeepsItsOwner() async throws {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect()
    do {
      let started = try await client.call(
        toolName: "fixture.start", arguments: .object(["handle": .string("old")]))
      let oldPID = try pid(started)
      try await fixture.activate(version: 2)
      let fresh = try await client.call(toolName: "fixture.identity")
      let currentPID = try pid(fresh)
      #expect(value(fresh, "version") == .integer(2))
      #expect(currentPID != oldPID && alive(oldPID))
      #expect(try await client.listTools().contains { $0.name == "fixture.generation_2" })
      let inspected = try await client.call(
        toolName: "fixture.inspect", arguments: .object(["handle": .string("old")]))
      #expect(try pid(inspected) == oldPID)
      #expect(value(inspected, "version") == .integer(1))

      var grant = try #require(try fixture.database.profiles().first { $0.id == .chatGPTOperate })
      let capabilities = grant.capabilityIDs
      let servers = grant.mcpServerIDs
      grant.capabilityIDs = []
      grant.mcpServerIDs = []
      try fixture.database.saveProfile(grant, expectedRevision: grant.authorizationRevision)
      let denied = try await client.call(
        toolName: "fixture.inspect", arguments: .object(["handle": .string("old")]))
      #expect(denied.result.objectValue?["isError"] == .bool(true))
      #expect(alive(oldPID))
      grant = try #require(try fixture.database.profiles().first { $0.id == .chatGPTOperate })
      grant.capabilityIDs = capabilities
      grant.mcpServerIDs = servers
      try fixture.database.saveProfile(grant, expectedRevision: grant.authorizationRevision)
      let finished = try await client.call(
        toolName: "fixture.finish", arguments: .object(["handle": .string("old")]))
      #expect(try pid(finished) == oldPID)
      try await wait { !alive(oldPID) }
      #expect(alive(currentPID))

      var previous = currentPID
      for version in 3...8 {
        try await fixture.activate(version: version)
        let next = try await client.call(toolName: "fixture.identity")
        #expect(value(next, "version") == .integer(Int64(version)))
        let obsolete = previous
        previous = try pid(next)
        #expect(previous != obsolete)
        try await wait { !alive(obsolete) }
      }
      let pids = try fixture.pids()
      #expect(pids.count >= 8)
      #expect(pids.filter(alive) == [previous])
      await client.disconnect()
      await fixture.service.stop()
      #expect(pids.allSatisfy { !alive($0) })
    } catch {
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test
  func duplicateNativeHandlesFailWithoutDispatchAndRoutingFailureIsAudited() async throws {
    let fixture = try GenerationFixture()
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect()
    do {
      _ = try await client.call(
        toolName: "fixture.start", arguments: .object(["handle": .string("same")]))
      try await fixture.activate(version: 2)
      _ = try await client.call(
        toolName: "fixture.start", arguments: .object(["handle": .string("same")]))
      let before = try fixture.calls()
      var rejected = try await client.call(
        toolName: "fixture.inspect", arguments: .object(["handle": .string("same")]))
      let deadline = ContinuousClock.now + .seconds(5)
      while String(describing: rejected.result).contains("mcp.continuation_pending"),
        ContinuousClock.now < deadline
      {
        try await Task.sleep(for: .milliseconds(10))
        rejected = try await client.call(
          toolName: "fixture.inspect", arguments: .object(["handle": .string("same")]))
      }
      #expect(rejected.result.objectValue?["isError"] == .bool(true))
      #expect(String(describing: rejected.result).contains("mcp.continuation_ambiguous"))
      #expect(try fixture.calls() == before)
      let request = try #require(
        rejected.result.objectValue?["structuredContent"]?.objectValue?["gateway_execution"]?
          .objectValue?["request_id"]?.stringValue)
      let audit = try #require(try fixture.database.auditEvent(requestID: request))
      #expect(audit.capabilityID == "fixture.inspect")
      #expect(audit.mcpRequestID == rejected.requestID)
      await client.disconnect()
      await fixture.service.stop()
    } catch {
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test
  func providerWithoutWorkReportingIsRetainedUntilExplicitShutdown() async throws {
    let fixture = try GenerationFixture(reportWork: false)
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    try await fixture.service.start(profile: .chatGPTOperate)
    let client = try await fixture.connect()
    do {
      let previous = try pid(await client.call(toolName: "fixture.identity"))
      try await fixture.activate(version: 2)
      let current = try pid(await client.call(toolName: "fixture.identity"))
      #expect(previous != current)
      #expect(alive(previous))
      await client.disconnect()
      #expect(alive(previous) && alive(current))
      await fixture.service.stop()
      #expect(!alive(previous) && !alive(current))
    } catch {
      await client.disconnect()
      await fixture.service.stop()
      throw error
    }
  }

  @Test
  func stopJoinsCandidateConstructionAndCannotPublishItIntoRestartedListener() async throws {
    let bookmark = GatedBookmarkService()
    let fixture = try GenerationFixture(bookmarkService: bookmark)
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    try await fixture.service.start(profile: .chatGPTOperate)
    bookmark.arm()
    let connecting = Task { try await fixture.connect() }
    do {
      try await wait { bookmark.entered }
      let stopping = Task { await fixture.service.stop() }
      let deadline = ContinuousClock.now + .seconds(3)
      while await fixture.service.snapshot().state != .stopping && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(await fixture.service.snapshot().state == .stopping)
      bookmark.release()
      await stopping.value
      switch await connecting.result {
      case .success(let client):
        await client.disconnect()
        Issue.record("A candidate published after listener stop.")
      case .failure: break
      }
      #expect(bookmark.returned)
      #expect(await fixture.service.snapshot().state == .stopped)
      for pid in try fixture.pids() { #expect(!alive(pid)) }
      try await fixture.service.start(profile: .chatGPTOperate)
      let client = try await fixture.connect()
      _ = try await client.call(toolName: "fixture.identity")
      await client.disconnect()
      await fixture.service.stop()
      for pid in try fixture.pids() { #expect(!alive(pid)) }
    } catch {
      bookmark.release()
      if case .success(let client) = await connecting.result { await client.disconnect() }
      await fixture.service.stop()
      throw error
    }
  }

  private func value(_ report: GatewayCallReport, _ key: String) -> JSONValue? {
    report.result.objectValue?["structuredContent"]?.objectValue?[key]
  }

  private func pid(_ report: GatewayCallReport) throws -> Int32 {
    let value = try #require(value(report, "pid")?.int64Value)
    return try #require(Int32(exactly: value))
  }

  private func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

  private func wait(_ condition: () throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while try !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try condition())
  }
}

private final class GatedBookmarkService: WorkspaceBookmarkServicing, @unchecked Sendable {
  private let condition = NSCondition()
  private var armed = false
  private var _entered = false
  private var _returned = false
  private var released = false
  private let base = WorkspaceBookmarkService()

  var entered: Bool { condition.withLock { _entered } }
  var returned: Bool { condition.withLock { _returned } }
  func arm() { condition.withLock { armed = true } }
  func release() {
    condition.withLock {
      released = true
      condition.broadcast()
    }
  }

  func registerFolder(at url: URL, displayName: String?) throws -> RegisteredWorkspace {
    try base.registerFolder(at: url, displayName: displayName)
  }

  func resolve(_ workspace: RegisteredWorkspace) throws -> ResolvedWorkspaceAccess {
    condition.lock()
    if armed && !_entered {
      _entered = true
      condition.broadcast()
      while !released { condition.wait() }
      _returned = true
    }
    condition.unlock()
    return try base.resolve(workspace)
  }
}

private struct GenerationFixture: Sendable {
  let root: URL
  let database: GatewayDatabase
  let control: AppControlPlaneService
  let service: AppGatewayService
  let reportWork: Bool

  init(
    reportWork: Bool = true,
    bookmarkService: any WorkspaceBookmarkServicing = WorkspaceBookmarkService()
  ) throws {
    self.reportWork = reportWork
    root = URL(fileURLWithPath: "/private/tmp/cm-gen-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let directories = AppControlPlaneServiceDirectories(
      applicationSupport: root.appendingPathComponent("state"),
      logs: root.appendingPathComponent("logs"))
    try directories.prepare()
    database = try GatewayDatabase(path: directories.database.path)
    let secrets = try KeychainSecretStore(adapter: MemoryKeychainAdapter())
    control = AppControlPlaneService(
      directories: directories, database: database,
      manifestStore: try AtomicManifestStore(manifestURL: directories.manifest, database: database),
      secretStore: secrets, openAITunnelSupervisor: OpenAITunnelSupervisor(secretStore: secrets),
      bookmarkService: bookmarkService, bundledPlugins: .init(packages: [], issues: []))
    service = AppGatewayService(
      controlPlane: control,
      socketConfiguration: .init(socketURL: root.appendingPathComponent("gateway.sock")))
    try database.saveWorkspace(.init(id: "fixture", displayName: "Fixture", rootPath: root.path))
    try Data(Self.provider.utf8).write(to: root.appendingPathComponent("provider.py"))
  }

  func activate(version: Int) async throws {
    let names = ["start", "inspect", "finish", "identity", "generation_\(version)"]
    let profile = ProfileGrantConfig(
      id: .chatGPTOperate,
      capabilities: ["mcp.tools.call", "mcp.requests.read", "mcp.requests.cancel"],
      workspaces: ["fixture"], allowedCallers: [.localMCP], mcpServers: ["fixture"],
      mode: .workspaceOperations, confirmationPolicy: .never)
    let configuration = GatewayConfiguration(
      runtime: .init(caller: .localMCP, profileID: .chatGPTOperate), profiles: [profile],
      mcp: .init(servers: [
        .init(
          id: "fixture", transport: .stdio, command: "/usr/bin/python3",
          args: [
            root.appendingPathComponent("provider.py").path, root.path, String(version),
            reportWork ? "yes" : "no",
          ],
          exposure: .reexport, prefix: "fixture", allowAnyTool: true,
          startupTimeoutMs: 5_000, requestTimeoutMs: 5_000,
          toolRisks: Dictionary(uniqueKeysWithValues: names.map { ($0, .readOnly) }))
      ]), workspaceDirectory: root)
    if try database.profiles().isEmpty { try database.saveProfile(profile.grant) }
    _ = try await control.activateManifest(configuration.exportedTOML())
  }

  func connect() async throws -> GatewayClientSession {
    try await GatewayClientSession.connectSocket(socketURL: service.socketConfiguration.socketURL)
  }

  func pids() throws -> [Int32] {
    let path = root.appendingPathComponent("pids")
    guard FileManager.default.fileExists(atPath: path.path) else { return [] }
    return try String(contentsOf: path, encoding: .utf8).split(separator: "\n").compactMap {
      Int32($0)
    }
  }

  func calls() throws -> String {
    try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)
  }

  func removeFiles() { try? FileManager.default.removeItem(at: root) }

  private static let provider = #"""
    import json, os, sys, uuid
    from pathlib import Path
    root, version, reporting = Path(sys.argv[1]), int(sys.argv[2]), sys.argv[3] == "yes"
    with (root / "pids").open("a") as f: f.write(str(os.getpid()) + "\n")
    uri, instance, revision, resources = "computer-mcp://runtime/work/v1", str(uuid.uuid4()), 0, []
    names = ["start", "inspect", "finish", "identity", "generation_" + str(version)]
    for line in sys.stdin:
        message = json.loads(line)
        if "id" not in message: continue
        method, params = message["method"], message.get("params", {})
        if method == "initialize":
            capabilities = {"tools": {}}
            if reporting: capabilities["resources"] = {}
            result = {"protocolVersion": "2025-11-25", "capabilities": capabilities, "serverInfo": {"name": "generation-fixture", "version": str(version)}}
        elif method == "tools/list":
            result = {"tools": [{"name": name, "inputSchema": {"type": "object"}} for name in names]}
            if reporting:
                for tool in result["tools"]:
                    tool["_meta"] = {"io.github.computer-mcp/work": {"format_version": 1, "uri": uri}}
                    if tool["name"] in ["inspect", "finish"]:
                        tool["_meta"]["io.github.computer-mcp/continuation"] = {"format_version": 1, "selectors": [{"kind": "session", "handles": {"id": "/handle"}}]}
        elif method == "resources/read":
            body = {"format_version": 1, "instance_id": instance, "revision": revision, "resources": resources}
            result = {"contents": [{"uri": uri, "mimeType": "application/json", "text": json.dumps(body)}]}
        elif method == "tools/call":
            name, arguments = params["name"], params.get("arguments", {})
            with (root / "calls").open("a") as f: f.write(str(version) + ":" + name + "\n")
            handle = arguments.get("handle")
            if name == "start":
                if reporting:
                    acquisition = params["_meta"]["io.github.computer-mcp/work-invocation"]
                    resources.append({"kind": "session", "id": handle, "acquired_by": acquisition, "state": "active"})
                    revision += 1
            elif name == "finish":
                resources = [r for r in resources if r["id"] != handle]
                revision += 1
            result = {"content": [], "structuredContent": {"pid": os.getpid(), "version": version}}
        else:
            result = {}
        print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}), flush=True)
    """#
}
