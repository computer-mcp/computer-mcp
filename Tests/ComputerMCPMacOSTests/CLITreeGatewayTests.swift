import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPPlatform
import ComputerMCPPlatformDarwin
import ComputerMCPProcess
import ComputerMCPSandbox
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPlugins
@testable import ComputerMCPToolsCLI

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

struct CLITreeGatewayTests {
  @Test
  func realCLIThroughFileCatalogAndRefresh() async throws {
    let fixture = try CLITreeFixture()
    defer { fixture.cleanup() }
    try fixture.write(Self.tree(Self.printCommand()))
    var configuration = GatewayConfiguration()
    configuration.projectDirectory = fixture.root
    configuration.cli.commands = [
      .init(
        id: "printf", executable: "/usr/bin/printf", allowAnyArgs: false,
        tree: .init(kind: .file, path: fixture.treeURL.path))
    ]
    let environment = ToolEnvironment(
      launcher: testExecutionLauncher(), configuration: configuration)
    let provider = CLIToolProvider(environment: environment)
    let router = try GatewayProviderRouter(
      source: { [provider] + (try provider.treeProviders()) },
      shutdownSource: { await environment.registeredCommands.execution.shutdown() })
    let tool = try #require(router.listTools(context: .empty).first { $0.name.hasPrefix("cli_") })
    #expect(tool.name.count <= 128)
    #expect(try router.capability(named: tool.name, context: .empty).risk == .fullShell)
    guard InvocationExecution.current == nil else {
      throw ExecutionEnvironmentError.unavailable("The direct CLI fixture requires its own scope")
    }
    let administration = ExecutionAdministration(
      mode: .fullAccess,
      environment: try ExecutionEnvironment(
        fullAccessVariables: ["PATH": "/usr/bin:/bin", "HOME": fixture.root.path]))
    let result = try await BlockingOperationExecutor(label: "cli-tree-printf-fixture").perform {
      try ExecutionAdministration.$current.withValue(administration) {
        try router.callTool(
          name: tool.name,
          arguments: .object([
            "values": .array([
              .string("你好 world"), .string("'\"$HOME"), .string("-42"), .string(""),
            ])
          ]), context: .empty)
      }
    }
    #expect(
      Self.output(result)?["stdout"]?.objectValue?["data"] == .string("你好 world\n'\"$HOME\n-42\n\n")
    )
    #expect(result.objectValue?["isError"] == .bool(false))
    #expect(Self.output(result)?["arguments"] == nil)
    #expect(throws: GatewayToolError.self) {
      try router.callTool(
        name: "cli.exec", arguments: .object(["id": .string("printf"), "argv": .array([])]),
        context: .empty)
    }
    #expect(throws: GatewayToolError.self) {
      try router.callTool(
        name: "cli.help",
        arguments: .object(["id": .string("printf"), "path": .array([.string("--anything")])]),
        context: .empty)
    }
    let help = try router.callTool(
      name: "cli.help", arguments: .object(["id": .string("printf")]), context: .empty)
    #expect(Self.output(help)?["executed"] == .bool(false))
    let events = router.toolChanges(context: .empty)
    var next = Self.printCommand()
    next.parameters = [.init(name: "values", schema: Self.strings)]
    try fixture.write(Self.tree(next))
    try await router.refreshTools(context: .empty)
    #expect(
      try router.listTools(context: .empty).first { $0.name == tool.name }?.inputSchema
        != tool.inputSchema)
    try Data("invalid".utf8).write(to: fixture.treeURL)
    await #expect(throws: (any Error).self) { try await router.refreshTools(context: .empty) }
    #expect(router.lastRefreshError != nil)
    #expect(try router.listTools(context: .empty).contains { $0.name == tool.name })
    await router.shutdown()
    var iterator = events.makeAsyncIterator()
    #expect(await iterator.next() != nil)
    #expect(await iterator.next() == nil)
  }

  @Test
  func pluginAndDirectRegistrationUseTheSamePolicyAndExecution() async throws {
    let fixture = try CLITreeFixture()
    defer { fixture.cleanup() }
    try fixture.write(Self.tree(Self.printCommand()))
    let manifest = """
      id = 'tree-test'
      name = 'Tree test'
      version = '1.0.0'
      plugin_api = 1
      [sandbox]
      full_access = true
      purpose = 'Exercise the fixed native printf invocation'
      [[permissions]]
      id = 'project'
      access = 'write'
      purpose = 'Run the fixed native printf command'
      [[dependencies]]
      id = 'printf'
      commands = ['printf']
      instructions = 'Use the system printf.'
      [[cli]]
      id = 'print'
      executable = { dependency = 'printf' }
      tree = { kind = 'file', path = 'tree.json' }
      """
    try manifest.write(
      to: fixture.root.appendingPathComponent(PluginManifest.filename), atomically: true,
      encoding: .utf8)
    let package = try PluginPackage.load(at: fixture.root)
    let plugin = try PluginResolver.resolve(
      package: package, source: .init(kind: .development, root: package.root),
      settings: .init(enabled: true, cli: ["print": .init(registrationID: "printf")]),
      dependencyExecutables: ["printf": URL(fileURLWithPath: "/usr/bin/printf")],
      hostVersion: PluginVersion("1.0.29"), architecture: "arm64")
    #expect(plugin.cliCommands.first?.tree?.packageRoot == package.root)
    var projects = [
      RegisteredProject(id: "fixture", displayName: "Fixture", rootPath: fixture.root.path)
    ]
    projects[0].rootPath = fixture.root.path
    let configuration = GatewayConfiguration(
      runtime: .init(caller: .localCLI, profileID: .localAdmin),
      profiles: [
        .init(
          id: .localAdmin,
          permissions: fixturePermissions([
            .machineInformation: .granted(.access), .skills: .granted(.access),
            .screen: .granted(.access), .desktopControl: .granted(.access),
            .unifiedLogs: .granted(.access), .localNetwork: .granted(.access),
            .project("fixture"): .granted(.write), .mcpServer("*"): .granted(.all),
            .plugin("*"): .granted(.use),
          ]), fullAccess: true, allowedCallers: [.localCLI])
      ])
    let state = fixture.root.deletingLastPathComponent().appendingPathComponent(
      "cli-state-\(UUID())")
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: state) }
    let database = try fixturePermissionDatabase(
      path: state.appendingPathComponent("state.sqlite").path)
    for project in projects { try database.saveProject(project) }
    let profile = configuration.profiles[0].grant
    try database.saveProfile(profile)
    let platform = MacOSPlatform.services(
      launcher: ExecutionLauncher(platform: try CLITreePrintfPlatform(root: fixture.root)))
    try await database.permissionRuntime(platform: platform).ready()
    let context = try fixtureConsentedContext(
      database: database, grant: profile, caller: .localCLI, platform: platform)
    let runtime = try GatewayRuntime(
      configuration: configuration, context: context, database: database,
      registeredProjects: projects,
      platform: platform, plugins: [plugin])
    let session = try runtime.makeControlSession()
    try fixtureApprovePlugin(
      package, database: database, runtime: runtime.permissionRuntime,
      permissions: fixturePermissions([.project("fixture"): .granted(.write)]), fullAccess: true)
    _ = try session.approveFullAccess(expectedRevision: session.revision)
    let tool = try #require(runtime.listTools(context: .empty).first { $0.name.hasPrefix("cli_") })
    let result = try await runtime.callToolAsync(
      name: tool.name, arguments: .object(["values": .array([.string("plugin value")])]),
      context: .empty)
    #expect(Self.output(result)?["stdout"]?.objectValue?["data"] == .string("plugin value\n"))
    await runtime.shutdown()

    var direct = configuration
    direct.cli.commands = [
      .init(
        id: "printf", executable: "/usr/bin/printf", allowAnyArgs: false,
        tree: .init(kind: .file, path: fixture.treeURL.path))
    ]
    let directRuntime = try GatewayRuntime(
      configuration: direct, context: context, database: database, registeredProjects: projects,
      platform: platform,
      plugins: [])
    let directTool = try #require(
      directRuntime.listTools(context: .empty).first { $0.name.hasPrefix("cli_") })
    #expect(directTool == tool)
    await directRuntime.shutdown()
    let observeDatabase = try GatewayDatabase(inMemory: ())
    for project in projects { try observeDatabase.saveProject(project) }
    let observeContext = ExecutionContext(
      caller: .secureTunnel, profileID: .chatGPTObserve,
      trustedPrincipalID: "verified-cli-observer")
    let observe = try GatewayRuntime(
      configuration: direct, context: observeContext, database: observeDatabase,
      registeredProjects: projects,
      platform: MacOSPlatform.services(launcher: testExecutionLauncher()), plugins: [])
    #expect(try observe.listTools(context: .empty).contains { $0.name == tool.name })
    await #expect(throws: (any Error).self) {
      try await observe.callToolAsync(
        name: tool.name, arguments: .object(["values": .array([.string("denied")])]),
        context: .empty)
    }
    await observe.shutdown()
  }

  static let string = JSONValue.object(["type": .string("string")])
  static let strings = JSONValue.object(["type": .string("array"), "items": string])

  static func printCommand() -> CLICommandDescriptor {
    CLICommandDescriptor(
      id: "print", path: [], description: "Print each supplied string literally",
      parameters: [.init(name: "values", schema: strings, required: true)],
      argv: [
        .init(kind: .literal, value: "--"), .init(kind: .literal, value: "%s\n"),
        .init(kind: .positional, parameter: "values"),
      ],
      helpArgv: ["--help"], riskHint: .readOnly)
  }

  static func tree(_ command: CLICommandDescriptor) -> CLITree {
    .init(
      formatVersion: 1, source: "test fixture; not upstream discovery",
      executableVersion: "fixture",
      coverage: .partial, omissions: ["Only the declared test invocation is represented."],
      commands: [command])
  }

  static func output(_ result: JSONValue) -> [String: JSONValue]? {
    result.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue
  }
}

