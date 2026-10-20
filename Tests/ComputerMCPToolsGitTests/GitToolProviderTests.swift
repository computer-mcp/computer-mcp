import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPProcess
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPToolsGit

@Suite(.nativeIntegration, .serialized)
final class GitToolProviderTests {
  @Test
  func alreadyCancelledCommitDoesNotReachRunner() async {
    let runner = RecordingCommandRunner()
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: .fixture(
          cli: .init(commands: [.init(id: "git", executable: "/usr/bin/git")]),
          builtin: .init(enabled: ["git.commit"])),
        commandRunner: runner))
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await provider.callToolAsync(
        .init(
          name: "git.commit", arguments: .object(["message": .string("Update fixture")]),
          context: .empty))
    }

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(runner.calls.isEmpty)
  }

  @Test
  func testGitBuiltinsAreExposedOnlyWhenEnabled() throws {
    let disabled = GitToolProvider(environment: ToolEnvironment(configuration: .fixture()))
    #expect(!(try disabled.definitions().map(\.tool).map(\.name).contains("git.status")))

    let enabled = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          builtin: BuiltinConfig(enabled: [
            "git.root", "git.config", "git.remotes", "git.worktrees", "git.stashes",
            "git.stash_show",
            "git.tags",
            "git.tag_show", "git.tag_create", "git.tag_delete", "git.ignored", "git.submodules",
            "git.files", "git.grep", "git.blame", "git.file_history",
            "git.file_at_revision", "git.staged_file", "git.conflicts", "git.status",
            "git.tracking_status", "git.clean_preview", "git.clean", "git.reflog", "git.refs",
            "git.resolve_ref", "git.merge_base", "git.compare_refs", "git.is_ancestor", "git.diff",
            "git.diff_summary", "git.diff_check", "git.branch", "git.branch_create",
            "git.branch_delete", "git.branch_rename", "git.branch_switch", "git.log",
            "git.commit_files", "git.show",
            "git.add", "git.unstage", "git.restore_worktree", "git.commit", "git.stash_push",
          ])
        )
      ))
    let names = try enabled.definitions().map(\.tool).map(\.name)

    #expect(names.contains("git.root"))
    #expect(names.contains("git.config"))
    #expect(names.contains("git.remotes"))
    #expect(names.contains("git.worktrees"))
    #expect(names.contains("git.stashes"))
    #expect(names.contains("git.stash_show"))
    #expect(names.contains("git.stash_push"))
    #expect(names.contains("git.tags"))
    #expect(names.contains("git.tag_show"))
    #expect(names.contains("git.tag_create"))
    #expect(names.contains("git.tag_delete"))
    #expect(names.contains("git.ignored"))
    #expect(names.contains("git.submodules"))
    #expect(names.contains("git.files"))
    #expect(names.contains("git.grep"))
    #expect(names.contains("git.blame"))
    #expect(names.contains("git.file_history"))
    #expect(names.contains("git.file_at_revision"))
    #expect(names.contains("git.staged_file"))
    #expect(names.contains("git.conflicts"))
    #expect(names.contains("git.status"))
    #expect(names.contains("git.tracking_status"))
    #expect(names.contains("git.clean_preview"))
    #expect(names.contains("git.clean"))
    #expect(names.contains("git.reflog"))
    #expect(names.contains("git.refs"))
    #expect(names.contains("git.resolve_ref"))
    #expect(names.contains("git.merge_base"))
    #expect(names.contains("git.compare_refs"))
    #expect(names.contains("git.is_ancestor"))
    #expect(names.contains("git.diff"))
    #expect(names.contains("git.diff_summary"))
    #expect(names.contains("git.diff_check"))
    #expect(names.contains("git.branch"))
    #expect(names.contains("git.branch_create"))
    #expect(names.contains("git.branch_delete"))
    #expect(names.contains("git.branch_rename"))
    #expect(names.contains("git.branch_switch"))
    #expect(names.contains("git.log"))
    #expect(names.contains("git.commit_files"))
    #expect(names.contains("git.show"))
    #expect(names.contains("git.add"))
    #expect(names.contains("git.unstage"))
    #expect(names.contains("git.restore_worktree"))
    #expect(names.contains("git.commit"))

    let gitAdd = try #require(enabled.definitions().map(\.tool).first { $0.name == "git.add" })
    let gitUnstage = try #require(
      enabled.definitions().map(\.tool).first { $0.name == "git.unstage" })
    let gitRestoreWorktree = try #require(
      enabled.definitions().map(\.tool).first { $0.name == "git.restore_worktree" })
    let gitCommit = try #require(
      enabled.definitions().map(\.tool).first { $0.name == "git.commit" })
    let gitClean = try #require(enabled.definitions().map(\.tool).first { $0.name == "git.clean" })
    let gitStashShow = try #require(
      enabled.definitions().map(\.tool).first { $0.name == "git.stash_show" })
    let gitStashPush = try #require(
      enabled.definitions().map(\.tool).first { $0.name == "git.stash_push" })
    let gitTagShow = try #require(
      enabled.definitions().map(\.tool).first { $0.name == "git.tag_show" })
    let gitTagCreate = try #require(
      enabled.definitions().map(\.tool).first { $0.name == "git.tag_create" })
    let gitTagDelete = try #require(
      enabled.definitions().map(\.tool).first { $0.name == "git.tag_delete" })
    let gitBranchCreate = try #require(
      enabled.definitions().map(\.tool).first { $0.name == "git.branch_create" })
    let gitBranchDelete = try #require(
      enabled.definitions().map(\.tool).first { $0.name == "git.branch_delete" })
    let gitBranchRename = try #require(
      enabled.definitions().map(\.tool).first { $0.name == "git.branch_rename" })
    let gitBranchSwitch = try #require(
      enabled.definitions().map(\.tool).first { $0.name == "git.branch_switch" })
    let gitConfig = try #require(
      enabled.definitions().map(\.tool).first { $0.name == "git.config" })
    let addProperties = gitAdd.inputSchema.objectValue?["properties"]?.objectValue
    let unstageProperties = gitUnstage.inputSchema.objectValue?["properties"]?.objectValue
    let restoreWorktreeProperties =
      gitRestoreWorktree.inputSchema.objectValue?["properties"]?.objectValue
    let commitProperties = gitCommit.inputSchema.objectValue?["properties"]?.objectValue
    let cleanProperties = gitClean.inputSchema.objectValue?["properties"]?.objectValue
    let stashShowProperties = gitStashShow.inputSchema.objectValue?["properties"]?.objectValue
    let stashPushProperties = gitStashPush.inputSchema.objectValue?["properties"]?.objectValue
    let tagShowProperties = gitTagShow.inputSchema.objectValue?["properties"]?.objectValue
    let tagCreateProperties = gitTagCreate.inputSchema.objectValue?["properties"]?.objectValue
    let tagDeleteProperties = gitTagDelete.inputSchema.objectValue?["properties"]?.objectValue
    let branchCreateProperties =
      gitBranchCreate.inputSchema.objectValue?["properties"]?.objectValue
    let branchDeleteProperties =
      gitBranchDelete.inputSchema.objectValue?["properties"]?.objectValue
    let branchRenameProperties =
      gitBranchRename.inputSchema.objectValue?["properties"]?.objectValue
    let branchSwitchProperties =
      gitBranchSwitch.inputSchema.objectValue?["properties"]?.objectValue
    let configProperties = gitConfig.inputSchema.objectValue?["properties"]?.objectValue
    #expect((addProperties?["dry_run"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((unstageProperties?["dry_run"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((restoreWorktreeProperties?["dry_run"]?.objectValue?["type"]) == (.string("boolean")))
    #expect(
      (restoreWorktreeProperties?["confirm_discard"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((commitProperties?["dry_run"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((cleanProperties?["dry_run"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((cleanProperties?["confirm_delete"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((cleanProperties?["all_paths"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((stashShowProperties?["stash"]?.objectValue?["type"]) == (.string("string")))
    #expect((stashShowProperties?["patch"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((stashPushProperties?["dry_run"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((tagShowProperties?["name"]?.objectValue?["type"]) == (.string("string")))
    #expect((tagShowProperties?["stat"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((tagCreateProperties?["name"]?.objectValue?["type"]) == (.string("string")))
    #expect((tagCreateProperties?["target"]?.objectValue?["type"]) == (.string("string")))
    #expect((tagCreateProperties?["dry_run"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((tagCreateProperties?["confirm_create"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((tagDeleteProperties?["name"]?.objectValue?["type"]) == (.string("string")))
    #expect((tagDeleteProperties?["dry_run"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((tagDeleteProperties?["confirm_delete"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((branchCreateProperties?["name"]?.objectValue?["type"]) == (.string("string")))
    #expect((branchCreateProperties?["dry_run"]?.objectValue?["type"]) == (.string("boolean")))
    #expect(
      (branchCreateProperties?["confirm_create"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((branchDeleteProperties?["name"]?.objectValue?["type"]) == (.string("string")))
    #expect((branchDeleteProperties?["force"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((branchDeleteProperties?["dry_run"]?.objectValue?["type"]) == (.string("boolean")))
    #expect(
      (branchDeleteProperties?["confirm_delete"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((branchRenameProperties?["old_name"]?.objectValue?["type"]) == (.string("string")))
    #expect((branchRenameProperties?["new_name"]?.objectValue?["type"]) == (.string("string")))
    #expect((branchRenameProperties?["force"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((branchRenameProperties?["dry_run"]?.objectValue?["type"]) == (.string("boolean")))
    #expect(
      (branchRenameProperties?["confirm_rename"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((branchSwitchProperties?["name"]?.objectValue?["type"]) == (.string("string")))
    #expect((branchSwitchProperties?["dry_run"]?.objectValue?["type"]) == (.string("boolean")))
    #expect(
      (branchSwitchProperties?["confirm_switch"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((branchSwitchProperties?["allow_dirty"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((configProperties?["include_values"]?.objectValue?["type"]) == (.string("boolean")))
    #expect((configProperties?["scope"]?.objectValue?["type"]) == (.string("string")))
  }

  @Test
  func testGitRootUsesRegisteredGitProvider() throws {
    let runner = RecordingCommandRunner()
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.root"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(name: "git.root", arguments: .object([:]), context: .empty))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/bin/echo"))
    #expect(
      (runner.calls.first?.arguments)
        == ([
          "rev-parse",
          "--show-toplevel",
          "--git-dir",
          "--git-common-dir",
          "--is-inside-work-tree",
          "--is-bare-repository",
          "--show-prefix",
        ]))
    #expect((payload.objectValue?["operation"]) == (.string("git.root")))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([
          .string("rev-parse"),
          .string("--show-toplevel"),
          .string("--git-dir"),
          .string("--git-common-dir"),
          .string("--is-inside-work-tree"),
          .string("--is-bare-repository"),
          .string("--show-prefix"),
        ])))
  }

  @Test
  func testGitConfigParsesStructuredEntriesAndRedactsValues() throws {
    let runner = RecordingCommandRunner()
    runner.stdout =
      "system\0file:/etc/gitconfig\0core.autocrlf\ninput\0"
      + "global\0file:/Users/example/.gitconfig\0user.email\nuser@example.com\0"
      + "global\0file:/Users/example/.gitconfig\0credential.helper\nosxkeychain\0"
      + "local\0file:.git/config\0remote.origin.url\nhttps://github.com/example/repo.git\0"
      + "local\0file:.git/config\0http.extraheader\nAUTHORIZATION: bearer abc123\0"
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.config"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.config",
        arguments: .object([
          "include_values": .bool(true),
          "max_results": .number(10),
          "timeout_ms": .number(1234),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let entries = try #require(payload.objectValue?["entries"]?.arrayValue)
    let entryObjects = entries.compactMap(\.objectValue)

    #expect((runner.calls.first?.executable) == ("/bin/echo"))
    #expect(
      (runner.calls.first?.arguments)
        == (["config", "--list", "--show-origin", "--show-scope", "--null"]))
    #expect((runner.calls.first?.timeoutMilliseconds) == (1234))
    #expect((payload.objectValue?["operation"]) == (.string("git.config")))
    #expect((payload.objectValue?["entry_count"]) == (.number(5)))
    #expect((payload.objectValue?["returned_count"]) == (.number(5)))
    #expect((payload.objectValue?["redacted_count"]) == (.number(2)))
    #expect((payload.objectValue?["parse_incomplete"]) == (.bool(false)))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout"]) == (nil))

    let emailEntry = try #require(
      entryObjects.first { $0["key"] == .string("user.email") })
    #expect((emailEntry["scope"]) == (.string("global")))
    #expect((emailEntry["origin"]) == (.string("file:/Users/example/.gitconfig")))
    #expect((emailEntry["value"]) == (.string("user@example.com")))
    #expect((emailEntry["value_included"]) == (.bool(true)))
    #expect((emailEntry["value_redacted"]) == (.bool(false)))

    let credentialEntry = try #require(
      entryObjects.first { $0["key"] == .string("credential.helper") })
    #expect((credentialEntry["value"]) == (.null))
    #expect((credentialEntry["value_included"]) == (.bool(false)))
    #expect((credentialEntry["value_redacted"]) == (.bool(true)))

    let headerEntry = try #require(
      entryObjects.first { $0["key"] == .string("http.extraheader") })
    #expect((headerEntry["value"]) == (.null))
    #expect((headerEntry["value_redacted"]) == (.bool(true)))
  }

  @Test
  func testGitConfigFiltersScopeAndRejectsBadInputs() throws {
    let runner = RecordingCommandRunner()
    runner.stdout =
      "system\0file:/etc/gitconfig\0core.autocrlf\ninput\0"
      + "global\0file:/Users/example/.gitconfig\0user.name\nExample\0"
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.config"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.config",
        arguments: .object([
          "scope": .string("global"),
          "max_results": .number(1),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let entries = try #require(payload.objectValue?["entries"]?.arrayValue)
    let firstEntry = try #require(entries.first?.objectValue)

    #expect((payload.objectValue?["scope"]) == (.string("global")))
    #expect((payload.objectValue?["entry_count"]) == (.number(1)))
    #expect((firstEntry["key"]) == (.string("user.name")))
    #expect((firstEntry["value"]) == (.null))
    #expect((firstEntry["value_redacted"]) == (.bool(true)))

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.config",
          arguments: .object(["scope": .string("repo")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("scope"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.config",
          arguments: .object(["max_results": .number(0)]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_results"))
    }
  }

  @Test
  func testGitRemotesUsesRegisteredGitProvider() throws {
    let runner = RecordingCommandRunner()
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.remotes"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.remotes", arguments: .object([:]), context: .empty))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/bin/echo"))
    #expect((runner.calls.first?.arguments) == (["remote", "--verbose"]))
    #expect((payload.objectValue?["operation"]) == (.string("git.remotes")))
    #expect((payload.objectValue?["argv"]) == (.array([.string("remote"), .string("--verbose")])))
  }

  @Test
  func testGitWorktreesUsesRegisteredGitProvider() throws {
    let runner = RecordingCommandRunner()
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.worktrees"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.worktrees", arguments: .object([:]), context: .empty))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/bin/echo"))
    #expect((runner.calls.first?.arguments) == (["worktree", "list", "--porcelain"]))
    #expect((payload.objectValue?["operation"]) == (.string("git.worktrees")))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([.string("worktree"), .string("list"), .string("--porcelain")])))
  }

  @Test
  func testGitStashesUsesRegisteredGitProvider() throws {
    let runner = RecordingCommandRunner()
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.stashes"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.stashes", arguments: .object([:]), context: .empty))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/bin/echo"))
    #expect((runner.calls.first?.arguments) == (["stash", "list", "--date=iso-strict"]))
    #expect((payload.objectValue?["operation"]) == (.string("git.stashes")))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([.string("stash"), .string("list"), .string("--date=iso-strict")])))
  }

  @Test
  func testGitStashShowBuildsReadOnlyArgv() throws {
    let runner = RecordingCommandRunner()
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.stash_show"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.stash_show",
        arguments: .object([
          "stash": .string("stash@{2}"),
          "stat": .bool(true),
          "patch": .bool(true),
          "context_lines": .number(1),
          "paths": .array([.string("Sources"), .string("README.md")]),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/bin/echo"))
    #expect(
      (runner.calls.first?.arguments)
        == ([
          "diff", "--stat", "--patch", "-U1", "stash@{2}^1", "stash@{2}", "--", "Sources",
          "README.md",
        ]))
    #expect((payload.objectValue?["operation"]) == (.string("git.stash_show")))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([
          .string("diff"), .string("--stat"), .string("--patch"), .string("-U1"),
          .string("stash@{2}^1"), .string("stash@{2}"), .string("--"), .string("Sources"),
          .string("README.md"),
        ])))
  }

  @Test
  func testGitStashShowDefaultsToLatestStatAndNameOnlyFallback() throws {
    let runner = RecordingCommandRunner()
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.stash_show"])
        ),
        commandRunner: runner
      ))

    _ = try provider.callTool(
      .init(name: "git.stash_show", arguments: .object([:]), context: .empty))
    _ = try provider.callTool(
      .init(
        name: "git.stash_show",
        arguments: .object([
          "stat": .bool(false),
          "patch": .bool(false),
        ]), context: .empty
      ))

    #expect((runner.calls[0].arguments) == (["stash", "show", "--stat", "stash@{0}"]))
    #expect((runner.calls[1].arguments) == (["stash", "show", "--name-only", "stash@{0}"]))
  }

  @Test
  func testGitStashPushBuildsWriteAndDryRunArgv() throws {
    let runner = RecordingCommandRunner()
    runner.outputs = [
      .init(stdout: "Sources/main.swift\0"),
      .init(stdout: "Saved working directory and index state"),
      .init(stdout: ""),
    ]
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.stash_push"])
        ),
        commandRunner: runner
      ))

    let writeResult = try provider.callTool(
      .init(
        name: "git.stash_push",
        arguments: .object([
          "message": .string("save focused work"),
          "paths": .array([.string("Sources"), .string("README.md")]),
          "include_untracked": .bool(true),
          "keep_index": .bool(true),
        ]), context: .empty
      ))
    let writePayload = try decodeTextPayload(writeResult)

    let dryRunResult = try provider.callTool(
      .init(
        name: "git.stash_push",
        arguments: .object([
          "message": .string("preview all work"),
          "all_paths": .bool(true),
          "dry_run": .bool(true),
        ]), context: .empty
      ))
    let dryRunPayload = try decodeTextPayload(dryRunResult)

    #expect((runner.calls[0].arguments) == (["ls-files", "-z", "--", "Sources", "README.md"]))
    #expect(
      (runner.calls[1].arguments)
        == ([
          "stash", "push", "-m", "save focused work", "--include-untracked", "--keep-index", "--",
          "Sources", "README.md",
        ]))
    #expect(
      (runner.calls[2].arguments) == (["status", "--porcelain=v1", "-z", "--untracked-files=no"]))
    #expect((writePayload.objectValue?["operation"]) == (.string("git.stash_push")))
    #expect((dryRunPayload.objectValue?["operation"]) == (.string("git.stash_push")))
    #expect((writePayload.objectValue?["dry_run"]) == (.bool(false)))
    #expect((dryRunPayload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((dryRunPayload.objectValue?["all_paths"]) == (.bool(true)))
    #expect((writePayload.objectValue?["effective_keep_index"]) == (.bool(true)))
    #expect(
      (writePayload.objectValue?["keep_index_omitted_for_untracked_only_paths"]) == (.bool(false)))
  }

  @Test
  func testGitStashPushOmitsKeepIndexForExplicitUntrackedOnlyPaths() throws {
    let runner = RecordingCommandRunner()
    runner.outputs = [
      .init(stdout: ""),
      .init(stdout: "Saved working directory and index state"),
    ]
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.stash_push"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.stash_push",
        arguments: .object([
          "message": .string("save untracked-only path"),
          "paths": .array([.string("untracked.txt")]),
          "include_untracked": .bool(true),
          "keep_index": .bool(true),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls[0].arguments) == (["ls-files", "-z", "--", "untracked.txt"]))
    #expect(
      (runner.calls[1].arguments)
        == ([
          "stash", "push", "-m", "save untracked-only path", "--include-untracked", "--",
          "untracked.txt",
        ]))
    #expect((payload.objectValue?["keep_index"]) == (.bool(true)))
    #expect((payload.objectValue?["effective_keep_index"]) == (.bool(false)))
    #expect((payload.objectValue?["keep_index_omitted_for_untracked_only_paths"]) == (.bool(true)))
  }

  @Test
  func testGitStashPushDryRunWithPathsIncludesUntrackedPreview() throws {
    let runner = RecordingCommandRunner()
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.stash_push"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.stash_push",
        arguments: .object([
          "message": .string("preview focused work"),
          "paths": .array([.string("Sources")]),
          "include_untracked": .bool(true),
          "dry_run": .bool(true),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect(
      (runner.calls.first?.arguments)
        == (["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", "Sources"]))
    #expect((payload.objectValue?["operation"]) == (.string("git.stash_push")))
    #expect((payload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((payload.objectValue?["include_untracked"]) == (.bool(true)))
  }

  @Test
  func testGitTagsUsesRegisteredGitProvider() throws {
    let runner = RecordingCommandRunner()
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.tags"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(name: "git.tags", arguments: .object([:]), context: .empty))
    let payload = try decodeTextPayload(result)
    let format =
      "--format=%(refname:short)%09%(objecttype)%09%(objectname:short)%09%(creatordate:iso-strict)%09%(subject)"

    #expect((runner.calls.first?.executable) == ("/bin/echo"))
    #expect((runner.calls.first?.arguments) == (["tag", "--list", "--sort=-creatordate", format]))
    #expect((payload.objectValue?["operation"]) == (.string("git.tags")))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([
          .string("tag"), .string("--list"), .string("--sort=-creatordate"), .string(format),
        ])))
  }

  @Test
  func testGitTagShowUsesLocalTagRef() throws {
    let runner = RecordingCommandRunner()
    runner.outputs = [
      RecordingCommandRunner.Output(stdout: "", exitCode: 0),
      RecordingCommandRunner.Output(stdout: "tag v1.0.0\ncommit abc123\n", exitCode: 0),
    ]
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.tag_show"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.tag_show",
        arguments: .object([
          "name": .string("v1.0.0"),
          "timeout_ms": .number(1234),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect(
      (runner.calls.map(\.arguments))
        == ([
          ["show-ref", "--verify", "--quiet", "refs/tags/v1.0.0"],
          ["show", "--date=iso-strict", "--stat", "refs/tags/v1.0.0"],
        ]))
    #expect((runner.calls.map(\.timeoutMilliseconds)) == ([1234, 1234]))
    #expect((payload.objectValue?["operation"]) == (.string("git.tag_show")))
    #expect((payload.objectValue?["provider"]) == (.string("git")))
    #expect((payload.objectValue?["name"]) == (.string("v1.0.0")))
    #expect((payload.objectValue?["ref"]) == (.string("refs/tags/v1.0.0")))
    #expect((payload.objectValue?["stat"]) == (.bool(true)))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([
          .string("show"), .string("--date=iso-strict"), .string("--stat"),
          .string("refs/tags/v1.0.0"),
        ])))
    #expect(
      (payload.objectValue?["result"]?.objectValue?["stdout"])
        == (.string("tag v1.0.0\ncommit abc123\n")))
  }

  @Test
  func testGitTagShowCanOmitStat() throws {
    let runner = RecordingCommandRunner()
    runner.outputs = [
      RecordingCommandRunner.Output(stdout: "", exitCode: 0),
      RecordingCommandRunner.Output(stdout: "commit abc123\n", exitCode: 0),
    ]
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.tag_show"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.tag_show",
        arguments: .object([
          "name": .string("v1.0.0"),
          "stat": .bool(false),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect(
      (runner.calls.map(\.arguments))
        == ([
          ["show-ref", "--verify", "--quiet", "refs/tags/v1.0.0"],
          ["show", "--date=iso-strict", "--no-patch", "refs/tags/v1.0.0"],
        ]))
    #expect((payload.objectValue?["stat"]) == (.bool(false)))
  }

  @Test
  func testGitTagShowRejectsUnsafeInputs() throws {
    let unsafeRunner = RecordingCommandRunner()
    let unsafeRegistry = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.tag_show"])
        ),
        commandRunner: unsafeRunner
      ))

    expectThrows(
      try unsafeRegistry.callTool(
        .init(
          name: "git.tag_show",
          arguments: .object(["name": .string("refs/tags/v1.0.0")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("not a full ref"))
      #expect(unsafeRunner.calls.isEmpty)
    }

    let missingTagRunner = RecordingCommandRunner()
    missingTagRunner.outputs = [RecordingCommandRunner.Output(stdout: "", exitCode: 1)]
    let missingTagRegistry = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.tag_show"])
        ),
        commandRunner: missingTagRunner
      ))

    expectThrows(
      try missingTagRegistry.callTool(
        .init(
          name: "git.tag_show",
          arguments: .object(["name": .string("v1.0.0")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("does not exist"))
      #expect((missingTagRunner.calls.count) == (1))
    }
  }

  @Test
  func testGitTagCreateDryRunPreflightsWithoutCreating() throws {
    let runner = RecordingCommandRunner()
    runner.outputs = [
      RecordingCommandRunner.Output(stdout: "v1.0.0\n"),
      RecordingCommandRunner.Output(stdout: String(repeating: "a", count: 40) + "\n"),
      RecordingCommandRunner.Output(stdout: "", exitCode: 1),
    ]
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.tag_create"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.tag_create",
        arguments: .object([
          "name": .string("v1.0.0"),
          "timeout_ms": .number(1234),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect(
      (runner.calls.map(\.arguments))
        == ([
          ["check-ref-format", "refs/tags/v1.0.0"],
          ["rev-parse", "--verify", "HEAD^{object}"],
          ["show-ref", "--verify", "--quiet", "refs/tags/v1.0.0"],
        ]))
    #expect((runner.calls.map(\.timeoutMilliseconds)) == ([1234, 1234, 1234]))
    #expect((payload.objectValue?["operation"]) == (.string("git.tag_create")))
    #expect((payload.objectValue?["provider"]) == (.string("git")))
    #expect((payload.objectValue?["name"]) == (.string("v1.0.0")))
    #expect((payload.objectValue?["target"]) == (.string("HEAD")))
    #expect((payload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((payload.objectValue?["confirm_create"]) == (.bool(false)))
    #expect((payload.objectValue?["result"]) == (.null))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([.string("tag"), .string("v1.0.0"), .string("HEAD")])))
  }

  @Test
  func testGitTagCreateRunsAfterConfirmation() throws {
    let runner = RecordingCommandRunner()
    runner.outputs = [
      RecordingCommandRunner.Output(stdout: "v1.0.0\n"),
      RecordingCommandRunner.Output(stdout: String(repeating: "b", count: 40) + "\n"),
      RecordingCommandRunner.Output(stdout: "", exitCode: 1),
      RecordingCommandRunner.Output(stdout: "", exitCode: 0),
    ]
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.tag_create"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.tag_create",
        arguments: .object([
          "name": .string("v1.0.0"),
          "target": .string("main"),
          "dry_run": .bool(false),
          "confirm_create": .bool(true),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect(
      (runner.calls.map(\.arguments))
        == ([
          ["check-ref-format", "refs/tags/v1.0.0"],
          ["rev-parse", "--verify", "main^{object}"],
          ["show-ref", "--verify", "--quiet", "refs/tags/v1.0.0"],
          ["tag", "v1.0.0", "main"],
        ]))
    #expect((payload.objectValue?["dry_run"]) == (.bool(false)))
    #expect((payload.objectValue?["confirm_create"]) == (.bool(true)))
    #expect(
      (payload.objectValue?["result"]?.objectValue?["arguments"])
        == (.array([.string("tag"), .string("v1.0.0"), .string("main")])))
    #expect((payload.objectValue?["result"]?.objectValue?["exit_code"]) == (.number(0)))
  }

  @Test
  func testGitTagCreateRejectsUnsafeInputs() throws {
    let missingConfirmRunner = RecordingCommandRunner()
    let missingConfirmRegistry = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.tag_create"])
        ),
        commandRunner: missingConfirmRunner
      ))

    expectThrows(
      try missingConfirmRegistry.callTool(
        .init(
          name: "git.tag_create",
          arguments: .object([
            "name": .string("v1.0.0"),
            "dry_run": .bool(false),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("confirm_create"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    expectThrows(
      try missingConfirmRegistry.callTool(
        .init(
          name: "git.tag_create",
          arguments: .object(["name": .string("refs/tags/v1.0.0")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("not a full ref"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    let existingTagRunner = RecordingCommandRunner()
    existingTagRunner.outputs = [
      RecordingCommandRunner.Output(stdout: "v1.0.0\n"),
      RecordingCommandRunner.Output(stdout: String(repeating: "c", count: 40) + "\n"),
      RecordingCommandRunner.Output(stdout: "", exitCode: 0),
    ]
    let existingTagRegistry = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.tag_create"])
        ),
        commandRunner: existingTagRunner
      ))

    expectThrows(
      try existingTagRegistry.callTool(
        .init(
          name: "git.tag_create",
          arguments: .object(["name": .string("v1.0.0")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("already exists"))
      #expect((existingTagRunner.calls.count) == (3))
    }

    let badTargetRunner = RecordingCommandRunner()
    badTargetRunner.outputs = [
      RecordingCommandRunner.Output(stdout: "v1.0.0\n"),
      RecordingCommandRunner.Output(stdout: "", exitCode: 1),
    ]
    let badTargetRegistry = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.tag_create"])
        ),
        commandRunner: badTargetRunner
      ))

    expectThrows(
      try badTargetRegistry.callTool(
        .init(
          name: "git.tag_create",
          arguments: .object([
            "name": .string("v1.0.0"),
            "target": .string("missing-ref"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("target"))
      #expect((badTargetRunner.calls.count) == (2))
    }
  }

  @Test
  func testGitTagDeleteDryRunPreflightsWithoutDeleting() throws {
    let runner = RecordingCommandRunner()
    runner.outputs = [
      RecordingCommandRunner.Output(stdout: "", exitCode: 0),
      RecordingCommandRunner.Output(stdout: String(repeating: "d", count: 40) + "\n"),
    ]
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.tag_delete"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.tag_delete",
        arguments: .object([
          "name": .string("v1.0.0"),
          "timeout_ms": .number(1234),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect(
      (runner.calls.map(\.arguments))
        == ([
          ["show-ref", "--verify", "--quiet", "refs/tags/v1.0.0"],
          ["rev-parse", "--verify", "refs/tags/v1.0.0^{object}"],
        ]))
    #expect((runner.calls.map(\.timeoutMilliseconds)) == ([1234, 1234]))
    #expect((payload.objectValue?["operation"]) == (.string("git.tag_delete")))
    #expect((payload.objectValue?["provider"]) == (.string("git")))
    #expect((payload.objectValue?["name"]) == (.string("v1.0.0")))
    #expect((payload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((payload.objectValue?["confirm_delete"]) == (.bool(false)))
    #expect((payload.objectValue?["result"]) == (.null))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([.string("tag"), .string("-d"), .string("v1.0.0")])))
  }

  @Test
  func testGitTagDeleteRunsAfterConfirmation() throws {
    let runner = RecordingCommandRunner()
    runner.outputs = [
      RecordingCommandRunner.Output(stdout: "", exitCode: 0),
      RecordingCommandRunner.Output(stdout: String(repeating: "e", count: 40) + "\n"),
      RecordingCommandRunner.Output(stdout: "Deleted tag 'v1.0.0'\n", exitCode: 0),
    ]
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.tag_delete"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.tag_delete",
        arguments: .object([
          "name": .string("v1.0.0"),
          "dry_run": .bool(false),
          "confirm_delete": .bool(true),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect(
      (runner.calls.map(\.arguments))
        == ([
          ["show-ref", "--verify", "--quiet", "refs/tags/v1.0.0"],
          ["rev-parse", "--verify", "refs/tags/v1.0.0^{object}"],
          ["tag", "-d", "v1.0.0"],
        ]))
    #expect((payload.objectValue?["dry_run"]) == (.bool(false)))
    #expect((payload.objectValue?["confirm_delete"]) == (.bool(true)))
    #expect(
      (payload.objectValue?["result"]?.objectValue?["arguments"])
        == (.array([.string("tag"), .string("-d"), .string("v1.0.0")])))
    #expect((payload.objectValue?["result"]?.objectValue?["exit_code"]) == (.number(0)))
  }

  @Test
  func testGitTagDeleteRejectsUnsafeInputs() throws {
    let missingConfirmRunner = RecordingCommandRunner()
    let missingConfirmRegistry = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.tag_delete"])
        ),
        commandRunner: missingConfirmRunner
      ))

    expectThrows(
      try missingConfirmRegistry.callTool(
        .init(
          name: "git.tag_delete",
          arguments: .object([
            "name": .string("v1.0.0"),
            "dry_run": .bool(false),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("confirm_delete"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    expectThrows(
      try missingConfirmRegistry.callTool(
        .init(
          name: "git.tag_delete",
          arguments: .object(["name": .string("refs/tags/v1.0.0")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("not a full ref"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    let missingTagRunner = RecordingCommandRunner()
    missingTagRunner.outputs = [RecordingCommandRunner.Output(stdout: "", exitCode: 1)]
    let missingTagRegistry = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.tag_delete"])
        ),
        commandRunner: missingTagRunner
      ))

    expectThrows(
      try missingTagRegistry.callTool(
        .init(
          name: "git.tag_delete",
          arguments: .object(["name": .string("v1.0.0")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("does not exist"))
      #expect((missingTagRunner.calls.count) == (1))
    }

    let unresolvedTagRunner = RecordingCommandRunner()
    unresolvedTagRunner.outputs = [
      RecordingCommandRunner.Output(stdout: "", exitCode: 0),
      RecordingCommandRunner.Output(stdout: "", exitCode: 1),
    ]
    let unresolvedTagRegistry = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.tag_delete"])
        ),
        commandRunner: unresolvedTagRunner
      ))

    expectThrows(
      try unresolvedTagRegistry.callTool(
        .init(
          name: "git.tag_delete",
          arguments: .object(["name": .string("v1.0.0")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("cannot be resolved"))
      #expect((unresolvedTagRunner.calls.count) == (2))
    }
  }

  @Test
  func testGitIgnoredUsesRegisteredGitProvider() throws {
    let runner = RecordingCommandRunner()
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.ignored"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.ignored",
        arguments: .object(["paths": .array([.string("build/output.log"), .string(".env")])]),
        context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/bin/echo"))
    #expect(
      (runner.calls.first?.arguments)
        == (["check-ignore", "--verbose", "--", "build/output.log", ".env"]))
    #expect((payload.objectValue?["operation"]) == (.string("git.ignored")))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([
          .string("check-ignore"), .string("--verbose"), .string("--"), .string("build/output.log"),
          .string(".env"),
        ])))
  }

  @Test
  func testGitSubmodulesUsesRegisteredGitProvider() throws {
    let runner = RecordingCommandRunner()
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.submodules"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.submodules", arguments: .object([:]), context: .empty))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/bin/echo"))
    #expect((runner.calls.first?.arguments) == (["submodule", "status", "--recursive"]))
    #expect((payload.objectValue?["operation"]) == (.string("git.submodules")))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([.string("submodule"), .string("status"), .string("--recursive")])))
  }

  @Test
  func testGitFilesUsesRegisteredGitProvider() throws {
    let runner = RecordingCommandRunner()
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.files"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.files",
        arguments: .object(["paths": .array([.string("Sources"), .string("Package.swift")])]),
        context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/bin/echo"))
    #expect(
      (runner.calls.first?.arguments)
        == (["ls-files", "--stage", "--eol", "--", "Sources", "Package.swift"]))
    #expect((payload.objectValue?["operation"]) == (.string("git.files")))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([
          .string("ls-files"), .string("--stage"), .string("--eol"), .string("--"),
          .string("Sources"), .string("Package.swift"),
        ])))
  }

  @Test
  func testGitGrepParsesBoundedNullSeparatedMatches() throws {
    let runner = RecordingCommandRunner()
    runner.outputs = [
      RecordingCommandRunner.Output(
        stdout:
          "Sources/App.swift\010\0let needle = true\nTests/AppTests.swift\024\0#expect(needle)\n"
      )
    ]
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.grep"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.grep",
        arguments: .object([
          "query": .string("needle"),
          "paths": .array([.string("Sources"), .string("Tests")]),
          "case_sensitive": .bool(false),
          "max_results": .number(1),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let matches = try #require(payload.objectValue?["matches"]?.arrayValue)
    let first = try #require(matches.first?.objectValue)

    #expect((runner.calls.first?.executable) == ("/bin/echo"))
    #expect(
      (runner.calls.first?.arguments)
        == ([
          "grep", "--line-number", "-I", "--null", "--fixed-strings", "--max-count", "1",
          "--ignore-case", "-e", "needle", "--", "Sources", "Tests",
        ]))
    #expect((payload.objectValue?["operation"]) == (.string("git.grep")))
    #expect((payload.objectValue?["case_sensitive"]) == (.bool(false)))
    #expect((payload.objectValue?["match_count"]) == (.number(2)))
    #expect((payload.objectValue?["returned_count"]) == (.number(1)))
    #expect((payload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((payload.objectValue?["parse_incomplete"]) == (.bool(false)))
    #expect((first["workspace_relative_path"]) == (.string("Sources/App.swift")))
    #expect((first["line"]) == (.number(10)))
    #expect((first["text"]) == (.string("let needle = true")))
    #expect((first["read_context"]?.objectValue?["tool"]) == (.string("file.read_lines")))
    #expect((first["read_context"]?.objectValue?["path"]) == (.string("Sources/App.swift")))
  }

  @Test
  func testGitBlameUsesRegisteredGitProvider() throws {
    let runner = RecordingCommandRunner()
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.blame"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.blame",
        arguments: .object([
          "path": .string("Sources/main.swift"),
          "start_line": .number(10),
          "max_lines": .number(25),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/bin/echo"))
    #expect(
      (runner.calls.first?.arguments)
        == (["blame", "--line-porcelain", "-L", "10,+25", "--", "Sources/main.swift"]))
    #expect((payload.objectValue?["operation"]) == (.string("git.blame")))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([
          .string("blame"), .string("--line-porcelain"), .string("-L"), .string("10,+25"),
          .string("--"), .string("Sources/main.swift"),
        ])))
  }

  @Test
  func testGitFileHistoryParsesBoundedCommitRows() throws {
    let runner = RecordingCommandRunner()
    runner.stdout =
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\taaaaaaa\t2026-07-08T17:16:39+08:00\tAda\tupdate file\nbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\tbbbbbbb\t2026-07-08T17:15:00+08:00\tBen\tcreate file\n"
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.file_history"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.file_history",
        arguments: .object([
          "path": .string("Sources/main.swift"),
          "limit": .number(10),
          "max_results": .number(1),
          "follow": .bool(true),
          "include_merges": .bool(false),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let entries = try #require(payload.objectValue?["entries"]?.arrayValue)

    #expect(
      (runner.calls.first?.arguments)
        == ([
          "log",
          "--follow",
          "--date=iso-strict",
          "--pretty=format:%H%x09%h%x09%ad%x09%an%x09%s",
          "-n",
          "10",
          "--no-merges",
          "--",
          "Sources/main.swift",
        ]))
    #expect((payload.objectValue?["operation"]) == (.string("git.file_history")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("Sources/main.swift")))
    #expect((payload.objectValue?["follow"]) == (.bool(true)))
    #expect((payload.objectValue?["include_merges"]) == (.bool(false)))
    #expect((payload.objectValue?["entry_count"]) == (.number(2)))
    #expect((payload.objectValue?["returned_entry_count"]) == (.number(1)))
    #expect((payload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((entries[0].objectValue?["commit"]) == (.string(String(repeating: "a", count: 40))))
    #expect((entries[0].objectValue?["abbreviated_commit"]) == (.string("aaaaaaa")))
    #expect((entries[0].objectValue?["committed_at"]) == (.string("2026-07-08T17:16:39+08:00")))
    #expect((entries[0].objectValue?["author"]) == (.string("Ada")))
    #expect((entries[0].objectValue?["subject"]) == (.string("update file")))
  }

  @Test
  func testGitFileAtRevisionReturnsBoundedHistoricalContent() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = "line one\nline two\n"
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          policy: PolicyConfig(maxOutputBytes: 64),
          builtin: BuiltinConfig(enabled: ["git.file_at_revision"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.file_at_revision",
        arguments: .object([
          "revision": .string("HEAD"),
          "path": .string("Sources/main.swift"),
          "max_bytes": .number(8),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.arguments) == (["show", "HEAD:Sources/main.swift"]))
    #expect((payload.objectValue?["operation"]) == (.string("git.file_at_revision")))
    #expect((payload.objectValue?["revision"]) == (.string("HEAD")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("Sources/main.swift")))
    #expect((payload.objectValue?["object_spec"]) == (.string("HEAD:Sources/main.swift")))
    #expect((payload.objectValue?["content"]) == (.string("line one")))
    #expect((payload.objectValue?["bytes_returned"]) == (.number(8)))
    #expect((payload.objectValue?["content_truncated"]) == (.bool(true)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
  }

  @Test
  func testGitStagedFileReturnsBoundedIndexContent() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = "staged one\nstaged two\n"
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          policy: PolicyConfig(maxOutputBytes: 64),
          builtin: BuiltinConfig(enabled: ["git.staged_file"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.staged_file",
        arguments: .object([
          "path": .string("Sources/main.swift"),
          "max_bytes": .number(10),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.arguments) == (["show", ":Sources/main.swift"]))
    #expect((payload.objectValue?["operation"]) == (.string("git.staged_file")))
    #expect((payload.objectValue?["workspace_relative_path"]) == (.string("Sources/main.swift")))
    #expect((payload.objectValue?["object_spec"]) == (.string(":Sources/main.swift")))
    #expect((payload.objectValue?["source"]) == (.string("index")))
    #expect((payload.objectValue?["index_stage"]) == (.number(0)))
    #expect((payload.objectValue?["content"]) == (.string("staged one")))
    #expect((payload.objectValue?["bytes_returned"]) == (.number(10)))
    #expect((payload.objectValue?["content_truncated"]) == (.bool(true)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
  }

  @Test
  func testGitConflictsUsesRegisteredGitProvider() throws {
    let runner = RecordingCommandRunner()
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.conflicts"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.conflicts",
        arguments: .object(["paths": .array([.string("Sources"), .string("Package.swift")])]),
        context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/bin/echo"))
    #expect(
      (runner.calls.first?.arguments)
        == (["ls-files", "--unmerged", "--", "Sources", "Package.swift"]))
    #expect((payload.objectValue?["operation"]) == (.string("git.conflicts")))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([
          .string("ls-files"), .string("--unmerged"), .string("--"),
          .string("Sources"), .string("Package.swift"),
        ])))
  }

  @Test
  func testGitStatusUsesRegisteredGitProvider() throws {
    let runner = RecordingCommandRunner()
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.status"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.status",
        arguments: .object(["paths": .array([.string("Sources")])]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("/bin/echo"))
    #expect(
      (runner.calls.first?.arguments)
        == (["status", "--short", "--branch", "--porcelain=v1", "--", "Sources"]))
    #expect((payload.objectValue?["operation"]) == (.string("git.status")))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([
          .string("status"), .string("--short"), .string("--branch"), .string("--porcelain=v1"),
          .string("--"), .string("Sources"),
        ])))
  }

  @Test
  func testGitTrackingStatusParsesBranchUpstreamStates() throws {
    let runner = RecordingCommandRunner()
    runner.outputs = [
      RecordingCommandRunner.Output(
        stdout: "## main...origin/main [ahead 2, behind 1]\n M file.txt\n"),
      RecordingCommandRunner.Output(stdout: "## HEAD (no branch)\n"),
      RecordingCommandRunner.Output(stdout: "## No commits yet on trunk\n"),
      RecordingCommandRunner.Output(stdout: "## topic...origin/topic [gone]\n"),
    ]
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.tracking_status"])
        ),
        commandRunner: runner
      ))

    let divergedResult = try provider.callTool(
      .init(
        name: "git.tracking_status", arguments: .object([:]), context: .empty))
    let divergedPayload = try decodeTextPayload(divergedResult)
    let diverged = try #require(divergedPayload.objectValue?["status"]?.objectValue)

    let detachedResult = try provider.callTool(
      .init(
        name: "git.tracking_status", arguments: .object([:]), context: .empty))
    let detachedPayload = try decodeTextPayload(detachedResult)
    let detached = try #require(detachedPayload.objectValue?["status"]?.objectValue)

    let unbornResult = try provider.callTool(
      .init(
        name: "git.tracking_status", arguments: .object([:]), context: .empty))
    let unbornPayload = try decodeTextPayload(unbornResult)
    let unborn = try #require(unbornPayload.objectValue?["status"]?.objectValue)

    let goneResult = try provider.callTool(
      .init(
        name: "git.tracking_status", arguments: .object([:]), context: .empty))
    let gonePayload = try decodeTextPayload(goneResult)
    let gone = try #require(gonePayload.objectValue?["status"]?.objectValue)

    #expect((runner.calls.first?.arguments) == (["status", "--branch", "--porcelain=v1"]))
    #expect((divergedPayload.objectValue?["operation"]) == (.string("git.tracking_status")))
    #expect((diverged["branch"]) == (.string("main")))
    #expect((diverged["upstream"]) == (.string("origin/main")))
    #expect((diverged["ahead"]) == (.number(2)))
    #expect((diverged["behind"]) == (.number(1)))
    #expect((diverged["state"]) == (.string("diverged")))
    #expect((detached["detached"]) == (.bool(true)))
    #expect((detached["state"]) == (.string("detached")))
    #expect((unborn["branch"]) == (.string("trunk")))
    #expect((unborn["unborn"]) == (.bool(true)))
    #expect((unborn["state"]) == (.string("unborn")))
    #expect((gone["state"]) == (.string("gone")))
    #expect((gone["flags"]) == (.array([.string("gone")])))
  }

  @Test
  func testGitCleanPreviewParsesDryRunOutput() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = """
      Would remove build/
      Would remove scratch.txt
      Would skip repository vendor/nested/
      """
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.clean_preview"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.clean_preview",
        arguments: .object([
          "include_ignored": .bool(true),
          "paths": .array([.string("Sources")]),
          "max_results": .number(10),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let items = try #require(payload.objectValue?["items"]?.arrayValue)

    #expect(
      (runner.calls.first?.arguments) == (["clean", "--dry-run", "-d", "-x", "--", "Sources"]))
    #expect((payload.objectValue?["operation"]) == (.string("git.clean_preview")))
    #expect((payload.objectValue?["include_ignored"]) == (.bool(true)))
    #expect((payload.objectValue?["ignored_only"]) == (.bool(false)))
    #expect((payload.objectValue?["item_count"]) == (.number(3)))
    #expect((items[0].objectValue?["action"]) == (.string("remove")))
    #expect((items[0].objectValue?["workspace_relative_path"]) == (.string("build/")))
    #expect((items[0].objectValue?["directory"]) == (.bool(true)))
    #expect((items[1].objectValue?["workspace_relative_path"]) == (.string("scratch.txt")))
    #expect((items[2].objectValue?["action"]) == (.string("skip_repository")))
    #expect((items[2].objectValue?["workspace_relative_path"]) == (.string("vendor/nested/")))
  }

  @Test
  func testGitCleanBuildsDryRunAndWriteArgv() throws {
    let runner = RecordingCommandRunner()
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.clean"])
        ),
        commandRunner: runner
      ))

    let dryRunResult = try provider.callTool(
      .init(
        name: "git.clean",
        arguments: .object([
          "paths": .array([.string("build"), .string("scratch.txt")]),
          "include_ignored": .bool(true),
        ]), context: .empty
      ))
    let dryRunPayload = try decodeTextPayload(dryRunResult)

    let writeResult = try provider.callTool(
      .init(
        name: "git.clean",
        arguments: .object([
          "all_paths": .bool(true),
          "ignored_only": .bool(true),
          "dry_run": .bool(false),
          "confirm_delete": .bool(true),
        ]), context: .empty
      ))
    let writePayload = try decodeTextPayload(writeResult)

    #expect(
      (runner.calls[0].arguments)
        == (["clean", "--dry-run", "-d", "-x", "--", "build", "scratch.txt"]))
    #expect((runner.calls[1].arguments) == (["clean", "-f", "-d", "-X"]))
    #expect((dryRunPayload.objectValue?["operation"]) == (.string("git.clean")))
    #expect((dryRunPayload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((dryRunPayload.objectValue?["confirm_delete"]) == (.bool(false)))
    #expect((dryRunPayload.objectValue?["all_paths"]) == (.bool(false)))
    #expect((writePayload.objectValue?["operation"]) == (.string("git.clean")))
    #expect((writePayload.objectValue?["dry_run"]) == (.bool(false)))
    #expect((writePayload.objectValue?["confirm_delete"]) == (.bool(true)))
    #expect((writePayload.objectValue?["all_paths"]) == (.bool(true)))
    #expect((writePayload.objectValue?["ignored_only"]) == (.bool(true)))
  }

  @Test
  func testGitReflogParsesBoundedLocalEntries() throws {
    let runner = RecordingCommandRunner()
    runner.stdout =
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\taaaaaaa\tHEAD@{2026-07-08T17:16:39+08:00}\tcommit: second\t2026-07-08T17:16:39+08:00\nbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\tbbbbbbb\tHEAD@{2026-07-08T17:15:00+08:00}\tcheckout: moving from main to topic\t2026-07-08T17:15:00+08:00\n"
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.reflog"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.reflog",
        arguments: .object(["limit": .number(10), "max_results": .number(1)]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let entries = try #require(payload.objectValue?["entries"]?.arrayValue)

    #expect(
      (runner.calls.first?.arguments)
        == ([
          "reflog",
          "show",
          "--date=iso-strict",
          "--pretty=format:%H%x09%h%x09%gd%x09%gs%x09%ad",
          "-n",
          "10",
        ]))
    #expect((payload.objectValue?["operation"]) == (.string("git.reflog")))
    #expect((payload.objectValue?["entry_count"]) == (.number(2)))
    #expect((payload.objectValue?["returned_entry_count"]) == (.number(1)))
    #expect((payload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((entries[0].objectValue?["commit"]) == (.string(String(repeating: "a", count: 40))))
    #expect((entries[0].objectValue?["abbreviated_commit"]) == (.string("aaaaaaa")))
    #expect((entries[0].objectValue?["selector"]) == (.string("HEAD@{2026-07-08T17:16:39+08:00}")))
    #expect((entries[0].objectValue?["action"]) == (.string("commit")))
    #expect((entries[0].objectValue?["message"]) == (.string("second")))
    #expect((entries[0].objectValue?["committed_at"]) == (.string("2026-07-08T17:16:39+08:00")))
  }

  @Test
  func testGitRefsParsesLocalRemoteAndTagRefs() throws {
    let runner = RecordingCommandRunner()
    runner.stdout =
      "refs/heads/main\tmain\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\taaaaaaa\tcommit\t2026-07-08T17:16:39+08:00\tInitial commit\nrefs/remotes/origin/topic\torigin/topic\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\tbbbbbbb\tcommit\t2026-07-08T17:15:00+08:00\tTopic work\nrefs/tags/v1.0\tv1.0\tcccccccccccccccccccccccccccccccccccccccc\tccccccc\ttag\t2026-07-08T17:14:00+08:00\tRelease v1.0\n"
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.refs"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.refs",
        arguments: .object([
          "include_tags": .bool(true),
          "limit": .number(20),
          "max_results": .number(2),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let refs = try #require(payload.objectValue?["refs"]?.arrayValue)

    #expect(
      (runner.calls.first?.arguments)
        == ([
          "for-each-ref",
          "--sort=-committerdate",
          "--count",
          "20",
          "--format=%(refname)%09%(refname:short)%09%(objectname)%09%(objectname:short)%09%(objecttype)%09%(committerdate:iso-strict)%09%(subject)",
          "refs/heads",
          "refs/remotes",
          "refs/tags",
        ]))
    #expect((payload.objectValue?["operation"]) == (.string("git.refs")))
    #expect((payload.objectValue?["include_branches"]) == (.bool(true)))
    #expect((payload.objectValue?["include_remotes"]) == (.bool(true)))
    #expect((payload.objectValue?["include_tags"]) == (.bool(true)))
    #expect((payload.objectValue?["ref_count"]) == (.number(3)))
    #expect((payload.objectValue?["returned_ref_count"]) == (.number(2)))
    #expect((payload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((refs[0].objectValue?["kind"]) == (.string("local_branch")))
    #expect((refs[0].objectValue?["refname"]) == (.string("refs/heads/main")))
    #expect((refs[0].objectValue?["short_name"]) == (.string("main")))
    #expect((refs[0].objectValue?["object"]) == (.string(String(repeating: "a", count: 40))))
    #expect((refs[0].objectValue?["abbreviated_object"]) == (.string("aaaaaaa")))
    #expect((refs[0].objectValue?["object_type"]) == (.string("commit")))
    #expect((refs[0].objectValue?["committer_date"]) == (.string("2026-07-08T17:16:39+08:00")))
    #expect((refs[0].objectValue?["subject"]) == (.string("Initial commit")))
    #expect((refs[1].objectValue?["kind"]) == (.string("remote_branch")))
    #expect((refs[1].objectValue?["short_name"]) == (.string("origin/topic")))
  }

  @Test
  func testGitCompareRefsReturnsCountsMergeBaseAndLeftRightCommits() throws {
    let runner = RecordingCommandRunner()
    runner.outputs = [
      RecordingCommandRunner.Output(stdout: "2\t3\n"),
      RecordingCommandRunner.Output(stdout: "dddddddddddddddddddddddddddddddddddddddd\n"),
      RecordingCommandRunner.Output(
        stdout:
          "<\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\taaaaaaa\t2026-07-08T17:16:39+08:00\tAda\tbase only\n>\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\tbbbbbbb\t2026-07-08T17:15:00+08:00\tBen\thead only\n"
      ),
    ]
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.compare_refs"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.compare_refs",
        arguments: .object([
          "base": .string("main"),
          "head": .string("origin/topic"),
          "limit": .number(10),
          "max_results": .number(1),
          "cherry_pick": .bool(true),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let commits = try #require(payload.objectValue?["commits"]?.arrayValue)

    #expect(
      (runner.calls[0].arguments)
        == (["rev-list", "--left-right", "--count", "--cherry-pick", "main...origin/topic"]))
    #expect((runner.calls[1].arguments) == (["merge-base", "main", "origin/topic"]))
    #expect(
      (runner.calls[2].arguments)
        == ([
          "log",
          "--left-right",
          "--cherry-pick",
          "--date=iso-strict",
          "--pretty=format:%m%x09%H%x09%h%x09%ad%x09%an%x09%s",
          "-n",
          "10",
          "main...origin/topic",
        ]))
    #expect((payload.objectValue?["operation"]) == (.string("git.compare_refs")))
    #expect((payload.objectValue?["base"]) == (.string("main")))
    #expect((payload.objectValue?["head"]) == (.string("origin/topic")))
    #expect((payload.objectValue?["range"]) == (.string("main...origin/topic")))
    #expect((payload.objectValue?["base_only_count"]) == (.number(2)))
    #expect((payload.objectValue?["head_only_count"]) == (.number(3)))
    #expect((payload.objectValue?["head_ahead"]) == (.number(3)))
    #expect((payload.objectValue?["head_behind"]) == (.number(2)))
    #expect((payload.objectValue?["merge_base"]) == (.string(String(repeating: "d", count: 40))))
    #expect((payload.objectValue?["commit_count"]) == (.number(2)))
    #expect((payload.objectValue?["returned_commit_count"]) == (.number(1)))
    #expect((payload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((commits[0].objectValue?["side"]) == (.string("<")))
    #expect((commits[0].objectValue?["ref_side"]) == (.string("base")))
    #expect((commits[0].objectValue?["commit"]) == (.string(String(repeating: "a", count: 40))))
    #expect((commits[0].objectValue?["abbreviated_commit"]) == (.string("aaaaaaa")))
    #expect((commits[0].objectValue?["author"]) == (.string("Ada")))
    #expect((commits[0].objectValue?["subject"]) == (.string("base only")))
  }

  @Test
  func testGitResolveRefReturnsObjectAndType() throws {
    let objectID = String(repeating: "a", count: 40)
    let runner = RecordingCommandRunner()
    runner.outputs = [
      RecordingCommandRunner.Output(stdout: "\(objectID)\n", exitCode: 0),
      RecordingCommandRunner.Output(stdout: "commit\n", exitCode: 0),
    ]
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.resolve_ref"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.resolve_ref",
        arguments: .object([
          "ref": .string("HEAD"),
          "timeout_ms": .number(1234),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect(
      (runner.calls.map(\.arguments))
        == ([
          ["rev-parse", "--verify", "HEAD^{object}"],
          ["cat-file", "-t", objectID],
        ]))
    #expect((runner.calls.map(\.timeoutMilliseconds)) == ([1234, 1234]))
    #expect((payload.objectValue?["operation"]) == (.string("git.resolve_ref")))
    #expect((payload.objectValue?["ref"]) == (.string("HEAD")))
    #expect((payload.objectValue?["object_spec"]) == (.string("HEAD^{object}")))
    #expect((payload.objectValue?["object"]) == (.string(objectID)))
    #expect((payload.objectValue?["object_type"]) == (.string("commit")))
    #expect(
      (payload.objectValue?["argv"]?.objectValue?["resolve"])
        == (.array([.string("rev-parse"), .string("--verify"), .string("HEAD^{object}")])))
    #expect(
      (payload.objectValue?["argv"]?.objectValue?["type"])
        == (.array([.string("cat-file"), .string("-t"), .string(objectID)])))
  }

  @Test
  func testGitResolveRefRejectsInvalidRefsAndCommandFailures() throws {
    let invalidRunner = RecordingCommandRunner()
    let invalidRegistry = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.resolve_ref"])
        ),
        commandRunner: invalidRunner
      ))

    expectThrows(
      try invalidRegistry.callTool(
        .init(
          name: "git.resolve_ref",
          arguments: .object(["ref": .string("-bad")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("ref"))
      #expect(invalidRunner.calls.isEmpty)
    }

    let revParseFailureRunner = RecordingCommandRunner()
    revParseFailureRunner.outputs = [
      RecordingCommandRunner.Output(stdout: "", stderr: "fatal: bad object\n", exitCode: 128)
    ]
    let revParseFailureRegistry = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.resolve_ref"])
        ),
        commandRunner: revParseFailureRunner
      ))

    expectThrows(
      try revParseFailureRegistry.callTool(
        .init(
          name: "git.resolve_ref",
          arguments: .object(["ref": .string("missing")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("failed"))
      #expect((revParseFailureRunner.calls.count) == (1))
    }

    let typeFailureRunner = RecordingCommandRunner()
    typeFailureRunner.outputs = [
      RecordingCommandRunner.Output(stdout: String(repeating: "a", count: 40) + "\n", exitCode: 0),
      RecordingCommandRunner.Output(stdout: "", stderr: "fatal: missing object\n", exitCode: 128),
    ]
    let typeFailureRegistry = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.resolve_ref"])
        ),
        commandRunner: typeFailureRunner
      ))

    expectThrows(
      try typeFailureRegistry.callTool(
        .init(
          name: "git.resolve_ref",
          arguments: .object(["ref": .string("HEAD")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("object type"))
      #expect((typeFailureRunner.calls.count) == (2))
    }
  }

  @Test
  func testGitMergeBaseReturnsMergeBasesAndNoMergeBase() throws {
    let firstBase = String(repeating: "a", count: 40)
    let secondBase = String(repeating: "b", count: 40)
    let runner = RecordingCommandRunner()
    runner.outputs = [
      RecordingCommandRunner.Output(stdout: "\(firstBase)\n\(secondBase)\n", exitCode: 0),
      RecordingCommandRunner.Output(stdout: "", exitCode: 1),
    ]
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.merge_base"])
        ),
        commandRunner: runner
      ))

    let mergeBaseResult = try provider.callTool(
      .init(
        name: "git.merge_base",
        arguments: .object([
          "refs": .array([.string("main"), .string("topic")]),
          "all": .bool(true),
          "timeout_ms": .number(1234),
        ]), context: .empty
      ))
    let noBaseResult = try provider.callTool(
      .init(
        name: "git.merge_base",
        arguments: .object([
          "refs": .array([.string("unrelated-a"), .string("unrelated-b")])
        ]), context: .empty
      ))
    let mergeBasePayload = try decodeTextPayload(mergeBaseResult)
    let noBasePayload = try decodeTextPayload(noBaseResult)

    #expect(
      (runner.calls.map(\.arguments))
        == ([
          ["merge-base", "--all", "main", "topic"],
          ["merge-base", "unrelated-a", "unrelated-b"],
        ]))
    #expect((runner.calls[0].timeoutMilliseconds) == (1234))
    #expect((mergeBasePayload.objectValue?["operation"]) == (.string("git.merge_base")))
    #expect(
      (mergeBasePayload.objectValue?["refs"]) == (.array([.string("main"), .string("topic")])))
    #expect((mergeBasePayload.objectValue?["all"]) == (.bool(true)))
    #expect((mergeBasePayload.objectValue?["merge_base"]) == (.string(firstBase)))
    #expect(
      (mergeBasePayload.objectValue?["merge_bases"])
        == (.array([.string(firstBase), .string(secondBase)])))
    #expect((mergeBasePayload.objectValue?["merge_base_count"]) == (.number(2)))
    #expect((mergeBasePayload.objectValue?["has_merge_base"]) == (.bool(true)))
    #expect((noBasePayload.objectValue?["merge_bases"]) == (.array([])))
    #expect((noBasePayload.objectValue?["merge_base"]) == (.null))
    #expect((noBasePayload.objectValue?["merge_base_count"]) == (.number(0)))
    #expect((noBasePayload.objectValue?["has_merge_base"]) == (.bool(false)))
    #expect((noBasePayload.objectValue?["result"]?.objectValue?["exit_code"]) == (.number(1)))
  }

  @Test
  func testGitMergeBaseRejectsInvalidRefsAndCommandFailures() throws {
    let invalidRunner = RecordingCommandRunner()
    let invalidRegistry = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.merge_base"])
        ),
        commandRunner: invalidRunner
      ))

    expectThrows(
      try invalidRegistry.callTool(
        .init(
          name: "git.merge_base",
          arguments: .object(["refs": .array([.string("main")])]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("at least 2"))
      #expect(invalidRunner.calls.isEmpty)
    }

    expectThrows(
      try invalidRegistry.callTool(
        .init(
          name: "git.merge_base",
          arguments: .object(["refs": .array([.string("main"), .string("-bad")])]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("refs[1]"))
      #expect(invalidRunner.calls.isEmpty)
    }

    let failureRunner = RecordingCommandRunner()
    failureRunner.outputs = [
      RecordingCommandRunner.Output(stdout: "", stderr: "fatal: bad object\n", exitCode: 128)
    ]
    let failureRegistry = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.merge_base"])
        ),
        commandRunner: failureRunner
      ))

    expectThrows(
      try failureRegistry.callTool(
        .init(
          name: "git.merge_base",
          arguments: .object(["refs": .array([.string("missing"), .string("main")])]),
          context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("failed"))
      #expect((failureRunner.calls.count) == (1))
    }
  }

  @Test
  func testGitIsAncestorMapsExitCodeToBoolean() throws {
    let runner = RecordingCommandRunner()
    runner.outputs = [
      RecordingCommandRunner.Output(stdout: "", exitCode: 0),
      RecordingCommandRunner.Output(stdout: "", exitCode: 1),
    ]
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.is_ancestor"])
        ),
        commandRunner: runner
      ))

    let trueResult = try provider.callTool(
      .init(
        name: "git.is_ancestor",
        arguments: .object([
          "ancestor": .string("main"),
          "descendant": .string("origin/main"),
          "timeout_ms": .number(1234),
        ]), context: .empty
      ))
    let falseResult = try provider.callTool(
      .init(
        name: "git.is_ancestor",
        arguments: .object([
          "ancestor": .string("feature"),
          "descendant": .string("main"),
        ]), context: .empty
      ))
    let truePayload = try decodeTextPayload(trueResult)
    let falsePayload = try decodeTextPayload(falseResult)

    #expect(
      (runner.calls.map(\.arguments))
        == ([
          ["merge-base", "--is-ancestor", "main", "origin/main"],
          ["merge-base", "--is-ancestor", "feature", "main"],
        ]))
    #expect((runner.calls[0].timeoutMilliseconds) == (1234))
    #expect((truePayload.objectValue?["operation"]) == (.string("git.is_ancestor")))
    #expect((truePayload.objectValue?["ancestor"]) == (.string("main")))
    #expect((truePayload.objectValue?["descendant"]) == (.string("origin/main")))
    #expect((truePayload.objectValue?["is_ancestor"]) == (.bool(true)))
    #expect(
      (truePayload.objectValue?["argv"])
        == (.array([
          .string("merge-base"), .string("--is-ancestor"), .string("main"),
          .string("origin/main"),
        ])))
    #expect((falsePayload.objectValue?["is_ancestor"]) == (.bool(false)))
    #expect((falsePayload.objectValue?["result"]?.objectValue?["exit_code"]) == (.number(1)))
  }

  @Test
  func testGitIsAncestorRejectsInvalidRefsAndCommandFailures() throws {
    let invalidRunner = RecordingCommandRunner()
    let invalidRegistry = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.is_ancestor"])
        ),
        commandRunner: invalidRunner
      ))

    expectThrows(
      try invalidRegistry.callTool(
        .init(
          name: "git.is_ancestor",
          arguments: .object([
            "ancestor": .string("-bad"),
            "descendant": .string("main"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("ancestor"))
      #expect(invalidRunner.calls.isEmpty)
    }

    let failureRunner = RecordingCommandRunner()
    failureRunner.outputs = [
      RecordingCommandRunner.Output(stdout: "", stderr: "fatal: bad object\n", exitCode: 128)
    ]
    let failureRegistry = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.is_ancestor"])
        ),
        commandRunner: failureRunner
      ))

    expectThrows(
      try failureRegistry.callTool(
        .init(
          name: "git.is_ancestor",
          arguments: .object([
            "ancestor": .string("missing"),
            "descendant": .string("main"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("failed"))
      #expect((failureRunner.calls.count) == (1))
    }
  }

  @Test
  func testGitDiffBuildsReadOnlyArgv() throws {
    let runner = RecordingCommandRunner()
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.diff"])
        ),
        commandRunner: runner
      ))

    _ = try provider.callTool(
      .init(
        name: "git.diff",
        arguments: .object([
          "staged": .bool(true),
          "stat": .bool(true),
          "context_lines": .number(3),
          "paths": .array([.string("README.md")]),
        ]), context: .empty
      ))

    #expect(
      (runner.calls.first?.arguments)
        == (["diff", "--no-ext-diff", "--cached", "--stat", "-U3", "--", "README.md"]))
  }

  @Test
  func testGitDiffSummaryParsesNumstatAndSummaryOutput() throws {
    let runner = RecordingCommandRunner()
    let nul = "\u{0}"
    let numstatOutput =
      "2\t1\tSources/App.swift\(nul)-\t-\tAssets/logo.png\(nul)1\t0\t\(nul)Old.swift\(nul)New.swift\(nul)"
    runner.outputs = [
      RecordingCommandRunner.Output(
        stdout: numstatOutput
      ),
      RecordingCommandRunner.Output(
        stdout:
          " create mode 100644 Assets/logo.png\n rename Old.swift => New.swift (86%)\n mode change 100644 => 100755 Scripts/build.sh\n"
      ),
    ]
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.diff_summary"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.diff_summary",
        arguments: .object([
          "staged": .bool(true),
          "paths": .array([.string("Sources")]),
          "max_results": .number(10),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let summary = try #require(payload.objectValue?["summary"]?.arrayValue)

    #expect(
      (runner.calls[0].arguments)
        == (["diff", "--no-ext-diff", "--no-color", "--cached", "--numstat", "-z", "--", "Sources"])
    )
    #expect(
      (runner.calls[1].arguments)
        == (["diff", "--no-ext-diff", "--no-color", "--cached", "--summary", "--", "Sources"]))
    #expect((payload.objectValue?["operation"]) == (.string("git.diff_summary")))
    #expect((payload.objectValue?["file_count"]) == (.number(3)))
    #expect((payload.objectValue?["total_additions"]) == (.number(3)))
    #expect((payload.objectValue?["total_deletions"]) == (.number(1)))
    #expect((payload.objectValue?["binary_file_count"]) == (.number(1)))
    #expect((files[0].objectValue?["workspace_relative_path"]) == (.string("Sources/App.swift")))
    #expect((files[0].objectValue?["additions"]) == (.number(2)))
    #expect((files[1].objectValue?["binary"]) == (.bool(true)))
    #expect((files[2].objectValue?["old_path"]) == (.string("Old.swift")))
    #expect((files[2].objectValue?["workspace_relative_path"]) == (.string("New.swift")))
    #expect((summary[0].objectValue?["kind"]) == (.string("create")))
    #expect((summary[0].objectValue?["mode"]) == (.string("100644")))
    #expect((summary[1].objectValue?["kind"]) == (.string("rename")))
    #expect((summary[1].objectValue?["similarity"]) == (.number(86)))
    #expect((summary[2].objectValue?["kind"]) == (.string("mode_change")))
    #expect((summary[2].objectValue?["old_mode"]) == (.string("100644")))
    #expect((summary[2].objectValue?["new_mode"]) == (.string("100755")))
    #expect(
      (payload.objectValue?["results"]?.objectValue?["numstat"]?.objectValue?["stdout_bytes"])
        == (.number(Double(numstatOutput.utf8.count))))
  }

  @Test
  func testGitDiffCheckParsesWhitespaceAndConflictMarkerIssues() throws {
    let runner = RecordingCommandRunner()
    runner.stdout = """
      Sources/App.swift:10: trailing whitespace.
      +let value = 1\u{20}\u{20}
      Sources/App.swift:11: leftover conflict marker
      """
    runner.exitCode = 2
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.diff_check"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.diff_check",
        arguments: .object([
          "staged": .bool(true),
          "paths": .array([.string("Sources")]),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let issues = try #require(payload.objectValue?["issues"]?.arrayValue)
    let rawLines = try #require(payload.objectValue?["raw_lines"]?.arrayValue)

    #expect(
      (runner.calls.first?.arguments)
        == (["diff", "--no-ext-diff", "--no-color", "--check", "--cached", "--", "Sources"]))
    #expect((payload.objectValue?["operation"]) == (.string("git.diff_check")))
    #expect((payload.objectValue?["passed"]) == (.bool(false)))
    #expect((payload.objectValue?["issue_count"]) == (.number(2)))
    #expect((issues[0].objectValue?["workspace_relative_path"]) == (.string("Sources/App.swift")))
    #expect((issues[0].objectValue?["line"]) == (.number(10)))
    #expect((issues[0].objectValue?["message"]) == (.string("trailing whitespace.")))
    #expect((issues[1].objectValue?["message"]) == (.string("leftover conflict marker")))
    #expect((rawLines[1]) == (.string("+let value = 1  ")))
    #expect((payload.objectValue?["result"]?.objectValue?["exit_code"]) == (.number(2)))
  }

  @Test
  func testGitCommitFilesParsesBoundedNameStatusRows() throws {
    let runner = RecordingCommandRunner()
    runner.outputs = [
      RecordingCommandRunner.Output(
        stdout:
          "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\taaaaaaa\t2026-07-08T18:30:00+08:00\tAda\tupdate files\n"
      ),
      RecordingCommandRunner.Output(
        stdout: "M\0Sources/App.swift\0R100\0Sources/Old.swift\0Sources/New.swift\0"
      ),
    ]
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.commit_files"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.commit_files",
        arguments: .object([
          "revision": .string("HEAD"),
          "max_results": .number(1),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let rawRecords = try #require(payload.objectValue?["raw_records"]?.arrayValue)

    #expect(
      (runner.calls[0].arguments)
        == ([
          "show",
          "-s",
          "--date=iso-strict",
          "--format=%H%x09%h%x09%ad%x09%an%x09%s",
          "HEAD",
        ]))
    #expect(
      (runner.calls[1].arguments)
        == (["diff-tree", "--root", "--no-commit-id", "--name-status", "-M", "-r", "-z", "HEAD"]))
    #expect((payload.objectValue?["operation"]) == (.string("git.commit_files")))
    #expect((payload.objectValue?["commit_hash"]) == (.string(String(repeating: "a", count: 40))))
    #expect((payload.objectValue?["abbreviated_commit"]) == (.string("aaaaaaa")))
    #expect((payload.objectValue?["committed_at"]) == (.string("2026-07-08T18:30:00+08:00")))
    #expect((payload.objectValue?["author"]) == (.string("Ada")))
    #expect((payload.objectValue?["subject"]) == (.string("update files")))
    #expect((payload.objectValue?["file_count"]) == (.number(2)))
    #expect((payload.objectValue?["returned_file_count"]) == (.number(1)))
    #expect((payload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((files[0].objectValue?["status"]) == (.string("M")))
    #expect((files[0].objectValue?["kind"]) == (.string("modified")))
    #expect((files[0].objectValue?["workspace_relative_path"]) == (.string("Sources/App.swift")))
    #expect((rawRecords[0]) == (.string("M\tSources/App.swift")))
  }

  @Test
  func testGitBranchLogAndShowBuildExpectedArgv() throws {
    let runner = RecordingCommandRunner()
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.branch", "git.log", "git.show"])
        ),
        commandRunner: runner
      ))

    _ = try provider.callTool(
      .init(
        name: "git.branch",
        arguments: .object(["all": .bool(true), "verbose": .bool(true)]), context: .empty
      ))
    _ = try provider.callTool(
      .init(
        name: "git.log",
        arguments: .object([
          "limit": .number(5),
          "paths": .array([.string("Sources")]),
        ]), context: .empty
      ))
    _ = try provider.callTool(
      .init(
        name: "git.show",
        arguments: .object([
          "revision": .string("HEAD~1"),
          "patch": .bool(true),
          "context_lines": .number(1),
          "paths": .array([.string("Package.swift")]),
        ]), context: .empty
      ))

    #expect(
      (runner.calls[0].arguments)
        == ([
          "--no-pager", "branch", "--list", "--no-color", "--no-column", "--all", "--verbose",
        ]))
    #expect(
      (runner.calls[1].arguments)
        == ([
          "log",
          "--date=iso-strict",
          "--pretty=format:%H%x09%h%x09%ad%x09%an%x09%s",
          "-n",
          "5",
          "--",
          "Sources",
        ]))
    #expect(
      (runner.calls[2].arguments)
        == (["show", "--date=iso-strict", "-U1", "HEAD~1", "--", "Package.swift"]))

    _ = try provider.callTool(
      .init(
        name: "git.show",
        arguments: .object([
          "revision": .string("HEAD"),
          "stat": .bool(true),
        ]), context: .empty
      ))

    #expect((runner.calls[3].arguments) == (["show", "--date=iso-strict", "--stat", "HEAD"]))
  }

  @Test
  func testGitBranchCreateDryRunPreflightsWithoutCreating() throws {
    let runner = RecordingCommandRunner()
    runner.outputs = [
      RecordingCommandRunner.Output(stdout: "feature/test\n"),
      RecordingCommandRunner.Output(stdout: "", exitCode: 1),
      RecordingCommandRunner.Output(stdout: String(repeating: "a", count: 40) + "\n"),
    ]
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.branch_create"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.branch_create",
        arguments: .object([
          "name": .string("feature/test"),
          "timeout_ms": .number(1234),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect(
      (runner.calls.map(\.arguments))
        == ([
          ["check-ref-format", "--branch", "feature/test"],
          ["show-ref", "--verify", "--quiet", "refs/heads/feature/test"],
          ["rev-parse", "--verify", "HEAD^{commit}"],
        ]))
    #expect((runner.calls.map(\.timeoutMilliseconds)) == ([1234, 1234, 1234]))
    #expect((payload.objectValue?["operation"]) == (.string("git.branch_create")))
    #expect((payload.objectValue?["provider"]) == (.string("git")))
    #expect((payload.objectValue?["name"]) == (.string("feature/test")))
    #expect((payload.objectValue?["start_point"]) == (.string("HEAD")))
    #expect((payload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((payload.objectValue?["confirm_create"]) == (.bool(false)))
    #expect((payload.objectValue?["result"]) == (.null))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([.string("branch"), .string("feature/test"), .string("HEAD")])))
    #expect(
      (payload.objectValue?["preflight"]?.objectValue?["existing_branch"]?.objectValue?[
        "exit_code"]) == (.number(1)))
  }

  @Test
  func testGitBranchCreateRunsAfterConfirmation() throws {
    let runner = RecordingCommandRunner()
    runner.outputs = [
      RecordingCommandRunner.Output(stdout: "feature/new\n"),
      RecordingCommandRunner.Output(stdout: "", exitCode: 1),
      RecordingCommandRunner.Output(stdout: String(repeating: "b", count: 40) + "\n"),
      RecordingCommandRunner.Output(stdout: "", exitCode: 0),
    ]
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.branch_create"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.branch_create",
        arguments: .object([
          "name": .string("feature/new"),
          "start_point": .string("main"),
          "dry_run": .bool(false),
          "confirm_create": .bool(true),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect(
      (runner.calls.map(\.arguments))
        == ([
          ["check-ref-format", "--branch", "feature/new"],
          ["show-ref", "--verify", "--quiet", "refs/heads/feature/new"],
          ["rev-parse", "--verify", "main^{commit}"],
          ["branch", "feature/new", "main"],
        ]))
    #expect((payload.objectValue?["dry_run"]) == (.bool(false)))
    #expect((payload.objectValue?["confirm_create"]) == (.bool(true)))
    #expect(
      (payload.objectValue?["result"]?.objectValue?["arguments"])
        == (.array([.string("branch"), .string("feature/new"), .string("main")])))
    #expect((payload.objectValue?["result"]?.objectValue?["exit_code"]) == (.number(0)))
  }

  @Test
  func testGitBranchDeleteDryRunPreflightsWithoutDeleting() throws {
    let runner = RecordingCommandRunner()
    runner.outputs = [
      RecordingCommandRunner.Output(stdout: "feature/old\n"),
      RecordingCommandRunner.Output(stdout: "", exitCode: 0),
      RecordingCommandRunner.Output(stdout: "main\n"),
    ]
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.branch_delete"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.branch_delete",
        arguments: .object([
          "name": .string("feature/old"),
          "timeout_ms": .number(1234),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect(
      (runner.calls.map(\.arguments))
        == ([
          ["check-ref-format", "--branch", "feature/old"],
          ["show-ref", "--verify", "--quiet", "refs/heads/feature/old"],
          ["branch", "--show-current"],
        ]))
    #expect((runner.calls.map(\.timeoutMilliseconds)) == ([1234, 1234, 1234]))
    #expect((payload.objectValue?["operation"]) == (.string("git.branch_delete")))
    #expect((payload.objectValue?["provider"]) == (.string("git")))
    #expect((payload.objectValue?["name"]) == (.string("feature/old")))
    #expect((payload.objectValue?["force"]) == (.bool(false)))
    #expect((payload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((payload.objectValue?["confirm_delete"]) == (.bool(false)))
    #expect((payload.objectValue?["current_branch"]) == (.string("main")))
    #expect((payload.objectValue?["result"]) == (.null))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([.string("branch"), .string("-d"), .string("feature/old")])))
  }

  @Test
  func testGitBranchDeleteRunsAfterConfirmation() throws {
    let runner = RecordingCommandRunner()
    runner.outputs = [
      RecordingCommandRunner.Output(stdout: "feature/delete\n"),
      RecordingCommandRunner.Output(stdout: "", exitCode: 0),
      RecordingCommandRunner.Output(stdout: "main\n"),
      RecordingCommandRunner.Output(stdout: "Deleted branch feature/delete.\n", exitCode: 0),
    ]
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.branch_delete"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.branch_delete",
        arguments: .object([
          "name": .string("feature/delete"),
          "force": .bool(true),
          "dry_run": .bool(false),
          "confirm_delete": .bool(true),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect(
      (runner.calls.map(\.arguments))
        == ([
          ["check-ref-format", "--branch", "feature/delete"],
          ["show-ref", "--verify", "--quiet", "refs/heads/feature/delete"],
          ["branch", "--show-current"],
          ["branch", "-D", "feature/delete"],
        ]))
    #expect((payload.objectValue?["dry_run"]) == (.bool(false)))
    #expect((payload.objectValue?["confirm_delete"]) == (.bool(true)))
    #expect((payload.objectValue?["force"]) == (.bool(true)))
    #expect(
      (payload.objectValue?["result"]?.objectValue?["arguments"])
        == (.array([.string("branch"), .string("-D"), .string("feature/delete")])))
    #expect((payload.objectValue?["result"]?.objectValue?["exit_code"]) == (.number(0)))
  }

  @Test
  func testGitBranchDeleteRejectsUnsafeInputs() throws {
    let missingConfirmRunner = RecordingCommandRunner()
    let missingConfirmRegistry = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.branch_delete"])
        ),
        commandRunner: missingConfirmRunner
      ))

    expectThrows(
      try missingConfirmRegistry.callTool(
        .init(
          name: "git.branch_delete",
          arguments: .object([
            "name": .string("feature/delete"),
            "dry_run": .bool(false),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("confirm_delete"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    expectThrows(
      try missingConfirmRegistry.callTool(
        .init(
          name: "git.branch_delete",
          arguments: .object(["name": .string("refs/heads/main")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("not a full ref"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    let missingBranchRunner = RecordingCommandRunner()
    missingBranchRunner.outputs = [
      RecordingCommandRunner.Output(stdout: "feature/missing\n"),
      RecordingCommandRunner.Output(stdout: "", exitCode: 1),
    ]
    let missingBranchRegistry = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.branch_delete"])
        ),
        commandRunner: missingBranchRunner
      ))

    expectThrows(
      try missingBranchRegistry.callTool(
        .init(
          name: "git.branch_delete",
          arguments: .object(["name": .string("feature/missing")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("does not exist"))
      #expect((missingBranchRunner.calls.count) == (2))
    }

    let currentBranchRunner = RecordingCommandRunner()
    currentBranchRunner.outputs = [
      RecordingCommandRunner.Output(stdout: "feature/current\n"),
      RecordingCommandRunner.Output(stdout: "", exitCode: 0),
      RecordingCommandRunner.Output(stdout: "feature/current\n"),
    ]
    let currentBranchRegistry = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.branch_delete"])
        ),
        commandRunner: currentBranchRunner
      ))

    expectThrows(
      try currentBranchRegistry.callTool(
        .init(
          name: "git.branch_delete",
          arguments: .object(["name": .string("feature/current")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("current branch"))
      #expect((currentBranchRunner.calls.count) == (3))
    }
  }

  @Test
  func testGitBranchRenameDryRunPreflightsWithoutRenaming() throws {
    let runner = RecordingCommandRunner()
    runner.outputs = [
      RecordingCommandRunner.Output(stdout: "feature/old\n"),
      RecordingCommandRunner.Output(stdout: "feature/new\n"),
      RecordingCommandRunner.Output(stdout: "", exitCode: 0),
      RecordingCommandRunner.Output(stdout: "", exitCode: 1),
      RecordingCommandRunner.Output(stdout: "main\n"),
    ]
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.branch_rename"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.branch_rename",
        arguments: .object([
          "old_name": .string("feature/old"),
          "new_name": .string("feature/new"),
          "timeout_ms": .number(1234),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect(
      (runner.calls.map(\.arguments))
        == ([
          ["check-ref-format", "--branch", "feature/old"],
          ["check-ref-format", "--branch", "feature/new"],
          ["show-ref", "--verify", "--quiet", "refs/heads/feature/old"],
          ["show-ref", "--verify", "--quiet", "refs/heads/feature/new"],
          ["branch", "--show-current"],
        ]))
    #expect((runner.calls.map(\.timeoutMilliseconds)) == ([1234, 1234, 1234, 1234, 1234]))
    #expect((payload.objectValue?["operation"]) == (.string("git.branch_rename")))
    #expect((payload.objectValue?["provider"]) == (.string("git")))
    #expect((payload.objectValue?["old_name"]) == (.string("feature/old")))
    #expect((payload.objectValue?["new_name"]) == (.string("feature/new")))
    #expect((payload.objectValue?["force"]) == (.bool(false)))
    #expect((payload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((payload.objectValue?["confirm_rename"]) == (.bool(false)))
    #expect((payload.objectValue?["current_branch"]) == (.string("main")))
    #expect((payload.objectValue?["renames_current_branch"]) == (.bool(false)))
    #expect((payload.objectValue?["target_exists"]) == (.bool(false)))
    #expect((payload.objectValue?["result"]) == (.null))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([
          .string("branch"), .string("-m"), .string("feature/old"), .string("feature/new"),
        ])))
  }

  @Test
  func testGitBranchRenameRunsAfterConfirmation() throws {
    let runner = RecordingCommandRunner()
    runner.outputs = [
      RecordingCommandRunner.Output(stdout: "feature/old\n"),
      RecordingCommandRunner.Output(stdout: "feature/new\n"),
      RecordingCommandRunner.Output(stdout: "", exitCode: 0),
      RecordingCommandRunner.Output(stdout: "", exitCode: 0),
      RecordingCommandRunner.Output(stdout: "feature/old\n"),
      RecordingCommandRunner.Output(stdout: "", exitCode: 0),
    ]
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.branch_rename"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.branch_rename",
        arguments: .object([
          "old_name": .string("feature/old"),
          "new_name": .string("feature/new"),
          "force": .bool(true),
          "dry_run": .bool(false),
          "confirm_rename": .bool(true),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect(
      (runner.calls.map(\.arguments))
        == ([
          ["check-ref-format", "--branch", "feature/old"],
          ["check-ref-format", "--branch", "feature/new"],
          ["show-ref", "--verify", "--quiet", "refs/heads/feature/old"],
          ["show-ref", "--verify", "--quiet", "refs/heads/feature/new"],
          ["branch", "--show-current"],
          ["branch", "-M", "feature/old", "feature/new"],
        ]))
    #expect((payload.objectValue?["dry_run"]) == (.bool(false)))
    #expect((payload.objectValue?["confirm_rename"]) == (.bool(true)))
    #expect((payload.objectValue?["force"]) == (.bool(true)))
    #expect((payload.objectValue?["renames_current_branch"]) == (.bool(true)))
    #expect((payload.objectValue?["target_exists"]) == (.bool(true)))
    #expect(
      (payload.objectValue?["result"]?.objectValue?["arguments"])
        == (.array([
          .string("branch"), .string("-M"), .string("feature/old"), .string("feature/new"),
        ])))
    #expect((payload.objectValue?["result"]?.objectValue?["exit_code"]) == (.number(0)))
  }

  @Test
  func testGitBranchRenameRejectsUnsafeInputs() throws {
    let missingConfirmRunner = RecordingCommandRunner()
    let missingConfirmRegistry = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.branch_rename"])
        ),
        commandRunner: missingConfirmRunner
      ))

    expectThrows(
      try missingConfirmRegistry.callTool(
        .init(
          name: "git.branch_rename",
          arguments: .object([
            "old_name": .string("feature/old"),
            "new_name": .string("feature/new"),
            "dry_run": .bool(false),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("confirm_rename"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    expectThrows(
      try missingConfirmRegistry.callTool(
        .init(
          name: "git.branch_rename",
          arguments: .object([
            "old_name": .string("feature/same"),
            "new_name": .string("feature/same"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("must be different"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    expectThrows(
      try missingConfirmRegistry.callTool(
        .init(
          name: "git.branch_rename",
          arguments: .object([
            "old_name": .string("feature/old"),
            "new_name": .string("refs/heads/new"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("not a full ref"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    let missingBranchRunner = RecordingCommandRunner()
    missingBranchRunner.outputs = [
      RecordingCommandRunner.Output(stdout: "feature/missing\n"),
      RecordingCommandRunner.Output(stdout: "feature/new\n"),
      RecordingCommandRunner.Output(stdout: "", exitCode: 1),
    ]
    let missingBranchRegistry = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.branch_rename"])
        ),
        commandRunner: missingBranchRunner
      ))

    expectThrows(
      try missingBranchRegistry.callTool(
        .init(
          name: "git.branch_rename",
          arguments: .object([
            "old_name": .string("feature/missing"),
            "new_name": .string("feature/new"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("does not exist"))
      #expect((missingBranchRunner.calls.count) == (3))
    }

    let existingTargetRunner = RecordingCommandRunner()
    existingTargetRunner.outputs = [
      RecordingCommandRunner.Output(stdout: "feature/old\n"),
      RecordingCommandRunner.Output(stdout: "feature/new\n"),
      RecordingCommandRunner.Output(stdout: "", exitCode: 0),
      RecordingCommandRunner.Output(stdout: "", exitCode: 0),
    ]
    let existingTargetRegistry = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.branch_rename"])
        ),
        commandRunner: existingTargetRunner
      ))

    expectThrows(
      try existingTargetRegistry.callTool(
        .init(
          name: "git.branch_rename",
          arguments: .object([
            "old_name": .string("feature/old"),
            "new_name": .string("feature/new"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("already exists"))
      #expect((existingTargetRunner.calls.count) == (4))
    }
  }

  @Test
  func testGitBranchSwitchDryRunPreflightsWithoutSwitching() throws {
    let runner = RecordingCommandRunner()
    runner.outputs = [
      RecordingCommandRunner.Output(stdout: "feature/target\n"),
      RecordingCommandRunner.Output(stdout: "", exitCode: 0),
      RecordingCommandRunner.Output(stdout: "main\n"),
      RecordingCommandRunner.Output(stdout: ""),
    ]
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.branch_switch"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.branch_switch",
        arguments: .object([
          "name": .string("feature/target"),
          "timeout_ms": .number(1234),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect(
      (runner.calls.map(\.arguments))
        == ([
          ["check-ref-format", "--branch", "feature/target"],
          ["show-ref", "--verify", "--quiet", "refs/heads/feature/target"],
          ["branch", "--show-current"],
          ["status", "--porcelain=v1", "-z"],
        ]))
    #expect((runner.calls.map(\.timeoutMilliseconds)) == ([1234, 1234, 1234, 1234]))
    #expect((payload.objectValue?["operation"]) == (.string("git.branch_switch")))
    #expect((payload.objectValue?["provider"]) == (.string("git")))
    #expect((payload.objectValue?["name"]) == (.string("feature/target")))
    #expect((payload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((payload.objectValue?["confirm_switch"]) == (.bool(false)))
    #expect((payload.objectValue?["allow_dirty"]) == (.bool(false)))
    #expect((payload.objectValue?["current_branch"]) == (.string("main")))
    #expect((payload.objectValue?["already_current"]) == (.bool(false)))
    #expect((payload.objectValue?["dirty_worktree"]) == (.bool(false)))
    #expect((payload.objectValue?["working_tree_change_count"]) == (.number(0)))
    #expect((payload.objectValue?["result"]) == (.null))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([.string("switch"), .string("--no-guess"), .string("feature/target")])))
  }

  @Test
  func testGitBranchSwitchRunsAfterConfirmation() throws {
    let runner = RecordingCommandRunner()
    runner.outputs = [
      RecordingCommandRunner.Output(stdout: "feature/target\n"),
      RecordingCommandRunner.Output(stdout: "", exitCode: 0),
      RecordingCommandRunner.Output(stdout: "main\n"),
      RecordingCommandRunner.Output(stdout: ""),
      RecordingCommandRunner.Output(stdout: "Switched to branch 'feature/target'\n", exitCode: 0),
    ]
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.branch_switch"])
        ),
        commandRunner: runner
      ))

    let result = try provider.callTool(
      .init(
        name: "git.branch_switch",
        arguments: .object([
          "name": .string("feature/target"),
          "dry_run": .bool(false),
          "confirm_switch": .bool(true),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect(
      (runner.calls.map(\.arguments))
        == ([
          ["check-ref-format", "--branch", "feature/target"],
          ["show-ref", "--verify", "--quiet", "refs/heads/feature/target"],
          ["branch", "--show-current"],
          ["status", "--porcelain=v1", "-z"],
          ["switch", "--no-guess", "feature/target"],
        ]))
    #expect((payload.objectValue?["dry_run"]) == (.bool(false)))
    #expect((payload.objectValue?["confirm_switch"]) == (.bool(true)))
    #expect((payload.objectValue?["dirty_worktree"]) == (.bool(false)))
    #expect(
      (payload.objectValue?["result"]?.objectValue?["arguments"])
        == (.array([.string("switch"), .string("--no-guess"), .string("feature/target")])))
    #expect((payload.objectValue?["result"]?.objectValue?["exit_code"]) == (.number(0)))
  }

  @Test
  func testGitBranchSwitchRejectsUnsafeInputs() throws {
    let missingConfirmRunner = RecordingCommandRunner()
    let missingConfirmRegistry = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.branch_switch"])
        ),
        commandRunner: missingConfirmRunner
      ))

    expectThrows(
      try missingConfirmRegistry.callTool(
        .init(
          name: "git.branch_switch",
          arguments: .object([
            "name": .string("feature/target"),
            "dry_run": .bool(false),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("confirm_switch"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    expectThrows(
      try missingConfirmRegistry.callTool(
        .init(
          name: "git.branch_switch",
          arguments: .object(["name": .string("refs/heads/main")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("not a full ref"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    let missingBranchRunner = RecordingCommandRunner()
    missingBranchRunner.outputs = [
      RecordingCommandRunner.Output(stdout: "feature/missing\n"),
      RecordingCommandRunner.Output(stdout: "", exitCode: 1),
    ]
    let missingBranchRegistry = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.branch_switch"])
        ),
        commandRunner: missingBranchRunner
      ))

    expectThrows(
      try missingBranchRegistry.callTool(
        .init(
          name: "git.branch_switch",
          arguments: .object(["name": .string("feature/missing")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("does not exist"))
      #expect((missingBranchRunner.calls.count) == (2))
    }

    let dirtyRunner = RecordingCommandRunner()
    dirtyRunner.outputs = [
      RecordingCommandRunner.Output(stdout: "feature/target\n"),
      RecordingCommandRunner.Output(stdout: "", exitCode: 0),
      RecordingCommandRunner.Output(stdout: "main\n"),
      RecordingCommandRunner.Output(stdout: " M README.md\u{0}"),
    ]
    let dirtyRegistry = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.branch_switch"])
        ),
        commandRunner: dirtyRunner
      ))

    expectThrows(
      try dirtyRegistry.callTool(
        .init(
          name: "git.branch_switch",
          arguments: .object([
            "name": .string("feature/target"),
            "dry_run": .bool(false),
            "confirm_switch": .bool(true),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("allow_dirty"))
      #expect((dirtyRunner.calls.count) == (4))
    }
  }

  @Test
  func testGitBranchSwitchAllowsDirtyWorktreeWhenExplicitAndSkipsAlreadyCurrent() throws {
    let dirtyRunner = RecordingCommandRunner()
    dirtyRunner.outputs = [
      RecordingCommandRunner.Output(stdout: "feature/target\n"),
      RecordingCommandRunner.Output(stdout: "", exitCode: 0),
      RecordingCommandRunner.Output(stdout: "main\n"),
      RecordingCommandRunner.Output(stdout: " M README.md\u{0}?? scratch.txt\u{0}"),
      RecordingCommandRunner.Output(stdout: "Switched to branch 'feature/target'\n", exitCode: 0),
    ]
    let dirtyRegistry = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.branch_switch"])
        ),
        commandRunner: dirtyRunner
      ))

    let dirtyResult = try dirtyRegistry.callTool(
      .init(
        name: "git.branch_switch",
        arguments: .object([
          "name": .string("feature/target"),
          "dry_run": .bool(false),
          "confirm_switch": .bool(true),
          "allow_dirty": .bool(true),
        ]), context: .empty
      ))
    let dirtyPayload = try decodeTextPayload(dirtyResult)

    #expect((dirtyPayload.objectValue?["dirty_worktree"]) == (.bool(true)))
    #expect((dirtyPayload.objectValue?["working_tree_change_count"]) == (.number(2)))
    #expect(
      (dirtyPayload.objectValue?["result"]?.objectValue?["arguments"])
        == (.array([.string("switch"), .string("--no-guess"), .string("feature/target")])))

    let currentRunner = RecordingCommandRunner()
    currentRunner.outputs = [
      RecordingCommandRunner.Output(stdout: "feature/current\n"),
      RecordingCommandRunner.Output(stdout: "", exitCode: 0),
      RecordingCommandRunner.Output(stdout: "feature/current\n"),
      RecordingCommandRunner.Output(stdout: ""),
    ]
    let currentRegistry = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.branch_switch"])
        ),
        commandRunner: currentRunner
      ))

    let currentResult = try currentRegistry.callTool(
      .init(
        name: "git.branch_switch",
        arguments: .object([
          "name": .string("feature/current"),
          "dry_run": .bool(false),
          "confirm_switch": .bool(true),
        ]), context: .empty
      ))
    let currentPayload = try decodeTextPayload(currentResult)

    #expect((currentRunner.calls.count) == (4))
    #expect((currentPayload.objectValue?["already_current"]) == (.bool(true)))
    #expect((currentPayload.objectValue?["would_switch"]) == (.bool(false)))
    #expect((currentPayload.objectValue?["result"]) == (.null))
  }

  @Test
  func testGitBranchCreateRejectsUnsafeInputs() throws {
    let missingConfirmRunner = RecordingCommandRunner()
    let missingConfirmRegistry = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.branch_create"])
        ),
        commandRunner: missingConfirmRunner
      ))

    expectThrows(
      try missingConfirmRegistry.callTool(
        .init(
          name: "git.branch_create",
          arguments: .object([
            "name": .string("feature/new"),
            "dry_run": .bool(false),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("confirm_create"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    expectThrows(
      try missingConfirmRegistry.callTool(
        .init(
          name: "git.branch_create",
          arguments: .object(["name": .string("refs/heads/main")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("not a full ref"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    expectThrows(
      try missingConfirmRegistry.callTool(
        .init(
          name: "git.branch_create",
          arguments: .object(["name": .string("HEAD")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("must not be HEAD"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    expectThrows(
      try missingConfirmRegistry.callTool(
        .init(
          name: "git.branch_create",
          arguments: .object([
            "name": .string("feature/new"),
            "start_point": .string("bad^{ref}"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("start_point"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    let existingRunner = RecordingCommandRunner()
    existingRunner.outputs = [
      RecordingCommandRunner.Output(stdout: "feature/existing\n"),
      RecordingCommandRunner.Output(stdout: "", exitCode: 0),
    ]
    let existingRegistry = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.branch_create"])
        ),
        commandRunner: existingRunner
      ))

    expectThrows(
      try existingRegistry.callTool(
        .init(
          name: "git.branch_create",
          arguments: .object(["name": .string("feature/existing")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("already exists"))
      #expect((existingRunner.calls.count) == (2))
    }

    let failedExistsRunner = RecordingCommandRunner()
    failedExistsRunner.outputs = [
      RecordingCommandRunner.Output(stdout: "feature/fail\n"),
      RecordingCommandRunner.Output(
        stdout: "", stderr: "fatal: not a git repository\n", exitCode: 128),
    ]
    let failedExistsRegistry = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: ["git.branch_create"])
        ),
        commandRunner: failedExistsRunner
      ))

    expectThrows(
      try failedExistsRegistry.callTool(
        .init(
          name: "git.branch_create",
          arguments: .object(["name": .string("feature/fail")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("existence check failed"))
      #expect((failedExistsRunner.calls.count) == (2))
    }
  }

  @Test
  func testGitAddUnstageAndCommitBuildExpectedWriteArgv() throws {
    let runner = RecordingCommandRunner()
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: [
            "git.add", "git.unstage", "git.restore_worktree", "git.commit",
          ])
        ),
        commandRunner: runner
      ))

    let addResult = try provider.callTool(
      .init(
        name: "git.add",
        arguments: .object([
          "paths": .array([.string("Sources"), .string("README.md")]),
          "intent_to_add": .bool(true),
        ]), context: .empty
      ))
    let addPayload = try decodeTextPayload(addResult)

    let unstageResult = try provider.callTool(
      .init(
        name: "git.unstage",
        arguments: .object([
          "paths": .array([.string("Sources"), .string("README.md")])
        ]), context: .empty
      ))
    let unstagePayload = try decodeTextPayload(unstageResult)

    let restoreWorktreeResult = try provider.callTool(
      .init(
        name: "git.restore_worktree",
        arguments: .object([
          "paths": .array([.string("Sources"), .string("README.md")]),
          "dry_run": .bool(false),
          "confirm_discard": .bool(true),
        ]), context: .empty
      ))
    let restoreWorktreePayload = try decodeTextPayload(restoreWorktreeResult)

    let commitResult = try provider.callTool(
      .init(
        name: "git.commit",
        arguments: .object([
          "message": .string("Update gateway atomics"),
          "all": .bool(true),
          "allow_empty": .bool(true),
        ]), context: .empty
      ))
    let commitPayload = try decodeTextPayload(commitResult)

    #expect(
      (runner.calls[0].arguments) == (["add", "--intent-to-add", "--", "Sources", "README.md"]))
    #expect((runner.calls[1].arguments) == (["restore", "--staged", "--", "Sources", "README.md"]))
    #expect(
      (runner.calls[2].arguments) == (["restore", "--worktree", "--", "Sources", "README.md"]))
    #expect(
      (runner.calls[3].arguments)
        == (["commit", "-m", "Update gateway atomics", "--all", "--allow-empty"]))
    #expect((addPayload.objectValue?["operation"]) == (.string("git.add")))
    #expect((unstagePayload.objectValue?["operation"]) == (.string("git.unstage")))
    #expect((restoreWorktreePayload.objectValue?["operation"]) == (.string("git.restore_worktree")))
    #expect((commitPayload.objectValue?["operation"]) == (.string("git.commit")))
    #expect((addPayload.objectValue?["dry_run"]) == (.bool(false)))
    #expect((unstagePayload.objectValue?["dry_run"]) == (.bool(false)))
    #expect((restoreWorktreePayload.objectValue?["dry_run"]) == (.bool(false)))
    #expect((restoreWorktreePayload.objectValue?["confirm_discard"]) == (.bool(true)))
    #expect((commitPayload.objectValue?["dry_run"]) == (.bool(false)))
  }

  @Test
  func testGitWriteAtomicsDryRunBuildPreviewArgv() throws {
    let runner = RecordingCommandRunner()
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: [
            "git.add", "git.unstage", "git.restore_worktree", "git.commit",
          ])
        ),
        commandRunner: runner
      ))

    let addResult = try provider.callTool(
      .init(
        name: "git.add",
        arguments: .object([
          "paths": .array([.string("Sources"), .string("README.md")]),
          "intent_to_add": .bool(true),
          "dry_run": .bool(true),
        ]), context: .empty
      ))
    let addPayload = try decodeTextPayload(addResult)

    let unstageResult = try provider.callTool(
      .init(
        name: "git.unstage",
        arguments: .object([
          "paths": .array([.string("Sources"), .string("README.md")]),
          "dry_run": .bool(true),
        ]), context: .empty
      ))
    let unstagePayload = try decodeTextPayload(unstageResult)

    let restoreWorktreeResult = try provider.callTool(
      .init(
        name: "git.restore_worktree",
        arguments: .object([
          "paths": .array([.string("Sources"), .string("README.md")])
        ]), context: .empty
      ))
    let restoreWorktreePayload = try decodeTextPayload(restoreWorktreeResult)

    let commitResult = try provider.callTool(
      .init(
        name: "git.commit",
        arguments: .object([
          "message": .string("Update gateway atomics"),
          "all": .bool(true),
          "allow_empty": .bool(true),
          "dry_run": .bool(true),
        ]), context: .empty
      ))
    let commitPayload = try decodeTextPayload(commitResult)

    #expect(
      (runner.calls[0].arguments)
        == (["add", "--dry-run", "--intent-to-add", "--", "Sources", "README.md"]))
    #expect(
      (runner.calls[1].arguments)
        == (["diff", "--cached", "--name-only", "--", "Sources", "README.md"]))
    #expect((runner.calls[2].arguments) == (["diff", "--name-only", "--", "Sources", "README.md"]))
    #expect(
      (runner.calls[3].arguments)
        == (["commit", "--dry-run", "-m", "Update gateway atomics", "--all", "--allow-empty"]))
    #expect((addPayload.objectValue?["operation"]) == (.string("git.add")))
    #expect((unstagePayload.objectValue?["operation"]) == (.string("git.unstage")))
    #expect((restoreWorktreePayload.objectValue?["operation"]) == (.string("git.restore_worktree")))
    #expect((commitPayload.objectValue?["operation"]) == (.string("git.commit")))
    #expect((addPayload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((unstagePayload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((restoreWorktreePayload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((restoreWorktreePayload.objectValue?["confirm_discard"]) == (.bool(false)))
    #expect((commitPayload.objectValue?["dry_run"]) == (.bool(true)))
  }

  @Test
  func testGitBuiltinsRequireGitProvider() {
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "echo", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: [
            "git.root", "git.config", "git.remotes", "git.worktrees", "git.stashes",
            "git.stash_show",
            "git.tags",
            "git.tag_show", "git.tag_create", "git.tag_delete", "git.ignored", "git.submodules",
            "git.files", "git.grep", "git.blame", "git.conflicts", "git.file_history",
            "git.file_at_revision", "git.staged_file",
            "git.status", "git.tracking_status", "git.clean_preview", "git.clean", "git.reflog",
            "git.refs", "git.resolve_ref", "git.merge_base", "git.compare_refs", "git.is_ancestor",
            "git.diff_summary", "git.diff_check", "git.branch_create", "git.branch_delete",
            "git.branch_rename", "git.branch_switch", "git.commit_files", "git.add", "git.unstage",
            "git.restore_worktree", "git.stash_push",
          ])
        )
      ))

    expectThrows(
      try provider.callTool(.init(name: "git.root", arguments: .object([:]), context: .empty))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(.init(name: "git.remotes", arguments: .object([:]), context: .empty))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(.init(name: "git.worktrees", arguments: .object([:]), context: .empty))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(.init(name: "git.stashes", arguments: .object([:]), context: .empty))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(.init(name: "git.stash_show", arguments: .object([:]), context: .empty))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(.init(name: "git.tags", arguments: .object([:]), context: .empty))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.tag_show", arguments: .object(["name": .string("v1.0.0")]), context: .empty))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.tag_create", arguments: .object(["name": .string("v1.0.0")]), context: .empty))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.tag_delete", arguments: .object(["name": .string("v1.0.0")]), context: .empty))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.ignored",
          arguments: .object(["paths": .array([.string("build/output.log")])]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(.init(name: "git.submodules", arguments: .object([:]), context: .empty))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(.init(name: "git.files", arguments: .object([:]), context: .empty))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.grep",
          arguments: .object(["query": .string("needle")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.blame",
          arguments: .object(["path": .string("Sources/main.swift")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.file_history",
          arguments: .object(["path": .string("Sources/main.swift")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.file_at_revision",
          arguments: .object(["revision": .string("HEAD"), "path": .string("Sources/main.swift")]),
          context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.staged_file",
          arguments: .object(["path": .string("Sources/main.swift")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(.init(name: "git.conflicts", arguments: .object([:]), context: .empty))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(.init(name: "git.status", arguments: .object([:]), context: .empty))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(
        .init(name: "git.tracking_status", arguments: .object([:]), context: .empty))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(
        .init(name: "git.clean_preview", arguments: .object([:]), context: .empty))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.clean",
          arguments: .object(["paths": .array([.string("build")])]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.commit_files",
          arguments: .object(["revision": .string("HEAD")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(.init(name: "git.reflog", arguments: .object([:]), context: .empty))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(.init(name: "git.refs", arguments: .object([:]), context: .empty))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.resolve_ref",
          arguments: .object(["ref": .string("HEAD")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.merge_base",
          arguments: .object(["refs": .array([.string("main"), .string("topic")])]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.compare_refs",
          arguments: .object(["base": .string("main"), "head": .string("topic")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.is_ancestor",
          arguments: .object([
            "ancestor": .string("main"),
            "descendant": .string("topic"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(
        .init(name: "git.diff_summary", arguments: .object([:]), context: .empty))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(.init(name: "git.diff_check", arguments: .object([:]), context: .empty))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.branch_create",
          arguments: .object(["name": .string("feature/new")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.branch_delete",
          arguments: .object(["name": .string("feature/old")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.branch_rename",
          arguments: .object([
            "old_name": .string("feature/old"),
            "new_name": .string("feature/new"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.branch_switch",
          arguments: .object(["name": .string("feature/target")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.add",
          arguments: .object(["paths": .array([.string("README.md")])]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.unstage",
          arguments: .object(["paths": .array([.string("README.md")])]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.restore_worktree",
          arguments: .object(["paths": .array([.string("README.md")])]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.stash_push",
          arguments: .object([
            "message": .string("save work"),
            "paths": .array([.string("README.md")]),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("registered CLI provider with id 'git'"))
    }
  }

  @Test
  func testGitBuiltinsValidateBounds() {
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: [
            "git.diff", "git.diff_summary", "git.diff_check", "git.clean_preview", "git.clean",
            "git.reflog", "git.refs", "git.compare_refs", "git.file_history",
            "git.file_at_revision", "git.staged_file", "git.commit_files", "git.grep", "git.log",
            "git.ignored", "git.blame", "git.add", "git.unstage", "git.restore_worktree",
            "git.commit", "git.stash_show", "git.stash_push",
          ])
        )
      ))

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.diff",
          arguments: .object(["context_lines": .number(101)]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("context_lines"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.stash_show",
          arguments: .object(["context_lines": .number(101)]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("context_lines"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.stash_show",
          arguments: .object(["stash": .string("main")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("stash@{N}"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.stash_show",
          arguments: .object(["stash": .string("stash@{-1}")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("non-negative integer"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.log",
          arguments: .object(["limit": .number(201)]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("limit"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.diff_summary",
          arguments: .object(["max_results": .number(5_001)]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_results"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.diff_check",
          arguments: .object(["max_results": .number(5_001)]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_results"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.clean_preview",
          arguments: .object(["max_results": .number(5_001)]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_results"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.clean_preview",
          arguments: .object(["include_ignored": .bool(true), "ignored_only": .bool(true)]),
          context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("cannot both be true"))
    }

    expectThrows(
      try provider.callTool(.init(name: "git.clean", arguments: .object([:]), context: .empty))
    ) { error in
      #expect(error.localizedDescription.contains("paths or all_paths"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.clean",
          arguments: .object([
            "paths": .array([.string("build")]),
            "all_paths": .bool(true),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("cannot combine paths"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.clean",
          arguments: .object([
            "paths": .array([.string("build")]),
            "dry_run": .bool(false),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("confirm_delete"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.clean",
          arguments: .object([
            "all_paths": .bool(true),
            "include_ignored": .bool(true),
            "ignored_only": .bool(true),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("cannot both be true"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.reflog",
          arguments: .object(["limit": .number(201)]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("limit"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.reflog",
          arguments: .object(["max_results": .number(201)]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_results"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.refs",
          arguments: .object(["limit": .number(1_001)]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("limit"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.refs",
          arguments: .object(["max_results": .number(1_001)]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_results"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.refs",
          arguments: .object([
            "include_branches": .bool(false),
            "include_remotes": .bool(false),
            "include_tags": .bool(false),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("At least one"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.compare_refs",
          arguments: .object([
            "base": .string("main"),
            "head": .string("topic"),
            "limit": .number(201),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("limit"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.compare_refs",
          arguments: .object([
            "base": .string("main"),
            "head": .string("topic"),
            "max_results": .number(201),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_results"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.compare_refs",
          arguments: .object(["base": .string("-main"), "head": .string("topic")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("base"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.compare_refs",
          arguments: .object(["base": .string("main..topic"), "head": .string("topic")]),
          context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("unsupported Git ref syntax"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.commit_files",
          arguments: .object(["revision": .string("HEAD"), "max_results": .number(5_001)]),
          context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_results"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.commit_files",
          arguments: .object(["revision": .string("HEAD~1")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("revision"))
    }

    expectThrows(
      try provider.callTool(
        .init(name: "git.commit_files", arguments: .object([:]), context: .empty))
    ) { error in
      #expect(error.localizedDescription.contains("revision"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.grep",
          arguments: .object(["query": .string("needle"), "max_results": .number(5_001)]),
          context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_results"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.grep", arguments: .object(["query": .string("")]), context: .empty))
    ) { error in
      #expect(error.localizedDescription.contains("query"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.grep", arguments: .object(["query": .string("a\nb")]), context: .empty))
    ) { error in
      #expect(error.localizedDescription.contains("newlines"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.add",
          arguments: .object(["paths": .array([])]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("requires at least one path"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.unstage",
          arguments: .object(["paths": .array([])]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("requires at least one path"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.restore_worktree",
          arguments: .object(["paths": .array([])]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("requires at least one path"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.restore_worktree",
          arguments: .object([
            "paths": .array([.string("README.md")]),
            "dry_run": .bool(false),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("confirm_discard"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.ignored",
          arguments: .object(["paths": .array([])]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("requires at least one path"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.blame",
          arguments: .object(["path": .string("Sources/main.swift"), "max_lines": .number(1_001)]),
          context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_lines"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.blame",
          arguments: .object(["path": .string("Sources/main.swift"), "start_line": .number(0)]),
          context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("start_line"))
    }

    expectThrows(
      try provider.callTool(.init(name: "git.blame", arguments: .object([:]), context: .empty))
    ) { error in
      #expect(error.localizedDescription.contains("requires path"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.file_history",
          arguments: .object(["path": .string("Sources/main.swift"), "limit": .number(201)]),
          context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("limit"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.file_history",
          arguments: .object(["path": .string("Sources/main.swift"), "max_results": .number(201)]),
          context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_results"))
    }

    expectThrows(
      try provider.callTool(
        .init(name: "git.file_history", arguments: .object([:]), context: .empty))
    ) { error in
      #expect(error.localizedDescription.contains("requires path"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.file_at_revision",
          arguments: .object([
            "revision": .string("HEAD"),
            "path": .string("Sources/main.swift"),
            "max_bytes": .number(1_048_577),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("policy.max_output_bytes"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.file_at_revision",
          arguments: .object(["revision": .string("HEAD~1"), "path": .string("Sources/main.swift")]
          ),
          context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("revision"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.file_at_revision",
          arguments: .object(["revision": .string("HEAD")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("requires path"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.staged_file",
          arguments: .object([
            "path": .string("Sources/main.swift"),
            "max_bytes": .number(1_048_577),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("policy.max_output_bytes"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.staged_file",
          arguments: .object([:]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("requires path"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.commit",
          arguments: .object(["message": .string(String(repeating: "x", count: 10_001))]),
          context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("10000 characters"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.stash_push",
          arguments: .object(["message": .string("save work")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("paths or all_paths"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.stash_push",
          arguments: .object([
            "message": .string(""),
            "all_paths": .bool(true),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("message"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "git.stash_push",
          arguments: .object([
            "message": .string(String(repeating: "x", count: 10_001)),
            "all_paths": .bool(true),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("10000 characters"))
    }
  }

  @Test
  func testGitBuiltinsRejectEscapingPaths() {
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration.fixture(
          cli: CLISectionConfig(commands: [CLICommandConfig(id: "git", executable: "/bin/echo")]),
          builtin: BuiltinConfig(enabled: [
            "git.status", "git.diff_summary", "git.diff_check", "git.clean_preview",
            "git.clean", "git.ignored", "git.files", "git.grep", "git.blame", "git.file_history",
            "git.file_at_revision", "git.staged_file", "git.conflicts", "git.add",
            "git.unstage", "git.restore_worktree", "git.stash_show", "git.stash_push",
          ])
        )
      ))

    for path in ["/tmp/file", "../outside", ":(top)README.md"] {
      expectThrows(
        try provider.callTool(
          .init(
            name: "git.status",
            arguments: .object(["paths": .array([.string(path)])]), context: .empty
          ))
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }

      expectThrows(
        try provider.callTool(
          .init(
            name: "git.add",
            arguments: .object(["paths": .array([.string(path)])]), context: .empty
          ))
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }

      expectThrows(
        try provider.callTool(
          .init(
            name: "git.unstage",
            arguments: .object(["paths": .array([.string(path)])]), context: .empty
          ))
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }

      expectThrows(
        try provider.callTool(
          .init(
            name: "git.restore_worktree",
            arguments: .object(["paths": .array([.string(path)])]), context: .empty
          ))
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }

      expectThrows(
        try provider.callTool(
          .init(
            name: "git.stash_push",
            arguments: .object([
              "message": .string("save work"),
              "paths": .array([.string(path)]),
            ]), context: .empty
          ))
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }

      expectThrows(
        try provider.callTool(
          .init(
            name: "git.clean",
            arguments: .object(["paths": .array([.string(path)])]), context: .empty
          ))
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }

      expectThrows(
        try provider.callTool(
          .init(
            name: "git.stash_show",
            arguments: .object(["paths": .array([.string(path)])]), context: .empty
          ))
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }

      expectThrows(
        try provider.callTool(
          .init(
            name: "git.diff_summary",
            arguments: .object(["paths": .array([.string(path)])]), context: .empty
          ))
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }

      expectThrows(
        try provider.callTool(
          .init(
            name: "git.diff_check",
            arguments: .object(["paths": .array([.string(path)])]), context: .empty
          ))
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }

      expectThrows(
        try provider.callTool(
          .init(
            name: "git.clean_preview",
            arguments: .object(["paths": .array([.string(path)])]), context: .empty
          ))
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }

      expectThrows(
        try provider.callTool(
          .init(
            name: "git.ignored",
            arguments: .object(["paths": .array([.string(path)])]), context: .empty
          ))
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }

      expectThrows(
        try provider.callTool(
          .init(
            name: "git.files",
            arguments: .object(["paths": .array([.string(path)])]), context: .empty
          ))
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }

      expectThrows(
        try provider.callTool(
          .init(
            name: "git.grep",
            arguments: .object([
              "query": .string("needle"),
              "paths": .array([.string(path)]),
            ]), context: .empty
          ))
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }

      expectThrows(
        try provider.callTool(
          .init(
            name: "git.blame",
            arguments: .object(["path": .string(path)]), context: .empty
          ))
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }

      expectThrows(
        try provider.callTool(
          .init(
            name: "git.file_history",
            arguments: .object(["path": .string(path)]), context: .empty
          ))
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }

      expectThrows(
        try provider.callTool(
          .init(
            name: "git.file_at_revision",
            arguments: .object(["revision": .string("HEAD"), "path": .string(path)]),
            context: .empty
          ))
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }

      expectThrows(
        try provider.callTool(
          .init(
            name: "git.staged_file",
            arguments: .object(["path": .string(path)]), context: .empty
          ))
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }

      expectThrows(
        try provider.callTool(
          .init(
            name: "git.conflicts",
            arguments: .object(["paths": .array([.string(path)])]), context: .empty
          ))
      ) { error in
        #expect(!(error.localizedDescription.isEmpty))
      }
    }
  }

  private func decodeTextPayload(_ value: JSONValue) throws -> JSONValue {
    let text = try #require(
      value.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

}
