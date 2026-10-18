import CryptoKit
import Foundation
import Testing

@testable import ComputerMCP

/// An explicit local dependency check, isolated from production App state and sockets.
@Suite(
  .enabled(
    if: ProcessInfo.processInfo.environment["COMPUTER_MCP_FORMATTER_PLUGIN"] != nil,
    "Set COMPUTER_MCP_FORMATTER_PLUGIN and COMPUTER_MCP_FORMATTER_EXECUTABLE for the native CLI integration."
  ),
  .timeLimit(.minutes(1)))
struct NativeCLITreeIntegrationTests {
  @Test
  func independentPluginAndDirectRegistrationExecuteTheSameNativeTree() async throws {
    let environment = ProcessInfo.processInfo.environment
    let packageURL = URL(
      fileURLWithPath: try #require(environment["COMPUTER_MCP_FORMATTER_PLUGIN"]))
    let executable = try #require(environment["COMPUTER_MCP_FORMATTER_EXECUTABLE"])
    let package = try PluginPackage.load(at: packageURL)
    #expect(package.manifest.id == "swift-format")
    let manifestBefore = try Data(
      contentsOf: package.root.appendingPathComponent(PluginManifest.filename))
    let treeURL = package.root.appendingPathComponent("cli-tree.json")
    let treeBefore = try Data(contentsOf: treeURL)
    let tree = try CLITree.parse(treeBefore)
    try #require(
      tree.executableChecks == [
        .init(args: ["--version"], stdout: "6.3.1\n"),
        .init(
          args: ["--experimental-dump-help"],
          stdoutSHA256: "afce7a2f8c5b0825b90ce7061c6508eb5545b07b1414ed853c23a0fb6ab8c14e"),
      ])
    let executableBefore = try Self.digest(executable)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let plugin = try PluginResolver.resolve(
      package: package, source: .init(kind: .development, root: package.root),
      settings: .init(enabled: true, cli: ["format": .init(registrationID: "native-formatter")]),
      dependencyExecutables: ["formatter": URL(fileURLWithPath: executable)],
      hostVersion: PluginVersion("1.0.29"), architecture: "arm64")
    try #require(plugin.diagnostics.isEmpty && plugin.cliCommands.count == 1)
    let workspaces = [
      RegisteredWorkspace(id: "native-fixture", displayName: "Native fixture", rootPath: root.path)
    ]
    let configuration = GatewayConfiguration(
      runtime: .init(caller: .localCLI, profileID: .localAdmin),
      profiles: [
        .init(
          id: .localAdmin, capabilities: ["*"], workspaces: ["native-fixture"],
          allowedCallers: [.localCLI], fullShellEnabled: true, mode: .localFullAccess,
          confirmationPolicy: .never)
      ])
    let runtime = try GatewayRuntime(
      configuration: configuration, registeredWorkspaces: workspaces, plugins: [plugin])
    do {
      let tools = try runtime.listTools().filter { $0.name.hasPrefix("cli_") }
      #expect(tools.count == 5)
      var direct = configuration
      direct.cli.commands = [
        .init(
          id: "native-formatter", executable: executable, allowAnyArgs: false,
          tree: .init(kind: .file, path: treeURL.path))
      ]
      let directRuntime = try GatewayRuntime(
        configuration: direct, registeredWorkspaces: workspaces, plugins: [])
      let directTools = try directRuntime.listTools().filter { $0.name.hasPrefix("cli_") }
      #expect(directTools == tools)
      await directRuntime.shutdown()
      let format = try #require(tools.first { $0.name.hasSuffix("_format") })
      #expect(
        format.meta?.objectValue?["cli"]?.objectValue?["executable_check_count"] == .number(2))
      let lint = try #require(tools.first { $0.name.hasSuffix("_lint") })
      let arguments: JSONValue = .object([
        "paths": .array([.string("-")]), "source": .string("let value=1\n"),
        "configuration": .string("{}"), "color_diagnostics": .bool(false),
      ])
      let formatted = try await runtime.callToolAsync(name: format.name, arguments: arguments)
      #expect(formatted.objectValue?["isError"] == .bool(false))
      #expect(Self.result(formatted)?["stdout"]?.objectValue?["data"] == .string("let value = 1\n"))
      #expect(Self.result(formatted)?["stderr"]?.objectValue?["data"] == .string(""))
      let incompatible = CLITreeToolProvider(
        registration: direct.cli.commands[0],
        tree: .init(
          formatVersion: tree.formatVersion, source: tree.source,
          executableVersion: tree.executableVersion, coverage: tree.coverage,
          omissions: tree.omissions, commands: tree.commands,
          executableChecks: [.init(args: ["--version"], stdout: "incompatible\n")]),
        workspace: root, execution: CLIProcessExecution(),
        timeoutMilliseconds: 5_000, maxOutputBytes: 4_096)
      await #expect(throws: CLITreeError.self) {
        try await incompatible.callToolAsync(name: format.name, arguments: arguments)
      }
      await incompatible.execution.shutdown()
      var lintArguments = try #require(arguments.objectValue)
      lintArguments["strict"] = .bool(true)
      let linted = try await runtime.callToolAsync(
        name: lint.name, arguments: .object(lintArguments))
      #expect(linted.objectValue?["isError"] == .bool(true))
      #expect(Self.result(linted)?["exit_code"] == .number(1))
      #expect(
        Self.result(linted)?["stderr"]?.objectValue?["data"]?.stringValue?.contains("[Spacing]")
          == true)
      await #expect(
        throws: GatewayToolError.disabled(
          "CLI command 'native-formatter' does not allow arbitrary args.")
      ) {
        try await runtime.callToolAsync(
          name: "cli.exec",
          arguments: .object([
            "id": .string("native-formatter"), "argv": .array([.string("--version")]),
          ]))
      }
      let observe = try GatewayRuntime(
        configuration: direct, context: .init(caller: .secureTunnel, profileID: .chatGPTObserve),
        registeredWorkspaces: workspaces, plugins: [])
      #expect(try !observe.listTools().contains { $0.name == format.name })
      await #expect(throws: (any Error).self) {
        try await observe.callToolAsync(name: format.name, arguments: arguments)
      }
      await observe.shutdown()
    } catch {
      await runtime.shutdown()
      throw error
    }
    await runtime.shutdown()
    #expect(
      try Data(contentsOf: package.root.appendingPathComponent(PluginManifest.filename))
        == manifestBefore)
    #expect(try Data(contentsOf: treeURL) == treeBefore)
    #expect(try Self.digest(executable) == executableBefore)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }

  private static func result(_ value: JSONValue) -> [String: JSONValue]? {
    value.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue
  }

  private static func digest(_ path: String) throws -> Data {
    Data(SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path))))
  }
}
