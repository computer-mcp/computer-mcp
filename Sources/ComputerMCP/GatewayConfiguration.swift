import Foundation
import TOML

private struct ConfigurationCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int?

  init?(stringValue: String) {
    self.stringValue = stringValue
    self.intValue = nil
  }

  init?(intValue: Int) {
    self.stringValue = String(intValue)
    self.intValue = intValue
  }
}

private indirect enum ConfigurationNode: Decodable {
  case object([String: ConfigurationNode])
  case array([ConfigurationNode])
  case scalar

  init(from decoder: any Decoder) throws {
    if let container = try? decoder.container(keyedBy: ConfigurationCodingKey.self) {
      var values: [String: ConfigurationNode] = [:]
      for key in container.allKeys {
        values[key.stringValue] = try container.decode(ConfigurationNode.self, forKey: key)
      }
      self = .object(values)
      return
    }
    if var container = try? decoder.unkeyedContainer() {
      var values: [ConfigurationNode] = []
      while !container.isAtEnd {
        values.append(try container.decode(ConfigurationNode.self))
      }
      self = .array(values)
      return
    }

    let container = try decoder.singleValueContainer()
    if container.decodeNil()
      || (try? container.decode(Bool.self)) != nil
      || (try? container.decode(Int.self)) != nil
      || (try? container.decode(Double.self)) != nil
      || (try? container.decode(String.self)) != nil
      || (try? container.decode(Date.self)) != nil
    {
      self = .scalar
      return
    }
    throw DecodingError.typeMismatch(
      ConfigurationNode.self,
      DecodingError.Context(
        codingPath: decoder.codingPath,
        debugDescription: "Unsupported TOML value."
      )
    )
  }

  var fieldPaths: Set<String> {
    collectFieldPaths(prefix: "")
  }

  private func collectFieldPaths(prefix: String) -> Set<String> {
    switch self {
    case .scalar:
      return []
    case .array(let values):
      return values.reduce(into: Set<String>()) { paths, value in
        paths.formUnion(value.collectFieldPaths(prefix: prefix))
      }
    case .object(let values):
      return values.reduce(into: Set<String>()) { paths, entry in
        let path = prefix.isEmpty ? entry.key : "\(prefix).\(entry.key)"
        paths.insert(path)
        paths.formUnion(entry.value.collectFieldPaths(prefix: path))
      }
    }
  }
}

