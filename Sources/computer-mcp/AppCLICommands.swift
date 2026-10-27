import ArgumentParser
import ComputerMCPControlPlane
import ComputerMCPCore
import ComputerMCPTunnels
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
    @OptionGroup var connection: AppControlConnectionOptions

    static let configuration = CommandConfiguration(commandName: "status")
    func run() async throws {
      printJSON(
        try await connection.client().call(
          "app.status",
          timeout: .seconds(5)
        )
      )
    }
  }

  struct Start: AsyncParsableCommand {
    @OptionGroup var connection: AppControlConnectionOptions

    static let configuration = CommandConfiguration(commandName: "start")
    func run() async throws {
      printJSON(try await connection.client().call("app.start"))
    }
  }

  struct Stop: AsyncParsableCommand {
    @OptionGroup var connection: AppControlConnectionOptions

    static let configuration = CommandConfiguration(commandName: "stop")
    func run() async throws {
      printJSON(try await connection.client().call("app.stop"))
    }
  }

  struct Restart: AsyncParsableCommand {
    @OptionGroup var connection: AppControlConnectionOptions

    static let configuration = CommandConfiguration(commandName: "restart")
    func run() async throws {
      printJSON(try await connection.client().call("app.restart"))
    }
  }

  struct LaunchAtLogin: AsyncParsableCommand {
    @OptionGroup var connection: AppControlConnectionOptions

    static let configuration = CommandConfiguration(commandName: "launch-at-login")
    @Flag(name: .long, inversion: .prefixedNo) var enabled = true
    func run() async throws {
      printJSON(
        try await connection.client().call(
          "app.launch_at_login",
          arguments: .object(["enabled": .bool(enabled)])
        )
      )
    }
  }
}

struct ConfigPath: AsyncParsableCommand {
  @OptionGroup var connection: AppControlConnectionOptions

  static let configuration = CommandConfiguration(commandName: "path")
  func run() async throws {
    let result = try await connection.client().call("config.path")
    print(result.objectValue?["path"]?.stringValue ?? "")
  }
}

struct ConfigShow: AsyncParsableCommand {
  @OptionGroup var connection: AppControlConnectionOptions

  static let configuration = CommandConfiguration(commandName: "show")
  func run() async throws {
    let result = try await connection.client().call("config.show")
    print(result.objectValue?["toml"]?.stringValue ?? "", terminator: "")
  }
}

struct ConfigExport: AsyncParsableCommand {
  @OptionGroup var connection: AppControlConnectionOptions

  static let configuration = CommandConfiguration(commandName: "export")

  @Option(name: .long, help: "Destination for the secret-free schema-1 TOML manifest.")
  var output: String?

  func run() async throws {
    let result = try await connection.client().call("config.export")
    try writeOrPrint(result.objectValue?["toml"]?.stringValue ?? "", output: output)
  }
}

struct ConfigImport: AsyncParsableCommand {
  @OptionGroup var connection: AppControlConnectionOptions

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
      try await connection.client().call(
        "config.import",
        arguments: .object(arguments)
      )
    )
  }
}

struct ConfigHistory: AsyncParsableCommand {
  @OptionGroup var connection: AppControlConnectionOptions

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
      try await connection.client().call(
        "config.history",
        arguments: .object(["limit": .number(Double(limit))])
      )
    )
  }
}

struct ConfigRollback: AsyncParsableCommand {
  @OptionGroup var connection: AppControlConnectionOptions

  static let configuration = CommandConfiguration(commandName: "rollback")
  @Argument(help: "Stable revision id returned by config history.") var revisionID: String

  func run() async throws {
    printJSON(
      try await connection.client().call(
        "config.rollback",
        arguments: .object(["revision_id": .string(revisionID)])
      )
    )
  }
}

struct Project: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "project",
    subcommands: [
      ProjectList.self, ProjectAdd.self, ProjectRepair.self, ProjectRemove.self,
      ProjectAccessCommand.self,
      ProjectDeduplicate.self,
    ]
  )
}

struct ProjectList: AsyncParsableCommand {
  @OptionGroup var connection: AppControlConnectionOptions

  static let configuration = CommandConfiguration(commandName: "list")
  func run() async throws {
    printJSON(try await connection.client().call("project.list"))
  }
}

struct ProjectAdd: AsyncParsableCommand {
  @OptionGroup var connection: AppControlConnectionOptions

  static let configuration = CommandConfiguration(commandName: "add")
  @Argument var path: String
  @Option(name: .long) var displayName: String?
  func run() async throws {
    var arguments: [String: JSONValue] = ["path": .string(path)]
    if let displayName { arguments["display_name"] = .string(displayName) }
    printJSON(
      try await connection.client().call(
        "project.add", arguments: .object(arguments))
    )
  }
}

