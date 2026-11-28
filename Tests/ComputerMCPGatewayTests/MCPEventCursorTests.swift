import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPPermissions
import ComputerMCPPersistence
import ComputerMCPProcess
import ComputerMCPSandbox
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPGateway
@testable import ComputerMCPPlatform

#if os(macOS)
  import ComputerMCPDarwinTestSupport
  import ComputerMCPPlatformDarwin
#endif

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

@Suite(.nativeIntegration)
struct MCPEventCursorTests {
  @Test
  func initialReadsAndUnavailableContinuationsDoNotStartAProvider() async throws {
    let fixture = try EventFixture()
    defer { fixture.remove() }
    let client = MCPProxyClient(launcher: testExecutionLauncher(), workingDirectory: fixture.root)
    do {
      let initial = try client.readEvents(
        server: fixture.server, afterCursor: 0, maxResults: 10, context: .empty)
      #expect(initial.objectValue?["cursor_state"] == .string("not_started"))
      #expect(initial.objectValue?["session_id"] == .null)
      #expect(initial.objectValue?["missed_events"] == .null)
      #expect(initial.objectValue?["events"] == .array([]))
      #expect(throws: (any Error).self) {
        try client.readEvents(
          server: fixture.server, afterCursor: 1, maxResults: 10, context: .empty)
      }
      #expect(throws: (any Error).self) {
        try client.readEvents(
          server: fixture.server, afterCursor: 0, maxResults: 10, sessionID: "old-session",
          context: .empty)
      }
      #expect(!FileManager.default.fileExists(atPath: fixture.starts.path))
      await client.shutdown()
    } catch {
      await client.shutdown()
      throw error
    }
  }

  #if canImport(Darwin)
    // Connected MCP transports inherit an ownership descriptor, supported only on Darwin.
    @Test
    func longEventStreamReportsEvictionAndPaginatesWithinOneVerifiedSession() async throws {
      let fixture = try EventFixture()
      defer { fixture.remove() }
      let execution = try await EventExecutionFixture(fixture: fixture)
      let client = MCPProxyClient(
        launcher: execution.launcher, workingDirectory: fixture.root,
        hostContext: execution.hostContext)
      do {
        let context = try await execution.connect(client)
        // Responses drain each burst below the transport queue bound before sending more events.
        for _ in 0..<100 {
          _ = try await execution.stream(client)
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        var page = try client.readEvents(
          server: fixture.server, afterCursor: 0, maxResults: 7, context: context)
        while page.objectValue?["latest_event_cursor"]?.intValue ?? 0 < 701, clock.now < deadline {
          try await Task.sleep(for: .milliseconds(10))
          page = try client.readEvents(
            server: fixture.server, afterCursor: 0, maxResults: 7, context: context)
        }
        let object = try #require(page.objectValue)
        let sessionID = try #require(object["session_id"]?.stringValue)
        let latest = try #require(object["latest_event_cursor"]?.intValue)
        let oldest = try #require(object["oldest_available_cursor"]?.intValue)
        #expect(latest >= 701)
        #expect(latest - oldest + 1 == 512)
        #expect(object["missed_events"] == .number(Double(oldest - 1)))
        #expect(object["cursor_state"] == .string("truncated"))
        #expect(object["events"]?.arrayValue?.count == 7)
        #expect(object["has_more"] == .bool(true))
        let next = try #require(object["next_cursor"]?.intValue)
        let verified = try client.readEvents(
          server: fixture.server, afterCursor: next, maxResults: 500, sessionID: sessionID,
          context: context)
        #expect(verified.objectValue?["session_verified"] == .bool(true))
        #expect(verified.objectValue?["events"]?.arrayValue?.count == 500)
        #expect(verified.objectValue?["missed_events"] == .number(0))
        let tail = try client.readEvents(
          server: fixture.server,
          afterCursor: try #require(verified.objectValue?["next_cursor"]?.intValue),
          maxResults: 500, sessionID: sessionID, context: context)
        #expect(tail.objectValue?["has_more"] == .bool(false))
        #expect(tail.objectValue?["events"]?.arrayValue?.count == 5)
        let unbound = try client.readEvents(
          server: fixture.server, afterCursor: latest, maxResults: 1, context: context)
        #expect(unbound.objectValue?["cursor_state"] == .string("unbound"))
        #expect(unbound.objectValue?["session_verified"] == .bool(false))
        #expect(throws: (any Error).self) {
          try client.readEvents(
            server: fixture.server, afterCursor: Int.max, maxResults: 1, sessionID: sessionID,
            context: context)
        }
        #expect(throws: (any Error).self) {
          try client.readEvents(
            server: fixture.server, afterCursor: latest, maxResults: 501, sessionID: sessionID,
            context: context)
        }
        #expect(try String(contentsOf: fixture.starts, encoding: .utf8) == "started\n")
        await client.shutdown()
        await execution.shutdown()
      } catch {
        await client.shutdown()
        await execution.shutdown()
        throw error
      }
    }

    @Test
    func sameNumericCursorFromAnotherInstanceIsRejectedThroughAuthorizationWrapper() async throws {
      let fixture = try EventFixture()
      defer { fixture.remove() }
      let execution = try await EventExecutionFixture(fixture: fixture)
      let first = MCPProxyClient(
        launcher: execution.launcher, workingDirectory: fixture.root,
        hostContext: execution.hostContext)
      let replacement = MCPProxyClient(
        launcher: execution.launcher, workingDirectory: fixture.root,
        hostContext: execution.hostContext)
      do {
        let firstContext = try await execution.connect(first)
        let original = try first.readEvents(
          server: fixture.server, afterCursor: 0, maxResults: 10, context: firstContext)
        let oldSession = try #require(original.objectValue?["session_id"]?.stringValue)
        let cursor = try #require(original.objectValue?["next_cursor"]?.intValue)
        await first.shutdown()
        #expect(throws: (any Error).self) {
          try replacement.readEvents(
            server: fixture.server, afterCursor: cursor, maxResults: 10, sessionID: oldSession,
            context: .empty)
        }
        #expect(try String(contentsOf: fixture.starts, encoding: .utf8) == "started\n")
        let replacementContext = try await execution.connect(replacement)
        let authorized: any DownstreamMCPClient = AuthorizedMCPClient(
          base: replacement,
          policy: .init(
            configuration: .init(mcp: .init(servers: [fixture.server])),
            grant: .init(
              id: .chatGPTObserve, permissions: try eventPermissions(fixture.server.id),
              allowedCallers: [.localMCP])))
        #expect(throws: (any Error).self) {
          try authorized.readEvents(
            server: fixture.server, afterCursor: cursor, maxResults: 10, sessionID: oldSession,
            context: replacementContext)
        }
        let current = try authorized.readEvents(
          server: fixture.server, afterCursor: 0, maxResults: 10, sessionID: nil,
          context: replacementContext)
        #expect(current.objectValue?["session_id"]?.stringValue != oldSession)
        #expect(try String(contentsOf: fixture.starts, encoding: .utf8) == "started\nstarted\n")
        await replacement.shutdown()
        await execution.shutdown()
      } catch {
        await first.shutdown()
        await replacement.shutdown()
        await execution.shutdown()
        throw error
      }
    }
  #endif
}

