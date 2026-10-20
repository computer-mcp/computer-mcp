import ComputerMCPMacOS
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCP
@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPPlugins
@testable import ComputerMCPToolsCLI

struct CLITreeGatewayTests {
  @Test
  func realCLIThroughFileCatalogAndRefresh() async throws {
    let fixture = try CLITreeFixture()
    defer { fixture.cleanup() }
    try fixture.write(Self.tree(Self.printCommand()))
    var configuration = GatewayConfiguration()
    configuration.workspaceDirectory = fixture.root
    configuration.cli.commands = [
      .init(
        id: "printf", executable: "/usr/bin/printf", allowAnyArgs: false,
        tree: .init(kind: .file, path: fixture.treeURL.path))
    ]
    let environment = ToolEnvironment(configuration: configuration)
    let provider = CLIToolProvider(environment: environment)
    let router = try GatewayProviderRouter(
      source: { [provider] + (try provider.treeProviders()) },
      shutdownSource: { await environment.registeredCommands.execution.shutdown() })
    let tool = try #require(router.listTools(context: .empty).first { $0.name.hasPrefix("cli_") })
    #expect(tool.name.count <= 128)
    #expect(try router.capability(named: tool.name, context: .empty).risk == .fullShell)
    let result = try await router.callToolAsync(
      name: tool.name,
      arguments: .object([
        "values": .array([.string("你好 world"), .string("'\"$HOME"), .string("-42"), .string("")])
      ]), context: .empty)
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
    let workspaces = [
      RegisteredWorkspace(id: "fixture", displayName: "Fixture", rootPath: fixture.root.path)
    ]
    let configuration = GatewayConfiguration(
      runtime: .init(caller: .localCLI, profileID: .localAdmin),
      // This fixture compares registration routes without a persistence or approval service.
      profiles: [
        .init(
          id: .localAdmin, capabilities: ["*"], workspaces: ["fixture"],
          allowedCallers: [.localCLI], fullShellEnabled: true,
          mode: .localFullAccess, confirmationPolicy: .never)
      ])
    let runtime = try GatewayRuntime(
      configuration: configuration, registeredWorkspaces: workspaces,
      platform: MacOSPlatform.services, plugins: [plugin])
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
      configuration: direct, registeredWorkspaces: workspaces, platform: MacOSPlatform.services,
      plugins: [])
    let directTool = try #require(
      directRuntime.listTools(context: .empty).first { $0.name.hasPrefix("cli_") })
    #expect(directTool == tool)
    await directRuntime.shutdown()
    let observeContext = ExecutionContext(caller: .secureTunnel, profileID: .chatGPTObserve)
    let observe = try GatewayRuntime(
      configuration: direct, context: observeContext, registeredWorkspaces: workspaces,
      platform: MacOSPlatform.services, plugins: [])
    #expect(try !observe.listTools(context: .empty).contains { $0.name == tool.name })
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
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "cli-tree-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  func write(_ tree: CLITree) throws {
    try JSONEncoder().encode(tree).write(to: treeURL, options: .atomic)
  }
  func cleanup() { try? FileManager.default.removeItem(at: root) }
}
