import ComputerMCPMacOS
import ComputerMCPSandbox
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPControlPlane
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPProcess
@testable import ComputerMCPTunnels

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.nativeIntegration, .serialized)

final class ProcessAndOpenAITunnelTests {
  @Test
  func testCommandRunnerCapturesStdout() throws {
    try Self.withLocalProcessAdministration {
      let result = try ProcessCommandRunner(launcher: testExecutionLauncher()).run(
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
  }

  @Test
  func testCommandRunnerDrainsShortOutputUnderConcurrency() async throws {
    let executor = BlockingOperationExecutor(
      label: "computer-mcp.concurrent-command-test", serial: false)
    try await withThrowingTaskGroup(of: Void.self) { group in
      // Bound simultaneous blocking calls while exercising 128 independent output drains.
      for lane in 0..<8 {
        group.addTask {
          for index in stride(from: lane, to: 128, by: 8) {
            let expected = "result-\(index)\n"
            let result = try await executor.perform {
              try Self.withLocalProcessAdministration {
                try ProcessCommandRunner(launcher: testExecutionLauncher()).run(
                  executable: "/bin/echo",
                  arguments: ["result-\(index)"],
                  workingDirectory: nil,
                  environment: [:],
                  timeoutMilliseconds: 5_000,
                  maxOutputBytes: 1_024
                )
              }
            }
            #expect(result.exitCode == 0)
            #expect(result.stdout == expected)
          }
        }
      }
      try await group.waitForAll()
    }
  }

  @Test
  func testManagedProcessCanSpawnReadAndCancel() throws {
    try Self.withLocalProcessAdministration {
      let registry = ManagedProcessRegistry(launcher: testExecutionLauncher())
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
  }

  @Test
  func testManagedProcessListReturnsManagedProcesses() throws {
    try Self.withLocalProcessAdministration {
      let registry = ManagedProcessRegistry(launcher: testExecutionLauncher())
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
  }

  @Test
  func testManagedProcessCanCancelRunningProcess() throws {
    try Self.withLocalProcessAdministration {
      let registry = ManagedProcessRegistry(launcher: testExecutionLauncher())
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
  }

  private static func withLocalProcessAdministration<Result>(
    _ operation: () throws -> Result
  ) throws -> Result {
    let administration = ExecutionAdministration(
      mode: .fullAccess,
      environment: try ExecutionEnvironment(fullAccessVariables: ["PATH": "/usr/bin:/bin"]))
    return try ExecutionAdministration.$current.withValue(administration, operation: operation)
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
  func catalogAuditReportsReadAndWriteToolsWithoutAnAuthorityGate() throws {
    let read = try auditTool(
      name: "system.time", readOnly: true, requirement: .privacy(.machineInformation))
    let write = try auditTool(
      name: "file.write", readOnly: false,
      requirement: .init(access: .projectWrite, paths: [.init("path", .write)]))
    let audit = try ChatGPTProfileAuditor().audit(
      registry: AuditToolRegistry(tools: [write, read]))
    #expect(audit.toolCount == 2)
    #expect(audit.readOnlyToolCount == 1)
    #expect(audit.writeCapableToolNames == ["file.write"])
  }

  @Test
  func catalogAuditRejectsAnEmptyCatalog() {
    #expect(throws: ChatGPTProfileAuditError.noTools) {
      try ChatGPTProfileAuditor().audit(registry: AuditToolRegistry(tools: []))
    }
  }

  @Test
  func catalogAuditRequiresExplicitEffectAnnotations() throws {
    let tool = try auditTool(name: "fixture.sample", readOnly: nil)
    #expect(throws: ChatGPTProfileAuditError.missingReadOnlyAnnotations([tool.name])) {
      try ChatGPTProfileAuditor().audit(registry: AuditToolRegistry(tools: [tool]))
    }
  }

  @Test(arguments: ["input-type", "input-properties", "input-required", "output-type"])
  func catalogAuditRequiresUsableObjectSchemas(invalid: String) throws {
    let input: JSONValue
    switch invalid {
    case "input-type": input = .object(["type": .string("array")])
    case "input-properties": input = .object(["type": .string("object"), "properties": .array([])])
    case "input-required":
      input = .object(["type": .string("object"), "required": .array([.bool(true)])])
    default: input = .object(["type": .string("object")])
    }
    let tool = try auditTool(
      name: "fixture.sample", readOnly: true, input: input,
      output: invalid == "output-type" ? .object(["type": .string("array")]) : nil)
    #expect(throws: ChatGPTProfileAuditError.invalidToolSchemas([tool.name])) {
      try ChatGPTProfileAuditor().audit(registry: AuditToolRegistry(tools: [tool]))
    }
  }

  @Test(arguments: [false, true])
  func catalogAuditRequiresHostPermissionDeclarations(malformed: Bool) throws {
    let declaration: JSONValue? = malformed ? .object(["access": .string("invented")]) : nil
    let tool = MCPTool(
      name: "fixture.sample", description: "Fixture",
      inputSchema: .object(["type": .string("object")]), annotations: .init(readOnlyHint: true),
      meta: declaration.map { .object(["computer_mcp": .object(["requirements": $0])]) })
    #expect(throws: ChatGPTProfileAuditError.invalidRequirements([tool.name])) {
      try ChatGPTProfileAuditor().audit(registry: AuditToolRegistry(tools: [tool]))
    }
  }

  private func auditTool(
    name: String, readOnly: Bool?, requirement: ToolRequirement = .none,
    input: JSONValue = .object(["type": .string("object")]), output: JSONValue? = nil
  ) throws -> MCPTool {
    MCPTool(
      name: name, description: "Fixture", inputSchema: input, outputSchema: output,
      annotations: readOnly.map { .init(readOnlyHint: $0) },
      meta: .object(["computer_mcp": .object(["requirements": try .encoded(requirement)])]))
  }

  @Test(arguments: [false, true])
  func tunnelResolverRejectsUnusableExecutables(directory: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = directory ? root : root.appendingPathComponent("missing-interpreter")
    if !directory {
      try Data("#!/nonexistent/computer-mcp-interpreter\nexit 0\n".utf8).write(to: executable)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    #expect(throws: (any Error).self) {
      try OpenAITunnelClientResolver(
        executableSearchDirectories: MacOSPlatform.services(launcher: testExecutionLauncher())
          .executableSearchDirectories
      ).resolve(
        requestedPath: executable.path,
        configuration: GatewayConfiguration(projectDirectory: root))
    }
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

private struct AuditToolRegistry: GatewayToolServing {
  let tools: [MCPTool]
  func listTools(context: InvocationContext) throws -> [MCPTool] { tools }
  func callTool(name: String, arguments: JSONValue?, context: InvocationContext) throws -> JSONValue
  {
    throw GatewayToolError.unknownTool(name)
  }
}