package struct GatewayConfiguration: Equatable, Sendable {
  package var schemaVersion: Int
  package var server: ServerConfig
  package var runtime: RuntimeBindingConfig
  package var policy: PolicyConfig
  package var workspaces: [WorkspaceManifestConfig]
  package var profiles: [ProfileGrantConfig]
  package var transports: TransportSectionConfig
  package var cli: CLISectionConfig
  package var mcp: MCPSectionConfig
  package var tools: [ToolConfig]
  package var builtin: BuiltinConfig
  package var skills: SkillsConfig
  package var codex: CodexConfig
  package var workspaceDirectory: URL

  package init(
    schemaVersion: Int = 1,
    server: ServerConfig = ServerConfig(),
    runtime: RuntimeBindingConfig = RuntimeBindingConfig(),
    policy: PolicyConfig = PolicyConfig(),
    workspaces: [WorkspaceManifestConfig] = [],
    profiles: [ProfileGrantConfig] = [],
    transports: TransportSectionConfig = TransportSectionConfig(),
    cli: CLISectionConfig = CLISectionConfig(),
    mcp: MCPSectionConfig = MCPSectionConfig(),
    tools: [ToolConfig] = [],
    builtin: BuiltinConfig = BuiltinConfig(),
    skills: SkillsConfig = SkillsConfig(),
    codex: CodexConfig = CodexConfig(),
    workspaceDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  ) {
    self.schemaVersion = schemaVersion
    self.server = server
    self.runtime = runtime
    self.policy = policy
    self.workspaces = workspaces
    self.profiles = profiles
    self.transports = transports
    self.cli = cli
    self.mcp = mcp
    self.tools = tools
    self.builtin = builtin
    self.skills = skills
    self.codex = codex
    self.workspaceDirectory = workspaceDirectory
  }

  package static func load(path: String) throws -> GatewayConfiguration {
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    guard let text = String(data: data, encoding: .utf8) else {
      throw ConfigurationError.invalid("Config file is not valid UTF-8: \(path)")
    }
    return try load(text: text, baseURL: url.deletingLastPathComponent())
  }

  package static func load(
    text: String,
    baseURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  ) throws -> GatewayConfiguration {
    let decoder = TOMLDecoder()
    let inputShape = try decoder.decode(ConfigurationNode.self, from: text)
    var configuration = try decoder.decode(GatewayConfiguration.self, from: text)
    let base = baseURL.standardizedFileURL
    configuration.workspaceDirectory = base
    configuration.workspaces = configuration.workspaces.map { $0.resolved(base: base) }
    configuration.skills = configuration.skills.resolved(base: base)
    try configuration.validate()
    let canonicalShape = try decoder.decode(
      ConfigurationNode.self,
      from: try configuration.exportedTOML()
    )
    let unknownFields = inputShape.fieldPaths.subtracting(canonicalShape.fieldPaths).sorted()
    guard unknownFields.isEmpty else {
      throw ConfigurationError.invalid(
        "Unknown configuration field\(unknownFields.count == 1 ? "" : "s"): "
          + unknownFields.joined(separator: ", ")
      )
    }
    return configuration
  }

  package func validate() throws {
    guard schemaVersion == 1 else {
      throw ConfigurationError.invalid("schema_version must be 1.")
    }
    try server.validate()
    try runtime.validate()
    try policy.validate()
    try skills.validate()
    try codex.validate()
    try validateUniqueIDs(workspaces.map(\.id), label: "workspace")
    try validateUniqueIDs(profiles.map { $0.id.rawValue }, label: "profile")
    try validateUniqueIDs(transports.openAI.map(\.id), label: "OpenAI transport")
    try validateUniqueIDs(transports.cloudflare.map(\.id), label: "Cloudflare transport")
    for registeredWorkspace in workspaces {
      try registeredWorkspace.validate()
    }
    let workspaceIDs = Set(workspaces.map(\.id))
    for profile in profiles {
      try profile.validate(knownWorkspaceIDs: workspaceIDs)
    }
    try transports.validate()
    for transport in transports.openAI {
      guard profileGrant(for: transport.gatewayProfile).allowedCallers.contains(.secureTunnel)
      else {
        throw ConfigurationError.invalid(
          "OpenAI transport '\(transport.id)' profile '\(transport.gatewayProfile.rawValue)' does not allow secure-tunnel."
        )
      }
    }
    for transport in transports.cloudflare {
      guard profileGrant(for: transport.gatewayProfile).allowedCallers.contains(.cloudflareTunnel)
      else {
        throw ConfigurationError.invalid(
          "Cloudflare transport '\(transport.id)' profile '\(transport.gatewayProfile.rawValue)' does not allow cloudflare-tunnel."
        )
      }
    }
    if let defaultWorkspaceID = runtime.defaultWorkspaceID,
      !workspaceIDs.isEmpty,
      !workspaceIDs.contains(defaultWorkspaceID)
    {
      throw ConfigurationError.invalid(
        "runtime.workspace_id references unknown workspace '\(defaultWorkspaceID)'."
      )
    }
    if runtime.profileID == .localAdmin && runtime.caller.isRemote {
      throw ConfigurationError.invalid(
        "runtime cannot bind remote caller '\(runtime.caller.rawValue)' to local-admin."
      )
    }
    try validateUniqueIDs(cli.commands.map(\.id), label: "CLI command")
    try validateUniqueIDs(mcp.servers.map(\.id), label: "MCP server")
    try validateUniqueToolNames(tools.map(\.name))

    for command in cli.commands {
      try command.validate()
    }

    var reexportPrefixes = Set<String>()
    for server in mcp.servers {
      try server.validate()
      if runtime.caller.isRemote && server.allowAnyTool {
        throw ConfigurationError.invalid(
          "MCP server '\(server.id)' cannot set allow_any_tool for remote caller "
            + "'\(runtime.caller.rawValue)'. Review allowed_tools or use pinned [[tools]]."
        )
      }
      if server.exposure.includesReexport {
        guard let prefix = server.prefix, !prefix.isEmpty else {
          throw ConfigurationError.invalid(
            "MCP server '\(server.id)' uses reexport exposure but has no prefix.")
        }
        guard server.allowAnyTool || !server.allowedTools.isEmpty else {
          throw ConfigurationError.invalid(
            "MCP server '\(server.id)' reexport requires allowed_tools or local allow_any_tool."
          )
        }
        guard reexportPrefixes.insert(prefix).inserted else {
          throw ConfigurationError.invalid("Duplicate MCP reexport prefix: \(prefix)")
        }
      }
    }

    let mcpIDs = Set(mcp.servers.map(\.id))
    let reservedToolNames = Set([
      "cli.list",
      "cli.describe",
      "cli.status",
      "cli.help",
      "cli.exec",
      "mcp.servers.list",
      "mcp.servers.status",
      "mcp.tools.list",
      "mcp.tools.describe",
      "mcp.tools.find",
      "mcp.tools.call",
      "mcp.resources.list",
      "mcp.resources.templates.list",
      "mcp.resources.read",
      "mcp.prompts.list",
      "mcp.prompts.get",
      "mcp.events.read",
      "mcp.requests.list",
      "mcp.requests.cancel",
      "policy.probe",
      "process.spawn",
      "process.list",
      "process.read",
      "process.cancel",
      "skills.roots",
      "skills.list",
      "skills.describe",
      "skills.validate",
      "skills.read",
      "skills.files",
      "skills.read_file",
      "skills.read_files",
      "skills.read_package",
      "skills.outline",
      "skills.link_check",
      "skills.search",
      "skills.search_files",
      "shell.run",
      "shell.spawn",
      "shell.list",
      "shell.read",
      "shell.write",
      "shell.cancel",
      "computer.permissions",
      "computer.displays",
      "computer.screenshot",
      "computer.windows",
      "computer.pointer.position",
      "computer.pointer.move",
      "computer.pointer.click",
      "computer.keyboard.key",
      "computer.keyboard.text",
      "computer.scroll",
      "computer.accessibility.query",
      "computer.accessibility.action",
      "computer.verify",
      "codex.app.status",
      "codex.app.methods.list",
      "codex.app.methods.describe",
      "codex.app.methods.call",
      "codex.app.thread.start",
      "codex.app.thread.list",
      "codex.app.thread.read",
      "codex.app.thread.fork",
      "codex.app.turn.start",
      "codex.app.turn.interrupt",
      "codex.app.review.start",
      "codex.app.models.list",
      "codex.app.skills.list",
      "codex.app.apps.list",
      "codex.app.events.read",
      "codex.app.requests.list",
      "codex.app.requests.respond",
      "codex.exec.start",
      "codex.exec.resume",
      "codex.exec.list",
      "codex.exec.events",
      "codex.exec.result",
      "codex.exec.cancel",
      "codex.mcp.status",
      "codex.mcp.tools.list",
      "codex.mcp.run",
      "codex.mcp.reply",
      "codex.mcp.calls.list",
      "codex.mcp.events",
      "codex.mcp.result",
      "codex.mcp.approvals.list",
      "codex.mcp.approval.respond",
      "codex.mcp.cancel",
      "workspace.info",
      "workspace.status",
      "workspace.manifests",
      "workspace.recent_files",
      "workspace.directory_stats",
      "workspace.artifact_directories",
      "workspace.empty_directories",
      "workspace.git_changes",
      "workspace.file_types",
      "workspace.large_files",
      "workspace.symlinks",
      "workspace.executable_files",
      "workspace.todos",
      "workspace.env_files",
      "workspace.dependency_files",
      "workspace.project_roots",
      "workspace.documentation_files",
      "workspace.agent_files",
      "workspace.instructions",
      "workspace.test_files",
      "workspace.ci_files",
      "workspace.infra_files",
      "workspace.config_files",
      "workspace.ignore_files",
      "workspace.asset_files",
      "workspace.archive_files",
      "workspace.log_files",
      "workspace.data_files",
      "workspace.schema_files",
      "workspace.source_files",
      "workspace.outline",
      "workspace.commands",
      "workspace.governance_files",
      "system.info",
      "system.kernel",
      "system.software",
      "system.locale",
      "system.memory",
      "system.load",
      "system.cpu",
      "system.thermal",
      "system.time",
      "system.uptime",
      "system.user",
      "system.groups",
      "system.power",
      "system.volumes",
      "system.processes",
      "system.which",
      "system.path",
      "logs.query",
      "service.status",
      "network.interfaces",
      "network.dns",
      "network.resolve",
      "network.proxy",
      "network.services",
      "network.hardware_ports",
      "network.wifi",
      "network.vpn",
      "network.locations",
      "network.routes",
      "network.connections",
      "network.arp",
      "network.ping",
      "network.tcp_check",
      "network.http_check",
      "network.listeners",
      "macos.user_directories",
      "macos.default_application",
      "macos.applications",
      "macos.screens",
      "macos.spotlight_search",
      "macos.running_applications",
      "macos.frontmost_application",
      "env.describe",
      "file.exists",
      "file.list",
      "file.tree",
      "file.stat",
      "file.permissions",
      "file.chmod",
      "file.type",
      "file.count",
      "file.disk_usage",
      "file.volume_info",
      "file.find",
      "file.search",
      "file.timeline",
      "file.read",
      "file.read_files",
      "file.read_window",
      "file.read_lines",
      "file.read_context",
      "file.head",
      "file.outline",
      "markdown.links",
      "markdown.tables",
      "markdown.section",
      "markdown.frontmatter",
      "markdown.link_check",
      "file.tail",
      "file.hexdump",
      "file.xattrs",
      "file.remove_xattr",
      "file.metadata",
      "file.readlink",
      "file.resolve",
      "image.info",
      "pdf.info",
      "pdf.text",
      "media.info",
      "json.read",
      "jsonl.read",
      "json.write",
      "toml.read",
      "yaml.read",
      "xml.read",
      "plist.read",
      "structured.get",
      "plist.write",
      "csv.read",
      "sqlite.schema",
      "sqlite.query",
      "file.hash",
      "file.diff",
      "file.compare_trees",
      "file.duplicates",
      "archive.list",
      "archive.read_file",
      "archive.extract",
      "archive.create",
      "file.download",
      "file.write",
      "file.write_files",
      "file.append",
      "file.replace_text",
      "file.insert_text",
      "file.replace_lines",
      "file.touch",
      "file.mkdir",
      "file.copy",
      "file.move",
      "file.symlink",
      "file.trash",
      "workspace.open",
      "workspace.reveal",
      "git.root",
      "git.config",
      "git.remotes",
      "git.worktrees",
      "git.stashes",
      "git.stash_show",
      "git.stash_push",
      "git.tags",
      "git.tag_show",
      "git.tag_create",
      "git.tag_delete",
      "git.ignored",
      "git.submodules",
      "git.files",
      "git.grep",
      "git.blame",
      "git.file_history",
      "git.file_at_revision",
      "git.staged_file",
      "git.conflicts",
      "git.status",
      "git.tracking_status",
      "git.clean_preview",
      "git.clean",
      "git.reflog",
      "git.refs",
      "git.resolve_ref",
      "git.merge_base",
      "git.compare_refs",
      "git.is_ancestor",
      "git.diff",
      "git.diff_summary",
      "git.diff_check",
      "git.branch",
      "git.branch_create",
      "git.branch_delete",
      "git.branch_rename",
      "git.branch_switch",
      "git.log",
      "git.commit_files",
      "git.show",
      "git.add",
      "git.unstage",
      "git.restore_worktree",
      "git.commit",
    ])

    for tool in tools {
      try tool.validate()
      if reservedToolNames.contains(tool.name) {
        throw ConfigurationError.invalid(
          "Configured tool name conflicts with gateway tool: \(tool.name)")
      }

      switch tool.adapter {
      case .mcp:
        guard mcpIDs.contains(tool.source) else {
          throw ConfigurationError.invalid(
            "Configured tool '\(tool.name)' references unknown MCP source: \(tool.source)")
        }
      }
    }

    let knownBuiltins = Set([
      "workspace.info",
      "workspace.status",
      "workspace.manifests",
      "workspace.recent_files",
      "workspace.directory_stats",
      "workspace.artifact_directories",
      "workspace.empty_directories",
      "workspace.git_changes",
      "workspace.file_types",
      "workspace.large_files",
      "workspace.symlinks",
      "workspace.executable_files",
      "workspace.todos",
      "workspace.env_files",
      "workspace.dependency_files",
      "workspace.project_roots",
      "workspace.documentation_files",
      "workspace.agent_files",
      "workspace.instructions",
      "workspace.test_files",
      "workspace.ci_files",
      "workspace.infra_files",
      "workspace.config_files",
      "workspace.ignore_files",
      "workspace.asset_files",
      "workspace.archive_files",
      "workspace.log_files",
      "workspace.data_files",
      "workspace.schema_files",
      "workspace.source_files",
      "workspace.outline",
      "workspace.commands",
      "workspace.governance_files",
      "system.info",
      "system.kernel",
      "system.software",
      "system.locale",
      "system.memory",
      "system.load",
      "system.cpu",
      "system.thermal",
      "system.time",
      "system.uptime",
      "system.user",
      "system.groups",
      "system.power",
      "system.volumes",
      "system.processes",
      "system.which",
      "system.path",
      "logs.query",
      "service.status",
      "network.interfaces",
      "network.dns",
      "network.resolve",
      "network.proxy",
      "network.services",
      "network.hardware_ports",
      "network.wifi",
      "network.vpn",
      "network.locations",
      "network.routes",
      "network.connections",
      "network.arp",
      "network.ping",
      "network.tcp_check",
      "network.http_check",
      "network.listeners",
      "macos.user_directories",
      "macos.default_application",
      "macos.applications",
      "macos.screens",
      "macos.spotlight_search",
      "macos.running_applications",
      "macos.frontmost_application",
      "env.describe",
      "file.exists",
      "file.list",
      "file.tree",
      "file.stat",
      "file.permissions",
      "file.chmod",
      "file.type",
      "file.count",
      "file.disk_usage",
      "file.volume_info",
      "file.find",
      "file.search",
      "file.timeline",
      "file.read",
      "file.read_files",
      "file.read_window",
      "file.read_lines",
      "file.read_context",
      "file.head",
      "file.outline",
      "markdown.links",
      "markdown.tables",
      "markdown.section",
      "markdown.frontmatter",
      "markdown.link_check",
      "file.tail",
      "file.hexdump",
      "file.xattrs",
      "file.remove_xattr",
      "file.metadata",
      "file.readlink",
      "file.resolve",
      "image.info",
      "pdf.info",
      "pdf.text",
      "media.info",
      "json.read",
      "jsonl.read",
      "json.write",
      "toml.read",
      "yaml.read",
      "xml.read",
      "plist.read",
      "structured.get",
      "plist.write",
      "csv.read",
      "sqlite.schema",
      "sqlite.query",
      "file.hash",
      "file.diff",
      "file.compare_trees",
      "file.duplicates",
      "archive.list",
      "archive.read_file",
      "archive.extract",
      "archive.create",
      "file.download",
      "file.write",
      "file.write_files",
      "file.append",
      "file.replace_text",
      "file.insert_text",
      "file.replace_lines",
      "file.touch",
      "file.mkdir",
      "file.copy",
      "file.move",
      "file.symlink",
      "file.trash",
      "workspace.open",
      "workspace.reveal",
      "git.root",
      "git.config",
      "git.remotes",
      "git.worktrees",
      "git.stashes",
      "git.stash_show",
      "git.stash_push",
      "git.tags",
      "git.tag_show",
      "git.tag_create",
      "git.tag_delete",
      "git.ignored",
      "git.submodules",
      "git.files",
      "git.grep",
      "git.blame",
      "git.file_history",
      "git.file_at_revision",
      "git.staged_file",
      "git.conflicts",
      "git.status",
      "git.tracking_status",
      "git.clean_preview",
      "git.clean",
      "git.reflog",
      "git.refs",
      "git.resolve_ref",
      "git.merge_base",
      "git.compare_refs",
      "git.is_ancestor",
      "git.diff",
      "git.diff_summary",
      "git.diff_check",
      "git.branch",
      "git.branch_create",
      "git.branch_delete",
      "git.branch_rename",
      "git.branch_switch",
      "git.log",
      "git.commit_files",
      "git.show",
      "git.add",
      "git.unstage",
      "git.restore_worktree",
      "git.commit",
    ])
    for builtin in builtin.enabled where !knownBuiltins.contains(builtin) {
      throw ConfigurationError.invalid("Unknown builtin capability: \(builtin)")
    }
  }

  package var manifestWorkspaces: [RegisteredWorkspace] {
    if workspaces.isEmpty {
      return [
        RegisteredWorkspace(
          id: "default",
          displayName: workspaceDirectory.lastPathComponent.isEmpty
            ? "Default Workspace" : workspaceDirectory.lastPathComponent,
          rootPath: workspaceDirectory.path
        )
      ]
    }
    return workspaces.compactMap(\.registeredWorkspace)
  }

  package func profileGrant(for id: GatewayProfileID) -> ProfileGrant {
    if let configured = profiles.first(where: { $0.id == id }) {
      return configured.grant
    }
    if id == .chatGPTObserve { return .observe }
    if id == .chatGPTOperate { return .operate }
    if id == .cloudflareObserve { return .cloudflareObserve }
    if id == .cloudflareOperate { return .cloudflareOperate }
    if id == .localAdmin { return .localAdmin }
    return ProfileGrant(id: id, capabilityIDs: [], allowedCallers: [])
  }

  package func executionContext(
    caller: GatewayCallerKind? = nil,
    profileID: GatewayProfileID? = nil,
    workspaceID: String? = nil,
    requestID: String = UUID().uuidString,
    transportTrace: GatewayTransportTrace? = nil
  ) -> ExecutionContext {
    ExecutionContext(
      requestID: requestID,
      caller: caller ?? runtime.caller,
      profileID: profileID ?? runtime.profileID,
      workspaceID: workspaceID ?? runtime.defaultWorkspaceID,
      transportTrace: transportTrace
    )
  }

  package func exportedTOML() throws -> String {
    let encoder = TOMLEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try validate()
    return try encoder.encodeToString(self)
  }

  private func validateUniqueIDs(_ ids: [String], label: String) throws {
    var seen = Set<String>()
    for id in ids {
      guard !id.isEmpty else {
        throw ConfigurationError.invalid("\(label) id must not be empty.")
      }
      guard seen.insert(id).inserted else {
        throw ConfigurationError.invalid("Duplicate \(label) id: \(id)")
      }
    }
  }

  private func validateUniqueToolNames(_ names: [String]) throws {
    var seen = Set<String>()
    for name in names {
      try validateGatewayToolID(name, label: "tools.name")
      guard seen.insert(name).inserted else {
        throw ConfigurationError.invalid("Duplicate tool name: \(name)")
      }
    }
  }
}

