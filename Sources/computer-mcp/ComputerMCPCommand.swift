import ArgumentParser
import ComputerMCP
import Foundation

@main
struct ComputerMCPCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "computer-mcp",
    abstract: "Policy-enforced MCP gateway for macOS.",
    version: ComputerMCPCLI.releaseVersion,
    subcommands: [
      App.self,
      Doctor.self,
      BuildInfo.self,
      Config.self,
      Workspace.self,
      Profile.self,
      Permissions.self,
      Tunnel.self,
      CodexControl.self,
      Tools.self,
      Audit.self,
      Providers.self,
      Install.self,
      Uninstall.self,
      Serve.self,
      Bridge.self,
    ]
  )
}

struct Serve: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "serve",
    abstract: "Run a standalone development gateway.",
    subcommands: [ServeStdio.self, ServeHTTP.self]
  )
}

struct StandaloneRuntimeOptions: ParsableArguments {
  @Option(name: .long, help: "Path to computer-mcp TOML configuration.")
  var config: String

  @Option(name: .long, help: "Bound caller identity for policy evaluation.")
  var caller: GatewayCallerKind?

  @Option(name: .long, help: "Bound gateway profile for policy evaluation.")
  var profile: GatewayProfileID?

  @Option(name: .long, help: "Optional default stable workspace id.")
  var workspaceID: String?

  @Option(
    name: .long,
    help: "Optional persistent Gateway database path for explicit standalone validation."
  )
  var database: String?

  func makeDatabase() throws -> GatewayDatabase {
    if let database {
      return try GatewayDatabase(path: URL(fileURLWithPath: database).standardizedFileURL.path)
    }
    return try GatewayDatabase(inMemory: ())
  }
}

struct ServeStdio: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "stdio",
    abstract: "Serve MCP over standard input and output."
  )

  @OptionGroup var runtime: StandaloneRuntimeOptions

  func run() async throws {
    let gateway = try GatewayConfiguration.load(path: runtime.config)
    let context = gateway.executionContext(
      caller: runtime.caller,
      profileID: runtime.profile,
      workspaceID: runtime.workspaceID,
      transportTrace: GatewayTransportTrace(transport: "stdio")
    )
    let registry = try GatewayRuntime(
      configuration: gateway,
      context: context,
      database: try runtime.makeDatabase()
    )
    try await MCPRuntimeAdapter.runStdioGateway(configuration: gateway, registry: registry)
  }
}

struct ServeHTTP: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "http",
    abstract: "Serve MCP over loopback Streamable HTTP."
  )

  @OptionGroup var runtime: StandaloneRuntimeOptions
  @Option(name: .long, help: "HTTP host override.") var host: String?
  @Option(name: .long, help: "HTTP port override.") var port: Int?
  @Option(name: .long, help: "Public base URL override.") var publicBaseURL: String?

  func run() async throws {
    let gateway = try GatewayConfiguration.load(path: runtime.config)
    let registry = try GatewayRuntime(
      configuration: gateway,
      context: gateway.executionContext(
        caller: runtime.caller,
        profileID: runtime.profile,
        workspaceID: runtime.workspaceID,
        transportTrace: GatewayTransportTrace(transport: "streamable_http")
      ),
      database: try runtime.makeDatabase()
    )
    try await MCPRuntimeAdapter.runHTTPGateway(
      configuration: gateway,
      registry: registry,
      host: host,
      port: port,
      publicBaseURL: publicBaseURL
    )
  }
}

struct Bridge: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "bridge",
    abstract: "Bridge MCP stdio to the app-hosted private Unix socket."
  )

  @Option(name: .long, help: "Path to the Computer MCP Unix-domain socket.")
  var socket: String?

  @Option(
    name: .long,
    help: "Path to the App-generated private Tunnel bridge credential."
  )
  var tunnelCredentialFile: String?

  @Option(name: .long, help: "Stable Tunnel profile id used for provenance.")
  var tunnelProfileID: String?

  @Option(
    name: .long,
    help:
      "Local bridge identity: local-mcp or local-cli. Mutually exclusive with Tunnel credentials."
  )
  var clientIdentity: BridgeClientIdentity?

  mutating func run() async throws {
    guard (tunnelCredentialFile == nil) == (tunnelProfileID == nil) else {
      throw ValidationError(
        "--tunnel-credential-file and --tunnel-profile-id must be provided together."
      )
    }
    guard tunnelCredentialFile == nil || clientIdentity == nil else {
      throw ValidationError(
        "--client-identity cannot be combined with Tunnel credential options."
      )
    }
    let socketPath: String
    if let socket {
      socketPath = socket
    } else {
      socketPath = try AppControlPlaneServiceDirectories.standard().gatewaySocket.path
    }
    let credentialURL = tunnelCredentialFile.map {
      URL(fileURLWithPath: $0).standardizedFileURL
    }
    let resolvedClientIdentity: GatewaySocketClientIdentity
    if let credentialURL, let tunnelProfileID {
      resolvedClientIdentity = .secureTunnel(
        credentialFile: credentialURL,
        tunnelInstanceID: UUID().uuidString,
        tunnelProfileID: tunnelProfileID
      )
    } else {
      resolvedClientIdentity = (clientIdentity ?? .localMCP).gatewayIdentity
    }
    try await GatewayStdioSocketBridge.run(
      configuration: GatewaySocketConfiguration(
        socketURL: URL(fileURLWithPath: socketPath),
        tunnelCredentialFile: credentialURL,
        clientIdentity: resolvedClientIdentity
      )
    )
  }
}

