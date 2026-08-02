import Foundation
import Testing

@testable import ComputerMCP

@Suite(.serialized)

final class ProcessAndOpenAITunnelTests {
  @Test
  func testCommandRunnerCapturesStdout() throws {
    let result = try ProcessCommandRunner().run(
      executable: "/bin/echo",
      arguments: ["hello"],
      workingDirectory: nil,
      environment: [:],
      timeoutMilliseconds: 5_000,
      maxOutputBytes: 1024
    )

    #expect((result.exitCode) == (0))
    #expect((result.stdout) == ("hello\n"))
    #expect(!(result.timedOut))
  }

  @Test
  func testManagedProcessCanSpawnReadAndCancel() throws {
    let registry = ManagedProcessRegistry()
    let id = try registry.spawn(
      executable: "/bin/echo",
      arguments: ["process"],
      workingDirectory: nil,
      environment: [:],
      maxOutputBytes: 1024
    )

    Thread.sleep(forTimeInterval: 0.1)
    let snapshot = try registry.read(processID: id)

    #expect((snapshot.processID) == (id))
    #expect((snapshot.stdout) == ("process\n"))
  }

  @Test
  func testManagedProcessListReturnsManagedProcesses() throws {
    let registry = ManagedProcessRegistry()
    let id = try registry.spawn(
      executable: "/bin/echo",
      arguments: ["listed"],
      workingDirectory: nil,
      environment: [:],
      maxOutputBytes: 1024
    )

    Thread.sleep(forTimeInterval: 0.1)
    let snapshots = try registry.list()

    #expect((snapshots.map(\.processID)) == ([id]))
    #expect((snapshots.first?.stdout) == ("listed\n"))
  }

  @Test
  func testManagedProcessCanCancelRunningProcess() throws {
    let registry = ManagedProcessRegistry()
    let id = try registry.spawn(
      executable: "/bin/sleep",
      arguments: ["5"],
      workingDirectory: nil,
      environment: [:],
      maxOutputBytes: 1024
    )

    let result = try registry.cancel(processID: id)

    #expect((result.processID) == (id))
    #expect(result.cancelled)
  }

