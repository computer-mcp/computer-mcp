import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPProcess
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPToolsGit

@Suite(.nativeIntegration)
struct GitOperationGuardTests {
  @Test
  func ignoredUsesLiteralPathsWithRealGit() throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url
    let git = try testExecutable("git")
    let runner = ProcessCommandRunner(environment: ["PATH": systemUtilityPath, "HOME": root.path])
    let initialized = try runner.run(
      executable: git, arguments: ["init", "--template="], workingDirectory: root,
      environment: [:], timeoutMilliseconds: 10_000, maxOutputBytes: 4096)
    try #require(initialized.exitCode == 0)
    try Data("ignored\n:(glob)*\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
    for path in ["ignored", ":(glob)*", "ordinary", "star*", "star-other"] {
      try Data("file".utf8).write(to: root.appendingPathComponent(path))
    }
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: .init(
          cli: .init(commands: [.init(id: "git", executable: git)]),
          builtin: .init(enabled: ["git.ignored", "git.add"]), projectDirectory: root),
        commandRunner: runner))
    for path in ["ignored", ":(glob)*"] {
      let payload = try decodeTextPayload(
        provider.callTool(
          .init(
            name: "git.ignored", arguments: .object(["paths": .array([.string(path)])]),
            context: .empty)))
      #expect(payload.objectValue?["result"]?.objectValue?["exit_code"] == .integer(0))
      #expect(
        payload.objectValue?["result"]?.objectValue?["stdout"]?.stringValue?.contains(path) == true)
    }
    try FileManager.default.removeItem(at: root.appendingPathComponent(".gitignore"))
    _ = try provider.callTool(
      .init(
        name: "git.add",
        arguments: .object([
          "paths": .array([.string("star*")]), "dry_run": .bool(false),
        ]), context: .empty))
    let staged = try runner.run(
      executable: git, arguments: ["diff", "--cached", "--name-only", "-z"],
      workingDirectory: root, environment: [:], timeoutMilliseconds: 10_000, maxOutputBytes: 4096)
    #expect(staged.stdout == "star*\0")
  }

  @Test
  func hostGitIsolatesOwnerConfigurationAndDisablesLocalPrograms() throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url.appendingPathComponent("repository")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let git = try testExecutable("git")
    let environment = ["PATH": systemUtilityPath, "HOME": temporary.url.path]
    let runner = ProcessCommandRunner(environment: environment)
    func run(_ args: [String]) throws -> String {
      let result = try runner.run(
        executable: git, arguments: ["-c", "core.hooksPath=/dev/null"] + args,
        workingDirectory: root, environment: [:], timeoutMilliseconds: 10_000,
        maxOutputBytes: 1_048_576)
      try #require(result.exitCode == 0, "\(result.stderr)")
      return result.stdout.trimmingCharacters(in: .newlines)
    }
    _ = try run(["init", "-b", "main"])
    _ = try run([
      "-c", "user.name=Initial", "-c", "user.email=initial@example.invalid", "commit",
      "--allow-empty", "-m", "test: initial",
    ])
    _ = try run(["branch", "topic"])
    let marker = temporary.url.appendingPathComponent("executed")
    let program = temporary.url.appendingPathComponent("program")
    try Data("#!/bin/sh\ntouch '\(marker.path)'\ncat\n".utf8).write(to: program)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
    let owner = temporary.url.appendingPathComponent("owner.config")
    for (key, value) in [
      ("user.name", "Owner Identity"), ("user.email", "owner@example.invalid"),
      ("rebase.instructionFormat", "%s%nexec '\(program.path)'"),
      ("core.hooksPath", root.appendingPathComponent(".git/hooks").path),
    ] {
      _ = try run(["config", "--file", owner.path, key, value])
    }
    for hook in ["post-checkout", "post-merge", "pre-rebase", "reference-transaction"] {
      let path = root.appendingPathComponent(".git/hooks/\(hook)")
      try Data("#!/bin/sh\n'\(program.path)'\n".utf8).write(to: path)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }
    for key in [
      "sequence.editor", "core.editor", "core.pager", "core.sshCommand", "core.fsmonitor",
      "core.askPass", "credential.helper", "credential.https://example.invalid.helper",
      "gpg.program", "gpg.openpgp.program", "gpg.x509.program", "gpg.ssh.program",
      "gpg.ssh.defaultKeyCommand", "diff.external", "diff.custom.command", "diff.custom.textconv",
      "merge.custom.driver", "filter.custom.clean", "filter.custom.smudge", "filter.custom.process",
      "uploadpack.packObjectsHook", "hook.custom.command",
    ] {
      _ = try run(["config", key, program.path])
    }
    _ = try run(["config", "core.hooksPath", root.appendingPathComponent(".git/hooks").path])
    _ = try run(["config", "hook.custom.event", "post-checkout"])
    _ = try run(["config", "rebase.instructionFormat", "%s%nexec '\(program.path)'"])
    let strategy = temporary.url.appendingPathComponent("git-merge-guard")
    try Data("#!/bin/sh\ntouch '\(marker.path)'\nexit 2\n".utf8).write(to: strategy)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: strategy.path)
    _ = try run(["config", "branch.main.mergeOptions", "-s guard -s ours"])
    _ = try run(["config", "pull.twohead", "guard ours"])
    _ = try run(["config", "pull.octopus", "guard ours"])
    let tools = ToolEnvironment(
      configuration: .init(projectDirectory: root),
      environment: environment.merging([
        "PATH": temporary.url.path + ":" + systemUtilityPath,
        "GIT_CONFIG_GLOBAL": owner.path, "GIT_CONFIG_SYSTEM": owner.path,
        "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.hooksPath",
        "GIT_CONFIG_VALUE_0": root.appendingPathComponent(".git/hooks").path,
        "GIT_SEQUENCE_EDITOR": program.path,
      ]) { _, value in value })
    let command = CLICommandConfig(id: "git", executable: git)
    func host(_ args: [String]) throws -> String {
      let result = try tools.registeredCommands.runHostGit(
        command: command, args: args, timeout: 10_000)
      try #require(result.exitCode == 0, "\(result.stderr)")
      #expect(!FileManager.default.fileExists(atPath: marker.path))
      return result.stdout.trimmingCharacters(in: .newlines)
    }
    let worktree = root.appendingPathComponent("worktree")
    _ = try host(["worktree", "add", "--", worktree.path, "topic"])
    var worktreeCommand = command
    worktreeCommand.cwd = worktree.path
    let commit = try tools.registeredCommands.runHostGit(
      command: worktreeCommand, args: ["commit", "--allow-empty", "-m", "test: topic"],
      timeout: 10_000)
    try #require(commit.exitCode == 0, "\(commit.stderr)")
    _ = try host(["merge", "--ff-only", "topic"])
    #expect(
      try host(["log", "-1", "--format=%an <%ae>"]) == "Owner Identity <owner@example.invalid>")
    _ = try host(["worktree", "remove", "--", worktree.path])
    _ = try host(["branch", "-d", "--", "topic"])
    _ = try host(["tag", "-a", "owner-tag", "-m", "test: annotated tag"])
    #expect(
      try host(["cat-file", "-p", "refs/tags/owner-tag"]).contains(
        "tagger Owner Identity <owner@example.invalid>"))
  }

  @Test(arguments: ["include.path", "includeIf.onbranch:topic.path"])
  func hostGitRefusesRepositoryIncludes(key: String) throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url
    let git = try testExecutable("git")
    let runner = ProcessCommandRunner(environment: ["PATH": systemUtilityPath, "HOME": root.path])
    let initialized = try runner.run(
      executable: git, arguments: ["init", "-b", "main"], workingDirectory: root, environment: [:],
      timeoutMilliseconds: 10_000, maxOutputBytes: 4096)
    try #require(initialized.exitCode == 0)
    let tools = ToolEnvironment(configuration: .init(projectDirectory: root), commandRunner: runner)
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: .init(
          cli: .init(commands: [.init(id: "git", executable: git)]),
          builtin: .init(enabled: ["git.status"]), projectDirectory: root),
        commandRunner: runner))
    _ = try provider.callTool(.init(name: "git.status", arguments: nil, context: .empty))
    let changed = try runner.run(
      executable: git, arguments: ["config", key, "missing.config"], workingDirectory: root,
      environment: [:], timeoutMilliseconds: 10_000, maxOutputBytes: 4096)
    try #require(changed.exitCode == 0)
    #expect(
      throws: GatewayToolError.executionFailed(
        "Host Git operations refuse repository configuration includes.")
    ) {
      _ = try provider.callTool(.init(name: "git.status", arguments: nil, context: .empty))
    }
    for args in [
      ["worktree", "add", "new"], ["merge", "topic"], ["rebase", "main"],
      ["worktree", "remove", "new"], ["branch", "-d", "topic"],
    ] {
      #expect(throws: (any Error).self) {
        _ = try tools.registeredCommands.runHostGit(
          command: .init(id: "git", executable: git), args: args, timeout: 10_000)
      }
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("new").path))
  }

  private func decodeTextPayload(_ value: JSONValue) throws -> JSONValue {
    let text = try #require(
      value.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
  }

  @Test
  func revisionsCannotBecomeOptionsAndCommitPreservesOtherStagedChanges() throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url
    let git = try testExecutable("git")
    let runner = ProcessCommandRunner(environment: ["PATH": systemUtilityPath, "HOME": root.path])
    func run(_ args: [String]) throws -> String {
      let result = try runner.run(
        executable: git, arguments: args, workingDirectory: root,
        environment: [:], timeoutMilliseconds: 10_000, maxOutputBytes: 1_048_576)
      #expect(result.exitCode == 0, "\(result.stderr)")
      return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    _ = try run(["init", "-b", "main"])
    _ = try run(["config", "user.name", "Guard Test"])
    _ = try run(["config", "user.email", "guard@example.invalid"])
    _ = try run(["config", "commit.gpgSign", "false"])
    for name in ["selected", "other"] {
      try Data("before".utf8).write(to: root.appendingPathComponent(name))
    }
    _ = try run(["add", "--", "selected", "other"])
    _ = try run(["commit", "-m", "test: initial state"])
    let enabled = [
      "git.show", "git.file_at_revision", "git.commit_files", "git.commit", "git.branch_delete",
    ]
    let provider = GitToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          cli: .init(commands: [.init(id: "git", executable: git)]),
          builtin: .init(enabled: enabled), projectDirectory: root), commandRunner: runner))
    for tool in ["git.show", "git.file_at_revision", "git.commit_files"] {
      #expect(throws: (any Error).self) {
        _ = try provider.callTool(
          .init(
            name: tool,
            arguments: .object([
              "revision": .string("--output=marker"), "path": .string("selected"),
              "patch": .bool(true),
            ]), context: .empty))
      }
      #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("marker").path))
    }
    _ = try run(["tag", "-a", "annotated", "-m", "tag description"])
    for revision in [try run(["rev-parse", "HEAD:selected"]), "HEAD^{tree}", "annotated"] {
      let result = try decodeTextPayload(
        provider.callTool(
          .init(
            name: "git.show", arguments: .object(["revision": .string(revision)]), context: .empty))
      )
      #expect(result.objectValue?["result"]?.objectValue?["exit_code"] == .number(0))
      if revision == "annotated" {
        #expect(
          result.objectValue?["result"]?.objectValue?["stdout"]?.stringValue?.contains(
            "tag description") == true)
      }
    }
    let marker = root.appendingPathComponent("hook-executed")
    let hook = root.appendingPathComponent(".git/hooks/pre-commit")
    try Data("#!/bin/sh\ntouch hook-executed\n".utf8).write(to: hook)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    _ = try run(["config", "hook.configured.command", "touch hook-executed"])
    _ = try run(["config", "hook.configured.event", "pre-commit"])
    try Data("selected change".utf8).write(to: root.appendingPathComponent("selected"))
    try Data("other staged change".utf8).write(to: root.appendingPathComponent("other"))
    _ = try run(["add", "--", "other"])
    let stagedBefore = try run(["rev-parse", ":other"])
    _ = try provider.callTool(
      .init(
        name: "git.commit",
        arguments: .object([
          "message": .string("test: selected change"), "paths": .array([.string("selected")]),
        ]), context: .empty))
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(try run(["show", "HEAD:selected"]) == "selected change")
    #expect(try run(["show", "HEAD:other"]) == "before")
    #expect(try run(["rev-parse", ":other"]) == stagedBefore)
    #expect(try run(["diff", "--cached", "--name-only"]) == "other")
    _ = try run(["config", "hook.evil=x.command", "touch hook-executed"])
    _ = try run(["config", "hook.evil=x.event", "pre-commit"])
    #expect(throws: (any Error).self) {
      _ = try provider.callTool(
        .init(
          name: "git.commit",
          arguments: .object([
            "message": .string("test: malformed program key"),
            "paths": .array([.string("selected")]),
          ]), context: .empty))
    }
    #expect(!FileManager.default.fileExists(atPath: marker.path))

  }
}
