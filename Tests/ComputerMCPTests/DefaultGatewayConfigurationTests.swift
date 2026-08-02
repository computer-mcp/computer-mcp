import Foundation
import Testing

@testable import ComputerMCP

@Suite

final class DefaultGatewayConfigurationTests {
  @Test
  func testDefaultManifestDefinesCompleteExplicitProfileBoundaries() throws {
    let fixture = try DefaultManifestFixture()
    defer { fixture.cleanup() }
    let configuration = try GatewayConfiguration.load(path: fixture.manifest.path)

    #expect(!(configuration.policy.shellEnabled))
    #expect(configuration.codex.enabled)
    #expect(configuration.codex.appServerEnabled)
    #expect(configuration.codex.execEnabled)
    #expect(configuration.codex.mcpEnabled)
    #expect(configuration.codex.experimentalAPI)
    #expect((configuration.codex.sandbox) == (.workspaceWrite))
    #expect((configuration.codex.approvalPolicy) == (.never))
    #expect(
      (configuration.skills.roots.map(\.id))
        == ([
          "codex-user", "codex-system", "agents-user",
        ]))

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
    #expect(observe.workspaces.isEmpty)
    #expect(operate.workspaces.isEmpty)
    #expect((observe.allowedCallers) == ([.secureTunnel]))
    #expect((operate.allowedCallers) == ([.secureTunnel]))
    #expect((Set(localAdmin.allowedCallers)) == ([.localApp, .localCLI, .localMCP]))
    #expect(!(observe.fullShellEnabled))
    #expect(!(operate.fullShellEnabled))
    #expect(localAdmin.fullShellEnabled)

    let operateCapabilities = Set(operate.capabilities)
    #expect(operateCapabilities.contains("file.write"))
    #expect(operateCapabilities.contains("operations.prepare"))
    #expect(operateCapabilities.contains("computer.pointer.click"))
    #expect(operateCapabilities.contains("mcp.tools.call"))
    #expect(operateCapabilities.contains("policy.probe"))
    #expect(operateCapabilities.contains("codex.app.turn.start"))
    #expect(operateCapabilities.contains("codex.exec.start"))
    #expect(operateCapabilities.contains("codex.mcp.run"))
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
      configuration.profiles[index].workspaces = ["workspace"]
    }
    try configuration.validate()
    let workspace = RegisteredWorkspace(
      id: "workspace",
      displayName: "Workspace",
      rootPath: fixture.workspace.path
    )

    let observeGateway = try GatewayRuntime(
      configuration: configuration,
      context: ExecutionContext(
        caller: .secureTunnel,
        profileID: .chatGPTObserve,
        workspaceID: workspace.id
      ),
      registeredWorkspaces: [workspace]
    )
    let observeTools = try observeGateway.listTools()
    #expect(
      (Set(observeTools.map(\.name))) == (Set(DefaultGatewayConfiguration.observeCapabilities)))
    #expect(observeTools.allSatisfy { $0.annotations?.readOnlyHint == true })
    #expect(observeTools.contains { $0.name == "git.commit_files" })
    #expect(!(observeTools.contains { $0.name.hasPrefix("codex.") }))
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
        workspaceID: workspace.id
      ),
      registeredWorkspaces: [workspace]
    )
    let operateNames = Set(try operateGateway.listTools().map(\.name))
    #expect(operateNames.isSuperset(of: Set(observeTools.map(\.name))))
    #expect(operateNames.contains("file.write"))
    #expect(operateNames.contains("computer.keyboard.text"))
    #expect(operateNames.contains("codex.app.status"))
    #expect(operateNames.contains("codex.exec.start"))
    #expect(operateNames.contains("codex.mcp.run"))
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
      database: GatewayDatabase(inMemory: ())
    )
    let localNames = Set(try localGateway.listTools().map(\.name))
    #expect(localNames.contains("cli.exec"))
    #expect(localNames.contains("process.spawn"))
    #expect(!(localNames.contains("shell.run")))
  }
}

private final class DefaultManifestFixture {
  let root: URL
  let manifest: URL
  let workspace: URL

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    manifest = root.appendingPathComponent("computer-mcp.toml")
    workspace = root.appendingPathComponent("Workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
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
