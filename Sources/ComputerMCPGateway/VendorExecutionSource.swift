import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPDownstream
import ComputerMCPPermissions
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPPlugins
import ComputerMCPSandbox
import Crypto
import Foundation

/// Launch and effect data belong to the reviewed manifest and its file inventory.
struct VendorExecutionSource: Sendable {
  enum ProtocolKind: Sendable {
    case cursor, trae, claudePrint

    var handleArgument: String {
      switch self {
      case .cursor: "session"
      case .trae: "session_handle"
      case .claudePrint: "run_id"
      }
    }

    var permissionArgument: String { self == .trae ? "permission_id" : "request_id" }
  }

  enum Effect: String, Decodable, Sendable {
    case acquire
    case detachedAcquire = "detached_acquire"
    case prompt
    case detachedPrompt = "detached_prompt"
    case mode, stop, answer, close, observe

    var acquires: Bool { self == .acquire || self == .detachedAcquire }
  }

  struct Signature: Decodable, Sendable {
    let capability: String
    let dependency: String
    let tools: [String: Effect]
    let probe: [String]
    let workload: Workload
    let versionStdout: String

    enum CodingKeys: String, CodingKey {
      case capability, dependency, tools, probe, workload
      case versionStdout = "version_stdout"
    }
  }

  enum Workload: Decodable, Sendable {
    case fixed([String])
    case print(ClaudePrintRecipe)

    init(from decoder: any Decoder) throws {
      let container = try decoder.singleValueContainer()
      if let fixed = try? container.decode([String].self) {
        self = .fixed(fixed)
      } else {
        self = .print(try container.decode(ClaudePrintRecipe.self))
      }
    }

    func arguments(_ admitted: [String: JSONValue]) throws -> [String] {
      switch self {
      case .fixed(let argv): argv
      case .print(let recipe): try recipe.arguments(admitted)
      }
    }
  }

  static let capability = MCPChildProcessTransport.vendorExecutionCapability

  let pluginID: String
  let manifestDigest: String
  let registrationID: String
  let protocolKind: ProtocolKind
  let signature: Signature
  let executable: SandboxPath
  let dependencyFiles: [VerifiedFileIdentity]
  private let root: URL
  private let files: [String: String]