struct ProjectRepair: AsyncParsableCommand {
  @OptionGroup var connection: AppControlConnectionOptions

  static let configuration = CommandConfiguration(
    commandName: "repair",
    abstract: "Renew folder access or rebind a project while keeping its ID and grants.")
  @Argument var id: String
  @Argument var path: String
  @Option(name: .long) var displayName: String?

  func run() async throws {
    var arguments: [String: JSONValue] = ["id": .string(id), "path": .string(path)]
    if let displayName { arguments["display_name"] = .string(displayName) }
    printJSON(try await connection.client().call("project.repair", arguments: .object(arguments)))
  }
}

struct ProjectRemove: AsyncParsableCommand {
  @OptionGroup var connection: AppControlConnectionOptions

  static let configuration = CommandConfiguration(commandName: "remove")
  @Argument var id: String
  func run() async throws {
    printJSON(
      try await connection.client().call(
        "project.remove", arguments: .object(["id": .string(id)])
      )
    )
  }
}

struct ProjectAccessCommand: AsyncParsableCommand {
  @OptionGroup var connection: AppControlConnectionOptions

  static let configuration = CommandConfiguration(
    commandName: "access", abstract: "Set one project's access at reviewed revisions.",
    discussion: "Ask clears the explicit rule. A wildcard project rule still applies.")
  @Argument var id: String
  @Option(name: .long) var profile: String
  @Option(name: .long, help: "ask, deny, read or write.") var access: String
  @Option(name: .long) var expectedProfileRevision: Int64
  @Option(name: .long) var expectedPermissionRevision: Int64

  func validate() throws {
    guard ProjectAccess(rawValue: access) != nil else {
      throw ValidationError("access must be ask, deny, read or write.")
    }
    guard expectedProfileRevision > 0, expectedPermissionRevision >= 0 else {
      throw ValidationError(
        "Supply the positive profile revision and nonnegative permission revision from profile show."
      )
    }
  }

  func run() async throws {
    printJSON(
      try await connection.client().call(
        "project.access",
        arguments: .object([
          "project_id": .string(id), "profile": .string(profile),
          "access": .string(access),
          "expected_profile_revision": .integer(expectedProfileRevision),
          "expected_permission_revision": .integer(expectedPermissionRevision),
        ])))
  }
}

struct ProjectDeduplicate: AsyncParsableCommand {
  @OptionGroup var connection: AppControlConnectionOptions

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
      try await connection.client().call(
        "project.deduplicate",
        arguments: .object(arguments)
      )
    )
  }
}

struct Profile: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "profile",
    subcommands: [
      ProfileList.self, ProfileShow.self, ProfileActivate.self,
      ProfilePermissions.self,
    ]
  )
}

struct ProfileActivate: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "activate")
  @Argument var id: String
  @OptionGroup var connection: AppControlConnectionOptions

  func run() async throws {
    printJSON(
      try await connection.client().call(
        "profile.activate",
        arguments: .object(["profile": .string(id)])
      )
    )
  }
}

struct ProfileList: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "list")
  @OptionGroup var connection: AppControlConnectionOptions
  func run() async throws {
    printJSON(try await connection.client().call("profile.list"))
  }
}

struct ProfileShow: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "show")
  @Argument var id: String
  @OptionGroup var connection: AppControlConnectionOptions
  func run() async throws {
    printJSON(
      try await connection.client().call(
        "profile.show", arguments: .object(["profile": .string(id)])
      )
    )
  }
}

