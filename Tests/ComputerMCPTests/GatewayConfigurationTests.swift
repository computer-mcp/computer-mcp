import Foundation
import Testing

@testable import ComputerMCP

@Suite

final class GatewayConfigurationTests {
  @Test
  func testSchemaV1SupportsValidatedCustomProfilesAndCallerSpecificDefaults() throws {
    let custom = try #require(GatewayProfileID(rawValue: "partner-observe"))
    #expect(GatewayProfileID(rawValue: "partner/observe") == nil)
    #expect(GatewayProfileID(rawValue: "") == nil)

    let configuration = try GatewayConfiguration.load(
      text: """
        schema_version = 1

        [runtime]
        caller = "local-cli"
        profile = "partner-observe"

        [[profiles]]
        id = "partner-observe"
        capabilities = ["system.time"]
        allowed_callers = ["local-cli"]

        [[profiles]]
        id = "cloudflare-observe"
        capabilities = ["system.time"]
        """,
      baseURL: URL(fileURLWithPath: "/tmp/computer-mcp-schema-1")
    )

    #expect(configuration.schemaVersion == 1)
    #expect(configuration.profileGrant(for: custom).allowedCallers == [.localCLI])
    #expect(
      configuration.profileGrant(for: .cloudflareObserve).allowedCallers
        == [.cloudflareTunnel]
    )
  }

  @Test
  func testRejectsUnknownProfileField() throws {
    expectThrows(
      try GatewayConfiguration.load(
        text: """
          schema_version = 1

          [[profiles]]
          id = "chatgpt-observe"
          capabilities = ["system.time"]
          obsolete_access = true
          """,
        baseURL: URL(fileURLWithPath: "/tmp/computer-mcp-schema-1")
      )
    ) { error in
      #expect(error.localizedDescription.contains("Unknown configuration field"))
      #expect(error.localizedDescription.contains("obsolete_access"))
    }
  }

  @Test
  func testSchemaV1StoresIndependentTransportDefinitionsWithoutSecrets() throws {
    let configuration = try GatewayConfiguration.load(
      text: """
        schema_version = 1

        [[transports.openai]]
        id = "chatgpt"
        tunnel_client_profile = "computer-mcp"
        tunnel_id = "tunnel_example"
        gateway_profile = "chatgpt-observe"
        tunnel_client_path = "/usr/local/bin/tunnel-client"
        http_proxy = "http://127.0.0.1:6152"
        requires_api_key = true

        [[transports.cloudflare]]
        id = "partner"
        tunnel_name = "computer-mcp-release"
        public_hostname = "mcp.example.com"
        gateway_profile = "cloudflare-observe"
        local_port = 8765
        metrics_port = 20241
        cloudflared_path = "/usr/local/bin/cloudflared"
        """,
      baseURL: URL(fileURLWithPath: "/tmp/computer-mcp-transports")
    )

    #expect(configuration.transports.openAI.map(\.id) == ["chatgpt"])
    #expect(configuration.transports.openAI.first?.requiresAPIKey == true)
    #expect(configuration.transports.openAI.first?.httpProxy == "http://127.0.0.1:6152")
    #expect(configuration.transports.cloudflare.map(\.id) == ["partner"])
    let exported = try configuration.exportedTOML()
    #expect(exported.contains("[[transports.openai]]"))
    #expect(exported.contains("[[transports.cloudflare]]"))
    #expect(exported.contains("http_proxy = \"http://127.0.0.1:6152\""))
    #expect(!exported.contains("token"))
    #expect(!exported.contains("bearer"))
  }

  @Test
  func testOpenAITransportRejectsProxyCredentials() throws {
    expectThrows(
      try GatewayConfiguration.load(
        text: """
          schema_version = 1

          [[transports.openai]]
          id = "chatgpt"
          tunnel_client_profile = "computer-mcp"
          tunnel_id = "tunnel_example"
          gateway_profile = "chatgpt-observe"
          http_proxy = "http://user:secret@127.0.0.1:6152"
          """,
        baseURL: URL(fileURLWithPath: "/tmp/computer-mcp-transports")
      )
    ) { error in
      #expect(error.localizedDescription.contains("without credentials"))
    }
  }

  @Test
  func testTransportDefinitionCannotCrossCallerProfiles() throws {
    expectThrows(
      try GatewayConfiguration.load(
        text: """
          schema_version = 1

          [[transports.cloudflare]]
          id = "invalid"
          tunnel_name = "invalid"
          public_hostname = "mcp.example.com"
          gateway_profile = "chatgpt-observe"
          """,
        baseURL: URL(fileURLWithPath: "/tmp/computer-mcp-transports")
      )
    ) { error in
      #expect(error.localizedDescription.contains("does not allow cloudflare-tunnel"))
    }
  }

  @Test
  func testLoadsValidGatewayConfigurationWithDefaults() throws {
    let path = try writeConfig(
      """
      schema_version = 1

      [server]
      name = "test-gateway"

      [[cli.commands]]
      id = "echo"
      executable = "/bin/echo"

      [cli.commands.interface]
      path_style = "argv"
      flag_style = "long_flags"
      flag_case = "kebab"
      value_style = "separate"
      format_flag = "--format"
      default_format = "json"
      dry_run_flag = "--dry-run"

      [[mcp.servers]]
      id = "local"
      transport = "stdio"
      command = "/bin/cat"

      [[tools]]
      name = "local.sample"
      description = "Call sample downstream MCP tool."
      adapter = "mcp"
      source = "local"
      tool = "sample"
      input_schema = '''
      {
        "type": "object",
        "additionalProperties": true
      }
      '''
      """
    )

    let config = try GatewayConfiguration.load(path: path)

    #expect((config.server.name) == ("test-gateway"))
    #expect((config.policy.defaultTimeoutMs) == (30_000))
    #expect(!(config.policy.shellEnabled))
    #expect((config.cli.commands.first?.id) == ("echo"))
    #expect((config.cli.commands.first?.interface?.formatFlag) == ("--format"))
    #expect((config.mcp.servers.first?.exposure) == (.gateway))
    #expect((config.tools.first?.name) == ("local.sample"))
    #expect(
      (try config.tools.first?.inputSchemaValue().objectValue?["type"]) == (.string("object")))
    #expect(
      (config.workspaceDirectory.standardizedFileURL.path)
        == (URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path))
  }

  @Test
  func testLoadsConfigurationTextRelativeToExplicitBaseURL() throws {
    let base = URL(fileURLWithPath: "/tmp/computer-mcp-config-base", isDirectory: true)
    let configuration = try GatewayConfiguration.load(
      text: """
        schema_version = 1

        [skills]
        enabled = true

        [[skills.roots]]
        id = "local"
        path = "Skills"
        """,
      baseURL: base
    )

    #expect(
      (configuration.workspaceDirectory) == (base.standardizedFileURL))
    #expect(
      (configuration.skills.roots.first?.path)
        == (base.appendingPathComponent("Skills").standardizedFileURL.path))
  }

  @Test
  func testRemoteMCPRequiresReviewedToolAllowlist() throws {
    var remote = GatewayConfiguration(
      runtime: RuntimeBindingConfig(
        caller: .secureTunnel,
        profileID: .chatGPTOperate
      ),
      mcp: MCPSectionConfig(servers: [
        MCPServerConfig(
          id: "unsafe",
          transport: .stdio,
          command: "/bin/cat",
          allowAnyTool: true
        )
      ])
    )

    expectThrows(try remote.validate()) { error in
      #expect(error.localizedDescription.contains("allow_any_tool"))
      #expect(error.localizedDescription.contains("remote caller"))
    }

    remote.mcp.servers = [
      MCPServerConfig(
        id: "reviewed",
        transport: .stdio,
        command: "/bin/cat",
        exposure: .reexport,
        prefix: "reviewed"
      )
    ]
    expectThrows(try remote.validate()) { error in
      #expect(error.localizedDescription.contains("reexport requires allowed_tools"))
    }

    remote.mcp.servers[0].allowedTools = ["read"]
    expectNoThrow(try remote.validate())
  }

  @Test
  func testUsesConfigDirectoryAsStandaloneWorkspaceDirectory() throws {
    let path = try writeConfig(
      """
      [server]
      name = "workspace-base"
      """
    )

    let config = try GatewayConfiguration.load(path: path)

    #expect(
      (config.workspaceDirectory.standardizedFileURL.path)
        == (URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path))
  }

  @Test
  func testLoadsSkillsConfiguration() throws {
    let path = try writeConfig(
      """
      [skills]
      enabled = true
      max_bytes_per_skill = 2048

      [[skills.roots]]
      id = "local"
      path = "skills"
      description = "Local reusable skills."
      """
    )

    let config = try GatewayConfiguration.load(path: path)
    let base = URL(fileURLWithPath: path).deletingLastPathComponent()

    #expect(config.skills.enabled)
    #expect((config.skills.maxBytesPerSkill) == (2048))
    #expect((config.skills.roots.first?.id) == ("local"))
    #expect((config.skills.roots.first?.description) == ("Local reusable skills."))
    #expect(
      (config.skills.roots.first?.path)
        == (base.appendingPathComponent("skills").standardizedFileURL.path))
  }

  @Test
  func testRejectsBadSkillsConfiguration() throws {
    let enabledWithoutRoots = try writeConfig(
      """
      [skills]
      enabled = true
      """
    )

    expectThrows(try GatewayConfiguration.load(path: enabledWithoutRoots)) { error in
      #expect(errorMessage(error).contains("skills.roots"))
    }

    let duplicateRoots = try writeConfig(
      """
      [skills]
      enabled = true

      [[skills.roots]]
      id = "local"
      path = "one"

      [[skills.roots]]
      id = "local"
      path = "two"
      """
    )

    expectThrows(try GatewayConfiguration.load(path: duplicateRoots)) { error in
      #expect(errorMessage(error).contains("Duplicate skill root id"))
    }

    let invalidRootID = try writeConfig(
      """
      [skills]
      enabled = true

      [[skills.roots]]
      id = "bad/id"
      path = "skills"
      """
    )

    expectThrows(try GatewayConfiguration.load(path: invalidRootID)) { error in
      #expect(errorMessage(error).contains("ASCII letters"))
    }

    let invalidByteLimit = try writeConfig(
      """
      [skills]
      enabled = false
      max_bytes_per_skill = 0
      """
    )

    expectThrows(try GatewayConfiguration.load(path: invalidByteLimit)) { error in
      #expect(errorMessage(error).contains("skills.max_bytes_per_skill"))
    }
  }

  @Test
  func testLoadsHTTPServerConfiguration() throws {
    let path = try writeConfig(
      """
      [server]
      name = "computer-mcp"

      [server.http]
      host = "127.0.0.1"
      port = 9876
      path = "/mcp"
      health_path = "/health"
      public_base_url = "https://gateway.example.com"
      access_token_env = "COMPUTER_MCP_HTTP_ACCESS_TOKEN"
      allowed_origins = ["https://chatgpt.com"]
      """
    )

    let config = try GatewayConfiguration.load(path: path)

    #expect((config.server.http.port) == (9876))
    #expect((config.server.http.publicBaseURL) == ("https://gateway.example.com"))
    #expect((config.server.http.accessTokenEnv) == ("COMPUTER_MCP_HTTP_ACCESS_TOKEN"))
    #expect((config.server.http.allowedOrigins) == (["https://chatgpt.com"]))
  }

  @Test
  func testRejectsRemovedOAuthConfigurationAsUnknown() throws {
    let path = try writeConfig(
      """
      [server.http]
      public_base_url = "https://gateway.example.com"

      [server.http.oauth]
      enabled = true
      """
    )

    expectThrows(try GatewayConfiguration.load(path: path)) { error in
      #expect(error.localizedDescription.contains("Unknown configuration field"))
      #expect(error.localizedDescription.contains("oauth"))
    }
  }

  @Test
  func testRejectsDuplicateCLIIDs() throws {
    let path = try writeConfig(
      """
      [[cli.commands]]
      id = "git"
      executable = "/usr/bin/git"

      [[cli.commands]]
      id = "git"
      executable = "/bin/echo"
      """
    )

    expectThrows(try GatewayConfiguration.load(path: path)) { error in
      #expect(error.localizedDescription.contains("Duplicate CLI command id"))
    }
  }

  @Test
  func testRejectsBadCLIInterfaceValue() throws {
    let path = try writeConfig(
      """
      [[cli.commands]]
      id = "echo"
      executable = "/bin/echo"

      [cli.commands.interface]
      path_style = "argv"
      flag_style = "long_flags"
      flag_case = "snake"
      value_style = "separate"
      """
    )

    expectThrows(try GatewayConfiguration.load(path: path))
  }

  @Test
  func testRejectsEmptyCLIInterfaceStringValue() throws {
    let path = try writeConfig(
      """
      [[cli.commands]]
      id = "echo"
      executable = "/bin/echo"

      [cli.commands.interface]
      path_style = "argv"
      flag_style = "long_flags"
      flag_case = "kebab"
      value_style = "separate"
      format_flag = ""
      """
    )

    expectThrows(try GatewayConfiguration.load(path: path)) { error in
      #expect(error.localizedDescription.contains("interface.format_flag"))
    }
  }

  @Test
  func testRejectsReexportWithoutPrefix() throws {
    let path = try writeConfig(
      """
      [[mcp.servers]]
      id = "figma"
      transport = "streamable_http"
      url = "https://mcp.figma.com/mcp"
      exposure = "reexport"
      """
    )

    expectThrows(try GatewayConfiguration.load(path: path)) { error in
      #expect(error.localizedDescription.contains("prefix"))
    }
  }

  @Test
  func testRejectsDuplicateToolNames() throws {
    let path = try writeConfig(
      """
      [[mcp.servers]]
      id = "fake"
      transport = "stdio"
      command = "/bin/cat"

      [[tools]]
      name = "fake.sample"
      adapter = "mcp"
      source = "fake"
      tool = "one"

      [[tools]]
      name = "fake.sample"
      adapter = "mcp"
      source = "fake"
      tool = "two"
      """
    )

    expectThrows(try GatewayConfiguration.load(path: path)) { error in
      #expect(error.localizedDescription.contains("Duplicate tool name"))
    }
  }

  @Test
  func testRejectsNoncanonicalGatewayToolIDs() throws {
    for toolName in ["sample", "Fake.sample", "fake.bad-name", "fake.bad__name"] {
      let path = try writeConfig(
        """
        [[mcp.servers]]
        id = "fake"
        transport = "stdio"
        command = "/bin/cat"

        [[tools]]
        name = "\(toolName)"
        adapter = "mcp"
        source = "fake"
        tool = "sample"
        """
      )

      expectThrows(try GatewayConfiguration.load(path: path)) { error in
        #expect(error.localizedDescription.contains("lowercase namespace"))
      }
    }
  }

  @Test
  func testRejectsNoncanonicalProfileCapabilityIDs() throws {
    for capability in ["workspace", "Workspace.info", "workspace.bad-name", "workspace.bad__name"] {
      let path = try writeConfig(
        """
        [[profiles]]
        id = "custom-observe"
        capabilities = ["\(capability)"]
        allowed_callers = ["secure-tunnel"]
        """
      )

      expectThrows(try GatewayConfiguration.load(path: path)) { error in
        #expect(error.localizedDescription.contains("lowercase namespace"))
      }
    }
  }

  @Test
  func testRejectsCLIBackedTool() throws {
    let path = try writeConfig(
      """
      [[cli.commands]]
      id = "echo"
      executable = "/bin/echo"

      [[tools]]
      name = "echo.say"
      adapter = "cli"
      source = "echo"
      argv = ["hello"]
      """
    )

    expectThrows(try GatewayConfiguration.load(path: path))
  }

  @Test
  func testRejectsToolWithUnknownMCPSource() throws {
    let path = try writeConfig(
      """
      [[tools]]
      name = "missing.sample"
      adapter = "mcp"
      source = "missing"
      tool = "sample"
      """
    )

    expectThrows(try GatewayConfiguration.load(path: path)) { error in
      #expect(error.localizedDescription.contains("unknown MCP source"))
    }
  }

  @Test
  func testRejectsMCPBackedToolWithoutDownstreamToolName() throws {
    let path = try writeConfig(
      """
      [[mcp.servers]]
      id = "fake"
      transport = "stdio"
      command = "/bin/cat"

      [[tools]]
      name = "fake.sample"
      adapter = "mcp"
      source = "fake"
      """
    )

    expectThrows(try GatewayConfiguration.load(path: path)) { error in
      #expect(error.localizedDescription.contains("requires tool"))
    }
  }

  @Test
  func testRejectsBadToolInputSchema() throws {
    let path = try writeConfig(
      """
      [[mcp.servers]]
      id = "fake"
      transport = "stdio"
      command = "/bin/cat"

      [[tools]]
      name = "fake.sample"
      adapter = "mcp"
      source = "fake"
      tool = "sample"
      input_schema = "not-json"
      """
    )

    expectThrows(try GatewayConfiguration.load(path: path)) { error in
      #expect(error.localizedDescription.contains("input_schema"))
    }
  }

  @Test
  func testRejectsUnknownToolAdapter() throws {
    let path = try writeConfig(
      """
      [[mcp.servers]]
      id = "fake"
      transport = "stdio"
      command = "/bin/cat"

      [[tools]]
      name = "fake.sample"
      adapter = "shell"
      source = "fake"
      tool = "sample"
      """
    )

    expectThrows(try GatewayConfiguration.load(path: path))
  }

  @Test
  func testRejectsConfiguredToolNameThatConflictsWithGatewayTool() throws {
    let path = try writeConfig(
      """
      [[mcp.servers]]
      id = "fake"
      transport = "stdio"
      command = "/bin/cat"

      [[tools]]
      name = "cli.exec"
      adapter = "mcp"
      source = "fake"
      tool = "sample"
      """
    )

    expectThrows(try GatewayConfiguration.load(path: path)) { error in
      #expect(error.localizedDescription.contains("conflicts with gateway tool"))
    }
  }

  @Test
  func testRejectsConfiguredToolNameThatConflictsWithNewGatewayTool() throws {
    let path = try writeConfig(
      """
      [[mcp.servers]]
      id = "fake"
      transport = "stdio"
      command = "/bin/cat"

      [[tools]]
      name = "cli.status"
      adapter = "mcp"
      source = "fake"
      tool = "sample"
      """
    )

    expectThrows(try GatewayConfiguration.load(path: path)) { error in
      #expect(error.localizedDescription.contains("conflicts with gateway tool"))
    }
  }

  @Test
  func testRejectsConfiguredToolNameThatConflictsWithPolicyProbe() throws {
    let path = try writeConfig(
      """
      [[mcp.servers]]
      id = "fake"
      transport = "stdio"
      command = "/bin/cat"

      [[tools]]
      name = "policy.probe"
      adapter = "mcp"
      source = "fake"
      tool = "sample"
      """
    )

    expectThrows(try GatewayConfiguration.load(path: path)) { error in
      #expect(error.localizedDescription.contains("conflicts with gateway tool"))
    }
  }

  @Test
  func testLoadsNewBuiltinAtomicCapabilities() throws {
    let path = try writeConfig(
      """
      [builtin]
      enabled = ["workspace.info", "workspace.status", "workspace.manifests", "workspace.recent_files", "workspace.directory_stats", "workspace.artifact_directories", "workspace.empty_directories", "workspace.git_changes", "workspace.file_types", "workspace.large_files", "workspace.symlinks", "workspace.executable_files", "workspace.todos", "workspace.env_files", "workspace.dependency_files", "workspace.project_roots", "workspace.documentation_files", "workspace.agent_files", "workspace.instructions", "workspace.test_files", "workspace.ci_files", "workspace.infra_files", "workspace.config_files", "workspace.ignore_files", "workspace.asset_files", "workspace.archive_files", "workspace.log_files", "workspace.data_files", "workspace.schema_files", "workspace.source_files", "workspace.outline", "workspace.commands", "workspace.governance_files", "system.info", "system.kernel", "system.software", "system.locale", "system.memory", "system.load", "system.cpu", "system.thermal", "system.time", "system.uptime", "system.user", "system.groups", "system.power", "system.volumes", "system.processes", "system.which", "system.path", "logs.query", "service.status", "network.interfaces", "network.dns", "network.resolve", "network.proxy", "network.services", "network.hardware_ports", "network.wifi", "network.vpn", "network.locations", "network.routes", "network.connections", "network.arp", "network.ping", "network.tcp_check", "network.http_check", "network.listeners", "macos.user_directories", "macos.default_application", "macos.applications", "macos.screens", "macos.spotlight_search", "macos.running_applications", "macos.frontmost_application", "env.describe", "file.exists", "file.list", "file.tree", "file.stat", "file.permissions", "file.chmod", "file.type", "file.count", "file.disk_usage", "file.volume_info", "file.find", "file.search", "file.timeline", "file.read", "file.read_files", "file.read_window", "file.read_lines", "file.read_context", "file.head", "file.outline", "markdown.links", "markdown.tables", "markdown.section", "markdown.frontmatter", "markdown.link_check", "file.tail", "file.hexdump", "file.xattrs", "file.remove_xattr", "file.metadata", "file.readlink", "file.resolve", "image.info", "pdf.info", "pdf.text", "media.info", "json.read", "jsonl.read", "json.write", "toml.read", "yaml.read", "xml.read", "plist.read", "structured.get", "plist.write", "csv.read", "sqlite.schema", "sqlite.query", "file.hash", "file.diff", "file.compare_trees", "file.duplicates", "archive.list", "archive.extract", "archive.create", "file.download", "file.write", "file.write_files", "file.append", "file.replace_text", "file.insert_text", "file.replace_lines", "file.touch", "file.mkdir", "file.copy", "file.move", "file.symlink", "file.trash", "workspace.open", "workspace.reveal", "git.root", "git.config", "git.remotes", "git.worktrees", "git.stashes", "git.stash_show", "git.stash_push", "git.tags", "git.tag_show", "git.tag_create", "git.tag_delete", "git.ignored", "git.submodules", "git.files", "git.grep", "git.blame", "git.file_history", "git.file_at_revision", "git.staged_file", "git.conflicts", "git.status", "git.tracking_status", "git.clean_preview", "git.clean", "git.reflog", "git.refs", "git.resolve_ref", "git.merge_base", "git.compare_refs", "git.is_ancestor", "git.diff", "git.diff_summary", "git.diff_check", "git.branch", "git.branch_create", "git.branch_delete", "git.branch_rename", "git.branch_switch", "git.log", "git.commit_files", "git.show", "git.add", "git.unstage", "git.restore_worktree", "git.commit"]
      """
    )

    let config = try GatewayConfiguration.load(path: path)

    #expect(
      (config.builtin.enabled)
        == ([
          "workspace.info", "workspace.status", "workspace.manifests", "workspace.recent_files",
          "workspace.directory_stats", "workspace.artifact_directories",
          "workspace.empty_directories", "workspace.git_changes",
          "workspace.file_types",
          "workspace.large_files",
          "workspace.symlinks",
          "workspace.executable_files", "workspace.todos", "workspace.env_files",
          "workspace.dependency_files", "workspace.project_roots",
          "workspace.documentation_files", "workspace.agent_files", "workspace.instructions",
          "workspace.test_files",
          "workspace.ci_files", "workspace.infra_files", "workspace.config_files",
          "workspace.ignore_files",
          "workspace.asset_files", "workspace.archive_files", "workspace.log_files",
          "workspace.data_files",
          "workspace.schema_files",
          "workspace.source_files",
          "workspace.outline",
          "workspace.commands", "workspace.governance_files", "system.info", "system.kernel",
          "system.software", "system.locale",
          "system.memory", "system.load", "system.cpu", "system.thermal", "system.time",
          "system.uptime",
          "system.user",
          "system.groups",
          "system.power",
          "system.volumes",
          "system.processes", "system.which", "system.path", "logs.query", "service.status",
          "network.interfaces", "network.dns",
          "network.resolve", "network.proxy", "network.services", "network.hardware_ports",
          "network.wifi",
          "network.vpn",
          "network.locations", "network.routes",
          "network.connections", "network.arp",
          "network.ping",
          "network.tcp_check",
          "network.http_check",
          "network.listeners",
          "macos.user_directories", "macos.default_application", "macos.applications",
          "macos.screens",
          "macos.spotlight_search", "macos.running_applications",
          "macos.frontmost_application", "env.describe", "file.exists",
          "file.list",
          "file.tree",
          "file.stat",
          "file.permissions", "file.chmod", "file.type", "file.count", "file.disk_usage",
          "file.volume_info", "file.find", "file.search",
          "file.timeline",
          "file.read", "file.read_files", "file.read_window", "file.read_lines",
          "file.read_context",
          "file.head",
          "file.outline",
          "markdown.links",
          "markdown.tables",
          "markdown.section",
          "markdown.frontmatter",
          "markdown.link_check",
          "file.tail", "file.hexdump",
          "file.xattrs",
          "file.remove_xattr", "file.metadata", "file.readlink", "file.resolve", "image.info",
          "pdf.info", "pdf.text", "media.info", "json.read",
          "jsonl.read", "json.write", "toml.read", "yaml.read", "xml.read",
          "plist.read", "structured.get", "plist.write", "csv.read", "sqlite.schema",
          "sqlite.query",
          "file.hash",
          "file.diff", "file.compare_trees", "file.duplicates", "archive.list", "archive.extract",
          "archive.create", "file.download",
          "file.write",
          "file.write_files",
          "file.append",
          "file.replace_text",
          "file.insert_text", "file.replace_lines", "file.touch", "file.mkdir", "file.copy",
          "file.move", "file.symlink",
          "file.trash", "workspace.open", "workspace.reveal", "git.root", "git.config",
          "git.remotes",
          "git.worktrees", "git.stashes", "git.stash_show", "git.stash_push", "git.tags",
          "git.tag_show", "git.tag_create", "git.tag_delete", "git.ignored",
          "git.submodules",
          "git.files", "git.grep", "git.blame", "git.file_history", "git.file_at_revision",
          "git.staged_file", "git.conflicts", "git.status", "git.tracking_status",
          "git.clean_preview", "git.clean", "git.reflog", "git.refs", "git.resolve_ref",
          "git.merge_base", "git.compare_refs", "git.is_ancestor", "git.diff", "git.diff_summary",
          "git.diff_check", "git.branch", "git.branch_create", "git.branch_delete",
          "git.branch_rename", "git.branch_switch",
          "git.log", "git.commit_files", "git.show", "git.add", "git.unstage",
          "git.restore_worktree", "git.commit",
        ]))
  }

  @Test
  func testRejectsUnknownBuiltinCapability() throws {
    let path = try writeConfig(
      """
      [builtin]
      enabled = ["file.inspect"]
      """
    )

    expectThrows(try GatewayConfiguration.load(path: path)) { error in
      #expect(error.localizedDescription.contains("Unknown builtin capability"))
    }
  }

  @Test
  func testLoadsSchemaV1WorkspacesProfilesAndRuntimeBinding() throws {
    let path = try writeConfig(
      """
      schema_version = 1

      [runtime]
      caller = "secure-tunnel"
      profile = "chatgpt-operate"
      workspace_id = "primary"

      [[workspaces]]
      id = "primary"
      display_name = "Primary Repository"
      path = "repo"

      [[workspaces]]
      id = "bookmarked"
      display_name = "App Bookmark"

      [[profiles]]
      id = "chatgpt-observe"
      capabilities = ["workspace.list", "file.read"]
      workspaces = ["primary"]
      allowed_callers = ["secure-tunnel"]

      [[profiles]]
      id = "chatgpt-operate"
      capabilities = ["file.read", "file.write"]
      workspaces = ["primary"]
      allowed_callers = ["secure-tunnel"]
      """
    )

    let config = try GatewayConfiguration.load(path: path)
    let base = URL(fileURLWithPath: path).deletingLastPathComponent()

    #expect((config.schemaVersion) == (1))
    #expect((config.runtime.caller) == (.secureTunnel))
    #expect((config.runtime.profileID) == (.chatGPTOperate))
    #expect((config.runtime.defaultWorkspaceID) == ("primary"))
    #expect((config.workspaces.map(\.id)) == (["primary", "bookmarked"]))
    #expect(
      (config.workspaces.first?.path)
        == (base.appendingPathComponent("repo").standardizedFileURL.path))
    #expect((config.workspaces.last?.path) == nil)
    #expect((config.manifestWorkspaces.map(\.id)) == (["primary"]))
    #expect(
      (config.profileGrant(for: .chatGPTOperate).capabilityIDs) == (["file.read", "file.write"]))
    #expect(!(config.profileGrant(for: .chatGPTOperate).fullShellEnabled))
  }

  @Test
  func testSchemaV1RejectsInvalidWorkspaceAndProfileBindings() throws {
    let duplicateWorkspaces = try writeConfig(
      """
      schema_version = 1

      [[workspaces]]
      id = "same"
      path = "."

      [[workspaces]]
      id = "same"
      path = ".."
      """
    )
    expectThrows(try GatewayConfiguration.load(path: duplicateWorkspaces)) { error in
      #expect(error.localizedDescription.contains("Duplicate workspace id"))
    }

    let unknownWorkspace = try writeConfig(
      """
      schema_version = 1

      [[workspaces]]
      id = "known"
      path = "."

      [[profiles]]
      id = "chatgpt-operate"
      capabilities = ["file.read"]
      workspaces = ["unknown"]
      """
    )
    expectThrows(try GatewayConfiguration.load(path: unknownWorkspace)) { error in
      #expect(error.localizedDescription.contains("unknown workspace"))
    }

    let remoteAdmin = try writeConfig(
      """
      schema_version = 1

      [runtime]
      caller = "secure-tunnel"
      profile = "local-admin"
      """
    )
    expectThrows(try GatewayConfiguration.load(path: remoteAdmin)) { error in
      #expect(error.localizedDescription.contains("local-admin"))
    }

    let removedWorkspaceSection = try writeConfig(
      """
      [workspace]
      root = "."
      """
    )
    expectThrows(try GatewayConfiguration.load(path: removedWorkspaceSection)) { error in
      #expect(error.localizedDescription.contains("Unknown configuration field"))
      #expect(error.localizedDescription.contains("workspace"))
    }
  }

  @Test
  func testSchemaV1AllowsExplicitOperateShellAndRejectsOtherRemoteProfiles() throws {
    let observeShell = try writeConfig(
      """
      schema_version = 1

      [[profiles]]
      id = "chatgpt-observe"
      capabilities = ["shell.run"]
      full_shell_enabled = true
      """
    )
    expectThrows(try GatewayConfiguration.load(path: observeShell)) { error in
      #expect(error.localizedDescription.contains("chatgpt-observe"))
    }

    let operateShell = try writeConfig(
      """
      schema_version = 1

      [policy]
      shell_enabled = true

      [[profiles]]
      id = "chatgpt-operate"
      capabilities = ["shell.run"]
      full_shell_enabled = true
      """
    )
    let operateConfig = try GatewayConfiguration.load(path: operateShell)
    #expect(operateConfig.policy.shellEnabled)
    #expect(operateConfig.profileGrant(for: .chatGPTOperate).fullShellEnabled)
    #expect(operateConfig.profileGrant(for: .chatGPTOperate).capabilityIDs.contains("shell.run"))

    let cloudflareShell = try writeConfig(
      """
      schema_version = 1

      [[profiles]]
      id = "cloudflare-operate"
      capabilities = ["shell.run"]
      full_shell_enabled = true
      """
    )
    expectThrows(try GatewayConfiguration.load(path: cloudflareShell)) { error in
      #expect(error.localizedDescription.contains("cloudflare-operate"))
    }

    let remoteAdmin = try writeConfig(
      """
      schema_version = 1

      [[profiles]]
      id = "local-admin"
      capabilities = ["*"]
      allowed_callers = ["secure-tunnel"]
      """
    )
    expectThrows(try GatewayConfiguration.load(path: remoteAdmin)) { error in
      #expect(error.localizedDescription.contains("local-admin"))
    }
  }

  @Test
  func testRejectsMissingAndUnsupportedSchemaVersions() throws {
    expectThrows(try GatewayConfiguration.load(text: "[server]\nname = \"missing\""))
    expectThrows(
      try GatewayConfiguration.load(text: "schema_version = 0\n[server]\nname = \"invalid\"")
    ) { error in
      #expect(error.localizedDescription.contains("schema_version must be 1"))
    }
  }

  private func writeConfig(_ text: String) throws -> String {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("computer-mcp.toml")
    let manifest = text.contains("schema_version") ? text : "schema_version = 1\n\n\(text)"
    try manifest.write(to: url, atomically: true, encoding: .utf8)
    return url.path
  }

  private func errorMessage(_ error: Error) -> String {
    "\(error) \(error.localizedDescription)"
  }
}
