import ComputerMCPMacOS
import ComputerMCPPlatform
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCP
@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPPlatformPOSIX
@testable import ComputerMCPToolsCLI

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
    configuration.workspaceDirectory = fixture.root
    configuration.cli.commands = [
      .init(
        id: "checked", executable: fixture.file("tool").path,
        allowAnyArgs: false, tree: .init(kind: .file, path: fixture.file("tree.json").path))
    ]
    let environment = ToolEnvironment(configuration: configuration)
    let provider = CLIToolProvider(environment: environment)
    let registry = GatewayToolRegistry(toolEnvironment: environment)
    let router = try GatewayProviderRouter(
      registry: registry, additionalProviders: { [provider] + (try provider.treeProviders()) })
    do {
      let tool = try #require(router.listTools(context: .empty).first { $0.name.hasPrefix("cli_") })
      #expect(
        tool.meta?.objectValue?["cli"]?.objectValue?["compatibility"]
          == .string("required_before_call"))
      _ = try router.callTool(
        name: "cli.help", arguments: .object(["id": .string("checked")]), context: .empty)
      #expect(!fixture.exists("probes"))
      let observe = try GatewayRuntime(
        configuration: configuration,
        context: .init(caller: .secureTunnel, profileID: .chatGPTObserve),
        registeredWorkspaces: [
          .init(id: "fixture", displayName: "Fixture", rootPath: fixture.root.path)
        ], platform: MacOSPlatform.services)
      #expect(try !observe.listTools(context: .empty).contains { $0.name == tool.name })
      await #expect(throws: (any Error).self) {
        try await observe.callToolAsync(name: tool.name, arguments: .object([:]), context: .empty)
      }
      await observe.shutdown()
      #expect(!fixture.exists("probes"))
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
    root = try WorkspacePathResolver.canonicalWorkspace(candidate)
  }
  func file(_ name: String) -> URL { root.appendingPathComponent(name) }
  func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: file(name).path) }
  func script(_ body: String, name: String = "tool", shebang: String = "#!/bin/sh") throws {
    try Data("\(shebang)\n\(body)\n".utf8).write(to: file(name), options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file(name).path)
  }
  func cleanup() { try? FileManager.default.removeItem(at: root) }
}