struct ProfilePermissions: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "permissions",
    abstract: "Replace a profile's permissions with a reviewed JSON grant.",
    discussion:
      "Run profile show, edit the returned grant, and supply its permission_revision. Revoking a permission ends work that uses it."
  )
  @Option(name: .long, help: "JSON profile grant file, based on profile show.") var file: String
  @Option(name: .long, help: "Permission revision returned by profile show.")
  var expectedPermissionRevision: Int64
  @OptionGroup var connection: AppControlConnectionOptions

  func run() async throws {
    guard expectedPermissionRevision >= 0 else {
      throw ValidationError("--expected-permission-revision must not be negative.")
    }
    let grant = try JSONDecoder().decode(
      JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
    guard grant.objectValue != nil else {
      throw ValidationError("The grant must be a JSON object.")
    }
    printJSON(
      try await connection.client().call(
        "profile.permissions",
        arguments: .object([
          "grant": grant, "expected_permission_revision": .integer(expectedPermissionRevision),
        ])))
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
  @OptionGroup var connection: AppControlConnectionOptions

  static let configuration = CommandConfiguration(commandName: "list")
  func run() async throws {
    printJSON(
      try await controlTunnelCall(connection: connection, transport: "openai", action: "list"))
  }
}

struct OpenAITunnelDoctor: AsyncParsableCommand {
  @OptionGroup var connection: AppControlConnectionOptions

  static let configuration = CommandConfiguration(commandName: "doctor")
  @Argument var id: String
  func run() async throws {
    printJSON(
      try await controlTunnelCall(
        connection: connection, transport: "openai", action: "doctor", id: id))
  }
}

struct OpenAITunnelStart: AsyncParsableCommand {
  @OptionGroup var connection: AppControlConnectionOptions

  static let configuration = CommandConfiguration(commandName: "start")
  @Argument var id: String
  func run() async throws {
    printJSON(
      try await controlTunnelCall(
        connection: connection, transport: "openai", action: "start", id: id))
  }
}

struct OpenAITunnelStop: AsyncParsableCommand {
  @OptionGroup var connection: AppControlConnectionOptions

  static let configuration = CommandConfiguration(commandName: "stop")
  @Argument var id: String
  func run() async throws {
    printJSON(
      try await controlTunnelCall(
        connection: connection, transport: "openai", action: "stop", id: id))
  }
}

struct OpenAITunnelReconnect: AsyncParsableCommand {
  @OptionGroup var connection: AppControlConnectionOptions

  static let configuration = CommandConfiguration(commandName: "reconnect")
  @Argument var id: String
  func run() async throws {
    printJSON(
      try await controlTunnelCall(
        connection: connection, transport: "openai", action: "reconnect", id: id))
  }
}

struct OpenAITunnelProvision: AsyncParsableCommand {
  @OptionGroup var connection: AppControlConnectionOptions

  static let configuration = CommandConfiguration(commandName: "provision")
  @Argument var id: String
  @Flag(name: .long, help: "Replace an existing Tunnel client profile.") var force = false

  func run() async throws {
    printJSON(
      try await connection.client().call(
        "tunnel.openai.provision",
        arguments: .object(["id": .string(id), "force": .bool(force)])
      )
    )
  }
}

struct OpenAITunnelSave: AsyncParsableCommand {
  @OptionGroup var connection: AppControlConnectionOptions

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
      try await connection.client().call(
        "tunnel.openai.save",
        arguments: .object(arguments)
      )
    )
  }
}

struct OpenAITunnelRemove: AsyncParsableCommand {
  @OptionGroup var connection: AppControlConnectionOptions

  static let configuration = CommandConfiguration(commandName: "remove")
  @Argument var id: String

  func run() async throws {
    printJSON(
      try await controlTunnelCall(
        connection: connection, transport: "openai", action: "remove", id: id))
  }
}

struct CloudflareTunnelSave: AsyncParsableCommand {
  @OptionGroup var connection: AppControlConnectionOptions

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
  @Flag(
    name: .long, inversion: .prefixedNo,
    help: "Enable OAuth pairing, or disable it with --no-oauth-enabled.")
  var oauthEnabled: Bool?
  @Option(name: .long, help: "Replace the exact CIMD host allowlist; repeat for each host.")
  var oauthClientHost: [String] = []
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
    if let oauthEnabled { arguments["oauth_enabled"] = .bool(oauthEnabled) }
    if !oauthClientHost.isEmpty {
      arguments["oauth_client_allowlist"] = .array(oauthClientHost.map(JSONValue.string))
    }
    if let token = try readSecretFromStandardInput(
      when: tunnelTokenStdin,
      label: "Named-tunnel token"
    ) {
      arguments["tunnel_token"] = .string(token)
    }
    printJSON(
      try await connection.client().call(
        "tunnel.cloudflare.save",
        arguments: .object(arguments)
      )
    )
  }
}

struct CloudflareTunnelRemove: AsyncParsableCommand {
  @OptionGroup var connection: AppControlConnectionOptions

  static let configuration = CommandConfiguration(commandName: "remove")
  @Argument var id: String

  func run() async throws {
    printJSON(
      try await controlTunnelCall(
        connection: connection, transport: "cloudflare", action: "remove", id: id))
  }
}

struct Permissions: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "permissions",
    abstract: "Inspect macOS access and answer durable client permission requests locally.",
    subcommands: [
      PermissionsStatus.self, PermissionRequests.self, PermissionRequestAnswer.self,
      PermissionConfirmAuthority.self,
    ])
}

struct PermissionsStatus: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "status")
  @OptionGroup var connection: AppControlConnectionOptions
  func run() async throws { printJSON(try await connection.client().call("permissions.status")) }
}

struct PermissionRequests: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "requests",
    abstract: "List durable permission requests and their current revision.")
  @OptionGroup var connection: AppControlConnectionOptions
  func run() async throws { printJSON(try await connection.client().call("permissions.requests")) }
}