extension GatewayConfiguration: Codable {
  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case server
    case runtime
    case policy
    case workspaces
    case profiles
    case transports
    case cli
    case mcp
    case tools
    case builtin
    case skills
    case codex
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    self.server =
      try container.decodeIfPresent(ServerConfig.self, forKey: .server) ?? ServerConfig()
    self.runtime =
      try container.decodeIfPresent(RuntimeBindingConfig.self, forKey: .runtime)
      ?? RuntimeBindingConfig()
    self.policy =
      try container.decodeIfPresent(PolicyConfig.self, forKey: .policy) ?? PolicyConfig()
    self.workspaces =
      try container.decodeIfPresent([WorkspaceManifestConfig].self, forKey: .workspaces) ?? []
    self.profiles =
      try container.decodeIfPresent([ProfileGrantConfig].self, forKey: .profiles) ?? []
    self.transports =
      try container.decodeIfPresent(TransportSectionConfig.self, forKey: .transports)
      ?? TransportSectionConfig()
    self.cli =
      try container.decodeIfPresent(CLISectionConfig.self, forKey: .cli)
      ?? CLISectionConfig()
    self.mcp =
      try container.decodeIfPresent(MCPSectionConfig.self, forKey: .mcp)
      ?? MCPSectionConfig()
    self.tools = try container.decodeIfPresent([ToolConfig].self, forKey: .tools) ?? []
    self.builtin =
      try container.decodeIfPresent(BuiltinConfig.self, forKey: .builtin)
      ?? BuiltinConfig()
    self.skills =
      try container.decodeIfPresent(SkillsConfig.self, forKey: .skills)
      ?? SkillsConfig()
    self.codex =
      try container.decodeIfPresent(CodexConfig.self, forKey: .codex)
      ?? CodexConfig()
    self.workspaceDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(server, forKey: .server)
    try container.encode(runtime, forKey: .runtime)
    try container.encode(policy, forKey: .policy)
    try container.encode(workspaces, forKey: .workspaces)
    try container.encode(profiles, forKey: .profiles)
    try container.encode(transports, forKey: .transports)
    try container.encode(cli, forKey: .cli)
    try container.encode(mcp, forKey: .mcp)
    try container.encode(tools, forKey: .tools)
    try container.encode(builtin, forKey: .builtin)
    try container.encode(skills, forKey: .skills)
    try container.encode(codex, forKey: .codex)
  }
}

