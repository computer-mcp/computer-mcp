import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPTestSupport
import ComputerMCPTunnels
import Darwin
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPControlPlane
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPlatform
@testable import ComputerMCPPlatformDarwin

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.nativeIntegration, .serialized)
struct GatewaySocketPrincipalLifecycleTests {
  @Test
  func disconnectedCallerCanObserveAndCancelItsOriginalExecutionAfterReconnect() async throws {
    let root = URL(fileURLWithPath: "/private/tmp/cm-owner-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let directories = AppControlPlaneServiceDirectories(
      applicationSupport: root.appendingPathComponent("state"),
      logs: root.appendingPathComponent("logs"))
    try directories.prepare()
    let database = try fixturePermissionDatabase(path: directories.database.path)
    let script = root.appendingPathComponent("fixture.py")
    try writePythonTestExecutable(Self.server, to: script)
    let launcher = fixtureProtocolExecutionLauncher(
      root: root, scripts: [try String(contentsOf: script, encoding: .utf8)], arguments: [[]])
    var platform = MacOSPlatform.services(launcher: launcher)
    platform.permissionPolicyReader = TestManagedPolicyReader()
    let permissionControl = try fixturePermissionControl(database: database, platform: platform)
    let manifest = try AtomicManifestStore(
      manifestURL: directories.manifest, database: database,
      loader: GatewayManifestConfigurationLoader(
        database: database,
        applications: platform.applications))
    let secrets = try KeychainSecretStore(adapter: MemoryKeychainAdapter())
    let control = AppControlPlaneService(
      directories: directories, database: database,
      permissionControl: permissionControl, manifestStore: manifest,
      defaultManifest: DefaultGatewayConfiguration.manifest, secretStore: secrets,
      openAITunnelSupervisor: OpenAITunnelSupervisor(
        launcher: testExecutionLauncher(),
        secretStore: secrets,
        executableSearchDirectories: MacOSPlatform.services(launcher: testExecutionLauncher())
          .executableSearchDirectories,
        proxyResolver: FixedOpenAITunnelHTTPProxyResolver()
      ),
      launchAtLoginController: SMAppServiceLaunchAtLoginController(),
      computerUsePermissionReader: FixedComputerUsePermissionReader(),
      platform: platform,
      bundledPlugins: .init(packages: [], issues: []))
    let provider = MCPServerConfig(
      id: "fixture", transport: .stdio, command: script.path,
      exposure: .reexport, prefix: "fixture", allowAnyTool: true,
      startupTimeoutMs: 5000, requestTimeoutMs: 5000,
      toolRisks: ["hang": .readOnly])
    let configuration = GatewayConfiguration(
      runtime: .init(caller: .localMCP, profileID: .chatGPTOperate),
      profiles: [
        .init(
          id: .chatGPTOperate,
          permissions: fixturePermissions([
            .project("fixture"): .granted(.write), .mcpServer("fixture"): .granted(.all),
            .mcpServer("*"): .granted(.all),
          ]), fullAccess: true, allowedCallers: [.localMCP])
      ],
      mcp: .init(servers: [provider]), projectDirectory: root)
    _ = try await control.activateManifest(
      configuration.exportedTOML(), expectedDigest: try? await control.configurationDigest())
    try database.saveProject(.init(id: "fixture", displayName: "Fixture", rootPath: root.path))
    let service = AppGatewayService(
      controlPlane: control,
      socketConfiguration: .init(socketURL: root.appendingPathComponent("gateway.sock")))
    let operations = AppControlPlaneOperations(controlPlane: control, gatewayService: service)
    try await service.start(profile: .chatGPTOperate)
    do {
      let first = try await GatewayClientSession.connectSocket(
        socketURL: service.socketConfiguration.socketURL)
      // Standing provider consent binds to the environment published by the socket runtime.
      try fixtureApproveLocalProvider(
        provider, database: database, runtime: database.permissionRuntime(platform: platform),
        permissions: fixturePermissions([.project("fixture"): .granted(.write)]), fullAccess: true)
      let firstScope = try #require(await operations.controlSessions().first)
      #expect(firstScope.fullAccessConsent == nil)
      let approved = try await operations.approveControlSession(
        id: firstScope.id, lifetime: .alwaysAllowClient,
        expectedRevision: firstScope.revision, expectedTrustRevision: 0)
      let trust = try #require(try operations.clientTrusts().first)
      #expect(approved.fullAccessConsent?.lifetime == .alwaysAllowClient)
      #expect(approved.fullAccessConsent?.trustID == trust.id)
      #expect(trust.fullAccessAllowed && trust.principalID == firstScope.principalID)
      let discovered = try await first.call(
        toolName: "mcp.tools.list",
        arguments: .object(["project_id": .string("fixture"), "server": .string("fixture")]))
      try #require(
        discovered.result.objectValue?["isError"] != .bool(true), "\(discovered.result)")
      let started = try await first.call(
        toolName: "mcp.tools.call",
        arguments: .object([
          "project_id": .string("fixture"), "server": .string("fixture"), "tool": .string("hang"),
          "arguments": .object([:]), "request_id": .string("owned-execution"),
          "wait_for_result": .bool(false),
        ]))
      try #require(started.result.objectValue?["isError"] != .bool(true), "\(started.result)")
      await first.disconnect()
      let pid = try #require(
        Int32(String(contentsOf: root.appendingPathComponent("pid"), encoding: .utf8)))
      #expect(kill(pid, 0) == 0)

