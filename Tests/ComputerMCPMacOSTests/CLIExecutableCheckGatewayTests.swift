import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPPlatform
import ComputerMCPProcess
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPlatformPOSIX
@testable import ComputerMCPToolsCLI

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.nativeIntegration, .timeLimit(.minutes(1)))
struct CLIExecutableCheckGatewayTests {
  @Test
  func policyStaticHelpAndCatalogRefreshKeepChecksAtCallTime() async throws {
    let fixture = try GatewayExecutableCheckFixture()
    defer { fixture.cleanup() }
    try fixture.script(
      """
      if [ "$1" = "--version" ]; then
        printf probe >> probes
        /bin/cat version
        exit 0
      fi
      printf target >> action
      """)
    try Data("one".utf8).write(to: fixture.file("version"))
    try JSONEncoder().encode(Self.tree([.init(args: ["--version"], stdout: "one")]))
      .write(to: fixture.file("tree.json"))
    var configuration = GatewayConfiguration(
      runtime: .init(caller: .localCLI, profileID: .localAdmin))
    configuration.projectDirectory = fixture.root
    configuration.cli.commands = [
      .init(
        id: "checked", executable: fixture.file("tool").path,
        allowAnyArgs: false, tree: .init(kind: .file, path: fixture.file("tree.json").path))
    ]
    let observations = ExecutionObservations()
    let environment = ToolEnvironment(
      launcher: testExecutionLauncher(observations: observations), configuration: configuration)
    let provider = CLIToolProvider(environment: environment)
    let router = try GatewayProviderRouter(
      source: { [provider] + (try provider.treeProviders()) },
      shutdownSource: { await environment.registeredCommands.execution.shutdown() })
    do {
      let tool = try #require(router.listTools(context: .empty).first { $0.name.hasPrefix("cli_") })
      #expect(
        tool.meta?.objectValue?["cli"]?.objectValue?["compatibility"]
          == .string("required_before_call"))
      _ = try router.callTool(
        name: "cli.help", arguments: .object(["id": .string("checked")]), context: .empty)
      #expect(!fixture.exists("probes"))
      #expect(observations.members.isEmpty)
      let profile = ProfileGrantConfig(
        id: .chatGPTObserve, permissions: fixturePermissions([.project("fixture"): .denied]),
        allowedCallers: [.secureTunnel])
      var observeConfiguration = configuration
      observeConfiguration.profiles = [profile]
      let database = try fixturePermissionDatabase(path: fixture.file("gateway.sqlite").path)
      try database.bootstrapPermissionProfiles([profile.grant])
      let project = ComputerMCPCore.RegisteredProject(
        id: "fixture", displayName: "Fixture", rootPath: fixture.root.path)
      try database.saveProject(project)
      var platform = MacOSPlatform.services(launcher: testExecutionLauncher())
      platform.permissionPolicyReader = TestManagedPolicyReader()
      let observe = try await GatewayRuntime.make(
        configuration: observeConfiguration,
        context: .init(
          caller: .secureTunnel, profileID: .chatGPTObserve,
          trustedPrincipalID: "cli-check-observer"),
        database: database, registeredProjects: [project], platform: platform,
        bundledPlugins: .load(directory: nil))
      let listed = try #require(
        await observe.listToolsAsync(context: .empty).first { $0.name == tool.name })
      #expect(listed.meta?.objectValue?["computer_mcp"]?.objectValue?["requirements"] != nil)
      do {
        _ = try await observe.callToolAsync(
          name: tool.name, arguments: .object(["project_id": .string("fixture")]), context: .empty)
        Issue.record("A denied Project grant must prevent compatibility checks and execution")
      } catch {
        #expect((error as? GatewayPermissionCallError)?.code == "permission.denied")
      }
      await observe.shutdown()
      #expect(!fixture.exists("probes"))
      #expect(observations.members.isEmpty)
      _ = try await fixture.callTool(router: router, name: tool.name)
      try #require(fixture.exists("action"))
      try FileManager.default.removeItem(at: fixture.file("action"))
      try Data("two".utf8).write(to: fixture.file("version"))
      await #expect(throws: CLITreeError.self) {
        try await fixture.callTool(router: router, name: tool.name)
      }
      #expect(!fixture.exists("action"))
      try Data("invalid".utf8).write(to: fixture.file("tree.json"))
      await #expect(throws: (any Error).self) { try await router.refreshTools(context: .empty) }
      await #expect(throws: CLITreeError.self) {
        try await fixture.callTool(router: router, name: tool.name)
      }
      #expect(!fixture.exists("action"))
      try JSONEncoder().encode(Self.tree([.init(args: ["--version"], stdout: "two")]))
        .write(to: fixture.file("tree.json"))
      try await router.refreshTools(context: .empty)
      _ = try await fixture.callTool(router: router, name: tool.name)
      #expect(try String(contentsOf: fixture.file("action"), encoding: .utf8) == "target")
      #expect(observations.members.count == 6)
      #expect(
        try String(contentsOf: fixture.file("probes"), encoding: .utf8) == "probeprobeprobeprobe")
    } catch {
      await router.shutdown()
      throw error
    }
    await router.shutdown()
  }

  private static func tree(_ checks: [CLIExecutableCheck]) -> CLITree {
    .init(
      formatVersion: 1, source: "owned fixture", executableVersion: "fixture",
      coverage: .complete, omissions: [],
      commands: [.init(id: "run", path: [], description: "Fixture action")],
      executableChecks: checks)
  }

}

private struct GatewayExecutableCheckFixture: Sendable {
  let root: URL
  init() throws {
    let candidate = FileManager.default.temporaryDirectory.appendingPathComponent(
      "cli-check-\(UUID().uuidString)"
    )
    try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
    root = try ProjectPathResolver.canonicalProject(candidate)
  }
  func file(_ name: String) -> URL { root.appendingPathComponent(name) }
  func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: file(name).path) }
  func script(_ body: String, name: String = "tool", shebang: String = "#!/bin/sh") throws {
    try Data("\(shebang)\n\(body)\n".utf8).write(to: file(name), options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file(name).path)
  }
  func callTool(router: GatewayProviderRouter, name: String) async throws -> JSONValue {
    try await BlockingOperationExecutor(label: "test.cli-compatibility").perform {
      let administration = ExecutionAdministration(
        mode: .fullAccess,
        environment: try .init(fullAccessVariables: [
          "HOME": root.path, "ZDOTDIR": root.path, "TMPDIR": root.path + "/",
          "PATH": systemUtilityPath,
        ]))
      return try ExecutionAdministration.$current.withValue(administration) {
        try router.callTool(name: name, arguments: .object([:]), context: .empty)
      }
    }
  }
  func cleanup() { try? FileManager.default.removeItem(at: root) }
}