package struct TransportSectionConfig: Codable, Equatable, Sendable {
  package var openAI: [OpenAITunnelTransportConfig]
  package var cloudflare: [CloudflareTunnelTransportConfig]

  package init(
    openAI: [OpenAITunnelTransportConfig] = [],
    cloudflare: [CloudflareTunnelTransportConfig] = []
  ) {
    self.openAI = openAI
    self.cloudflare = cloudflare
  }

  private enum CodingKeys: String, CodingKey {
    case openAI = "openai"
    case cloudflare
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    openAI =
      try container.decodeIfPresent([OpenAITunnelTransportConfig].self, forKey: .openAI) ?? []
    cloudflare =
      try container.decodeIfPresent([CloudflareTunnelTransportConfig].self, forKey: .cloudflare)
      ?? []
  }

  fileprivate func validate() throws {
    for configuration in openAI { try configuration.validate() }
    for configuration in cloudflare { try configuration.validate() }
  }
}

package struct OpenAITunnelTransportConfig: Codable, Equatable, Sendable, Identifiable {
  package var id: String
  package var tunnelClientProfile: String
  package var tunnelID: String
  package var gatewayProfile: GatewayProfileID
  package var profileDirectory: String?
  package var tunnelClientPath: String?
  package var httpProxy: String?
  package var requiresAPIKey: Bool

  package init(
    id: String,
    tunnelClientProfile: String,
    tunnelID: String,
    gatewayProfile: GatewayProfileID = .chatGPTObserve,
    profileDirectory: String? = nil,
    tunnelClientPath: String? = nil,
    httpProxy: String? = nil,
    requiresAPIKey: Bool = false
  ) {
    self.id = id
    self.tunnelClientProfile = tunnelClientProfile
    self.tunnelID = tunnelID
    self.gatewayProfile = gatewayProfile
    self.profileDirectory = profileDirectory
    self.tunnelClientPath = tunnelClientPath
    self.httpProxy = httpProxy
    self.requiresAPIKey = requiresAPIKey
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case tunnelClientProfile = "tunnel_client_profile"
    case tunnelID = "tunnel_id"
    case gatewayProfile = "gateway_profile"
    case profileDirectory = "profile_directory"
    case tunnelClientPath = "tunnel_client_path"
    case httpProxy = "http_proxy"
    case requiresAPIKey = "requires_api_key"
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    tunnelClientProfile = try container.decode(String.self, forKey: .tunnelClientProfile)
    tunnelID = try container.decode(String.self, forKey: .tunnelID)
    gatewayProfile =
      try container.decodeIfPresent(GatewayProfileID.self, forKey: .gatewayProfile)
      ?? .chatGPTObserve
    profileDirectory = try container.decodeIfPresent(String.self, forKey: .profileDirectory)
    tunnelClientPath = try container.decodeIfPresent(String.self, forKey: .tunnelClientPath)
    httpProxy = try container.decodeIfPresent(String.self, forKey: .httpProxy)
    requiresAPIKey = try container.decodeIfPresent(Bool.self, forKey: .requiresAPIKey) ?? false
  }

  fileprivate func validate() throws {
    try validateConfigIdentifier(id, label: "transports.openai.id")
    for (label, value) in [
      ("transports.openai.tunnel_client_profile", tunnelClientProfile),
      ("transports.openai.tunnel_id", tunnelID),
    ] {
      guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !value.contains("\0")
      else { throw ConfigurationError.invalid("\(label) must not be empty.") }
    }
    guard gatewayProfile != .localAdmin else {
      throw ConfigurationError.invalid("OpenAI transport cannot use local-admin.")
    }
    try validateOptionalAbsolutePath(profileDirectory, label: "transports.openai.profile_directory")
    try validateOptionalAbsolutePath(
      tunnelClientPath, label: "transports.openai.tunnel_client_path")
    if let httpProxy,
      let failure = openAITunnelHTTPProxyValidationFailure(httpProxy)
    {
      throw ConfigurationError.invalid("transports.openai.\(failure)")
    }
  }
}

package struct CloudflareTunnelTransportConfig: Codable, Equatable, Sendable, Identifiable {
  package var id: String
  package var tunnelName: String
  package var publicHostname: String
  package var gatewayProfile: GatewayProfileID
  package var localPort: Int
  package var metricsPort: Int
  package var cloudflaredPath: String?

  package init(
    id: String,
    tunnelName: String,
    publicHostname: String,
    gatewayProfile: GatewayProfileID = .cloudflareObserve,
    localPort: Int = 8_765,
    metricsPort: Int = 20_241,
    cloudflaredPath: String? = nil
  ) {
    self.id = id
    self.tunnelName = tunnelName
    self.publicHostname = publicHostname
    self.gatewayProfile = gatewayProfile
    self.localPort = localPort
    self.metricsPort = metricsPort
    self.cloudflaredPath = cloudflaredPath
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case tunnelName = "tunnel_name"
    case publicHostname = "public_hostname"
    case gatewayProfile = "gateway_profile"
    case localPort = "local_port"
    case metricsPort = "metrics_port"
    case cloudflaredPath = "cloudflared_path"
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    tunnelName = try container.decode(String.self, forKey: .tunnelName)
    publicHostname = try container.decode(String.self, forKey: .publicHostname)
    gatewayProfile =
      try container.decodeIfPresent(GatewayProfileID.self, forKey: .gatewayProfile)
      ?? .cloudflareObserve
    localPort = try container.decodeIfPresent(Int.self, forKey: .localPort) ?? 8_765
    metricsPort = try container.decodeIfPresent(Int.self, forKey: .metricsPort) ?? 20_241
    cloudflaredPath = try container.decodeIfPresent(String.self, forKey: .cloudflaredPath)
  }

  fileprivate func validate() throws {
    try validateConfigIdentifier(id, label: "transports.cloudflare.id")
    guard !tunnelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !tunnelName.contains("\0")
    else {
      throw ConfigurationError.invalid("transports.cloudflare.tunnel_name must not be empty.")
    }
    guard let url = URL(string: "https://\(publicHostname)"), url.host == publicHostname,
      publicHostname.contains("."), !publicHostname.contains("/"), !publicHostname.contains(":")
    else {
      throw ConfigurationError.invalid("transports.cloudflare.public_hostname is invalid.")
    }
    guard gatewayProfile != .localAdmin else {
      throw ConfigurationError.invalid("Cloudflare transport cannot use local-admin.")
    }
    guard (1...65_535).contains(localPort), (1...65_535).contains(metricsPort),
      localPort != metricsPort
    else {
      throw ConfigurationError.invalid("Cloudflare origin and metrics ports are invalid.")
    }
    try validateOptionalAbsolutePath(
      cloudflaredPath,
      label: "transports.cloudflare.cloudflared_path"
    )
  }
}

private func validateOptionalAbsolutePath(_ value: String?, label: String) throws {
  guard let value else { return }
  guard value.hasPrefix("/"), !value.contains("\0") else {
    throw ConfigurationError.invalid("\(label) must be an absolute path when set.")
  }
}

package struct ServerConfig: Codable, Equatable, Sendable {
  package var name: String
  package var http: HTTPServerConfig

  package init(
    name: String = "computer-mcp",
    http: HTTPServerConfig = HTTPServerConfig()
  ) {
    self.name = name
    self.http = http
  }

  private enum CodingKeys: String, CodingKey {
    case name
    case http
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "computer-mcp"
    self.http =
      try container.decodeIfPresent(HTTPServerConfig.self, forKey: .http)
      ?? HTTPServerConfig()
  }

  fileprivate func validate() throws {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ConfigurationError.invalid("server.name must not be empty.")
    }
    try http.validate()
  }
}

package struct HTTPServerConfig: Codable, Equatable, Sendable {
  package var host: String
  package var port: Int
  package var path: String
  package var healthPath: String
  package var publicBaseURL: String?
  package var accessTokenEnv: String?
  package var allowedOrigins: [String]

  package init(
    host: String = "127.0.0.1",
    port: Int = 8765,
    path: String = "/mcp",
    healthPath: String = "/health",
    publicBaseURL: String? = nil,
    accessTokenEnv: String? = nil,
    allowedOrigins: [String] = []
  ) {
    self.host = host
    self.port = port
    self.path = path
    self.healthPath = healthPath
    self.publicBaseURL = publicBaseURL
    self.accessTokenEnv = accessTokenEnv
    self.allowedOrigins = allowedOrigins
  }

  private enum CodingKeys: String, CodingKey {
    case host
    case port
    case path
    case healthPath = "health_path"
    case publicBaseURL = "public_base_url"
    case accessTokenEnv = "access_token_env"
    case allowedOrigins = "allowed_origins"
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.host = try container.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
    self.port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 8765
    self.path = try container.decodeIfPresent(String.self, forKey: .path) ?? "/mcp"
    self.healthPath = try container.decodeIfPresent(String.self, forKey: .healthPath) ?? "/health"
    self.publicBaseURL = try container.decodeIfPresent(String.self, forKey: .publicBaseURL)
    self.accessTokenEnv = try container.decodeIfPresent(String.self, forKey: .accessTokenEnv)
    self.allowedOrigins =
      try container.decodeIfPresent([String].self, forKey: .allowedOrigins) ?? []
  }

  fileprivate func validate() throws {
    guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ConfigurationError.invalid("server.http.host must not be empty.")
    }
    guard port > 0 && port <= 65_535 else {
      throw ConfigurationError.invalid("server.http.port must be between 1 and 65535.")
    }
    try validateHTTPPath(path, label: "server.http.path")
    try validateHTTPPath(healthPath, label: "server.http.health_path")
    if let publicBaseURL {
      guard let url = URL(string: publicBaseURL), url.scheme == "https" || url.isLoopbackHTTP else {
        throw ConfigurationError.invalid(
          "server.http.public_base_url must be https or loopback http.")
      }
      guard (url.path.isEmpty || url.path == "/") && url.query == nil && url.fragment == nil else {
        throw ConfigurationError.invalid(
          "server.http.public_base_url must be an origin without path, query, or fragment.")
      }
    }
    if let accessTokenEnv {
      try validateEnvName(accessTokenEnv, label: "server.http.access_token_env")
    }
    for origin in allowedOrigins {
      guard URL(string: origin) != nil else {
        throw ConfigurationError.invalid("server.http.allowed_origins contains invalid URL.")
      }
    }
  }
}

