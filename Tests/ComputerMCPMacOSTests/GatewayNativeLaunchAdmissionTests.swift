import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPSandbox
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPlatform
@testable import ComputerMCPProcess

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.nativeIntegration, .timeLimit(.minutes(1)))
struct GatewayNativeLaunchAdmissionTests {
  @Test
  func standaloneFullAccessSettingCannotLaunchNativeServerWithoutConsent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try #require(
      Bundle.module.url(
        forResource: "mcp_native_launch", withExtension: "py", subdirectory: "Fixtures"))
    let configuration = GatewayConfiguration(
      runtime: .init(caller: .localCLI, profileID: .localAdmin),
      projects: [.init(id: "fixture", path: root.path)],
      profiles: [
        .init(
          id: .localAdmin,
          permissions: fixturePermissions([
            .project("fixture"): .granted(.write), .mcpServer("owned"): .granted(.all),
          ]),
          fullAccess: true, allowedCallers: [.localCLI])
      ],
      mcp: .init(servers: [
        .init(
          id: "owned", transport: .stdio, command: "/usr/bin/python3",
          args: [fixture.path, "server", root.path], exposure: .reexport, prefix: "owned",
          allowedTools: ["write"], toolRisks: ["write": .destructive])
      ]))
    let manifest = root.appendingPathComponent("config.toml")
    try Data(configuration.exportedTOML().utf8).write(to: manifest)
    let executable = try nativeGatewayTestExecutable()
    let result = try await BlockingOperationExecutor(label: "gateway-native-admission-test").perform
    {
      let administration = ExecutionAdministration(
        mode: .fullAccess,
        environment: try ExecutionEnvironment(fullAccessVariables: ["PATH": "/usr/bin:/bin"]))
      return try ExecutionAdministration.$current.withValue(administration) {
        try ProcessCommandRunner(launcher: testExecutionLauncher()).run(
          executable: "/usr/bin/python3",
          arguments: ["-I", fixture.path, "driver", root.path, executable.path, manifest.path],
          workingDirectory: root, environment: [:], timeoutMilliseconds: 20_000,
          maxOutputBytes: 1_048_576)
      }
    }
    try #require(result.exitCode == 0, "\(result.stdout)\n\(result.stderr)")
    let receipt = try JSONDecoder().decode(JSONValue.self, from: Data(result.stdout.utf8))
    #expect(receipt.objectValue?["native_started"] == .bool(false))
    #expect(receipt.objectValue?["write_refused"] == .bool(true))
  }

  @Test(arguments: [false, true])
  func providerDiscoveryUsesSandboxRegardlessOfCallerExecutionMode(fullAccess: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let projectRoot = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: false)
    let bundledFixture = try #require(
      Bundle.module.url(
        forResource: "mcp_native_launch", withExtension: "py", subdirectory: "Fixtures"))
    let fixture = root.appendingPathComponent("provider.py")
    try writePythonTestExecutable(String(contentsOf: bundledFixture, encoding: .utf8), to: fixture)
    let database = try fixturePermissionDatabase(
      path: root.appendingPathComponent("gateway.sqlite").path)
    let container = try database.prepareProviderContainer(.localServer("owned"))
    let providerHome = URL(fileURLWithPath: try container.sandbox.home.value)
    let grant = ProfileGrant(
      id: .chatGPTOperate,
      permissions: fixturePermissions([
        .project("fixture"): .granted(.read), .mcpServer("owned"): .granted(.read),
      ]), fullAccess: fullAccess, allowedCallers: [.localMCP])
    try database.saveProfile(grant)
    try database.bootstrapPermissionProfiles([grant])
    let project = ComputerMCPCore.RegisteredProject(
      id: "fixture", displayName: "Fixture", rootPath: projectRoot.path)
    try database.saveProject(project)
    var platform = MacOSPlatform.services(launcher: testExecutionLauncher())
    platform.permissionPolicyReader = TestManagedPolicyReader()
    let session = GatewayControlSession(
      principalID: "verified-native-discovery", profileID: grant.id, caller: .localMCP,
      database: database, profile: .init(grant: grant, persisted: true),
      permissionService: try database.permissionRuntime(platform: platform).service)
    if fullAccess { _ = try session.approveFullAccess(expectedRevision: session.revision) }
    var context = ExecutionContext(
      caller: .localMCP, profileID: grant.id, projectID: project.id,
      trustedPrincipalID: session.principalID)
    context.controlSession = session
    let server = MCPServerConfig(
      id: "owned", transport: .stdio, command: fixture.path,
      args: ["server", providerHome.path], exposure: .reexport, prefix: "owned",
      allowedTools: ["write"], toolRisks: ["write": .destructive])
    let runtime = try GatewayRuntime(
      configuration: GatewayConfiguration(
        runtime: .init(caller: .localMCP, profileID: grant.id), profiles: [.init(grant: grant)],
        mcp: .init(servers: [
          server
        ]),
        projectDirectory: projectRoot),
      context: context, database: database, registeredProjects: [project], platform: platform,
      bundledPlugins: .init(packages: [], issues: []))
    try fixtureApproveLocalProvider(
      server, database: database,
      runtime: database.permissionRuntime(platform: platform), permissions: .newPrincipal,
      fullAccess: false)
    do {
      #expect(
        !FileManager.default.fileExists(
          atPath: providerHome.appendingPathComponent("native-started").path))
      #expect(ExecutionAdministration.current == nil)
      let report = try await runtime.callToolForMCPAsync(
        name: "mcp.tools.list", arguments: .object(["server": .string("owned")]), context: .empty)
      #expect(report.objectValue?["isError"] == .bool(false), "\(report)")
      #expect(
        report.objectValue?["structuredContent"]?.objectValue?["result"]?.arrayValue?
          .compactMap { $0.objectValue?["name"]?.stringValue } == ["write"])
      #expect(
        FileManager.default.fileExists(
          atPath: providerHome.appendingPathComponent("native-started").path))
      #expect(
        !FileManager.default.fileExists(
          atPath: providerHome.appendingPathComponent("write-dispatched").path))
      #expect((session.snapshot.fullAccessConsent == nil) == !fullAccess)
      await runtime.shutdown()
    } catch {
      await runtime.shutdown()
      throw error
    }
  }

  @Test
  func nativeLauncherRequiresAuthorityBeforeStartingAnExactCommand() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let marker = root.appendingPathComponent("no-context-started")
    #expect(ExecutionAdministration.current == nil)
    #expect(try PreparedExecutionContext.current() == nil)
    do {
      let child = try await testExecutionLauncher().start(
        executable: SandboxPath("/usr/bin/touch"), arguments: [marker.path],
        directory: SandboxPath(root.path),
        environment: ExecutionEnvironment(fullAccessVariables: [:]),
        mode: .fullAccess)
      _ = try await child.wait()
      Issue.record("A native command started without an authorized context")
    } catch ExecutionEnvironmentError.unavailable(let message) {
      #expect(message == "No authorized execution context is installed")
    }
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }

}
