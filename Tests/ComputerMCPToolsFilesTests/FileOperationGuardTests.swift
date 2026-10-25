import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPToolsFiles

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

@Suite(.nativeIntegration)
struct FileOperationGuardTests {
  private func provider(
    _ root: URL, runner: (any CommandRunning)? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    trasher: (any FileTrashing)? = nil
  ) -> FilesToolProvider {
    var executables = ArchiveFixture.extractionExecutables.merging([
      "zipinfo": "zipinfo", "unzip": "unzip", "curl": "curl",
    ]) { _, value in value }
    if let executable = try? testExecutable("zip") { executables["zip"] = executable }
    return FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: [
            "file.write", "file.append", "file.touch", "file.chmod", "file.copy", "file.move",
            "file.mkdir", "file.trash", "file.write_files", "archive.extract", "archive.create",
            "file.download", "file.symlink",
          ]), projectDirectory: root), commandRunner: runner, environment: environment,
        builtinExecutables: executables, fileTrasher: trasher))
  }

  private func call(_ provider: FilesToolProvider, _ name: String, _ arguments: [String: JSONValue])
    throws
  {
    _ = try provider.callTool(.init(name: name, arguments: .object(arguments), context: .empty))
  }

  @discardableResult
  private func git(_ root: URL, _ arguments: [String]) throws -> String {
    let environment = ToolEnvironment(configuration: .init(projectDirectory: root))
    let result = try environment.commandRunner.runIsolated(
      executable: testExecutable("git"),
      arguments: HostGitConfiguration.arguments + arguments, workingDirectory: root,
      environment: [
        "PATH": systemUtilityPath, "HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
      ], timeoutMilliseconds: 10_000, maxOutputBytes: 65_536)
    try #require(result.exitCode == 0, "\(result.stderr)")
    return result.stdout
  }

  private func initializeGit(_ root: URL, directory: URL? = nil) throws {
    try git(
      root, ["init", "--template="] + (directory.map { ["--separate-git-dir=" + $0.path] } ?? []))
  }

  @Test(arguments: [false, true])
  func trashRefusesTheProjectRoot(dryRun: Bool) throws {
    let temporary = try ScopedTemporaryDirectory()
    try initializeGit(temporary.url)
    for path in [".", temporary.url.path] {
      #expect(throws: (any Error).self) {
        try call(
          provider(temporary.url), "file.trash", ["path": .string(path), "dry_run": .bool(dryRun)])
      }
    }
    #expect(
      FileManager.default.fileExists(atPath: temporary.url.appendingPathComponent(".git").path))
  }

  @Test(arguments: ["nested/.git", "nested/.GiT/config"])
  func trashChecksEveryDirectoryMember(path: String) throws {
    let temporary = try ScopedTemporaryDirectory()
    let directory = temporary.url.appendingPathComponent("tree")
    let member = directory.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: member.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("metadata".utf8).write(to: member)
    #expect(throws: metadataError) {
      try call(
        provider(temporary.url), "file.trash", ["path": .string("tree"), "dry_run": .bool(true)])
    }
    #expect(try Data(contentsOf: member) == Data("metadata".utf8))
  }

  @Test(arguments: [false, true])
  func trashAllowsHardLinkedFiles(directory: Bool) throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url.appendingPathComponent("project")
    let tree = root.appendingPathComponent("tree")
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
    let original = temporary.url.appendingPathComponent("original")
    let trash = temporary.url.appendingPathComponent("trash")
    try Data("original".utf8).write(to: original)
    try FileManager.default.linkItem(at: original, to: tree.appendingPathComponent("member"))
    try call(
      provider(root, trasher: GuardTestTrasher(destination: trash)), "file.trash",
      [
        "path": .string(directory ? "tree" : "tree/member")
      ])
    #expect(try Data(contentsOf: original) == Data("original".utf8))
    #expect(
      try Data(contentsOf: directory ? trash.appendingPathComponent("member") : trash)
        == Data("original".utf8))
  }

  @Test(arguments: ["file.write", "file.append", "file.touch", "file.chmod"])
  func hardLinkedFilesAreRejected(tool: String) throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url
    let original = root.appendingPathComponent("original")
    try Data("unchanged".utf8).write(to: original)
    try FileManager.default.linkItem(at: original, to: root.appendingPathComponent("linked"))
    #expect(throws: (any Error).self) {
      try call(
        provider(root), tool,
        ["path": .string("linked"), "content": .string("changed"), "mode": .string("0600")])
    }
    #expect(try Data(contentsOf: original) == Data("unchanged".utf8))
  }

  private let metadataError = GatewayToolError.invalidArguments(
    "[policy.project_denied] File tools cannot write Git metadata or configuration.")

  private func layoutError(_ layout: String) -> GatewayToolError {
    .invalidArguments(
      "[policy.project_denied] \(layout) The project must use a standard Git layout for in-process write tools."
    )
  }

  @Test(
    arguments: [
      "file.write", "file.append", "file.touch", "file.chmod", "file.mkdir", "file.copy",
      "file.move", "file.symlink", "file.trash", "archive.create",
    ],
    [".git", ".git/config", ".GIT", ".GIT/config", "cafe\u{301}/.GiT", "cafe\u{301}/.GiT/config"])
  func gitNamesAreRejectedAsMutationTargets(tool: String, path: String) throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url
    try initializeGit(root)
    let original = try Data(contentsOf: root.appendingPathComponent(".git/config"))
    try Data("ordinary".utf8).write(to: root.appendingPathComponent("ordinary"))
    #expect(throws: metadataError) {
      try call(
        provider(root), tool,
        [
          "path": .string(path), "content": .string("changed"), "mode": .string("0600"),
          "source": .string("ordinary"), "sources": .array([.string("ordinary")]),
          "destination": .string(path), "create_directories": .bool(true),
          "dry_run": .bool(false), "confirm_create": .bool(true),
        ])
    }
    #expect(try Data(contentsOf: root.appendingPathComponent(".git/config")) == original)
    #expect(try Data(contentsOf: root.appendingPathComponent("ordinary")) == Data("ordinary".utf8))
  }

  @Test(arguments: [".git", ".GIT", "cafe\u{301}/.GiT"])
  func gitNamesAreRejectedAsMoveSources(path: String) throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url
    try initializeGit(root)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(path), withIntermediateDirectories: true)
    #expect(throws: metadataError) {
      try call(
        provider(root), "file.move",
        ["source": .string(path), "destination": .string("renamed")])
    }
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("renamed").path))
  }

  @Test(arguments: [".gitconfig", ".config/git/config"])
  func gitConfigurationNamesAreRejected(path: String) throws {
    let temporary = try ScopedTemporaryDirectory()
    #expect(throws: metadataError) {
      try call(
        provider(temporary.url), "file.write",
        ["path": .string(path), "content": .string("changed"), "create_directories": .bool(true)])
    }
    #expect(
      !FileManager.default.fileExists(atPath: temporary.url.appendingPathComponent(path).path))
  }

  @Test(arguments: ["directory", "gitfile"], ["file.write", "file.write_files"])
  func symbolicGitEntryRefusesProjectWrites(kind: String, tool: String) throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try initializeGit(
      root, directory: kind == "gitfile" ? temporary.url.appendingPathComponent("metadata") : nil)
    let marker = root.appendingPathComponent(".git")
    let pointer = root.appendingPathComponent("pointer")
    try FileManager.default.moveItem(at: marker, to: pointer)
    try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: pointer)
    let original = Data("original".utf8)
    try original.write(to: root.appendingPathComponent("ordinary"))
    let arguments: [String: JSONValue] = [
      "path": .string("ordinary"), "content": .string("changed"),
      "files": .array([
        .object(["path": .string("ordinary"), "content": .string("changed")]),
        .object(["path": .string("pointer"), "content": .string("changed")]),
      ]), "overwrite": .bool(true), "dry_run": .bool(false), "confirm_write": .bool(true),
    ]
    #expect(throws: layoutError("The project's .git entry is a symbolic link.")) {
      try call(provider(root), tool, arguments)
    }
    #expect(try Data(contentsOf: root.appendingPathComponent("ordinary")) == original)
  }

  @Test(arguments: ["metadata", "cafe\u{301}/Meta", ".git-store", "Meta "], [false, true])
  func separateGitDirectoryInsideProjectRefusesAllWrites(directory: String, coreWorktree: Bool)
    throws
  {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url
    let metadata = root.appendingPathComponent(directory)
    try FileManager.default.createDirectory(
      at: metadata.deletingLastPathComponent(), withIntermediateDirectories: true)
    try initializeGit(root, directory: metadata)
    if coreWorktree { try git(root, ["config", "core.worktree", root.path]) }
    let head = try Data(contentsOf: metadata.appendingPathComponent("HEAD"))
    #expect(
      throws: layoutError(
        "The project's Git directory is inside the work tree at '\(directory)' without a .git path component."
      )
    ) {
      try call(
        provider(root), "file.write_files",
        [
          "files": .array([
            .object(["path": .string("ordinary"), "content": .string("changed")]),
            .object(["path": .string(directory + "/HEAD"), "content": .string("changed")]),
          ]), "overwrite": .bool(true), "dry_run": .bool(false), "confirm_write": .bool(true),
        ])
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("ordinary").path))
    #expect(try Data(contentsOf: metadata.appendingPathComponent("HEAD")) == head)
  }

  @Test
  func unavailableGitRefusesUnverifiedProjectLayout() throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url
    let metadata = root.appendingPathComponent("metadata")
    try initializeGit(root, directory: metadata)
    let head = try Data(contentsOf: metadata.appendingPathComponent("HEAD"))
    let tools = provider(root, environment: ["PATH": root.appendingPathComponent("missing").path])
    for path in ["ordinary", "metadata/HEAD"] {
      #expect(
        throws: GatewayToolError.invalidArguments("Cannot safely resolve the project's Git layout.")
      ) {
        try call(tools, "file.write", ["path": .string(path), "content": .string("changed")])
      }
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("ordinary").path))
    #expect(try Data(contentsOf: metadata.appendingPathComponent("HEAD")) == head)
  }

  @Test
  func ancestorRepositoryLayoutIsCheckedForNestedProject() throws {
    let temporary = try ScopedTemporaryDirectory()
    let project = temporary.url.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try initializeGit(temporary.url, directory: project.appendingPathComponent("metadata"))
    #expect(
      throws: layoutError(
        "The project's Git directory is inside the work tree at 'metadata' without a .git path component."
      )
    ) {
      try call(
        provider(project), "file.write",
        ["path": .string("ordinary"), "content": .string("changed")])
    }
    #expect(
      !FileManager.default.fileExists(atPath: project.appendingPathComponent("ordinary").path))
  }

  @Test
  func commonDirectoryInsideProjectRequiresGitName() throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url
    let metadata = root.appendingPathComponent("metadata")
    try initializeGit(root, directory: metadata)
    let marker = root.appendingPathComponent(".git")
    try FileManager.default.removeItem(at: marker)
    try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: false)
    try FileManager.default.copyItem(
      at: metadata.appendingPathComponent("HEAD"), to: marker.appendingPathComponent("HEAD"))
    try Data("../metadata\n".utf8).write(to: marker.appendingPathComponent("commondir"))
    #expect(
      throws: layoutError(
        "The project's Git common directory is inside the work tree at 'metadata' without a .git path component."
      )
    ) {
      try call(
        provider(root), "file.write",
        ["path": .string("ordinary"), "content": .string("changed")])
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("ordinary").path))
  }

  @Test
  func externalGitDirectoryWithRelativeCoreWorktreeAllowsWrites() throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try initializeGit(root, directory: temporary.url.appendingPathComponent("metadata"))
    try git(root, ["config", "core.worktree", "../project"])
    try call(
      provider(root), "file.write", ["path": .string("ordinary"), "content": .string("allowed")])
    #expect(try Data(contentsOf: root.appendingPathComponent("ordinary")) == Data("allowed".utf8))
  }

  @Test
  func linkedWorktreeAllowsOrdinaryWritesAndProtectsItsGitfile() throws {
    let temporary = try ScopedTemporaryDirectory()
    let main = temporary.url.appendingPathComponent("main")
    let root = temporary.url.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: main, withIntermediateDirectories: false)
    try initializeGit(main)
    try git(
      main,
      [
        "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
        "commit", "--allow-empty", "-m", "test: initial",
      ])
    try git(main, ["worktree", "add", "-b", "topic", "--", root.path])
    let marker = try Data(contentsOf: root.appendingPathComponent(".git"))
    let tools = provider(root)
    try call(tools, "file.write", ["path": .string("ordinary"), "content": .string("allowed")])
    try call(
      tools, "file.move", ["source": .string("ordinary"), "destination": .string("renamed")])
    #expect(try Data(contentsOf: root.appendingPathComponent("renamed")) == Data("allowed".utf8))
    for path in [".git", ".git/HEAD"] {
      #expect(throws: metadataError) {
        try call(tools, "file.write", ["path": .string(path), "content": .string("changed")])
      }
    }
    #expect(throws: metadataError) {
      try call(tools, "file.move", ["source": .string(".git"), "destination": .string("pointer")])
    }
    #expect(try Data(contentsOf: root.appendingPathComponent(".git")) == marker)
  }

  @Test
  func filesystemRootProjectAllowsDescendantMutations() throws {
    let temporary = try ScopedTemporaryDirectory()
    let canonical = try #require(realpath(temporary.url.path, nil))
    defer { free(canonical) }
    let root = URL(fileURLWithPath: String(cString: canonical))
    let tools = provider(URL(fileURLWithPath: "/"))
    let target = root.appendingPathComponent("original")
    try call(
      tools, "file.write", ["path": .string(target.path), "content": .string("allowed")])
    let copy = root.appendingPathComponent("copy")
    try call(
      tools, "file.copy",
      ["source": .string(String(target.path.dropFirst())), "destination": .string(copy.path)])
    let moved = root.appendingPathComponent("moved")
    try call(
      tools, "file.move", ["source": .string(copy.path), "destination": .string(moved.path)])
    #expect(try Data(contentsOf: target) == Data("allowed".utf8))
    #expect(try Data(contentsOf: moved) == Data("allowed".utf8))
    #expect(!FileManager.default.fileExists(atPath: copy.path))
  }

  @Test(arguments: ["tar", "zip"])
  func archivesStreamThroughCheckedDescriptors(format: String) throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url
    try Data("round trip".utf8).write(to: root.appendingPathComponent("input"))
    let tools = provider(root)
    if format == "zip", (try? testExecutable("zip")) == nil {
      #expect(
        throws: GatewayToolError.disabled("Builtin command 'zip' is unavailable on this platform.")
      ) {
        try call(
          tools, "archive.create",
          [
            "path": .string("bundle.zip"), "sources": .array([.string("input")]),
            "dry_run": .bool(false), "confirm_create": .bool(true),
          ])
      }
      #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["input"])
      return
    }
    try call(
      tools, "archive.create",
      [
        "path": .string("bundle." + format), "sources": .array([.string("input")]),
        "dry_run": .bool(false), "confirm_create": .bool(true),
      ])
    let extractArguments: [String: JSONValue] = [
      "path": .string("bundle." + format), "destination": .string("output"),
      "create_directories": .bool(true), "dry_run": .bool(false), "confirm_extract": .bool(true),
    ]
    if format == "zip", !ArchiveFixture.zipExtractionAvailable {
      #expect(
        throws: GatewayToolError.disabled(
          "Builtin command 'bsdtar' is unavailable on this platform.")
      ) {
        try call(tools, "archive.extract", extractArguments)
      }
      #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("output").path))
      return
    }
    try call(tools, "archive.extract", extractArguments)
    #expect(
      try Data(contentsOf: root.appendingPathComponent("output/input")) == Data("round trip".utf8))
  }

  @Test(arguments: ["file.copy", "file.move"], ["symlink", "hardlink", "git"])
  func recursiveMembersAreChecked(tool: String, kind: String) throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url
    let source = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let original = root.appendingPathComponent("original")
    try Data("original".utf8).write(to: original)
    if kind == "symlink" {
      try FileManager.default.createSymbolicLink(
        at: source.appendingPathComponent("member"), withDestinationURL: original)
    } else if kind == "hardlink" {
      try FileManager.default.linkItem(at: original, to: source.appendingPathComponent("member"))
    } else {
      try FileManager.default.createDirectory(
        at: source.appendingPathComponent(".git"), withIntermediateDirectories: true)
    }
    #expect(throws: (any Error).self) {
      try call(provider(root), tool, ["source": .string("source"), "destination": .string("copy")])
    }
    #expect(try Data(contentsOf: original) == Data("original".utf8))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("copy").path))
  }

  @Test(arguments: ["parent", "leaf", "hardlink"])
  func downloadRejectsReplacementDuringSubprocess(replacement: String) throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url.appendingPathComponent("project")
    let outside = temporary.url.appendingPathComponent("outside")
    let destination = root.appendingPathComponent("destination")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let sentinel = outside.appendingPathComponent("output")
    try Data("sentinel".utf8).write(to: sentinel)
    let runner = RecordingCommandRunner()
    runner.stdout = "downloaded bytes"
    runner.onRun = { _ in
      if replacement == "parent" {
        try FileManager.default.moveItem(
          at: destination, to: root.appendingPathComponent("original-directory"))
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outside)
      } else if replacement == "leaf" {
        try FileManager.default.createSymbolicLink(
          at: destination.appendingPathComponent("output"), withDestinationURL: sentinel)
      } else {
        try FileManager.default.linkItem(
          at: sentinel, to: destination.appendingPathComponent("output"))
      }
    }
    #expect(throws: (any Error).self) {
      try call(
        provider(root, runner: runner), "file.download",
        [
          "path": .string("destination/output"), "url": .string("https://example.invalid/file"),
          "dry_run": .bool(false), "confirm_download": .bool(true), "overwrite": .bool(true),
        ])
    }
    #expect(try Data(contentsOf: sentinel) == Data("sentinel".utf8))
  }

  @Test(arguments: ["../escape", "/absolute", "link", "hardlink", "fifo", "character"])
  func archiveEntriesAreChecked(entry: String) throws {
    let fixture = try ArchiveFixture()
    defer { fixture.remove() }
    let kind =
      entry == "link"
      ? "symlink" : (["hardlink", "fifo", "character"].contains(entry) ? entry : "file")
    let archive = try fixture.archive([.init(name: entry, kind: kind)])
    let source = fixture.root.appendingPathComponent("input.tar")
    try FileManager.default.moveItem(at: archive, to: source)
    #expect(throws: (any Error).self) {
      try call(
        provider(fixture.root), "archive.extract",
        [
          "path": .string("input.tar"), "destination": .string("output"),
          "create_directories": .bool(true), "dry_run": .bool(false),
          "confirm_extract": .bool(true),
        ])
    }
  }

  @Test(
    arguments: [
      ".git", ".git/config", ".GIT", ".GIT/config", "cafe\u{301}/.GiT", "cafe\u{301}/.GiT/config",
    ],
    ["tar", "zip"])
  func gitNamesAreRejectedAsArchiveEntries(entry: String, format: String) throws {
    let fixture = try ArchiveFixture()
    defer { fixture.remove() }
    let archive = try fixture.archive([.init(name: entry)], format: format)
    try FileManager.default.moveItem(
      at: archive, to: fixture.root.appendingPathComponent("input." + format))
    let expectedError =
      format == "zip" && !ArchiveFixture.zipExtractionAvailable
      ? GatewayToolError.disabled("Builtin command 'bsdtar' is unavailable on this platform.")
      : metadataError
    #expect(throws: expectedError) {
      try call(
        provider(fixture.root), "archive.extract",
        [
          "path": .string("input." + format), "destination": .string("output"),
          "create_directories": .bool(true), "dry_run": .bool(false),
          "confirm_extract": .bool(true),
        ])
    }
    #expect(
      !FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("output").path))
  }

  @Test
  func archiveCannotOverwriteHardlink() throws {
    let fixture = try ArchiveFixture()
    defer { fixture.remove() }
    let archive = try fixture.archive([.init(name: "member", content: "new")])
    try FileManager.default.moveItem(
      at: archive, to: fixture.root.appendingPathComponent("input.tar"))
    try FileManager.default.createDirectory(at: fixture.output, withIntermediateDirectories: true)
    let original = fixture.root.appendingPathComponent("original")
    try Data("original".utf8).write(to: original)
    try FileManager.default.linkItem(
      at: original, to: fixture.output.appendingPathComponent("member"))
    let arguments: [String: JSONValue] = [
      "path": .string("input.tar"), "destination": .string("staging"), "overwrite": .bool(true),
      "dry_run": .bool(false), "confirm_extract": .bool(true),
    ]
    #expect(throws: (any Error).self) {
      try call(provider(fixture.root), "archive.extract", arguments)
    }
    #expect(try Data(contentsOf: original) == Data("original".utf8))
  }
}

private struct GuardTestTrasher: FileTrashing {
  let destination: URL
  func trashItem(at url: URL) throws -> URL? {
    try FileManager.default.moveItem(at: url, to: destination)
    return destination
  }
}