private func validateHTTPPath(_ path: String, label: String) throws {
  guard path.hasPrefix("/"), !path.contains("?"), !path.contains("#") else {
    throw ConfigurationError.invalid("\(label) must be an absolute HTTP path.")
  }
}

private func validateEnvName(_ name: String, label: String) throws {
  let allowed = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_")
  guard !name.isEmpty && name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
    throw ConfigurationError.invalid("\(label) must be a valid environment variable name.")
  }
}

extension URL {
  fileprivate var isLoopbackHTTP: Bool {
    guard scheme == "http", let host else {
      return false
    }
    return host == "127.0.0.1" || host == "localhost" || host == "::1"
  }
}

package struct RuntimeBindingConfig: Codable, Equatable, Sendable {
  package var caller: GatewayCallerKind
  package var profileID: GatewayProfileID
  package var defaultWorkspaceID: String?

  package init(
    caller: GatewayCallerKind = .localMCP,
    profileID: GatewayProfileID = .localAdmin,
    defaultWorkspaceID: String? = nil
  ) {
    self.caller = caller
    self.profileID = profileID
    self.defaultWorkspaceID = defaultWorkspaceID
  }

  private enum CodingKeys: String, CodingKey {
    case caller
    case profileID = "profile"
    case defaultWorkspaceID = "workspace_id"
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    caller =
      try container.decodeIfPresent(GatewayCallerKind.self, forKey: .caller) ?? .localMCP
    profileID =
      try container.decodeIfPresent(GatewayProfileID.self, forKey: .profileID) ?? .localAdmin
    defaultWorkspaceID = try container.decodeIfPresent(String.self, forKey: .defaultWorkspaceID)
  }

  fileprivate func validate() throws {
    if let defaultWorkspaceID,
      defaultWorkspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      throw ConfigurationError.invalid("runtime.workspace_id must not be empty when set.")
    }
  }
}

package struct PolicyConfig: Codable, Equatable, Sendable {
  package var defaultTimeoutMs: Int
  package var maxOutputBytes: Int
  package var shellEnabled: Bool
  package var shellExecutable: String
  package var maxShellSessions: Int
  package var maxShellInputBytes: Int
  package var shellTerminationGraceMs: Int

  package init(
    defaultTimeoutMs: Int = 30_000,
    maxOutputBytes: Int = 1_048_576,
    shellEnabled: Bool = false,
    shellExecutable: String = "/bin/zsh",
    maxShellSessions: Int = 16,
    maxShellInputBytes: Int = 1_048_576,
    shellTerminationGraceMs: Int = 2_000
  ) {
    self.defaultTimeoutMs = defaultTimeoutMs
    self.maxOutputBytes = maxOutputBytes
    self.shellEnabled = shellEnabled
    self.shellExecutable = shellExecutable
    self.maxShellSessions = maxShellSessions
    self.maxShellInputBytes = maxShellInputBytes
    self.shellTerminationGraceMs = shellTerminationGraceMs
  }

  private enum CodingKeys: String, CodingKey {
    case defaultTimeoutMs = "default_timeout_ms"
    case maxOutputBytes = "max_output_bytes"
    case shellEnabled = "shell_enabled"
    case shellExecutable = "shell_executable"
    case maxShellSessions = "max_shell_sessions"
    case maxShellInputBytes = "max_shell_input_bytes"
    case shellTerminationGraceMs = "shell_termination_grace_ms"
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    defaultTimeoutMs =
      try container.decodeIfPresent(Int.self, forKey: .defaultTimeoutMs) ?? 30_000
    maxOutputBytes =
      try container.decodeIfPresent(Int.self, forKey: .maxOutputBytes) ?? 1_048_576
    shellEnabled = try container.decodeIfPresent(Bool.self, forKey: .shellEnabled) ?? false
    shellExecutable =
      try container.decodeIfPresent(String.self, forKey: .shellExecutable) ?? "/bin/zsh"
    maxShellSessions =
      try container.decodeIfPresent(Int.self, forKey: .maxShellSessions) ?? 16
    maxShellInputBytes =
      try container.decodeIfPresent(Int.self, forKey: .maxShellInputBytes) ?? 1_048_576
    shellTerminationGraceMs =
      try container.decodeIfPresent(Int.self, forKey: .shellTerminationGraceMs) ?? 2_000
  }

  fileprivate func validate() throws {
    guard defaultTimeoutMs > 0 else {
      throw ConfigurationError.invalid("policy.default_timeout_ms must be greater than zero.")
    }
    guard maxOutputBytes > 0 else {
      throw ConfigurationError.invalid("policy.max_output_bytes must be greater than zero.")
    }
    guard shellExecutable.hasPrefix("/"), !shellExecutable.contains("\0") else {
      throw ConfigurationError.invalid("policy.shell_executable must be an absolute path.")
    }
    guard maxShellSessions > 0 && maxShellSessions <= 256 else {
      throw ConfigurationError.invalid(
        "policy.max_shell_sessions must be between 1 and 256."
      )
    }
    guard maxShellInputBytes > 0 && maxShellInputBytes <= 67_108_864 else {
      throw ConfigurationError.invalid(
        "policy.max_shell_input_bytes must be between 1 and 67108864."
      )
    }
    guard shellTerminationGraceMs >= 0 && shellTerminationGraceMs <= 60_000 else {
      throw ConfigurationError.invalid(
        "policy.shell_termination_grace_ms must be between 0 and 60000."
      )
    }
  }
}

package struct WorkspaceManifestConfig: Codable, Equatable, Sendable {
  package var id: String
  package var displayName: String
  package var path: String?

  package init(id: String, displayName: String? = nil, path: String? = nil) {
    self.id = id
    self.displayName = displayName ?? id
    self.path = path
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case displayName = "display_name"
    case path
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? id
    path = try container.decodeIfPresent(String.self, forKey: .path)
  }

  fileprivate func resolved(base: URL) -> WorkspaceManifestConfig {
    guard let path else {
      return self
    }
    let resolvedPath: String
    if path.hasPrefix("/") {
      resolvedPath = URL(fileURLWithPath: path).standardizedFileURL.path
    } else {
      resolvedPath = base.appendingPathComponent(path).standardizedFileURL.path
    }
    return WorkspaceManifestConfig(id: id, displayName: displayName, path: resolvedPath)
  }

  fileprivate func validate() throws {
    try validateConfigIdentifier(id, label: "workspaces.id")
    guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ConfigurationError.invalid("workspaces.display_name must not be empty.")
    }
    if let path {
      guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ConfigurationError.invalid("workspaces.path must not be empty when set.")
      }
      guard path.hasPrefix("/") else {
        throw ConfigurationError.invalid(
          "Resolved workspaces.path must be absolute; load configuration through GatewayConfiguration.load."
        )
      }
    }
  }

  package var registeredWorkspace: RegisteredWorkspace? {
    guard let path else {
      return nil
    }
    return RegisteredWorkspace(id: id, displayName: displayName, rootPath: path)
  }
}

