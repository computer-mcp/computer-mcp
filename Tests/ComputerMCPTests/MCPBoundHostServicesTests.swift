import CryptoKit
import Foundation
import MCP
import Testing

@testable import ComputerMCP

@Suite(.serialized, .timeLimit(.minutes(1)))
struct MCPBoundHostServicesTests {
  @Test
  func genericHostCallbackRequiresWorkspaceWhenSelectionIsAmbiguous() async throws {
    let fixture = try HostAuthorityFixture(additionalWorkspace: true)
    defer { fixture.remove() }
    let tool = try #require(fixture.runtime.listTools().first { $0.name == "mcp.tools.call" })
    let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
    #expect(properties["workspace_id"]?.objectValue?["type"] == .string("string"))
    do {
      _ = try await fixture.genericRelease(workspaceID: nil)
      Issue.record("An ambiguous workspace must be rejected before invoking the plugin.")
    } catch {
      #expect(String(describing: error).contains("workspace_required"))
    }
    await fixture.close()
  }

  @Test(arguments: [false, true])
  func genericReleaseBindsHostCallbackWorkspace(explicitWorkspace: Bool) async throws {
    let fixture = try HostAuthorityFixture()
    defer { fixture.remove() }
    let target = try fixture.approved(threadID: "thread-1")
    let result = try await fixture.genericRelease(
      workspaceID: explicitWorkspace ? "scope" : nil)
    #expect(result.objectValue?["isError"] == .bool(false))
    #expect(try fixture.database.codexElevationGrant(id: target.id)?.state == .invalidated)
    await fixture.close()
  }

