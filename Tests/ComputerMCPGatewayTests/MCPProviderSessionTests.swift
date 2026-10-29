import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPSandbox
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPGateway
@testable import ComputerMCPPermissions
@testable import ComputerMCPProcess

#if os(macOS)
  import ComputerMCPDarwinTestSupport
  import Darwin
#endif

@Suite(.serialized, .timeLimit(.minutes(1)))
struct MCPProviderSessionTests {
  @Test func standingReuseRequiresBothCompleteBasesAndSource() throws {
    let root = try ScopedTemporaryDirectory()
    let a = try SessionAuthority(client: "a")
    let same = try SessionAuthority(client: "a")
    let b = try SessionAuthority(client: "b")
    let project = try SessionAuthority(client: "a", project: "other")
    let source = try SessionAuthority(client: "a", digest: String(repeating: "b", count: 64))
    let revision = try SessionAuthority(client: "a", generation: 2)
    let providerRevision = try SessionAuthority(client: "a", providerGeneration: 2)
    let key = try MCPProviderSessionAuthority(a.prepared(root.url))
    #expect(key == (try MCPProviderSessionAuthority(same.prepared(root.url))))
    for different in [b, project, source, revision, providerRevision] {
      #expect(key != (try MCPProviderSessionAuthority(different.prepared(root.url))))
    }
    let once = try SessionAuthority(client: "a", once: true)
    let retry = try SessionAuthority(binding: once.binding)
    #expect(
      try MCPProviderSessionAuthority(once.prepared(root.url))
        != MCPProviderSessionAuthority(retry.prepared(root.url)))
  }

  @Test func uncertainCleanupBlocksOnlyItsDelegationAndLegacyRemainsConservative() throws {
    let root = try ScopedTemporaryDirectory()
    let storage = root.url.appendingPathComponent("ownership")
    let a = try SessionAuthority(client: "a")
    let b = try SessionAuthority(client: "b")
    let owner = try MCPProcessOwnership.acquire(
      root: storage, project: root.url, registration: "provider", provider: a.binding)
    try owner.finish(confirmed: false)
    #expect(throws: (any Error).self) {
      try MCPProcessOwnership.acquire(
        root: storage, project: root.url, registration: "provider", provider: a.binding)
    }
    let independent = try MCPProcessOwnership.acquire(
      root: storage, project: root.url, registration: "provider", provider: b.binding)
    try independent.finish(confirmed: true)
    #expect(
      try MCPProcessOwnership.inspect(
        root: storage, project: root.url, registration: "provider"
      ).count == 1)
    #expect(throws: (any Error).self) {
      try MCPProcessOwnership.acquire(root: storage, project: root.url, registration: "provider")
    }
    let legacyStorage = root.url.appendingPathComponent("legacy")
    let legacy = try MCPProcessOwnership.acquire(
      root: legacyStorage, project: root.url, registration: "provider")
    try legacy.finish(confirmed: false)
    #expect(throws: (any Error).self) {
      try MCPProcessOwnership.acquire(
        root: legacyStorage, project: root.url, registration: "provider", provider: b.binding)
    }
  }

  @Test func callbackDirectoryCannotSelectAnotherClientsOrOneTimeInvocation() throws {
    let root = try ScopedTemporaryDirectory()
    let directory = MCPHostToolDirectory()
    let a = try SessionAuthority(client: "a").prepared(root.url)
    let b = try SessionAuthority(client: "b").prepared(root.url)
    let once = try SessionAuthority(client: "a", once: true).prepared(root.url)
    for execution in [a, b, once] {
      let invocation = MCPHostInvocation(
        id: UUID(), requestLeaseID: UUID(), admission: nil,
        reference: .init(serverID: "provider", toolName: "pid"),
        admittedCapability: .init(id: "fixture", risk: .readOnly, requirement: .none),
        upstreamName: "fixture", arguments: [:],
        context: .init(caller: .localMCP, profileID: .localAdmin, projectID: "project"),
        authorizationRevision: 1, providerExecution: execution)
      try directory.begin(invocation, store: nil)
    }
    for execution in [a, b, once] {
      let selected = directory.active(projectID: "project", origin: "provider", provider: execution)
      #expect(selected.count == 1 && selected.first?.providerExecution === execution)
    }
  }

  #if os(macOS)
    @Test(.nativeIntegration)
    func concurrentCallsReuseMatchingAuthorityAndSeparateClientsAndOneTimeExecutions() async throws
    {
      let f = try SessionFixture()
      defer { f.remove() }
      let a = try SessionAuthority(client: "a")
      let same = try SessionAuthority(client: "a")
      let b = try SessionAuthority(client: "b")
      let once = try SessionAuthority(client: "a", once: true)
      let nextOnce = try SessionAuthority(binding: once.binding)
      let client = f.client()
      do {
        async let first = f.call(client, authority: a)
        async let second = f.call(client, authority: same)
        let (firstPID, secondPID) = try await (first, second)
        #expect(firstPID == secondPID)
        #expect(a.retained == 1 && same.retained == 1)
        let bPID = try await f.call(client, authority: b)
        let oncePID = try await f.call(client, authority: once)
        let nextPID = try await f.call(client, authority: nextOnce)
        #expect(Set([firstPID, bPID, oncePID, nextPID]).count == 4)
        #expect(a.starts + same.starts == 1)
        #expect(b.starts == 1 && once.starts == 1 && nextOnce.starts == 1)
        a.invalidate()
        same.invalidate()
        #expect(try await f.call(client, authority: b) == bPID)
        let replacement = try SessionAuthority(client: "a", generation: 2)
        #expect(try await f.call(client, authority: replacement) != firstPID)
        #expect(kill(firstPID, 0) == -1 && errno == ESRCH)
        #expect(kill(bPID, 0) == 0)
        await client.shutdown()
        #expect([a, same, b, once, nextOnce, replacement].allSatisfy { $0.retained == 0 })
        for pid in [bPID, oncePID, nextPID] { #expect(kill(pid, 0) == -1 && errno == ESRCH) }
      } catch {
        await client.shutdown()
        throw error
      }
    }

    @Test(.nativeIntegration)
    func discoveryUsesItsOwnProofAndChangedSourceCannotReturnTheCachedCatalog() async throws {
      let f = try SessionFixture()
      defer { f.remove() }
      let source = SessionSource(root: f.root)
      let client = f.client(source: source)
      let calls = BlockingOperationExecutor(label: "provider-discovery", serial: false)
      do {
        async let first = calls.perform { try client.listTools(server: f.server, context: .empty) }
        async let second = calls.perform { try client.listTools(server: f.server, context: .empty) }
        let catalogs = try await (first, second)
        #expect(catalogs.0.map(\.name) == ["pid"] && catalogs.1.map(\.name) == ["pid"])
        #expect(source.preparations == 1 && source.starts == 1)
        #expect(try client.cachedTools(server: f.server, context: .empty)?.map(\.name) == ["pid"])
        source.replace()
        #expect(try client.cachedTools(server: f.server, context: .empty) == nil)
        _ = try await calls.perform { try client.listTools(server: f.server, context: .empty) }
        #expect(source.preparations == 2 && source.starts == 2)
        #expect(throws: PermissionModelError.invalidAuthorization) {
          try client.callTool(
            server: f.server, name: "pid", arguments: .object([:]), context: .empty)
        }
        await client.shutdown()
      } catch {
        await client.shutdown()
        throw error
      }
    }
  #endif
}

