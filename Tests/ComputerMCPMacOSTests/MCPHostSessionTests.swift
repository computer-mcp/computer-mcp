import ComputerMCPDownstream
import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPSandbox
import ComputerMCPTestSupport
import ComputerMCPToolKit
import ComputerMCPTransport
import ComputerMCPWorktrees
import CryptoKit
import Darwin
import Foundation
import GRDB
import MCP
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPlatform
@testable import ComputerMCPPlatformDarwin
@testable import ComputerMCPPlugins
@testable import ComputerMCPProcess

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.nativeIntegration, .timeLimit(.minutes(1)))
struct MCPHostSessionTests {
  @Test(arguments: [false, true])
  func manifestProjectsBecomeDurableBeforeHostCallbacks(fileBacked: Bool)
    async throws
  {
    let fixture = try HostFixture(fileBacked: fileBacked, persistProjects: false)
    defer { fixture.remove() }
    #expect(try Set(fixture.database.projects().map(\.id)) == ["first", "second"])
    let result = try await fixture.call("file.read", ["path": .string("value.txt")])
    #expect(result.objectValue?["isError"] != .bool(true))
    #expect(fixture.payload(result)["content"] == .string("first"))
    #expect(try Set(fixture.database.projects().map(\.id)) == ["first", "second"])
    await fixture.runtime.shutdown()
  }