  static func resolve(
    server: MCPServerConfig, origin: PluginContributionOrigin, package: PluginPackage,
    state: PluginStoreSnapshot
  ) throws -> Self? {
    guard let contribution = package.manifest.mcp.first(where: { $0.id == origin.componentID })
    else { throw PermissionModelError.invalidAuthorization }
    let managedKind: ProtocolKind?
    switch (origin.pluginID, origin.componentID) {
    case ("cursor", "acp"): managedKind = .cursor
    case ("trae", "acp"): managedKind = .trae
    case ("claude", "stream"): managedKind = .claudePrint
    default: managedKind = nil
    }
    guard let declaration = contribution.vendorExecution else {
      // This installed entry point is managed. Standalone adapters are direct MCP registrations.
      if origin.source.kind == .artifact, managedKind == .cursor {
        throw PermissionModelError.invalidAuthorization
      }
      // Older TRAE and Claude contributions use the standalone entry point.
      if managedKind == .claudePrint, contribution.executable?.path == "bin/claude-mcp-managed" {
        throw PermissionModelError.invalidAuthorization
      }
      return nil
    }

    let digest = try PluginStore.manifestDigest(package.manifest)
    guard package.manifest.id == origin.pluginID, package.manifest.version == origin.version,
      package.root == origin.source.root, origin.reviewedRequirements?.sourceDigest == digest,
      let settings = state.settings[origin.pluginID], settings.enabled,
      let choice = settings.mcp[origin.componentID], choice.enabled, !choice.hostServices,
      choice.args == nil, server.enabled, !server.hostServices, server.transport == .stdio,
      server.id
        == PluginResolver.registrationID(
          pluginID: origin.pluginID, componentID: origin.componentID,
          override: choice.registrationID),
      let dependency = origin.vendorExecutable,
      dependency.isFileURL, dependency.path.hasPrefix("/")
    else { throw PermissionModelError.invalidAuthorization }

    if let selected = state.selectedInstallations[origin.pluginID] {
      guard
        state.installations.contains(where: {
          $0.id == selected && $0.pluginID == origin.pluginID && $0.source == origin.source
            && $0.version == origin.version && $0.manifestDigest == digest
        })
      else { throw PermissionModelError.invalidAuthorization }
    } else if origin.source.kind != .bundled {
      throw PermissionModelError.invalidAuthorization
    }

    guard
      let bytes = try verifyFiles(
        root: package.root, inventory: declaration.files, retaining: declaration.signature)
    else {
      throw PermissionModelError.invalidAuthorization
    }
    let signature = try JSONDecoder().decode(Signature.self, from: bytes)
    let protocolKind = managedKind ?? .cursor
    guard signature.capability == capability, signature.dependency == declaration.dependency,
      signature.probe == ["--version"],
      signature.tools.values.contains(where: \.acquires),
      signature.tools.keys.allSatisfy({
        !$0.isEmpty && !$0.contains("\0")
      }),
      (1...65_536).contains(signature.versionStdout.utf8.count)
    else { throw PermissionModelError.invalidAuthorization }
    switch (protocolKind, signature.workload) {
    case (.claudePrint, .print(let recipe)):
      guard signature.dependency == "claude-code", recipe.isSupported,
        signature.tools.filter({ $0.value != .observe }) == [
          "claude.run": .acquire, "claude.run.start": .detachedAcquire, "claude.run.cancel": .close,
        ]
      else { throw PermissionModelError.invalidAuthorization }
    case (.trae, .fixed(let argv)):
      guard signature.dependency == "trae-cli",
        argv == [
          "--sandbox", "read-only", "--ask-for-approval", "on-request", "-c",
          "analytics.enabled=false", "acp", "serve",
        ],
        signature.tools.filter({ $0.value != .observe }) == [
          "trae.session.open": .detachedAcquire, "trae.session.prompt": .detachedPrompt,
          "trae.session.close": .close, "trae.permissions.respond": .answer,
          "trae.turn.cancel": .stop,
        ]
      else { throw PermissionModelError.invalidAuthorization }
    case (.cursor, .fixed(let argv)):
      guard !argv.isEmpty, argv.allSatisfy({ !$0.contains("\0") })
      else { throw PermissionModelError.invalidAuthorization }
    default: throw PermissionModelError.invalidAuthorization
    }

    let inspection = ExecutableInspection.inspect(
      dependency.path, workingDirectory: package.root, environment: ["PATH": "/usr/bin:/bin"])
    let dependencyFiles = try identities(inspection)
    guard let executable = dependencyFiles.first else {
      throw PermissionModelError.invalidAuthorization
    }
    return try Self(
      pluginID: origin.pluginID, manifestDigest: digest, registrationID: server.id,
      protocolKind: protocolKind, signature: signature, executable: SandboxPath(executable.path),
      dependencyFiles: dependencyFiles, root: package.root, files: declaration.files)
  }

  func verify() throws {
    _ = try Self.verifyFiles(root: root, inventory: files)
    for file in dependencyFiles { try file.verify(URL(fileURLWithPath: file.path)) }
  }

  func verifyInterpreter(searchPath: [SandboxPath]) throws {
    let inspection = ExecutableInspection.inspect(
      executable.value, workingDirectory: root,
      environment: ["PATH": searchPath.map(\.value).joined(separator: ":")])
    guard try Self.identities(inspection) == dependencyFiles else {
      throw PermissionModelError.invalidAuthorization
    }
  }

  private static func identities(_ file: ExecutableInspection) throws -> [VerifiedFileIdentity] {
    guard !file.hasKnownFailure, let path = file.path else {
      throw PermissionModelError.invalidAuthorization
    }
    return try [VerifiedFileIdentity.capture(URL(fileURLWithPath: path))]
      + file.interpreters.flatMap(identities)
  }

  private static func verifyFiles(
    root: URL, inventory: [String: String], retaining signature: String? = nil
  ) throws -> Data? {
    let files = try PackageFiles(root: root)
    var result: Data?
    for (path, digest) in inventory {
      let url = root.appendingPathComponent(path)
      let identity = try VerifiedFileIdentity.capture(url)
      guard identity.path == url.path else { throw PermissionModelError.invalidAuthorization }
      let data = try files.read(path, maximumBytes: 1_048_576)
      guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest
      else { throw PermissionModelError.invalidAuthorization }
      try identity.verify(url)
      if path == signature { result = data }
    }
    return result
  }
}