/// Deterministic authority records isolate pool selection from ledger admission tests.
private final class SessionAuthority: ExecutionAuthorizing, @unchecked Sendable {
  static let limits = EffectiveExecutionLimits(
    timeMilliseconds: nil, outputBytes: 65_536, memoryBytes: nil, retentionSeconds: 60,
    retainedOutputBytes: 65_536, sources: [:])
  let executionID = UUID()
  let binding: ProviderExecutionBinding
  var authorizationIDs: Set<UUID> { binding.authorizationIDs }
  private let lock = NSLock()
  private var valid = true
  private var startCount = 0
  private var retainedCount = 0
  var starts: Int { lock.withLock { startCount } }
  var retained: Int { lock.withLock { retainedCount } }

  init(binding: ProviderExecutionBinding) throws { self.binding = binding }

  init(
    client: String? = nil, project: String = "project", generation: UInt64 = 1,
    providerGeneration: UInt64 = 1, digest: String = String(repeating: "a", count: 64),
    once: Bool = false
  ) throws {
    let identity = PluginIdentity.localServer("provider")
    let invocation = InvocationIdentity(
      principal: .plugin(identity), tool: "pid", projectID: client == nil ? nil : project,
      argumentsDigest: "fixture")
    let stable = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let provider = InvocationAuthorization(
      identity: .init(id: UUID(), generation: 1), invocation: invocation, requirements: .init(),
      basis: [.mode(.sandbox), .consent(.init(id: stable, generation: providerGeneration))])
    let caller = try client.map { client in
      let requirement = try PermissionRequirement(.mcpServer("provider"), .all)
      let basis = BasisIdentity(id: stable, generation: generation)
      var evidence: Set<AuthorizationBasis> = [
        .mode(.sandbox),
        .permission(
          .init(
            principal: .client(client), requirement: requirement, scope: .principal,
            pluginPurpose: nil, source: .standing(entry: requirement.permission, id: basis))),
      ]
      if once { evidence.insert(.request(.init(id: stable, generation: 1))) }
      return InvocationAuthorization(
        identity: .init(id: UUID(), generation: 1),
        invocation: .init(
          principal: .client(client), tool: "pid", projectID: project, argumentsDigest: "fixture"),
        requirements: .init(actions: [.init(requirement: requirement)]), basis: evidence)
    }
    binding = try .init(
      identity: identity, registrationID: "provider", sourceDigest: digest,
      providerAuthorization: provider, delegatingAuthorization: caller)
  }

