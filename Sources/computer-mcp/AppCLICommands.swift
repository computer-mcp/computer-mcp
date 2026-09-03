import ArgumentParser
import ComputerMCP
import Darwin
import Foundation

struct App: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "app",
    abstract: "Inspect and control the App-owned gateway lifecycle.",
    subcommands: [
      Capabilities.self, Status.self, Start.self, Stop.self, Restart.self, LaunchAtLogin.self,
    ]
  )

  struct Capabilities: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "capabilities")
    func run() throws {
      printJSON(
        .object([
          "schema_version": .number(1),
          "capabilities": try .encoded(AppControlCapabilityCatalog.all),
        ])
      )
    }
  }

  struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status")
    func run() async throws {
      printJSON(
        try await AppControlPlaneServiceClient.live().call(
          "app.status",
          timeout: .seconds(5)
        )
      )
    }
  }

  struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start")
    func run() async throws {
      printJSON(try await AppControlPlaneServiceClient.live().call("app.start"))
    }
  }

  struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop")
    func run() async throws {
      printJSON(try await AppControlPlaneServiceClient.live().call("app.stop"))
    }
  }

  struct Restart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restart")
    func run() async throws {
      printJSON(try await AppControlPlaneServiceClient.live().call("app.restart"))
    }
  }

  struct LaunchAtLogin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "launch-at-login")
    @Flag(name: .long, inversion: .prefixedNo) var enabled = true
    func run() async throws {
      printJSON(
        try await AppControlPlaneServiceClient.live().call(
          "app.launch_at_login",
          arguments: .object(["enabled": .bool(enabled)])
        )
      )
    }
  }
}

struct ConfigPath: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "path")
  func run() async throws {
    let result = try await AppControlPlaneServiceClient.live().call("config.path")
    print(result.objectValue?["path"]?.stringValue ?? "")
  }
}

struct ConfigShow: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "show")
  func run() async throws {
    let result = try await AppControlPlaneServiceClient.live().call("config.show")
    print(result.objectValue?["toml"]?.stringValue ?? "", terminator: "")
  }
}

struct ConfigExport: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "export")

  @Option(name: .long, help: "Destination for the secret-free schema-1 TOML manifest.")
  var output: String?

  func run() async throws {
    let result = try await AppControlPlaneServiceClient.live().call("config.export")
    try writeOrPrint(result.objectValue?["toml"]?.stringValue ?? "", output: output)
  }
}

struct ConfigImport: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "import")

  @Option(name: .long, help: "Current schema-1 TOML manifest to preview or import.")
  var input: String

  @Flag(
    name: .long,
    help: "Apply a previewed import; restart only when the App gateway is already running."
  )
  var apply = false

  @Option(
    name: .long,
    help: "Current digest printed by the preview; required with --apply to prevent races."
  )
  var expectedCurrentDigest: String?

  func run() async throws {
    if apply && expectedCurrentDigest == nil {
      throw ValidationError("--apply requires --expected-current-digest from a prior preview.")
    }
    var arguments: [String: JSONValue] = [
      "toml": .string(try String(contentsOfFile: input, encoding: .utf8)),
      "apply": .bool(apply),
    ]
    if let expectedCurrentDigest {
      arguments["expected_current_digest"] = .string(expectedCurrentDigest)
    }
    printJSON(
      try await AppControlPlaneServiceClient.live().call(
        "config.import",
        arguments: .object(arguments)
      )
    )
  }
}

struct ConfigHistory: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "history")

  @Option(name: .long, help: "Maximum revisions to return (1...200).")
  var limit = 50

  func validate() throws {
    guard (1...200).contains(limit) else {
      throw ValidationError("--limit must be between 1 and 200.")
    }
  }

  func run() async throws {
    printJSON(
      try await AppControlPlaneServiceClient.live().call(
        "config.history",
        arguments: .object(["limit": .number(Double(limit))])
      )
    )
  }
}

struct ConfigRollback: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "rollback")
  @Argument(help: "Stable revision id returned by config history.") var revisionID: String

  func run() async throws {
    printJSON(
      try await AppControlPlaneServiceClient.live().call(
        "config.rollback",
        arguments: .object(["revision_id": .string(revisionID)])
      )
    )
  }
}

struct Workspace: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "workspace",
    subcommands: [
      WorkspaceList.self, WorkspaceAdd.self, WorkspaceRemove.self, WorkspaceEnable.self,
      WorkspaceDeduplicate.self,
    ]
  )
}

