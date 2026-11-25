import ComputerMCPDownstream
import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPPlatform
import ComputerMCPSandbox
import ComputerMCPTestSupport
import ComputerMCPTunnels
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPControlPlane
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPlatformDarwin
@testable import ComputerMCPProcess

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.nativeIntegration, .serialized, .timeLimit(.minutes(1)))
struct GatewayRetainedContinuationTests {
  @Test
  func preparedLineTransportLaunchesTheExactCommandAndRetainsItsInputLifetime() async throws {
    let fixture = try RetainedContinuationFixture()
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    let source = try await fixture.sessions()
    var process: ManagedLineProcess?
    do {
      let client = try await fixture.connect(source, principal: "line-owner")
      let prepared = try await fixture.prepareLineTransport(client)
      let launched = try prepared.withValue {
        try ManagedLineProcess(
          launcher: fixture.launcher,
          configuration: .init(executable: "/bin/cat", workingDirectory: fixture.projectRoot))
      }
      process = launched
      var lines = launched.inboundLines.makeAsyncIterator()
      try await launched.sendLine("before admission finishes")
      #expect(try await lines.next() == "before admission finishes")
      let running = await launched.snapshot()
      #expect(running.processID != nil)
      #expect(running.supervisorProcessID == nil)
      try prepared.finishAdmission()
      try await launched.sendLine("retained input")
      #expect(try await lines.next() == "retained input")
      let foreign = try await fixture.connect(source, principal: "line-foreign")
      let foreignAuthority = try await fixture.prepareLineTransport(foreign)
      await #expect(throws: (any Error).self) {
        try await foreignAuthority.withValue { try await launched.sendLine("foreign input") }
      }
      try foreignAuthority.finishAdmission()
      do {
        try await InvocationExecution.$current.withValue(LinePathOnlyAuthority()) {
          try await launched.sendLine("input without execution authority")
        }
        Issue.record("A path-only invocation authorized process input")
      } catch ExecutionEnvironmentError.unavailable(let message) {
        #expect(message == "The current invocation cannot authorize input to this execution")
      }
      try await prepared.withValue { try await launched.sendLine("owned input after refusals") }
      #expect(try await lines.next() == "owned input after refusals")
      await launched.close()
      #expect(await launched.snapshot().hasExited)
      #expect(try await lines.next() == nil)
      await source.shutdown()
      await fixture.service.stop()
    } catch {
      await process?.close()
      await source.shutdown()
      await fixture.service.stop()
      throw error
    }
  }

  @Test
  func processInputUsesTheRetainedGenerationAndExactOwner() async throws {
    let fixture = try RetainedContinuationFixture()
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    let source = try await fixture.sessions()
    do {
      let client = try await fixture.connect(source, principal: "input-owner")
      let foreign = try await fixture.connect(source, principal: "input-foreign")
      let started = try await fixture.call(
        client, "process.spawn",
        [
          "id": .string("cat"), "argv": .array([]),
        ])
      let processID = try #require(try fixture.payload(started)["process_id"]?.stringValue)
      let owner = try await fixture.owner(client, resourceID: processID)
      let before = try await fixture.call(
        client, "process.read", ["process_id": .string(processID)])
      try #require(before.objectValue?["isError"] != .bool(true), "Before publication: \(before)")
      try #require(try fixture.payload(before)["is_running"] == .bool(true), "\(before)")
      let profileRevision = try fixture.currentGrant().authorizationRevision
      let previousAuthority = try fixture.authority()
      try await fixture.activate(version: 2)
      #expect(try fixture.currentGrant().authorizationRevision == profileRevision)
      #expect(client.session.snapshot.fullAccessConsent != nil)
      let published = try await fixture.call(client, "project.list")
      try #require(published.objectValue?["isError"] != .bool(true), "\(published)")
      let publishedAuthority = try fixture.authority()
      try #require(
        publishedAuthority.environment.paths?.registeredProjects
          == previousAuthority.environment.paths?.registeredProjects,
        "An unrelated publication changed the Project roots or their authority identities."
      )
      for execution in previousAuthority.executions.values where execution.isRunning {
        try #require(
          publishedAuthority.executions[execution.id]?.revoked == false,
          "An unrelated publication revoked an existing execution."
        )
      }
      let after = try await fixture.call(client, "process.read", ["process_id": .string(processID)])
      try #require(after.objectValue?["isError"] != .bool(true), "After publication: \(after)")
      try #require(try fixture.payload(after)["is_running"] == .bool(true), "\(after)")
      let directory = try await fixture.call(client, "runtime.owners.list")
      let retained = try #require(
        try fixture.payload(directory)["owners"]?.arrayValue?.first {
          $0.objectValue?["owner"] == owner
        }, "\(directory)")
      try #require(retained.objectValue?["current"] == .bool(false))

      let automatic = try await fixture.call(
        client, "process.write",
        [
          "process_id": .string(processID), "text": .string("automatic-"),
        ])
      #expect(try fixture.payload(automatic)["bytes_written"]?.int64Value == 10)
      let foreignWrite = try await fixture.call(
        foreign, "process.write",
        [
          "process_id": .string(processID), "text": .string("forged"),
        ])
      #expect(foreignWrite.objectValue?["isError"] == .bool(true))
      let foreignSelected = try await fixture.selected(
        foreign, owner: owner, tool: "process.write",
        arguments: ["process_id": .string(processID), "text": .string("forged")])
      #expect(foreignSelected.objectValue?["isError"] == .bool(true))
      var wrongOwner = try #require(owner.objectValue)
      wrongOwner["runtime_id"] = .string(UUID().uuidString)
      let wrongSelected = try await fixture.selected(
        client, owner: .object(wrongOwner), tool: "process.write",
        arguments: ["process_id": .string(processID), "text": .string("forged")])
      #expect(wrongSelected.objectValue?["isError"] == .bool(true))

      let selected = try await fixture.selected(
        client, owner: owner, tool: "process.write",
        arguments: [
          "process_id": .string(processID), "text": .string("selected"), "close": .bool(true),
        ])
      #expect(try fixture.payload(selected)["input_closed"] == .bool(true))
      let output = try await fixture.waitForResult {
        let result = try await fixture.call(
          client, "process.read",
          [
            "process_id": .string(processID)
          ])
        return try fixture.payload(result)
      } settled: {
        $0["is_running"] == .bool(false)
      }
      #expect(output["stdout"] == .string("automatic-selected"))

      let active = try await fixture.call(
        client, "process.spawn",
        [
          "id": .string("cat"), "argv": .array([]),
        ])
      let revokedID = try #require(try fixture.payload(active)["process_id"]?.stringValue)
      let revokedOwner = try await fixture.owner(client, resourceID: revokedID)
      try fixture.revoke(.project("fixture"))
      let revoked = try await fixture.selected(
        client, owner: revokedOwner, tool: "process.write",
        arguments: ["process_id": .string(revokedID), "text": .string("revoked")])
      #expect(revoked.objectValue?["isError"] == .bool(true))
      let revokedAutomatic = try await fixture.call(
        client, "process.write",
        [
          "process_id": .string(revokedID), "text": .string("revoked"),
        ])
      #expect(revokedAutomatic.objectValue?["isError"] == .bool(true))
      await source.shutdown()
      await fixture.service.stop()
    } catch {
      await source.shutdown()
      await fixture.service.stop()
      throw error
    }
  }

  @Test
  func oneTimeMCPReceiptsKeepExactAuthorityWithoutStandingWritePermission() async throws {
    let fixture = try RetainedContinuationFixture()
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    let source = try await fixture.sessions()
    do {
      let client = try await fixture.connect(source, principal: "receipt-owner")
      let foreign = try await fixture.connect(source, principal: "receipt-foreign")
      let discovery = try await fixture.call(
        client, "mcp.tools.list", ["server": .string("fixture")])
      try #require(discovery.objectValue?["isError"] != .bool(true), "\(discovery)")
      let tools = try #require(
        discovery.objectValue?["structuredContent"]?.objectValue?["result"]?.arrayValue)
      #expect(
        tools.compactMap { $0.objectValue?["name"]?.stringValue }.sorted() == ["complete", "wait"])
      let started = try await fixture.startOneTime(client, requestID: "owned")
      #expect(try fixture.payload(started)["request_id"] == .string("owned"))
      #expect(
        try fixture.currentGrant().permissions.state(for: .mcpServer("fixture")) == .granted(.read))
      let pendingCount = try fixture.permissionControl.view().requests.count
      let listed = try await fixture.call(
        client, "mcp.requests.list", ["server": .string("fixture")])
      #expect(
        try fixture.payload(listed)["requests"]?.arrayValue?.map { $0.objectValue?["request_id"] }
          == [.string("owned")])
      let initialRead = try await fixture.call(
        client, "mcp.requests.read",
        [
          "server": .string("fixture"), "request_id": .string("owned"),
        ])
      #expect(try fixture.payload(initialRead)["request_id"] == .string("owned"))
      let foreignList = try await fixture.call(
        foreign, "mcp.requests.list", ["server": .string("fixture")])
      #expect(try fixture.payload(foreignList)["requests"] == .array([]))
      for tool in ["mcp.requests.read", "mcp.requests.cancel"] {
        let rejected = try await fixture.call(
          foreign, tool,
          [
            "server": .string("fixture"), "request_id": .string("owned"),
          ])
        #expect(rejected.objectValue?["isError"] == .bool(true))
      }
      let cancelled = try await fixture.call(
        client, "mcp.requests.cancel",
        [
          "server": .string("fixture"), "request_id": .string("owned"),
        ])
      #expect(try fixture.payload(cancelled)["cancellation_requested"] == .bool(true))
      #expect(try fixture.permissionControl.view().requests.count == pendingCount)
      _ = try await fixture.call(client, "mcp.tools.list", ["server": .string("fixture")])
      let secondUse = try await fixture.call(
        client, "mcp.tools.call",
        [
          "server": .string("fixture"), "tool": .string("wait"), "arguments": .object([:]),
          "request_id": .string("second-use"), "wait_for_result": .bool(false),
        ])
      #expect(secondUse.objectValue?["isError"] == .bool(true))
      #expect(String(describing: secondUse).contains("permission.required"), "\(secondUse)")
      let receipt = try await fixture.waitForResult {
        let read = try await fixture.call(
          client, "mcp.requests.read",
          [
            "server": .string("fixture"), "request_id": .string("owned"),
          ])
        return try fixture.payload(read)
      } settled: {
        $0["state"] == .string("succeeded")
      }
      #expect(receipt["cancellation"] == .string("sent"))
      #expect(try fixture.starts() == 2)

      _ = try await fixture.startOneTime(client, requestID: "revoked")
      try fixture.revoke(.mcpServer("fixture"))
      let completedAfterRevocation = try await fixture.call(
        client, "mcp.requests.read",
        ["server": .string("fixture"), "request_id": .string("owned")])
      #expect(completedAfterRevocation.objectValue?["isError"] == .bool(true))
      for tool in ["mcp.requests.read", "mcp.requests.cancel"] {
        let rejected = try await fixture.call(
          client, tool,
          [
            "server": .string("fixture"), "request_id": .string("revoked"),
          ])
        #expect(rejected.objectValue?["isError"] == .bool(true))
      }
      let revokedList = try await fixture.call(
        client, "mcp.requests.list", ["server": .string("fixture")])
      #expect(try fixture.payload(revokedList)["requests"] == .array([]))
      #expect(try fixture.starts() == 3)
      await source.shutdown()
      await fixture.service.stop()
    } catch {
      await source.shutdown()
      await fixture.service.stop()
      throw error
    }
  }
  @Test func reconnectAndUnconfirmedCleanupDoNotReplayRetainedCalls() async throws {
    let fixture = try RetainedContinuationFixture()
    defer { fixture.removeFiles() }
    try await fixture.activate(version: 1)
    let first = try await fixture.sessions()
    let client = try await fixture.connect(first, principal: "restart-owner")
    let started = try await fixture.startOneTime(client, requestID: "before-restart")
    _ = try fixture.payload(started)
    let starts = try fixture.starts()
    await first.shutdown()
    await fixture.service.stop()
    let replacement = AppGatewayService(
      controlPlane: fixture.control,
      socketConfiguration: .init(socketURL: fixture.root.appendingPathComponent("replacement.sock"))
    )
    let next = try await replacement.makeHTTPSessions(
      profileID: .chatGPTOperate,
      trace: .init(transport: "http"))
    do {
      let reconnected = try await fixture.connect(
        next, principal: "restart-owner", service: replacement)
      let stale = try await fixture.call(
        reconnected, "mcp.requests.read",
        ["server": .string("fixture"), "request_id": .string("before-restart")])
      #expect(stale.objectValue?["isError"] == .bool(true), "\(stale)")
      #expect(try fixture.starts() == starts)
      let fresh = try await fixture.startOneTime(reconnected, requestID: "after-restart")
      _ = try fixture.payload(fresh)
      #expect(try fixture.starts() == starts + 2)
      await next.shutdown()
      await replacement.stop()
      let uncertain = try MCPProcessOwnership.acquire(
        root: #require(fixture.database.mcpProcessOwnershipRoot),
        project: fixture.projectRoot, registration: "fixture")
      try uncertain.finish(confirmed: false)
      let blockedService = AppGatewayService(
        controlPlane: fixture.control,
        socketConfiguration: .init(socketURL: fixture.root.appendingPathComponent("blocked.sock")))
      let blockedSource = try await blockedService.makeHTTPSessions(
        profileID: .chatGPTOperate,
        trace: .init(transport: "http"))
      do {
        let blocked = try await fixture.connect(
          blockedSource, principal: "restart-owner", service: blockedService)
        let result = try await fixture.call(
          blocked, "mcp.tools.list", ["server": .string("fixture")])
        #expect(result.objectValue?["isError"] == .bool(true), "\(result)")
        #expect(try fixture.starts() == starts + 2)
      } catch {
        await blockedSource.shutdown()
        await blockedService.stop()
        throw error
      }
      await blockedSource.shutdown()
      await blockedService.stop()
    } catch {
      await next.shutdown()
      await replacement.stop()
      throw error
    }
  }

}