struct Tools: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tools",
    abstract: "Inspect or call exposed MCP tools.",
    subcommands: [ToolsList.self, ToolsInspect.self, ToolsCall.self, ToolsInventory.self]
  )
}

struct ToolConnectionOptions: ParsableArguments {
  @Option(
    name: .long,
    help: "Path to a schema-1 TOML manifest for explicit standalone development mode."
  )
  var config: String?

  @Option(name: .long, help: "Standalone caller identity; requires --config.")
  var caller: GatewayCallerKind?

  @Option(name: .long, help: "Standalone gateway profile; requires --config.")
  var profile: GatewayProfileID?

  @Option(name: .long, help: "Standalone default workspace ID; requires --config.")
  var workspaceID: String?

  func validateMode() throws {
    guard config == nil else { return }
    let standaloneOptions = caller != nil || profile != nil || workspaceID != nil
    guard !standaloneOptions else {
      throw ValidationError("--caller, --profile, and --workspace-id require --config.")
    }
  }
}

struct ToolsList: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "list")
  @OptionGroup var connection: ToolConnectionOptions

  func run() async throws {
    try connection.validateMode()
    guard let config = connection.config else {
      printJSON(try await AppControlPlaneServiceClient.live().call("tools.list"))
      return
    }
    let gateway = try GatewayConfiguration.load(path: config)
    let registry = try GatewayRuntime(
      configuration: gateway,
      context: gateway.executionContext(
        caller: connection.caller,
        profileID: connection.profile,
        workspaceID: connection.workspaceID
      ),
      database: GatewayDatabase(inMemory: ())
    )
    let surface = GatewayMCPToolSurface(registry: registry)
    printJSON(.object(["tools": .array(try surface.listTools().map(\.json))]))
  }
}

struct ToolsInspect: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "inspect")
  @Argument(help: "Tool name.") var name: String
  @OptionGroup var connection: ToolConnectionOptions

  func run() async throws {
    try connection.validateMode()
    if connection.config == nil {
      printJSON(
        try await AppControlPlaneServiceClient.live().call(
          "tools.inspect",
          arguments: .object(["name": .string(name)])
        )
      )
      return
    }
    let surface = try standaloneToolSurface(connection)
    guard let tool = try surface.listTools().first(where: { $0.name == name }) else {
      throw ValidationError("Unknown tool: \(name)")
    }
    printJSON(tool.json)
  }
}

struct ToolsCall: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "call")
  @Argument(help: "Tool name.") var name: String
  @Option(name: .long, help: "JSON object arguments.") var argumentsJSON = "{}"
  @OptionGroup var connection: ToolConnectionOptions

  func run() async throws {
    try connection.validateMode()
    let arguments = try decodeArguments(argumentsJSON)
    if connection.config == nil {
      let result = try await AppControlPlaneServiceClient.live().call(
        "tools.call",
        arguments: .object([
          "name": .string(name),
          "arguments": arguments,
        ])
      )
      printJSON(result)
      if result.objectValue?["isError"]?.boolValue == true {
        throw ExitCode.failure
      }
      return
    }
    printJSON(
      try await standaloneToolSurface(connection).callToolAsync(
        name: name,
        arguments: arguments
      ))
  }
}

private func standaloneToolSurface(
  _ options: ToolConnectionOptions
) throws -> GatewayMCPToolSurface {
  guard let config = options.config else {
    throw ValidationError("A standalone tool surface requires --config.")
  }
  let gateway = try GatewayConfiguration.load(path: config)
  let registry = try GatewayRuntime(
    configuration: gateway,
    context: gateway.executionContext(
      caller: options.caller,
      profileID: options.profile,
      workspaceID: options.workspaceID
    ),
    database: GatewayDatabase(inMemory: ())
  )
  return GatewayMCPToolSurface(registry: registry)
}