struct WorkspaceList: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "list")
  func run() async throws {
    printJSON(try await AppControlPlaneServiceClient.live().call("workspace.list"))
  }
}

struct WorkspaceAdd: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "add")
  @Argument var path: String
  @Option(name: .long) var displayName: String?
  func run() async throws {
    var arguments: [String: JSONValue] = ["path": .string(path)]
    if let displayName { arguments["display_name"] = .string(displayName) }
    printJSON(
      try await AppControlPlaneServiceClient.live().call(
        "workspace.add", arguments: .object(arguments))
    )
  }
}

struct WorkspaceRemove: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "remove")
  @Argument var id: String
  func run() async throws {
    printJSON(
      try await AppControlPlaneServiceClient.live().call(
        "workspace.remove", arguments: .object(["id": .string(id)])
      )
    )
  }
}

struct WorkspaceEnable: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "enable")
  @Argument var id: String
  @Option(name: .long) var profile: String
  @Flag(name: .long, inversion: .prefixedNo) var enabled = true
  func run() async throws {
    printJSON(
      try await AppControlPlaneServiceClient.live().call(
        "workspace.enable",
        arguments: .object([
          "workspace_id": .string(id), "profile": .string(profile), "enabled": .bool(enabled),
        ])
      )
    )
  }
}

struct WorkspaceDeduplicate: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "deduplicate")

  @Flag(name: .long, help: "Apply the previously previewed plan.")
  var apply = false

  @Option(
    name: .long,
    help: "Plan digest printed by preview; required with --apply to prevent races."
  )
  var expectedPlanDigest: String?

  @Flag(
    name: .long,
    help: "Keep the oldest registration metadata after explicitly reviewing conflicts."
  )
  var allowMetadataConflicts = false

  func run() async throws {
    if apply && expectedPlanDigest == nil {
      throw ValidationError("--apply requires --expected-plan-digest from a prior preview.")
    }
    var arguments: [String: JSONValue] = ["apply": .bool(apply)]
    if let expectedPlanDigest {
      arguments["expected_plan_digest"] = .string(expectedPlanDigest)
    }
    if allowMetadataConflicts {
      arguments["allow_metadata_conflicts"] = .bool(true)
    }
    printJSON(
      try await AppControlPlaneServiceClient.live().call(
        "workspace.deduplicate",
        arguments: .object(arguments)
      )
    )
  }
}

struct Profile: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "profile",
    subcommands: [
      ProfileList.self, ProfileShow.self, ProfileActivate.self, ProfileGrant.self,
      ProfileShell.self,
    ]
  )
}

struct ProfileActivate: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "activate")
  @Argument var id: String

  func run() async throws {
    printJSON(
      try await AppControlPlaneServiceClient.live().call(
        "profile.activate",
        arguments: .object(["profile": .string(id)])
      )
    )
  }
}

struct ProfileList: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "list")
  func run() async throws {
    printJSON(try await AppControlPlaneServiceClient.live().call("profile.list"))
  }
}

struct ProfileShow: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "show")
  @Argument var id: String
  func run() async throws {
    printJSON(
      try await AppControlPlaneServiceClient.live().call(
        "profile.show", arguments: .object(["profile": .string(id)])
      )
    )
  }
}

struct ProfileGrant: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "grant")
  @Argument var id: String
  @Option(name: .long) var workspace: String
  @Flag(name: .long, inversion: .prefixedNo) var enabled = true
  func run() async throws {
    printJSON(
      try await AppControlPlaneServiceClient.live().call(
        "profile.grant",
        arguments: .object([
          "profile": .string(id), "workspace_id": .string(workspace),
          "enabled": .bool(enabled),
        ])
      )
    )
  }
}

struct ProfileShell: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "shell",
    abstract: "Enable or disable Full Shell for an eligible profile."
  )

  @Argument var id: String
  @Flag(name: .long, inversion: .prefixedNo) var enabled = true

  func run() async throws {
    printJSON(
      try await AppControlPlaneServiceClient.live().call(
        "profile.shell",
        arguments: .object([
          "profile": .string(id), "enabled": .bool(enabled),
        ])
      )
    )
  }
}

struct Tunnel: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "tunnel",
    subcommands: [OpenAITunnel.self, CloudflareTunnel.self]
  )
}

struct OpenAITunnel: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "openai",
    subcommands: [
      OpenAITunnelList.self, OpenAITunnelDoctor.self, OpenAITunnelStart.self,
      OpenAITunnelReconnect.self, OpenAITunnelStop.self, OpenAITunnelProvision.self,
      OpenAITunnelLogs.self, OpenAITunnelSave.self, OpenAITunnelRemove.self,
    ]
  )
}

