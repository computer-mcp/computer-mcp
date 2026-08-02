import ArgumentParser
import ComputerMCP
import Darwin
import Foundation

struct App: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "app",
    subcommands: [Status.self]
  )

  struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status")
    func run() async throws {
      printJSON(try await AppControlPlaneServiceClient.live().call("app.status"))
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

  @Flag(name: .long, help: "Apply a previously previewed import without starting transports.")
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

struct Workspace: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "workspace",
    subcommands: [
      WorkspaceList.self, WorkspaceAdd.self, WorkspaceRemove.self, WorkspaceEnable.self,
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

struct Profile: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "profile",
    subcommands: [ProfileList.self, ProfileShow.self, ProfileGrant.self]
  )
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
      OpenAITunnelStop.self, OpenAITunnelLogs.self,
    ]
  )
}

struct CloudflareTunnel: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "cloudflare",
    subcommands: [
      CloudflareTunnelList.self, CloudflareTunnelDoctor.self, CloudflareTunnelStart.self,
      CloudflareTunnelStop.self, CloudflareTunnelLogs.self,
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
