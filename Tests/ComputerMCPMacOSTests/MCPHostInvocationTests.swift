import ComputerMCPConfiguration
import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPTestSupport
import Foundation
import GRDB
import Testing

@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPlatform
@testable import ComputerMCPPlatformDarwin

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.nativeIntegration, .serialized)
struct MCPHostInvocationTests {
  @Test(.timeLimit(.minutes(10)))
  func backgroundWorkKeepsExactContextThroughDerivedWorkAndReleasesItAtCompletion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await Self.makeFixture(
      root: root, names: ["background", "derive", "finish", "replay"], work: true,
      backgroundProvider: true)
    let runtime = fixture.runtime
    let database = fixture.database
    let context = InvocationContext(session: fixture.session)
    let providerHost = try #require(fixture.providerHost)
    let loopStarted = ContinuousClock.now
    var completedBackgroundCalls = 0
    var lastCompletionElapsed = Duration.zero
    var loopTimings: [String] = []
    var lastProviderPID: Int64?
    var providerTransitions: [String] = []
    var phase = "background calls"
    defer {
      #expect(
        completedBackgroundCalls == 257,
        "Completed \(completedBackgroundCalls)/257 background calls; last completion at \(lastCompletionElapsed); timings: \(loopTimings.joined(separator: ", ")); stopped during \(phase)."
      )
    }
    do {
      // Retained contexts must not exhaust the independent 256 active-call slots.
      for _ in 0..<257 {
        let response = try await runtime.callToolAsync(
          name: "mcp.tools.call",
          arguments: Self.arguments(tool: "background", timeoutMilliseconds: 600_000),
          context: context)
        completedBackgroundCalls += 1
        lastCompletionElapsed = loopStarted.duration(to: .now)
        let providerPID = try #require(
          Self.payload(response).objectValue?["structuredContent"]?.objectValue?["pid"]?.int64Value)
        providerHost.assertProviderPID(providerPID)
        if providerPID != lastProviderPID {
          providerTransitions.append(
            "call \(completedBackgroundCalls) at \(lastCompletionElapsed): pid \(providerPID)")
          lastProviderPID = providerPID
        }
        if [1, 32, 64, 128, 256, 257].contains(completedBackgroundCalls) {
          loopTimings.append("\(completedBackgroundCalls): \(lastCompletionElapsed)")
        }
      }
      phase = "observing 257 retained resources"
      try await Self.waitForResourceCount(257, runtime: runtime)
      try providerHost.assertIndependentCalls(257)
      phase = "first retained callback"
      let replay = try await runtime.callToolAsync(
        name: "mcp.tools.call", arguments: Self.arguments(tool: "replay"), context: context)
      let original = try #require(
        Self.payload(replay).objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue)
      #expect(original["tool"] == .string("background"))
      #expect(original["registration_id"] == .string("provider"))
      #expect(original["host_action"] == .string("diagnostics.snapshot"))
      phase = "deriving retained work"
      _ = try await runtime.callToolAsync(
        name: "mcp.tools.call", arguments: Self.arguments(tool: "derive"), context: context)
      try await Self.waitForResourceCount(1, runtime: runtime, timeout: .seconds(90))
      let derived = try await runtime.callToolAsync(
        name: "mcp.tools.call", arguments: Self.arguments(tool: "replay"), context: context)
      #expect(
        Self.payload(derived).objectValue?["structuredContent"]?.objectValue?["result"]
          == .object(original))
      let retainedID = try #require(
        original["invocation_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
      #expect(
        try runtime.requireHostInvocation(
          projectID: "fixture", origin: "provider", id: retainedID
        ).reference.toolName == "background")
      let record = try #require(try database.hostCallRecordStore().record(id: retainedID))
      #expect(record.lifecycle == .retained)
      #expect(record.requestLeaseIDs.isEmpty && !record.workLeaseIDs.isEmpty)
      // Retained work does not extend the active request's mutation window.
      #expect(throws: (any Error).self) {
        try runtime.requireHostInvocation(
          projectID: "fixture", origin: "provider", action: .diagnosticsSnapshot)
      }
      #expect(throws: (any Error).self) {
        try runtime.requireHostInvocation(projectID: "fixture", origin: "other", id: retainedID)
      }
      phase = "finishing retained work"
      _ = try await runtime.callToolAsync(
        name: "mcp.tools.call", arguments: Self.arguments(tool: "finish"), context: context)
      try await Self.waitForResourceCount(0, runtime: runtime)
      phase = "checking completed invocation replay"
      let expired = try await runtime.callToolAsync(
        name: "mcp.tools.call", arguments: Self.arguments(tool: "replay"), context: context)
      #expect(Self.payload(expired).objectValue?["isError"] == .bool(true))
      #expect(throws: (any Error).self) {
        try runtime.requireHostInvocation(
          projectID: "fixture", origin: "provider", id: retainedID)
      }
      // The final replay also creates an observation barrier, even when it fails.
      try await Self.waitForResourceCount(0, runtime: runtime)
      let completed = try #require(try database.hostCallRecordStore().record(id: retainedID))
      #expect(completed.lifecycle == .completed)
      #expect(completed.requestLeaseIDs.isEmpty && completed.workLeaseIDs.isEmpty)
    } catch {
      let failedElapsed = loopStarted.duration(to: .now)
      let snapshot: String
      do {
        snapshot = try Self.capacityFailureSnapshot(
          database: database, runtime: runtime, connectionID: fixture.session.id)
      } catch let snapshotError {
        snapshot = "Snapshot unavailable: \(snapshotError)"
      }
      Issue.record(
        "Host invocation failed during \(phase) after \(failedElapsed); completed \(completedBackgroundCalls)/257 background calls, last completion at \(lastCompletionElapsed); timings: \(loopTimings.joined(separator: ", ")); provider transitions: \(providerTransitions.joined(separator: ", ")); \(snapshot)"
      )
      await runtime.shutdown()
      do { try await providerHost.finishAfterRuntimeShutdown() } catch let cleanupError {
        Issue.record("Background provider cleanup failed: \(cleanupError)")
      }
      throw error
    }
    await runtime.shutdown()
    try await providerHost.finishAfterRuntimeShutdown()
    #expect(runtime.ownedWork.snapshot.isEmpty)
  }

  private static func capacityFailureSnapshot(
    database: GatewayDatabase, runtime: GatewayRuntime, connectionID: String
  ) throws -> String {
    let ownership = runtime.ownedWork.snapshot
    let capturedAt = Date()
    let executions = try database.configuredPermissionStore().readWithDatabase {
      database, original in
      let pending = original.pendingExecutionTerminations.map(\.uuidString).sorted()
      var lines = [
        "captured_at=\(capturedAt.timeIntervalSince1970) pending_termination_ids=\(pending)"
      ]
      for record in try ExecutionRuntimeRecord.all(database).filter({ !$0.children.isEmpty })
        .sorted(by: { $0.id.uuidString < $1.id.uuidString })
      {
        let children = record.children.sorted { $0.key.uuidString < $1.key.uuidString }.map {
          id, child in
          "id=\(id) pid=\(child.recovery?.root.processID.description ?? "unpublished") "
            + "identity=\(child.recovery?.root.identity.description ?? "unpublished") "
            + "completed=\(child.completed) released=\(child.released)"
        }.joined(separator: ", ")
        let originalState: String
        let copiedAccess: String
        if let execution = original.executions[record.id] {
          originalState =
            "started_at=\(execution.startedAt.timeIntervalSince1970) "
            + "background=\(execution.limitRequest.background) "
            + "requested_ms=\(execution.limitRequest.timeMilliseconds?.description ?? "none") "
            + "effective_ms=\(execution.limits.timeMilliseconds?.description ?? "none") "
            + "running=\(execution.isRunning) revoked=\(execution.revoked) "
            + "ended_at=\(execution.endedAt?.timeIntervalSince1970.description ?? "none") "
            + "end_reason=\(String(describing: execution.limitEndReason))"
          var validation = original
          copiedAccess = String(
            describing: validation.executionAccess(
              record.id, principal: execution.owner, operation: .writeInput,
              connectionID: connectionID, authorizingInvocation: nil, now: capturedAt))
        } else {
          originalState = "ledger_execution=missing"
          copiedAccess = "not_evaluated"
        }
        lines.append(
          "execution_id=\(record.id) admission_finished=\(record.admissionFinished) "
            + "runtime_completed=\(record.completed) original={\(originalState)} "
            + "copied_write_input=\(copiedAccess) children=[\(children)]")
      }
      return lines.joined(separator: "; ")
    }
    let owners = Dictionary(grouping: ownership) { record in
      "kind=\(record.kind.rawValue) connection=\(record.connectionID?.uuidString ?? "none") "
        + "uncertain=\(record.uncertain)"
    }.map { key, records in "\(key) count=\(records.count)" }.sorted()
    return "executions=[\(executions)] ownership=[\(owners.joined(separator: "; "))]"
  }

  @Test(.timeLimit(.minutes(2)))
  func profileChangesRetireRetainedInvocationWithoutResurrection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await Self.makeFixture(
      root: root, names: ["background", "replay"], work: true)
    let runtime = fixture.runtime
    let context = InvocationContext(session: fixture.session)
    do {
      let started = try await runtime.callToolAsync(
        name: "mcp.tools.call", arguments: Self.arguments(tool: "background"), context: context)
      let reportedPID = try #require(
        Self.payload(started).objectValue?["structuredContent"]?.objectValue?["pid"]?.int64Value)
      let processID = try #require(Int32(exactly: reportedPID))
      let provider = try #require(DarwinProcessIdentity.current(pid: processID)?.identity)
      try await Self.waitForResourceCount(1, runtime: runtime)
      let resource = try #require(runtime.ownedWork.snapshot.first { $0.kind == .mcpResource })
      _ = try #require(resource.connectionID)
      #expect(resource.projectID == "fixture" && resource.registrationID == "provider")
      let replay = try await runtime.callToolAsync(
        name: "mcp.tools.call", arguments: Self.arguments(tool: "replay"), context: context)
      let retainedID = try #require(
        Self.payload(replay).objectValue?["structuredContent"]?.objectValue?["result"]?
          .objectValue?["invocation_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
      #expect(
        try runtime.requireHostInvocation(
          projectID: "fixture", origin: "provider", id: retainedID
        ).reference.toolName == "background")
      var grant = try #require(fixture.database.profiles().first { $0.id == .localAdmin })
      grant.permissions.removeEntry(for: .project("fixture"))
      try fixture.database.saveProfile(grant, expectedRevision: grant.authorizationRevision)
      #expect(throws: (any Error).self) {
        try runtime.requireHostInvocation(projectID: "fixture", origin: "provider", id: retainedID)
      }
      try await Self.waitForRetiredProvider(
        provider, resource: resource, runtime: runtime, database: fixture.database,
        invocationID: retainedID)
      let retired = try #require(try fixture.database.hostCallRecordStore().record(id: retainedID))
      #expect(retired.lifecycle == .completed)
      #expect(retired.requestLeaseIDs.isEmpty && retired.workLeaseIDs.isEmpty)
      grant = try #require(fixture.database.profiles().first { $0.id == .localAdmin })
      try grant.permissions.set(.granted(.read), for: .project("fixture"))
      try fixture.database.saveProfile(grant, expectedRevision: grant.authorizationRevision)
      #expect(throws: (any Error).self) {
        try runtime.requireHostInvocation(projectID: "fixture", origin: "provider", id: retainedID)
      }
      #expect(fixture.session.snapshot.fullAccessConsent == nil)
      await runtime.shutdown()
      try await Self.waitForRetiredProvider(
        provider, resource: resource, runtime: runtime, database: fixture.database,
        invocationID: retainedID)
      let completed = try #require(
        try fixture.database.hostCallRecordStore().record(id: retainedID))
      #expect(completed.lifecycle == .completed)
      #expect(completed.requestLeaseIDs.isEmpty && completed.workLeaseIDs.isEmpty)
    } catch {
      await runtime.shutdown()
      throw error
    }
  }

  private static func waitForRetiredProvider(
    _ provider: DarwinProcessIdentity, resource: GatewayOwnedWork.Record, runtime: GatewayRuntime,
    database: GatewayDatabase, invocationID: UUID
  ) async throws {
    var uncertainResource = resource
    uncertainResource.uncertain = true
    func retired() throws -> Bool {
      let record = try database.hostCallRecordStore().record(id: invocationID)
      let snapshot = runtime.ownedWork.snapshot
      return DarwinProcessIdentity.current(pid: provider.pid, includingZombies: true)?.identity
        != provider
        && record?.lifecycle == .completed
        && record?.requestLeaseIDs.isEmpty == true && record?.workLeaseIDs.isEmpty == true
        && snapshot.count == 2 && snapshot.contains(uncertainResource)
        && snapshot.contains {
          $0.kind == .mcpObservation && $0.uncertain
            && $0.projectID == resource.projectID && $0.registrationID == resource.registrationID
            && $0.connectionID == resource.connectionID
            && $0.resourceID == resource.connectionID?.uuidString
        }
    }
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
      if try retired() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(
      try retired(),
      "Provider \(provider) was not joined with only its original uncertain resource and observation remaining: \(runtime.ownedWork.snapshot)"
    )
  }

  @Test(.timeLimit(.minutes(2)), arguments: [false, true])
  func nativeDispatchLeaseFailureNeverReachesProvider(failWorkLease: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let marker = root.appendingPathComponent("dispatched")
    let source = Self.provider.replacingOccurrences(
      of: "elif method == \"tools/call\":",
      with: "elif method == \"tools/call\":\n        open(" + String(reflecting: marker.path)
        + ", \"w\").write(\"dispatched\")")
    let database = try fixturePermissionDatabase(path: root.appendingPathComponent("host.db").path)
    let connection = database.connection
    let fixture = try await Self.makeFixture(
      root: root, names: ["background"], work: true, source: source, database: database)
    let runtime = fixture.runtime
    let context = InvocationContext(session: fixture.session)
    do {
      try await connection.writer.write { database in
        let condition =
          failWorkLease ? "WHEN json_array_length(NEW.payload, '$.workLeaseIDs') > 0" : ""
        try database.execute(
          sql: "CREATE TRIGGER fail_lease BEFORE UPDATE ON hostCallRecords " + condition
            + " BEGIN SELECT RAISE(ABORT, 'fixture'); END")
      }
      await #expect(throws: (any Error).self) {
        try await runtime.callToolAsync(
          name: "mcp.tools.call", arguments: Self.arguments(tool: "background"), context: context)
      }
      #expect(!FileManager.default.fileExists(atPath: marker.path))
      let records = try await connection.writer.read { database in
        try Data.fetchAll(database, sql: "SELECT payload FROM hostCallRecords").map {
          try JSONDecoder().decode(HostCallRecord.self, from: $0)
        }
      }
      let record = try #require(records.first)
      #expect(records.count == 1)
      #expect(record.admission.reference == .init(serverID: "provider", toolName: "background"))
      #expect(record.admission.upstreamName == "mcp.tools.call")
      #expect(record.admission.controlSessionID == fixture.session.id)
      #expect(record.admission.authorizationID != nil)
      if failWorkLease { #expect(record.lifecycle == .completed) }
      #expect(throws: (any Error).self) {
        try runtime.requireHostInvocation(
          projectID: "fixture", origin: "provider", id: record.admission.id)
      }
    } catch {
      await runtime.shutdown()
      throw error
    }
    await runtime.shutdown()
  }

  private static func waitForResourceCount(
    _ count: Int, runtime: GatewayRuntime, timeout: Duration = .seconds(3)
  ) async throws {
    let deadline = ContinuousClock.now + timeout
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

  @Test(.timeLimit(.minutes(2)), arguments: [false, true], ["sync", "async", "detached"])
  func nativeProviderReceivesOnlyItsHostBoundInvocation(hostServices: Bool, mode: String)
    async throws
  {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try await Self.makeFixture(
      root: root, names: ["inspect", "deferred", "release", "replay"], work: false,
      hostServices: hostServices)
    let runtime = fixture.runtime
    let context = InvocationContext(session: fixture.session)
    do {
      let arguments = Self.arguments(tool: mode == "detached" ? "deferred" : "inspect")
      let result: JSONValue
      if mode == "sync" {
        result = try await BlockingOperationExecutor(label: "host-invocation-test").perform {
          try runtime.callTool(name: "mcp.tools.call", arguments: arguments, context: context)
        }
      } else if mode == "async" {
        result = try await runtime.callToolAsync(
          name: "mcp.tools.call", arguments: arguments, context: context)
      } else {
        var startedArguments = try #require(arguments.objectValue)
        startedArguments["wait_for_result"] = .bool(false)
        startedArguments["request_id"] = .string("detached")
        let started = try await runtime.callToolAsync(
          name: "mcp.tools.call", arguments: .object(startedArguments), context: context)
        #expect(Self.payload(started).objectValue?["state"] == .string("running"))
        startedArguments["request_id"] = .string("second")
        _ = try await runtime.callToolAsync(
          name: "mcp.tools.call", arguments: .object(startedArguments), context: context)
        #expect(runtime.ownedWork.snapshot.filter { $0.kind == .mcpRequest }.count == 2)
        _ = try await runtime.callToolAsync(
          name: "mcp.tools.call", arguments: Self.arguments(tool: "release"), context: context)
        let first = try await Self.readResult(runtime, id: "detached", context: context)
        let second = try await Self.readResult(runtime, id: "second", context: context)
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
      let reportedContext = try #require(
        Self.payload(result).objectValue?["structuredContent"]?.objectValue)
      if hostServices {
        let bound = try #require(reportedContext["result"]?.objectValue)
        #expect(bound["registration_id"] == .string("provider"))
        #expect(bound["workspace_id"] == .string("fixture"))
        #expect(bound["tool"] == .string(mode == "detached" ? "deferred" : "inspect"))
        #expect(bound["capability_id"] == .string("mcp.tools.call"))
        #expect(bound["invocation_id"]?.stringValue.flatMap(UUID.init(uuidString:)) != nil)
        let replay = try await runtime.callToolAsync(
          name: "mcp.tools.call", arguments: Self.arguments(tool: "replay"), context: context)
        #expect(Self.payload(replay).objectValue?["isError"] == .bool(true))
      } else {
        #expect(reportedContext["host_metadata"] == .null)
      }
    } catch {
      await runtime.shutdown()
      throw error
    }
    await runtime.shutdown()
    #expect(runtime.ownedWork.snapshot.isEmpty)
  }

  /// Metadata is observed through the same admitted native connection used by calls.
  private static func makeFixture(
    root: URL, names: [String], work: Bool, hostServices: Bool = true,
    source suppliedSource: String? = nil, database suppliedDatabase: GatewayDatabase? = nil,
    backgroundProvider: Bool = false
  ) async throws -> (
    runtime: GatewayRuntime, session: GatewayControlSession, database: GatewayDatabase,
    providerHost: MCPInvocationBackgroundProvider?
  ) {
    let root = try ProjectPathResolver.canonicalProject(root)
    let source = suppliedSource ?? provider
    let script = root.appendingPathComponent("provider.py")
    try writePythonTestExecutable(source, to: script)
    let arguments = work ? ["work"] : []
    let launcher = testExecutionLauncher()
    var platform = MacOSPlatform.services(launcher: launcher)
    platform.permissionPolicyReader = TestManagedPolicyReader()
    let database =
      try suppliedDatabase
      ?? fixturePermissionDatabase(path: root.appendingPathComponent("host.db").path)
    let project = ComputerMCPCore.RegisteredProject(
      id: "fixture", displayName: "Fixture", rootPath: root.path)
    try database.saveProject(project)
    let profile = ProfileGrant(
      id: .localAdmin,
      permissions: fixturePermissions([
        .project("fixture"): .granted(.read), .mcpServer("provider"): .granted(.read),
      ]), fullAccess: true, allowedCallers: [.localMCP])
    try database.saveProfile(profile)
    let server = MCPServerConfig(
      id: "provider", transport: .stdio, command: script.path,
      args: arguments, allowedTools: names,
      startupTimeoutMs: backgroundProvider ? 30_000 : 5_000, requestTimeoutMs: 5_000,
      toolRisks: Dictionary(uniqueKeysWithValues: names.map { ($0, .readOnly) }),
      hostServices: hostServices)
    let capture =
      backgroundProvider
      ? MCPInvocationScopedClientCapture(
        base: MCPProxyClient(launcher: launcher), projectID: project.id) : nil
    let runtime = try await GatewayRuntime.make(
      configuration: .init(
        runtime: .init(caller: .localMCP, profileID: profile.id), profiles: [.init(grant: profile)],
        mcp: .init(servers: [server]), projectDirectory: root),
      context: .init(
        caller: .localMCP, profileID: profile.id, projectID: project.id,
        trustedPrincipalID: "host-invocation-client"),
      database: database, registeredProjects: [project], platform: platform, mcpClient: capture,
      bundledPlugins: .init(packages: [], issues: []), requiresControlSession: true)
    var providerHost: MCPInvocationBackgroundProvider?
    do {
      let session = try runtime.makeControlSession()
      try fixtureApproveLocalProvider(
        server, database: database, runtime: runtime.permissionRuntime,
        permissions: fixturePermissions([.project(project.id): .granted(.read)]), fullAccess: true)
      _ = try session.approveFullAccess(expectedRevision: session.revision)
      if let capture {
        #expect(capture.scopes.count == 1)
        let scope = try #require(capture.scopes.first)
        providerHost = try await MCPInvocationBackgroundProvider.start(
          runtime: runtime, database: database, session: session, scope: scope, server: server)
      }
      let catalog = try await runtime.callToolAsync(
        name: "mcp.tools.list",
        arguments: .object(["project_id": .string("fixture"), "server": .string("provider")]),
        context: .init(session: session))
      let tools = try #require(payload(catalog).arrayValue)
      #expect(Set(tools.compactMap { $0.objectValue?["name"]?.stringValue }) == Set(names))
      return (runtime, session, database, providerHost)
    } catch {
      await runtime.shutdown()
      if let providerHost {
        do { try await providerHost.finishAfterRuntimeShutdown() } catch let cleanupError {
          Issue.record("Background provider cleanup failed: \(cleanupError)")
        }
      }
      throw error
    }
  }

  private static func arguments(tool: String, timeoutMilliseconds: Int64? = nil) -> JSONValue {
    var arguments: [String: JSONValue] = [
      "project_id": .string("fixture"), "server": .string("provider"), "tool": .string(tool),
      "arguments": .object(["invocation_id": .string("caller-forged-id")]),
    ]
    if let timeoutMilliseconds { arguments["timeout_ms"] = .integer(timeoutMilliseconds) }
    return .object(arguments)
  }

  private static func readResult(
    _ runtime: GatewayRuntime, id: String, context: InvocationContext
  ) async throws -> JSONValue {
    let deadline = ContinuousClock.now + .seconds(2)
    var receipt: JSONValue = .null
    repeat {
      receipt = try await runtime.callToolAsync(
        name: "mcp.requests.read",
        arguments: .object([
          "project_id": .string("fixture"), "server": .string("provider"),
          "request_id": .string(id),
        ]), context: context)
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
                result = {"content": [], "structuredContent": {"pid": os.getpid()}}
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