  func prepared(_ directory: URL) throws -> PreparedExecutionContext {
    let root = try SandboxPath(ProjectPathResolver.canonicalProject(directory).path)
    #if os(macOS)
      let reads = testExecutionLauncher().hostSystemReadPaths
    #else
      let reads: [SandboxPath] = []
    #endif
    let sandbox = try SandboxConfiguration(
      readOnly: true, worktree: root, temporaryDirectory: root, homeDirectory: root,
      cacheDirectory: root, readableRoots: reads, listableAncestors: [.init("/")])
    return try PreparedExecutionContext(
      authority: self, mode: .sandbox(sandbox),
      environment: .init(
        searchPath: [.init("/usr/bin"), .init("/bin")], home: root, temporary: root, cache: root),
      limits: Self.limits, provider: binding)
  }

  func invalidate() { lock.withLock { valid = false } }
  func reserveChild(_ id: UUID) { lock.withLock { startCount += 1 } }
  func bindChild(_ id: UUID, ownership: any ExecutionOwnership) {}
  func launchFailed(_ id: UUID) {}
  func finishAdmission() {}
  func retainWork(cancellation: @escaping @Sendable () async -> Void) throws -> ExecutionWorkLease {
    _ = try access(executionID, operation: .writeInput)
    lock.withLock { retainedCount += 1 }
    return .init { [self] in lock.withLock { retainedCount -= 1 } }
  }
  func access(_ executionID: UUID, operation: ExecutionOperation) throws -> EffectiveExecutionLimits
  {
    try lock.withLock {
      guard valid else { throw PermissionModelError.invalidAuthorization }
      return Self.limits
    }
  }
}

