import Foundation

public enum CapabilityFixtureExecution: Equatable, Sendable {
  case direct
  case committed
}

public struct CapabilityFixtureInvocation: Equatable, Sendable {
  public var arguments: [String: JSONValue]
  public var expectedMarker: String?
  public var execution: CapabilityFixtureExecution

  public init(
    arguments: [String: JSONValue],
    expectedMarker: String? = nil,
    execution: CapabilityFixtureExecution = .direct
  ) {
    self.arguments = arguments
    self.expectedMarker = expectedMarker
    self.execution = execution
  }
}

public struct CapabilityFixturePlan: Sendable {
  public var workspaceID: String
  public var repositoryWorkspaceID: String?
  public var fixturePrefix: String
  public var skillRootID: String
  public var skillName: String
  public var skillHeading: String
  public var skillContentMarker: String
  public var skillSectionMarker: String
  public var skillSearchQuery: String
  public var skillSecondaryPath: String
  public var accessibilityProcessID: Int32
  public var loopbackHTTPURL: URL?

  public init(
    workspaceID: String,
    repositoryWorkspaceID: String? = nil,
    fixturePrefix: String = ".build/validation/fixtures",
    skillRootID: String = "codex-user",
    skillName: String = "github-swift-package-issue-workflow",
    skillHeading: String = "Operating Rules",
    skillContentMarker: String = "GitHub Swift Package",
    skillSectionMarker: String = "Keep changes minimal",
    skillSearchQuery: String = "Swift package maintenance",
    skillSecondaryPath: String = "agents/openai.yaml",
    accessibilityProcessID: Int32,
    loopbackHTTPURL: URL? = nil
  ) {
    self.workspaceID = workspaceID
    self.repositoryWorkspaceID = repositoryWorkspaceID
    self.fixturePrefix = fixturePrefix
    self.skillRootID = skillRootID
    self.skillName = skillName
    self.skillHeading = skillHeading
    self.skillContentMarker = skillContentMarker
    self.skillSectionMarker = skillSectionMarker
    self.skillSearchQuery = skillSearchQuery
    self.skillSecondaryPath = skillSecondaryPath
    self.accessibilityProcessID = accessibilityProcessID
    self.loopbackHTTPURL = loopbackHTTPURL
  }

