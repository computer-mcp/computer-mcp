import Foundation

package enum DefaultGatewayConfiguration {
  package static let observeCapabilities = names(
    """
    archive.list
    archive.read_file
    cli.describe
    cli.help
    cli.list
    cli.status
    computer.accessibility.query
    computer.displays
    computer.permissions
    computer.pointer.position
    computer.screenshot
    computer.verify
    computer.windows
    csv.read
    env.describe
    file.compare_trees
    file.count
    file.diff
    file.disk_usage
    file.duplicates
    file.exists
    file.find
    file.hash
    file.head
    file.hexdump
    file.list
    file.metadata
    file.outline
    file.permissions
    file.read
    file.read_context
    file.read_files
    file.read_lines
    file.read_window
    file.readlink
    file.resolve
    file.search
    file.stat
    file.tail
    file.timeline
    file.tree
    file.type
    file.volume_info
    file.xattrs
    git.blame
    git.branch
    git.clean_preview
    git.compare_refs
    git.config
    git.conflicts
    git.diff
    git.diff_check
    git.diff_summary
    git.file_at_revision
    git.file_history
    git.files
    git.grep
    git.ignored
    git.is_ancestor
    git.log
    git.commit_files
    git.merge_base
    git.reflog
    git.refs
    git.remotes
    git.resolve_ref
    git.root
    git.show
    git.staged_file
    git.stash_show
    git.stashes
    git.status
    git.submodules
    git.tag_show
    git.tags
    git.tracking_status
    git.worktrees
    image.info
    json.read
    jsonl.read
    logs.query
    macos.applications
    macos.default_application
    macos.frontmost_application
    macos.running_applications
    macos.screens
    macos.spotlight_search
    macos.user_directories
    markdown.frontmatter
    markdown.link_check
    markdown.links
    markdown.section
    markdown.tables
    media.info
    network.arp
    network.connections
    network.dns
    network.hardware_ports
    network.http_check
    network.interfaces
    network.listeners
    network.locations
    network.ping
    network.proxy
    network.resolve
    network.routes
    network.services
    network.tcp_check
    network.vpn
    network.wifi
    pdf.info
    pdf.text
    plist.read
    policy.probe
    service.status
    skills.describe
    skills.files
    skills.frontmatter
    skills.link_check
    skills.links
    skills.list
    skills.outline
    skills.read
    skills.read_file
    skills.read_files
    skills.read_package
    skills.roots
    skills.search
    skills.search_files
    skills.section
    skills.tables
    skills.validate
    sqlite.query
    sqlite.schema
    structured.get
    system.cpu
    system.groups
    system.info
    system.kernel
    system.load
    system.locale
    system.memory
    system.path
    system.power
    system.processes
    system.software
    system.thermal
    system.time
    system.uptime
    system.user
    system.volumes
    system.which
    toml.read
    workspace.agent_files
    workspace.archive_files
    workspace.artifact_directories
    workspace.asset_files
    workspace.ci_files
    workspace.commands
    workspace.config_files
    workspace.data_files
    workspace.dependency_files
    workspace.describe
    workspace.directory_stats
    workspace.documentation_files
    workspace.empty_directories
    workspace.env_files
    workspace.executable_files
    workspace.file_types
    workspace.git_changes
    workspace.governance_files
    workspace.ignore_files
    workspace.info
    workspace.infra_files
    workspace.instructions
    workspace.large_files
    workspace.list
    workspace.log_files
    workspace.manifests
    workspace.outline
    workspace.project_roots
    workspace.recent_files
    workspace.schema_files
    workspace.source_files
    workspace.status
    workspace.symlinks
    workspace.test_files
    workspace.todos
    xml.read
    yaml.read
    """
  )

  package static let operateAdditionalCapabilities = names(
    """
    archive.create
    archive.extract
    codex.app.apps.list
    codex.app.approvals.list
    codex.app.approvals.read
    codex.app.approvals.respond
    codex.app.elevation.approve
    codex.app.elevation.deny
    codex.app.elevation.effective
    codex.app.elevation.list
    codex.app.elevation.read
    codex.app.elevation.request
    codex.app.elevation.revoke
    codex.app.events.read
    codex.app.goal.clear
    codex.app.goal.get
    codex.app.goal.set
    codex.app.handoff.diagnose
    codex.app.methods.call
    codex.app.methods.describe
    codex.app.methods.list
    codex.app.models.list
    codex.app.ownership.reconcile.perform
    codex.app.ownership.reconcile.preview
    codex.app.requests.list
    codex.app.requests.respond
    codex.app.review.start
    codex.app.runtime.stop
    codex.app.runtimes.cleanup.perform
    codex.app.runtimes.cleanup.preview
    codex.app.runtimes.history
    codex.app.runtimes.inspect
    codex.app.runtimes.list
    codex.app.runtimes.stop
    codex.app.skills.list
    codex.app.status
    codex.app.thread.fork
    codex.app.thread.list
    codex.app.thread.loaded.list
    codex.app.thread.read
    codex.app.thread.recent
    codex.app.thread.reclaim
    codex.app.thread.release
    codex.app.thread.start
    codex.app.turn.interrupt
    codex.app.turn.start
    codex.app.turn.steer
    codex.diagnostics.snapshot
    codex.exec.cancel
    codex.exec.events
    codex.exec.list
    codex.exec.result
    codex.exec.resume
    codex.exec.start
    codex.mcp.approval.respond
    codex.mcp.approvals.list
    codex.mcp.calls.list
    codex.mcp.cancel
    codex.mcp.events
    codex.mcp.reply
    codex.mcp.result
    codex.mcp.run
    codex.mcp.status
    codex.mcp.tools.list
    codex.run.accept
    codex.run.create
    codex.run.evaluate
    codex.run.list
    codex.run.read
    codex.run.reconcile
    codex.run.record
    codex.run.transition
    codex.worktree.leases.acquire
    codex.worktree.leases.cleanup.perform
    codex.worktree.leases.cleanup.preview
    codex.worktree.leases.heartbeat
    codex.worktree.leases.list
    codex.worktree.leases.read
    codex.worktree.leases.release
    codex.worktree.managed.list
    codex.worktree.managed.read
    codex.worktree.provision.plan
    codex.worktree.provision.perform
    codex.worktree.remove.plan
    codex.worktree.remove.perform
    computer.accessibility.action
    computer.keyboard.key
    computer.keyboard.text
    computer.pointer.click
    computer.pointer.move
    computer.scroll
    file.append
    file.chmod
    file.copy
    file.download
    file.insert_text
    file.mkdir
    file.move
    file.remove_xattr
    file.replace_lines
    file.replace_text
    file.symlink
    file.touch
    file.trash
    file.write
    file.write_files
    git.add
    git.branch_create
    git.branch_delete
    git.branch_rename
    git.branch_switch
    git.clean
    git.commit
    git.restore_worktree
    git.stash_push
    git.tag_create
    git.tag_delete
    git.unstage
    json.write
    mcp.events.read
    mcp.prompts.get
    mcp.prompts.list
    mcp.requests.cancel
    mcp.requests.list
    mcp.resources.list
    mcp.resources.read
    mcp.resources.templates.list
    mcp.servers.list
    mcp.servers.status
    mcp.tools.call
    mcp.tools.describe
    mcp.tools.find
    mcp.tools.list
    operations.commit
    operations.prepare
    plist.write
    process.list
    workspace.open
    workspace.reveal
    """
  )

  package static let operateCapabilities = Array(
    Set(observeCapabilities + operateAdditionalCapabilities)
  ).sorted()

  package static let enabledBuiltinCapabilities = operateCapabilities.filter {
    if $0 == "workspace.list" || $0 == "workspace.describe" {
      return false
    }
    let domain = $0.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
    return ![
      "cli",
      "codex",
      "computer",
      "mcp",
      "operations",
      "policy",
      "process",
      "skills",
    ].contains(domain)
  }

  package static let manifest: String = {
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    let codexExecutable = resolvedCodexExecutable()
    return """
      schema_version = 1

      [server]
      name = "computer-mcp"

      [runtime]
      caller = "secure-tunnel"
      profile = "chatgpt-observe"

      [policy]
      default_timeout_ms = 30000
      max_output_bytes = 1048576
      shell_enabled = false

      [[profiles]]
      id = "chatgpt-observe"
      capabilities = \(tomlArray(observeCapabilities))
      workspaces = []
      allowed_callers = ["secure-tunnel"]
      full_shell_enabled = false

      [[profiles]]
      id = "chatgpt-operate"
      capabilities = \(tomlArray(operateCapabilities))
      workspaces = []
      allowed_callers = ["secure-tunnel"]

      [[profiles]]
      id = "cloudflare-observe"
      capabilities = \(tomlArray(observeCapabilities))
      workspaces = []
      allowed_callers = ["cloudflare-tunnel"]
      full_shell_enabled = false

      [[profiles]]
      id = "cloudflare-operate"
      capabilities = \(tomlArray(operateCapabilities))
      workspaces = []
      allowed_callers = ["cloudflare-tunnel"]
      full_shell_enabled = false

      [[profiles]]
      id = "local-admin"
      capabilities = ["*"]
      workspaces = []
      allowed_callers = ["local-app", "local-cli", "local-mcp"]
      full_shell_enabled = true

      [skills]
      enabled = true
      max_bytes_per_skill = 1048576

      [[skills.roots]]
      id = "codex-user"
      path = \(tomlString(home + "/.codex/skills"))
      description = "User Codex skills."

      [[skills.roots]]
      id = "codex-system"
      path = \(tomlString(home + "/.codex/skills/.system"))
      description = "Bundled Codex system skills."

      [[skills.roots]]
      id = "agents-user"
      path = \(tomlString(home + "/.agents/skills"))
      description = "User agent skills."

      [[cli.commands]]
      id = "git"
      executable = "git"
      cwd = "workspace"
      allow_any_args = true
      risk = "workspace-write-capable"
      discovery = ["help"]

      [[cli.commands]]
      id = "swift"
      executable = "swift"
      cwd = "workspace"
      allow_any_args = true
      risk = "workspace-write-capable"
      discovery = ["help"]

      [[cli.commands]]
      id = "codex"
      executable = \(tomlString(codexExecutable))
      cwd = "workspace"
      allow_any_args = true
      risk = "workspace-write-capable"
      discovery = ["help"]

      [[cli.commands]]
      id = "lark"
      executable = "lark-cli"
      cwd = "workspace"
      allow_any_args = true
      risk = "external-write-capable"
      discovery = ["help", "schema", "dry-run"]

      [cli.commands.interface]
      path_style = "argv"
      flag_style = "long_flags"
      flag_case = "kebab"
      value_style = "separate"
      format_flag = "--format"
      default_format = "json"
      dry_run_flag = "--dry-run"

      [codex]
      enabled = true
      executable = \(tomlString(codexExecutable))
      app_server_enabled = true
      exec_enabled = true
      mcp_enabled = true
      experimental_api = true
      app_server_request_timeout_seconds = 30
      app_server_app_list_timeout_seconds = 120
      app_server_termination_grace_milliseconds = 1000
      app_server_kill_grace_milliseconds = 2000
      app_server_approval_timeout_seconds = 300
      app_server_auto_approve_workspace_writes = false
      sandbox = "workspace-write"
      approval_policy = "never"
      max_sessions = 8
      max_events_per_session = 1024

      [builtin]
      enabled = \(tomlArray(enabledBuiltinCapabilities))
      """
  }()

  package static func configuration(
    for profileID: GatewayProfileID
  ) throws -> GatewayConfiguration {
    var configuration = try GatewayConfiguration.load(
      text: manifest,
      baseURL: FileManager.default.homeDirectoryForCurrentUser
    )
    let caller: GatewayCallerKind =
      profileID == .localAdmin
      ? .localMCP
      : (profileID == .cloudflareObserve || profileID == .cloudflareOperate
        ? .cloudflareTunnel : .secureTunnel)
    configuration.runtime = RuntimeBindingConfig(
      caller: caller,
      profileID: profileID
    )
    try configuration.validate()
    return configuration
  }

  private static func names(_ value: String) -> [String] {
    value.split(whereSeparator: \.isWhitespace).map(String.init).sorted()
  }

  private static func tomlArray(_ values: [String]) -> String {
    guard !values.isEmpty else {
      return "[]"
    }
    return "[\n" + values.sorted().map { "  \(tomlString($0))," }.joined(separator: "\n") + "\n]"
  }

  private static func tomlString(_ value: String) -> String {
    var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
    escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
    escaped = escaped.replacingOccurrences(of: "\n", with: "\\n")
    return "\"\(escaped)\""
  }

  private static func resolvedCodexExecutable() -> String {
    let environment = ProcessInfo.processInfo.environment
    let home = FileManager.default.homeDirectoryForCurrentUser
    var candidates = [
      URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
      URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
      home.appendingPathComponent(".local/bin/codex"),
      home.appendingPathComponent("bin/codex"),
      URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
      URL(fileURLWithPath: "/usr/local/bin/codex"),
    ]
    candidates.insert(
      contentsOf: (environment["PATH"] ?? "")
        .split(separator: ":", omittingEmptySubsequences: true)
        .map { URL(fileURLWithPath: String($0)).appendingPathComponent("codex") },
      at: 0
    )
    return candidates.first {
      FileManager.default.isExecutableFile(atPath: $0.standardizedFileURL.path)
    }?.standardizedFileURL.resolvingSymlinksInPath().path ?? "codex"
  }
}