private struct LinePathOnlyAuthority: InvocationExecutionAuthority {
  let pathAccess: (any HostPathAccessChecking)? = nil
}

private struct RetainedContinuationFixture {
  let root: URL
  let projectRoot: URL
  let database: GatewayDatabase
  let control: AppControlPlaneService
  let service: AppGatewayService
  let permissionControl: PermissionControlService
  let launcher: ExecutionLauncher
  let platform: PlatformServices

  init() throws {
    root = URL(fileURLWithPath: "/private/tmp/cm-receipt-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    projectRoot = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: false)
    let directories = AppControlPlaneServiceDirectories(
      applicationSupport: root.appendingPathComponent("state"),
      logs: root.appendingPathComponent("logs"))
    try directories.prepare()
    database = try fixturePermissionDatabase(path: directories.database.path)
    launcher = fixtureProtocolExecutionLauncher(
      root: root, scripts: [Self.provider], arguments: [[root.path]], allowCat: true)
    var native = MacOSPlatform.services(launcher: launcher)
    native.permissionPolicyReader = TestManagedPolicyReader()
    platform = native
    permissionControl = try fixturePermissionControl(database: database, platform: platform)
    let secrets = try KeychainSecretStore(adapter: MemoryKeychainAdapter())
    control = AppControlPlaneService(
      directories: directories, database: database, permissionControl: permissionControl,
      manifestStore: try AtomicManifestStore(
        manifestURL: directories.manifest, database: database,
        loader: GatewayManifestConfigurationLoader(
          database: database, applications: platform.applications)),
      defaultManifest: DefaultGatewayConfiguration.manifest, secretStore: secrets,
      openAITunnelSupervisor: OpenAITunnelSupervisor(
        launcher: testExecutionLauncher(), secretStore: secrets,
        executableSearchDirectories: platform.executableSearchDirectories,
        proxyResolver: FixedOpenAITunnelHTTPProxyResolver()),
      launchAtLoginController: SMAppServiceLaunchAtLoginController(),
      computerUsePermissionReader: FixedComputerUsePermissionReader(), platform: platform,
      bundledPlugins: .init(packages: [], issues: []))
    service = AppGatewayService(
      controlPlane: control,
      socketConfiguration: .init(socketURL: root.appendingPathComponent("gateway.sock")))
    try database.saveProject(
      .init(id: "fixture", displayName: "Fixture", rootPath: projectRoot.path))
    try database.saveProfile(
      .init(
        id: .chatGPTOperate,
        permissions: fixturePermissions([
          .project("fixture"): .granted(.write), .mcpServer("fixture"): .granted(.read),
        ]), fullAccess: true, allowedCallers: [.cloudflareTunnel]))
    try Data(Self.provider.utf8).write(to: root.appendingPathComponent("provider.py"))
  }

  var registration: MCPServerConfig {
    .init(
      id: "fixture", transport: .stdio, command: "/usr/bin/python3",
      args: [root.appendingPathComponent("provider.py").path, root.path],
      exposure: .reexport, prefix: "fixture", allowAnyTool: true,
      startupTimeoutMs: 5_000, requestTimeoutMs: 10_000,
      toolRisks: ["wait": .destructive, "complete": .readOnly])
  }

  func activate(version: Int) async throws {
    let configuration = GatewayConfiguration(
      server: .init(name: "retained-\(version)"),
      runtime: .init(caller: .cloudflareTunnel, profileID: .chatGPTOperate),
      profiles: [.init(grant: try currentGrant())],
      cli: .init(commands: [.init(id: "cat", executable: "/bin/cat", allowAnyArgs: true)]),
      mcp: .init(servers: [
        registration
      ]), projectDirectory: root)
    _ = try await control.activateManifest(
      configuration.exportedTOML(), expectedDigest: try? await control.configurationDigest())
    try fixtureApproveLocalProvider(
      configuration.mcp.servers[0], database: database,
      runtime: database.permissionRuntime(platform: platform),
      permissions: fixturePermissions([
        .project("fixture"): .granted(.write), .mcpServer("fixture"): .granted(.all),
      ]), fullAccess: true)
  }

  func sessions() async throws -> GatewayHTTPManagedSessions {
    try await service.makeHTTPSessions(profileID: .chatGPTOperate, trace: .init(transport: "http"))
  }

  func prepareLineTransport(_ client: GatewayControlSessionServing) async throws
    -> PreparedExecutionContext
  {
    let projects = try await call(client, "project.list")
    try #require(projects.objectValue?["isError"] != .bool(true), "\(projects)")
    let runtime = try database.permissionRuntime(platform: platform)
    try await runtime.ready()
    var context = ExecutionContext(
      caller: .cloudflareTunnel, profileID: .chatGPTOperate, projectID: "fixture",
      trustedPrincipalID: client.session.principalID)
    context.controlSession = client.session
    let requirements = try InvocationRequirements(
      actions: [.init(requirement: .init(.project("fixture"), .write))],
      mode: .fullAccess(.standing), sandboxProjectID: "fixture")
    let decision = try runtime.service.admit(
      subject: GatewayPermissionSubject(context: context), tool: "fixture.line-transport",
      projectID: "fixture", argumentsDigest: "fixed-/bin/cat-without-arguments",
      requirements: requirements,
      connectionID: client.session.id)
    guard case .allowed(let authorization) = decision else {
      throw GatewayToolError.executionFailed("Fixture transport admission was refused: \(decision)")
    }
    let descriptor = CapabilityDescriptor(
      id: "fixture.line-transport", risk: .fullShell,
      requirement: .init(access: .projectWrite, execution: .start), projectRequirement: .required,
      localOnly: false, usesNetwork: false)
    return try #require(
      await runtime.prepare(
        authorization: authorization, descriptor: descriptor, directory: projectRoot,
        connectionID: client.session.id, auditContext: context) as? PreparedExecutionContext)
  }