  @Test
  func deletingPersistedAuthorityDoesNotRestoreConfiguredHostAccess() async throws {
    let fixture = try HostFixture(fileBacked: true)
    defer { fixture.remove() }
    let catalog = try fixture.runtime.hostToolCatalog(projectID: "first", origin: "plugin")
    try #require(catalog.contains { $0.name == "file.read" })
    let path = try #require(fixture.database.fileURL).path
    let writer = try DatabaseQueue(path: path)
    try await writer.write { database in
      try database.execute(
        sql: "DELETE FROM permissionProfiles WHERE id = ?", arguments: ["chatgpt-operate"])
    }
    #expect(try !fixture.database.profiles().contains { $0.id == .chatGPTOperate })
    #expect(throws: (any Error).self) {
      try fixture.runtime.hostToolCatalog(projectID: "first", origin: "plugin")
    }
    let result = try await fixture.call("file.read", ["path": .string("value.txt")])
    #expect(result.objectValue?["isError"] == .bool(true))
    await fixture.runtime.shutdown()
  }

  @Test
  func ordinaryMCPCallsUseBoundProjectAndOriginalAuditIdentity() async throws {
    let fixture = try HostFixture()
    defer { fixture.remove() }
    let session = try fixture.session()
    let client = MCP.Client(name: "plugin-fixture", version: "1")
    let transport = try MCPInheritedSocketTransport(takingOwnershipOf: session.childHandle)
    do {
      _ = try await client.connect(transport: transport)
      let request: RequestContext<MCP.CallTool.Result> = try await client.callTool(
        name: "file.read", arguments: ["path": .string("value.txt")])
      let result = try await request.value
      #expect(result.isError != true)
      #expect(
        result.structuredContent?.objectValue?["result"]?.objectValue?["content"]
          == .string("first"))
      let audit = try #require(
        try fixture.database.auditEvents().first { $0.capabilityID == "file.read" })
      #expect(audit.projectID == "first")
      #expect(audit.profileID == .chatGPTOperate)
      #expect(audit.caller == .secureTunnel)
      #expect(audit.transport == "gateway_socket")
      #expect(audit.socketConnectionID == "original-socket")
      #expect(audit.requestID.hasPrefix("host:"))
      let listed = try await fixture.call("project.list")
      #expect(fixture.payload(listed)["projects"]?.arrayValue?.count == 1)
      let rejected = try await fixture.call(
        "file.read", ["project_id": .string("second"), "path": .string("value.txt")])
      #expect(rejected.objectValue?["isError"] == .bool(true))
      #expect(
        try fixture.database.auditEvents().contains { $0.errorCode == "policy.project_denied" })
      await client.disconnect()
      await session.close()
      await fixture.runtime.shutdown()
    } catch {
      await transport.disconnect()
      await client.disconnect()
      await session.close()
      await fixture.runtime.shutdown()
      throw error
    }
  }

  @Test(arguments: [
    "alias.callback", "loop.operation", "mcp.tools.call", "policy.probe",
    "nested-project", "selected-owner",
  ])
  func indirectCallsCannotReenterTheOriginOrWidenProject(route: String) async throws {
    let fixture = try HostFixture()
    defer { fixture.remove() }
    var name = route
    var arguments: [String: JSONValue] = [:]
    let ownerLease = fixture.runtime.ownedWork.retain(
      .mcpUnreportedWork, projectID: "first", registrationID: "plugin",
      resourceID: "callback-owner", connectionID: UUID())
    defer { ownerLease.finish() }
    if route == "mcp.tools.call" {
      arguments = ["server": .string("plugin"), "tool": .string("operation")]
    } else if route == "policy.probe" {
      arguments = ["capability_id": .string("alias.callback"), "arguments": .object([:])]
    } else if route == "selected-owner" {
      name = "runtime.owners.call"
      arguments = [
        "owner": GatewayOwnerSelection(
          runtimeID: fixture.runtime.generationID,
          projectID: "first", ownershipID: ownerLease.id
        ).json,
        "tool": .string("alias.callback"), "arguments": .object([:]),
      ]
    } else if route == "nested-project" {
      name = "policy.probe"
      arguments = [
        "capability_id": .string("file.read"),
        "arguments": .object([
          "project_id": .string("second"), "path": .string("value.txt"),
        ]),
      ]
    }
    let previousAudits = Set(try fixture.database.auditEvents().map(\.id))
    let result = try await fixture.call(name, arguments)
    #expect(result.objectValue?["isError"] == .bool(true))
    if route == "selected-owner" {
      #expect(String(describing: result).contains("policy.host_recursion_denied"))
    }
    #expect(fixture.downstream.invocations == 0)
    #expect(
      try fixture.database.auditEvents().filter { !previousAudits.contains($0.id) }.count == 1)
    await fixture.runtime.shutdown()
  }

  @Test
  func gitDryRunThroughHostCallbackPreservesTheIndex() async throws {
    let fixture = try HostFixture(git: true)
    defer { fixture.remove() }
    func git(_ arguments: [String]) async throws -> String {
      try await BlockingOperationExecutor(label: "host-callback-git-setup").perform {
        try fixture.ownerGit(arguments)
      }
    }
    do {
      _ = try await git(["init", "--quiet"])
      _ = try await git(["add", "value.txt"])
      let index = try Data(contentsOf: fixture.first.appendingPathComponent(".git/index"))
      try "changed".write(
        to: fixture.first.appendingPathComponent("value.txt"), atomically: true, encoding: .utf8)
      let result = try await fixture.call(
        "git.add", ["paths": .array([.string("value.txt")]), "dry_run": .bool(true)])
      #expect(result.objectValue?["isError"] != .bool(true), "\(result)")
      #expect(try Data(contentsOf: fixture.first.appendingPathComponent(".git/index")) == index)
      #expect(try await git(["show", ":value.txt"]) == "first")
      await fixture.runtime.shutdown()
    } catch {
      await fixture.runtime.shutdown()
      throw error
    }
  }

  @Test
  func destructiveCallsPreserveOriginalAuditAttribution() async throws {
    let fixture = try HostFixture()
    defer { fixture.remove() }
    let session = try fixture.session()
    let client = MCP.Client(name: "plugin-fixture", version: "1")
    let transport = try MCPInheritedSocketTransport(takingOwnershipOf: session.childHandle)
    do {
      _ = try await client.connect(transport: transport)
      let request: RequestContext<MCP.CallTool.Result> = try await client.callTool(
        name: "file.replace_text",
        arguments: [
          "path": .string("value.txt"), "search": .string("first"),
          "replacement": .string("updated"),
          "expected_replacements": .int(1), "dry_run": .bool(false),
        ])
      let result = try await request.value
      #expect(result.isError == false)
      #expect(
        try String(contentsOf: fixture.first.appendingPathComponent("value.txt"), encoding: .utf8)
          == "updated")
      let audit = try #require(
        try fixture.database.auditEvents().first {
          $0.capabilityID == "file.replace_text" && $0.decision == .allowed
        })
      #expect(audit.socketConnectionID == "original-socket")
      #expect(audit.requestID.hasPrefix("host:"))
      await client.disconnect()
      await session.close()
      await fixture.runtime.shutdown()
    } catch {
      await transport.disconnect()
      await client.disconnect()
      await session.close()
      await fixture.runtime.shutdown()
      throw error
    }
  }

  @Test(arguments: [
    "observe", "grant-revoked", "project-removed", "project-changed", "shutdown",
  ])
  func liveScopeAndReadOnlyDenialsRemainAuthoritative(reason: String) async throws {
    let fixture = try HostFixture(observe: reason == "observe")
    defer { fixture.remove() }
    if reason == "grant-revoked" {
      var grant = fixture.grant
      try grant.permissions.set(.denied, for: .project("first"))
      try fixture.database.saveProfile(grant)
    } else if reason == "project-removed" {
      try fixture.database.deleteProject(id: "first")
    } else if reason == "project-changed" {
      let replacement = fixture.root.appendingPathComponent("replacement")
      try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
      try fixture.database.saveProject(
        .init(id: "first", displayName: "Changed", rootPath: replacement.path))
    } else if reason == "shutdown" {
      await fixture.runtime.shutdown()
    }
    let name = reason == "observe" ? "file.replace_text" : "file.read"
    var arguments: [String: JSONValue] = ["path": .string("value.txt")]
    if reason == "observe" {
      arguments.merge([
        "search": .string("first"), "replacement": .string("changed"),
        "expected_replacements": .integer(1), "dry_run": .bool(false),
      ]) { _, value in value }
    }
    let result = try await fixture.call(name, arguments)
    #expect(result.objectValue?["isError"] == .bool(true))
    #expect(
      try String(contentsOf: fixture.first.appendingPathComponent("value.txt"), encoding: .utf8)
        == "first")
    await fixture.runtime.shutdown()
  }

  @Test
  func revokedProjectGrantDeniesCallbacksWhileKnownToolsRemainRequestable() async throws {
    let fixture = try HostFixture()
    defer { fixture.remove() }
    #expect(
      try fixture.runtime.hostToolCatalog(projectID: "first", origin: "plugin").contains {
        $0.name == "file.read"
      })
    var grant = fixture.grant
    try grant.permissions.set(.denied, for: .project("first"))
    try fixture.database.saveProfile(grant)
    #expect(
      try fixture.runtime.hostToolCatalog(projectID: "first", origin: "plugin").contains {
        $0.name == "file.read"
      })
    let denied = try await fixture.call("file.read", ["path": .string("value.txt")])
    #expect(denied.objectValue?["isError"] == .bool(true))
    await fixture.runtime.shutdown()
  }

  @Test
  func hostDelegationIsExplicitAndSurvivesConfigurationRoundTrip() throws {
    let disabled = MCPServerConfig(id: "plugin", transport: .stdio, command: "/bin/cat")
    #expect(!disabled.hostServices)
    var enabled = disabled
    enabled.hostServices = true
    let config = GatewayConfiguration(mcp: .init(servers: [enabled]))
    let restored = try GatewayConfiguration.load(text: config.exportedTOML())
    #expect(restored.mcp.servers.first?.hostServices == true)
    let settings = PluginMCPSettings(hostServices: true)
    #expect(
      try JSONDecoder().decode(PluginMCPSettings.self, from: JSONEncoder().encode(settings))
        .hostServices)
    let environment = try MCPHostLaunchMetadata.launchEnvironment(
      inherited: [
        "COMPUTER_MCP_HOST_FD": "8", "COMPUTER_MCP_HOST_READ_HANDLE": "144",
        "COMPUTER_MCP_HOST_WRITE_HANDLE": "148",
      ],
      overrides: [
        "COMPUTER_MCP_HOST_FD": "9", "COMPUTER_MCP_HOST_READ_HANDLE": "152",
        "COMPUTER_MCP_HOST_WRITE_HANDLE": "156",
      ], context: nil)
    #expect(environment["COMPUTER_MCP_HOST_FD"] == nil)
    #expect(environment["COMPUTER_MCP_HOST_READ_HANDLE"] == nil)
    #expect(environment["COMPUTER_MCP_HOST_WRITE_HANDLE"] == nil)
    let remote = GatewayConfiguration(
      mcp: .init(servers: [
        .init(
          id: "remote", transport: .streamableHTTP, url: "https://example.invalid/mcp",
          hostServices: true)
      ]))
    #expect(throws: (any Error).self) { try remote.validate() }
  }

  @Test
  func inheritedDescriptorReachesOnlyTheOwnedCommandAndParentCopyCanCloseImmediately() async throws
  {
    let pair = try MCPInheritedSocketTransport.makePair()
    let transport = try MCPInheritedSocketTransport(takingOwnershipOf: pair.0)
    let source =
      "import os,socket; s=socket.socket(fileno=3); s.sendall(b'owned-child\\n'); s.close(); print('completed',flush=True)"
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("inherited.py")
    try source.write(to: script, atomically: true, encoding: .utf8)
    let command = MCPServerConfig(
      id: "inherited-descriptor", transport: .stdio, command: "/usr/bin/python3",
      args: [script.path])
    let authority = try ProxyExecutionFixture(server: command, root: root)
    defer { try? authority.close() }
    let execution = try #require(try authority.context.executionAuthority)
    let process = try InvocationExecution.$current.withValue(execution) {
      try ManagedLineProcess(
        launcher: authority.launcher,
        configuration: .init(
          executable: "/usr/bin/python3", arguments: [script.path], environment: [:],
          workingDirectory: root, inheritedDescriptors: [3: pair.1]))
    }
    try pair.1.close()
    do {
      try await transport.connect()
      var received = await transport.receive().makeAsyncIterator()
      #expect(try await received.next() == Data("owned-child".utf8))
      // EOF requires every host copy of the child endpoint to be closed.
      #expect(try await received.next() == nil)
      var lines = process.inboundLines.makeAsyncIterator()
      #expect(try await lines.next() == "completed")
      await process.close()
      #expect(await process.snapshot().hasExited)
      await transport.disconnect()
    } catch {
      await transport.disconnect()
      await process.close()
      throw error
    }
  }
}