struct ClaudePrintRecipe: Decodable, Sendable {
  private let kind: String
  private let argv: [[String: String]]

  private static let literals = [
    "-p", "--output-format", "stream-json", "--verbose",
    "--include-partial-messages",
  ]
  private static let options = [
    ("model", "--model"), ("resume_session_id", "--resume"), ("session_id", "--session-id"),
    ("max_budget_usd", "--max-budget-usd"), ("effort", "--effort"),
    ("append_system_prompt", "--append-system-prompt"),
  ]
  private static let flags = [
    ("continue_previous", "--continue"), ("no_session_persistence", "--no-session-persistence"),
  ]

  var isSupported: Bool {
    let head =
      Self.literals.map { ["kind": "literal", "value": $0] } + [
        [
          "kind": "option", "parameter": "permission_mode", "flag": "--permission-mode",
          "style": "separate", "default": "dontAsk",
        ]
      ]
    let options = Self.options.map {
      ["kind": "option", "parameter": $0.0, "flag": $0.1, "style": "equals"]
    }
    let flags = Self.flags.map { ["kind": "flag", "parameter": $0.0, "flag": $0.1] }
    return kind == "print"
      && argv == head + options + flags + [
        ["kind": "literal", "value": "--"], ["kind": "positional", "parameter": "prompt"],
      ]
  }

  func arguments(_ input: [String: JSONValue]) throws -> [String] {
    let allowed = Set(
      Self.options.map(\.0) + Self.flags.map(\.0) + [
        "prompt", "permission_mode", "timeout_seconds", "max_events",
      ])
    guard Set(input.keys).isSubset(of: allowed) else { throw VendorExecutionFailure.denied }

    func string(_ field: String, _ length: ClosedRange<Int>) throws -> String? {
      guard let value = input[field] else { return nil }
      guard let text = value.stringValue, length.contains(text.unicodeScalars.count),
        !text.contains("\0")
      else { throw VendorExecutionFailure.denied }
      return text
    }

    func flag(_ field: String) throws -> Bool {
      guard let value = input[field] else { return false }
      guard let enabled = value.boolValue else { throw VendorExecutionFailure.denied }
      return enabled
    }

    func validateLimit(_ field: String, _ range: ClosedRange<Int>) throws {
      guard let value = input[field] else { return }
      guard case .integer(let integer) = value, let exact = Int(exactly: integer),
        range.contains(exact)
      else { throw VendorExecutionFailure.denied }
    }

    try validateLimit("timeout_seconds", 1...1800)
    try validateLimit("max_events", 1...256)
    guard let prompt = try string("prompt", 1...131_072) else {
      throw VendorExecutionFailure.denied
    }
    let permission = try string("permission_mode", 1...12) ?? "dontAsk"
    let effort = try string("effort", 1...6)
    let resume = try string("resume_session_id", 1...256)
    let session = try string("session_id", 36...36)
    let continues = try flag("continue_previous")
    let transient = try flag("no_session_persistence")
    guard ["dontAsk", "plan", "acceptEdits"].contains(permission),
      effort.map({ ["low", "medium", "high"].contains($0) }) ?? true,
      session.map({ UUID(uuidString: $0) != nil }) ?? true,
      [resume != nil, session != nil, continues].filter({ $0 }).count <= 1,
      !transient || (resume == nil && !continues)
    else { throw VendorExecutionFailure.denied }
    let budget: String?
    switch input["max_budget_usd"] {
    case nil: budget = nil
    case .integer(let value) where value >= 0: budget = String(value)
    case .number(let value) where value.isFinite && value >= 0: budget = String(value)
    default: throw VendorExecutionFailure.denied
    }
    let values = [
      try string("model", 1...256), resume, session, budget, effort,
      try string("append_system_prompt", 0...65_536),
    ]
    let options = zip(Self.options, values).compactMap { option, value in
      value.map { "\(option.1)=\($0)" }
    }
    let flags = zip(Self.flags, [continues, transient]).compactMap { $1 ? $0.1 : nil }
    return Self.literals + ["--permission-mode", permission] + options + flags + ["--", prompt]
  }
}
