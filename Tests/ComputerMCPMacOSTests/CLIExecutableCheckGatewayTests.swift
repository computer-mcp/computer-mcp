import ComputerMCPMacOS
import ComputerMCPPlatform
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
      let observe = try GatewayRuntime(
        configuration: configuration,
        context: .init(caller: .secureTunnel, profileID: .chatGPTObserve),
        registeredProjects: [
          .init(id: "fixture", displayName: "Fixture", rootPath: fixture.root.path)
        ], platform: MacOSPlatform.services(launcher: testExecutionLauncher()))
      #expect(try !observe.listTools(context: .empty).contains { $0.name == tool.name })
      await #expect(throws: (any Error).self) {
        try await observe.callToolAsync(name: tool.name, arguments: .object([:]), context: .empty)
      }
      await observe.shutdown()
      #expect(!fixture.exists("probes"))
      #expect(observations.members.isEmpty)
      _ = try await router.callToolAsync(name: tool.name, arguments: .object([:]), context: .empty)
      try #require(fixture.exists("action"))
      try FileManager.default.removeItem(at: fixture.file("action"))
      try Data("two".utf8).write(to: fixture.file("version"))
      await #expect(throws: CLITreeError.self) {
        try await router.callToolAsync(name: tool.name, arguments: .object([:]), context: .empty)
      }
      #expect(!fixture.exists("action"))
      try Data("invalid".utf8).write(to: fixture.file("tree.json"))
      await #expect(throws: (any Error).self) { try await router.refreshTools(context: .empty) }
      await #expect(throws: CLITreeError.self) {
        try await router.callToolAsync(name: tool.name, arguments: .object([:]), context: .empty)
      }
      #expect(!fixture.exists("action"))
      try JSONEncoder().encode(Self.tree([.init(args: ["--version"], stdout: "two")]))
        .write(to: fixture.file("tree.json"))
      try await router.refreshTools(context: .empty)
      _ = try await router.callToolAsync(name: tool.name, arguments: .object([:]), context: .empty)
      #expect(try String(contentsOf: fixture.file("action"), encoding: .utf8) == "target")
      #expect(observations.members.count == 6)
      #expect(!fixture.exists("probes"))
    } catch {
      await router.shutdown()
      throw error
    }
    await router.shutdown()
  }

  private static func tree(_ checks: [CLIExecutableCheck]) -> CLITree {
    .init(
      formatVersion: 1, source: "isolated fixture", executableVersion: "fixture",
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
  func cleanup() { try? FileManager.default.removeItem(at: root) }
}