private final class HostFixture: Sendable {
  let root: URL
  let first: URL
  let database: GatewayDatabase
  let runtime: GatewayRuntime
  let grant: ProfileGrant
  let downstream = HostCatalogClient()
  let context: ExecutionContext
  let registration: MCPServerConfig
  private let gitBackend: HostCallbackGitBackend?

  init(
    observe: Bool = false, fileBacked: Bool = false, persistProjects: Bool = true,
    git: Bool = false
  ) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "host-fixture-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    root = try ProjectPathResolver.canonicalProject(directory)
    first = root.appendingPathComponent("first")
    let second = root.appendingPathComponent("second")
    for directory in [first, second] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try directory.lastPathComponent.write(
        to: directory.appendingPathComponent("value.txt"), atomically: true, encoding: .utf8)
    }
    database =
      try fileBacked
      ? fixturePermissionDatabase(path: root.appendingPathComponent("gateway.sqlite").path)
      : GatewayDatabase(inMemory: ())
    let projects = [first, second].map {
      RegisteredProject(
        id: $0.lastPathComponent, displayName: $0.lastPathComponent, rootPath: $0.path)
    }
    if persistProjects {
      for project in projects { try database.saveProject(project) }
    }
    var platform: PlatformServices
    let gitCommand: CLICommandConfig
    if git {
      let backend = try HostCallbackGitBackend(
        directory: first, scratch: root.appendingPathComponent("git-scratch"))
      gitBackend = backend
      platform = MacOSPlatform.services(launcher: ExecutionLauncher(platform: backend))
      gitCommand = .init(id: "git", executable: backend.executable.value)
    } else {
      gitBackend = nil
      let nonGit = try fixtureNonGitProject(root: first)
      platform = nonGit.platform
      gitCommand = nonGit.git
    }
    platform.permissionPolicyReader = TestManagedPolicyReader()
    let profile: GatewayProfileID = observe ? .chatGPTObserve : .chatGPTOperate
    grant = ProfileGrant(
      id: profile,
      permissions: fixturePermissions([
        .project("first"): .granted(observe ? .read : .write),
        .project("second"): .granted(observe ? .read : .write),
        .mcpServer("plugin"): .granted(.all),
      ]), fullAccess: !observe, allowedCallers: [.secureTunnel])
    try database.saveProfile(grant)
    let trace = GatewayTransportTrace(
      transport: "gateway_socket", socketConnectionID: "original-socket")
    context =
      observe
      ? ExecutionContext(
        caller: .secureTunnel, profileID: profile, transportTrace: trace,
        trustedPrincipalID: "original-principal")
      : try fixtureConsentedContext(
        database: database, grant: grant, caller: .secureTunnel,
        principalID: "original-principal", transportTrace: trace, platform: platform)
    registration = MCPServerConfig(
      id: "plugin", transport: .stdio, command: "/bin/cat", exposure: .reexport,
      prefix: "loop", allowedTools: ["operation"], toolRisks: ["operation": .readOnly],
      hostServices: true)
    runtime = try GatewayRuntime(
      configuration: .init(
        runtime: .init(caller: .secureTunnel, profileID: profile),
        projects: projects.map {
          .init(id: $0.id, displayName: $0.displayName, path: $0.rootPath)
        },
        profiles: [
          .init(grant: grant)
        ],
        cli: .init(commands: [gitCommand]),
        mcp: .init(servers: [registration]),
        tools: [.init(name: "alias.callback", adapter: .mcp, source: "plugin", tool: "operation")],
        builtin: .init(enabled: ["file.read", "file.replace_text"] + (git ? ["git.add"] : []))),
      context: context, database: database,
      registeredProjects: persistProjects ? projects : nil,
      platform: platform,
      mcpClient: downstream)
  }

  func ownerGit(_ arguments: [String]) throws -> String {
    let backend = try #require(gitBackend)
    try #require(
      [["init", "--quiet"], ["add", "value.txt"], ["show", ":value.txt"]].contains(arguments))
    let administration = ExecutionAdministration(
      mode: .fullAccess,
      environment: try ExecutionEnvironment(fullAccessVariables: backend.environment))
    let result = try ExecutionAdministration.$current.withValue(administration) {
      try ProcessCommandRunner(launcher: testExecutionLauncher()).run(
        executable: backend.executable.value, arguments: HostGitConfiguration.arguments + arguments,
        workingDirectory: first, environment: backend.environment,
        timeoutMilliseconds: 5_000, maxOutputBytes: 16_384)
    }
    try #require(result.exitCode == 0 && !result.timedOut, "\(result.stderr)")
    return result.stdout
  }

  func session() throws -> MCPHostSession {
    let directory = MCPHostToolDirectory()
    directory.attach(runtime)
    return try MCPHostSession(
      context: .init(
        runtimeID: UUID(), context: context, projectID: "first", rootURL: first,
        readOnly: false, tools: directory), server: registration)
  }
  func call(_ name: String, _ arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
    try await runtime.callHostTool(
      name: name, arguments: arguments, projectID: "first", origin: "plugin",
      requestID: UUID().uuidString)
  }
  func payload(_ value: JSONValue) -> [String: JSONValue] {
    value.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue ?? [:]
  }
  func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class HostCatalogClient: DownstreamMCPClient, @unchecked Sendable {
  private static let tools = [
    MCPTool(name: "operation", description: "Fixture", inputSchema: .object([:]))
  ]
  func cachedTools(server: MCPServerConfig, context: InvocationContext) -> [MCPTool]? {
    Self.tools
  }

  private let lock = NSLock()
  private var count = 0
  var invocations: Int { lock.withLock { count } }
  func makeScopedClient(
    workingDirectory: URL, environment: [String: String], hostContext: (any MCPHostEnvironment)?
  ) -> any DownstreamMCPClient { self }
  func listTools(server: MCPServerConfig, context: InvocationContext) throws -> [MCPTool] {
    Self.tools
  }
  func callTool(
    server: MCPServerConfig, name: String, arguments: JSONValue, context: InvocationContext
  ) throws -> JSONValue {
    lock.withLock { count += 1 }
    return .null
  }
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

/// The callback owns a real Git process whose writes are confined to fixture scratch.
private struct HostCallbackGitBackend: ExecutionPlatform {
  let executable: SandboxPath
  let directory: SandboxPath
  let scratch: SandboxPath
  private let executableDigest: Data
  private let base = DarwinExecutionPlatform(
    bootstrapExecutable: (try? nativeGatewayTestExecutable())?
      .deletingLastPathComponent().appendingPathComponent("computer-mcp-execution-bootstrap"))

  init(directory: URL, scratch: URL) throws {
    let candidates = [
      "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
      "/Library/Developer/CommandLineTools/usr/bin/git",
    ]
    let path = try #require(candidates.first { FileManager.default.isExecutableFile(atPath: $0) })
    executable = try SandboxPath(
      ProjectPathResolver.canonicalProject(URL(fileURLWithPath: path)).path)
    executableDigest = Data(
      SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: executable.value))))
    self.directory = try SandboxPath(ProjectPathResolver.canonicalProject(directory).path)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
    self.scratch = try SandboxPath(ProjectPathResolver.canonicalProject(scratch).path)
    for name in ["home", "cache"] {
      try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: self.scratch.value).appendingPathComponent(name),
        withIntermediateDirectories: false)
    }
  }

  var environment: [String: String] {
    HostGitConfiguration.environment(
      home: URL(fileURLWithPath: scratch.value).appendingPathComponent("home")
    )
    .merging(["PATH": "/usr/bin:/bin"]) { _, value in value }
  }
  var supportsRecovery: Bool { base.supportsRecovery }
  var bootSessionID: String? { base.bootSessionID }
  var hostSystemReadPaths: [SandboxPath] { base.hostSystemReadPaths }
  func supportsDurableOwnership(sandboxed: Bool) -> Bool { true }

  func start(
    _ command: ExecutionCommand, sandbox: SandboxConfiguration?, method: ExecutionLaunchMethod,
    input: Int32, output: Int32, error: Int32,
    bindOwnership: @Sendable (any ExecutionOwnership) -> Void
  ) async throws -> any ExecutionOwnership {
    let fixedNames = HostGitConfiguration.arguments.enumerated().compactMap { index, argument in
      index > 0 && HostGitConfiguration.arguments[index - 1] == "-c"
        ? String(argument.prefix { $0 != "=" }).lowercased() : nil
    }.joined(separator: "\0")
    let fixedOverrides = try HostGitConfiguration.overrides(for: fixedNames)
    let queries = [
      HostGitConfiguration.arguments + [
        "config", "--null", "--name-only", "--list", "--no-includes",
      ],
      HostGitConfiguration.arguments + fixedOverrides + [
        "--literal-pathspecs", "add", "--dry-run", "--", "value.txt",
      ],
    ]
    let actualDirectory = try SandboxPath(
      ProjectPathResolver.canonicalProject(URL(fileURLWithPath: command.directory.value)).path)
    guard try PreparedExecutionContext.current() != nil,
      command.executable == executable, actualDirectory == directory,
      command.inheritedDescriptors.isEmpty, queries.contains(command.arguments),
      Data(SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: executable.value))))
        == executableDigest
    else {
      throw ExecutionEnvironmentError.unavailable(
        "The Git fixture accepts only its reviewed callback commands")
    }
    let scratchURL = URL(fileURLWithPath: scratch.value)
    let readableRoots =
      try base.hostSystemReadPaths + [
        directory,
        SandboxPath(
          URL(fileURLWithPath: executable.value).deletingLastPathComponent()
            .deletingLastPathComponent().path),
      ]
    let contentRoots = readableRoots + [scratch]
    var ancestors = Set<SandboxPath>()
    // dyld opens the filesystem root before resolving its shared cache.
    for root in contentRoots {
      var ancestor = URL(fileURLWithPath: root.value).deletingLastPathComponent()
      while true {
        let canonical = try SandboxPath(ProjectPathResolver.canonicalProject(ancestor).path)
        if !contentRoots.contains(where: { $0.contains(canonical) }) {
          ancestors.insert(canonical)
        }
        if ancestor.path == "/" { break }
        ancestor.deleteLastPathComponent()
      }
    }
    let profile = try SandboxConfiguration(
      readOnly: true, worktree: directory, temporaryDirectory: scratch,
      homeDirectory: SandboxPath(scratchURL.appendingPathComponent("home").path),
      cacheDirectory: SandboxPath(scratchURL.appendingPathComponent("cache").path),
      readableRoots: readableRoots,
      listableAncestors: ancestors.sorted { $0.value < $1.value })
    let fixedEnvironment = try ExecutionEnvironment(
      searchPath: [SandboxPath("/usr/bin"), SandboxPath("/bin")],
      home: profile.homeDirectory, temporary: profile.temporaryDirectory,
      cache: profile.cacheDirectory, locale: "C"
    ).variables(sandbox: profile).merging(environment) { _, value in value }
    let controlled = ExecutionCommand(
      executable: executable, arguments: command.arguments, directory: directory,
      environment: fixedEnvironment, directoryDescriptor: command.directoryDescriptor)
    return try await base.start(
      controlled, sandbox: profile, method: method,
      input: input, output: output, error: error, bindOwnership: bindOwnership)
  }

  func recover(_ state: ExecutionRecoveryState) async throws -> any ExecutionOwnership {
    try await base.recover(state)
  }
  func interrupt(_ members: [ExecutionMember]) async throws { try await base.interrupt(members) }
  func releaseRecovery(_ state: ExecutionRecoveryState) throws { try base.releaseRecovery(state) }
}