private struct CLITreeFixture {
  let root: URL
  var treeURL: URL { root.appendingPathComponent("tree.json") }
  init() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "cli-tree-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    root = try ProjectPathResolver.canonicalProject(directory)
  }
  func write(_ tree: CLITree) throws {
    try JSONEncoder().encode(tree).write(to: treeURL, options: .atomic)
  }
  func cleanup() { try? FileManager.default.removeItem(at: root) }
}

/// The fixed system printf invocation cannot create descendants, so its native root
/// identity covers the complete execution through confirmed exit and recovery.
private struct CLITreePrintfPlatform: ExecutionPlatform {
  let root: URL
  let base: DarwinExecutionPlatform

  init(root: URL) throws {
    self.root = root
    base = DarwinExecutionPlatform(
      bootstrapExecutable: try nativeGatewayTestExecutable().deletingLastPathComponent()
        .appendingPathComponent("computer-mcp-execution-bootstrap"))
  }

  var supportsRecovery: Bool { true }
  var bootSessionID: String? { base.bootSessionID }
  var hostSystemReadPaths: [SandboxPath] { base.hostSystemReadPaths }
  func supportsDurableOwnership(sandboxed: Bool) -> Bool { !sandboxed }

  func start(
    _ command: ExecutionCommand, sandbox: SandboxConfiguration?, method: ExecutionLaunchMethod,
    input: Int32, output: Int32, error: Int32,
    bindOwnership: @Sendable (any ExecutionOwnership) -> Void
  ) async throws -> any ExecutionOwnership {
    guard try PreparedExecutionContext.current() != nil, sandbox == nil,
      command.executable.value == "/usr/bin/printf",
      command.arguments == ["--", "%s\n", "plugin value"],
      try ProjectPathResolver.canonicalProject(URL(fileURLWithPath: command.directory.value))
        == root,
      command.directoryDescriptor == nil, command.inheritedDescriptors.isEmpty
    else {
      throw ExecutionEnvironmentError.unavailable(
        "The CLI fixture backend accepts only its declared printf invocation")
    }
    let controlled = ExecutionCommand(
      executable: command.executable, arguments: command.arguments,
      directory: try SandboxPath(root.path),
      environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "LANG": "C", "LC_ALL": "C"])
    let owner = try await base.start(
      controlled, sandbox: nil, method: method, input: input, output: output, error: error,
      bindOwnership: { bindOwnership(CLITreePrintfOwnership(base: $0)) })
    return CLITreePrintfOwnership(base: owner)
  }

  func recover(_ state: ExecutionRecoveryState) async throws -> any ExecutionOwnership {
    guard !state.sandboxed, state.backend == CLITreePrintfOwnership.backend,
      state.root.processID > 0, state.root.identity > 0
    else { throw ExecutionEnvironmentError.unavailable("Invalid CLI fixture recovery") }
    try await base.interrupt([state.root])
    return CLITreePrintfCompletedOwnership(state: state)
  }

  func interrupt(_ members: [ExecutionMember]) async throws { try await base.interrupt(members) }

  func releaseRecovery(_ state: ExecutionRecoveryState) throws {
    guard !state.sandboxed, state.backend == CLITreePrintfOwnership.backend else {
      throw ExecutionEnvironmentError.unavailable("Invalid CLI fixture recovery")
    }
  }
}

private struct CLITreePrintfOwnership: ExecutionOwnership {
  static let backend = "cli-tree-printf-fixture"
  let base: any ExecutionOwnership

  func recoveryState() throws -> ExecutionRecoveryState {
    let state = try base.recoveryState()
    return ExecutionRecoveryState(root: state.root, sandboxed: false, backend: Self.backend)
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

private struct CLITreePrintfCompletedOwnership: ExecutionOwnership {
  let state: ExecutionRecoveryState
  func recoveryState() throws -> ExecutionRecoveryState { state }
  func beforeStart(_ handler: @escaping @Sendable (ExecutionMember) throws -> Void) {}
  func members() async throws -> [ExecutionMember] { [] }
  func onCancellation(_ handler: @escaping @Sendable () -> Void) {}
  func cancel(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit {
    ExecutionExit(status: 143, signal: 15)
  }
  func wait(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit {
    ExecutionExit(status: 143, signal: 15)
  }
}
