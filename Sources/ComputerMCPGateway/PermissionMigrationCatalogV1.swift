import ComputerMCPCore
import ComputerMCPPermissions

// Migration V1 classifications, frozen from the 278-tool host catalog at 4c0c3cd.
// This migration input is independent of future provider catalog changes.
extension PermissionMigrationCatalog {
  static let builtinV1: [PermissionMigrationTool] = {
    var result: [PermissionMigrationTool] = []
    result += [
      "mcp.connections.close",
      "mcp.requests.cancel",
      "mcp.tools.call",
    ].map { id in
      PermissionMigrationTool(
        id: id, risk: .destructive, projectRequirement: .none,
        localOnly: false, usesNetwork: true, access: .none,
        permissions: [])
    }
    result += [
      "archive.create",
      "archive.extract",
      "json.write",
      "plist.write",
    ].map { id in
      PermissionMigrationTool(
        id: id, risk: .destructive, projectRequirement: .optional,
        localOnly: false, usesNetwork: false, access: .projectWrite,
        permissions: [])
    }
    result += [
      "file.chmod",
      "file.copy",
      "file.insert_text",
      "file.move",
      "file.remove_xattr",
      "file.replace_lines",
      "file.replace_text",
      "file.touch",
      "file.trash",
      "file.write",
      "file.write_files",
      "git.add",
      "git.branch_rename",
      "git.branch_switch",
      "git.clean",
      "git.restore_worktree",
      "git.stash_push",
      "git.tag_delete",
      "git.unstage",
      "process.cancel",
    ].map { id in
      PermissionMigrationTool(
        id: id, risk: .destructive, projectRequirement: .required,
        localOnly: false, usesNetwork: false, access: .projectWrite,
        permissions: [])
    }
    result += [
      "git.branch_delete"
    ].map { id in
      PermissionMigrationTool(
        id: id, risk: .destructive, projectRequirement: .required,
        localOnly: false, usesNetwork: false, access: .sourceProjectWrite,
        permissions: [])
    }
    result += [
      "file.download"
    ].map { id in
      PermissionMigrationTool(
        id: id, risk: .destructive, projectRequirement: .required,
        localOnly: false, usesNetwork: true, access: .projectWrite,
        permissions: [])
    }
    result += [
      "computer.accessibility.action",
      "computer.keyboard.key",
      "computer.keyboard.text",
      "computer.pointer.click",
      "computer.pointer.move",
      "computer.scroll",
    ].map { id in
      PermissionMigrationTool(
        id: id, risk: .externalWrite, projectRequirement: .none,
        localOnly: false, usesNetwork: false, access: .none,
        permissions: [try! PermissionRequirement(.desktopControl, .access)])
    }
    result += [
      "operations.commit",
      "operations.prepare",
    ].map { id in
      PermissionMigrationTool(
        id: id, risk: .externalWrite, projectRequirement: .optional,
        localOnly: false, usesNetwork: false, access: .none,
        permissions: [])
    }
    result += [
      "plugin.configure",
      "plugin.disable",
      "plugin.enable",
      "plugin.uninstall",
      "project.add",
      "project.grant",
      "project.remove",
      "project.repair",
    ].map { id in
      PermissionMigrationTool(
        id: id, risk: .fullShell, projectRequirement: .none,
        localOnly: false, usesNetwork: false, access: .none,
        permissions: [])
    }
    result += [
      "plugin.install",
      "plugin.update",
    ].map { id in
      PermissionMigrationTool(
        id: id, risk: .fullShell, projectRequirement: .none,
        localOnly: false, usesNetwork: true, access: .none,
        permissions: [])
    }
    result += [
      "cli.exec",
      "process.spawn",
      "process.write",
      "shell.cancel",
      "shell.run",
      "shell.spawn",
      "shell.write",
    ].map { id in
      PermissionMigrationTool(
        id: id, risk: .fullShell, projectRequirement: .required,
        localOnly: false, usesNetwork: false, access: .projectWrite,
        permissions: [])
    }
    result += [
      "shell.list",
      "shell.read",
    ].map { id in
      PermissionMigrationTool(
        id: id, risk: .fullShell, projectRequirement: .required,
        localOnly: false, usesNetwork: false, access: .read,
        permissions: [])
    }
    result += [
      "profile.limit"
    ].map { id in
      PermissionMigrationTool(
        id: id, risk: .projectWrite, projectRequirement: .none,
        localOnly: false, usesNetwork: false, access: .none,
        permissions: [])
    }
    result += [
      "project.open",
      "project.reveal",
    ].map { id in
      PermissionMigrationTool(
        id: id, risk: .projectWrite, projectRequirement: .required,
        localOnly: false, usesNetwork: false, access: .none,
        permissions: [try! PermissionRequirement(.desktopControl, .access)])
    }
    result += [
      "delivery.apply",
      "file.append",
      "file.mkdir",
      "file.symlink",
      "git.branch_create",
      "git.commit",
      "git.tag_create",
    ].map { id in
      PermissionMigrationTool(
        id: id, risk: .projectWrite, projectRequirement: .required,
        localOnly: false, usesNetwork: false, access: .projectWrite,
        permissions: [])
    }
    result += [
      "profile.show",
      "project.describe",
      "project.list",
    ].map { id in
      PermissionMigrationTool(
        id: id, risk: .readOnly, projectRequirement: .none,
        localOnly: false, usesNetwork: false, access: .none,
        permissions: [])
    }
    result += [
      "cli.describe",
      "cli.help",
      "cli.list",
      "cli.status",
      "macos.applications",
      "macos.default_application",
      "macos.frontmost_application",
      "macos.running_applications",
      "macos.screens",
      "macos.spotlight_search",
      "macos.user_directories",
      "plugin.describe",
      "plugin.list",
      "system.cpu",
      "system.groups",
      "system.info",
      "system.kernel",
      "system.load",
      "system.locale",
      "system.memory",
      "system.path",
      "system.power",
      "system.processes",
      "system.software",
      "system.thermal",
      "system.time",
      "system.uptime",
      "system.user",
      "system.volumes",
      "system.which",
    ].map { id in
      PermissionMigrationTool(
        id: id, risk: .readOnly, projectRequirement: .none,
        localOnly: false, usesNetwork: false, access: .none,
        permissions: [try! PermissionRequirement(.machineInformation, .access)])
    }
    result += [
      "computer.accessibility.query",
      "computer.displays",
      "computer.permissions",
      "computer.pointer.position",
      "computer.screenshot",
      "computer.verify",
      "computer.windows",
    ].map { id in
      PermissionMigrationTool(
        id: id, risk: .readOnly, projectRequirement: .none,
        localOnly: false, usesNetwork: false, access: .none,
        permissions: [try! PermissionRequirement(.screen, .access)])
    }
    result += [
      "skills.describe",
      "skills.files",
      "skills.frontmatter",
      "skills.link_check",
      "skills.links",
      "skills.list",
      "skills.outline",
      "skills.read",
      "skills.read_file",
      "skills.read_files",
      "skills.read_package",
      "skills.roots",
      "skills.search",
      "skills.search_files",
      "skills.section",
      "skills.tables",
      "skills.validate",
    ].map { id in
      PermissionMigrationTool(
        id: id, risk: .readOnly, projectRequirement: .none,
        localOnly: false, usesNetwork: false, access: .none,
        permissions: [try! PermissionRequirement(.skills, .access)])
    }
    result += [
      "mcp.events.read",
      "mcp.prompts.get",
      "mcp.prompts.list",
      "mcp.requests.list",
      "mcp.requests.read",
      "mcp.resources.list",
      "mcp.resources.read",
      "mcp.resources.templates.list",
      "mcp.servers.list",
      "mcp.servers.status",
      "mcp.tools.describe",
      "mcp.tools.find",
      "mcp.tools.list",
    ].map { id in
      PermissionMigrationTool(
        id: id, risk: .readOnly, projectRequirement: .none,
        localOnly: false, usesNetwork: true, access: .none,
        permissions: [])
    }
    result += [
      "network.arp",
      "network.connections",
      "network.dns",
      "network.hardware_ports",
      "network.http_check",
      "network.interfaces",
      "network.listeners",
      "network.locations",
      "network.ping",
      "network.proxy",
      "network.resolve",
      "network.routes",
      "network.services",
      "network.tcp_check",
      "network.vpn",
      "network.wifi",
      "plugin.artifacts",
      "plugin.search",
    ].map { id in
      PermissionMigrationTool(
        id: id, risk: .readOnly, projectRequirement: .none,
        localOnly: false, usesNetwork: true, access: .none,
        permissions: [try! PermissionRequirement(.machineInformation, .access)])
    }
    result += [
      "policy.probe"
    ].map { id in
      PermissionMigrationTool(
        id: id, risk: .readOnly, projectRequirement: .optional,
        localOnly: false, usesNetwork: false, access: .none,
        permissions: [])
    }
    result += [
      "env.describe",
      "service.status",
    ].map { id in
      PermissionMigrationTool(
        id: id, risk: .readOnly, projectRequirement: .optional,
        localOnly: false, usesNetwork: false, access: .none,
        permissions: [try! PermissionRequirement(.machineInformation, .access)])
    }
    result += [
      "logs.query"
    ].map { id in
      PermissionMigrationTool(
        id: id, risk: .readOnly, projectRequirement: .optional,
        localOnly: false, usesNetwork: false, access: .none,
        permissions: [try! PermissionRequirement(.unifiedLogs, .access)])
    }
    result += [
      "archive.list",
      "archive.read_file",
      "csv.read",
      "image.info",
      "json.read",
      "jsonl.read",
      "markdown.frontmatter",
      "markdown.link_check",
      "markdown.links",
      "markdown.section",
      "markdown.tables",
      "media.info",
      "pdf.info",
      "pdf.text",
      "plist.read",
      "sqlite.query",
      "sqlite.schema",
      "structured.get",
      "toml.read",
      "xml.read",
      "yaml.read",
    ].map { id in
      PermissionMigrationTool(
        id: id, risk: .readOnly, projectRequirement: .optional,
        localOnly: false, usesNetwork: false, access: .read,
        permissions: [])
    }
    result += [
      "runtime.owners.call"
    ].map { id in
      PermissionMigrationTool(
        id: id, risk: .readOnly, projectRequirement: .required,
        localOnly: false, usesNetwork: false, access: .none,
        permissions: [])
    }
    result += [
      "delivery.scopes.list",
      "file.compare_trees",
      "file.count",
      "file.diff",
      "file.disk_usage",
      "file.duplicates",
      "file.exists",
      "file.find",
      "file.hash",
      "file.head",
      "file.hexdump",
      "file.list",
      "file.metadata",
      "file.outline",
      "file.permissions",
      "file.read",
      "file.read_context",
      "file.read_files",
      "file.read_lines",
      "file.read_window",
      "file.readlink",
      "file.resolve",
      "file.search",
      "file.stat",
      "file.tail",
      "file.timeline",
      "file.tree",
      "file.type",
      "file.volume_info",
      "file.xattrs",
      "git.blame",
      "git.branch",
      "git.clean_preview",
      "git.commit_files",
      "git.compare_refs",
      "git.config",
      "git.conflicts",
      "git.diff",
      "git.diff_check",
      "git.diff_summary",
      "git.file_at_revision",
      "git.file_history",
      "git.files",
      "git.grep",
      "git.ignored",
      "git.is_ancestor",
      "git.log",
      "git.merge_base",
      "git.reflog",
      "git.refs",
      "git.remotes",
      "git.resolve_ref",
      "git.root",
      "git.show",
      "git.staged_file",
      "git.stash_show",
      "git.stashes",
      "git.status",
      "git.submodules",
      "git.tag_show",
      "git.tags",
      "git.tracking_status",
      "git.worktrees",
      "process.list",
      "process.read",
      "project.agent_files",
      "project.archive_files",
      "project.artifact_directories",
      "project.asset_files",
      "project.ci_files",
      "project.commands",
      "project.config_files",
      "project.data_files",
      "project.dependency_files",
      "project.directory_stats",
      "project.documentation_files",
      "project.empty_directories",
      "project.env_files",
      "project.executable_files",
      "project.file_types",
      "project.git_changes",
      "project.ignore_files",
      "project.info",
      "project.infra_files",
      "project.instructions",
      "project.large_files",
      "project.log_files",
      "project.manifests",
      "project.outline",
      "project.project_roots",
      "project.recent_files",
      "project.schema_files",
      "project.source_files",
      "project.status",
      "project.symlinks",
      "project.test_files",
      "project.todos",
      "runtime.owners.list",
    ].map { id in
      PermissionMigrationTool(
        id: id, risk: .readOnly, projectRequirement: .required,
        localOnly: false, usesNetwork: false, access: .read,
        permissions: [])
    }
    return result
  }()
}