private struct EventFixture: Sendable {
  let root: URL
  let starts: URL
  let script: URL
  let server: MCPServerConfig

  init() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    root = try ProjectPathResolver.canonicalProject(directory)
    starts = root.appendingPathComponent("starts")
    script = root.appendingPathComponent("events.py")
    try Data(Self.script.utf8).write(to: script)
    server = .init(
      id: "fixture", transport: .stdio, command: try testExecutable("python3"),
      args: [script.path, starts.path],
      startupTimeoutMs: 5000, requestTimeoutMs: 10_000)
  }

  #if canImport(Darwin)
    func executionLauncher() throws -> ExecutionLauncher {
      ExecutionLauncher(
        platform: try EventExecutionPlatform(
          root: root, script: script, starts: starts,
          executable: try #require(server.command), program: Self.script))
    }
  #endif

  func remove() { try? FileManager.default.removeItem(at: root) }

  private static let script = #"""
    import json, sys
    with open(sys.argv[1], "a") as marker:
        marker.write("started\n")
    for line in sys.stdin:
        message = json.loads(line)
        if "id" not in message:
            continue
        method = message.get("method")
        result = {}
        if method == "initialize":
            result = {"protocolVersion":"2025-11-25", "capabilities":{"tools":{"listChanged":True}}, "serverInfo":{"name":"events", "version":"1"}}
        elif method == "tools/list":
            result = {"tools":[{"name":"stream", "inputSchema":{"type":"object"}}]}
        elif method == "tools/call":
            for _ in range(7):
                print(json.dumps({"jsonrpc":"2.0", "method":"notifications/tools/list_changed"}), flush=True)
            result = {"content":[]}
        print(json.dumps({"jsonrpc":"2.0", "id":message["id"], "result":result}), flush=True)
    """#
}

private func eventPermissions(_ server: String) throws -> Permissions {
  var permissions = Permissions()
  try permissions.set(.granted(.read), for: .mcpServer(server))
  return permissions
}

#if canImport(Darwin)
  private final class EventExecutionFixture: @unchecked Sendable {
    let launcher: ExecutionLauncher
    let hostContext: MCPHostContext
    private let fixture: EventFixture
    private let database: GatewayDatabase
    private let service: GatewayPermissionService
    private let coordinator: ExecutionRevocationCoordinator
    private let session: GatewayControlSession
    private let subject: GatewayPermissionSubject
    private let directory: URL
    private let calls = BlockingOperationExecutor(label: "event-cursor-test")
    private let lock = NSLock()
    private var contexts: [PreparedExecutionContext] = []

    init(fixture: EventFixture) async throws {
      self.fixture = fixture
      let launcher = try fixture.executionLauncher()
      self.launcher = launcher
      let database = try GatewayDatabase(
        path: fixture.root.appendingPathComponent("authority.sqlite").path)
      self.database = database
      let store = database.permissionStore(counter: TestAuthorizationEpochCounter())
      let project = ComputerMCPCore.RegisteredProject(
        id: "event-project", displayName: "Event fixture", rootPath: fixture.root.path)
      try database.saveProject(project)
      var permissions = try eventPermissions(fixture.server.id)
      try permissions.set(.granted(.write), for: .project(project.id))
      let grant = ProfileGrant(
        id: .chatGPTObserve, permissions: permissions, fullAccess: true,
        allowedCallers: [.localMCP])
      try database.bootstrapPermissionProfiles([grant])
      let service = GatewayPermissionService(store: store, policyReader: TestManagedPolicyReader())
      self.service = service
      let directory = fixture.root.appendingPathComponent("executions")
      self.directory = directory
      let coordinator = try ExecutionRevocationCoordinator(
        store: store, launcher: launcher, directory: directory,
        refreshPolicy: { _ = try service.reconcilePolicy(notify: false) })
      self.coordinator = coordinator
      try await coordinator.recover()
      let ownership = try #require(database.mcpProcessOwnershipRoot).resolvingSymlinksInPath()
      var rules: Set<PathRule> = try [
        .init(root: CanonicalPath(fixture.root.path), kind: .userData),
        .init(root: CanonicalPath(directory.path), kind: .hostData),
        .init(root: CanonicalPath(ownership.path), kind: .hostData),
      ]
      rules.insert(
        .init(
          root: try CanonicalPath(#require(database.providerContainerRoot).path), kind: .hostData))
      for path in ["/System", "/Library", "/usr", "/bin", "/sbin", "/Applications"] {
        rules.insert(try .init(root: CanonicalPath(path), kind: .systemOrApplication))
      }
      try service.configureEnvironment(
        PathEnvironmentSnapshot(
          projects: [.init(id: project.id, root: CanonicalPath(fixture.root.path))], rules: rules),
        trustedHosts: [], expectedProjects: database.projects(), expectedConfigurationRevision: nil)
      var context = ExecutionContext(
        caller: .localMCP, profileID: grant.id, projectID: project.id,
        trustedPrincipalID: "verified-event-fixture")
      let session = GatewayControlSession(
        principalID: "verified-event-fixture", profileID: grant.id, caller: .localMCP,
        database: database, profile: .init(grant: grant, persisted: true),
        permissionService: service)
      self.session = session
      let review = try GatewayProviderReview(
        server: fixture.server, configuration: database.configurationState())
      let owner = try GatewayPermissionOwner(
        context: .init(
          caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "event-owner"),
        validate: {})
      let view = try service.view(owner: owner)
      _ = try service.approveProvider(
        review, permissions: permissions, fullAccess: true, owner: owner,
        expectedProviderRevision: nil, expectedRevision: view.revision,
        expectedEpoch: #require(view.epoch))
      _ = try session.approveFullAccess(expectedRevision: session.revision)
      context.controlSession = session
      subject = try GatewayPermissionSubject(context: context)
      hostContext = MCPHostContext(
        runtimeID: UUID(), context: context, projectID: project.id,
        rootURL: fixture.root, readOnly: false, processOwnershipRoot: ownership,
        executionDatabase: database)
    }

    func connect(_ client: MCPProxyClient) async throws -> InvocationContext {
      let context = try await invocation(
        tool: "mcp.tools.call",
        arguments: .object(["server": .string(fixture.server.id), "tool": .string("stream")]))
      let server = fixture.server
      _ = try await calls.perform {
        try client.callTool(
          server: server, name: "stream", arguments: .object([:]), context: context)
      }
      return context
    }

    func stream(_ client: MCPProxyClient) async throws -> JSONValue {
      let context = try await invocation(
        tool: "mcp.tools.call",
        arguments: .object([
          "server": .string(fixture.server.id), "tool": .string("stream"),
          "arguments": .object([:]),
        ]))
      let prepared = try #require(context.executionAuthority as? PreparedExecutionContext)
      defer { try? prepared.finishAdmission() }
      let server = fixture.server
      return try await calls.perform {
        try client.callTool(
          server: server, name: "stream", arguments: .object([:]), context: context)
      }
    }

    private func invocation(tool: String, arguments: JSONValue) async throws -> InvocationContext {
      let requirements = try InvocationRequirements(
        actions: [
          .init(requirement: .init(.mcpServer(fixture.server.id), .read)),
          .init(requirement: .init(.project("event-project"), .write)),
        ], paths: [.init(path: CanonicalPath(fixture.root.path), operation: .write)],
        mode: .fullAccess(.standing), sandboxProjectID: "event-project")
      let decision = try service.admit(
        subject: subject, tool: tool, projectID: "event-project",
        argumentsDigest: MCPExecutionRecord.digest(arguments), requirements: requirements,
        connectionID: session.id)
      guard case .allowed(let authorization) = decision else {
        throw PermissionModelError.invalidAuthorization
      }
      let scratch = directory.appendingPathComponent(authorization.id.uuidString)
      try FileManager.default.createDirectory(
        at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      let binding = try service.authorizeProviderExecution(
        review: GatewayProviderReview(
          server: fixture.server, configuration: database.configurationState()),
        registrationID: fixture.server.id, caller: authorization, retryIDs: [])
      let prepared = try await coordinator.prepare(
        authorizationID: authorization.id,
        context: .init(
          directory: SandboxPath(fixture.root.path), temporaryDirectory: SandboxPath(scratch.path),
          purpose: .pluginProgram,
          providerContainer: database.prepareProviderContainer(binding.identity)),
        connectionID: session.id, provider: binding,
        providerWorkingDirectory: SandboxPath(fixture.root.path),
        validateProvider: { [service] in try service.validateProviderExecution(binding) })
      lock.withLock { contexts.append(prepared) }
      return InvocationContext(session: session, executionAuthority: prepared)
    }

    func shutdown() async {
      for context in lock.withLock({ contexts }) { try? context.finishAdmission() }
      session.end()
      try? await coordinator.reconcile()
    }
  }

  /// The exact isolated Python program never forks or evaluates tool-supplied code.
  /// Its one native root therefore owns the complete protocol execution.
  private struct EventExecutionPlatform: ExecutionPlatform {
    let root: URL
    let script: URL
    let starts: URL
    let executable: String
    let program: String
    private let base: DarwinExecutionPlatform

    init(root: URL, script: URL, starts: URL, executable: String, program: String) throws {
      self.root = root
      self.script = script
      self.starts = starts
      self.executable = executable
      self.program = program
      base = DarwinExecutionPlatform(
        bootstrapExecutable: try nativeGatewayTestExecutable().deletingLastPathComponent()
          .appendingPathComponent("computer-mcp-execution-bootstrap"))
    }

    var supportsRecovery: Bool { true }
    var bootSessionID: String? { base.bootSessionID }
    func supportsDurableOwnership(sandboxed: Bool) -> Bool { !sandboxed }

    func start(
      _ command: ExecutionCommand, sandbox: SandboxConfiguration?, method: ExecutionLaunchMethod,
      input: Int32, output: Int32, error: Int32,
      bindOwnership: @Sendable (any ExecutionOwnership) -> Void
    ) async throws -> any ExecutionOwnership {
      guard try PreparedExecutionContext.current() != nil, sandbox == nil,
        command.executable.value == executable,
        command.arguments == [script.path, starts.path],
        try ProjectPathResolver.canonicalProject(URL(fileURLWithPath: command.directory.value))
          .path == root.path,
        command.directoryDescriptor == nil,
        command.inheritedDescriptors.isEmpty,
        try String(contentsOf: script, encoding: .utf8) == program
      else {
        throw ExecutionEnvironmentError.unavailable(
          "Only the fixed event protocol fixture may start")
      }
      let controlled = ExecutionCommand(
        executable: command.executable, arguments: ["-I"] + command.arguments,
        directory: command.directory,
        environment: command.environment.filter {
          !$0.key.hasPrefix("DYLD_") && !$0.key.hasPrefix("PYTHON")
        })
      let ownership = try await base.start(
        controlled, sandbox: nil, method: method, input: input, output: output, error: error,
        bindOwnership: { bindOwnership(EventProcessOwnership(base: $0)) })
      return EventProcessOwnership(base: ownership)
    }

    func recover(_ state: ExecutionRecoveryState) async throws -> any ExecutionOwnership {
      guard !state.sandboxed, state.backend == EventProcessOwnership.backend,
        state.root.processID > 0, state.root.identity > 0
      else { throw ExecutionEnvironmentError.unavailable("Invalid event fixture recovery") }
      try await base.interrupt([state.root])
      return EventCompletedOwnership(state: state)
    }

    func interrupt(_ members: [ExecutionMember]) async throws { try await base.interrupt(members) }

    func releaseRecovery(_ state: ExecutionRecoveryState) throws {
      guard !state.sandboxed, state.backend == EventProcessOwnership.backend else {
        throw ExecutionEnvironmentError.unavailable("Invalid event fixture recovery")
      }
    }
  }

  private struct EventProcessOwnership: ExecutionOwnership {
    static let backend = "event-cursor-fixture"
    let base: any ExecutionOwnership
    func recoveryState() throws -> ExecutionRecoveryState {
      let state = try base.recoveryState()
      return .init(root: state.root, sandboxed: false, backend: Self.backend)
    }
    func beforeStart(_ handler: @escaping @Sendable (ExecutionMember) throws -> Void) {
      base.beforeStart(handler)
    }
    func members() async throws -> [ExecutionMember] { try await base.members() }
    func onCancellation(_ handler: @escaping @Sendable () -> Void) { base.onCancellation(handler) }
    func cancel(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit {
      try await base.cancel(until: deadline)
    }
    func wait(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit {
      try await base.wait(until: deadline)
    }
  }

  private struct EventCompletedOwnership: ExecutionOwnership {
    let state: ExecutionRecoveryState
    func recoveryState() throws -> ExecutionRecoveryState { state }
    func beforeStart(_ handler: @escaping @Sendable (ExecutionMember) throws -> Void) {}
    func members() async throws -> [ExecutionMember] { [] }
    func onCancellation(_ handler: @escaping @Sendable () -> Void) {}
    func cancel(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit {
      .init(status: 128 + SIGTERM, signal: SIGTERM)
    }
    func wait(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit {
      .init(status: 128 + SIGTERM, signal: SIGTERM)
    }
  }
#endif
