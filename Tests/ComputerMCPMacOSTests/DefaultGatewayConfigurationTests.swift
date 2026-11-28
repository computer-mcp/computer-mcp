import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPControlPlane
@testable import ComputerMCPCore
@testable import ComputerMCPGateway

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite

final class DefaultGatewayConfigurationTests {
  @Test(arguments: [false, true])
  func testDefaultManifestPreservesCodexEntryAcrossUpgrade(linkDirectory: Bool) throws {
    let fixture = try DefaultManifestFixture()
    defer { fixture.cleanup() }
    let manager = FileManager.default
    let bin = fixture.root.appendingPathComponent("bin")
    let firstVersion = fixture.root.appendingPathComponent("Caskroom/codex/1.0/bin")
    let nextVersion = fixture.root.appendingPathComponent("Caskroom/codex/2.0/bin")
    for directory in [firstVersion, nextVersion] {
      try manager.createDirectory(at: directory, withIntermediateDirectories: true)
      let executable = directory.appendingPathComponent("codex")
      try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
      try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }
    let entry = bin.appendingPathComponent("codex")
    let link = linkDirectory ? bin : entry
    if !linkDirectory {
      try manager.createDirectory(at: bin, withIntermediateDirectories: true)
    }
    try manager.createSymbolicLink(
      at: link,
      withDestinationURL: linkDirectory
        ? firstVersion : firstVersion.appendingPathComponent("codex"))

    let manifest = DefaultGatewayConfiguration.makeManifest(
      environment: ["PATH": bin.path], homeDirectory: fixture.root)
    try manifest.write(to: fixture.manifest, atomically: true, encoding: .utf8)
    let configuration = try GatewayConfiguration.load(path: fixture.manifest.path)
    let command = try #require(configuration.cli.commands.first { $0.id == "codex" })
    #expect(command.executable == entry.standardizedFileURL.path)

    try manager.removeItem(at: link)
    try manager.createSymbolicLink(
      at: link,
      withDestinationURL: linkDirectory ? nextVersion : nextVersion.appendingPathComponent("codex"))
    try manager.removeItem(at: firstVersion)

    let reloaded = try GatewayConfiguration.load(path: fixture.manifest.path)
    let savedCommand = try #require(reloaded.cli.commands.first { $0.id == "codex" })
    #expect(savedCommand.executable == command.executable)
    #expect(manager.isExecutableFile(atPath: savedCommand.executable))
    #expect(
      URL(fileURLWithPath: savedCommand.executable).resolvingSymlinksInPath()
        == nextVersion.appendingPathComponent("codex").resolvingSymlinksInPath())
  }

  @Test
  func testDefaultManifestDefinesCompleteExplicitProfileBoundaries() throws {
    let fixture = try DefaultManifestFixture()
    defer { fixture.cleanup() }
    let configuration = try GatewayConfiguration.load(path: fixture.manifest.path)

    #expect(!(configuration.policy.shellEnabled))
    #expect(
      (configuration.skills.roots.map(\.id))
        == ([
          "codex-user", "codex-system", "agents-user",
        ]))
    #expect(configuration.cli.commands.map(\.id) == ["git", "swift", "codex"])

    for configured in configuration.profiles {
      let profile = configured.grant
      #expect(profile.permissions.entries == Permissions.newPrincipal.entries)
      #expect(profile.projectNetworks.isEmpty)
      #expect(!profile.fullAccess)
    }
    #expect(configuration.profileGrant(for: .chatGPTObserve).allowedCallers == [.secureTunnel])
    #expect(configuration.profileGrant(for: .chatGPTOperate).allowedCallers == [.secureTunnel])
    #expect(
      configuration.profileGrant(for: .localAdmin).allowedCallers == [
        .localApp, .localCLI, .localMCP,
      ])
    #expect(configuration.builtin.enabled.contains("file.write"))
    #expect(configuration.builtin.enabled.contains("system.time"))
  }

  @Test
  func testGeneratedConfigurationsBindEachProfileToTheCorrectCaller() throws {
    let observe = try DefaultGatewayConfiguration.configuration(for: .chatGPTObserve)
    let operate = try DefaultGatewayConfiguration.configuration(for: .chatGPTOperate)
    let localAdmin = try DefaultGatewayConfiguration.configuration(for: .localAdmin)

    #expect((observe.runtime.caller) == (.secureTunnel))
    #expect((observe.runtime.profileID) == (.chatGPTObserve))
    #expect((operate.runtime.caller) == (.secureTunnel))
    #expect((operate.runtime.profileID) == (.chatGPTOperate))
    #expect((localAdmin.runtime.caller) == (.localMCP))
    #expect((localAdmin.runtime.profileID) == (.localAdmin))

    let localGateway = try GatewayRuntime(
      configuration: localAdmin,
      context: .init(
        caller: .localMCP, profileID: .localAdmin,
        trustedPrincipalID: "verified-default-profile"),
      database: GatewayDatabase(inMemory: ()),
      platform: MacOSPlatform.services(launcher: testExecutionLauncher())
    )
    let localNames = Set(try localGateway.listTools(context: .empty).map(\.name))
    #expect(localNames.contains("cli.exec"))
    #expect(localNames.contains("process.spawn"))
    #expect(!(localNames.contains("shell.run")))
  }
}

private final class DefaultManifestFixture {
  let root: URL
  let manifest: URL
  let project: URL

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    manifest = root.appendingPathComponent("computer-mcp.toml")
    project = root.appendingPathComponent("Project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try DefaultGatewayConfiguration.manifest.write(
      to: manifest,
      atomically: true,
      encoding: .utf8
    )
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }
}
