import ComputerMCPMacOS
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

    let observe = try #require(
      configuration.profiles.first { $0.id == .chatGPTObserve }
    )
    let operate = try #require(
      configuration.profiles.first { $0.id == .chatGPTOperate }
    )
    let localAdmin = try #require(
      configuration.profiles.first { $0.id == .localAdmin }
    )
    #expect((Set(observe.capabilities)) == (Set(DefaultGatewayConfiguration.observeCapabilities)))
    #expect((Set(operate.capabilities)) == (Set(DefaultGatewayConfiguration.operateCapabilities)))
    #expect((localAdmin.capabilities) == (["*"]))
    #expect(observe.projects.isEmpty)
    #expect(operate.projects.isEmpty)
    #expect((observe.allowedCallers) == ([.secureTunnel]))
    #expect((operate.allowedCallers) == ([.secureTunnel]))
    #expect((Set(localAdmin.allowedCallers)) == ([.localApp, .localCLI, .localMCP]))
    #expect(!(observe.fullShellEnabled))
    #expect(!(operate.fullShellEnabled))
    #expect(localAdmin.fullShellEnabled)
    #expect(localAdmin.projects == ["*"])
    #expect(localAdmin.mode == .localFullAccess)
    #expect(observe.mode == .readOnly)
    #expect(operate.mode == .projectOperations)
    #expect(configuration.profiles.allSatisfy { $0.confirmationPolicy == .riskBased })

    let operateCapabilities = Set(operate.capabilities)
    #expect(operateCapabilities.contains("file.write"))
    #expect(operateCapabilities.contains("operations.prepare"))
    #expect(operateCapabilities.contains("computer.pointer.click"))
    #expect(operateCapabilities.contains("mcp.tools.call"))
    #expect(operateCapabilities.contains("policy.probe"))
    #expect(operateCapabilities.isDisjoint(with: ProfileGrant.fullShellCapabilities))
    #expect(operateCapabilities.contains("process.list"))
    #expect(!(operateCapabilities.contains("process.read")))
    #expect(!(operateCapabilities.contains("process.cancel")))
  }

  @Test
  func testObserveCatalogIsReadOnlyAndOperateCatalogAddsReviewedWriteProviders() throws {
    let fixture = try DefaultManifestFixture()
    defer { fixture.cleanup() }
    var configuration = try GatewayConfiguration.load(path: fixture.manifest.path)
    for index in configuration.profiles.indices {
      configuration.profiles[index].projects = ["project"]
    }
    try configuration.validate()
    let project = RegisteredProject(
      id: "project",
      displayName: "Project",
      rootPath: fixture.project.path
    )

    let observeGateway = try GatewayRuntime(
      configuration: configuration,
      context: ExecutionContext(
        caller: .secureTunnel,
        profileID: .chatGPTObserve,
        projectID: project.id
      ),
      registeredProjects: [project],
      platform: MacOSPlatform.services(launcher: testExecutionLauncher())
    )
    let observeTools = try observeGateway.listTools(context: .empty)
    #expect(
      (Set(observeTools.map(\.name))) == (Set(DefaultGatewayConfiguration.observeCapabilities)))
    #expect(observeTools.allSatisfy { $0.annotations?.readOnlyHint == true })
    #expect(observeTools.contains { $0.name == "git.commit_files" })
    _ = try ChatGPTProfileAuditor().audit(
      configuration: configuration,
      registry: observeGateway,
      allowWriteTools: false
    )

    let operateGateway = try GatewayRuntime(
      configuration: configuration,
      context: ExecutionContext(
        caller: .secureTunnel,
        profileID: .chatGPTOperate,
        projectID: project.id
      ),
      registeredProjects: [project],
      platform: MacOSPlatform.services(launcher: testExecutionLauncher())
    )
    let operateNames = Set(try operateGateway.listTools(context: .empty).map(\.name))
    #expect(operateNames.isSuperset(of: Set(observeTools.map(\.name))))
    #expect(operateNames.contains("file.write"))
    #expect(operateNames.contains("computer.keyboard.text"))
    #expect(operateNames.contains("policy.probe"))
    #expect(operateNames.contains("process.list"))
    #expect(!(operateNames.contains("cli.exec")))
    #expect(!(operateNames.contains("process.spawn")))
    #expect(!(operateNames.contains { $0.hasPrefix("shell.") }))
    _ = try ChatGPTProfileAuditor().audit(
      configuration: configuration,
      registry: operateGateway,
      allowWriteTools: true
    )
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