#if os(macOS)
  private final class SessionSource: @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    private var revision = "a"
    private var authorities: [SessionAuthority] = []
    init(root: URL) { self.root = root }
    var preparations: Int { lock.withLock { authorities.count } }
    var starts: Int { lock.withLock { authorities.reduce(0) { $0 + $1.starts } } }
    func replace() {
      lock.withLock {
        revision = "b"
        for authority in authorities { authority.invalidate() }
      }
    }
    func source() -> MCPProviderExecutionSource {
      let digest = lock.withLock { String(repeating: revision, count: 64) }
      return .init(
        digest: digest,
        prepareDiscovery: { [self] in
          let authority = try SessionAuthority(digest: digest)
          lock.withLock { authorities.append(authority) }
          return try authority.prepared(root)
        })
    }
  }

  private struct SessionFixture: Sendable {
    let root: URL
    let server: MCPServerConfig
    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        .resolvingSymlinksInPath()
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      let source = root.appendingPathComponent("peer.c")
      let binary = root.appendingPathComponent("peer")
      try #"""
      #include <ctype.h>
      #include <fcntl.h>
      #include <stdio.h>
      #include <stdlib.h>
      #include <string.h>
      #include <sys/socket.h>
      #include <unistd.h>
      int main(void) {
        if (!getenv("COMPUTER_MCP_HOST_FD") || strcmp(getenv("COMPUTER_MCP_HOST_FD"), "3")) return 11;
        struct sockaddr addr; socklen_t len = sizeof(addr);
        if (getpeername(3, &addr, &len) || addr.sa_family != AF_UNIX) return 12;
        if (fcntl(3, F_SETFD, FD_CLOEXEC)) return 13;
        char *line = NULL; size_t capacity = 0;
        while (getline(&line, &capacity, stdin) > 0) {
          char *id = strstr(line, "\"id\""); if (!id) continue;
          id = strchr(id, ':') + 1; while (isspace(*id)) id++;
          char *end = id; if (*end == '"') { end++; while (*end && *end != '"') end++; end++; }
          else { while (*end && *end != ',' && *end != '}') end++; }
          printf("{\"jsonrpc\":\"2.0\",\"id\":%.*s,\"result\":", (int)(end-id), id);
          if (strstr(line, "\"initialize\""))
            printf("{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"peer\",\"version\":\"1\"}}");
          else if (strstr(line, "tools/list") || strstr(line, "tools\\/list"))
            printf("{\"tools\":[{\"name\":\"pid\",\"inputSchema\":{\"type\":\"object\"}}]}");
          else printf("{\"content\":[{\"type\":\"text\",\"text\":\"%d\"}]}", getpid());
          puts("}"); fflush(stdout);
        }
        free(line); return 0;
      }
      """#.write(to: source, atomically: true, encoding: .utf8)
      let compiler = Process()
      compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
      compiler.arguments = ["-Wall", "-Werror", source.path, "-o", binary.path]
      compiler.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": root.path]
      try compiler.run()
      compiler.waitUntilExit()
      try #require(compiler.terminationStatus == 0)
      server = .init(
        id: "provider", transport: .stdio, command: binary.path,
        startupTimeoutMs: 5000, requestTimeoutMs: 5000, hostServices: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func client(source: SessionSource? = nil) -> MCPProxyClient {
      var host = MCPHostContext(
        runtimeID: UUID(), context: .init(caller: .localMCP, profileID: .localAdmin),
        projectID: "project", rootURL: root, readOnly: true, tools: MCPHostToolDirectory(),
        processOwnershipRoot: root.appendingPathComponent("ownership"))
      if let source { host.providerSource = { _ in source.source() } }
      return MCPProxyClient(
        launcher: testExecutionLauncher(), workingDirectory: root, hostContext: host)
    }
    func call(_ client: MCPProxyClient, authority: SessionAuthority) async throws -> Int32 {
      let execution = try authority.prepared(root)
      let result = try await client.callToolAsync(
        server: server, name: "pid", arguments: .object([:]), requestID: nil,
        context: .init(executionAuthority: execution))
      return try #require(
        result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?
          .stringValue.flatMap(Int32.init))
    }
  }

#endif
