import Foundation

internal struct OpenAITunnelInvocation: Codable, Equatable, Sendable {
  internal var tunnelClient: String
  internal var arguments: [String]
  internal var mcpCommand: String

  private enum CodingKeys: String, CodingKey {
    case tunnelClient = "tunnel_client"
    case arguments
    case mcpCommand = "mcp_command"
  }

}

internal struct OpenAITunnelPlan: Codable, Equatable, Sendable {
  internal var initInvocation: OpenAITunnelInvocation?
  internal var doctorInvocation: OpenAITunnelInvocation
  internal var runInvocation: OpenAITunnelInvocation

  private enum CodingKeys: String, CodingKey {
    case initInvocation = "init_invocation"
    case doctorInvocation = "doctor_invocation"
    case runInvocation = "run_invocation"
  }

}

internal struct ChatGPTProfileAudit: Codable, Equatable, Sendable {
  internal var toolCount: Int
  internal var readOnlyToolCount: Int
  internal var writeCapableToolNames: [String]

  private enum CodingKeys: String, CodingKey {
    case toolCount = "tool_count"
    case readOnlyToolCount = "read_only_tool_count"
    case writeCapableToolNames = "write_capable_tool_names"
  }

}

internal enum ChatGPTProfileAuditError: Error, LocalizedError, Equatable {
  case noTools
  case missingReadOnlyAnnotations([String])
  case writeToolsRequireExplicitOptIn([String])

  internal var errorDescription: String? {
    switch self {
    case .noTools:
      return "ChatGPT tunnel profile exposes no MCP tools."
    case .missingReadOnlyAnnotations(let names):
      return
        "ChatGPT tunnel tools must declare readOnlyHint explicitly. Missing annotations: \(names.joined(separator: ", "))."
    case .writeToolsRequireExplicitOptIn(let names):
      return
        "ChatGPT Pro supports read/fetch MCP access only. These tools are not read-only: \(names.joined(separator: ", ")). Use a read-only profile, or pass --allow-write-tools only for an eligible Business, Enterprise, or Edu workspace."
    }
  }
}

internal struct ChatGPTProfileAuditor: Sendable {
  internal func audit(
    configuration: GatewayConfiguration,
    registry: any GatewayToolServing,
    allowWriteTools: Bool
  ) throws -> ChatGPTProfileAudit {
    let tools = try GatewayMCPToolSurface(registry: registry).listTools()
    guard !tools.isEmpty else {
      throw ChatGPTProfileAuditError.noTools
    }

    let missingAnnotations =
      tools
      .filter { $0.annotations?.readOnlyHint == nil }
      .map(\.name)
      .sorted()
    guard missingAnnotations.isEmpty else {
      throw ChatGPTProfileAuditError.missingReadOnlyAnnotations(missingAnnotations)
    }

    let writeCapable =
      tools
      .filter { $0.annotations?.readOnlyHint != true }
      .map(\.name)
      .sorted()
    if !allowWriteTools, !writeCapable.isEmpty {
      throw ChatGPTProfileAuditError.writeToolsRequireExplicitOptIn(writeCapable)
    }

    return ChatGPTProfileAudit(
      toolCount: tools.count,
      readOnlyToolCount: tools.count - writeCapable.count,
      writeCapableToolNames: writeCapable
    )
  }
}

internal enum OpenAITunnelLauncherError: Error, LocalizedError, Equatable {
  case missingTunnelClient(String)
  case invalidHTTPProxy(String)

  internal var errorDescription: String? {
    switch self {
    case .missingTunnelClient(let name):
      return
        "Could not find \(name). Install OpenAI Secure MCP Tunnel client and make it available on PATH, or pass --tunnel-client."
    case .invalidHTTPProxy(let detail):
      return "Invalid OpenAI Tunnel HTTP proxy: \(detail)"
    }
  }
}

internal struct OpenAITunnelLauncher: Sendable {
  internal var commandRunner: CommandRunning

  internal init(commandRunner: CommandRunning = ProcessCommandRunner()) {
    self.commandRunner = commandRunner
  }