  func connect(
    _ source: GatewayHTTPManagedSessions, principal: String,
    service selectedService: AppGatewayService? = nil
  ) async throws
    -> GatewayControlSessionServing
  {
    let client = try await source.makeSession(principal)
    _ = try await (selectedService ?? service).approveControlSession(
      id: client.session.id, lifetime: .thisSession, expectedRevision: client.session.revision)
    _ = try payload(await call(client, "project.list"))
    try fixtureApproveLocalProvider(
      registration, database: database,
      runtime: database.permissionRuntime(platform: platform),
      permissions: fixturePermissions([
        .project("fixture"): .granted(.write), .mcpServer("fixture"): .granted(.all),
      ]), fullAccess: true)
    return client
  }

  func call(
    _ client: GatewayControlSessionServing, _ tool: String, _ arguments: [String: JSONValue] = [:]
  ) async throws -> JSONValue {
    var arguments = arguments
    arguments["project_id"] = .string("fixture")
    return try await client.callToolForMCPAsync(
      name: tool, arguments: .object(arguments), context: .empty)
  }

  func selected(
    _ client: GatewayControlSessionServing, owner: JSONValue, tool: String,
    arguments: [String: JSONValue]
  ) async throws -> JSONValue {
    try await call(
      client, "runtime.owners.call",
      [
        "owner": owner, "tool": .string(tool), "arguments": .object(arguments),
      ])
  }

