import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPPlatform
import ComputerMCPSandbox
import ComputerMCPTestSupport
import ComputerMCPToolKit
import CryptoKit
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPlugins
@testable import ComputerMCPProcess
@testable import ComputerMCPToolsCLI

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

/// An explicit local dependency check, isolated from production App state and sockets.
@Suite(
  .enabled(
    if: ProcessInfo.processInfo.environment["COMPUTER_MCP_FORMATTER_PLUGIN"] != nil,
    "Set COMPUTER_MCP_FORMATTER_PLUGIN and COMPUTER_MCP_FORMATTER_EXECUTABLE for the native CLI integration."
  ),
  .timeLimit(.minutes(1)))
struct NativeCLITreeIntegrationTests {
  @Test
  func independentPluginAndDirectRegistrationShareTheNativeTree() async throws {
    let environment = ProcessInfo.processInfo.environment
    let packageURL = try ProjectPathResolver.canonicalProject(
      URL(
        fileURLWithPath: #require(environment["COMPUTER_MCP_FORMATTER_PLUGIN"])))
    let executable = try ProjectPathResolver.canonicalProject(
      URL(
        fileURLWithPath: #require(environment["COMPUTER_MCP_FORMATTER_EXECUTABLE"]))
    ).path
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
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
    let root = try ProjectPathResolver.canonicalProject(temporary)
    defer { try? FileManager.default.removeItem(at: root) }
    let plugin = try PluginResolver.resolve(
      package: package, source: .init(kind: .development, root: package.root),
      settings: .init(enabled: true, cli: ["format": .init(registrationID: "native-formatter")]),
      dependencyExecutables: ["formatter": URL(fileURLWithPath: executable)],
      hostVersion: PluginVersion("1.0.29"), architecture: "arm64")
    try #require(plugin.diagnostics.isEmpty && plugin.cliCommands.count == 1)
    let projects = [
      RegisteredProject(id: "native-fixture", displayName: "Native fixture", rootPath: root.path)
    ]
    let configuration = GatewayConfiguration(
      runtime: .init(caller: .localCLI, profileID: .localAdmin),
      profiles: [
        .init(
          id: .localAdmin,
          permissions: fixturePermissions([
            .project("native-fixture"): .granted(.write),
            .plugin(package.manifest.id): .granted(.use),
          ]), fullAccess: true, allowedCallers: [.localCLI])
      ])
    let database = try GatewayDatabase(inMemory: ())
    let profile = configuration.profiles[0].grant
    try database.saveProfile(profile)
    for project in projects { try database.saveProject(project) }
    let registeredProjects = try database.projects()
    let context = try fixtureConsentedContext(
      database: database, grant: profile, caller: .localCLI,
      principalID: "formatter-owner", projectID: "native-fixture")
    let runtime = try GatewayRuntime(
      configuration: configuration, context: context, database: database,
      registeredProjects: registeredProjects,
      platform: MacOSPlatform.services(launcher: testExecutionLauncher()), plugins: [plugin])
    do {
      let tools = try runtime.listTools(context: .empty).filter { $0.name.hasPrefix("cli_") }
      #expect(tools.count == 5)
      var direct = configuration
      direct.cli.commands = [
        .init(
          id: "native-formatter", executable: executable, allowAnyArgs: false,
          tree: .init(kind: .file, path: treeURL.path))
      ]
      let directRuntime = try GatewayRuntime(
        configuration: direct, context: context, database: database,
        registeredProjects: registeredProjects,
        platform: MacOSPlatform.services(launcher: testExecutionLauncher()),
        plugins: [])
      let directTools = try directRuntime.listTools(context: .empty).filter {
        $0.name.hasPrefix("cli_")
      }
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
      let observerDatabase = try GatewayDatabase(inMemory: ())
      for project in registeredProjects { try observerDatabase.saveProject(project) }
      let observe = try GatewayRuntime(
        configuration: direct,
        context: .init(
          caller: .secureTunnel, profileID: .chatGPTObserve, projectID: "native-fixture",
          trustedPrincipalID: "formatter-observer"),
        database: observerDatabase, registeredProjects: observerDatabase.projects(),
        platform: MacOSPlatform.services(launcher: testExecutionLauncher()), plugins: [])
      do {
        let requestable = try #require(
          try observe.listTools(context: .empty).first { $0.name == format.name })
        #expect(requestable.meta?.objectValue?["computer_mcp"]?.objectValue?["requirements"] != nil)
        await #expect(throws: GatewayPermissionCallError.self) {
          try await observe.callToolAsync(name: format.name, arguments: arguments, context: .empty)
        }
      } catch {
        await observe.shutdown()
        throw error
      }
      await observe.shutdown()
      await #expect(throws: ExecutionEnvironmentError.self) {
        try await runtime.callToolAsync(name: format.name, arguments: arguments, context: .empty)
      }
      #expect(
        try database.auditEvents().contains {
          $0.capabilityID == format.name && $0.errorCode == "execution.unavailable"
            && $0.errorDetails?.objectValue?["authorization_id"]?.stringValue != nil
        })
      let formatted = try await Self.callOwnedProvider(
        registration: direct.cli.commands[0], tree: tree, project: root,
        name: format.name, arguments: arguments, executableDigest: executableBefore)
      #expect(formatted.objectValue?["isError"] == .bool(false))
      #expect(Self.result(formatted)?["stdout"]?.objectValue?["data"] == .string("let value = 1\n"))
      #expect(Self.result(formatted)?["stderr"]?.objectValue?["data"] == .string(""))
      let incompatible = CLITree(
        formatVersion: tree.formatVersion, source: tree.source,
        executableVersion: tree.executableVersion, coverage: tree.coverage,
        omissions: tree.omissions, commands: tree.commands,
        executableChecks: [.init(args: ["--version"], stdout: "incompatible\n")])
      await #expect(throws: CLITreeError.self) {
        try await Self.callOwnedProvider(
          registration: direct.cli.commands[0], tree: incompatible, project: root,
          name: format.name, arguments: arguments, executableDigest: executableBefore)
      }
      var lintArguments = try #require(arguments.objectValue)
      lintArguments["strict"] = .bool(true)
      let linted = try await Self.callOwnedProvider(
        registration: direct.cli.commands[0], tree: tree, project: root,
        name: lint.name, arguments: .object(lintArguments), executableDigest: executableBefore)
      #expect(linted.objectValue?["isError"] == .bool(true))
      #expect(Self.result(linted)?["exit_code"] == .number(1))
      #expect(
        Self.result(linted)?["stderr"]?.objectValue?["data"]?.stringValue?.contains("[Spacing]")
          == true)
      let raw = CLIToolProvider(
        environment: ToolEnvironment(
          launcher: testExecutionLauncher(), configuration: direct, environment: [:]))
      #expect(
        throws: GatewayToolError.disabled(
          "CLI command 'native-formatter' does not allow arbitrary args.")
      ) {
        try raw.callTool(
          .init(
            name: "cli.exec",
            arguments: .object([
              "id": .string("native-formatter"), "argv": .array([.string("--version")]),
            ]), context: .empty))
      }
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

  private static func callOwnedProvider(
    registration: CLICommandConfig, tree: CLITree, project: URL,
    name: String, arguments: JSONValue, executableDigest: Data
  ) async throws -> JSONValue {
    let execution = CLIProcessExecution(
      launcher: testExecutionLauncher(), inheritsEnvironment: false)
    let provider = CLITreeToolProvider(
      registration: registration, tree: tree, project: project, execution: execution,
      timeoutMilliseconds: 5_000, maxOutputBytes: 4_096)
    do {
      let result = try await BlockingOperationExecutor(label: "native-formatter-owner").perform {
        try #require(registration.id == "native-formatter" && !registration.allowAnyArgs)
        try #require(registration.env.isEmpty && registration.interpreterBindings.isEmpty)
        try #require(try digest(registration.executable) == executableDigest)
        let commandID = name.hasSuffix("_lint") ? "lint" : "format"
        try #require(name.hasSuffix("_" + commandID))
        let command = try #require(tree.commands.first { $0.id == commandID })
        try #require(command.path == [commandID] || commandID == "format" && command.path.isEmpty)
        var expected: [String: JSONValue] = [
          "paths": .array([.string("-")]), "source": .string("let value=1\n"),
          "configuration": .string("{}"), "color_diagnostics": .bool(false),
        ]
        if commandID == "lint" { expected["strict"] = .bool(true) }
        try #require(arguments == .object(expected))
        try #require(
          tree.executableChecks.allSatisfy {
            $0.args == ["--version"] || $0.args == ["--experimental-dump-help"]
          })
        let administration = ExecutionAdministration(
          mode: .fullAccess,
          environment: try ExecutionEnvironment(fullAccessVariables: ["PATH": "/usr/bin:/bin"]))
        return try ExecutionAdministration.$current.withValue(administration) {
          try provider.callTool(.init(name: name, arguments: arguments, context: .empty))
        }
      }
      await execution.shutdown()
      return result
    } catch {
      await execution.shutdown()
      throw error
    }
  }

  private static func result(_ value: JSONValue) -> [String: JSONValue]? {
    value.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue
  }

  private static func digest(_ path: String) throws -> Data {
    Data(SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path))))
  }
}
