import Foundation

/// App-owned management is injected into each admitted generation; the normal
/// gateway still owns tool admission, invocation leases, tickets and audit.
package struct GatewayRemoteManagement: Sendable {
  let call: @Sendable (String, [String: JSONValue], ExecutionContext) async throws -> JSONValue

  struct Contract: Sendable {
    let input: ControlToolContract
    let summary: String
    let risk: CapabilityRisk
    var network = false
    var destructive = false

    var tool: MCPTool {
      MCPTool(
        name: input.name, description: summary, inputSchema: input.inputSchema,
        annotations: .init(
          readOnlyHint: input.readOnly, destructiveHint: destructive,
          idempotentHint: input.readOnly, openWorldHint: network))
    }

    var descriptor: CapabilityDescriptor {
      CapabilityDescriptor(
        id: input.name, risk: risk, workspaceRequirement: .none,
        localOnly: false, usesNetwork: network)
    }
  }

  static let contracts: [Contract] = [
    .init(
      input: .init("profile.show", readOnly: true),
      summary: "Inspect this connection's current profile, session access and exact revisions.",
      risk: .readOnly),
    .init(
      input: .init(
        "profile.limit", arguments: ["mode": .string, "expected_revision": .integer],
        required: ["mode", "expected_revision"], readOnly: false),
      summary:
        "Reduce only this session to observe or restricted using its reviewed revision. Full Access and persistent trust require local consent.",
      risk: .workspaceWrite),
    .init(
      input: .init(
        "workspace.add", arguments: ["path": .string, "display_name": .string],
        required: ["path"], readOnly: false),
      summary:
        "Register an absolute local workspace path in an approved Full Access session. Connected clients see the new configuration; running work keeps its owner.",
      risk: .fullShell),
    .init(
      input: .init(
        "workspace.repair",
        arguments: [
          "id": .string, "path": .string, "expected_root_path": .string, "display_name": .string,
        ],
        required: ["id", "path", "expected_root_path"], readOnly: false),
      summary:
        "Repair a registered workspace after comparing its reviewed root path. Requires approved Full Access; the selected folder must remain valid through publication.",
      risk: .fullShell),
    .init(
      input: .init(
        "workspace.remove", arguments: ["id": .string, "expected_root_path": .string],
        required: ["id", "expected_root_path"], readOnly: false),
      summary:
        "Remove a workspace registration matching the reviewed root path. Files and retained work are preserved. Requires approved Full Access.",
      risk: .fullShell, destructive: true),
    .init(
      input: .init(
        "workspace.grant",
        arguments: ["id": .string, "enabled": .boolean, "expected_profile_revision": .integer],
        required: ["id", "enabled", "expected_profile_revision"], readOnly: false),
      summary:
        "Change one workspace grant for this connection's profile using its exact revision. Requires approved Full Access. Changing profile authority invalidates prior Full consent.",
      risk: .fullShell),
    .init(
      input: .init(
        "plugin.list", arguments: ["after_id": .string, "limit": .integer], readOnly: true),
      summary:
        "List installed and bundled plugin summaries without credentials or launch arguments. Live pages use after_id; limit defaults to 50 and is at most 200.",
      risk: .readOnly),
    .init(
      input: .init(
        "plugin.describe", arguments: ["id": .string, "after_id": .string, "limit": .integer],
        required: ["id"], readOnly: true),
      summary:
        "Inspect one plugin's selection and safe settings, with a live page of installations and exact store revision. after_id continues the page; limit defaults to 50 and is at most 200. Credentials and launch arguments are omitted.",
      risk: .readOnly),
    .init(
      input: .init(
        "plugin.search",
        arguments: ["query": .string, "kind": .string, "page": .integer, "refresh": .boolean],
        readOnly: true),
      summary:
        "Search the official static plugin catalog. Pages start at 1; optional kind is mcp, cli or skills.",
      risk: .readOnly, network: true),
    .init(
      input: .init(
        "plugin.artifacts",
        arguments: [
          "repository": .string, "repository_id": .integer, "tag": .string, "page": .integer,
        ],
        required: ["repository", "repository_id"], readOnly: true),
      summary:
        "Inspect official release artifacts for an exact catalog repository identity. Pass a returned artifact unchanged to plugin.install or plugin.update.",
      risk: .readOnly, network: true),
    .init(
      input: .init(
        "plugin.install", arguments: ["artifact": .object, "expected_revision": .integer],
        required: ["artifact", "expected_revision"], readOnly: false),
      summary:
        "Install one official release after current GitHub provenance and archive-byte verification. Requires approved Full Access and exact store revision; activation is separate.",
      risk: .fullShell, network: true),
    .init(
      input: .init(
        "plugin.update",
        arguments: ["id": .string, "artifact": .object, "expected_revision": .integer],
        required: ["id", "artifact", "expected_revision"], readOnly: false),
      summary:
        "Install a selected official release for an existing plugin, preserving saved settings and already-running work. Requires approved Full Access and exact store revision.",
      risk: .fullShell, network: true),
    .init(
      input: .init(
        "plugin.configure",
        arguments: ["id": .string, "settings": .object, "expected_revision": .integer],
        required: ["id", "settings", "expected_revision"], readOnly: false),
      summary:
        "Patch host settings for a bundled or verified official plugin. Requires approved Full Access and exact store revision. MCP authentication changes require the local credential owner.",
      risk: .fullShell),
    .init(
      input: .init(
        "plugin.enable", arguments: ["id": .string, "expected_revision": .integer],
        required: ["id", "expected_revision"], readOnly: false),
      summary:
        "Enable a bundled or verified official plugin in an approved Full Access session using the exact store revision.",
      risk: .fullShell),
    .init(
      input: .init(
        "plugin.disable", arguments: ["id": .string, "expected_revision": .integer],
        required: ["id", "expected_revision"], readOnly: false),
      summary:
        "Disable new calls to a plugin while retaining its active work. Requires approved Full Access and exact store revision.",
      risk: .fullShell),
    .init(
      input: .init(
        "plugin.uninstall", arguments: ["installation_id": .string, "expected_revision": .integer],
        required: ["installation_id", "expected_revision"], readOnly: false),
      summary:
        "Uninstall one plugin artifact installation using the exact store revision. Active work retains its artifact lease. Requires approved Full Access.",
      risk: .fullShell, destructive: true),
  ]

  static let byName = Dictionary(uniqueKeysWithValues: contracts.map { ($0.input.name, $0) })
  static var tools: [MCPTool] { contracts.map(\.tool) }
  static var readCapabilities: Set<String> {
    Set(contracts.filter { $0.risk == .readOnly }.map { $0.input.name })
  }

  static func denied(_ message: String) -> GatewayToolError {
    .invalidArguments("[management.local_consent_required] " + message)
  }

  static func path(_ value: String) throws -> URL {
    guard value.hasPrefix("/"), !value.contains("\0") else {
      throw GatewayToolError.invalidArguments("Workspace paths must be absolute and NUL-free.")
    }
    return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
  }

  static func workspace(_ value: RegisteredWorkspace) -> JSONValue {
    .object([
      "id": .string(value.id), "display_name": .string(value.displayName),
      "root_path": .string(value.rootPath), "bookmark_stale": .bool(value.bookmarkIsStale),
    ])
  }

  static func pluginIDs(_ snapshot: PluginHostSnapshot) -> [String] {
    Set(snapshot.state.installations.map(\.pluginID) + snapshot.bundled.map { $0.manifest.id })
      .sorted()
  }

  static func requireTrustedPlugin(_ id: String, snapshot: PluginHostSnapshot) throws {
    if let selected = snapshot.state.selectedInstallations[id],
      let record = snapshot.state.installations.first(where: { $0.id == selected })
    {
      guard record.source.kind == .artifact, let release = record.source.githubRelease,
        release.declaration.pluginID == id,
        record.source.artifactSHA256 == release.sha256
      else { throw denied("This plugin source requires a local trust decision.") }
      try release.validate()
    } else if !snapshot.bundled.contains(where: { $0.manifest.id == id }) {
      throw denied("Select a bundled or verified official plugin through the local owner.")
    }
  }

  static func plugin(
    _ id: String, snapshot: PluginHostSnapshot, details: Bool = true,
    afterID: String = "", limit: Int = 50
  ) throws -> JSONValue {
    guard pluginIDs(snapshot).contains(id) else { throw PluginStoreError.unknownInstallation(id) }
    let settings = snapshot.settings(for: id)
    guard (1...200).contains(limit) else {
      throw GatewayToolError.invalidArguments("limit must be between 1 and 200.")
    }
    let installations = snapshot.state.installations.filter { $0.pluginID == id }.sorted {
      $0.id < $1.id
    }
    var result: [String: JSONValue] = [
      "id": .string(id), "revision": .integer(snapshot.state.revision),
      "enabled": .bool(settings.enabled),
      "installation_count": .integer(Int64(installations.count)),
      "selected_installation": snapshot.state.selectedInstallations[id].map(JSONValue.string)
        ?? .null,
      "bundled": .bool(snapshot.bundled.contains { $0.manifest.id == id }),
    ]
    guard details else { return .object(result) }
    let remaining = installations.filter { $0.id > afterID }
    let selected = Array(remaining.prefix(limit))
    let records = try selected.map { record in
      JSONValue.object([
        "id": .string(record.id), "version": .string(record.version.description),
        "source": .string(record.source.kind.rawValue),
        "official_release": try record.source.githubRelease.map(ControlToolResponse.encodedPayload)
          ?? .null,
        "selected": .bool(snapshot.state.selectedInstallations[id] == record.id),
      ])
    }
    var safeSettings = try JSONValue.encoded(settings).objectValue ?? [:]
    safeSettings["mcp"] = .object(
      try settings.mcp.mapValues { choice in
        var value = try JSONValue.encoded(choice).objectValue ?? [:]
        value.removeValue(forKey: "authentication")
        value.removeValue(forKey: "args")
        value["has_authentication"] = .bool(choice.authentication != nil)
        value["argument_count"] = choice.args.map { .integer(Int64($0.count)) } ?? .null
        return .object(value)
      })
    result["settings"] = .object(safeSettings)
    result["installations"] = .array(records)
    result["next_after_id"] = remaining.count > limit ? .string(selected.last!.id) : .null
    return .object(result)
  }

  /// Merge only supplied choices, retaining secret configuration under its local owner.
  static func patchSettings(_ patch: JSONValue, current: PluginSettings) throws -> PluginSettings {
    guard let object = patch.objectValue,
      Set(object.keys).isSubset(of: ["enabled", "mcp", "cli", "skills", "dependencyExecutables"])
    else { throw GatewayToolError.invalidArguments("Unknown plugin settings field.") }
    if let mcp = object["mcp"]?.objectValue {
      for value in mcp.values where value.objectValue?["authentication"] != nil {
        throw denied("MCP authentication changes require the local credential owner.")
      }
    }
    func merge(_ base: JSONValue, _ patch: JSONValue) -> JSONValue {
      guard var base = base.objectValue, let patch = patch.objectValue else { return patch }
      for (key, value) in patch { base[key] = merge(base[key] ?? .null, value) }
      return .object(base)
    }
    let merged = try merge(JSONValue.encoded(current), patch)
    let result = try JSONDecoder().decode(
      PluginSettings.self, from: ControlToolResponse.encodedJSON(merged))
    guard
      result.mcp.mapValues(\.authentication)
        == current.mcp.mapValues(\.authentication).merging(
          result.mcp.filter { current.mcp[$0.key] == nil }.mapValues(\.authentication),
          uniquingKeysWith: { old, _ in old })
    else { throw denied("MCP authentication changes require the local credential owner.") }
    return result
  }
}

/// Captured before asynchronous preparation; only the commit runs under its lock.
package struct GatewayManagementAuthorization: Sendable {
  let session: GatewayControlSession
  let context: ExecutionContext
  let revision: Int64
  let requiresFullAccess: Bool
  let consent: GatewayFullAccessConsent?

  init(
    session: GatewayControlSession, context: ExecutionContext, revision: Int64,
    requiresFullAccess: Bool
  ) {
    self.session = session
    self.context = context
    self.revision = revision
    self.requiresFullAccess = requiresFullAccess
    self.consent = session.snapshot.fullAccessConsent
  }

  func perform<Result>(_ operation: () throws -> Result) throws -> Result {
    try session.withManagementAuthorization(
      context: context, expectedRevision: revision, requiresFullAccess: requiresFullAccess,
      operation: operation)
  }
}