struct CloudflareTunnel: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "cloudflare",
    subcommands: [
      CloudflareTunnelList.self, CloudflareTunnelDoctor.self, CloudflareTunnelStart.self,
      CloudflareTunnelStop.self, CloudflareTunnelLogs.self, CloudflareTunnelSave.self,
      CloudflareTunnelRemove.self,
    ]
  )
}

struct OpenAITunnelList: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "list")
  func run() async throws {
    printJSON(try await controlTunnelCall(transport: "openai", action: "list"))
  }
}

struct OpenAITunnelDoctor: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "doctor")
  @Argument var id: String
  func run() async throws {
    printJSON(try await controlTunnelCall(transport: "openai", action: "doctor", id: id))
  }
}

struct OpenAITunnelStart: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "start")
  @Argument var id: String
  func run() async throws {
    printJSON(try await controlTunnelCall(transport: "openai", action: "start", id: id))
  }
}

struct OpenAITunnelStop: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "stop")
  @Argument var id: String
  func run() async throws {
    printJSON(try await controlTunnelCall(transport: "openai", action: "stop", id: id))
  }
}

struct OpenAITunnelReconnect: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "reconnect")
  @Argument var id: String
  func run() async throws {
    printJSON(try await controlTunnelCall(transport: "openai", action: "reconnect", id: id))
  }
}

struct OpenAITunnelProvision: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "provision")
  @Argument var id: String
  @Flag(name: .long, help: "Replace an existing Tunnel client profile.") var force = false

  func run() async throws {
    printJSON(
      try await AppControlPlaneServiceClient.live().call(
        "tunnel.openai.provision",
        arguments: .object(["id": .string(id), "force": .bool(force)])
      )
    )
  }
}

struct OpenAITunnelSave: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "save",
    abstract: "Create or update an OpenAI Tunnel configuration."
  )

  @Argument var id: String
  @Option(name: .long) var tunnelClientProfile: String
  @Option(name: .long) var tunnelID: String
  @Option(name: .long) var gatewayProfile: String
  @Option(name: .long) var tunnelClientPath: String?
  @Option(name: .long) var httpProxy: String?
  @Flag(name: .long, help: "Read a new OpenAI API key from standard input.")
  var apiKeyStdin = false

  func run() async throws {
    var arguments: [String: JSONValue] = [
      "id": .string(id),
      "tunnel_client_profile": .string(tunnelClientProfile),
      "tunnel_id": .string(tunnelID),
      "gateway_profile": .string(gatewayProfile),
    ]
    if let tunnelClientPath { arguments["tunnel_client_path"] = .string(tunnelClientPath) }
    if let httpProxy { arguments["http_proxy"] = .string(httpProxy) }
    if let apiKey = try readSecretFromStandardInput(
      when: apiKeyStdin,
      label: "OpenAI API key"
    ) {
      arguments["api_key"] = .string(apiKey)
    }
    printJSON(
      try await AppControlPlaneServiceClient.live().call(
        "tunnel.openai.save",
        arguments: .object(arguments)
      )
    )
  }
}

struct OpenAITunnelRemove: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "remove")
  @Argument var id: String

  func run() async throws {
    printJSON(try await controlTunnelCall(transport: "openai", action: "remove", id: id))
  }
}

struct CloudflareTunnelSave: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "save",
    abstract: "Create or update a named Cloudflare Tunnel configuration."
  )

  @Argument var id: String
  @Option(name: .long) var tunnelName: String
  @Option(name: .long) var publicHostname: String
  @Option(name: .long) var gatewayProfile: String
  @Option(name: .long) var localPort = 8_765
  @Option(name: .long) var metricsPort = 20_241
  @Option(name: .long) var cloudflaredPath: String?
  @Flag(name: .long, help: "Read a new named-tunnel token from standard input.")
  var tunnelTokenStdin = false
  @Flag(name: .long, help: "Generate and return a replacement Computer MCP access token.")
  var regenerateAccessToken = false

  func run() async throws {
    var arguments: [String: JSONValue] = [
      "id": .string(id),
      "tunnel_name": .string(tunnelName),
      "public_hostname": .string(publicHostname),
      "gateway_profile": .string(gatewayProfile),
      "local_port": .number(Double(localPort)),
      "metrics_port": .number(Double(metricsPort)),
      "regenerate_access_token": .bool(regenerateAccessToken),
    ]
    if let cloudflaredPath { arguments["cloudflared_path"] = .string(cloudflaredPath) }
    if let token = try readSecretFromStandardInput(
      when: tunnelTokenStdin,
      label: "Named-tunnel token"
    ) {
      arguments["tunnel_token"] = .string(token)
    }
    printJSON(
      try await AppControlPlaneServiceClient.live().call(
        "tunnel.cloudflare.save",
        arguments: .object(arguments)
      )
    )
  }
}