struct PermissionConfirmAuthority: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "confirm-authority",
    abstract: "Confirm a complete saved profile snapshot after reviewing restored authority.",
    discussion:
      "Read permissions requests, review every returned profile, then pass its complete profiles array with the captured epoch and revision. The command never refreshes or retries a stale review."
  )
  @OptionGroup var connection: AppControlConnectionOptions
  @Option(name: .long, help: "Epoch UUID from the reviewed permissions requests snapshot.")
  var epoch: String
  @Option(name: .long, help: "Permission revision from the same reviewed snapshot.")
  var expectedPermissionRevision: Int64
  @Option(name: .long, help: "JSON file containing the complete reviewed ProfileGrant array.")
  var profilesFile: String

  func validate() throws {
    guard UUID(uuidString: epoch) != nil, expectedPermissionRevision >= 0 else {
      throw ValidationError(
        "--epoch must be a UUID and --expected-permission-revision must not be negative.")
    }
  }

  func run() async throws {
    let profiles = try JSONDecoder().decode(
      JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: profilesFile)))
    guard let rows = profiles.arrayValue, rows.allSatisfy({ $0.objectValue != nil }) else {
      throw ValidationError("--profiles-file must contain the complete reviewed profiles array.")
    }
    printJSON(
      try await connection.client().call(
        "permissions.confirm_authority",
        arguments: .object([
          "epoch": .string(epoch),
          "expected_permission_revision": .integer(expectedPermissionRevision),
          "profiles": profiles,
        ])))
  }
}

struct PermissionRequestAnswer: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "answer",
    abstract: "Answer one reviewed permission request. The original client retries the call.")
  @Argument(help: "Request UUID from permissions requests.") var id: String
  @Option(name: .long) var answer: PermissionRequestAnswerChoice
  @Option(name: .long, help: "Revision returned by permissions requests.") var expectedRevision:
    Int64
  @OptionGroup var connection: AppControlConnectionOptions
  func run() async throws {
    guard UUID(uuidString: id) != nil, expectedRevision >= 0 else {
      throw ValidationError("A request UUID and non-negative --expected-revision are required.")
    }
    printJSON(
      try await connection.client().call(
        "permissions.answer",
        arguments: .object([
          "id": .string(id), "answer": .string(answer.rawValue),
          "expected_revision": .integer(expectedRevision),
        ])))
  }
}

enum PermissionRequestAnswerChoice: String, ExpressibleByArgument {
  case onlyThisTime = "only_this_time"
  case always, deny
}

struct OpenAITunnelLogs: AsyncParsableCommand {
  @OptionGroup var connection: AppControlConnectionOptions

  static let configuration = CommandConfiguration(commandName: "logs")
  @Argument var id: String
  func run() async throws {
    printJSON(
      try await controlTunnelCall(
        connection: connection, transport: "openai", action: "logs", id: id))
  }
}

struct CloudflareTunnelList: AsyncParsableCommand {
  @OptionGroup var connection: AppControlConnectionOptions

  static let configuration = CommandConfiguration(commandName: "list")
  func run() async throws {
    printJSON(
      try await controlTunnelCall(connection: connection, transport: "cloudflare", action: "list"))
  }
}

struct CloudflareTunnelDoctor: AsyncParsableCommand {
  @OptionGroup var connection: AppControlConnectionOptions

  static let configuration = CommandConfiguration(commandName: "doctor")
  @Argument var id: String
  func run() async throws {
    printJSON(
      try await controlTunnelCall(
        connection: connection, transport: "cloudflare", action: "doctor", id: id))
  }
}

struct CloudflareTunnelStart: AsyncParsableCommand {
  @OptionGroup var connection: AppControlConnectionOptions

  static let configuration = CommandConfiguration(commandName: "start")
  @Argument var id: String
  func run() async throws {
    printJSON(
      try await controlTunnelCall(
        connection: connection, transport: "cloudflare", action: "start", id: id))
  }
}

struct CloudflareTunnelStop: AsyncParsableCommand {
  @OptionGroup var connection: AppControlConnectionOptions

  static let configuration = CommandConfiguration(commandName: "stop")
  @Argument var id: String
  func run() async throws {
    printJSON(
      try await controlTunnelCall(
        connection: connection, transport: "cloudflare", action: "stop", id: id))
  }
}

struct CloudflareTunnelLogs: AsyncParsableCommand {
  @OptionGroup var connection: AppControlConnectionOptions

  static let configuration = CommandConfiguration(commandName: "logs")
  @Argument var id: String
  func run() async throws {
    printJSON(
      try await controlTunnelCall(
        connection: connection, transport: "cloudflare", action: "logs", id: id))
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
  connection: AppControlConnectionOptions,
  transport: String,
  action: String,
  id: String? = nil
) async throws -> JSONValue {
  var arguments: [String: JSONValue] = [:]
  if let id { arguments["id"] = .string(id) }
  return try await connection.client().call(
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