      let reconnected = try await GatewayClientSession.connectSocket(
        socketURL: service.socketConfiguration.socketURL)
      let restored = try #require(
        await operations.controlSessions().first { $0.id != firstScope.id })
      #expect(restored.principalID == firstScope.principalID)
      #expect(restored.fullAccessConsent?.lifetime == .alwaysAllowClient)
      #expect(restored.fullAccessConsent?.trustID == trust.id)
      #expect(restored.fullAccessConsent?.trustRevision == trust.revision)
      #expect(try operations.clientTrusts().first == trust)
      let selector: JSONValue = .object([
        "project_id": .string("fixture"), "server": .string("fixture"),
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
      let clock = ContinuousClock()
      let cancellationMarker = root.appendingPathComponent("cancelled")
      let cancellationDeadline = clock.now.advanced(by: .seconds(5))
      while !FileManager.default.fileExists(atPath: cancellationMarker.path),
        clock.now < cancellationDeadline
      {
        try await Task.sleep(for: .milliseconds(10))
      }
      try #require(
        FileManager.default.fileExists(atPath: cancellationMarker.path),
        "The original provider did not receive native cancellation.")
      var receipt = try payload(
        await reconnected.call(toolName: "mcp.requests.read", arguments: selector))
      try #require(receipt.objectValue?["state"] == .string("running"), "\(receipt)")
      try Data().write(to: root.appendingPathComponent("release"))
      let deadline = clock.now.advanced(by: .seconds(5))
      while receipt.objectValue?["state"] == .string("running"), clock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
        receipt = try payload(
          await reconnected.call(toolName: "mcp.requests.read", arguments: selector))
      }
      #expect(receipt.objectValue?["state"] == .string("succeeded"), "\(receipt)")
      #expect(
        receipt.objectValue?["result"]?.objectValue?["content"]?.arrayValue?.first?
          .objectValue?["text"] == .string("late completion"))
      #expect(
        try String(contentsOf: root.appendingPathComponent("dispatches"), encoding: .utf8) == "1")
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
    import json, os, sys, time
    from pathlib import Path
    root = Path.cwd()
    (root / "pid").write_text(str(os.getpid()))
    pending_id = None
    dispatches = 0
    for line in sys.stdin:
        message = json.loads(line)
        method = message.get("method")
        if method == "notifications/cancelled":
            if pending_id is None or message.get("params", {}).get("requestId") != pending_id:
                continue
            (root / "cancelled").touch()
            release = root / "release"
            deadline = time.monotonic() + 10
            while not release.exists():
                if time.monotonic() >= deadline:
                    raise TimeoutError("Fixture completion was not released")
                time.sleep(0.01)
            result = {"content": [{"type": "text", "text": "late completion"}]}
            print(json.dumps({"jsonrpc": "2.0", "id": pending_id, "result": result}), flush=True)
            pending_id = None
            continue
        if "id" not in message:
            continue
        result = {}
        if method == "initialize":
            result = {"protocolVersion":"2025-11-25", "capabilities":{"tools":{}}, "serverInfo":{"name":"fixture", "version":"1"}}
        elif method == "tools/list":
            result = {"tools":[{"name":"hang", "inputSchema":{"type":"object"}}]}
        elif method == "tools/call" and message["params"]["name"] == "hang":
            pending_id = message["id"]
            dispatches += 1
            (root / "dispatches").write_text(str(dispatches))
            continue
        print(json.dumps({"jsonrpc":"2.0", "id":message["id"], "result":result}), flush=True)
    """#
}