struct CloudflareTunnelRemove: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "remove")
  @Argument var id: String

  func run() async throws {
    printJSON(try await controlTunnelCall(transport: "cloudflare", action: "remove", id: id))
  }
}

struct Permissions: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "permissions",
    abstract: "Inspect macOS permissions without prompting.",
    subcommands: [PermissionsStatus.self]
  )
}

struct PermissionsStatus: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "status")

  func run() async throws {
    printJSON(try await AppControlPlaneServiceClient.live().call("permissions.status"))
  }
}

struct OpenAITunnelLogs: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "logs")
  @Argument var id: String
  func run() async throws {
    printJSON(try await controlTunnelCall(transport: "openai", action: "logs", id: id))
  }
}

struct CloudflareTunnelList: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "list")
  func run() async throws {
    printJSON(try await controlTunnelCall(transport: "cloudflare", action: "list"))
  }
}

struct CloudflareTunnelDoctor: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "doctor")
  @Argument var id: String
  func run() async throws {
    printJSON(try await controlTunnelCall(transport: "cloudflare", action: "doctor", id: id))
  }
}

struct CloudflareTunnelStart: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "start")
  @Argument var id: String
  func run() async throws {
    printJSON(try await controlTunnelCall(transport: "cloudflare", action: "start", id: id))
  }
}

struct CloudflareTunnelStop: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "stop")
  @Argument var id: String
  func run() async throws {
    printJSON(try await controlTunnelCall(transport: "cloudflare", action: "stop", id: id))
  }
}

struct CloudflareTunnelLogs: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "logs")
  @Argument var id: String
  func run() async throws {
    printJSON(try await controlTunnelCall(transport: "cloudflare", action: "logs", id: id))
  }
}

struct CLIInstall: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "cli")
  @Flag(name: .long) var status = false
  @Flag(name: .long) var replaceInvalidLink = false
  func run() throws {
    let installer = EmbeddedCLIInstaller()
    if status {
      printJSON(try JSONValue.encoded(installer.status()))
      return
    }
    let source = try currentExecutableURL()
    printJSON(
      try JSONValue.encoded(
        installer.install(source: source, replaceInvalidLink: replaceInvalidLink)
      )
    )
  }
}

struct CLIUninstall: ParsableCommand {
  static let configuration = CommandConfiguration(commandName: "cli")
  func run() throws {
    try EmbeddedCLIInstaller().uninstall()
  }
}

private func controlTunnelCall(
  transport: String,
  action: String,
  id: String? = nil
) async throws -> JSONValue {
  var arguments: [String: JSONValue] = [:]
  if let id { arguments["id"] = .string(id) }
  return try await AppControlPlaneServiceClient.live().call(
    "tunnel.\(transport).\(action)",
    arguments: .object(arguments)
  )
}

func currentExecutableURL() throws -> URL {
  var capacity: UInt32 = 0
  _ = _NSGetExecutablePath(nil, &capacity)
  var buffer = [CChar](repeating: 0, count: Int(capacity))
  guard _NSGetExecutablePath(&buffer, &capacity) == 0 else {
    throw ValidationError("Could not resolve the running CLI executable.")
  }
  let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
  return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
    .standardizedFileURL
    .resolvingSymlinksInPath()
}

private func writeOrPrint(_ content: String, output: String?) throws {
  guard let output else {
    print(content, terminator: "")
    return
  }
  let url = URL(fileURLWithPath: output).standardizedFileURL
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try Data(content.utf8).write(to: url, options: .atomic)
  print(url.path)
}

private func readSecretFromStandardInput(
  when enabled: Bool,
  label: String
) throws -> String? {
  guard enabled else { return nil }
  let maximumBytes = 65_536
  let data = try FileHandle.standardInput.read(upToCount: maximumBytes + 1) ?? Data()
  guard data.count <= maximumBytes else {
    throw ValidationError("\(label) must not exceed \(maximumBytes) bytes.")
  }
  guard let value = String(data: data, encoding: .utf8) else {
    throw ValidationError("\(label) must be valid UTF-8.")
  }
  let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !normalized.isEmpty, !normalized.contains("\0") else {
    throw ValidationError("\(label) must not be empty.")
  }
  return normalized
}
