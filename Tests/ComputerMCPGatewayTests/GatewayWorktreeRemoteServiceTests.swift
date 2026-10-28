import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPPermissions
import ComputerMCPPlatform
import ComputerMCPProcess
import ComputerMCPTestSupport
import ComputerMCPToolKit
import ComputerMCPToolsMCP
import Foundation
import Testing

@testable import ComputerMCPGateway

@Suite(.nativeIntegration, .serialized)
struct GatewayWorktreeRemoteServiceTests {
  @Test func remoteHTTPCallUsesServiceScopeForAWorktreeProject() async throws {
    let f = try WorktreeServiceFixture()
    defer { f.remove() }
    let made = try f.call(.add(name: "remote", branch: nil, base: nil))
    let id = try #require(made.objectValue?["project_id"]?.stringValue)
    let root = URL(fileURLWithPath: try #require(made.objectValue?["path"]?.stringValue))
    var grant = try #require(try f.database.profiles().first { $0.id == .chatGPTOperate })
    try grant.permissions.set(.granted(.read), for: .mcpServer("remote"))
    try grant.permissions.set(.granted(.access), for: .localNetwork)
    try f.database.saveProfile(grant)
    let endpoint = GatewayHTTPRuntime(
      configuration: .init(), registry: RemoteWorktreeEndpoint(), host: "127.0.0.1", port: 0,
      publicBaseURL: nil)
    try await endpoint.startListening()
    var runtime: GatewayRuntime?
    do {
      let port = try #require(await endpoint.boundPort())
      let configuration = GatewayConfiguration(
        runtime: .init(caller: .secureTunnel, profileID: grant.id),
        profiles: [.init(grant: grant)],
        mcp: .init(servers: [
          .init(
            id: "remote", transport: .streamableHTTP, url: "http://127.0.0.1:\(port)/mcp",
            allowedTools: ["ping"], toolRisks: ["ping": .readOnly])
        ]), projectDirectory: root)
      let services = RemoteWorktreeProviders()
      let platform = PlatformServices(
        launcher: f.platform.launcher, projectGrants: services,
        pluginDirectories: f.platform.pluginDirectories, applications: f.platform.applications,
        toolProviders: services, managementToolNames: [], executableSearchDirectories: [],
        gitExecutable: f.platform.gitExecutable, fileChanges: f.platform.fileChanges,
        permissionPolicyReader: f.platform.permissionPolicyReader)
      let gateway = try GatewayRuntime(
        configuration: configuration,
        context: .init(
          caller: .secureTunnel, profileID: grant.id, projectID: id,
          trustedPrincipalID: "remote-worktree"),
        database: f.database, registeredProjects: f.database.projects(), platform: platform,
        bundledPlugins: .init(packages: [], issues: []))
      runtime = gateway
      let admission = try f.repository().admission(projectID: id)
      let operation = UUID()
      #expect(try admission.close(operationID: operation).isEmpty)
      for (tool, arguments) in [
        ("mcp.tools.list", ["server": JSONValue.string("remote"), "project_id": .string(id)]),
        (
          "mcp.tools.call",
          [
            "server": .string("remote"), "project_id": .string(id), "tool": .string("ping"),
            "arguments": .object([:]),
          ]
        ),
      ] {
        let result = try await gateway.callToolForMCPAsync(
          name: tool, arguments: .object(arguments), context: .empty)
        try #require(result.objectValue?["isError"] != .bool(true), "\(result)")
        if tool == "mcp.tools.call" { #expect(String(describing: result).contains("pong")) }
      }
      #expect(try admission.close(operationID: operation).isEmpty)
      try admission.reopen(operationID: operation)
      await gateway.shutdown()
      await endpoint.stop()
    } catch {
      await runtime?.shutdown()
      await endpoint.stop()
      throw error
    }
  }
}

private struct RemoteWorktreeEndpoint: GatewayAsyncToolServing {
  func listToolsAsync(context: InvocationContext) async throws -> [MCPTool] {
    [
      MCPTool(
        name: "ping", description: "Fixture", inputSchema: .object(["type": .string("object")]))
    ]
  }

  func callToolAsync(name: String, arguments: JSONValue?, context: InvocationContext) async throws
    -> JSONValue
  {
    try #require(name == "ping")
    return .object([
      "content": .array([.object(["type": .string("text"), "text": .string("pong")])])
    ])
  }
}

private struct RemoteWorktreeProviders: ProjectBookmarkServicing, GatewayToolProviderFactory {
  func registerFolder(at url: URL, displayName: String?) throws -> ComputerMCPCore.RegisteredProject
  {
    throw PermissionModelError.invalidAuthorization
  }

  func resolve(_ project: ComputerMCPCore.RegisteredProject) throws -> ResolvedProjectAccess {
    try .init(
      project: project, rootURL: URL(fileURLWithPath: project.rootPath),
      bookmarkWasRefreshed: false,
      stopAccessing: nil)
  }

  func makeProviders(
    configuration: GatewayConfiguration, commandRunner: any CommandRunning,
    processManager: any ProcessManaging, shellManager: any ShellManaging,
    mcpClient: any DownstreamMCPClient, hostContext: MCPHostContext
  ) -> GatewayToolRegistry {
    let environment = ToolEnvironment(
      configuration: configuration, commandRunner: commandRunner, processManager: processManager,
      shellManager: shellManager, environment: [:])
    let client = mcpClient.makeScopedClient(
      workingDirectory: configuration.projectDirectory, environment: [:], hostContext: hostContext)
    let mcp = MCPToolProvider(environment: environment, mcpClient: client)
    return .init(
      providers: { [mcp] },
      downstreamPolicy: { try mcp.downstreamPolicy(for: $0, context: $1) },
      shutdown: { await client.shutdown() })
  }
}