  func owner(_ client: GatewayControlSessionServing, resourceID: String) async throws -> JSONValue {
    let report = try await call(client, "runtime.owners.list")
    let rows = try #require(try payload(report)["owners"]?.arrayValue)
    return try #require(
      rows.first { $0.objectValue?["resource_id"] == .string(resourceID) }?.objectValue?["owner"])
  }

  func payload(_ report: JSONValue) throws -> [String: JSONValue] {
    try #require(report.objectValue?["isError"] != .bool(true), "\(report)")
    return try #require(
      report.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue, "\(report)")
  }

  func startOneTime(_ client: GatewayControlSessionServing, requestID: String) async throws
    -> JSONValue
  {
    let catalog = try await call(client, "mcp.tools.list", ["server": .string("fixture")])
    try #require(catalog.objectValue?["isError"] != .bool(true), "\(catalog)")
    var arguments: [String: JSONValue] = [
      "server": .string("fixture"), "tool": .string("wait"), "arguments": .object([:]),
      "request_id": .string(requestID), "wait_for_result": .bool(false),
    ]
    let required = try await call(client, "mcp.tools.call", arguments)
    let error = try #require(
      required.objectValue?["structuredContent"]?.objectValue?["error"]?.objectValue)
    try #require(error["code"] == .string("permission.required"), "\(required)")
    let ids = try #require(error["request_ids"]?.arrayValue).map {
      try #require($0.stringValue.flatMap(UUID.init(uuidString:)))
    }
    try #require(!ids.isEmpty)
    for id in ids {
      _ = try permissionControl.answerRequest(
        id, answer: .onlyThisTime, expectedRevision: permissionControl.view().revision)
    }
    arguments["_permission_request_ids"] = .array(ids.map { .string($0.uuidString) })
    return try await call(client, "mcp.tools.call", arguments)
  }

  func currentGrant() throws -> ProfileGrant {
    try #require(database.profiles().first { $0.id == .chatGPTOperate })
  }

  func authority() throws -> PermissionLedger {
    try database.configuredPermissionStore().readWithDatabase { _, ledger in ledger }
  }

  func revoke(_ permission: Permission) throws {
    _ = try permissionControl.revokePermission(
      permission, profileID: .chatGPTOperate, expectedRevision: permissionControl.view().revision)
  }

  func starts() throws -> Int {
    let container = try database.prepareProviderContainer(.localServer("fixture"))
    return try String(
      contentsOf: URL(fileURLWithPath: container.sandbox.home.value).appendingPathComponent(
        "starts"), encoding: .utf8
    ).split(
      separator: "\n"
    ).count
  }

  func waitForResult(
    _ read: () async throws -> [String: JSONValue], settled: ([String: JSONValue]) -> Bool
  ) async throws -> [String: JSONValue] {
    let deadline = ContinuousClock.now + .seconds(5)
    var value = try await read()
    while !settled(value), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
      value = try await read()
    }
    try #require(settled(value), "\(value)")
    return value
  }

  func removeFiles() { try? FileManager.default.removeItem(at: root) }

  private static let provider = #"""
    import json, os, pathlib, sys
    root = pathlib.Path(os.environ["HOME"])
    with (root / "starts").open("a") as log:
        log.write("start\n")
    pending = []
    def reply(request_id, result):
        print(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}), flush=True)
    def result(text):
        return {"content": [{"type": "text", "text": text}], "isError": False}
    for line in sys.stdin:
        message = json.loads(line)
        method = message.get("method")
        request_id = message.get("id")
        if method == "initialize":
            reply(request_id, {"protocolVersion": "2025-03-26", "capabilities": {"tools": {}}, "serverInfo": {"name": "retained-fixture", "version": "1"}})
        elif method == "tools/list":
            reply(request_id, {"tools": [{"name": name, "inputSchema": {"type": "object"}} for name in ("wait", "complete")]})
        elif method == "notifications/cancelled":
            original = message.get("params", {}).get("requestId")
            if original in pending:
                reply(original, result("completed retained work"))
                pending.remove(original)
        elif method == "tools/call":
            if message["params"]["name"] == "wait":
                pending.append(request_id)
            else:
                for original in pending:
                    reply(original, result("completed retained work"))
                pending.clear()
                reply(request_id, result("completed"))
    """#
}