  @Test(arguments: ["release", "wrong-thread", "wrong-method", "no-invocation"], [false, true])
  func threadReleaseInvalidatesUnusedGrantsOnlyWithinItsLiveScope(
    mode: String, persistedProfile: Bool
  ) async throws {
    let fixture = try HostAuthorityFixture(persistedProfile: persistedProfile)
    defer { fixture.remove() }
    let target = try fixture.approved(threadID: "thread-1")
    let otherThread = try fixture.approved(threadID: "thread-2")
    let otherConnection = try fixture.approved(threadID: "thread-1", connection: "other")
    let unbound = try fixture.approved(threadID: nil)
    let arguments: [String: JSONValue] = [
      "runtime_ids": .array([]), "thread_id": .string("thread-1"),
      "reason": .string("Thread released"),
    ]
    let result: JSONValue
    if mode == "no-invocation" {
      result = try await fixture.direct("host.elevation.invalidate", arguments)
    } else {
      result = try await fixture.during(
        mode == "wrong-method" ? "codex.app.turn.start" : "codex.app.thread.release",
        ["thread_id": .string(mode == "wrong-thread" ? "thread-2" : "thread-1")]
      ) { service in
        try await .encoded(service.call(name: "host.elevation.invalidate", arguments: arguments))
      }
    }
    #expect(result.objectValue?["isError"] == .bool(mode != "release"))
    #expect(
      try fixture.database.codexElevationGrant(id: target.id)?.state
        == (mode == "release" ? .invalidated : .approved))
    for grant in [otherThread, otherConnection, unbound] {
      #expect(try fixture.database.codexElevationGrant(id: grant.id)?.state == .approved)
    }
    await fixture.close()
  }

  @Test
  func completedProvisionInvocationsDoNotExhaustTheConnection() async throws {
    let fixture = try HostAuthorityFixture(worktrees: true)
    defer { fixture.remove() }
    for index in 0..<129 {
      let receipt = try fixture.worktreeReceipt()
      let result = try await fixture.during(
        "codex.worktree.provision.perform",
        [
          "plan_id": receipt["id"]!, "expected_revision": .number(1),
          "confirm_provision": .bool(true),
        ]
      ) { service in
        try await .encoded(
          service.call(name: "host.workspaces.register", arguments: ["worktree": .object(receipt)]))
      }
      try #require(
        result.objectValue?["isError"] == .bool(false), "Provision \(index + 1): \(result)")
      let workspaceID = try #require(receipt["workspace_id"]?.stringValue)
      #expect(try fixture.database.derivedWorkspaceRegistration(id: workspaceID) != nil)
    }
    await fixture.close()
  }

  @Test(arguments: [false, true])
  func registrationRollbackRequiresItsOriginalLiveInvocation(laterInvocation: Bool) async throws {
    let fixture = try HostAuthorityFixture(worktrees: true)
    defer { fixture.remove() }
    let receipt = try fixture.worktreeReceipt()
    let args: [String: JSONValue] = [
      "plan_id": receipt["id"]!, "expected_revision": .number(1),
      "confirm_provision": .bool(true),
    ]
    let registered = try await fixture.during("codex.worktree.provision.perform", args) { service in
      let result = try await service.call(
        name: "host.workspaces.register", arguments: ["worktree": .object(receipt)])
      try #require(result.isError == false)
      if laterInvocation { return try .encoded(result) }
      return try await .encoded(
        service.call(name: "host.workspaces.unregister", arguments: ["worktree": .object(receipt)]))
    }
    #expect(registered.objectValue?["isError"] == .bool(false))
    if laterInvocation {
      let replay = try await fixture.during("codex.worktree.provision.perform", args) { service in
        try await .encoded(
          service.call(
            name: "host.workspaces.unregister", arguments: ["worktree": .object(receipt)]))
      }
      #expect(replay.objectValue?["isError"] == .bool(true))
    }
    let workspaceID = try #require(receipt["workspace_id"]?.stringValue)
    #expect((try fixture.database.workspace(id: workspaceID) != nil) == laterInvocation)
    await fixture.close()
  }

  @Test(arguments: ["no-invocation", "wrong-thread", "extra-owner", "caller-time", "wrong-action"])
  func activationCannotInventAnInvocationOrScope(attack: String) async throws {
    let fixture = try HostAuthorityFixture()
    defer { fixture.remove() }
    let grant = try fixture.approved(threadID: "thread-1")
    var arguments: [String: JSONValue] = [
      "runtime_id": .string("runtime"), "action": .string("turn-start"),
      "thread_id": .string("thread-1"),
    ]
    if attack == "wrong-thread" { arguments["thread_id"] = .string("thread-other") }
    if attack == "extra-owner" { arguments["profile_id"] = .string("local-admin") }
    if attack == "caller-time" { arguments["now"] = .number(1) }
    if attack == "wrong-action" { arguments["action"] = .string("thread-start") }
    let result: JSONValue
    if attack == "no-invocation" {
      result = try await fixture.direct("host.elevation.claim", arguments)
    } else {
      let args = arguments
      result = try await fixture.during("codex.app.turn.start", ["thread_id": .string("thread-1")])
      { service in
        try await .encoded(service.call(name: "host.elevation.claim", arguments: args))
      }
    }
    #expect(result.objectValue?["isError"] == .bool(true))
    let stored = try #require(try fixture.database.codexElevationGrant(id: grant.id))
    #expect(stored.state == .approved && stored.inFlightClaimID == nil)
    await fixture.close()
  }

  @Test
  func claimCannotBeReplayedInLaterOrDifferentNativeInvocation() async throws {
    let fixture = try HostAuthorityFixture()
    defer { fixture.remove() }
    let grant = try fixture.approved(threadID: nil)
    let claimed = try await fixture.during("codex.app.thread.start") { service in
      try await .encoded(
        service.call(
          name: "host.elevation.claim",
          arguments: ["runtime_id": .string("runtime"), "action": .string("thread-start")]))
    }
    let id = try #require(fixture.payload(claimed)["id"]?.stringValue)
    for runtime in ["other-runtime", "runtime"] {
      let result = try await fixture.during("codex.app.thread.start") { service in
        try await .encoded(
          service.call(
            name: "host.elevation.commit",
            arguments: [
              "claim_id": .string(id), "runtime_id": .string(runtime),
              "thread_id": .string("thread-new"),
            ]))
      }
      #expect(result.objectValue?["isError"] == .bool(true))
    }
    #expect(try fixture.database.codexElevationGrant(id: grant.id)?.inFlightClaimID == id)
    let invalidated = try await fixture.direct(
      "host.elevation.invalidate_claim",
      ["claim_id": .string(id), "reason": .string("Original start failed")])
    #expect(invalidated.objectValue?["isError"] == .bool(false))
    #expect(try fixture.database.codexElevationGrant(id: grant.id)?.state == .invalidated)
    await fixture.close()
  }

  @Test
  func closingConnectionInvalidatesOnlyItsOwnCommittedGrant() async throws {
    let fixture = try HostAuthorityFixture()
    defer { fixture.remove() }
    let grant = try fixture.approved(threadID: nil)
    let unrelated = try fixture.approved(threadID: nil, connection: "other-connection")
    let result = try await fixture.during("codex.app.thread.start") { service in
      let response = try await service.call(
        name: "host.elevation.claim",
        arguments: ["runtime_id": .string("runtime"), "action": .string("thread-start")])
      let id = try #require(
        response.structuredContent?.objectValue?["result"]?.objectValue?["id"]?.stringValue)
      return try await .encoded(
        service.call(
          name: "host.elevation.commit",
          arguments: [
            "claim_id": .string(id), "runtime_id": .string("runtime"),
            "thread_id": .string("thread-bound"),
          ]))
    }
    #expect(result.objectValue?["isError"] == .bool(false))
    #expect(try fixture.database.codexElevationGrant(id: grant.id)?.state == .active)
    await fixture.close()
    #expect(try fixture.database.codexElevationGrant(id: grant.id)?.state == .invalidated)
    #expect(try fixture.database.codexElevationGrant(id: unrelated.id)?.state == .approved)
  }

  @Test
  func unsuccessfulGrantCleanupRemainsUnconfirmedAndCanBeRetried() async throws {
    let fixture = try HostAuthorityFixture()
    defer { fixture.remove() }
    let grant = try fixture.approved(threadID: nil)
    _ = try await fixture.during("codex.app.thread.start") { service in
      let response = try await service.call(
        name: "host.elevation.claim",
        arguments: ["runtime_id": .string("runtime"), "action": .string("thread-start")])
      let id = try #require(
        response.structuredContent?.objectValue?["result"]?.objectValue?["id"]?.stringValue)
      return try await .encoded(
        service.call(
          name: "host.elevation.commit",
          arguments: [
            "claim_id": .string(id), "runtime_id": .string("runtime"),
            "thread_id": .string("thread-bound"),
          ]))
    }
    _ = try fixture.database.updateCodexElevationGrant(id: grant.id) { value in
      value.consumedRuntimeIDs = ["independent-runtime"]
    }
    await fixture.service.close()
    #expect(await !fixture.service.cleanupConfirmed)
    #expect(try fixture.database.codexElevationGrant(id: grant.id)?.state == .active)
    _ = try fixture.database.updateCodexElevationGrant(id: grant.id) { value in
      value.consumedRuntimeIDs = ["runtime"]
    }
    await fixture.service.close()
    #expect(await fixture.service.cleanupConfirmed)
    #expect(try fixture.database.codexElevationGrant(id: grant.id)?.state == .invalidated)
    await fixture.close()
  }

  @Test
  func unrelatedRecentGrantsDoNotConsumeTheRequestersPage() async throws {
    let fixture = try HostAuthorityFixture()
    defer { fixture.remove() }
    let own = try fixture.approved(threadID: nil)
    _ = try fixture.approved(threadID: nil, connection: "newer-other-connection")
    let owner = CodexRuntimeOwner(
      workspaceID: "scope", profileID: "chatgpt-operate",
      caller: "secure-tunnel", transport: "gateway_socket", socketConnectionID: "connection",
      tunnelInstanceID: nil, tunnelProfileID: nil)
    let grants = try CodexElevationGrantService.visibleGrants(
      owner: owner,
      database: fixture.database, limit: 1)
    #expect(grants.map(\.id) == [own.id])
    #expect(
      try CodexElevationGrantService.visibleGrants(
        owner: nil,
        database: fixture.database, limit: 1
      ).isEmpty)
    await fixture.close()
  }

  @Test
  func invocationEndsOnBothSuccessAndError() async throws {
    let fixture = try HostAuthorityFixture()
    defer { fixture.remove() }
    for fails in [false, true] {
      if fails {
        await #expect(throws: (any Error).self) {
          try await fixture.during("codex.app.thread.start") { _ in
            throw MCPHostServiceError.denied("Fixture failure")
          }
        }
      } else {
        _ = try await fixture.during("codex.app.thread.start") { _ in .object([:]) }
      }
      let result = try await fixture.direct(
        "host.elevation.claim",
        ["runtime_id": .string("runtime"), "action": .string("thread-start")])
      #expect(result.objectValue?["isError"] == .bool(true))
    }
    await fixture.close()
  }

  @Test
  func privateServiceSurfaceIsNotExposedUpstreamAndDoesNotApproveGrants() async throws {
    let fixture = try HostAuthorityFixture()
    defer { fixture.remove() }
    #expect(try !fixture.runtime.listTools().contains { $0.name.hasPrefix("host.") })
    #expect(
      !MCPBoundHostServices.tools.contains {
        $0.name.contains("approve") || $0.name.contains("request")
      })
    let result = try await fixture.direct("host.elevation.approve", ["id": .string("unowned")])
    #expect(result.objectValue?["isError"] == .bool(true))
    await fixture.close()
  }

  @Test
  func expiredGrantCannotCommitUsingACallerSuppliedEarlierClock() async throws {
    let fixture = try HostAuthorityFixture()
    defer { fixture.remove() }
    let grant = try fixture.approved(threadID: nil)
    let database = fixture.database
    let result = try await fixture.during("codex.app.thread.start") { service in
      let claimed = try await service.call(
        name: "host.elevation.claim",
        arguments: ["runtime_id": .string("runtime"), "action": .string("thread-start")])
      let id = try #require(
        claimed.structuredContent?.objectValue?["result"]?.objectValue?["id"]?.stringValue)
      _ = try database.updateCodexElevationGrant(id: grant.id) { record in
        record.expiresAt = Date().addingTimeInterval(-1)
      }
      return try await .encoded(
        service.call(
          name: "host.elevation.commit",
          arguments: [
            "claim_id": .string(id), "runtime_id": .string("runtime"),
            "thread_id": .string("thread"),
          ]))
    }
    #expect(result.objectValue?["isError"] == .bool(true))
    #expect(try fixture.database.codexElevationGrant(id: grant.id)?.state == .expired)
    await fixture.close()
  }
}