  public func invocation(
    for tool: String,
    pointerPosition: (x: Double, y: Double)? = nil
  ) -> CapabilityFixtureInvocation? {
    switch tool {
    case "workspace.list":
      return invocation([:], marker: workspaceID)
    case "workspace.describe":
      return primary([:], marker: workspaceID)
    case "policy.probe":
      return invocation(
        ["capability_id": .string("workspace.list")],
        marker: "allowed"
      )
    case "process.list":
      return primary([:], marker: "processes")

    case "codex.app.status":
      return primary([:])
    case "codex.app.methods.list":
      return primary([:], marker: "thread/list")
    case "codex.app.methods.describe":
      return primary(["method": .string("thread/list")], marker: "thread/list")
    case "codex.app.methods.call":
      return primary(
        [
          "method": .string("thread/list"),
          "params": .object(["limit": .number(1)]),
        ],
        marker: "data"
      )
    case "codex.app.thread.list":
      return primary(["limit": .number(20)])
    case "codex.app.models.list":
      return primary(["limit": .number(20)])
    case "codex.app.skills.list":
      return primary(["force_reload": .bool(false)])
    case "codex.app.apps.list":
      return primary(
        [
          "force_refetch": .bool(false),
          "limit": .number(1),
        ],
        marker: "data"
      )
    case "codex.app.events.read":
      return primary([
        "after_cursor": .number(0),
        "max_results": .number(20),
      ])
    case "codex.app.requests.list":
      return primary([:])
    case "codex.exec.list":
      return primary([:])
    case "codex.mcp.status", "codex.mcp.tools.list", "codex.mcp.calls.list":
      return primary([:])

    case "mcp.servers.list":
      return invocation([:], marker: "fixture-stdio")
    case "mcp.servers.status":
      return invocation(["server": .string("fixture-stdio")], marker: "fixture-stdio")
    case "mcp.tools.list":
      return invocation(["server": .string("fixture-stdio")], marker: "fixture_echo")
    case "mcp.tools.describe":
      return invocation(
        [
          "server": .string("fixture-stdio"),
          "tool": .string("fixture_echo"),
        ],
        marker: "fixture_echo"
      )
    case "mcp.tools.find":
      return invocation(
        [
          "server": .string("fixture-stdio"),
          "query": .string("fixture_echo"),
          "field": .string("name"),
          "match": .string("exact"),
          "max_results": .number(10),
        ],
        marker: "fixture_echo"
      )
    case "mcp.resources.list":
      return invocation(["server": .string("fixture-stdio")], marker: "fixture://sample")
    case "mcp.resources.templates.list":
      return invocation(["server": .string("fixture-stdio")], marker: "fixture://{name}")
    case "mcp.resources.read":
      return invocation(
        [
          "server": .string("fixture-stdio"),
          "uri": .string("fixture://sample"),
        ],
        marker: "resource:fixture://sample"
      )
    case "mcp.prompts.list":
      return invocation(["server": .string("fixture-stdio")], marker: "fixture_prompt")
    case "mcp.prompts.get":
      return invocation(
        [
          "server": .string("fixture-stdio"),
          "name": .string("fixture_prompt"),
          "arguments": .object(["value": .string("CMCP-VALIDATION-PROMPT")]),
        ],
        marker: "prompt:CMCP-VALIDATION-PROMPT"
      )
    case "mcp.events.read":
      return invocation(
        [
          "server": .string("fixture-stdio"),
          "after_cursor": .number(0),
          "max_results": .number(20),
        ],
        marker: "fixture-stdio"
      )
    case "mcp.requests.list":
      return invocation(["server": .string("fixture-stdio")], marker: "fixture-stdio")
    case "mcp.tools.call":
      return CapabilityFixtureInvocation(
        arguments: [
          "server": .string("fixture-stdio"),
          "tool": .string("fixture_echo"),
          "arguments": .object([
            "value": .string("CMCP-VALIDATION-DOWNSTREAM-CALL")
          ]),
          "wait_for_result": .bool(true),
        ],
        expectedMarker: "CMCP-VALIDATION-DOWNSTREAM-CALL",
        execution: .committed
      )

    case "cli.list":
      return invocation([:], marker: "git")
    case "cli.describe":
      return invocation(["id": .string("git")], marker: "git")
    case "cli.status":
      return invocation(["id": .string("git")], marker: "is_executable")
    case "cli.help":
      return invocation(["id": .string("git")], marker: "cli.exec")

    case "skills.roots":
      return invocation([:], marker: skillRootID)
    case "skills.list":
      return skill([:], includeName: false, marker: skillName)
    case "skills.describe", "skills.validate", "skills.read":
      return skill([:], marker: skillName)
    case "skills.frontmatter":
      return skill(["path": .string("SKILL.md")], marker: "description")
    case "skills.files":
      return skill(["max_depth": .number(3)], marker: "SKILL.md")
    case "skills.read_file":
      return skill(["path": .string("SKILL.md")], marker: skillContentMarker)
    case "skills.read_files":
      return skill(
        [
          "paths": .array([
            .string("SKILL.md"),
            .string(skillSecondaryPath),
          ])
        ],
        marker: "SKILL.md"
      )
    case "skills.read_package":
      return skill(
        [
          "max_depth": .number(3),
          "max_files": .number(16),
          "max_total_bytes": .number(65_536),
        ],
        marker: skillSecondaryPath
      )
    case "skills.outline":
      return skill(["path": .string("SKILL.md")], marker: skillHeading)
    case "skills.section":
      return skill(
        [
          "path": .string("SKILL.md"),
          "heading": .string(skillHeading),
        ],
        marker: skillSectionMarker
      )
    case "skills.tables":
      return skill(["path": .string("SKILL.md")], marker: "skills.tables")
    case "skills.links":
      return skill(["path": .string("SKILL.md")], marker: "skills.links")
    case "skills.link_check":
      return skill(["path": .string("SKILL.md")], marker: "skills.link_check")
    case "skills.search":
      return invocation(
        [
          "root_id": .string(skillRootID),
          "query": .string(skillSearchQuery),
          "search_content": .bool(true),
          "max_results": .number(20),
        ],
        marker: skillName
      )
    case "skills.search_files":
      return skill(
        [
          "query": .string(skillSearchQuery),
          "search_content": .bool(true),
          "max_results": .number(20),
        ],
        marker: "SKILL.md"
      )

    case "workspace.git_changes":
      return repository([:], marker: "workspace.git_changes")
    case "workspace.info":
      return primary([:], marker: "workspace")
    case "workspace.status":
      return primary(["max_entries": .number(100)], marker: "workspace.status")
    case "workspace.manifests":
      return primary([:], marker: "Package.swift")
    case "workspace.executable_files":
      return primary(["include_hidden": .bool(true)], marker: "fixture.sh")
    case "workspace.file_types":
      return primary([:], marker: "workspace.file_types")
    case "workspace.large_files":
      return primary([:], marker: "workspace.large_files")
    case "workspace.recent_files":
      return primary([:], marker: "workspace.recent_files")
    case "workspace.symlinks":
      return primary(["include_hidden": .bool(true)], marker: "Links/readme.md")
    case "workspace.instructions":
      return primary(
        [
          "path": .string(path("AGENTS.md")),
          "path_is_directory": .bool(false),
          "include_content": .bool(true),
        ],
        marker: "deterministic and bounded"
      )
    case "workspace.commands":
      return primary(
        [
          "path": .string(path(".")),
          "max_depth": .number(4),
        ],
        marker: "Package.swift"
      )
    case "workspace.todos":
      return primary(
        [
          "path": .string(path("Sources")),
          "max_depth": .number(2),
        ],
        marker: "TODO"
      )
    case "workspace.open":
      return primary(
        [
          "path": .string(path("README.md")),
          "timeout_ms": .number(5_000),
        ],
        marker: "README.md"
      )
    case "workspace.reveal":
      return primary(
        [
          "path": .string(path("README.md")),
          "timeout_ms": .number(5_000),
        ],
        marker: "README.md"
      )
    case "workspace.agent_files":
      return workspaceScan(tool, path: path("."), marker: "AGENTS.md")
    case "workspace.archive_files":
      return workspaceScan(tool, path: path("."), marker: "sample.zip")
    case "workspace.artifact_directories":
      return workspaceScan(tool, path: path("."), marker: "build")
    case "workspace.asset_files":
      return workspaceScan(tool, path: path("."), marker: "pixel.png")
    case "workspace.ci_files":
      return workspaceScan(tool, path: path("."), marker: "ci.yml")
    case "workspace.config_files":
      return workspaceScan(tool, path: path("."), marker: ".swift-format")
    case "workspace.data_files":
      return workspaceScan(tool, path: path("."), marker: "sample.json")
    case "workspace.dependency_files":
      return workspaceScan(tool, path: path("."), marker: "Package.swift")
    case "workspace.directory_stats":
      return workspaceScan(tool, path: path("."), marker: "directory")
    case "workspace.documentation_files":
      return workspaceScan(tool, path: path("."), marker: "README.md")
    case "workspace.empty_directories":
      return workspaceScan(tool, path: path("."), marker: "Empty")
    case "workspace.env_files":
      return workspaceScan(tool, path: path("."), marker: ".env.example")
    case "workspace.governance_files":
      return workspaceScan(tool, path: path("."), marker: "CODEOWNERS")
    case "workspace.ignore_files":
      return workspaceScan(tool, path: path("."), marker: ".gitignore")
    case "workspace.infra_files":
      return workspaceScan(tool, path: path("."), marker: "Dockerfile")
    case "workspace.log_files":
      return workspaceScan(tool, path: path("."), marker: "sample.log")
    case "workspace.outline":
      return workspaceScan(tool, path: path("."), marker: "struct")
    case "workspace.project_roots":
      return workspaceScan(tool, path: path("."), marker: "Package.swift")
    case "workspace.schema_files":
      return workspaceScan(tool, path: path("."), marker: "fixture.schema.json")
    case "workspace.source_files":
      return workspaceScan(tool, path: path("."), marker: "main.swift")
    case "workspace.test_files":
      return workspaceScan(tool, path: path("."), marker: "FixtureTests.swift")

    case "archive.list":
      return primary(
        ["path": .string(path("Artifacts/sample.zip"))],
        marker: "ArchiveSource/hello.txt"
      )
    case "archive.read_file":
      return primary(
        [
          "path": .string(path("Artifacts/sample.zip")),
          "entry": .string("ArchiveSource/hello.txt"),
        ],
        marker: "hello from archive"
      )
    case "archive.create":
      return committedPrimary(
        [
          "path": .string(path("Mutations/generated.zip")),
          "sources": .array([.string(path("ArchiveSource"))]),
          "dry_run": .bool(false),
          "confirm_create": .bool(true),
          "create_directories": .bool(true),
          "overwrite": .bool(false),
        ],
        marker: "Mutations/generated.zip"
      )
    case "archive.extract":
      return committedPrimary(
        [
          "path": .string(path("Artifacts/sample.zip")),
          "destination": .string(path("Mutations/extracted")),
          "dry_run": .bool(false),
          "confirm_extract": .bool(true),
          "create_directories": .bool(true),
          "overwrite": .bool(false),
        ],
        marker: "Mutations/extracted"
      )
    case "file.compare_trees":
      return primary(
        [
          "left": .string(path("Duplicates")),
          "right": .string(path("Text")),
          "max_depth": .number(2),
        ],
        marker: "file.compare_trees"
      )
    case "file.count":
      return primary(["path": .string(path("Text/lines.txt"))], marker: "5")
    case "file.diff":
      return primary(
        [
          "source": .string(path("Duplicates/first.txt")),
          "target": .string(path("Text/lines.txt")),
        ],
        marker: "duplicate-content"
      )
    case "file.disk_usage":
      return primary(["path": .string(path("."))], marker: "file.disk_usage")
    case "file.duplicates":
      return primary(
        ["path": .string(path("Duplicates"))],
        marker: "first.txt"
      )
    case "file.exists":
      return primary(["path": .string(path("README.md"))], marker: "\"exists\":true")
    case "file.stat":
      return primary(["path": .string(path("README.md"))], marker: "\"type\":\"file\"")
    case "file.permissions":
      return primary(["path": .string(path("README.md"))], marker: "mode_octal")
    case "file.xattrs":
      return primary(["path": .string(path("README.md"))], marker: "attributes")
    case "file.metadata", "file.type", "file.volume_info":
      return primary(["path": .string(path("README.md"))], marker: tool)
    case "file.find":
      return primary(
        [
          "path": .string(path("Docs")),
          "query": .string("guide.md"),
        ],
        marker: "guide.md"
      )
    case "file.hash":
      return primary(["path": .string(path("README.md"))], marker: "sha256")
    case "file.head":
      return primary(
        [
          "path": .string(path("Text/lines.txt")),
          "max_lines": .number(2),
        ],
        marker: "alpha"
      )
    case "file.hexdump":
      return primary(
        [
          "path": .string(path("Text/lines.txt")),
          "max_bytes": .number(16),
        ],
        marker: "61 6c 70 68 61"
      )
    case "file.list":
      return primary(
        [
          "path": .string(path("Data")),
          "recursive_depth": .number(1),
        ],
        marker: "sample.json"
      )
    case "file.outline":
      return primary(
        ["path": .string(path("Sources/main.swift"))],
        marker: "main.swift"
      )
    case "file.read":
      return primary(
        ["path": .string(path("Docs/guide.md"))],
        marker: "CMCP-FIXTURE-ALPHA"
      )
    case "file.read_context":
      return primary(
        [
          "path": .string(path("Text/lines.txt")),
          "line": .number(3),
          "before": .number(1),
          "after": .number(1),
        ],
        marker: "gamma"
      )
    case "file.read_files":
      return primary(
        [
          "paths": .array([
            .string(path("README.md")),
            .string(path("Docs/guide.md")),
          ])
        ],
        marker: "CMCP-FIXTURE-ALPHA"
      )
    case "file.read_lines":
      return primary(
        [
          "path": .string(path("Text/lines.txt")),
          "start_line": .number(2),
          "max_lines": .number(2),
        ],
        marker: "beta"
      )
    case "file.read_window":
      return primary(
        [
          "path": .string(path("Text/lines.txt")),
          "offset_bytes": .number(0),
          "max_bytes": .number(32),
        ],
        marker: "alpha"
      )
    case "file.readlink":
      return primary(
        ["path": .string(path("Links/readme.md"))],
        marker: "../README.md"
      )
    case "file.resolve":
      return primary(
        ["path": .string(path("Links/readme.md"))],
        marker: "README.md"
      )
    case "file.search":
      return primary(
        [
          "path": .string(path("Docs")),
          "query": .string("CMCP-FIXTURE-ALPHA"),
        ],
        marker: "CMCP-FIXTURE-ALPHA"
      )
    case "file.tail":
      return primary(
        [
          "path": .string(path("Text/lines.txt")),
          "max_lines": .number(2),
        ],
        marker: "epsilon"
      )
    case "file.timeline":
      return primary(
        [
          "path": .string(path(".")),
          "max_depth": .number(3),
          "max_results": .number(100),
        ],
        marker: "file.timeline"
      )
    case "file.tree":
      return primary(
        [
          "path": .string(path(".")),
          "max_depth": .number(3),
        ],
        marker: "Data"
      )
    case "file.append":
      return primary(
        [
          "path": .string(path("Mutations/append.txt")),
          "content": .string("CMCP-VALIDATION-APPEND"),
          "append_newline": .bool(true),
          "create_if_missing": .bool(true),
          "create_directories": .bool(true),
        ],
        marker: "Mutations/append.txt"
      )
    case "file.chmod":
      return committedPrimary(
        [
          "path": .string(path("Scripts/fixture.sh")),
          "mode": .string("0700"),
          "expected_current_mode": .string("0755"),
        ],
        marker: "Scripts/fixture.sh"
      )
    case "file.copy":
      return committedPrimary(
        [
          "source": .string(path("README.md")),
          "destination": .string(path("Mutations/copied.md")),
          "create_directories": .bool(true),
          "overwrite": .bool(false),
        ],
        marker: "Mutations/copied.md"
      )
    case "file.download":
      guard let loopbackHTTPURL else {
        return nil
      }
      return committedPrimary(
        [
          "url": .string(loopbackHTTPURL.appendingPathComponent("README.md").absoluteString),
          "path": .string(path("Mutations/downloaded.md")),
          "dry_run": .bool(false),
          "confirm_download": .bool(true),
          "create_directories": .bool(true),
          "overwrite": .bool(false),
          "max_download_bytes": .number(65_536),
        ],
        marker: "Mutations/downloaded.md"
      )
    case "file.insert_text":
      return committedPrimary(
        [
          "path": .string(path("Text/lines.txt")),
          "line": .number(2),
          "position": .string("before"),
          "content": .string("CMCP-VALIDATION-INSERT"),
        ],
        marker: "Text/lines.txt"
      )
    case "file.mkdir":
      return primary(
        ["path": .string(path("Mutations/directory"))],
        marker: "Mutations/directory"
      )
    case "file.move":
      return committedPrimary(
        [
          "source": .string(path("Mutations/copied.md")),
          "destination": .string(path("Mutations/moved.md")),
          "overwrite": .bool(false),
        ],
        marker: "Mutations/moved.md"
      )
    case "file.remove_xattr":
      return committedPrimary(
        [
          "path": .string(path("Xattrs/tagged.txt")),
          "name": .string("com.showxu.computer-mcp.fixture"),
        ],
        marker: "com.showxu.computer-mcp.fixture"
      )
    case "file.replace_lines":
      return committedPrimary(
        [
          "path": .string(path("Text/lines.txt")),
          "start_line": .number(3),
          "end_line": .number(3),
          "content": .string("CMCP-VALIDATION-REPLACED-LINE"),
        ],
        marker: "Text/lines.txt"
      )
    case "file.replace_text":
      return committedPrimary(
        [
          "path": .string(path("Docs/guide.md")),
          "search": .string("CMCP-FIXTURE-ALPHA"),
          "replacement": .string("CMCP-VALIDATION-REPLACED-TEXT"),
          "expected_replacements": .number(1),
        ],
        marker: "Docs/guide.md"
      )
    case "file.symlink":
      return primary(
        [
          "path": .string(path("Mutations/readme-link.md")),
          "destination": .string("../README.md"),
          "create_directories": .bool(true),
          "overwrite": .bool(false),
        ],
        marker: "Mutations/readme-link.md"
      )
    case "file.touch":
      return committedPrimary(
        [
          "path": .string(path("Mutations/touched.txt")),
          "create_directories": .bool(true),
          "create_if_missing": .bool(true),
        ],
        marker: "Mutations/touched.txt"
      )
    case "file.trash":
      return committedPrimary(
        ["path": .string(path("Mutations/moved.md"))],
        marker: "Mutations/moved.md"
      )
    case "file.write":
      return committedPrimary(
        [
          "path": .string(path("Mutations/write.txt")),
          "content": .string("CMCP-VALIDATION-WRITE\n"),
          "create_directories": .bool(true),
          "overwrite": .bool(false),
        ],
        marker: "Mutations/write.txt"
      )
    case "file.write_files":
      return committedPrimary(
        [
          "files": .array([
            .object([
              "path": .string(path("Mutations/batch-a.txt")),
              "content": .string("CMCP-VALIDATION-BATCH-A\n"),
            ]),
            .object([
              "path": .string(path("Mutations/batch-b.txt")),
              "content": .string("CMCP-VALIDATION-BATCH-B\n"),
            ]),
          ]),
          "dry_run": .bool(false),
          "confirm_write": .bool(true),
          "create_directories": .bool(true),
          "overwrite": .bool(false),
        ],
        marker: "Mutations/batch-a.txt"
      )

    case "csv.read":
      return primary(["path": .string(path("Data/sample.csv"))], marker: "gamma")
    case "image.info":
      return primary(["path": .string(path("Artifacts/pixel.png"))], marker: "1")
    case "json.read":
      return primary(["path": .string(path("Data/sample.json"))], marker: "computer-mcp")
    case "json.write":
      return committedPrimary(
        [
          "path": .string(path("Mutations/generated.json")),
          "value": .object([
            "marker": .string("CMCP-VALIDATION-JSON-WRITE")
          ]),
          "dry_run": .bool(false),
          "confirm_write": .bool(true),
          "create_directories": .bool(true),
          "overwrite": .bool(false),
        ],
        marker: "Mutations/generated.json"
      )
    case "jsonl.read":
      return primary(["path": .string(path("Data/sample.jsonl"))], marker: "gamma")
    case "markdown.frontmatter":
      return primary(
        ["path": .string(path("Skills/fixture-skill/SKILL.md"))], marker: "fixture-skill")
    case "markdown.link_check":
      return primary(["path": .string(path("README.md"))], marker: "markdown.link_check")
    case "markdown.links":
      return primary(["path": .string(path("README.md"))], marker: "Docs/guide.md")
    case "markdown.section":
      return primary(
        [
          "path": .string(path("README.md")),
          "heading": .string("Links"),
        ],
        marker: "Local guide"
      )
    case "markdown.tables":
      return primary(["path": .string(path("README.md"))], marker: "Capability")
    case "media.info":
      return primary(["path": .string(path("Artifacts/silence.wav"))], marker: "audio")
    case "pdf.info":
      return primary(["path": .string(path("Artifacts/report.pdf"))], marker: "2")
    case "pdf.text":
      return primary(
        ["path": .string(path("Artifacts/report.pdf"))],
        marker: "Computer MCP fixture PDF page two"
      )
    case "plist.read":
      return primary(["path": .string(path("Data/sample.plist"))], marker: "computer-mcp")
    case "plist.write":
      return committedPrimary(
        [
          "path": .string(path("Mutations/generated.plist")),
          "value": .object([
            "marker": .string("CMCP-VALIDATION-PLIST-WRITE")
          ]),
          "dry_run": .bool(false),
          "confirm_write": .bool(true),
          "create_directories": .bool(true),
          "overwrite": .bool(false),
        ],
        marker: "Mutations/generated.plist"
      )
    case "sqlite.query":
      return primary(
        [
          "path": .string(path("Data/sample.sqlite")),
          "query": .string("SELECT id, name, enabled FROM items ORDER BY id"),
        ],
        marker: "gamma"
      )
    case "sqlite.schema":
      return primary(["path": .string(path("Data/sample.sqlite"))], marker: "items")
    case "structured.get":
      return primary(
        [
          "path": .string(path("Data/sample.json")),
          "query_path": .array([
            .string("items"),
            .number(1),
          ]),
        ],
        marker: "beta"
      )
    case "toml.read":
      return primary(["path": .string(path("Data/sample.toml"))], marker: "computer-mcp")
    case "xml.read":
      return primary(["path": .string(path("Data/sample.xml"))], marker: "alpha")
    case "yaml.read":
      return primary(["path": .string(path("Data/sample.yaml"))], marker: "computer-mcp")

    case "git.blame":
      return repository(["path": .string("Sources/main.swift")], marker: "git.blame")
    case "git.branch":
      return repository([:], marker: "main")
    case "git.clean_preview":
      return repository([:], marker: "untracked.txt")
    case "git.compare_refs":
      return repository(
        [
          "base": .string("fixture-base"),
          "head": .string("main"),
        ],
        marker: "Second fixture revision"
      )
    case "git.config":
      return repository(
        [
          "scope": .string("local"),
          "include_values": .bool(false),
        ],
        marker: "user.name"
      )
    case "git.conflicts":
      return repository([:], marker: tool)
    case "git.diff", "git.diff_check", "git.diff_summary":
      return repository([:], marker: tool)
    case "git.file_at_revision":
      return repository(
        [
          "revision": .string("HEAD"),
          "path": .string("README.md"),
        ],
        marker: "Second committed revision"
      )
    case "git.file_history":
      return repository(["path": .string("README.md")], marker: "Second fixture revision")
    case "git.files":
      return repository([:], marker: "README.md")
    case "git.grep":
      return repository(
        ["query": .string("fixture repository")],
        marker: "Sources/main.swift"
      )
    case "git.ignored":
      return repository(
        ["paths": .array([.string(".fixture-ignored")])],
        marker: ".fixture-ignored"
      )
    case "git.is_ancestor":
      return repository(
        [
          "ancestor": .string("fixture-base"),
          "descendant": .string("main"),
        ],
        marker: "true"
      )
    case "git.log":
      return repository([:], marker: "Second fixture revision")
    case "git.commit_files":
      return repository(["revision": .string("HEAD")], marker: "README.md")
    case "git.merge_base":
      return repository(
        ["refs": .array([.string("fixture-base"), .string("main")])],
        marker: "merge_base"
      )
    case "git.reflog":
      return repository([:], marker: "commit")
    case "git.refs":
      return repository([:], marker: "fixture-base")
    case "git.remotes":
      return repository([:], marker: "origin")
    case "git.resolve_ref":
      return repository(["ref": .string("main")], marker: "git.resolve_ref")
    case "git.root":
      return repository([:], marker: "Repository")
    case "git.show":
      return repository(
        [
          "revision": .string("HEAD"),
          "patch": .bool(false),
        ],
        marker: "Second fixture revision"
      )
    case "git.staged_file":
      return repository(["path": .string("staged.txt")], marker: "staged fixture")
    case "git.stash_show":
      return repository(
        [
          "stash": .string("stash@{0}"),
          "patch": .bool(true),
        ],
        marker: "Temporary stash revision"
      )
    case "git.stashes":
      return repository([:], marker: "Fixture stash")
    case "git.status":
      return repository([:], marker: "untracked.txt")
    case "git.submodules":
      return repository([:], marker: tool)
    case "git.tag_show":
      return repository(["name": .string("v0.1.0")], marker: "Fixture release")
    case "git.tags":
      return repository([:], marker: "v0.1.0")
    case "git.tracking_status":
      return repository([:], marker: "upstream")
    case "git.worktrees":
      return repository([:], marker: "main")
    case "git.branch_create":
      return repository(
        [
          "name": .string("validation-created"),
          "dry_run": .bool(false),
          "confirm_create": .bool(true),
        ],
        marker: "validation-created"
      )
    case "git.branch_rename":
      return committedRepository(
        [
          "old_name": .string("fixture-base"),
          "new_name": .string("fixture-base-renamed"),
          "dry_run": .bool(false),
          "confirm_rename": .bool(true),
          "force": .bool(false),
        ],
        marker: "fixture-base-renamed"
      )
    case "git.branch_switch":
      return committedRepository(
        [
          "name": .string("fixture-base-renamed"),
          "dry_run": .bool(false),
          "confirm_switch": .bool(true),
          "allow_dirty": .bool(true),
        ],
        marker: "fixture-base-renamed"
      )
    case "git.branch_delete":
      return committedRepository(
        [
          "name": .string("validation-created"),
          "dry_run": .bool(false),
          "confirm_delete": .bool(true),
          "force": .bool(true),
        ],
        marker: "validation-created"
      )
    case "git.clean":
      return committedRepository(
        [
          "paths": .array([.string(".fixture-ignored")]),
          "ignored_only": .bool(true),
          "dry_run": .bool(false),
          "confirm_delete": .bool(true),
        ],
        marker: ".fixture-ignored"
      )
    case "git.tag_create":
      return repository(
        [
          "name": .string("validation-tag"),
          "dry_run": .bool(false),
          "confirm_create": .bool(true),
        ],
        marker: "validation-tag"
      )
    case "git.tag_delete":
      return committedRepository(
        [
          "name": .string("validation-tag"),
          "dry_run": .bool(false),
          "confirm_delete": .bool(true),
        ],
        marker: "validation-tag"
      )
    case "git.restore_worktree":
      return committedRepository(
        [
          "paths": .array([.string("README.md")]),
          "dry_run": .bool(false),
          "confirm_discard": .bool(true),
        ],
        marker: "README.md"
      )
    case "git.add":
      return committedRepository(
        [
          "paths": .array([.string("untracked.txt")]),
          "dry_run": .bool(false),
        ],
        marker: "untracked.txt"
      )
    case "git.stash_push":
      return committedRepository(
        [
          "message": .string("Validation mutation stash"),
          "paths": .array([.string("Sources/main.swift")]),
          "keep_index": .bool(true),
          "dry_run": .bool(false),
        ],
        marker: "Validation mutation stash"
      )
    case "git.unstage":
      return committedRepository(
        [
          "paths": .array([
            .string("staged.txt"),
            .string("untracked.txt"),
          ]),
          "dry_run": .bool(false),
        ],
        marker: "staged.txt"
      )
    case "git.commit":
      return repository(
        [
          "message": .string("Validation empty commit"),
          "allow_empty": .bool(true),
          "dry_run": .bool(false),
        ],
        marker: "Validation empty commit"
      )

    case "env.describe":
      return primary([:], marker: "\"values_redacted\":true")
    case "logs.query":
      return primary(
        [
          "last_seconds": .number(60),
          "max_entries": .number(20),
        ],
        marker: "logs.query"
      )
    case "service.status":
      return primary(
        [
          "domain": .string("system"),
          "label": .string("com.apple.cfprefsd.xpc.daemon"),
        ],
        marker: "service.status"
      )

    case "system.which":
      return invocation(["name": .string("git")], marker: "system.which")
    case "system.path":
      return invocation(["max_entries": .number(32)], marker: "system.path")
    case "system.processes":
      return invocation(["max_results": .number(20)], marker: "system.processes")
    case "system.info":
      return invocation([:], marker: "macOS")
    case "system.time":
      return invocation([:], marker: "time_zone")
    case "system.volumes":
      return invocation([:], marker: "volume_count")
    case let systemTool where systemTool.hasPrefix("system."):
      return invocation([:], marker: systemTool)

    case "network.http_check":
      guard let loopbackHTTPURL else {
        return nil
      }
      return invocation(
        [
          "url": .string(loopbackHTTPURL.absoluteString),
          "include_body": .bool(false),
        ],
        marker: "network.http_check"
      )
    case "network.ping":
      return invocation(
        [
          "host": .string("127.0.0.1"),
          "count": .number(1),
        ],
        marker: "127.0.0.1"
      )
    case "network.resolve":
      return invocation(["host": .string("localhost")], marker: "127.0.0.1")
    case "network.tcp_check":
      guard let loopbackHTTPURL, let port = loopbackHTTPURL.port else {
        return nil
      }
      return invocation(
        [
          "host": .string(loopbackHTTPURL.host ?? "127.0.0.1"),
          "port": .number(Double(port)),
        ],
        marker: "network.tcp_check"
      )
    case let networkTool where networkTool.hasPrefix("network."):
      return invocation([:], marker: networkTool)

    case "macos.default_application":
      return invocation(
        ["url": .string("https://example.invalid")],
        marker: "macos.default_application"
      )
    case "macos.spotlight_search":
      return invocation(
        [
          "query": .string("Safari"),
          "max_results": .number(10),
        ],
        marker: "Safari"
      )
    case "macos.applications":
      return invocation(["max_results": .number(20)], marker: "application_count")
    case "macos.running_applications":
      return invocation(
        [
          "query": .string("Computer MCP"),
          "max_results": .number(20),
        ],
        marker: "Computer MCP"
      )
    case "macos.frontmost_application":
      return invocation([:], marker: "\"available\":true")
    case "macos.screens":
      return invocation([:], marker: "screen_count")
    case let macOSTool where macOSTool.hasPrefix("macos."):
      return invocation([:], marker: macOSTool)

    case "computer.permissions", "computer.displays", "computer.pointer.position":
      return invocation([:])
    case "computer.screenshot":
      return invocation([
        "target": .string("display"),
        "max_width": .number(320),
        "max_height": .number(240),
        "max_bytes": .number(262_144),
        "shows_cursor": .bool(false),
      ])
    case "computer.windows":
      return invocation([
        "on_screen_only": .bool(true),
        "exclude_desktop_elements": .bool(true),
        "max_results": .number(20),
      ])
    case "computer.accessibility.query":
      return invocation([
        "process_id": .number(Double(accessibilityProcessID)),
        "max_depth": .number(2),
        "max_results": .number(10),
        "max_scanned_elements": .number(100),
      ])
    case "computer.verify":
      guard let pointerPosition else {
        return nil
      }
      return invocation([
        "verification": .object([
          "type": .string("pointer-position"),
          "point": .object([
            "x": .number(pointerPosition.x),
            "y": .number(pointerPosition.y),
          ]),
          "tolerance": .number(1),
        ]),
        "policy": .object([
          "timeout_milliseconds": .number(0),
          "poll_interval_milliseconds": .number(20),
        ]),
      ])
    default:
      return nil
    }
  }