  internal func plan(
    tunnelClient: String?,
    profile: String,
    configPath: String,
    executablePath: String,
    gatewaySocketPath: String? = nil,
    gatewayProfile: GatewayProfileID = .chatGPTObserve,
    tunnelID: String? = nil,
    profileDirectory: String? = nil,
    httpProxy: String? = nil,
    forceInit: Bool = false
  ) throws -> OpenAITunnelPlan {
    let resolvedTunnelClient = try resolveTunnelClient(tunnelClient)
    let resolvedExecutablePath =
      executablePath.contains("/")
      ? absolutePath(executablePath) : executablePath
    let resolvedConfigPath = absolutePath(configPath)
    let mcpCommand: String
    if let gatewaySocketPath {
      let absoluteSocketPath = absolutePath(gatewaySocketPath)
      let credentialPath = absoluteSocketPath + ".openai-tunnel-auth"
      mcpCommand =
        "\(shellToken(resolvedExecutablePath)) bridge --socket \(shellToken(absoluteSocketPath)) --tunnel-credential-file \(shellToken(credentialPath)) --tunnel-profile-id \(shellToken(profile))"
    } else {
      mcpCommand =
        "\(shellToken(resolvedExecutablePath)) serve stdio --config \(shellToken(resolvedConfigPath)) --caller \(GatewayCallerKind.secureTunnel.rawValue) --profile \(gatewayProfile.rawValue)"
    }
    var initInvocation: OpenAITunnelInvocation?
    if let tunnelID, !tunnelID.isEmpty {
      var initArguments = [
        "init",
        "--sample",
        "sample_mcp_stdio_local",
        "--profile",
        profile,
        "--tunnel-id",
        tunnelID,
        "--mcp-command",
        mcpCommand,
      ]
      if let profileDirectory, !profileDirectory.isEmpty {
        initArguments += ["--profile-dir", profileDirectory]
      }
      if forceInit {
        initArguments.append("--force")
      }
      initInvocation = OpenAITunnelInvocation(
        tunnelClient: resolvedTunnelClient,
        arguments: initArguments,
        mcpCommand: mcpCommand
      )
    }

    var doctorArguments = ["doctor", "--profile", profile, "--explain"]
    var runArguments = ["run", "--profile", profile]
    if let profileDirectory, !profileDirectory.isEmpty {
      doctorArguments += ["--profile-dir", profileDirectory]
      runArguments += ["--profile-dir", profileDirectory]
    }
    if let httpProxy {
      if let failure = openAITunnelHTTPProxyValidationFailure(httpProxy) {
        throw OpenAITunnelLauncherError.invalidHTTPProxy(failure)
      }
      runArguments += ["--http-proxy", httpProxy]
    }

    return OpenAITunnelPlan(
      initInvocation: initInvocation,
      doctorInvocation: OpenAITunnelInvocation(
        tunnelClient: resolvedTunnelClient,
        arguments: doctorArguments,
        mcpCommand: mcpCommand
      ),
      runInvocation: OpenAITunnelInvocation(
        tunnelClient: resolvedTunnelClient,
        arguments: runArguments,
        mcpCommand: mcpCommand
      )
    )
  }

  internal func invocation(
    tunnelClient: String?,
    profile: String,
    configPath: String,
    executablePath: String,
    gatewayProfile: GatewayProfileID = .chatGPTObserve
  ) throws -> OpenAITunnelInvocation {
    try plan(
      tunnelClient: tunnelClient,
      profile: profile,
      configPath: configPath,
      executablePath: executablePath,
      gatewayProfile: gatewayProfile
    ).runInvocation
  }

  internal func runInit(_ invocation: OpenAITunnelInvocation) throws -> CommandResult {
    try commandRunner.run(
      executable: invocation.tunnelClient,
      arguments: invocation.arguments,
      workingDirectory: nil,
      environment: [:],
      timeoutMilliseconds: 30_000,
      maxOutputBytes: 1_048_576
    )
  }

  internal func runDaemon(_ invocation: OpenAITunnelInvocation) throws -> CommandResult {
    try commandRunner.run(
      executable: invocation.tunnelClient,
      arguments: invocation.arguments,
      workingDirectory: nil,
      environment: [:],
      timeoutMilliseconds: 86_400_000,
      maxOutputBytes: 1_048_576
    )
  }

  internal func runDoctor(_ invocation: OpenAITunnelInvocation) throws -> CommandResult {
    try commandRunner.run(
      executable: invocation.tunnelClient,
      arguments: invocation.arguments,
      workingDirectory: nil,
      environment: [:],
      timeoutMilliseconds: 30_000,
      maxOutputBytes: 1_048_576
    )
  }

  internal func run(
    tunnelClient: String?,
    profile: String,
    configPath: String,
    executablePath: String,
    gatewayProfile: GatewayProfileID = .chatGPTObserve,
    tunnelID: String? = nil,
    profileDirectory: String? = nil,
    httpProxy: String? = nil,
    forceInit: Bool = false,
    prepareOnly: Bool = false
  ) throws -> [CommandResult] {
    let plan = try plan(
      tunnelClient: tunnelClient,
      profile: profile,
      configPath: configPath,
      executablePath: executablePath,
      gatewayProfile: gatewayProfile,
      tunnelID: tunnelID,
      profileDirectory: profileDirectory,
      httpProxy: httpProxy,
      forceInit: forceInit
    )
    var results: [CommandResult] = []
    if let initInvocation = plan.initInvocation {
      results.append(try runInit(initInvocation))
    }
    let doctorResult = try runDoctor(plan.doctorInvocation)
    results.append(doctorResult)
    guard doctorResult.exitCode == 0, !doctorResult.timedOut else {
      return results
    }
    if !prepareOnly {
      results.append(try runDaemon(plan.runInvocation))
    }
    return results
  }

  private func resolveTunnelClient(_ tunnelClient: String?) throws -> String {
    if let tunnelClient, !tunnelClient.isEmpty {
      if tunnelClient.contains("/") {
        guard FileManager.default.isExecutableFile(atPath: tunnelClient) else {
          throw OpenAITunnelLauncherError.missingTunnelClient(tunnelClient)
        }
        return absolutePath(tunnelClient)
      }
      if let path = findOnPath(tunnelClient) {
        return path
      }
      throw OpenAITunnelLauncherError.missingTunnelClient(tunnelClient)
    }

    if let path = findOnPath("tunnel-client") {
      return path
    }

    throw OpenAITunnelLauncherError.missingTunnelClient("tunnel-client")
  }

  private func absolutePath(_ path: String) -> String {
    URL(
      fileURLWithPath: path,
      relativeTo: URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath,
        isDirectory: true
      )
    )
    .absoluteURL.path
  }

  private func shellToken(_ value: String) -> String {
    let safeCharacters = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-=.,/:@%")
    if value.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
      return value
    }
    return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
  }

  private func findOnPath(_ name: String) -> String? {
    let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
      .split(separator: ":")
      .map(String.init)
    for path in paths {
      let candidate = URL(fileURLWithPath: path).appendingPathComponent(name).path
      if FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }
    return nil
  }
}