/// Explicit protocol peer substitute for negative host authorization tests.
/// The separate opt-in integration suite uses the real compiled adapter.
private final class HostAuthorityFixture: @unchecked Sendable {
  let root: URL
  let database: GatewayDatabase
  let runtime: GatewayRuntime
  let service: MCPBoundHostServices
  let peer = HostServiceProbe()
  init(
    worktrees: Bool = false, persistedProfile: Bool = true, additionalWorkspace: Bool = false
  ) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    database = try GatewayDatabase(inMemory: ())
    let workspace = RegisteredWorkspace(id: "scope", displayName: "Fixture", rootPath: root.path)
    try database.saveWorkspace(workspace)
    var workspaces = [workspace]
    if additionalWorkspace {
      let other = RegisteredWorkspace(id: "other", displayName: "Other", rootPath: root.path)
      try database.saveWorkspace(other)
      workspaces.append(other)
    }
    let caps = ["mcp.tools.call", "operations.prepare", "operations.commit"]
    if persistedProfile {
      try database.saveProfile(
        .init(
          id: .chatGPTOperate, capabilityIDs: Set(caps), workspaceIDs: ["scope"],
          allowedCallers: [.secureTunnel]))
    }
    runtime = try GatewayRuntime(
      configuration: .init(
        runtime: .init(caller: .secureTunnel, profileID: .chatGPTOperate),
        profiles: [
          .init(
            id: .chatGPTOperate, capabilities: caps, workspaces: ["scope"],
            allowedCallers: [.secureTunnel])
        ],
        mcp: .init(servers: [
          .init(
            id: "probe", transport: .stdio, command: "/bin/cat", exposure: .reexport,
            prefix: "adapter", allowedTools: HostServiceProbe.methods,
            toolRisks: Dictionary(
              uniqueKeysWithValues: HostServiceProbe.methods.map { ($0, .workspaceWrite) }),
            hostServices: true)
        ])),
      context: .init(
        caller: .secureTunnel, profileID: .chatGPTOperate,
        transportTrace: .init(transport: "gateway_socket", socketConnectionID: "connection")),
      database: database, registeredWorkspaces: workspaces, mcpClient: peer)
    let captured = try #require(peer.context)
    if worktrees {
      let managed = root.resolvingSymlinksInPath().appendingPathComponent("managed")
      try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: false)
      let scoped = MCPHostContext(
        runtimeID: captured.runtimeID,
        context: .init(
          caller: captured.caller, profileID: captured.profileID,
          transportTrace: captured.transportTrace),
        workspaceID: captured.workspace.id,
        rootURL: URL(fileURLWithPath: captured.workspace.rootPath),
        readOnly: captured.readOnly, tools: captured.tools, managedWorkspaceRoot: managed)
      service = MCPBoundHostServices(
        database: database, directory: try #require(captured.tools), context: scoped,
        origin: "probe",
        commandRunner: HostWorktreeGitStub(source: captured.workspace.rootPath))
    } else {
      service = try #require(try runtime.makeHostServices(context: captured, origin: "probe"))
    }
  }
  func worktreeReceipt() throws -> [String: JSONValue] {
    let id = UUID().uuidString.lowercased()
    let source = root.resolvingSymlinksInPath()
    let component = SHA256.hash(data: Data("scope".utf8)).prefix(12).map {
      String(format: "%02x", $0)
    }.joined()
    let path = source.appendingPathComponent("managed").appendingPathComponent(component)
      .appendingPathComponent(id)
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    return [
      "id": .string(id), "workspace_id": .string("codex-worktree-" + id),
      "source_workspace_id": .string("scope"), "source_repository_root": .string(source.path),
      "git_common_directory": .string(source.appendingPathComponent(".git").path),
      "path": .string(path.path), "branch": .string("fixture-" + id),
      "parent_lease_id": .string("fixture-parent"), "profile_id": .string("chatgpt-operate"),
      "caller": .string("secure-tunnel"), "state": .string("provisioning"), "revision": .number(2),
    ]
  }
  func approved(threadID: String?, connection: String = "connection") throws
    -> CodexElevationGrantRecord
  {
    let grant = try CodexElevationGrantService.request(
      owner: .init(
        workspaceID: "scope", profileID: "chatgpt-operate", caller: "secure-tunnel",
        transport: "gateway_socket",
        socketConnectionID: connection, tunnelInstanceID: nil, tunnelProfileID: nil),
      database: database, threadID: threadID, mode: .boundedTime,
      reason: "Fixture authority", maximumDurationSeconds: 300, maximumTurnCount: nil)
    return try CodexElevationGrantService.approve(
      id: grant.id,
      owner: .init(
        workspaceID: "scope", profileID: "local-admin", caller: "local-cli", transport: "fixture",
        socketConnectionID: nil, tunnelInstanceID: nil, tunnelProfileID: nil), database: database)
  }
  func during(
    _ method: String, _ arguments: [String: JSONValue] = [:],
    _ body: @escaping @Sendable (MCPBoundHostServices) async throws -> JSONValue
  ) async throws -> JSONValue {
    let service = service
    peer.setHandler { try await body(service) }
    defer { peer.setHandler(nil) }
    var args = arguments
    args["workspace_id"] = .string("scope")
    return try await runtime.callToolAsync(name: "adapter." + method, arguments: .object(args))
  }
  func direct(_ name: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
    try await .encoded(service.call(name: name, arguments: arguments))
  }
  func genericRelease(workspaceID: String?) async throws -> JSONValue {
    let service = service
    peer.setHandler {
      try await .encoded(
        service.call(
          name: "host.elevation.invalidate",
          arguments: [
            "runtime_ids": .array([]), "thread_id": .string("thread-1"),
            "reason": .string("Thread released"),
          ]))
    }
    defer { peer.setHandler(nil) }
    var arguments: [String: JSONValue] = [
      "server": .string("probe"), "tool": .string("codex.app.thread.release"),
      "arguments": .object(["thread_id": .string("thread-1")]),
    ]
    if let workspaceID { arguments["workspace_id"] = .string(workspaceID) }
    return try await runtime.callToolAsync(name: "mcp.tools.call", arguments: .object(arguments))
  }
  func payload(_ value: JSONValue) -> [String: JSONValue] {
    value.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue ?? [:]
  }
  func close() async {
    await service.close()
    await runtime.shutdown()
  }
  func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class HostServiceProbe: DownstreamMCPClient, @unchecked Sendable {
  static let methods = [
    "codex.app.thread.start", "codex.app.turn.start", "codex.diagnostics.snapshot",
    "codex.app.thread.release",
    "codex.worktree.provision.perform",
  ]
  private let lock = NSLock()
  private var captured: MCPHostContext?
  private var handler: (@Sendable () async throws -> JSONValue)?
  var context: MCPHostContext? { lock.withLock { captured } }
  func setHandler(_ value: (@Sendable () async throws -> JSONValue)?) {
    lock.withLock { handler = value }
  }
  func makeScopedClient(
    workingDirectory: URL, environment: [String: String], hostContext: MCPHostContext?
  ) -> any DownstreamMCPClient {
    lock.withLock { captured = hostContext }
    return self
  }
  func listTools(server: MCPServerConfig) throws -> [MCPTool] {
    Self.methods.map { .init(name: $0, description: "Fixture", inputSchema: .object([:])) }
  }
  func callTool(server: MCPServerConfig, name: String, arguments: JSONValue) throws -> JSONValue {
    guard let handler = lock.withLock({ handler }) else {
      throw MCPHostServiceError.denied("Fixture handler absent.")
    }
    let box = HostProbeResult()
    let ready = DispatchSemaphore(value: 0)
    let task = Task {
      do { box.set(.success(try await handler())) } catch { box.set(.failure(error)) }
      ready.signal()
    }
    guard ready.wait(timeout: .now() + 10) == .success else {
      task.cancel()
      throw MCPHostServiceError.denied("Fixture callback timed out.")
    }
    return try box.get()
  }
  func listResources(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func listResourceTemplates(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func readResource(server: MCPServerConfig, uri: String) throws -> JSONValue { .null }
  func listPrompts(server: MCPServerConfig, cursor: String?) throws -> JSONValue { .null }
  func getPrompt(server: MCPServerConfig, name: String, arguments: [String: String]?) throws
    -> JSONValue
  { .null }
}

/// Isolates host invocation lifetime from Git execution; packaged integration tests use real Git.
private struct HostWorktreeGitStub: CommandRunning {
  let source: String
  func run(
    executable: String, arguments: [String], workingDirectory: URL?, environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult {
    let output: String
    switch arguments {
    case ["rev-parse", "--show-toplevel"]: output = try #require(workingDirectory).path
    case ["rev-parse", "--git-common-dir"]: output = source + "/.git"
    default: throw MCPHostServiceError.denied("Unexpected fixture Git command.")
    }
    return .init(
      executable: executable, arguments: arguments, exitCode: 0, timedOut: false,
      stdout: output + "\n", stderr: "", stdoutTruncated: false, stderrTruncated: false)
  }
  func runData(
    executable: String, arguments: [String], workingDirectory: URL?, environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandDataResult {
    throw MCPHostServiceError.denied("Unexpected fixture binary command.")
  }
}
private final class HostProbeResult: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Result<JSONValue, any Error>?
  func set(_ value: Result<JSONValue, any Error>) { lock.withLock { self.value = value } }
  func get() throws -> JSONValue { try lock.withLock { try value!.get() } }
}