extension GatewayCallerKind: ExpressibleByArgument {}
extension GatewayProfileID: ExpressibleByArgument {}

struct Config: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "config",
    abstract: "Inspect and validate gateway configuration.",
    subcommands: [
      ConfigPath.self,
      ConfigShow.self,
      ConfigDefaults.self,
      Validate.self,
      ConfigExport.self,
      ConfigImport.self,
      ConfigHistory.self,
      ConfigRollback.self,
    ]
  )
}

struct Validate: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "validate",
    abstract: "Validate a TOML registry configuration."
  )

  @Option(name: .long, help: "Path to computer-mcp TOML configuration.")
  var config: String?

  @Flag(name: .long, help: "Also connect to downstream MCP servers and list their tools.")
  var connect = false

  mutating func run() async throws {
    guard let config else {
      printJSON(try await AppControlPlaneServiceClient.live().call("config.validate"))
      return
    }
    let gateway = try GatewayConfiguration.load(path: config)
    try gateway.validate()
    var object: [String: JSONValue] = ["ok": .bool(true)]
    if connect {
      let client = MCPProxyClient()
      object["mcp"] = .array(
        try gateway.mcp.servers.map { server in
          let tools = try client.listTools(server: server)
          return .object([
            "id": .string(server.id),
            "ok": .bool(true),
            "tools": .array(tools.map(\.json)),
          ])
        })
    }
    printJSON(.object(object))
  }
}

struct Install: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "install",
    abstract: "Install computer-mcp into local MCP clients.",
    subcommands: [CLIInstall.self, Codex.self]
  )
}

struct Uninstall: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "uninstall",
    abstract: "Remove user-scoped Computer MCP integrations.",
    subcommands: [CLIUninstall.self]
  )
}

struct Codex: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "codex",
    abstract: "Register this gateway as an external MCP server for Codex."
  )

  @Option(name: .long, help: "Path to a standalone computer-mcp TOML configuration.")
  var config: String?

  @Flag(name: .long, help: "Register the App-owned bridge without using a TOML manifest.")
  var app = false

  @Option(name: .long, help: "MCP server name to register in Codex.")
  var name = "computer-mcp"

  @Option(name: .long, help: "Optional path to Codex CLI.")
  var codexCLI: String?

  @Option(name: .long, help: "Optional path to the computer-mcp executable.")
  var serverExecutable: String?

  @Flag(name: .long, help: "Print the planned codex mcp add invocation without running it.")
  var dryRun = false

  mutating func run() throws {
    guard app != (config != nil) else {
      throw ValidationError("Pass exactly one of --app or --config.")
    }
    let executablePath = try serverExecutable ?? currentExecutableURL().path
    let installer = CodexMCPInstaller()
    let invocation: CodexMCPInstallInvocation
    if app {
      invocation = try installer.planApp(
        codexCLI: codexCLI,
        serverName: name,
        executablePath: executablePath
      )
    } else {
      guard let config else {
        throw ValidationError("--config is required outside App mode.")
      }
      _ = try GatewayConfiguration.load(path: config)
      invocation = try installer.plan(
        codexCLI: codexCLI,
        serverName: name,
        configPath: config,
        executablePath: executablePath
      )
    }

    if dryRun {
      printJSON(try JSONValue.encoded(invocation))
      return
    }

    let result: CommandResult
    if app {
      result = try installer.installApp(
        codexCLI: codexCLI,
        serverName: name,
        executablePath: executablePath
      )
    } else {
      guard let config else {
        throw ValidationError("--config is required outside App mode.")
      }
      result = try installer.install(
        codexCLI: codexCLI,
        serverName: name,
        configPath: config,
        executablePath: executablePath
      )
    }
    if !result.stdout.isEmpty {
      print(result.stdout, terminator: "")
    }
    if !result.stderr.isEmpty {
      fputs(result.stderr, stderr)
    }
    throw ExitCode(result.exitCode ?? 0)
  }
}

func printJSON(_ value: JSONValue) {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

  do {
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
  } catch {
    fputs("Could not encode JSON: \(error.localizedDescription)\n", stderr)
    Foundation.exit(1)
  }
}

func decodeArguments(_ text: String) throws -> JSONValue {
  let data = Data(text.utf8)
  let value = try JSONDecoder().decode(JSONValue.self, from: data)
  guard value.objectValue != nil else {
    throw ValidationError("--arguments-json must be a JSON object.")
  }
  return value
}
