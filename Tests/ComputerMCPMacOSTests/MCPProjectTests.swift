import ComputerMCPDownstream
import ComputerMCPMacOS
import ComputerMCPProcess
import ComputerMCPSandbox
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Darwin
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPControlPlane
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPermissions
@testable import ComputerMCPPlatform
@testable import ComputerMCPPlatformDarwin
@testable import ComputerMCPPlatformPOSIX

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.nativeIntegration)
struct MCPProjectTests {
  @Test(arguments: [false, true])
  func connectionValidationUsesTheConfigurationDirectoryAndCleansUp(_ fail: Bool) async throws {
    let fixture = try MCPProjectFixture()
    defer { fixture.remove() }
    let marker = fixture.first.appendingPathComponent("started.jsonl")
    var configuration = fixture.configuration()
    configuration.mcp.servers[0].cwd = "first"
    configuration.mcp.servers[0].env = ["START_MARKER": marker.path]
    let scope = try MCPProjectUnitScope(directory: fixture.first, readableRoot: fixture.root)
    let prepared = try scope.prepared(variables: configuration.mcp.servers[0].env)
    let platform = MacOSPlatform.services(launcher: scope.launcher)
    do {
      if fail {
        configuration.mcp.servers.append(
          .init(
            id: "missing", transport: .stdio,
            command: fixture.root.appendingPathComponent("not-installed").path))
        let selectedConfiguration = configuration
        await expectThrowsAsync(
          try await prepared.withValue {
            try await ComputerMCPProductContracts.validateMCPConnections(
              configuration: selectedConfiguration, platform: platform)
          }
        ) { error in
          #expect(error.localizedDescription.contains("missing"))
        }
      } else {
        let selectedConfiguration = configuration
        let report = try await prepared.withValue {
          try await ComputerMCPProductContracts.validateMCPConnections(
            configuration: selectedConfiguration, platform: platform)
        }
        let row = try #require(report.arrayValue?.first?.objectValue)
        #expect(row["id"] == .string("shared"))
        #expect(row["ok"] == .bool(true))
        #expect(
          row["tools"]?.arrayValue?.first?.objectValue?["description"]
            == .string(fixture.first.path))
      }
      let records = try String(contentsOf: marker, encoding: .utf8).split(separator: "\n").map {
        line in
        try #require(JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)).objectValue)
      }
      #expect(records.count == 1)
      #expect(records.first?["cwd"] == .string(fixture.first.path))
      try await fixture.expectExited(records)
      try await scope.finish()
    } catch {
      try await scope.finish()
      throw error
    }
  }

  @Test(arguments: [false, true])
  func projectProvidersOwnSessionsAndStoppingOnePreservesItsPeer(_ authorized: Bool) async throws {
    let fixture = try MCPProjectFixture()
    defer { fixture.remove() }
    let configuration = fixture.configuration()
    let firstScope = try MCPProjectUnitScope(directory: fixture.first, readableRoot: fixture.root)
    let secondScope = try MCPProjectUnitScope(directory: fixture.second, readableRoot: fixture.root)
    let firstContext = InvocationContext(
      executionAuthority: try firstScope.prepared(variables: [:]))
    let secondContext = InvocationContext(
      executionAuthority: try secondScope.prepared(variables: [:]))
    let parent = MCPProxyClient(launcher: firstScope.launcher)
    let client: any DownstreamMCPClient =
      authorized
      ? AuthorizedMCPClient(
        base: parent,
        policy: .init(
          configuration: configuration, grant: configuration.profileGrant(for: .localAdmin),
        ))
      : parent
    var firstConfiguration = configuration
    firstConfiguration.projectDirectory = fixture.first
    var secondConfiguration = configuration
    secondConfiguration.projectDirectory = fixture.second
    let first = try GatewayProviderRouter(
      registry: MacOSToolProviders().makeProviders(
        toolEnvironment: ToolEnvironment(
          launcher: firstScope.launcher, configuration: firstConfiguration), mcpClient: client))
    let second = try GatewayProviderRouter(
      registry: MacOSToolProviders().makeProviders(
        toolEnvironment: ToolEnvironment(
          launcher: secondScope.launcher, configuration: secondConfiguration), mcpClient: client)
    )
    let executor = BlockingOperationExecutor(label: "test.mcp-project")
    do {
      for (router, context) in [(first, firstContext), (second, secondContext)] {
        _ = try await router.callToolAsync(
          name: "mcp.tools.list", arguments: .object(["server": .string("shared")]),
          context: context)
        try await router.refreshTools(context: context)
      }
      let firstValue = try await executor.perform { try fixture.read(first, context: firstContext) }
      let secondValue = try await executor.perform {
        try fixture.read(second, context: secondContext)
      }
      #expect(firstValue["cwd"] == .string(fixture.first.path))
      #expect(secondValue["cwd"] == .string(fixture.second.path))
      #expect(firstValue["pid"] != secondValue["pid"])
      await first.shutdown()
      let repeated = try await executor.perform { try fixture.read(second, context: secondContext) }
      #expect(repeated["pid"] == secondValue["pid"])
      #expect(repeated["cwd"] == secondValue["cwd"])
      await second.shutdown()
      await parent.shutdown()
      try await fixture.expectExited([firstValue, secondValue])
      try await firstScope.finish()
      try await secondScope.finish()
    } catch {
      await first.shutdown()
      await second.shutdown()
      await parent.shutdown()
      try await firstScope.finish()
      try await secondScope.finish()
      throw error
    }
  }

  @Test(arguments: [false, true])
  func runtimeRoutesConcurrentCallsToTheirProjectSessions(_ readOnly: Bool) async throws {
    let fixture = try MCPProjectFixture()
    defer { fixture.remove() }
    var configuration = fixture.configuration()
    configuration.mcp.servers[0].env[MCPHostLaunchMetadata.environmentKey] = "forged registration"
    let originalContext = ExecutionContext(
      caller: readOnly ? .secureTunnel : .localMCP,
      profileID: readOnly ? .chatGPTObserve : .localAdmin,
      transportTrace: .init(
        transport: "fixture", socketConnectionID: "socket-owner", tunnelInstanceID: "tunnel-owner",
        tunnelProfileID: "tunnel-profile"), trustedPrincipalID: "project-session-owner")
    let (gateway, context, invocation) = try await fixture.runtime(
      configuration: configuration, context: originalContext, readOnly: readOnly)
    do {
      _ = try #require(context.controlSession as? GatewayControlSession)
      for project in ["first", "second"] {
        _ = try await gateway.callToolAsync(
          name: "mcp.tools.list",
          arguments: .object(["project_id": .string(project), "server": .string("shared")]),
          context: context, invocationContext: invocation)
      }
      try await gateway.refreshTools(context: invocation)
      async let first = gateway.callToolAsync(
        name: "fixture.context",
        arguments: .object([
          "project_id": .string("first"), "caller": .string("local-admin"),
          "hostContext": .object(["readOnly": .bool(false)]),
        ]), context: context, invocationContext: invocation)
      async let second = gateway.callToolAsync(
        name: "fixture.context", arguments: .object(["project_id": .string("second")]),
        context: context, invocationContext: invocation)
      let values = try await [first, second].map { result in
        #expect(result.objectValue?["isError"] != .bool(true))
        return try #require(result.objectValue?["structuredContent"]?.objectValue)
      }
      #expect(values[0]["cwd"] == .string(fixture.first.path))
      #expect(values[1]["cwd"] == .string(fixture.second.path))
      #expect(values[0]["pid"] != values[1]["pid"])
      var runtimeIDs: Set<String> = []
      for (index, projectID) in ["first", "second"].enumerated() {
        let host = try #require(values[index]["hostContext"]?.objectValue)
        #expect(host["formatVersion"] == .number(1))
        #expect(host["caller"] == .string(context.caller.rawValue))
        #expect(host["profileID"] == .string(context.profileID.rawValue))
        #expect(host["readOnly"] == .bool(readOnly))
        #expect(host["project"]?.objectValue?["id"] == .string(projectID))
        let declaredRoot = URL(
          fileURLWithPath: try #require(host["project"]?.objectValue?["rootPath"]?.stringValue))
        let actualRoot = URL(fileURLWithPath: try #require(values[index]["cwd"]?.stringValue))
        #expect(
          try ProjectPathResolver.canonicalProject(declaredRoot)
            == ProjectPathResolver.canonicalProject(actualRoot))
        #expect(
          host["transportTrace"]?.objectValue?["socketConnectionID"] == .string("socket-owner"))
        #expect(
          host["transportTrace"]?.objectValue?["tunnelInstanceID"] == .string("tunnel-owner"))
        #expect(
          host["transportTrace"]?.objectValue?["tunnelProfileID"] == .string("tunnel-profile"))
        runtimeIDs.insert(try #require(host["runtimeID"]?.stringValue))
        #expect(host["permissions"] == nil)
      }
      #expect(runtimeIDs.count == 1)
      #expect(runtimeIDs.first.flatMap(UUID.init(uuidString:)) != nil)
      var reconnected = context
      reconnected.transportTrace?.socketConnectionID = "new-connection"
      let retained = try await gateway.callToolAsync(
        name: "fixture.context", arguments: .object(["project_id": .string("first")]),
        context: reconnected, invocationContext: invocation)
      #expect(retained.objectValue?["structuredContent"]?.objectValue?["pid"] == values[0]["pid"])
      for changedPrincipal in [false, true] {
        var changedContext = context
        if changedPrincipal {
          changedContext.trustedPrincipalID = "different-owner"
        } else {
          changedContext.caller = .localCLI
        }
        await expectThrowsAsync(
          try await gateway.callToolAsync(
            name: "fixture.context", arguments: .object(["project_id": .string("first")]),
            context: changedContext, invocationContext: invocation)
        ) { error in
          #expect(error.localizedDescription.contains("policy.caller_denied"))
        }
      }
      await gateway.shutdown()
      (context.controlSession as? GatewayControlSession)?.end()
      try await fixture.expectExited(values)
    } catch {
      await gateway.shutdown()
      (context.controlSession as? GatewayControlSession)?.end()
      throw error
    }
  }

  @Test(arguments: [nil, "", "project", "nested"] as [String?])
  func launchResolvesDirectoryExecutableAndInterpreterTogether(_ cwd: String?) async throws {
    let fixture = try MCPProjectFixture()
    defer { fixture.remove() }
    let directory = cwd == "nested" ? fixture.first.appendingPathComponent("nested") : fixture.first
    let bin = directory.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let server = fixture.root.appendingPathComponent("path-resolved-peer.pl")
    try MCPProjectFixture.writeServer(to: server, interpreter: "/usr/bin/env fixture-perl")
    let link = directory.appendingPathComponent("probe")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: server)
    let interpreter = bin.appendingPathComponent("fixture-perl")
    try Data("#!/bin/sh\nexec /usr/bin/perl \"$@\"\n".utf8).write(to: interpreter)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: interpreter.path)
    var configuration = fixture.configuration()
    configuration.projectDirectory = fixture.first
    configuration.mcp.servers[0].command = "./probe"
    configuration.mcp.servers[0].args = []
    configuration.mcp.servers[0].cwd = cwd
    configuration.mcp.servers[0].env = ["PATH": "bin", "SCOPE_VALUE": "child", "EMPTY": ""]
    configuration.mcp.servers[0].env[MCPHostLaunchMetadata.environmentKey] = "forged registration"
    let scope = try MCPProjectUnitScope(directory: directory, readableRoot: fixture.root)
    let invocation = InvocationContext(
      executionAuthority: try scope.prepared(variables: configuration.mcp.servers[0].env))
    let registry = try GatewayProviderRouter(
      registry: MacOSToolProviders().makeProviders(
        toolEnvironment: ToolEnvironment(
          launcher: scope.launcher,
          configuration: configuration,
          environment: [
            "PATH": "/unrelated", "SCOPE_VALUE": "parent", "EMPTY": "parent",
            MCPHostLaunchMetadata.environmentKey: "forged ancestor",
          ]), mcpClient: MCPProxyClient(launcher: scope.launcher)))
    do {
      _ = try await registry.callToolAsync(
        name: "mcp.tools.list", arguments: .object(["server": .string("shared")]),
        context: invocation)
      try await registry.refreshTools(context: invocation)
      let value = try await BlockingOperationExecutor(label: "test.mcp-launch").perform {
        try fixture.read(registry, context: invocation)
      }
      #expect(value["cwd"] == .string(directory.path))
      #expect(value["script"] == .string(link.standardizedFileURL.path))
      #expect(value["scope"] == .string("child"))
      #expect(value["empty"] == .string(""))
      #expect(value["hostContext"] == .null)
      await registry.shutdown()
      try await fixture.expectExited([value])
      try await scope.finish()
    } catch {
      await registry.shutdown()
      try await scope.finish()
      throw error
    }
  }
}