  @Test
  func testOpenAITunnelInvocationUsesProfileAndConfig() throws {
    let launcher = OpenAITunnelLauncher()
    let invocation = try launcher.plan(
      tunnelClient: "/bin/echo",
      profile: "computer-mcp",
      configPath: "/tmp/computer-mcp.toml",
      executablePath: "/tmp/computer-mcp"
    ).runInvocation

    #expect((invocation.tunnelClient) == ("/bin/echo"))
    #expect((invocation.arguments) == (["run", "--profile", "computer-mcp"]))
    #expect(
      (invocation.mcpCommand)
        == ("/tmp/computer-mcp serve stdio --config /tmp/computer-mcp.toml --caller secure-tunnel --profile chatgpt-observe")
    )
  }

  @Test
  func testOpenAITunnelPlanPassesValidatedHTTPProxyToTunnelClient() throws {
    let plan = try OpenAITunnelLauncher().plan(
      tunnelClient: "/bin/echo",
      profile: "computer-mcp",
      configPath: "/tmp/computer-mcp.toml",
      executablePath: "/tmp/computer-mcp",
      httpProxy: "http://127.0.0.1:6152"
    )

    #expect(
      plan.runInvocation.arguments == [
        "run", "--profile", "computer-mcp", "--http-proxy", "http://127.0.0.1:6152",
      ]
    )
    expectThrows(
      try OpenAITunnelLauncher().plan(
        tunnelClient: "/bin/echo",
        profile: "computer-mcp",
        configPath: "/tmp/computer-mcp.toml",
        executablePath: "/tmp/computer-mcp",
        httpProxy: "http://user:secret@127.0.0.1:6152"
      )
    ) { error in
      #expect(error.localizedDescription.contains("without credentials"))
    }
  }

  @Test
  func testOpenAITunnelPlanInitializesProfileWhenTunnelIDIsProvided() throws {
    let launcher = OpenAITunnelLauncher()
    let plan = try launcher.plan(
      tunnelClient: "/bin/echo",
      profile: "computer-mcp",
      configPath: "/tmp/computer-mcp.toml",
      executablePath: "/tmp/computer-mcp",
      tunnelID: "tunnel_test",
      profileDirectory: "/tmp/profiles",
      forceInit: true
    )

    #expect(
      (plan.initInvocation?.arguments)
        == ([
          "init", "--sample", "sample_mcp_stdio_local", "--profile", "computer-mcp", "--tunnel-id",
          "tunnel_test", "--mcp-command",
          "/tmp/computer-mcp serve stdio --config /tmp/computer-mcp.toml --caller secure-tunnel --profile chatgpt-observe",
          "--profile-dir", "/tmp/profiles", "--force",
        ]))
    #expect(
      (plan.runInvocation.arguments)
        == (["run", "--profile", "computer-mcp", "--profile-dir", "/tmp/profiles"]))
    #expect(
      (plan.doctorInvocation.arguments)
        == (["doctor", "--profile", "computer-mcp", "--explain", "--profile-dir", "/tmp/profiles"]))
  }

  @Test
  func testOpenAITunnelPlanUsesAbsolutePathsForRelativeMCPCommandInputs() throws {
    let launcher = OpenAITunnelLauncher()
    let cwd = FileManager.default.currentDirectoryPath

    let plan = try launcher.plan(
      tunnelClient: "/bin/echo",
      profile: "computer-mcp",
      configPath: "Examples/computer-mcp.toml",
      executablePath: ".build/debug/computer-mcp"
    )

    #expect(
      (plan.runInvocation.mcpCommand)
        == ("\(cwd)/.build/debug/computer-mcp serve stdio --config \(cwd)/Examples/computer-mcp.toml --caller secure-tunnel --profile chatgpt-observe")
    )
  }

  @Test
  func testOpenAITunnelPlanCanBindOperateProfileWithoutChangingTunnelClientProfile() throws {
    let launcher = OpenAITunnelLauncher()
    let plan = try launcher.plan(
      tunnelClient: "/bin/echo",
      profile: "personal-tunnel",
      configPath: "/tmp/computer-mcp.toml",
      executablePath: "/tmp/computer-mcp",
      gatewayProfile: .chatGPTOperate
    )

    #expect((plan.runInvocation.arguments) == (["run", "--profile", "personal-tunnel"]))
    #expect(plan.runInvocation.mcpCommand.contains("--profile chatgpt-operate"))
  }

  @Test
  func testOpenAITunnelPlanUsesAppOwnedSocketBridgeWhenConfigured() throws {
    let launcher = OpenAITunnelLauncher()
    let plan = try launcher.plan(
      tunnelClient: "/bin/echo",
      profile: "personal-tunnel",
      configPath: "/tmp/ignored.toml",
      executablePath: "/Applications/Computer MCP.app/Contents/Resources/computer-mcp",
      gatewaySocketPath:
        "/Users/example/Library/Application Support/Computer MCP/Runtime/gateway.sock",
      gatewayProfile: .chatGPTOperate,
      tunnelID: "tunnel_test"
    )

    #expect(
      (plan.runInvocation.mcpCommand)
        == ("'/Applications/Computer MCP.app/Contents/Resources/computer-mcp' bridge --socket '/Users/example/Library/Application Support/Computer MCP/Runtime/gateway.sock' --tunnel-credential-file '/Users/example/Library/Application Support/Computer MCP/Runtime/gateway.sock.openai-tunnel-auth' --tunnel-profile-id personal-tunnel")
    )
    #expect(!(plan.runInvocation.mcpCommand.contains("serve stdio")))
    #expect(!(plan.runInvocation.mcpCommand.contains("--profile chatgpt-operate")))
    #expect(
      (plan.initInvocation?.arguments.suffix(2))
        == ([
          "--mcp-command",
          "'/Applications/Computer MCP.app/Contents/Resources/computer-mcp' bridge --socket '/Users/example/Library/Application Support/Computer MCP/Runtime/gateway.sock' --tunnel-credential-file '/Users/example/Library/Application Support/Computer MCP/Runtime/gateway.sock.openai-tunnel-auth' --tunnel-profile-id personal-tunnel",
        ]))
  }

  @Test
  func testOpenAITunnelConfigurationDecodesOptionalSocketPath() throws {
    let data = try #require(
      """
      {
        "id": "minimal",
        "tunnel_client_profile": "computer-mcp",
        "tunnel_id": "tunnel_minimal",
        "gateway_profile": "chatgpt-observe",
        "manifest_path": "/tmp/computer-mcp.toml",
        "gateway_executable_path": "/tmp/computer-mcp"
      }
      """.data(using: .utf8)
    )

    let profile = try JSONDecoder().decode(OpenAITunnelConfiguration.self, from: data)

    #expect((profile.gatewaySocketPath) == nil)
    #expect((profile.gatewayProfile) == (.chatGPTObserve))
    #expect(profile.httpProxy == nil)
    expectNoThrow(try profile.validate())
  }

  @Test
  func testChatGPTProfileAuditAcceptsReadOnlyProfile() throws {
    let configuration = GatewayConfiguration.fixture(
      cli: CLISectionConfig(),
      mcp: MCPSectionConfig(),
      builtin: BuiltinConfig(enabled: ["system.time"])
    )

    let audit = try ChatGPTProfileAuditor().audit(
      configuration: configuration,
      registry: GatewayToolRegistry(configuration: configuration),
      allowWriteTools: false
    )

    #expect((audit.toolCount) == (1))
    #expect((audit.readOnlyToolCount) == (1))
    #expect((audit.writeCapableToolNames) == ([]))
  }

  @Test
  func testChatGPTProfileAuditRejectsWriteToolsByDefault() throws {
    let configuration = GatewayConfiguration.fixture(
      mcp: MCPSectionConfig(),
      builtin: BuiltinConfig(enabled: ["file.write"])
    )

    expectThrows(
      try ChatGPTProfileAuditor().audit(
        configuration: configuration,
        registry: GatewayToolRegistry(configuration: configuration),
        allowWriteTools: false
      )
    ) { error in
      #expect(error.localizedDescription.contains("ChatGPT Pro"))
      #expect(error.localizedDescription.contains("file.write"))
    }
  }

  @Test
  func testChatGPTProfileAuditAllowsExplicitWriteToolOptIn() throws {
    let configuration = GatewayConfiguration.fixture(
      mcp: MCPSectionConfig(),
      builtin: BuiltinConfig(enabled: ["file.write"])
    )

    let audit = try ChatGPTProfileAuditor().audit(
      configuration: configuration,
      registry: GatewayToolRegistry(configuration: configuration),
      allowWriteTools: true
    )

    #expect(audit.writeCapableToolNames.contains("file.write"))
  }

  @Test
  func testChatGPTProfileAuditRejectsMissingReadOnlyAnnotation() throws {
    let configuration = GatewayConfiguration.fixture(
      cli: CLISectionConfig(),
      tools: [
        ToolConfig(name: "fake.sample", adapter: .mcp, source: "fake", tool: "sample")
      ]
    )

    expectThrows(
      try ChatGPTProfileAuditor().audit(
        configuration: configuration,
        registry: GatewayToolRegistry(configuration: configuration),
        allowWriteTools: true
      )
    ) { error in
      #expect(error.localizedDescription.contains("readOnlyHint"))
      #expect(error.localizedDescription.contains("fake.sample"))
    }
  }

  @Test
  func testChatGPTProfileAuditAcceptsCanonicalDottedToolNames() throws {
    let configuration = GatewayConfiguration.fixture(
      cli: CLISectionConfig(),
      mcp: MCPSectionConfig(),
      builtin: BuiltinConfig(enabled: ["system.time"])
    )

    let audit = try ChatGPTProfileAuditor().audit(
      configuration: configuration,
      registry: GatewayToolRegistry(configuration: configuration),
      allowWriteTools: false
    )

    #expect((audit.toolCount) == (1))
    #expect((audit.readOnlyToolCount) == (1))
  }

  @Test
  func testCodexInstallPlanBuildsCodexMCPAddInvocation() throws {
    let installer = CodexMCPInstaller()
    let cwd = FileManager.default.currentDirectoryPath

    let invocation = try installer.plan(
      codexCLI: "/bin/echo",
      serverName: "computer-mcp",
      configPath: "Examples/computer-mcp.toml",
      executablePath: "/bin/cat"
    )

    #expect((invocation.codexCLI) == ("/bin/echo"))
    #expect(
      (invocation.arguments)
        == ([
          "mcp", "add", "computer-mcp", "--", "/bin/cat", "serve", "--config",
          "\(cwd)/Examples/computer-mcp.toml",
        ]))
    #expect(
      (invocation.mcpCommand)
        == (["/bin/cat", "serve", "--config", "\(cwd)/Examples/computer-mcp.toml"]))
  }

  @Test
  func testMissingTunnelClientReportsActionableError() {
    let launcher = OpenAITunnelLauncher()

    expectThrows(
      try launcher.invocation(
        tunnelClient: "/definitely/missing/tunnel-client",
        profile: "computer-mcp",
        configPath: "/tmp/config.toml",
        executablePath: "/tmp/computer-mcp"
      )
    ) { error in
      #expect(error.localizedDescription.contains("tunnel-client"))
    }
  }
}