  public func codexThreadArchiveInvocation(threadID: String) -> CapabilityFixtureInvocation {
    primary([
      "method": .string("thread/archive"),
      "params": .object(["threadId": .string(threadID)]),
    ])
  }

  private func workspaceScan(
    _ tool: String,
    path: String,
    marker: String
  ) -> CapabilityFixtureInvocation {
    primary(
      [
        "path": .string(path),
        "max_depth": .number(4),
        "max_results": .number(100),
        "max_scan_entries": .number(5_000),
      ],
      marker: marker.isEmpty ? tool : marker
    )
  }

  private func primary(
    _ arguments: [String: JSONValue],
    marker: String? = nil
  ) -> CapabilityFixtureInvocation {
    invocation(
      arguments.merging(["workspace_id": .string(workspaceID)]) { current, _ in current },
      marker: marker
    )
  }

  private func repository(
    _ arguments: [String: JSONValue],
    marker: String? = nil
  ) -> CapabilityFixtureInvocation? {
    guard let repositoryWorkspaceID else {
      return nil
    }
    return invocation(
      arguments.merging(["workspace_id": .string(repositoryWorkspaceID)]) { current, _ in current },
      marker: marker
    )
  }

  private func committedRepository(
    _ arguments: [String: JSONValue],
    marker: String? = nil
  ) -> CapabilityFixtureInvocation? {
    guard let repositoryWorkspaceID else {
      return nil
    }
    return CapabilityFixtureInvocation(
      arguments: arguments.merging(["workspace_id": .string(repositoryWorkspaceID)]) {
        current, _ in current
      },
      expectedMarker: marker,
      execution: .committed
    )
  }

  private func committedPrimary(
    _ arguments: [String: JSONValue],
    marker: String? = nil
  ) -> CapabilityFixtureInvocation {
    CapabilityFixtureInvocation(
      arguments: arguments.merging(["workspace_id": .string(workspaceID)]) { current, _ in
        current
      },
      expectedMarker: marker,
      execution: .committed
    )
  }

  private func skill(
    _ arguments: [String: JSONValue],
    includeName: Bool = true,
    marker: String? = nil
  ) -> CapabilityFixtureInvocation {
    var bound = arguments
    bound["root_id"] = .string(skillRootID)
    if includeName {
      bound["name"] = .string(skillName)
    }
    return invocation(bound, marker: marker)
  }

  private func invocation(
    _ arguments: [String: JSONValue],
    marker: String? = nil
  ) -> CapabilityFixtureInvocation {
    CapabilityFixtureInvocation(arguments: arguments, expectedMarker: marker)
  }

  private func path(_ relativePath: String) -> String {
    let prefix = fixturePrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let relative = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if prefix.isEmpty || prefix == "." {
      return relative.isEmpty || relative == "." ? "." : relative
    }
    if relative.isEmpty || relative == "." {
      return prefix
    }
    return "\(prefix)/\(relative)"
  }
}