private struct MCPProjectFixture: Sendable {
  let root: URL
  let first: URL
  let second: URL
  let script: URL

  init() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    root = try ProjectPathResolver.canonicalProject(directory)
    first = root.appendingPathComponent("first", isDirectory: true)
    second = root.appendingPathComponent("second", isDirectory: true)
    for url in [first, second] {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }
    script = root.appendingPathComponent("probe.pl")
    try Self.writeServer(to: script, interpreter: "/usr/bin/perl")
  }

  func configuration() -> GatewayConfiguration {
    GatewayConfiguration(
      runtime: .init(caller: .localMCP, profileID: .localAdmin),
      profiles: [
        .init(
          id: .localAdmin, permissions: fixturePermissions([.mcpServer("shared"): .granted(.all)]),
          allowedCallers: [.localMCP])
      ],
      mcp: .init(servers: [
        .init(
          id: "shared", transport: .stdio, command: "/usr/bin/perl", args: [script.path],
          exposure: .reexport, prefix: "fixture", allowAnyTool: true,
          requestTimeoutMs: 5_000, toolRisks: ["context": .readOnly])
      ]), projectDirectory: root)
  }

  func read(_ registry: any GatewayToolServing, context: InvocationContext) throws -> [String:
    JSONValue]
  {
    _ = try registry.listTools(context: context)
    return try #require(
      registry.callTool(name: "fixture.context", arguments: .object([:]), context: context)
        .objectValue?["structuredContent"]?.objectValue)
  }

  func runtime(
    configuration: GatewayConfiguration, context: ExecutionContext, readOnly: Bool
  ) async throws -> (GatewayRuntime, ExecutionContext, InvocationContext) {
    let launcher = testExecutionLauncher()
    var platform = MacOSPlatform.services(launcher: launcher)
    platform.permissionPolicyReader = TestManagedPolicyReader()
    let database = try fixturePermissionDatabase(path: root.appendingPathComponent("host.db").path)
    let grant = ProfileGrant(
      id: context.profileID,
      permissions: fixturePermissions([
        .project("first"): .granted(readOnly ? .read : .write),
        .project("second"): .granted(readOnly ? .read : .write),
        .mcpServer("shared"): .granted(.all),
      ]), fullAccess: true, allowedCallers: [context.caller])
    for (id, directory) in [("first", first), ("second", second)] {
      try database.saveProject(.init(id: id, displayName: id, rootPath: directory.path))
    }
    try database.bootstrapPermissionProfiles([grant])
    var configuration = configuration
    configuration.mcp.servers[0].command = script.path
    configuration.mcp.servers[0].args = []
    configuration.profiles = [.init(grant: grant)]
    let runtime = try await GatewayRuntime.make(
      configuration: configuration, context: context, database: database,
      registeredProjects: database.projects(), platform: platform,
      mcpClient: MCPProxyClient(launcher: launcher), plugins: [])
    do {
      let session = try runtime.makeControlSession()
      try fixtureApproveLocalProvider(
        configuration.mcp.servers[0], database: database, runtime: runtime.permissionRuntime,
        permissions: fixturePermissions([
          .project("first"): .granted(readOnly ? .read : .write),
          .project("second"): .granted(readOnly ? .read : .write),
        ]), fullAccess: true)
      _ = try session.approveFullAccess(expectedRevision: session.revision)
      var context = context
      context.controlSession = session
      return (runtime, context, InvocationContext(session: session))
    } catch {
      await runtime.shutdown()
      throw error
    }
  }

  func expectExited(_ values: [[String: JSONValue]]) async throws {
    for value in values {
      let pid = Int32(try #require(value["pid"]?.intValue))
      let deadline = ContinuousClock.now + .seconds(2)
      while kill(pid, 0) == 0, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  fileprivate static func writeServer(to script: URL, interpreter: String) throws {
    try Data(("#!\(interpreter)\n" + server + "\n").utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
  }

  private static let server = #"""
    use strict;
    use warnings;
    use Cwd qw(getcwd);
    use Encode qw(decode_utf8);
    use JSON::PP qw(decode_json encode_json);
    $| = 1;

    my $cwd = decode_utf8(getcwd());
    if (my $marker = $ENV{START_MARKER}) {
        open my $output, '>>', $marker or die "open start marker: $!";
        print {$output} encode_json({pid => $$, cwd => $cwd}), "\n";
        close $output or die "close start marker: $!";
    }
    while (my $line = <STDIN>) {
        my $message = decode_json($line);
        next unless exists $message->{id};
        my $method = $message->{method};
        my $response = {jsonrpc => '2.0', id => $message->{id}};
        if ($method eq 'initialize') {
            $response->{result} = {
                protocolVersion => '2025-11-25', capabilities => {tools => {}},
                serverInfo => {name => 'project-fixture', version => '1'}};
        } elsif ($method eq 'tools/list') {
            $response->{result} = {tools => [{
                name => 'context', description => $cwd, inputSchema => {type => 'object'}}]};
        } elsif ($method eq 'tools/call') {
            $response->{result} = {content => [], structuredContent => {
                cwd => $cwd, pid => $$, script => decode_utf8($0),
                scope => $ENV{SCOPE_VALUE}, empty => $ENV{EMPTY},
                hostContext => decode_json($ENV{COMPUTER_MCP_HOST_CONTEXT} // 'null')}};
        } else {
            $response->{error} = {code => -32601, message => 'not found'};
        }
        print encode_json($response), "\n";
    }
    """#
}

/// Direct transport fixtures own native Sandbox trees; Gateway tests use durable admission.
private final class MCPProjectUnitScope: @unchecked Sendable {
  private let authority = MCPProjectUnitAuthority()
  let launcher: ExecutionLauncher
  private let sandbox: SandboxConfiguration
  private let home: SandboxPath

  init(directory: URL, readableRoot: URL) throws {
    let launcher = testExecutionLauncher()
    self.launcher = launcher
    let root = try SandboxPath(ProjectPathResolver.canonicalProject(directory).path)
    let storage = directory.appendingPathComponent("private-home", isDirectory: true)
    try FileManager.default.createDirectory(
      at: storage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let home = try SandboxPath(ProjectPathResolver.canonicalProject(storage).path)
    self.home = home
    let reads =
      [root, try SandboxPath(ProjectPathResolver.canonicalProject(readableRoot).path)]
      + launcher.hostSystemReadPaths
    var ancestors: Set<String> = ["/"]
    for path in reads + [home] {
      var parent = (path.value as NSString).deletingLastPathComponent
      while parent != "/" {
        ancestors.insert(parent)
        parent = (parent as NSString).deletingLastPathComponent
      }
    }
    sandbox = try SandboxConfiguration(
      worktree: root, temporaryDirectory: home, homeDirectory: home, cacheDirectory: home,
      readableRoots: reads, listableAncestors: ancestors.sorted().map(SandboxPath.init))
  }

  var joined: Bool { authority.joined }

  func prepared(variables: [String: String]) throws -> PreparedExecutionContext {
    try PreparedExecutionContext(
      authority: authority, mode: .sandbox(sandbox),
      environment: .init(
        searchPath: [SandboxPath("/usr/bin"), SandboxPath("/bin")],
        home: home, temporary: home, cache: home, hostVariables: variables),
      limits: MCPProjectUnitAuthority.limits)
  }

  func finish() async throws {
    authority.finishAdmission()
    try await Task.detached { [authority, launcher] in
      try await authority.joinResources(launcher: launcher)
    }.value
  }
}

private final class MCPProjectUnitAuthority: ExecutionAuthorizing, @unchecked Sendable {
  static let limits = EffectiveExecutionLimits(
    timeMilliseconds: 60_000, outputBytes: 8 * 1024 * 1024, memoryBytes: nil,
    retentionSeconds: 60, retainedOutputBytes: 8 * 1024 * 1024, sources: [:])

  let executionID = UUID()
  let authorizationIDs: Set<UUID> = [UUID()]
  private struct Child {
    var ownership: (any ExecutionOwnership)?
    var member: ExecutionMember?
    var failed = false
    var released = false
  }
  private let lock = NSLock()
  private var closed = false
  private var didJoin = false
  private var children: [UUID: Child] = [:]
  private var work: [UUID: @Sendable () async -> Void] = [:]
  private var rootObservers: [UUID: Task<Void, Never>] = [:]

  var joined: Bool { lock.withLock { didJoin } }

  func reserveChild(_ id: UUID) throws {
    try lock.withLock {
      guard !closed, children[id] == nil else { throw PermissionModelError.invalidAuthorization }
      children[id] = Child()
    }
  }

  func bindChild(_ id: UUID, ownership: any ExecutionOwnership) {
    lock.withLock { children[id]?.ownership = ownership }
    ownership.beforeStart { [weak self] member in
      guard let self else { throw PermissionModelError.invalidAuthorization }
      try self.lock.withLock {
        guard !self.closed, self.children[id]?.ownership != nil,
          self.children[id]?.member == nil
        else { throw PermissionModelError.invalidAuthorization }
        self.children[id]?.member = member
      }
      #if os(macOS)
        let root = DarwinProcessIdentity(pid: member.processID, uniqueID: member.identity)
        let observer = Task.detached { [weak self] in
          guard let self else { return }
          await self.observeRoot(id, identity: root, ownership: ownership)
        }
        self.lock.withLock {
          self.rootObservers[id] = observer
          if self.closed { observer.cancel() }
        }
      #endif
    }
  }

  #if os(macOS)
    /// A wrapper's pinned kernel identity survives exec and remains observable until reaped.
    /// Its departure closes only the original ownership tree, including descendants.
    private func observeRoot(
      _ id: UUID, identity: DarwinProcessIdentity, ownership: any ExecutionOwnership
    ) async {
      while !Task.isCancelled, lock.withLock({ !closed && children[id]?.released == false }) {
        do {
          let current = DarwinProcessIdentity.current(pid: identity.pid, includingZombies: true)
          if current?.identity != identity {
            _ = try await ownership.cancel()
            return
          }
        } catch {
          if Task.isCancelled { return }
        }
        do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
      }
    }
  #endif

  func launchFailed(_ id: UUID) {
    lock.withLock { children[id]?.failed = true }
  }

  func finishAdmission() { lock.withLock { closed = true } }

  func retainWork(cancellation: @escaping @Sendable () async -> Void) throws -> ExecutionWorkLease {
    let id = UUID()
    try lock.withLock {
      guard !closed else { throw PermissionModelError.invalidAuthorization }
      work[id] = cancellation
    }
    return ExecutionWorkLease { [self] in _ = lock.withLock { work.removeValue(forKey: id) } }
  }

  func access(_ id: UUID, operation: ExecutionOperation) throws -> EffectiveExecutionLimits {
    try lock.withLock {
      guard id == executionID, !closed || operation == .readResult else {
        throw PermissionModelError.invalidAuthorization
      }
      return Self.limits
    }
  }

  func joinResources(launcher: ExecutionLauncher) async throws {
    if joined { return }
    let rootObservers = lock.withLock { Array(self.rootObservers.values) }
    for observer in rootObservers { observer.cancel() }
    let cancellations = lock.withLock { Array(work.values) }
    let cancelling = cancellations.map { cancellation in Task { await cancellation() } }
    let deadline = ContinuousClock.now + .seconds(10)
    var firstError: (any Error)?
    while true {
      let pending = lock.withLock { children.filter { !$0.value.released } }
      for (id, child) in pending {
        guard let ownership = child.ownership else {
          if child.failed { lock.withLock { children[id]?.released = true } }
          continue
        }
        do {
          _ = try await ownership.cancel(until: deadline)
          try #require(try await ownership.members().isEmpty)
          if let member = child.member {
            let recovery = try ownership.recoveryState()
            try #require(recovery.root == member && recovery.sandboxed)
            try launcher.releaseRecovery(recovery)
          }
          lock.withLock { children[id]?.released = true }
        } catch { firstError = firstError ?? error }
      }
      if let firstError {
        for task in cancelling { await task.value }
        for observer in rootObservers { await observer.value }
        throw firstError
      }
      let complete = lock.withLock { children.values.allSatisfy(\.released) && work.isEmpty }
      if complete {
        for task in cancelling { await task.value }
        let observers = lock.withLock { Array(self.rootObservers.values) }
        for observer in observers {
          observer.cancel()
          await observer.value
        }
        lock.withLock { didJoin = true }
        return
      }
      guard ContinuousClock.now < deadline else {
        throw ExecutionEnvironmentError.unavailable(
          "The native protocol fixture has unjoined child reservations or logical work")
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}