package struct ProfileGrantConfig: Codable, Equatable, Sendable {
  package var id: GatewayProfileID
  package var capabilities: [String]
  package var workspaces: [String]
  package var allowedCallers: [GatewayCallerKind]
  package var fullShellEnabled: Bool

  package init(
    id: GatewayProfileID,
    capabilities: [String] = [],
    workspaces: [String] = [],
    allowedCallers: [GatewayCallerKind]? = nil,
    fullShellEnabled: Bool = false
  ) {
    self.id = id
    self.capabilities = capabilities
    self.workspaces = workspaces
    self.allowedCallers = allowedCallers ?? Self.defaultAllowedCallers(for: id)
    self.fullShellEnabled = fullShellEnabled
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case capabilities
    case workspaces
    case allowedCallers = "allowed_callers"
    case fullShellEnabled = "full_shell_enabled"
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(GatewayProfileID.self, forKey: .id)
    capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
    workspaces = try container.decodeIfPresent([String].self, forKey: .workspaces) ?? []
    if let configured = try container.decodeIfPresent(
      [GatewayCallerKind].self,
      forKey: .allowedCallers
    ) {
      allowedCallers = configured
    } else {
      allowedCallers = Self.defaultAllowedCallers(for: id)
    }
    fullShellEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .fullShellEnabled) ?? false
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(capabilities, forKey: .capabilities)
    try container.encode(workspaces, forKey: .workspaces)
    try container.encode(allowedCallers, forKey: .allowedCallers)
    try container.encode(fullShellEnabled, forKey: .fullShellEnabled)
  }

  fileprivate func validate(knownWorkspaceIDs: Set<String>) throws {
    var capabilityIDs = Set<String>()
    for capability in capabilities {
      if capability != "*" {
        try validateGatewayToolID(capability, label: "profiles.capabilities")
      }
      guard capabilityIDs.insert(capability).inserted else {
        throw ConfigurationError.invalid(
          "Profile '\(id.rawValue)' contains duplicate capability '\(capability)'."
        )
      }
    }
    var workspaceIDs = Set<String>()
    for workspaceID in workspaces {
      try validateConfigIdentifier(workspaceID, label: "profiles.workspaces")
      guard workspaceIDs.insert(workspaceID).inserted else {
        throw ConfigurationError.invalid(
          "Profile '\(id.rawValue)' contains duplicate workspace '\(workspaceID)'."
        )
      }
      guard knownWorkspaceIDs.isEmpty || knownWorkspaceIDs.contains(workspaceID) else {
        throw ConfigurationError.invalid(
          "Profile '\(id.rawValue)' references unknown workspace '\(workspaceID)'."
        )
      }
    }
    do {
      try grant.validate()
    } catch {
      throw ConfigurationError.invalid(error.localizedDescription)
    }
  }

  package var grant: ProfileGrant {
    ProfileGrant(
      id: id,
      capabilityIDs: Set(capabilities),
      workspaceIDs: Set(workspaces),
      allowedCallers: Set(allowedCallers),
      fullShellEnabled: fullShellEnabled
    )
  }

  private static func defaultAllowedCallers(for id: GatewayProfileID) -> [GatewayCallerKind] {
    if id == .chatGPTObserve || id == .chatGPTOperate { return [.secureTunnel] }
    if id == .cloudflareObserve || id == .cloudflareOperate { return [.cloudflareTunnel] }
    if id == .localAdmin { return [.localApp, .localCLI, .localMCP] }
    return []
  }
}

func validateConfigIdentifier(
  _ value: String,
  label: String,
  allowDots: Bool = false
) throws {
  guard !value.isEmpty, value.utf8.count <= 128 else {
    throw ConfigurationError.invalid("\(label) must contain between 1 and 128 UTF-8 bytes.")
  }
  let allowed = CharacterSet(
    charactersIn:
      allowDots
      ? "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-*"
      : "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
  )
  guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
    let suffix = allowDots ? ", '.', or '*'" : ""
    throw ConfigurationError.invalid(
      "\(label) may only contain ASCII letters, digits, '_', '-'\(suffix)."
    )
  }
}

private func validateGatewayToolID(_ value: String, label: String) throws {
  let segments = value.split(separator: ".", omittingEmptySubsequences: false)
  let canonical =
    segments.count >= 2
    && segments.allSatisfy { segment in
      guard let first = segment.utf8.first, (97...122).contains(first),
        let last = segment.utf8.last, last != 95
      else {
        return false
      }
      var previousWasUnderscore = false
      for byte in segment.utf8 {
        let isUnderscore = byte == 95
        guard (97...122).contains(byte) || (48...57).contains(byte) || isUnderscore,
          !(isUnderscore && previousWasUnderscore)
        else {
          return false
        }
        previousWasUnderscore = isUnderscore
      }
      return true
    }
  guard canonical, value.utf8.count <= 128 else {
    throw ConfigurationError.invalid(
      "\(label) must use a lowercase namespace and snake_case action segments."
    )
  }
}

package struct SkillsConfig: Codable, Equatable, Sendable {
  package var enabled: Bool
  package var roots: [SkillRootConfig]
  package var maxBytesPerSkill: Int

  package init(
    enabled: Bool = false,
    roots: [SkillRootConfig] = [],
    maxBytesPerSkill: Int = 1_048_576
  ) {
    self.enabled = enabled
    self.roots = roots
    self.maxBytesPerSkill = maxBytesPerSkill
  }

  private enum CodingKeys: String, CodingKey {
    case enabled
    case roots
    case maxBytesPerSkill = "max_bytes_per_skill"
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    roots = try container.decodeIfPresent([SkillRootConfig].self, forKey: .roots) ?? []
    maxBytesPerSkill =
      try container.decodeIfPresent(Int.self, forKey: .maxBytesPerSkill) ?? 1_048_576
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(enabled, forKey: .enabled)
    try container.encode(roots, forKey: .roots)
    try container.encode(maxBytesPerSkill, forKey: .maxBytesPerSkill)
  }

  fileprivate func resolved(base: URL) -> SkillsConfig {
    SkillsConfig(
      enabled: enabled,
      roots: roots.map { $0.resolved(base: base) },
      maxBytesPerSkill: maxBytesPerSkill
    )
  }

  fileprivate func validate() throws {
    guard maxBytesPerSkill > 0 && maxBytesPerSkill <= 20_971_520 else {
      throw ConfigurationError.invalid(
        "skills.max_bytes_per_skill must be between 1 and 20971520.")
    }
    if enabled && roots.isEmpty {
      throw ConfigurationError.invalid("skills.roots must not be empty when skills are enabled.")
    }
    try validateUniqueSkillRootIDs(roots.map(\.id))
    for root in roots {
      try root.validate()
    }
  }

  private func validateUniqueSkillRootIDs(_ ids: [String]) throws {
    var seen = Set<String>()
    for id in ids {
      guard seen.insert(id).inserted else {
        throw ConfigurationError.invalid("Duplicate skill root id: \(id)")
      }
    }
  }
}

package struct SkillRootConfig: Codable, Equatable, Sendable {
  package var id: String
  package var path: String
  package var description: String?

  package init(id: String, path: String, description: String? = nil) {
    self.id = id
    self.path = path
    self.description = description
  }

  fileprivate func resolved(base: URL) -> SkillRootConfig {
    let resolvedPath: String
    if path.hasPrefix("/") {
      resolvedPath = URL(fileURLWithPath: path).standardizedFileURL.path
    } else {
      resolvedPath = base.appendingPathComponent(path).standardizedFileURL.path
    }
    return SkillRootConfig(id: id, path: resolvedPath, description: description)
  }

  fileprivate func validate() throws {
    guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ConfigurationError.invalid("skills.roots id must not be empty.")
    }
    guard
      id.unicodeScalars.allSatisfy({ scalar in
        let value = scalar.value
        return (value >= 48 && value <= 57)
          || (value >= 65 && value <= 90)
          || (value >= 97 && value <= 122)
          || value == 95 || value == 45
      })
    else {
      throw ConfigurationError.invalid(
        "skills.roots id may only contain ASCII letters, digits, '_' or '-'.")
    }
    guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ConfigurationError.invalid("skills.roots path must not be empty.")
    }
    if let description, description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw ConfigurationError.invalid("skills.roots description must not be empty when set.")
    }
  }
}

package struct CLISectionConfig: Codable, Equatable, Sendable {
  package var commands: [CLICommandConfig]

  package init(commands: [CLICommandConfig] = []) {
    self.commands = commands
  }
}

