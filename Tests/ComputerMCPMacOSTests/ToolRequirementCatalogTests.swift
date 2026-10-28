import ComputerMCPCore
import ComputerMCPPermissions
import Foundation
import Testing

/// The accepted catalog access table, independent of provider factories and effect annotations.
struct ToolRequirementCatalogTests {
  @Test
  func completeCatalogHasTheReviewedAccessContract() throws {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/builtin-tool-catalog.json")
    let catalog = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: file))
    var reviewed: Set<String> = []
    for (access, names) in Self.accessTable {
      for name in names.split(whereSeparator: \.isWhitespace).map(String.init) {
        #expect(reviewed.insert(name).inserted)
        let entry = try #require(catalog[name])
        let requirement = try JSONDecoder().decode(
          ToolRequirement.self,
          from: JSONEncoder().encode(
            try #require(entry.objectValue?["capability"]?.objectValue?["requirement"])))
        #expect(requirement.access == access, "Access mismatch: \(name)")
        let schema = try #require(entry.objectValue?["inputSchema"])
        let properties = schema.objectValue?["properties"]?.objectValue ?? [:]
        let fullAccess = Set(
          "git.branch_create git.branch_rename git.branch_switch git.tag_create git.tag_delete git.stash_push plugin.install plugin.update plugin.configure plugin.enable plugin.disable plugin.uninstall project.add project.grant project.remove project.repair"
            .split(separator: " ").map(String.init))
        #expect(
          requirement.requiresFullAccess == fullAccess.contains(name),
          "Full access mismatch: \(name)")
        switch requirement.execution {
        case .read(let key), .input(let key), .cancel(let key):
          #expect(properties[key]?.objectValue?["type"] == .string("string"))
        case .none, .start, .list: break
        }
        if let url = requirement.networkURL {
          #expect(properties[url]?.objectValue?["type"] == .string("string"))
        }
        for path in requirement.paths {
          switch path.relativeBase {
          case .deliveryScope(let key), .linkParent(let key): #expect(properties[key] != nil)
          case .project: break
          }
          guard case .argument(let selector) = path.source else { continue }
          var selected = schema
          for part in selector.split(separator: ".") {
            let array = part.hasSuffix("[]")
            let key = array ? String(part.dropLast(2)) : String(part)
            selected = try #require(selected.objectValue?["properties"]?.objectValue?[key])
            if array { selected = try #require(selected.objectValue?["items"]) }
          }
          #expect(selected.objectValue?["type"] == .string("string"))
        }
        let exactPaths: [String: [ToolRequirement.Path]] = [
          "git.tag_create": [.project(.read)],
          "file.diff": [.init("source", .read), .init("target", .read)],
          "file.write_files": [.init("files[].path", .write)],
          "json.read": [.init("path", .read)],
          "delivery.apply": [
            .init("edits[].path", .write, relativeBase: .deliveryScope(argument: "scope"))
          ],
        ]
        if let expected = exactPaths[name] { #expect(requirement.paths == expected) }
        func check(_ object: ToolRequirement.Object) {
          switch object {
          case .argument(let key):
            #expect(properties[key] != nil, "Missing selector: \(name).\(key)")
          case .skill(let nameKey, let rootKey):
            #expect(properties[nameKey] != nil && properties[rootKey] != nil)
          case .registered, .catalog: break
          }
        }
        switch requirement.target {
        case .none: break
        case .mcp(let object, _): check(object)
        case .forwarded(let tool, let arguments, let server):
          #expect(properties[tool] != nil && properties[arguments] != nil)
          if let server { #expect(properties[server] != nil) }
        }
        switch requirement.contribution {
        case .cli(let object), .skills(let object), .mcp(let object): check(object)
        case nil: break
        }
        let privacy: Permission?
        if name.hasPrefix("computer.") {
          privacy =
            entry.objectValue?["annotations"]?.objectValue?["readOnlyHint"] == .bool(true)
            ? .screen : .desktopControl
        } else if name.hasPrefix("skills.") {
          privacy = .skills
        } else if name == "logs.query" {
          privacy = .unifiedLogs
        } else if ["project.open", "project.reveal"].contains(name) {
          privacy = .desktopControl
        } else if name.hasPrefix("system.") || name.hasPrefix("macos.")
          || name.hasPrefix("network.")
          || [
            "env.describe", "service.status", "cli.list", "cli.status", "cli.describe", "cli.help",
            "plugin.list", "plugin.describe", "plugin.search", "plugin.artifacts",
          ].contains(name)
        {
          privacy = .machineInformation
        } else {
          privacy = nil
        }
        #expect(
          requirement.permissions
            == (try privacy.map { [try PermissionRequirement($0, .access)] } ?? []),
          "Privacy mismatch: \(name)")
      }
    }
    let shell = try #require(catalog["shell.run"]?.objectValue?["description"]?.stringValue)
    #expect(shell.contains("Sandbox") && shell.contains("consented Full access"))
    #expect(shell.contains("Project permissions") && shell.contains("execution limits"))
    #expect(reviewed == Set(catalog.keys))
  }

  private static let accessTable: [(ToolRequirement.Access, String)] = [
    (
      .none,
      """
      cli.describe cli.help cli.list cli.status computer.accessibility.action
      computer.accessibility.query computer.displays computer.keyboard.key computer.keyboard.text
      computer.permissions computer.pointer.click computer.pointer.move computer.pointer.position
      computer.screenshot computer.scroll computer.verify computer.windows env.describe logs.query
      macos.applications macos.default_application macos.frontmost_application
      macos.running_applications macos.screens macos.spotlight_search macos.user_directories
      mcp.connections.close mcp.events.read mcp.prompts.get mcp.prompts.list mcp.requests.cancel
      mcp.requests.list mcp.requests.read mcp.resources.list mcp.resources.read
      mcp.resources.templates.list mcp.servers.list mcp.servers.status mcp.tools.call
      mcp.tools.describe mcp.tools.find mcp.tools.list network.arp network.connections network.dns
      network.hardware_ports network.http_check network.interfaces network.listeners
      network.locations network.ping network.proxy network.resolve network.routes network.services
      network.tcp_check network.vpn network.wifi
      plugin.artifacts plugin.configure plugin.describe plugin.disable plugin.enable
      plugin.install plugin.list plugin.search plugin.uninstall plugin.update policy.probe
      profile.limit profile.show project.add project.describe project.grant project.list
      project.open project.remove project.repair project.request project.reveal runtime.owners.call service.status
      skills.describe
      skills.files skills.frontmatter skills.link_check skills.links skills.list skills.outline
      skills.read skills.read_file skills.read_files skills.read_package skills.roots
      skills.search skills.search_files skills.section skills.tables skills.validate system.cpu
      system.groups system.info system.kernel system.load system.locale system.memory system.path
      system.power system.processes system.software system.thermal system.time system.uptime
      system.user system.volumes system.which
      """
    ),
    (
      .read,
      """
      archive.list archive.read_file csv.read delivery.scopes.list file.compare_trees file.count
      file.diff file.disk_usage file.duplicates file.exists file.find file.hash file.head
      file.hexdump file.list file.metadata file.outline file.permissions file.read
      file.read_context file.read_files file.read_lines file.read_window file.readlink
      file.resolve file.search file.stat file.tail file.timeline file.tree file.type
      file.volume_info file.xattrs git.blame git.branch git.clean_preview git.commit_files
      git.compare_refs git.config git.conflicts git.diff git.diff_check git.diff_summary
      git.file_at_revision git.file_history git.files git.grep git.ignored git.is_ancestor git.log
      git.merge_base git.reflog git.refs git.remotes git.resolve_ref git.root git.show
      git.staged_file git.stash_show git.stashes git.status git.submodules git.tag_show git.tags
      git.tracking_status git.worktree_list image.info json.read jsonl.read markdown.frontmatter
      markdown.link_check markdown.links markdown.section markdown.tables media.info pdf.info
      pdf.text plist.read process.list process.read project.agent_files project.archive_files
      project.artifact_directories project.asset_files project.ci_files project.commands
      project.config_files project.data_files project.dependency_files project.directory_stats
      project.documentation_files project.empty_directories project.env_files
      project.executable_files project.file_types project.git_changes project.ignore_files
      project.info project.infra_files project.instructions project.large_files project.log_files
      project.manifests project.outline project.project_roots project.recent_files
      project.schema_files project.source_files project.status project.symlinks
      project.test_files project.todos runtime.owners.list shell.list shell.read sqlite.query
      sqlite.schema structured.get toml.read xml.read yaml.read
      """
    ),
    (
      .projectWrite,
      """
      archive.create archive.extract cli.exec delivery.apply file.append file.chmod file.copy
      file.download file.insert_text file.mkdir file.move file.remove_xattr file.replace_lines
      file.replace_text file.symlink file.touch file.trash file.write file.write_files git.worktree_remove git.add
      git.branch_create git.branch_rename git.branch_switch git.clean git.commit
      git.restore_worktree git.stash_push git.tag_create git.tag_delete git.unstage json.write
      plist.write process.cancel process.spawn process.write shell.cancel shell.run shell.spawn
      shell.write
      """
    ),
    (
      .sourceProjectWrite,
      """
      git.branch_delete git.worktree_add git.merge
      """
    ),
  ]
}