package struct CLICommandConfig: Codable, Equatable, Sendable {
  package var id: String
  package var executable: String
  package var description: String?
  package var cwd: String?
  package var env: [String: String]
  package var allowAnyArgs: Bool
  package var risk: String?
  package var discovery: [String]
  package var defaultTimeoutMs: Int?
  package var interface: CLIInterfaceConfig?

  package init(
    id: String,
    executable: String,
    description: String? = nil,
    cwd: String? = nil,
    env: [String: String] = [:],
    allowAnyArgs: Bool = true,
    risk: String? = nil,
    discovery: [String] = [],
    defaultTimeoutMs: Int? = nil,
    interface: CLIInterfaceConfig? = nil
  ) {
    self.id = id
    self.executable = executable
    self.description = description
    self.cwd = cwd
    self.env = env
    self.allowAnyArgs = allowAnyArgs
    self.risk = risk
    self.discovery = discovery
    self.defaultTimeoutMs = defaultTimeoutMs
    self.interface = interface
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case executable
    case description
    case cwd
    case env
    case allowAnyArgs = "allow_any_args"
    case risk
    case discovery
    case defaultTimeoutMs = "default_timeout_ms"
    case interface
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.executable = try container.decode(String.self, forKey: .executable)
    self.description = try container.decodeIfPresent(String.self, forKey: .description)
    self.cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
    self.env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
    self.allowAnyArgs = try container.decodeIfPresent(Bool.self, forKey: .allowAnyArgs) ?? true
    self.risk = try container.decodeIfPresent(String.self, forKey: .risk)
    self.discovery = try container.decodeIfPresent([String].self, forKey: .discovery) ?? []
    self.defaultTimeoutMs = try container.decodeIfPresent(Int.self, forKey: .defaultTimeoutMs)
    self.interface = try container.decodeIfPresent(CLIInterfaceConfig.self, forKey: .interface)
  }

  fileprivate func validate() throws {
    guard !id.isEmpty else {
      throw ConfigurationError.invalid("CLI command id must not be empty.")
    }
    guard !executable.isEmpty else {
      throw ConfigurationError.invalid("CLI command '\(id)' executable must not be empty.")
    }
    if let defaultTimeoutMs {
      guard defaultTimeoutMs > 0 else {
        throw ConfigurationError.invalid(
          "CLI command '\(id)' default_timeout_ms must be greater than zero.")
      }
    }
    try interface?.validate(commandID: id)
  }

  package func resolvedWorkingDirectory(base: URL) -> URL? {
    guard let cwd, !cwd.isEmpty else {
      return base
    }
    if cwd == "workspace" {
      return base
    }
    if cwd.hasPrefix("/") {
      return URL(fileURLWithPath: cwd)
    }
    return base.appendingPathComponent(cwd)
  }
}

package struct CLIInterfaceConfig: Codable, Equatable, Sendable {
  package var pathStyle: CLIPathStyle
  package var flagStyle: CLIFlagStyle
  package var flagCase: CLIFlagCase
  package var valueStyle: CLIValueStyle
  package var formatFlag: String?
  package var defaultFormat: String?
  package var dryRunFlag: String?

  package init(
    pathStyle: CLIPathStyle = .argv,
    flagStyle: CLIFlagStyle = .longFlags,
    flagCase: CLIFlagCase = .kebab,
    valueStyle: CLIValueStyle = .separate,
    formatFlag: String? = nil,
    defaultFormat: String? = nil,
    dryRunFlag: String? = nil
  ) {
    self.pathStyle = pathStyle
    self.flagStyle = flagStyle
    self.flagCase = flagCase
    self.valueStyle = valueStyle
    self.formatFlag = formatFlag
    self.defaultFormat = defaultFormat
    self.dryRunFlag = dryRunFlag
  }

  private enum CodingKeys: String, CodingKey {
    case pathStyle = "path_style"
    case flagStyle = "flag_style"
    case flagCase = "flag_case"
    case valueStyle = "value_style"
    case formatFlag = "format_flag"
    case defaultFormat = "default_format"
    case dryRunFlag = "dry_run_flag"
  }

  fileprivate func validate(commandID: String) throws {
    for (name, value) in [
      ("format_flag", formatFlag),
      ("default_format", defaultFormat),
      ("dry_run_flag", dryRunFlag),
    ] {
      if let value, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw ConfigurationError.invalid(
          "CLI command '\(commandID)' interface.\(name) must not be empty when set.")
      }
    }
  }

  package var json: JSONValue {
    var object: [String: JSONValue] = [
      "path_style": .string(pathStyle.rawValue),
      "flag_style": .string(flagStyle.rawValue),
      "flag_case": .string(flagCase.rawValue),
      "value_style": .string(valueStyle.rawValue),
    ]
    if let formatFlag {
      object["format_flag"] = .string(formatFlag)
    }
    if let defaultFormat {
      object["default_format"] = .string(defaultFormat)
    }
    if let dryRunFlag {
      object["dry_run_flag"] = .string(dryRunFlag)
    }
    return .object(object)
  }
}

package enum CLIPathStyle: String, Codable, Equatable, Sendable {
  case argv
}

package enum CLIFlagStyle: String, Codable, Equatable, Sendable {
  case longFlags = "long_flags"
}

package enum CLIFlagCase: String, Codable, Equatable, Sendable {
  case kebab
}

package enum CLIValueStyle: String, Codable, Equatable, Sendable {
  case separate
}

package struct MCPSectionConfig: Codable, Equatable, Sendable {
  package var servers: [MCPServerConfig]

  package init(servers: [MCPServerConfig] = []) {
    self.servers = servers
  }
}

package struct MCPServerConfig: Codable, Equatable, Sendable {
  package var id: String
  package var transport: MCPTransport
  package var url: String?
  package var command: String?
  package var args: [String]
  package var env: [String: String]
  package var cwd: String?
  package var exposure: MCPExposure
  package var prefix: String?
  package var capabilities: [String]
  package var allowedTools: [String]
  package var allowAnyTool: Bool
  package var startupTimeoutMs: Int?
  package var requestTimeoutMs: Int?

  package init(
    id: String,
    transport: MCPTransport,
    url: String? = nil,
    command: String? = nil,
    args: [String] = [],
    env: [String: String] = [:],
    cwd: String? = nil,
    exposure: MCPExposure = .gateway,
    prefix: String? = nil,
    capabilities: [String] = ["tools"],
    allowedTools: [String] = [],
    allowAnyTool: Bool = false,
    startupTimeoutMs: Int? = nil,
    requestTimeoutMs: Int? = nil
  ) {
    self.id = id
    self.transport = transport
    self.url = url
    self.command = command
    self.args = args
    self.env = env
    self.cwd = cwd
    self.exposure = exposure
    self.prefix = prefix
    self.capabilities = capabilities
    self.allowedTools = allowedTools
    self.allowAnyTool = allowAnyTool
    self.startupTimeoutMs = startupTimeoutMs
    self.requestTimeoutMs = requestTimeoutMs
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case transport
    case url
    case command
    case args
    case env
    case cwd
    case exposure
    case prefix
    case capabilities
    case allowedTools = "allowed_tools"
    case allowAnyTool = "allow_any_tool"
    case startupTimeoutMs = "startup_timeout_ms"
    case requestTimeoutMs = "request_timeout_ms"
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.transport = try container.decode(MCPTransport.self, forKey: .transport)
    self.url = try container.decodeIfPresent(String.self, forKey: .url)
    self.command = try container.decodeIfPresent(String.self, forKey: .command)
    self.args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
    self.env = try container.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
    self.cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
    self.exposure = try container.decodeIfPresent(MCPExposure.self, forKey: .exposure) ?? .gateway
    self.prefix = try container.decodeIfPresent(String.self, forKey: .prefix)
    self.capabilities =
      try container.decodeIfPresent([String].self, forKey: .capabilities)
      ?? ["tools"]
    self.allowedTools =
      try container.decodeIfPresent([String].self, forKey: .allowedTools)
      ?? []
    self.allowAnyTool =
      try container.decodeIfPresent(Bool.self, forKey: .allowAnyTool)
      ?? false
    self.startupTimeoutMs = try container.decodeIfPresent(Int.self, forKey: .startupTimeoutMs)
    self.requestTimeoutMs = try container.decodeIfPresent(Int.self, forKey: .requestTimeoutMs)
  }

  fileprivate func validate() throws {
    switch transport {
    case .stdio:
      guard let command, !command.isEmpty else {
        throw ConfigurationError.invalid("MCP server '\(id)' stdio transport requires command.")
      }
    case .streamableHTTP, .http, .sse:
      guard let url, URL(string: url) != nil else {
        throw ConfigurationError.invalid("MCP server '\(id)' HTTP transport requires valid url.")
      }
    }

    for value in [startupTimeoutMs, requestTimeoutMs].compactMap({ $0 }) {
      guard value > 0 else {
        throw ConfigurationError.invalid("MCP server '\(id)' timeout values must be positive.")
      }
    }
    guard Set(allowedTools).count == allowedTools.count else {
      throw ConfigurationError.invalid("MCP server '\(id)' allowed_tools contains duplicates.")
    }
    for name in allowedTools {
      guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ConfigurationError.invalid(
          "MCP server '\(id)' allowed_tools entries must not be empty."
        )
      }
    }
  }

  package func permitsTool(_ name: String) -> Bool {
    allowAnyTool || allowedTools.contains(name)
  }
}

package enum MCPTransport: String, Codable, Equatable, Sendable {
  case stdio
  case streamableHTTP = "streamable_http"
  case http
  case sse
}

package enum MCPExposure: String, Codable, Equatable, Sendable {
  case gateway
  case reexport

  package var includesReexport: Bool {
    self == .reexport
  }
}

package struct ToolConfig: Codable, Equatable, Sendable {
  package var name: String
  package var description: String?
  package var adapter: ToolAdapter
  package var source: String
  package var tool: String?
  package var risk: String?
  package var inputSchema: String?
  package var defaultTimeoutMs: Int?

  package init(
    name: String,
    description: String? = nil,
    adapter: ToolAdapter,
    source: String,
    tool: String? = nil,
    risk: String? = nil,
    inputSchema: String? = nil,
    defaultTimeoutMs: Int? = nil
  ) {
    self.name = name
    self.description = description
    self.adapter = adapter
    self.source = source
    self.tool = tool
    self.risk = risk
    self.inputSchema = inputSchema
    self.defaultTimeoutMs = defaultTimeoutMs
  }

  private enum CodingKeys: String, CodingKey {
    case name
    case description
    case adapter
    case source
    case tool
    case risk
    case inputSchema = "input_schema"
    case defaultTimeoutMs = "default_timeout_ms"
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.name = try container.decode(String.self, forKey: .name)
    self.description = try container.decodeIfPresent(String.self, forKey: .description)
    self.adapter = try container.decode(ToolAdapter.self, forKey: .adapter)
    self.source = try container.decode(String.self, forKey: .source)
    self.tool = try container.decodeIfPresent(String.self, forKey: .tool)
    self.risk = try container.decodeIfPresent(String.self, forKey: .risk)
    self.inputSchema = try container.decodeIfPresent(String.self, forKey: .inputSchema)
    self.defaultTimeoutMs = try container.decodeIfPresent(Int.self, forKey: .defaultTimeoutMs)
  }

  fileprivate func validate() throws {
    guard !name.isEmpty else {
      throw ConfigurationError.invalid("Tool name must not be empty.")
    }
    guard !source.isEmpty else {
      throw ConfigurationError.invalid("Configured tool '\(name)' source must not be empty.")
    }

    switch adapter {
    case .mcp:
      guard let tool, !tool.isEmpty else {
        throw ConfigurationError.invalid("MCP-backed tool '\(name)' requires tool.")
      }
    }

    if let defaultTimeoutMs {
      guard defaultTimeoutMs > 0 else {
        throw ConfigurationError.invalid(
          "Configured tool '\(name)' default_timeout_ms must be greater than zero.")
      }
    }

    _ = try inputSchemaValue()
  }

  package func inputSchemaValue() throws -> JSONValue {
    guard let inputSchema else {
      return .object([
        "type": .string("object"),
        "properties": .object([:]),
        "additionalProperties": .bool(false),
      ])
    }

    guard let data = inputSchema.data(using: .utf8) else {
      throw ConfigurationError.invalid("Configured tool '\(name)' input_schema is not valid UTF-8.")
    }

    do {
      let schema = try JSONDecoder().decode(JSONValue.self, from: data)
      guard schema.objectValue != nil else {
        throw ConfigurationError.invalid(
          "Configured tool '\(name)' input_schema must be a JSON object.")
      }
      return schema
    } catch let error as ConfigurationError {
      throw error
    } catch {
      throw ConfigurationError.invalid(
        "Configured tool '\(name)' input_schema is not valid JSON: \(error.localizedDescription)")
    }
  }
}

package enum ToolAdapter: String, Codable, Equatable, Sendable {
  case mcp
}

package struct CodexConfig: Codable, Equatable, Sendable {
  package var enabled: Bool
  package var executable: String
  package var appServerEnabled: Bool
  package var execEnabled: Bool
  package var mcpEnabled: Bool
  package var experimentalAPI: Bool
  package var appServerRequestTimeoutSeconds: Int
  package var sandbox: CodexSandboxMode
  package var approvalPolicy: CodexApprovalPolicy
  package var maxSessions: Int
  package var maxEventsPerSession: Int

  package init(
    enabled: Bool = false,
    executable: String = "codex",
    appServerEnabled: Bool = true,
    execEnabled: Bool = true,
    mcpEnabled: Bool = true,
    experimentalAPI: Bool = true,
    appServerRequestTimeoutSeconds: Int = 30,
    sandbox: CodexSandboxMode = .workspaceWrite,
    approvalPolicy: CodexApprovalPolicy = .never,
    maxSessions: Int = 8,
    maxEventsPerSession: Int = 1_024
  ) {
    self.enabled = enabled
    self.executable = executable
    self.appServerEnabled = appServerEnabled
    self.execEnabled = execEnabled
    self.mcpEnabled = mcpEnabled
    self.experimentalAPI = experimentalAPI
    self.appServerRequestTimeoutSeconds = appServerRequestTimeoutSeconds
    self.sandbox = sandbox
    self.approvalPolicy = approvalPolicy
    self.maxSessions = maxSessions
    self.maxEventsPerSession = maxEventsPerSession
  }

  private enum CodingKeys: String, CodingKey {
    case enabled
    case executable
    case appServerEnabled = "app_server_enabled"
    case execEnabled = "exec_enabled"
    case mcpEnabled = "mcp_enabled"
    case experimentalAPI = "experimental_api"
    case appServerRequestTimeoutSeconds = "app_server_request_timeout_seconds"
    case sandbox
    case approvalPolicy = "approval_policy"
    case maxSessions = "max_sessions"
    case maxEventsPerSession = "max_events_per_session"
  }

  package init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    executable = try container.decodeIfPresent(String.self, forKey: .executable) ?? "codex"
    appServerEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .appServerEnabled) ?? true
    execEnabled = try container.decodeIfPresent(Bool.self, forKey: .execEnabled) ?? true
    mcpEnabled = try container.decodeIfPresent(Bool.self, forKey: .mcpEnabled) ?? true
    experimentalAPI =
      try container.decodeIfPresent(Bool.self, forKey: .experimentalAPI) ?? true
    appServerRequestTimeoutSeconds =
      try container.decodeIfPresent(Int.self, forKey: .appServerRequestTimeoutSeconds) ?? 30
    sandbox =
      try container.decodeIfPresent(CodexSandboxMode.self, forKey: .sandbox)
      ?? .workspaceWrite
    approvalPolicy =
      try container.decodeIfPresent(CodexApprovalPolicy.self, forKey: .approvalPolicy)
      ?? .never
    maxSessions = try container.decodeIfPresent(Int.self, forKey: .maxSessions) ?? 8
    maxEventsPerSession =
      try container.decodeIfPresent(Int.self, forKey: .maxEventsPerSession) ?? 1_024
  }

  fileprivate func validate() throws {
    guard !executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ConfigurationError.invalid("codex.executable must not be empty.")
    }
    guard maxSessions > 0 && maxSessions <= 64 else {
      throw ConfigurationError.invalid("codex.max_sessions must be between 1 and 64.")
    }
    guard appServerRequestTimeoutSeconds >= 1 && appServerRequestTimeoutSeconds <= 300 else {
      throw ConfigurationError.invalid(
        "codex.app_server_request_timeout_seconds must be between 1 and 300."
      )
    }
    guard maxEventsPerSession >= 64 && maxEventsPerSession <= 16_384 else {
      throw ConfigurationError.invalid(
        "codex.max_events_per_session must be between 64 and 16384."
      )
    }
    if enabled && !appServerEnabled && !execEnabled && !mcpEnabled {
      throw ConfigurationError.invalid(
        "At least one Codex path must be enabled when [codex].enabled is true."
      )
    }
    guard sandbox != .dangerFullAccess else {
      throw ConfigurationError.invalid(
        "codex.sandbox cannot be danger-full-access."
      )
    }
  }

  package var executableURL: URL? {
    executable.contains("/") ? URL(fileURLWithPath: executable).standardizedFileURL : nil
  }
}

package enum CodexSandboxMode: String, Codable, Equatable, Sendable {
  case readOnly = "read-only"
  case workspaceWrite = "workspace-write"
  case dangerFullAccess = "danger-full-access"
}

package enum CodexApprovalPolicy: String, Codable, Equatable, Sendable {
  case untrusted
  case onFailure = "on-failure"
  case onRequest = "on-request"
  case never
}

package struct BuiltinConfig: Codable, Equatable, Sendable {
  package var enabled: [String]

  package init(enabled: [String] = []) {
    self.enabled = enabled
  }
}

package enum ConfigurationError: Error, LocalizedError, Equatable {
  case invalid(String)

  package var errorDescription: String? {
    switch self {
    case .invalid(let message):
      return message
    }
  }
}
