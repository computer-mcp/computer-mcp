import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPToolsFiles

@Suite(.nativeIntegration, .serialized)
final class FilesToolProviderTests {
  private let builtinExecutables = Dictionary(
    uniqueKeysWithValues: [
      "file", "wc", "du", "mdls", "diff", "curl", "zipinfo", "tar", "bsdtar", "unzip", "zip",
    ].map { ($0, $0) })

  @Test
  func testDisabledBuiltinRejectsDirectToolCall() {
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: .fixture(), builtinExecutables: builtinExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.write",
          arguments: .object([
            "path": .string("blocked.txt"),
            "content": .string("blocked"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("disabled"))
    }
  }

  @Test
  func testEnabledFileBuiltinsReadWriteProjectFiles() throws {
    let directory = try temporaryDirectory()
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.read", "file.read_files", "file.write"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let names = try provider.definitions().map(\.tool.name)
    #expect(names.contains("file.read"))
    #expect(names.contains("file.read_files"))
    #expect(names.contains("file.write"))

    let writeResult = try provider.callTool(
      .init(
        name: "file.write",
        arguments: .object([
          "path": .string("notes/debug.txt"),
          "content": .string("codex ready"),
          "create_directories": .bool(true),
        ]), context: .empty
      ))
    let writePayload = try decodeTextPayload(writeResult)
    #expect((writePayload.objectValue?["bytes_written"]) == (.number(11)))

    let readResult = try provider.callTool(
      .init(
        name: "file.read",
        arguments: .object(["path": .string("notes/debug.txt")]), context: .empty
      ))
    let readPayload = try decodeTextPayload(readResult)
    #expect((readPayload.objectValue?["content"]) == (.string("codex ready")))
    #expect((readPayload.objectValue?["truncated"]) == (.bool(false)))

    try "follow-up".write(
      to: directory.appendingPathComponent("notes/todo.md"),
      atomically: true,
      encoding: .utf8
    )
    let batchResult = try provider.callTool(
      .init(
        name: "file.read_files",
        arguments: .object([
          "paths": .array([.string("notes/debug.txt"), .string("notes/todo.md")]),
          "max_bytes_per_file": .number(64),
        ]), context: .empty
      ))
    let batchPayload = try decodeTextPayload(batchResult)
    let files = try #require(batchPayload.objectValue?["files"]?.arrayValue)
    #expect((batchPayload.objectValue?["operation"]) == (.string("file.read_files")))
    #expect((batchPayload.objectValue?["file_count"]) == (.number(2)))
    #expect((batchPayload.objectValue?["truncated_file_count"]) == (.number(0)))
    #expect((files[0].objectValue?["project_relative_path"]) == (.string("notes/debug.txt")))
    #expect((files[0].objectValue?["content"]) == (.string("codex ready")))
    #expect((files[1].objectValue?["project_relative_path"]) == (.string("notes/todo.md")))
    #expect((files[1].objectValue?["content"]) == (.string("follow-up")))
  }

  @Test
  func testFileReadFilesSupportsBase64AndTruncation() throws {
    let directory = try temporaryDirectory()
    let binaryURL = directory.appendingPathComponent("blob.bin")
    try Data([0xff, 0xfe, 0xfd, 0xfc]).write(to: binaryURL)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.read_files"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.read_files",
        arguments: .object([
          "paths": .array([.string("blob.bin")]),
          "encoding": .string("base64"),
          "max_bytes_per_file": .number(3),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let file = try #require(payload.objectValue?["files"]?.arrayValue?.first?.objectValue)
    #expect((payload.objectValue?["encoding"]) == (.string("base64")))
    #expect((payload.objectValue?["total_bytes_read"]) == (.number(3)))
    #expect((payload.objectValue?["truncated_file_count"]) == (.number(1)))
    #expect((file["content"]) == (.string("//79")))
    #expect((file["bytes_read"]) == (.number(3)))
    #expect((file["truncated"]) == (.bool(true)))
    #expect((file["valid_utf8"]) == (.bool(false)))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.read_files",
          arguments: .object([
            "paths": .array([.string(".")])
          ]), context: .empty
        ))
    )
  }

  @Test
  func testFileWriteDryRunDoesNotCreateDirectoriesOrWriteFile() throws {
    let directory = try temporaryDirectory()
    let target = directory.appendingPathComponent("notes/debug.txt")
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.write"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.write",
        arguments: .object([
          "path": .string("notes/debug.txt"),
          "content": .string("codex ready"),
          "create_directories": .bool(true),
          "dry_run": .bool(true),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let preview = payload.objectValue?["preview"]?.objectValue

    #expect(!(FileManager.default.fileExists(atPath: target.path)))
    #expect((payload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((payload.objectValue?["written"]) == (.bool(false)))
    #expect((payload.objectValue?["would_create"]) == (.bool(true)))
    #expect((payload.objectValue?["would_create_parent_directories"]) == (.bool(true)))
    #expect((payload.objectValue?["bytes_to_write"]) == (.number(11)))
    #expect((payload.objectValue?["bytes_written"]) == (.number(0)))
    #expect((preview?["content"]) == (.string("codex ready")))
    #expect((preview?["content_truncated"]) == (.bool(false)))
  }

  @Test
  func testFileWriteRejectsNonexistentTargetThroughEscapingSymlink() throws {
    let container = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: container) }
    let project = container.appendingPathComponent("project", isDirectory: true)
    let outside = container.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: project.appendingPathComponent("escape"),
      withDestinationURL: outside
    )
    let outsideTarget = outside.appendingPathComponent("written.txt")
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.write"]),
          projectDirectory: project
        ), builtinExecutables: builtinExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.write",
          arguments: .object([
            "path": .string("escape/written.txt"),
            "content": .string("must not escape"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("policy.project_denied"))
    }
    #expect(!FileManager.default.fileExists(atPath: outsideTarget.path))
  }

  @Test
  func testFileSymlinkRejectsDestinationThroughEscapingSymlink() throws {
    let container = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: container) }
    let project = container.appendingPathComponent("project", isDirectory: true)
    let outside = container.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: project.appendingPathComponent("escape"),
      withDestinationURL: outside
    )
    let link = project.appendingPathComponent("new-link")
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.symlink"]),
          projectDirectory: project
        ), builtinExecutables: builtinExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.symlink",
          arguments: .object([
            "path": .string("new-link"),
            "destination": .string("escape/future.txt"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("policy.project_denied"))
    }
    #expect(!FileManager.default.fileExists(atPath: link.path))
  }

  @Test
  func testFileWriteFilesDryRunAndConfirmedWrite() throws {
    let directory = try temporaryDirectory()
    let first = directory.appendingPathComponent("notes/one.txt")
    let second = directory.appendingPathComponent("notes/two.txt")
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.write_files"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let dryRunResult = try provider.callTool(
      .init(
        name: "file.write_files",
        arguments: .object([
          "files": .array([
            .object(["path": .string("notes/one.txt"), "content": .string("hello world")]),
            .object(["path": .string("notes/two.txt"), "content": .string("")]),
          ]),
          "create_directories": .bool(true),
          "preview_max_bytes": .number(5),
        ]), context: .empty
      ))
    let dryRunPayload = try decodeTextPayload(dryRunResult)
    let dryRunFiles = try #require(dryRunPayload.objectValue?["files"]?.arrayValue)
    #expect((dryRunPayload.objectValue?["operation"]) == (.string("file.write_files")))
    #expect((dryRunPayload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((dryRunPayload.objectValue?["total_bytes_to_write"]) == (.number(11)))
    #expect((dryRunPayload.objectValue?["total_bytes_written"]) == (.number(0)))
    #expect((dryRunFiles[0].objectValue?["project_relative_path"]) == (.string("notes/one.txt")))
    #expect((dryRunFiles[0].objectValue?["would_create"]) == (.bool(true)))
    #expect((dryRunFiles[0].objectValue?["would_create_parent_directories"]) == (.bool(true)))
    #expect((dryRunFiles[0].objectValue?["preview"]?.objectValue?["content"]) == (.string("hello")))
    #expect(
      (dryRunFiles[0].objectValue?["preview"]?.objectValue?["content_truncated"]) == (.bool(true)))
    #expect(!(FileManager.default.fileExists(atPath: first.path)))
    #expect(!(FileManager.default.fileExists(atPath: second.path)))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.write_files",
          arguments: .object([
            "files": .array([
              .object(["path": .string("notes/one.txt"), "content": .string("hello")])
            ]),
            "create_directories": .bool(true),
            "dry_run": .bool(false),
          ]), context: .empty
        ))
    )

    let writeResult = try provider.callTool(
      .init(
        name: "file.write_files",
        arguments: .object([
          "files": .array([
            .object(["path": .string("notes/one.txt"), "content": .string("hello world")]),
            .object(["path": .string("notes/two.txt"), "content": .string("")]),
          ]),
          "create_directories": .bool(true),
          "dry_run": .bool(false),
          "confirm_write": .bool(true),
        ]), context: .empty
      ))
    let writePayload = try decodeTextPayload(writeResult)
    #expect((writePayload.objectValue?["written"]) == (.bool(true)))
    #expect((writePayload.objectValue?["total_bytes_written"]) == (.number(11)))
    #expect((try String(contentsOf: first, encoding: .utf8)) == ("hello world"))
    #expect((try String(contentsOf: second, encoding: .utf8)) == (""))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.write_files",
          arguments: .object([
            "files": .array([
              .object(["path": .string("notes/one.txt"), "content": .string("again")])
            ])
          ]), context: .empty
        ))
    )
    expectThrows(
      try provider.callTool(
        .init(
          name: "file.write_files",
          arguments: .object([
            "files": .array([
              .object(["path": .string("notes/three.txt"), "content": .string("a")]),
              .object(["path": .string("notes/three.txt"), "content": .string("b")]),
            ]),
            "create_directories": .bool(true),
          ]), context: .empty
        ))
    )
  }

  @Test
  func testFileExistsReturnsPresenceWithoutStatError() throws {
    let directory = try temporaryDirectory()
    try "hello".write(
      to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("logs"),
      withIntermediateDirectories: true
    )
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.exists"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let fileResult = try provider.callTool(
      .init(
        name: "file.exists",
        arguments: .object(["path": .string("notes.txt")]), context: .empty
      ))
    let filePayload = try decodeTextPayload(fileResult)
    #expect((filePayload.objectValue?["exists"]) == (.bool(true)))
    #expect((filePayload.objectValue?["is_file"]) == (.bool(true)))
    #expect((filePayload.objectValue?["is_directory"]) == (.bool(false)))

    let directoryResult = try provider.callTool(
      .init(
        name: "file.exists",
        arguments: .object(["path": .string("logs")]), context: .empty
      ))
    let directoryPayload = try decodeTextPayload(directoryResult)
    #expect((directoryPayload.objectValue?["exists"]) == (.bool(true)))
    #expect((directoryPayload.objectValue?["is_directory"]) == (.bool(true)))

    let missingResult = try provider.callTool(
      .init(
        name: "file.exists",
        arguments: .object(["path": .string("missing.txt")]), context: .empty
      ))
    let missingPayload = try decodeTextPayload(missingResult)
    #expect((missingPayload.objectValue?["exists"]) == (.bool(false)))
    #expect((missingPayload.objectValue?["is_file"]) == (.null))
    #expect((missingPayload.objectValue?["project_relative_path"]) == (.string("missing.txt")))
  }

  @Test
  func testFileExistsRejectsProjectEscape() throws {
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.exists"]),
          projectDirectory: try temporaryDirectory()
        ), builtinExecutables: builtinExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.exists",
          arguments: .object(["path": .string("../outside")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }
  }

  @Test
  func testFileAppendAddsContentWithoutOverwriting() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "first".write(to: file, atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.append"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.append",
        arguments: .object([
          "path": .string("notes.txt"),
          "content": .string(" second"),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let content = try String(contentsOf: file, encoding: .utf8)

    #expect((content) == ("first second"))
    #expect((payload.objectValue?["created"]) == (.bool(false)))
    #expect((payload.objectValue?["bytes_appended"]) == (.number(7)))
    #expect((payload.objectValue?["size_before_bytes"]) == (.number(5)))
    #expect((payload.objectValue?["size_after_bytes"]) == (.number(12)))
  }

  @Test
  func testFileAppendCanCreateMissingFileWithNewline() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("logs/session.txt")
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.append"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.append",
        arguments: .object([
          "path": .string("logs/session.txt"),
          "content": .string("created"),
          "create_directories": .bool(true),
          "append_newline": .bool(true),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let content = try String(contentsOf: file, encoding: .utf8)

    #expect((content) == ("created\n"))
    #expect((payload.objectValue?["created"]) == (.bool(true)))
    #expect((payload.objectValue?["append_newline"]) == (.bool(true)))
    #expect((payload.objectValue?["bytes_appended"]) == (.number(8)))
  }

  @Test
  func testFileAppendDryRunDoesNotCreateOrAppend() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("logs/session.txt")
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.append"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.append",
        arguments: .object([
          "path": .string("logs/session.txt"),
          "content": .string("created"),
          "create_directories": .bool(true),
          "append_newline": .bool(true),
          "dry_run": .bool(true),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let preview = payload.objectValue?["preview"]?.objectValue

    #expect(!(FileManager.default.fileExists(atPath: file.path)))
    #expect((payload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((payload.objectValue?["created"]) == (.bool(false)))
    #expect((payload.objectValue?["would_create"]) == (.bool(true)))
    #expect((payload.objectValue?["would_create_parent_directories"]) == (.bool(true)))
    #expect((payload.objectValue?["bytes_to_append"]) == (.number(8)))
    #expect((payload.objectValue?["bytes_appended"]) == (.number(0)))
    #expect((payload.objectValue?["size_before_bytes"]) == (.number(0)))
    #expect((payload.objectValue?["size_after_bytes"]) == (.number(8)))
    #expect((preview?["content"]) == (.string("created\n")))
    #expect((preview?["content_truncated"]) == (.bool(false)))
  }

  @Test
  func testFileAppendRejectsDirectoryEscapeAndOversizedContent() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("logs"),
      withIntermediateDirectories: true
    )
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          policy: PolicyConfig(maxOutputBytes: 3),
          builtin: BuiltinConfig(enabled: ["file.append"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.append",
          arguments: .object(["path": .string("logs"), "content": .string("x")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("directory"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.append",
          arguments: .object(["path": .string("../outside"), "content": .string("x")]),
          context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.append",
          arguments: .object(["path": .string("notes.txt"), "content": .string("long")]),
          context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_output_bytes"))
    }
  }

  @Test
  func testFileReplaceTextReplacesFirstMatchByDefault() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "alpha beta beta".write(to: file, atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.replace_text"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.replace_text",
        arguments: .object([
          "path": .string("notes.txt"),
          "search": .string("beta"),
          "replacement": .string("gamma"),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let content = try String(contentsOf: file, encoding: .utf8)

    #expect((content) == ("alpha gamma beta"))
    #expect((payload.objectValue?["total_matches"]) == (.number(2)))
    #expect((payload.objectValue?["replacements"]) == (.number(1)))
    #expect((payload.objectValue?["changed"]) == (.bool(true)))
  }

  @Test
  func testFileReplaceTextCanReplaceAllWithExpectedCountAndEmptyReplacement() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one two two two".write(to: file, atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.replace_text"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.replace_text",
        arguments: .object([
          "path": .string("notes.txt"),
          "search": .string("two"),
          "replacement": .string(""),
          "replace_all": .bool(true),
          "expected_replacements": .number(3),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let content = try String(contentsOf: file, encoding: .utf8)

    #expect((content) == ("one   "))
    #expect((payload.objectValue?["replace_all"]) == (.bool(true)))
    #expect((payload.objectValue?["total_matches"]) == (.number(3)))
    #expect((payload.objectValue?["replacements"]) == (.number(3)))
  }

  @Test
  func testFileReplaceTextDryRunReturnsCountsAndPreviewWithoutWriting() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one two two".write(to: file, atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.replace_text"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.replace_text",
        arguments: .object([
          "path": .string("notes.txt"),
          "search": .string("two"),
          "replacement": .string("three"),
          "replace_all": .bool(true),
          "expected_replacements": .number(2),
          "dry_run": .bool(true),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let preview = payload.objectValue?["preview"]?.objectValue
    let content = try String(contentsOf: file, encoding: .utf8)

    #expect((content) == ("one two two"))
    #expect((payload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((payload.objectValue?["total_matches"]) == (.number(2)))
    #expect((payload.objectValue?["replacements"]) == (.number(2)))
    #expect((payload.objectValue?["would_change"]) == (.bool(true)))
    #expect((payload.objectValue?["changed"]) == (.bool(false)))
    #expect((preview?["search"]) == (.string("two")))
    #expect((preview?["search_truncated"]) == (.bool(false)))
    #expect((preview?["replacement"]) == (.string("three")))
    #expect((preview?["replacement_truncated"]) == (.bool(false)))
  }

  @Test
  func testFileReplaceTextPreviewCanBeRequestedAndTruncated() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "abcdef abcdef".write(to: file, atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.replace_text"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.replace_text",
        arguments: .object([
          "path": .string("notes.txt"),
          "search": .string("abcdef"),
          "replacement": .string("uvwxyz"),
          "include_preview": .bool(true),
          "preview_max_bytes": .number(3),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let preview = payload.objectValue?["preview"]?.objectValue
    let content = try String(contentsOf: file, encoding: .utf8)

    #expect((content) == ("uvwxyz abcdef"))
    #expect((payload.objectValue?["dry_run"]) == (.bool(false)))
    #expect((payload.objectValue?["would_change"]) == (.bool(true)))
    #expect((payload.objectValue?["changed"]) == (.bool(true)))
    #expect((preview?["search"]) == (.string("abc")))
    #expect((preview?["search_truncated"]) == (.bool(true)))
    #expect((preview?["replacement"]) == (.string("uvw")))
    #expect((preview?["replacement_truncated"]) == (.bool(true)))
  }

  @Test
  func testFileReplaceTextExpectedMismatchDoesNotWrite() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one two two".write(to: file, atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.replace_text"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.replace_text",
          arguments: .object([
            "path": .string("notes.txt"),
            "search": .string("two"),
            "replacement": .string("three"),
            "replace_all": .bool(true),
            "expected_replacements": .number(1),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Expected 1 replacements"))
    }

    #expect((try String(contentsOf: file, encoding: .utf8)) == ("one two two"))
  }

  @Test
  func testFileReplaceTextRejectsDirectoryEscapeAndOversizedFile() throws {
    let directory = try temporaryDirectory()
    try "abcdef".write(
      to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.replace_text"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.replace_text",
          arguments: .object([
            "path": .string("../outside"),
            "search": .string("a"),
            "replacement": .string("b"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.replace_text",
          arguments: .object([
            "path": .string("notes.txt"),
            "search": .string("a"),
            "replacement": .string("b"),
            "max_bytes": .number(3),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_bytes"))
    }
  }

  @Test
  func testFileInsertTextInsertsBeforeLineWithExpectedLine() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one\ntwo\nthree\n".write(to: file, atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.insert_text"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.insert_text",
        arguments: .object([
          "path": .string("notes.txt"),
          "line": .number(2),
          "content": .string("inserted"),
          "expected_line": .string("two"),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let content = try String(contentsOf: file, encoding: .utf8)

    #expect((content) == ("one\ninserted\ntwo\nthree\n"))
    #expect((payload.objectValue?["line"]) == (.number(2)))
    #expect((payload.objectValue?["position"]) == (.string("before")))
    #expect((payload.objectValue?["line_count_before"]) == (.number(3)))
    #expect((payload.objectValue?["changed"]) == (.bool(true)))
  }

  @Test
  func testFileInsertTextCanInsertAfterLastLineWithoutTrailingNewline() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one\ntwo".write(to: file, atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.insert_text"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.insert_text",
        arguments: .object([
          "path": .string("notes.txt"),
          "line": .number(2),
          "position": .string("after"),
          "content": .string("three"),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let content = try String(contentsOf: file, encoding: .utf8)

    #expect((content) == ("one\ntwo\nthree\n"))
    #expect((payload.objectValue?["position"]) == (.string("after")))
    #expect((payload.objectValue?["bytes_inserted"]) == (.number(7)))
  }

  @Test
  func testFileInsertTextMatchesLastLineWithoutTrailingNewlineText() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one\ntwo\n".write(to: file, atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.insert_text"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    _ = try provider.callTool(
      .init(
        name: "file.insert_text",
        arguments: .object([
          "path": .string("notes.txt"),
          "line": .number(2),
          "position": .string("after"),
          "content": .string("three"),
          "expected_line": .string("two"),
        ]), context: .empty
      ))

    let content = try String(contentsOf: file, encoding: .utf8)
    #expect((content) == ("one\ntwo\nthree\n"))
  }

  @Test
  func testFileInsertTextDryRunReturnsPreviewWithoutWriting() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one\ntwo\nthree\n".write(to: file, atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.insert_text"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.insert_text",
        arguments: .object([
          "path": .string("notes.txt"),
          "line": .number(2),
          "content": .string("inserted"),
          "expected_line": .string("two"),
          "dry_run": .bool(true),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let preview = payload.objectValue?["preview"]?.objectValue
    let content = try String(contentsOf: file, encoding: .utf8)

    #expect((content) == ("one\ntwo\nthree\n"))
    #expect((payload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((payload.objectValue?["would_change"]) == (.bool(true)))
    #expect((payload.objectValue?["changed"]) == (.bool(false)))
    #expect((preview?["target_line"]) == (.string("two")))
    #expect((preview?["target_line_truncated"]) == (.bool(false)))
    #expect((preview?["inserted_content"]) == (.string("inserted\n")))
    #expect((preview?["inserted_content_truncated"]) == (.bool(false)))
  }

  @Test
  func testFileInsertTextPreviewCanBeRequestedAndTruncated() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "abcdef\n".write(to: file, atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.insert_text"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.insert_text",
        arguments: .object([
          "path": .string("notes.txt"),
          "line": .number(1),
          "content": .string("uvwxyz"),
          "append_newline": .bool(false),
          "include_preview": .bool(true),
          "preview_max_bytes": .number(3),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let preview = payload.objectValue?["preview"]?.objectValue
    let content = try String(contentsOf: file, encoding: .utf8)

    #expect((content) == ("uvwxyzabcdef\n"))
    #expect((payload.objectValue?["dry_run"]) == (.bool(false)))
    #expect((payload.objectValue?["would_change"]) == (.bool(true)))
    #expect((payload.objectValue?["changed"]) == (.bool(true)))
    #expect((preview?["target_line"]) == (.string("abc")))
    #expect((preview?["target_line_truncated"]) == (.bool(true)))
    #expect((preview?["inserted_content"]) == (.string("uvw")))
    #expect((preview?["inserted_content_truncated"]) == (.bool(true)))
  }

  @Test
  func testFileInsertTextExpectedLineMismatchDoesNotWrite() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one\ntwo\n".write(to: file, atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.insert_text"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.insert_text",
          arguments: .object([
            "path": .string("notes.txt"),
            "line": .number(2),
            "content": .string("inserted"),
            "expected_line": .string("wrong"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("expected_line"))
    }

    #expect((try String(contentsOf: file, encoding: .utf8)) == ("one\ntwo\n"))
  }

  @Test
  func testFileInsertTextRejectsBadPositionLineEscapeAndOversizedFile() throws {
    let directory = try temporaryDirectory()
    try "one\ntwo\n".write(
      to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.insert_text"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.insert_text",
          arguments: .object([
            "path": .string("notes.txt"),
            "line": .number(1),
            "position": .string("middle"),
            "content": .string("x"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("position"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.insert_text",
          arguments: .object([
            "path": .string("notes.txt"),
            "line": .number(3),
            "content": .string("x"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("line must be between"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.insert_text",
          arguments: .object([
            "path": .string("../outside"),
            "line": .number(1),
            "content": .string("x"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.insert_text",
          arguments: .object([
            "path": .string("notes.txt"),
            "line": .number(1),
            "content": .string("x"),
            "max_bytes": .number(3),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_bytes"))
    }
  }

  @Test
  func testFileReplaceLinesReplacesRangeWithExpectedContent() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one\ntwo\nthree\nfour\n".write(to: file, atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.replace_lines"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.replace_lines",
        arguments: .object([
          "path": .string("notes.txt"),
          "start_line": .number(2),
          "end_line": .number(3),
          "content": .string("middle"),
          "expected_content": .string("two\nthree\n"),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let content = try String(contentsOf: file, encoding: .utf8)

    #expect((content) == ("one\nmiddle\nfour\n"))
    #expect((payload.objectValue?["start_line"]) == (.number(2)))
    #expect((payload.objectValue?["end_line"]) == (.number(3)))
    #expect((payload.objectValue?["line_count_before"]) == (.number(4)))
    #expect((payload.objectValue?["deleted_line_count"]) == (.number(2)))
    #expect((payload.objectValue?["inserted_line_count"]) == (.number(1)))
    #expect((payload.objectValue?["changed"]) == (.bool(true)))
  }

  @Test
  func testFileReplaceLinesCanDeleteLastLineWithoutTrailingNewline() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one\ntwo\nthree".write(to: file, atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.replace_lines"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.replace_lines",
        arguments: .object([
          "path": .string("notes.txt"),
          "start_line": .number(3),
          "end_line": .number(3),
          "content": .string(""),
          "expected_content": .string("three"),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let content = try String(contentsOf: file, encoding: .utf8)

    #expect((content) == ("one\ntwo\n"))
    #expect((payload.objectValue?["deleted_line_count"]) == (.number(1)))
    #expect((payload.objectValue?["inserted_line_count"]) == (.number(0)))
    #expect((payload.objectValue?["bytes_inserted"]) == (.number(0)))
  }

  @Test
  func testFileReplaceLinesDryRunReturnsPreviewWithoutWriting() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one\ntwo\nthree\n".write(to: file, atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.replace_lines"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.replace_lines",
        arguments: .object([
          "path": .string("notes.txt"),
          "start_line": .number(2),
          "end_line": .number(2),
          "content": .string("updated"),
          "dry_run": .bool(true),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let preview = payload.objectValue?["preview"]?.objectValue
    let content = try String(contentsOf: file, encoding: .utf8)

    #expect((content) == ("one\ntwo\nthree\n"))
    #expect((payload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((payload.objectValue?["would_change"]) == (.bool(true)))
    #expect((payload.objectValue?["changed"]) == (.bool(false)))
    #expect((preview?["selected_content"]) == (.string("two\n")))
    #expect((preview?["selected_truncated"]) == (.bool(false)))
    #expect((preview?["replacement_content"]) == (.string("updated\n")))
    #expect((preview?["replacement_truncated"]) == (.bool(false)))
  }

  @Test
  func testFileReplaceLinesPreviewCanBeRequestedAndTruncated() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "abcdef\n".write(to: file, atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.replace_lines"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.replace_lines",
        arguments: .object([
          "path": .string("notes.txt"),
          "start_line": .number(1),
          "end_line": .number(1),
          "content": .string("uvwxyz"),
          "append_newline": .bool(false),
          "include_preview": .bool(true),
          "preview_max_bytes": .number(3),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let preview = payload.objectValue?["preview"]?.objectValue
    let content = try String(contentsOf: file, encoding: .utf8)

    #expect((content) == ("uvwxyz"))
    #expect((payload.objectValue?["dry_run"]) == (.bool(false)))
    #expect((payload.objectValue?["would_change"]) == (.bool(true)))
    #expect((payload.objectValue?["changed"]) == (.bool(true)))
    #expect((preview?["selected_content"]) == (.string("abc")))
    #expect((preview?["selected_truncated"]) == (.bool(true)))
    #expect((preview?["replacement_content"]) == (.string("uvw")))
    #expect((preview?["replacement_truncated"]) == (.bool(true)))
  }

  @Test
  func testFileReplaceLinesRejectsMismatchRangeEscapeAndOversizedFile() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one\ntwo\nthree\n".write(to: file, atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.replace_lines"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.replace_lines",
          arguments: .object([
            "path": .string("notes.txt"),
            "start_line": .number(2),
            "end_line": .number(2),
            "content": .string("updated"),
            "expected_content": .string("wrong\n"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("expected_content"))
    }

    #expect((try String(contentsOf: file, encoding: .utf8)) == ("one\ntwo\nthree\n"))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.replace_lines",
          arguments: .object([
            "path": .string("notes.txt"),
            "start_line": .number(3),
            "end_line": .number(2),
            "content": .string("x"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("end_line"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.replace_lines",
          arguments: .object([
            "path": .string("../outside"),
            "start_line": .number(1),
            "end_line": .number(1),
            "content": .string("x"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.replace_lines",
          arguments: .object([
            "path": .string("notes.txt"),
            "start_line": .number(1),
            "end_line": .number(1),
            "content": .string("x"),
            "max_bytes": .number(3),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_bytes"))
    }
  }

  @Test
  func testFileReadLinesReturnsBoundedLineRange() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one\ntwo\nthree\nfour\n".write(to: file, atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.read_lines"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.read_lines",
        arguments: .object([
          "path": .string("notes.txt"),
          "start_line": .number(2),
          "max_lines": .number(2),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let lines = try #require(payload.objectValue?["lines"]?.arrayValue)

    #expect((payload.objectValue?["project_relative_path"]) == (.string("notes.txt")))
    #expect((payload.objectValue?["line_count"]) == (.number(2)))
    #expect((lines[0].objectValue?["line"]) == (.number(2)))
    #expect((lines[0].objectValue?["text"]) == (.string("two")))
    #expect((lines[1].objectValue?["line"]) == (.number(3)))
    #expect((lines[1].objectValue?["text"]) == (.string("three")))
  }

  @Test
  func testFileReadContextReturnsTargetLineNeighborhood() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one\ntwo\nthree\nfour\nfive\n".write(to: file, atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.read_context"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.read_context",
        arguments: .object([
          "path": .string("notes.txt"),
          "line": .number(3),
          "before": .number(1),
          "after": .number(1),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let lines = try #require(payload.objectValue?["lines"]?.arrayValue)

    #expect((payload.objectValue?["operation"]) == (.string("file.read_context")))
    #expect((payload.objectValue?["project_relative_path"]) == (.string("notes.txt")))
    #expect((payload.objectValue?["start_line"]) == (.number(2)))
    #expect((payload.objectValue?["end_line"]) == (.number(4)))
    #expect((payload.objectValue?["start_clamped"]) == (.bool(false)))
    #expect((payload.objectValue?["target_line_returned"]) == (.bool(true)))
    #expect((payload.objectValue?["range_may_be_truncated"]) == (.bool(false)))
    #expect((payload.objectValue?["line_count"]) == (.number(3)))
    #expect((lines[0].objectValue?["line"]) == (.number(2)))
    #expect((lines[0].objectValue?["relative_line"]) == (.number(-1)))
    #expect((lines[0].objectValue?["is_target"]) == (.bool(false)))
    #expect((lines[0].objectValue?["text"]) == (.string("two")))
    #expect((lines[1].objectValue?["line"]) == (.number(3)))
    #expect((lines[1].objectValue?["relative_line"]) == (.number(0)))
    #expect((lines[1].objectValue?["is_target"]) == (.bool(true)))
    #expect((lines[1].objectValue?["text"]) == (.string("three")))

    let clampedResult = try provider.callTool(
      .init(
        name: "file.read_context",
        arguments: .object([
          "path": .string("notes.txt"),
          "line": .number(1),
          "before": .number(5),
          "after": .number(1),
        ]), context: .empty
      ))
    let clampedPayload = try decodeTextPayload(clampedResult)
    #expect((clampedPayload.objectValue?["start_line"]) == (.number(1)))
    #expect((clampedPayload.objectValue?["start_clamped"]) == (.bool(true)))
    #expect((clampedPayload.objectValue?["line_count"]) == (.number(2)))
  }

  @Test
  func testFileReadContextReportsTruncatedRangeAndRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one\ntwo\nthree\n".write(to: file, atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.read_context"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let truncatedResult = try provider.callTool(
      .init(
        name: "file.read_context",
        arguments: .object([
          "path": .string("notes.txt"),
          "line": .number(3),
          "before": .number(0),
          "after": .number(0),
          "max_bytes": .number(4),
        ]), context: .empty
      ))
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["file_truncated"]) == (.bool(true)))
    #expect((truncatedPayload.objectValue?["range_may_be_truncated"]) == (.bool(true)))
    #expect((truncatedPayload.objectValue?["target_line_returned"]) == (.bool(false)))
    #expect((truncatedPayload.objectValue?["line_count"]) == (.number(0)))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.read_context",
          arguments: .object([
            "path": .string("notes.txt"),
            "line": .number(0),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("line"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.read_context",
          arguments: .object([
            "path": .string("notes.txt"),
            "line": .number(1),
            "before": .number(-1),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("before"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.read_context",
          arguments: .object([
            "path": .string("."),
            "line": .number(1),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }
  }

  @Test
  func testFileReadWindowReturnsOffsetTextWindow() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "zero\none\ntwo\n".write(to: file, atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.read_window"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.read_window",
        arguments: .object([
          "path": .string("notes.txt"),
          "offset_bytes": .number(5),
          "max_bytes": .number(3),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["operation"]) == (.string("file.read_window")))
    #expect((payload.objectValue?["project_relative_path"]) == (.string("notes.txt")))
    #expect((payload.objectValue?["offset_bytes"]) == (.number(5)))
    #expect((payload.objectValue?["max_bytes"]) == (.number(3)))
    #expect((payload.objectValue?["bytes_read"]) == (.number(3)))
    #expect((payload.objectValue?["next_offset_bytes"]) == (.number(8)))
    #expect((payload.objectValue?["eof"]) == (.bool(false)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
    #expect((payload.objectValue?["valid_utf8"]) == (.bool(true)))
    #expect((payload.objectValue?["content"]) == (.string("one")))

    let eofResult = try provider.callTool(
      .init(
        name: "file.read_window",
        arguments: .object([
          "path": .string("notes.txt"),
          "offset_bytes": .number(10_000),
          "max_bytes": .number(10),
        ]), context: .empty
      ))
    let eofPayload = try decodeTextPayload(eofResult)
    #expect((eofPayload.objectValue?["bytes_read"]) == (.number(0)))
    #expect((eofPayload.objectValue?["eof"]) == (.bool(true)))
    #expect((eofPayload.objectValue?["content"]) == (.string("")))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.read_window",
          arguments: .object(["path": .string(".")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }
  }

  @Test
  func testFileReadWindowReportsInvalidUTF8Window() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("unicode.txt")
    try Data("aé\n".utf8).write(to: file)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.read_window"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.read_window",
        arguments: .object([
          "path": .string("unicode.txt"),
          "offset_bytes": .number(2),
          "max_bytes": .number(2),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["bytes_read"]) == (.number(2)))
    #expect((payload.objectValue?["valid_utf8"]) == (.bool(false)))
  }

  @Test
  func testFileReadLinesReportsTruncatedScan() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "1234567890\nnext\n".write(to: file, atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.read_lines"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.read_lines",
        arguments: .object([
          "path": .string("notes.txt"),
          "max_bytes": .number(5),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["bytes_scanned"]) == (.number(5)))
    #expect((payload.objectValue?["file_truncated"]) == (.bool(true)))
  }

  @Test
  func testFileHeadReturnsFirstLinesWithBoundedByteWindow() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one\ntwo\nthree\nfour\n".write(to: file, atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.head"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.head",
        arguments: .object([
          "path": .string("notes.txt"),
          "max_lines": .number(2),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let lines = try #require(payload.objectValue?["lines"]?.arrayValue)

    #expect((payload.objectValue?["project_relative_path"]) == (.string("notes.txt")))
    #expect((payload.objectValue?["line_count"]) == (.number(2)))
    #expect((payload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((payload.objectValue?["file_truncated"]) == (.bool(false)))
    #expect((payload.objectValue?["last_line_truncated"]) == (.bool(false)))
    #expect((lines[0].objectValue?["line"]) == (.number(1)))
    #expect((lines[0].objectValue?["head_index"]) == (.number(1)))
    #expect((lines[0].objectValue?["text"]) == (.string("one")))
    #expect((lines[0].objectValue?["line_truncated"]) == (.bool(false)))
    #expect((lines[1].objectValue?["line"]) == (.number(2)))
    #expect((lines[1].objectValue?["text"]) == (.string("two")))
  }

  @Test
  func testFileHeadReportsTruncatedLastLine() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "1234567890\nnext\n".write(to: file, atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.head"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.head",
        arguments: .object([
          "path": .string("notes.txt"),
          "max_lines": .number(5),
          "max_bytes": .number(5),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let lines = try #require(payload.objectValue?["lines"]?.arrayValue)

    #expect((payload.objectValue?["bytes_read"]) == (.number(5)))
    #expect((payload.objectValue?["file_truncated"]) == (.bool(true)))
    #expect((payload.objectValue?["result_truncated"]) == (.bool(false)))
    #expect((payload.objectValue?["last_line_truncated"]) == (.bool(true)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
    #expect((lines[0].objectValue?["text"]) == (.string("12345")))
    #expect((lines[0].objectValue?["line_truncated"]) == (.bool(true)))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.head",
          arguments: .object(["path": .string(".")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }
  }

  @Test
  func testFileOutlineReturnsBoundedMechanicalMarkdownAndSourceMarkers() throws {
    let directory = try temporaryDirectory()
    let readme = directory.appendingPathComponent("README.md")
    let source = directory.appendingPathComponent("App.swift")
    let script = directory.appendingPathComponent("tool.js")
    try "# Computer MCP\n\nIntro\n\n## Install\n```toml\n# Not a heading\n```\n### Verify\n"
      .write(to: readme, atomically: true, encoding: .utf8)
    try """
    import Foundation

    public struct Gateway {
      func serve() {}
    }

    private enum Mode {
    }
    """.write(to: source, atomically: true, encoding: .utf8)
    try """
    export function run() {}
    const value = 1
    """.write(to: script, atomically: true, encoding: .utf8)

    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.outline"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let markdownResult = try provider.callTool(
      .init(
        name: "file.outline",
        arguments: .object([
          "path": .string("README.md"),
          "max_results": .number(2),
        ]), context: .empty
      ))
    let markdownPayload = try decodeTextPayload(markdownResult)
    let markdownItems = try #require(markdownPayload.objectValue?["items"]?.arrayValue)

    #expect((markdownPayload.objectValue?["operation"]) == (.string("file.outline")))
    #expect((markdownPayload.objectValue?["project_relative_path"]) == (.string("README.md")))
    #expect((markdownPayload.objectValue?["language"]) == (.string("markdown")))
    #expect((markdownPayload.objectValue?["outline_count"]) == (.number(3)))
    #expect((markdownPayload.objectValue?["returned_count"]) == (.number(2)))
    #expect((markdownPayload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((markdownItems[0].objectValue?["kind"]) == (.string("heading")))
    #expect((markdownItems[0].objectValue?["level"]) == (.number(1)))
    #expect((markdownItems[0].objectValue?["name"]) == (.string("Computer MCP")))
    #expect((markdownItems[1].objectValue?["line"]) == (.number(5)))

    let sourceResult = try provider.callTool(
      .init(
        name: "file.outline",
        arguments: .object([
          "path": .string("App.swift"),
          "include_imports": .bool(true),
        ]), context: .empty
      ))
    let sourcePayload = try decodeTextPayload(sourceResult)
    let sourceItems = try #require(sourcePayload.objectValue?["items"]?.arrayValue)

    #expect((sourcePayload.objectValue?["language"]) == (.string("swift")))
    #expect((sourceItems[0].objectValue?["kind"]) == (.string("import")))
    #expect((sourceItems[0].objectValue?["name"]) == (.string("Foundation")))
    #expect((sourceItems[1].objectValue?["kind"]) == (.string("struct")))
    #expect((sourceItems[1].objectValue?["name"]) == (.string("Gateway")))
    #expect((sourceItems[2].objectValue?["kind"]) == (.string("function")))
    #expect((sourceItems[2].objectValue?["name"]) == (.string("serve")))
    #expect((sourceItems[3].objectValue?["kind"]) == (.string("enum")))
    #expect((sourceItems[3].objectValue?["name"]) == (.string("Mode")))

    let scriptResult = try provider.callTool(
      .init(
        name: "file.outline",
        arguments: .object([
          "path": .string("tool.js")
        ]), context: .empty
      ))
    let scriptPayload = try decodeTextPayload(scriptResult)
    let scriptItems = try #require(scriptPayload.objectValue?["items"]?.arrayValue)

    #expect((scriptPayload.objectValue?["language"]) == (.string("javascript")))
    #expect((scriptItems[0].objectValue?["kind"]) == (.string("function")))
    #expect((scriptItems[0].objectValue?["name"]) == (.string("run")))
    #expect((scriptItems[1].objectValue?["kind"]) == (.string("variable")))
    #expect((scriptItems[1].objectValue?["name"]) == (.string("value")))
  }

  @Test
  func testFileTailReturnsLastLines() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one\ntwo\nthree\nfour\n".write(to: file, atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.tail"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.tail",
        arguments: .object([
          "path": .string("notes.txt"),
          "max_lines": .number(2),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let lines = try #require(payload.objectValue?["lines"]?.arrayValue)

    #expect((payload.objectValue?["project_relative_path"]) == (.string("notes.txt")))
    #expect((payload.objectValue?["line_numbers_known"]) == (.bool(true)))
    #expect((payload.objectValue?["file_truncated"]) == (.bool(false)))
    #expect((payload.objectValue?["line_count"]) == (.number(2)))
    #expect((lines[0].objectValue?["line"]) == (.number(3)))
    #expect((lines[0].objectValue?["tail_index"]) == (.number(1)))
    #expect((lines[0].objectValue?["text"]) == (.string("three")))
    #expect((lines[1].objectValue?["line"]) == (.number(4)))
    #expect((lines[1].objectValue?["text"]) == (.string("four")))
  }

  @Test
  func testFileTailReportsTruncatedWindowAndDropsPartialFirstLine() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one\ntwo\nthree\nfour\n".write(to: file, atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.tail"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.tail",
        arguments: .object([
          "path": .string("notes.txt"),
          "max_lines": .number(3),
          "max_bytes": .number(9),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let lines = try #require(payload.objectValue?["lines"]?.arrayValue)

    #expect((payload.objectValue?["bytes_read"]) == (.number(9)))
    #expect((payload.objectValue?["file_truncated"]) == (.bool(true)))
    #expect((payload.objectValue?["dropped_partial_first_line"]) == (.bool(true)))
    #expect((payload.objectValue?["line_numbers_known"]) == (.bool(false)))
    #expect((payload.objectValue?["line_count"]) == (.number(1)))
    #expect((lines[0].objectValue?["line"]) == (.null))
    #expect((lines[0].objectValue?["text"]) == (.string("four")))
  }

  @Test
  func testFileHexdumpReturnsBoundedHexAndASCIIWindow() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("blob.bin")
    let bytes = Data([
      0x00, 0x41, 0x7f, 0x80, 0x20, 0x7e, 0x0a, 0xff, 0x42, 0x43, 0x44, 0x45, 0x46,
      0x47, 0x48, 0x49, 0x4a, 0x4b, 0x4c, 0x4d,
    ])
    try bytes.write(to: file)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.hexdump"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.hexdump",
        arguments: .object([
          "path": .string("blob.bin"),
          "offset_bytes": .number(1),
          "max_bytes": .number(18),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let lines = try #require(payload.objectValue?["lines"]?.arrayValue)

    #expect((payload.objectValue?["project_relative_path"]) == (.string("blob.bin")))
    #expect((payload.objectValue?["offset_bytes"]) == (.number(1)))
    #expect((payload.objectValue?["max_bytes"]) == (.number(18)))
    #expect((payload.objectValue?["file_size_bytes"]) == (.number(20)))
    #expect((payload.objectValue?["bytes_read"]) == (.number(18)))
    #expect((payload.objectValue?["next_offset_bytes"]) == (.number(19)))
    #expect((payload.objectValue?["eof"]) == (.bool(false)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
    #expect((lines.count) == (2))
    #expect((lines[0].objectValue?["offset_bytes"]) == (.number(1)))
    #expect(
      (lines[0].objectValue?["hex"]) == (.string("41 7f 80 20 7e 0a ff 42 43 44 45 46 47 48 49 4a"))
    )
    #expect((lines[0].objectValue?["ascii"]) == (.string("A.. ~..BCDEFGHIJ")))
    #expect((lines[1].objectValue?["offset_bytes"]) == (.number(17)))
    #expect((lines[1].objectValue?["hex"]) == (.string("4b 4c")))
    #expect((lines[1].objectValue?["ascii"]) == (.string("KL")))
  }

  @Test
  func testFileHexdumpCanReadEmptyWindowAtEOF() throws {
    let directory = try temporaryDirectory()
    try Data([0x01, 0x02]).write(to: directory.appendingPathComponent("blob.bin"))
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.hexdump"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.hexdump",
        arguments: .object([
          "path": .string("blob.bin"),
          "offset_bytes": .number(10),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["bytes_read"]) == (.number(0)))
    #expect((payload.objectValue?["next_offset_bytes"]) == (.number(10)))
    #expect((payload.objectValue?["eof"]) == (.bool(true)))
    #expect((payload.objectValue?["truncated"]) == (.bool(false)))
    #expect((payload.objectValue?["lines"]) == (.array([])))
  }

  @Test
  func testFileHexdumpRejectsProjectEscapeNonFileAndBadBounds() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.hexdump"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.hexdump",
          arguments: .object(["path": .string("../outside")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.hexdump",
          arguments: .object(["path": .string("folder")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.hexdump",
          arguments: .object([
            "path": .string("folder"),
            "max_bytes": .number(0),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_bytes"))
    }
  }

  @Test
  func testFileMetadataUsesFixedMDLSArgvAndParsesPlist() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("document.txt")
    try "document".write(to: file, atomically: true, encoding: .utf8)
    let runner = RecordingCommandRunner()
    runner.stdout = """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
      "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>kMDItemDisplayName</key>
        <string>document.txt</string>
        <key>kMDItemFSSize</key>
        <integer>8</integer>
        <key>kMDItemWhereFroms</key>
        <array>
          <string>https://example.com/document.txt</string>
        </array>
        <key>kMDItemIsUbiquitous</key>
        <false/>
      </dict>
      </plist>
      """
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.metadata"]),
          projectDirectory: directory
        ),
        commandRunner: runner, builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.metadata",
        arguments: .object([
          "path": .string("document.txt"),
          "attributes": .array([
            .string("kMDItemDisplayName"),
            .string("kMDItemFSSize"),
          ]),
          "max_output_bytes": .number(4096),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let metadata = try #require(payload.objectValue?["metadata"]?.objectValue)

    #expect((runner.calls.first?.executable) == ("mdls"))
    #expect((runner.calls.first?.arguments) == (["-plist", "-", file.path]))
    #expect((payload.objectValue?["operation"]) == (.string("file.metadata")))
    #expect((payload.objectValue?["project_relative_path"]) == (.string("document.txt")))
    #expect(
      (payload.objectValue?["requested_attributes"])
        == (.array([.string("kMDItemDisplayName"), .string("kMDItemFSSize")])))
    #expect((metadata["kMDItemDisplayName"]) == (.string("document.txt")))
    #expect((metadata["kMDItemFSSize"]) == (.number(8)))
    #expect((metadata.count) == (2))
    #expect((metadata["kMDItemWhereFroms"]) == nil)
    #expect((metadata["kMDItemIsUbiquitous"]) == nil)
    #expect((payload.objectValue?["metadata_parse_error"]) == (.null))
    #expect((payload.objectValue?["metadata_omitted_reason"]) == (.null))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout"]) == nil)
  }

  @Test
  func testFileMetadataRejectsBadInputsAndReportsTruncation() throws {
    let directory = try temporaryDirectory()
    try "document".write(
      to: directory.appendingPathComponent("document.txt"),
      atomically: true,
      encoding: .utf8
    )
    let runner = RecordingCommandRunner()
    runner.stdout = "<plist version=\"1.0\"><dict></dict></plist>"
    runner.stdoutTruncated = true
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.metadata"]),
          projectDirectory: directory
        ),
        commandRunner: runner, builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.metadata",
        arguments: .object(["path": .string("document.txt")]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    #expect((payload.objectValue?["metadata"]) == (.null))
    #expect((payload.objectValue?["metadata_omitted_reason"]) == (.string("stdout truncated")))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.metadata",
          arguments: .object(["path": .string("../outside")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.metadata",
          arguments: .object([
            "path": .string("document.txt"),
            "attributes": .array([.string("-bad")]),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("attribute must not be an option"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.metadata",
          arguments: .object([
            "path": .string("document.txt"),
            "attributes": .array([.string("bad attribute")]),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("attribute may contain only"))
    }
  }

  @Test
  func testFileReadlinkReturnsRawDestinationWithoutFollowingFinalSymlink() throws {
    let directory = try temporaryDirectory()
    let target = directory.appendingPathComponent("target.txt")
    let link = directory.appendingPathComponent("target-link")
    let outsideLink = directory.appendingPathComponent("outside-link")
    try "target".write(to: target, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "target.txt")
    try FileManager.default.createSymbolicLink(
      atPath: outsideLink.path,
      withDestinationPath: "/tmp/computer-mcp-outside-target"
    )
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.readlink"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.readlink",
        arguments: .object(["path": .string("target-link")]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["operation"]) == (.string("file.readlink")))
    #expect((payload.objectValue?["path"]) == (.string(link.path)))
    #expect((payload.objectValue?["project_relative_path"]) == (.string("target-link")))
    #expect((payload.objectValue?["destination"]) == (.string("target.txt")))
    #expect((payload.objectValue?["destination_is_absolute"]) == (.bool(false)))
    #expect((payload.objectValue?["destination_project_contained"]) == (.bool(true)))
    #expect((payload.objectValue?["destination_exists"]) == (.bool(true)))
    #expect((payload.objectValue?["resolved_destination_path"]) == (.string(target.path)))
    #expect(
      (payload.objectValue?["destination_project_relative_path"]) == (.string("target.txt")))

    let outside = try provider.callTool(
      .init(
        name: "file.readlink",
        arguments: .object(["path": .string("outside-link")]), context: .empty
      ))
    let outsidePayload = try decodeTextPayload(outside)
    #expect((outsidePayload.objectValue?["destination_is_absolute"]) == (.bool(true)))
    #expect((outsidePayload.objectValue?["destination_project_contained"]) == (.bool(false)))
    #expect((outsidePayload.objectValue?["destination_project_relative_path"]) == (.null))
  }

  @Test
  func testFileReadlinkRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    try "target".write(
      to: directory.appendingPathComponent("regular.txt"),
      atomically: true,
      encoding: .utf8
    )
    let outsideDirectory = try temporaryDirectory()
    let parentLink = directory.appendingPathComponent("outside-parent")
    try FileManager.default.createSymbolicLink(
      atPath: parentLink.path,
      withDestinationPath: outsideDirectory.path
    )
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.readlink"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.readlink",
          arguments: .object(["path": .string("regular.txt")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("not a symbolic link"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.readlink",
          arguments: .object(["path": .string("../outside")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.readlink",
          arguments: .object(["path": .string("outside-parent/link")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("parent symlink"))
    }
  }

  @Test
  func testFileResolveReportsLexicalAndResolvedProjectPaths() throws {
    let directory = try temporaryDirectory()
    let target = directory.appendingPathComponent("target.txt")
    let link = directory.appendingPathComponent("target-link")
    try "target".write(to: target, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "target.txt")
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.resolve"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let fileResult = try provider.callTool(
      .init(
        name: "file.resolve",
        arguments: .object(["path": .string("./target.txt")]), context: .empty
      ))
    let filePayload = try decodeTextPayload(fileResult)
    #expect((filePayload.objectValue?["operation"]) == (.string("file.resolve")))
    #expect((filePayload.objectValue?["input_path"]) == (.string("./target.txt")))
    #expect((filePayload.objectValue?["path"]) == (.string(target.path)))
    #expect((filePayload.objectValue?["project_relative_path"]) == (.string("target.txt")))
    #expect((filePayload.objectValue?["exists"]) == (.bool(true)))
    #expect((filePayload.objectValue?["is_symlink"]) == (.bool(false)))
    #expect((filePayload.objectValue?["resolved_path"]) == (.string(target.path)))
    #expect((filePayload.objectValue?["resolved_project_contained"]) == (.bool(true)))
    #expect(
      (filePayload.objectValue?["resolved_project_relative_path"]) == (.string("target.txt")))

    let linkResult = try provider.callTool(
      .init(
        name: "file.resolve",
        arguments: .object(["path": .string("target-link")]), context: .empty
      ))
    let linkPayload = try decodeTextPayload(linkResult)
    #expect((linkPayload.objectValue?["path"]) == (.string(link.path)))
    #expect((linkPayload.objectValue?["project_relative_path"]) == (.string("target-link")))
    #expect((linkPayload.objectValue?["exists"]) == (.bool(true)))
    #expect((linkPayload.objectValue?["is_symlink"]) == (.bool(true)))
    #expect((linkPayload.objectValue?["symlink_destination"]) == (.string("target.txt")))
    #expect((linkPayload.objectValue?["resolved_path"]) == (.string(target.path)))
    #expect(
      (linkPayload.objectValue?["resolved_project_relative_path"]) == (.string("target.txt")))

    let missingResult = try provider.callTool(
      .init(
        name: "file.resolve",
        arguments: .object(["path": .string("missing/new.txt")]), context: .empty
      ))
    let missingPayload = try decodeTextPayload(missingResult)
    #expect((missingPayload.objectValue?["exists"]) == (.bool(false)))
    #expect(
      (missingPayload.objectValue?["project_relative_path"]) == (.string("missing/new.txt")))
    #expect((missingPayload.objectValue?["resolved_project_contained"]) == (.bool(true)))
  }

  @Test
  func testFileResolveRejectsProjectEscapeThroughParentSymlink() throws {
    let directory = try temporaryDirectory()
    let outsideDirectory = try temporaryDirectory()
    let parentLink = directory.appendingPathComponent("outside-parent")
    try FileManager.default.createSymbolicLink(
      atPath: parentLink.path,
      withDestinationPath: outsideDirectory.path
    )
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.resolve"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.resolve",
          arguments: .object(["path": .string("../outside")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.resolve",
          arguments: .object(["path": .string("outside-parent/file")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("parent symlink"))
    }
  }

  @Test
  func testFileHashReturnsSHA256Digest() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "abc".write(to: file, atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.hash"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.hash",
        arguments: .object(["path": .string("notes.txt")]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["algorithm"]) == (.string("sha256")))
    #expect(
      (payload.objectValue?["hex"])
        == (.string("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")))
    #expect((payload.objectValue?["bytes_read"]) == (.number(3)))
  }

  @Test
  func testFileHashRejectsUnsupportedAlgorithm() throws {
    let directory = try temporaryDirectory()
    try "abc".write(
      to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.hash"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.hash",
          arguments: .object([
            "path": .string("notes.txt"),
            "algorithm": .string("md5"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("sha256"))
    }
  }

  @Test
  func testFileTypeUsesFileMimeWithProjectFile() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "hello".write(to: file, atomically: true, encoding: .utf8)
    let runner = RecordingCommandRunner()
    runner.stdout = "text/plain; charset=us-ascii\n"
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.type"]),
          projectDirectory: directory
        ),
        commandRunner: runner, builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.type",
        arguments: .object([
          "path": .string("notes.txt"),
          "max_output_bytes": .number(4096),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("file"))
    #expect((runner.calls.first?.arguments) == (["-b", "--mime", file.path]))
    #expect((payload.objectValue?["operation"]) == (.string("file.type")))
    #expect((payload.objectValue?["project_relative_path"]) == (.string("notes.txt")))
    #expect((payload.objectValue?["mime_type"]) == (.string("text/plain")))
    #expect((payload.objectValue?["charset"]) == (.string("us-ascii")))
    #expect((payload.objectValue?["raw"]) == (.string("text/plain; charset=us-ascii")))
  }

  @Test
  func testFileCountUsesWCWithProjectFile() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "one two\nthree\n".write(to: file, atomically: true, encoding: .utf8)
    let runner = RecordingCommandRunner()
    runner.stdout = "       2       3      14 \(file.path)\n"
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.count"]),
          projectDirectory: directory
        ),
        commandRunner: runner, builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.count",
        arguments: .object(["path": .string("notes.txt")]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("wc"))
    #expect((runner.calls.first?.arguments) == (["-l", "-w", "-c", file.path]))
    #expect((payload.objectValue?["operation"]) == (.string("file.count")))
    #expect((payload.objectValue?["project_relative_path"]) == (.string("notes.txt")))
    #expect((payload.objectValue?["line_count"]) == (.number(2)))
    #expect((payload.objectValue?["word_count"]) == (.number(3)))
    #expect((payload.objectValue?["byte_count"]) == (.number(14)))
  }

  @Test
  func testFileDiskUsageUsesDUForProjectPath() throws {
    let directory = try temporaryDirectory()
    let nested = directory.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try "hello".write(
      to: nested.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    let runner = RecordingCommandRunner()
    runner.stdout = "8\t\(nested.path)\n"
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.disk_usage"]),
          projectDirectory: directory
        ),
        commandRunner: runner, builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.disk_usage",
        arguments: .object(["path": .string("nested")]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("du"))
    #expect((runner.calls.first?.arguments) == (["-sk", nested.path]))
    #expect((payload.objectValue?["operation"]) == (.string("file.disk_usage")))
    #expect((payload.objectValue?["project_relative_path"]) == (.string("nested")))
    #expect((payload.objectValue?["type"]) == (.string("directory")))
    #expect((payload.objectValue?["disk_usage_kib"]) == (.number(8)))
    #expect((payload.objectValue?["disk_usage_bytes"]) == (.number(8192)))
    #expect((payload.objectValue?["apparent_size_bytes"]) != nil)
  }

  @Test
  func testFileVolumeInfoReturnsPathVolumeMetadataWithoutCommandRunner() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("notes.txt")
    try "hello".write(to: file, atomically: true, encoding: .utf8)
    let runner = RecordingCommandRunner()
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.volume_info"]),
          projectDirectory: directory
        ),
        commandRunner: runner, builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.volume_info",
        arguments: .object(["path": .string("notes.txt")]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let volume = try #require(payload.objectValue?["volume"]?.objectValue)

    #expect(runner.calls.isEmpty)
    #expect((payload.objectValue?["operation"]) == (.string("file.volume_info")))
    #expect((payload.objectValue?["project_relative_path"]) == (.string("notes.txt")))
    #expect((payload.objectValue?["type"]) == (.string("file")))
    #expect((volume["path"]?.stringValue) != nil)
    #expect((volume["name"]?.stringValue) != nil)
    #expect((volume["available_capacity_bytes"]) != nil)
    #expect((volume["is_read_only"]) != nil)
    #expect((volume["supports_case_sensitive_names"]) != nil)
  }

  @Test
  func testFileVolumeInfoRejectsProjectEscapeAndMissingPath() throws {
    let directory = try temporaryDirectory()
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.volume_info"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.volume_info",
          arguments: .object(["path": .string("../outside")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.volume_info",
          arguments: .object(["path": .string("missing")]), context: .empty
        ))
    )
  }

  @Test
  func testFileTypeAndCountRejectProjectEscapeNonFileAndBadBounds() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.type", "file.count"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.type",
          arguments: .object(["path": .string("../outside")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.count",
          arguments: .object(["path": .string("folder")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.count",
          arguments: .object([
            "path": .string("folder"),
            "timeout_ms": .number(0),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("timeout_ms"))
    }
  }

  @Test
  func testFileDiskUsageRejectsProjectEscapeMissingPathAndBadBounds() throws {
    let directory = try temporaryDirectory()
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.disk_usage"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.disk_usage",
          arguments: .object(["path": .string("../outside")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.disk_usage",
          arguments: .object(["path": .string("missing")]), context: .empty
        ))
    )

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.disk_usage",
          arguments: .object([
            "path": .string("."),
            "timeout_ms": .number(0),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("timeout_ms"))
    }
  }

  @Test
  func testFileDiffUsesDiffWithProjectFiles() throws {
    let directory = try temporaryDirectory()
    try "one\ntwo\n".write(
      to: directory.appendingPathComponent("before.txt"), atomically: true, encoding: .utf8)
    try "one\nthree\n".write(
      to: directory.appendingPathComponent("after.txt"), atomically: true, encoding: .utf8)
    let runner = RecordingCommandRunner()
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.diff"]),
          projectDirectory: directory
        ),
        commandRunner: runner, builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.diff",
        arguments: .object([
          "source": .string("before.txt"),
          "target": .string("after.txt"),
          "context_lines": .number(1),
          "max_output_bytes": .number(4096),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("diff"))
    #expect(
      (runner.calls.first?.arguments)
        == ([
          "-U", "1", directory.appendingPathComponent("before.txt").path,
          directory.appendingPathComponent("after.txt").path,
        ]))
    #expect((payload.objectValue?["operation"]) == (.string("file.diff")))
    #expect(
      (payload.objectValue?["source"]?.objectValue?["project_relative_path"])
        == (.string("before.txt")))
    #expect(
      (payload.objectValue?["target"]?.objectValue?["project_relative_path"])
        == (.string("after.txt")))
    #expect((payload.objectValue?["context_lines"]) == (.number(1)))
    #expect((payload.objectValue?["max_output_bytes"]) == (.number(4096)))
  }

  @Test
  func testFileDiffRejectsProjectEscapeNonFileAndBadBounds() throws {
    let directory = try temporaryDirectory()
    try "one".write(
      to: directory.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.diff"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.diff",
          arguments: .object([
            "source": .string("../outside"),
            "target": .string("one.txt"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.diff",
          arguments: .object([
            "source": .string("folder"),
            "target": .string("one.txt"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Source is not a file"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.diff",
          arguments: .object([
            "source": .string("one.txt"),
            "target": .string("one.txt"),
            "context_lines": .number(-1),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("context_lines"))
    }
  }

  @Test
  func testFileCompareTreesReturnsBoundedMetadataDifferences() throws {
    let directory = try temporaryDirectory()
    let left = directory.appendingPathComponent("left", isDirectory: true)
    let right = directory.appendingPathComponent("right", isDirectory: true)
    try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
    try "same".write(
      to: left.appendingPathComponent("common.txt"), atomically: true, encoding: .utf8)
    try "same".write(
      to: right.appendingPathComponent("common.txt"), atomically: true, encoding: .utf8)
    try "left".write(to: left.appendingPathComponent("left.txt"), atomically: true, encoding: .utf8)
    try "right".write(
      to: right.appendingPathComponent("right.txt"), atomically: true, encoding: .utf8)
    try "small".write(
      to: left.appendingPathComponent("size.txt"), atomically: true, encoding: .utf8)
    try "larger".write(
      to: right.appendingPathComponent("size.txt"), atomically: true, encoding: .utf8)
    try "file".write(to: left.appendingPathComponent("kind"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(
      at: right.appendingPathComponent("kind"),
      withIntermediateDirectories: true
    )
    try "ignored".write(
      to: left.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      atPath: left.appendingPathComponent("link").path,
      withDestinationPath: "left-target"
    )
    try FileManager.default.createSymbolicLink(
      atPath: right.appendingPathComponent("link").path,
      withDestinationPath: "right-target"
    )
    let runner = RecordingCommandRunner()
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.compare_trees"]),
          projectDirectory: directory
        ),
        commandRunner: runner, builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.compare_trees",
        arguments: .object([
          "left": .string("left"),
          "right": .string("right"),
          "max_depth": .number(3),
          "max_results": .number(20),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let counts = try #require(payload.objectValue?["difference_counts"]?.objectValue)

    #expect(runner.calls.isEmpty)
    #expect((payload.objectValue?["operation"]) == (.string("file.compare_trees")))
    #expect(
      (payload.objectValue?["left"]?.objectValue?["project_relative_path"]) == (.string("left")))
    #expect(
      (payload.objectValue?["right"]?.objectValue?["project_relative_path"]) == (.string("right"))
    )
    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["difference_count"]) == (.number(5)))
    #expect((payload.objectValue?["metadata_match_count"]) == (.number(1)))
    #expect((counts["left_only"]) == (.number(1)))
    #expect((counts["right_only"]) == (.number(1)))
    #expect((counts["size_mismatch"]) == (.number(1)))
    #expect((counts["type_mismatch"]) == (.number(1)))
    #expect((counts["symlink_mismatch"]) == (.number(1)))

    let differences = try #require(payload.objectValue?["differences"]?.arrayValue)
    #expect((differences.count) == (5))
    #expect(
      !(differences.contains { difference in
        difference.objectValue?["relative_path"] == .string(".hidden")
      }))
  }

  @Test
  func testFileCompareTreesCanHashSameSizeFiles() throws {
    let directory = try temporaryDirectory()
    let left = directory.appendingPathComponent("left", isDirectory: true)
    let right = directory.appendingPathComponent("right", isDirectory: true)
    try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
    try "ab".write(
      to: left.appendingPathComponent("same-size.txt"), atomically: true, encoding: .utf8)
    try "cd".write(
      to: right.appendingPathComponent("same-size.txt"), atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.compare_trees"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.compare_trees",
        arguments: .object([
          "left": .string("left"),
          "right": .string("right"),
          "compare_hashes": .bool(true),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let counts = try #require(payload.objectValue?["difference_counts"]?.objectValue)
    let differences = try #require(payload.objectValue?["differences"]?.arrayValue)
    let firstDifference = try #require(differences.first?.objectValue)

    #expect((counts["hash_mismatch"]) == (.number(1)))
    #expect((payload.objectValue?["hash_files_compared"]) == (.number(2)))
    #expect((payload.objectValue?["hash_bytes_read"]) == (.number(4)))
    #expect((firstDifference["kind"]) == (.string("hash_mismatch")))
    #expect((firstDifference["left"]?.objectValue?["sha256"]?.stringValue) != nil)
    #expect((firstDifference["right"]?.objectValue?["sha256"]?.stringValue) != nil)
  }

  @Test
  func testFileCompareTreesRejectsProjectEscapeNonDirectoryAndBadBounds() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("left"),
      withIntermediateDirectories: true
    )
    try "file".write(
      to: directory.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.compare_trees"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.compare_trees",
          arguments: .object([
            "left": .string("../outside"),
            "right": .string("left"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.compare_trees",
          arguments: .object([
            "left": .string("file.txt"),
            "right": .string("left"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a directory"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.compare_trees",
          arguments: .object([
            "left": .string("left"),
            "right": .string("left"),
            "max_depth": .number(-1),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_depth"))
    }
  }

  @Test
  func testFileDuplicatesReturnsHashConfirmedGroups() throws {
    let directory = try temporaryDirectory()
    let nested = directory.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try "same".write(
      to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try "same".write(
      to: nested.appendingPathComponent("a-copy.txt"), atomically: true, encoding: .utf8)
    try "abcd".write(
      to: directory.appendingPathComponent("same-size-1.txt"), atomically: true, encoding: .utf8)
    try "wxyz".write(
      to: directory.appendingPathComponent("same-size-2.txt"), atomically: true, encoding: .utf8)
    try "".write(
      to: directory.appendingPathComponent("empty-1.txt"), atomically: true, encoding: .utf8)
    try "".write(
      to: directory.appendingPathComponent("empty-2.txt"), atomically: true, encoding: .utf8)
    try "same".write(
      to: directory.appendingPathComponent(".hidden-copy.txt"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      atPath: directory.appendingPathComponent("link-to-a").path,
      withDestinationPath: "a.txt"
    )
    let runner = RecordingCommandRunner()
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.duplicates"]),
          projectDirectory: directory
        ),
        commandRunner: runner, builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.duplicates",
        arguments: .object([
          "path": .string("."),
          "max_depth": .number(3),
          "max_groups": .number(10),
          "max_files_per_group": .number(10),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let groups = try #require(payload.objectValue?["groups"]?.arrayValue)
    let firstGroup = try #require(groups.first?.objectValue)
    let files = try #require(firstGroup["files"]?.arrayValue)
    let returnedPaths = files.compactMap {
      $0.objectValue?["project_relative_path"]?.stringValue
    }

    #expect(runner.calls.isEmpty)
    #expect((payload.objectValue?["operation"]) == (.string("file.duplicates")))
    #expect((payload.objectValue?["project_relative_path"]) == (.string(".")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["candidate_file_count"]) == (.number(4)))
    #expect((payload.objectValue?["candidate_size_bucket_count"]) == (.number(1)))
    #expect((payload.objectValue?["skipped_small_file_count"]) == (.number(2)))
    #expect((payload.objectValue?["hashed_file_count"]) == (.number(4)))
    #expect((payload.objectValue?["duplicate_group_count"]) == (.number(1)))
    #expect((payload.objectValue?["duplicate_file_count"]) == (.number(2)))
    #expect((payload.objectValue?["result_truncated"]) == (.bool(false)))
    #expect((firstGroup["file_count"]) == (.number(2)))
    #expect((firstGroup["returned_file_count"]) == (.number(2)))
    #expect((firstGroup["size_bytes"]) == (.number(4)))
    #expect((firstGroup["sha256"]?.stringValue) != nil)
    #expect((returnedPaths) == (["a.txt", "nested/a-copy.txt"]))
    #expect((files.first?.objectValue?["read_context"]?.objectValue) != nil)
    #expect(!(returnedPaths.contains(".hidden-copy.txt")))
  }

  @Test
  func testFileDuplicatesHonorsHashLimits() throws {
    let directory = try temporaryDirectory()
    try "same".write(
      to: directory.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try "same".write(
      to: directory.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.duplicates"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.duplicates",
        arguments: .object([
          "max_hash_files": .number(1)
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["candidate_file_count"]) == (.number(2)))
    #expect((payload.objectValue?["hashed_file_count"]) == (.number(0)))
    #expect((payload.objectValue?["hash_skipped_file_count"]) == (.number(2)))
    #expect((payload.objectValue?["hash_skipped_size_bucket_count"]) == (.number(1)))
    #expect((payload.objectValue?["duplicate_group_count"]) == (.number(0)))
  }

  @Test
  func testFileDuplicatesRejectsProjectEscapeNonDirectoryAndBadBounds() throws {
    let directory = try temporaryDirectory()
    try "file".write(
      to: directory.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.duplicates"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.duplicates",
          arguments: .object([
            "path": .string("../outside")
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.duplicates",
          arguments: .object([
            "path": .string("file.txt")
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a directory"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.duplicates",
          arguments: .object([
            "max_depth": .number(-1)
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_depth"))
    }
  }

  @Test
  func testArchiveListUsesFixedZipInfoArgvAndReturnsBoundedEntries() throws {
    let directory = try temporaryDirectory()
    let archive = directory.appendingPathComponent("bundle.zip")
    try Data([0x50, 0x4b]).write(to: archive)
    let runner = RecordingCommandRunner()
    runner.stdout = "dir/\ndir/file.txt\nimage.png\n"
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["archive.list"]),
          projectDirectory: directory
        ),
        commandRunner: runner, builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "archive.list",
        arguments: .object([
          "path": .string("bundle.zip"),
          "max_entries": .number(2),
          "max_output_bytes": .number(4096),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let entries = try #require(payload.objectValue?["entries"]?.arrayValue)

    #expect((runner.calls.first?.executable) == ("zipinfo"))
    #expect((runner.calls.first?.arguments) == (["-1", archive.path]))
    #expect((payload.objectValue?["operation"]) == (.string("archive.list")))
    #expect((payload.objectValue?["archive"]?.objectValue?["format"]) == (.string("zip")))
    #expect(
      (payload.objectValue?["archive"]?.objectValue?["project_relative_path"])
        == (.string("bundle.zip")))
    #expect((payload.objectValue?["entry_count"]) == (.number(2)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
    #expect((entries[0].objectValue?["path"]) == (.string("dir/")))
    #expect((entries[0].objectValue?["is_directory"]) == (.bool(true)))
    #expect((entries[1].objectValue?["path"]) == (.string("dir/file.txt")))
    #expect((entries[1].objectValue?["is_directory"]) == (.bool(false)))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout"]) == nil)
  }

  @Test
  func testArchiveListUsesTarArgvAndRejectsUnsupportedInputs() throws {
    let directory = try temporaryDirectory()
    let archive = directory.appendingPathComponent("bundle.tar.gz")
    try Data("tar".utf8).write(to: archive)
    try Data("text".utf8).write(to: directory.appendingPathComponent("notes.txt"))
    let runner = RecordingCommandRunner()
    runner.stdout = "src/\nsrc/main.swift\n"
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["archive.list"]),
          projectDirectory: directory
        ),
        commandRunner: runner, builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "archive.list",
        arguments: .object(["path": .string("bundle.tar.gz")]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("tar"))
    #expect((runner.calls.first?.arguments) == (["-tf", archive.path]))
    #expect((payload.objectValue?["archive"]?.objectValue?["format"]) == (.string("tar")))

    expectThrows(
      try provider.callTool(
        .init(
          name: "archive.list",
          arguments: .object(["path": .string("notes.txt")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Unsupported archive format"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "archive.list",
          arguments: .object(["path": .string("../outside.zip")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "archive.list",
          arguments: .object([
            "path": .string("bundle.tar.gz"),
            "max_entries": .number(0),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_entries"))
    }
  }

  @Test
  func testArchiveReadFileUsesFixedZipArgvAndReturnsText() throws {
    let directory = try temporaryDirectory()
    let archive = directory.appendingPathComponent("bundle.zip")
    try Data([0x50, 0x4b]).write(to: archive)
    let runner = RecordingCommandRunner()
    runner.outputs = [
      .init(stdout: "hello from archive\n", stdoutTruncated: true)
    ]
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["archive.read_file"]),
          projectDirectory: directory
        ),
        commandRunner: runner, builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "archive.read_file",
        arguments: .object([
          "path": .string("bundle.zip"),
          "entry": .string("dir/file.txt"),
          "max_bytes": .number(32),
          "timeout_ms": .number(1234),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("unzip"))
    #expect((runner.calls.first?.arguments) == (["-p", archive.path, "dir/file.txt"]))
    #expect((runner.calls.first?.timeoutMilliseconds) == (1234))
    #expect((runner.calls.first?.maxOutputBytes) == (32))
    #expect((payload.objectValue?["operation"]) == (.string("archive.read_file")))
    #expect((payload.objectValue?["archive"]?.objectValue?["format"]) == (.string("zip")))
    #expect(
      (payload.objectValue?["archive"]?.objectValue?["project_relative_path"])
        == (.string("bundle.zip")))
    #expect(
      (payload.objectValue?["entry"]?.objectValue?["requested_path"]) == (.string("dir/file.txt")))
    #expect(
      (payload.objectValue?["entry"]?.objectValue?["normalized_path"]) == (.string("dir/file.txt")))
    #expect((payload.objectValue?["content"]) == (.string("hello from archive\n")))
    #expect((payload.objectValue?["requested_encoding"]) == (.string("utf8")))
    #expect((payload.objectValue?["encoding"]) == (.string("utf8")))
    #expect((payload.objectValue?["valid_utf8"]) == (.bool(true)))
    #expect((payload.objectValue?["content_truncated"]) == (.bool(true)))
    #expect((payload.objectValue?["result"]?.objectValue?["stdout_truncated"]) == (.bool(true)))
  }

  @Test
  func testArchiveReadFileCanReturnBinaryMemberAsBase64() throws {
    let directory = try temporaryDirectory()
    let archive = directory.appendingPathComponent("bundle.zip")
    try Data([0x50, 0x4b]).write(to: archive)
    let runner = RecordingCommandRunner()
    runner.outputs = [
      .init(stdout: "", stdoutData: Data([0x00, 0xff, 0x41, 0x42]))
    ]
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["archive.read_file"]),
          projectDirectory: directory
        ),
        commandRunner: runner, builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "archive.read_file",
        arguments: .object([
          "path": .string("bundle.zip"),
          "entry": .string("image.bin"),
          "encoding": .string("auto"),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.arguments) == (["-p", archive.path, "image.bin"]))
    #expect((payload.objectValue?["requested_encoding"]) == (.string("auto")))
    #expect((payload.objectValue?["encoding"]) == (.string("base64")))
    #expect((payload.objectValue?["valid_utf8"]) == (.bool(false)))
    #expect(
      (payload.objectValue?["content"])
        == (.string(Data([0x00, 0xff, 0x41, 0x42]).base64EncodedString())))
    #expect((payload.objectValue?["bytes_read"]) == (.number(4)))

    let forcedBase64Result = try provider.callTool(
      .init(
        name: "archive.read_file",
        arguments: .object([
          "path": .string("bundle.zip"),
          "entry": .string("image.bin"),
          "encoding": .string("base64"),
        ]), context: .empty
      ))
    let forcedPayload = try decodeTextPayload(forcedBase64Result)
    #expect((forcedPayload.objectValue?["encoding"]) == (.string("base64")))
  }

  @Test
  func testArchiveReadFileRejectsInvalidUTF8WhenUTF8Requested() throws {
    let directory = try temporaryDirectory()
    let archive = directory.appendingPathComponent("bundle.zip")
    try Data([0x50, 0x4b]).write(to: archive)
    let runner = RecordingCommandRunner()
    runner.outputs = [
      .init(stdout: "", stdoutData: Data([0xff, 0xfe]))
    ]
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["archive.read_file"]),
          projectDirectory: directory
        ),
        commandRunner: runner, builtinExecutables: builtinExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "archive.read_file",
          arguments: .object([
            "path": .string("bundle.zip"),
            "entry": .string("image.bin"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("not valid UTF-8"))
      #expect((runner.calls.count) == (1))
    }
  }

  @Test
  func testArchiveReadFileUsesTarArgvAndNormalizesEntry() throws {
    let directory = try temporaryDirectory()
    let archive = directory.appendingPathComponent("bundle.tar.gz")
    try Data("tar".utf8).write(to: archive)
    let runner = RecordingCommandRunner()
    runner.stdout = "main\n"
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["archive.read_file"]),
          projectDirectory: directory
        ),
        commandRunner: runner, builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "archive.read_file",
        arguments: .object([
          "path": .string("bundle.tar.gz"),
          "entry": .string("./src/main.swift"),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("tar"))
    #expect((runner.calls.first?.arguments) == (["-xOf", archive.path, "--", "src/main.swift"]))
    #expect((payload.objectValue?["archive"]?.objectValue?["format"]) == (.string("tar")))
    #expect(
      (payload.objectValue?["entry"]?.objectValue?["normalized_path"])
        == (.string("src/main.swift")))
    #expect((payload.objectValue?["content"]) == (.string("main\n")))
  }

  @Test
  func testArchiveReadFileRejectsUnsafeInputsAndCommandFailure() throws {
    let directory = try temporaryDirectory()
    let archive = directory.appendingPathComponent("bundle.zip")
    let notes = directory.appendingPathComponent("notes.txt")
    try Data([0x50, 0x4b]).write(to: archive)
    try Data("text".utf8).write(to: notes)
    let runner = RecordingCommandRunner()
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["archive.read_file"]),
          projectDirectory: directory
        ),
        commandRunner: runner, builtinExecutables: builtinExecutables))

    for entry in ["../outside.txt", "/absolute.txt", "dir/", "-option", "*.txt"] {
      expectThrows(
        try provider.callTool(
          .init(
            name: "archive.read_file",
            arguments: .object([
              "path": .string("bundle.zip"),
              "entry": .string(entry),
            ]), context: .empty
          ))
      )
    }
    #expect(runner.calls.isEmpty)

    expectThrows(
      try provider.callTool(
        .init(
          name: "archive.read_file",
          arguments: .object([
            "path": .string("notes.txt"),
            "entry": .string("README.md"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Unsupported archive format"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "archive.read_file",
          arguments: .object([
            "path": .string("bundle.zip"),
            "entry": .string("README.md"),
            "max_bytes": .number(0),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_bytes"))
    }

    let failureRunner = RecordingCommandRunner()
    failureRunner.exitCode = 11
    let failureRegistry = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["archive.read_file"]),
          projectDirectory: directory
        ),
        commandRunner: failureRunner, builtinExecutables: builtinExecutables))
    expectThrows(
      try failureRegistry.callTool(
        .init(
          name: "archive.read_file",
          arguments: .object([
            "path": .string("bundle.zip"),
            "entry": .string("missing.txt"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("failed with exit code 11"))
      #expect((failureRunner.calls.count) == (1))
    }
  }

  @Test(arguments: ["zip", "jar", "war", "ear", "tar"], [true, false])
  func testArchiveExtractRequiresARegisteredReader(suffix: String, dryRun: Bool) throws {
    let directory = try temporaryDirectory()
    try Data("archive".utf8).write(to: directory.appendingPathComponent("input." + suffix))
    let runner = RecordingCommandRunner()
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: .init(
          builtin: .init(enabled: ["archive.extract"]), projectDirectory: directory),
        commandRunner: runner))
    #if canImport(Darwin)
      let reader = "tar"
    #else
      let reader = suffix == "tar" ? "tar" : "bsdtar"
    #endif
    #expect(
      throws: GatewayToolError.disabled(
        "Builtin command '\(reader)' is unavailable on this platform.")
    ) {
      _ = try provider.callTool(
        .init(
          name: "archive.extract",
          arguments: .object([
            "path": .string("input." + suffix), "destination": .string("output"),
            "create_directories": .bool(true), "dry_run": .bool(dryRun),
            "confirm_extract": .bool(true),
          ]), context: .empty))
    }
    #expect(runner.calls.isEmpty)
    #expect(
      !FileManager.default.fileExists(atPath: directory.appendingPathComponent("output").path))
  }

  @Test
  func testArchiveExtractDryRunValidatesZipEntriesWithoutWriting() throws {
    let directory = try temporaryDirectory()
    let archive = directory.appendingPathComponent("bundle.zip")
    try Data([0x50, 0x4b]).write(to: archive)
    let destination = directory.appendingPathComponent("out")
    let runner = RecordingCommandRunner()
    runner.outputs = [
      .init(
        stdout: """
          drwxr-xr-x  0 0 0 0 Jul 08 23:11 dir/
          -rw-r--r--  0 0 0 1 Jul 08 23:11 dir/file.txt
          -rw-r--r--  0 0 0 1 Jul 08 23:11 image.png
          """
      )
    ]
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["archive.extract"]),
          projectDirectory: directory
        ),
        commandRunner: runner, builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "archive.extract",
        arguments: .object([
          "path": .string("bundle.zip"),
          "destination": .string("out"),
          "create_directories": .bool(true),
          "max_preview_entries": .number(2),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let entries = try #require(payload.objectValue?["entries"]?.arrayValue)

    #if canImport(Darwin)
      #expect((runner.calls.map(\.executable)) == (["tar"]))
    #else
      #expect((runner.calls.map(\.executable)) == (["bsdtar"]))
    #endif
    #expect((runner.calls[0].arguments) == (["--numeric-owner", "-tvf", archive.path]))
    #expect(!(FileManager.default.fileExists(atPath: destination.path)))
    #expect((payload.objectValue?["operation"]) == (.string("archive.extract")))
    #expect((payload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((payload.objectValue?["confirm_extract"]) == (.bool(false)))
    #expect((payload.objectValue?["entry_count"]) == (.number(3)))
    #expect((payload.objectValue?["entries_truncated"]) == (.bool(true)))
    #expect(
      (payload.objectValue?["destination"]?.objectValue?["project_relative_path"])
        == (.string("out")))
    #expect((payload.objectValue?["destination"]?.objectValue?["would_create"]) == (.bool(true)))
    #expect((entries[0].objectValue?["path"]) == (.string("dir/")))
    #expect((entries[0].objectValue?["normalized_path"]) == (.string("dir")))
    #expect((entries[0].objectValue?["is_directory"]) == (.bool(true)))
    #expect((entries[1].objectValue?["normalized_path"]) == (.string("dir/file.txt")))
    #expect((payload.objectValue?["result"]) == (.null))
  }

  @Test
  func testArchiveExtractRunsTarAfterConfirmation() throws {
    let directory = try temporaryDirectory()
    let archive = directory.appendingPathComponent("bundle.tar.gz")
    let destination = directory.appendingPathComponent("out")
    try Data("tar".utf8).write(to: archive)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let fixture = try ArchiveFixture()
    defer { fixture.remove() }
    let generated = try fixture.archive(
      [
        .init(name: "src/", kind: "directory", mode: 0o755),
        .init(name: "src/main.swift", content: "extracted"),
      ], format: "tar.gz")
    try FileManager.default.removeItem(at: archive)
    try FileManager.default.moveItem(at: generated, to: archive)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["archive.extract"]),
          projectDirectory: directory
        ),
        builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "archive.extract",
        arguments: .object([
          "path": .string("bundle.tar.gz"),
          "destination": .string("out"),
          "dry_run": .bool(false),
          "confirm_extract": .bool(true),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect(
      try String(contentsOf: destination.appendingPathComponent("src/main.swift"), encoding: .utf8)
        == "extracted")
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["src"])
    #expect((payload.objectValue?["operation"]) == (.string("archive.extract")))
    #expect((payload.objectValue?["dry_run"]) == (.bool(false)))
    #expect((payload.objectValue?["confirm_extract"]) == (.bool(true)))
    #expect(
      (payload.objectValue?["result"]?.objectValue?["exit_code"]) == (.number(0)))
  }

  @Test
  func testArchiveExtractRejectsUnsafeInputs() throws {
    let directory = try temporaryDirectory()
    let archive = directory.appendingPathComponent("bundle.zip")
    let destination = directory.appendingPathComponent("out")
    try Data([0x50, 0x4b]).write(to: archive)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("existing".utf8).write(to: destination.appendingPathComponent("existing.txt"))

    let missingConfirmRunner = RecordingCommandRunner()
    let missingConfirmRegistry = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["archive.extract"]),
          projectDirectory: directory
        ),
        commandRunner: missingConfirmRunner, builtinExecutables: builtinExecutables))
    expectThrows(
      try missingConfirmRegistry.callTool(
        .init(
          name: "archive.extract",
          arguments: .object([
            "path": .string("bundle.zip"),
            "destination": .string("out"),
            "dry_run": .bool(false),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("confirm_extract"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    let traversalRunner = RecordingCommandRunner()
    traversalRunner.outputs = [
      .init(
        stdout: "-rw-r--r--  0 0 0 1 Jul 08 23:11 ../outside.txt\n")
    ]
    let traversalRegistry = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["archive.extract"]),
          projectDirectory: directory
        ),
        commandRunner: traversalRunner, builtinExecutables: builtinExecutables))
    expectThrows(
      try traversalRegistry.callTool(
        .init(
          name: "archive.extract",
          arguments: .object([
            "path": .string("bundle.zip"),
            "destination": .string("out"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes destination"))
    }

    let linkRunner = RecordingCommandRunner()
    linkRunner.outputs = [
      .init(stdout: "lrwxr-xr-x  0 0 0 4 Jul 08 23:11 link\n")
    ]
    let linkRegistry = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["archive.extract"]),
          projectDirectory: directory
        ),
        commandRunner: linkRunner, builtinExecutables: builtinExecutables))
    expectThrows(
      try linkRegistry.callTool(
        .init(
          name: "archive.extract",
          arguments: .object([
            "path": .string("bundle.zip"),
            "destination": .string("out"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("link entries"))
    }

    let overwriteRunner = RecordingCommandRunner()
    overwriteRunner.outputs = [
      .init(stdout: "-rw-r--r--  0 0 0 1 Jul 08 23:11 existing.txt\n")
    ]
    let overwriteRegistry = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["archive.extract"]),
          projectDirectory: directory
        ),
        commandRunner: overwriteRunner, builtinExecutables: builtinExecutables))
    expectThrows(
      try overwriteRegistry.callTool(
        .init(
          name: "archive.extract",
          arguments: .object([
            "path": .string("bundle.zip"),
            "destination": .string("out"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("overwrite existing path"))
    }
  }

  @Test
  func testArchiveCreateDryRunBuildsZipArgvWithoutWriting() throws {
    let directory = try temporaryDirectory()
    let sourceDirectory = directory.appendingPathComponent("src")
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try "main".write(
      to: sourceDirectory.appendingPathComponent("main.swift"),
      atomically: true,
      encoding: .utf8
    )
    try "readme".write(
      to: directory.appendingPathComponent("README.md"),
      atomically: true,
      encoding: .utf8
    )
    let archive = directory.appendingPathComponent("dist/bundle.zip")
    let runner = RecordingCommandRunner()
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["archive.create"]),
          projectDirectory: directory
        ),
        commandRunner: runner, builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "archive.create",
        arguments: .object([
          "path": .string("dist/bundle.zip"),
          "sources": .array([.string("src"), .string("README.md")]),
          "create_directories": .bool(true),
          "max_preview_entries": .number(2),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let entries = try #require(payload.objectValue?["entries"]?.arrayValue)

    #expect(runner.calls.isEmpty)
    #expect(!(FileManager.default.fileExists(atPath: archive.deletingLastPathComponent().path)))
    #expect((payload.objectValue?["operation"]) == (.string("archive.create")))
    #expect((payload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((payload.objectValue?["confirm_create"]) == (.bool(false)))
    #expect((payload.objectValue?["entry_count"]) == (.number(3)))
    #expect((payload.objectValue?["entries_truncated"]) == (.bool(true)))
    #expect(
      (payload.objectValue?["archive"]?.objectValue?["project_relative_path"])
        == (.string("dist/bundle.zip")))
    #expect(
      (payload.objectValue?["archive"]?.objectValue?["would_create_parent_directories"])
        == (.bool(true)))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([
          .string("-qry"),
          .string("-"),
          .string("--"),
          .string("src"),
          .string("README.md"),
        ])))
    #expect((entries[0].objectValue?["project_relative_path"]) == (.string("src")))
    #expect((entries[0].objectValue?["type"]) == (.string("directory")))
    #expect((entries[1].objectValue?["project_relative_path"]) == (.string("src/main.swift")))
    #expect((payload.objectValue?["result"]) == (.null))
  }

  @Test
  func testArchiveCreateRunsTarAfterConfirmation() throws {
    let directory = try temporaryDirectory()
    let sourceDirectory = directory.appendingPathComponent("src")
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try "main".write(
      to: sourceDirectory.appendingPathComponent("main.swift"),
      atomically: true,
      encoding: .utf8
    )
    let archive = directory.appendingPathComponent("out/bundle.tar.gz")
    let runner = RecordingCommandRunner()
    runner.stdout = "created\n"
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["archive.create"]),
          projectDirectory: directory
        ),
        commandRunner: runner, builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "archive.create",
        arguments: .object([
          "path": .string("out/bundle.tar.gz"),
          "sources": .array([.string("src")]),
          "create_directories": .bool(true),
          "dry_run": .bool(false),
          "confirm_create": .bool(true),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.map(\.executable)) == (["tar"]))
    #expect((runner.calls.first?.arguments) == (["-czf", "-", "--", "src"]))
    #expect(FileManager.default.fileExists(atPath: archive.deletingLastPathComponent().path))
    #expect((payload.objectValue?["operation"]) == (.string("archive.create")))
    #expect((payload.objectValue?["dry_run"]) == (.bool(false)))
    #expect((payload.objectValue?["confirm_create"]) == (.bool(true)))
    #expect((payload.objectValue?["result"]?.objectValue?["exit_code"]) == (.number(0)))
  }

  @Test
  func testArchiveCreateRejectsUnsafeInputs() throws {
    let directory = try temporaryDirectory()
    let sourceDirectory = directory.appendingPathComponent("src")
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    let sourceFile = sourceDirectory.appendingPathComponent("main.swift")
    try "main".write(to: sourceFile, atomically: true, encoding: .utf8)

    let missingConfirmRunner = RecordingCommandRunner()
    let missingConfirmRegistry = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["archive.create"]),
          projectDirectory: directory
        ),
        commandRunner: missingConfirmRunner, builtinExecutables: builtinExecutables))
    expectThrows(
      try missingConfirmRegistry.callTool(
        .init(
          name: "archive.create",
          arguments: .object([
            "path": .string("bundle.zip"),
            "sources": .array([.string("src")]),
            "dry_run": .bool(false),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("confirm_create"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    let existingArchive = directory.appendingPathComponent("bundle.zip")
    try Data("old".utf8).write(to: existingArchive)
    let existingRegistry = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["archive.create"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))
    expectThrows(
      try existingRegistry.callTool(
        .init(
          name: "archive.create",
          arguments: .object([
            "path": .string("bundle.zip"),
            "sources": .array([.string("src")]),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("already exists"))
    }

    let insideSourceRegistry = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["archive.create"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))
    expectThrows(
      try insideSourceRegistry.callTool(
        .init(
          name: "archive.create",
          arguments: .object([
            "path": .string("src/bundle.zip"),
            "sources": .array([.string("src")]),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("inside a source path"))
    }

    let symlink = sourceDirectory.appendingPathComponent("link.swift")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: sourceFile)
    let symlinkRegistry = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["archive.create"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))
    expectThrows(
      try symlinkRegistry.callTool(
        .init(
          name: "archive.create",
          arguments: .object([
            "path": .string("new-bundle.zip"),
            "sources": .array([.string("src")]),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("symbolic link entries"))
    }

    expectThrows(
      try symlinkRegistry.callTool(
        .init(
          name: "archive.create",
          arguments: .object([
            "path": .string("new-bundle.zip"),
            "sources": .array([]),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("sources must not be empty"))
    }
  }

  @Test
  func testFileOrganizationBuiltinsCreateCopyAndMoveProjectPaths() throws {
    let directory = try temporaryDirectory()
    try "source".write(
      to: directory.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.mkdir", "file.copy", "file.move"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let mkdirResult = try provider.callTool(
      .init(
        name: "file.mkdir",
        arguments: .object(["path": .string("notes/nested")]), context: .empty
      ))
    let mkdirPayload = try decodeTextPayload(mkdirResult)
    #expect((mkdirPayload.objectValue?["project_relative_path"]) == (.string("notes/nested")))
    #expect((mkdirPayload.objectValue?["created"]) == (.bool(true)))

    let existingResult = try provider.callTool(
      .init(
        name: "file.mkdir",
        arguments: .object(["path": .string("notes/nested")]), context: .empty
      ))
    let existingPayload = try decodeTextPayload(existingResult)
    #expect((existingPayload.objectValue?["created"]) == (.bool(false)))

    let copyResult = try provider.callTool(
      .init(
        name: "file.copy",
        arguments: .object([
          "source": .string("source.txt"),
          "destination": .string("notes/nested/copy.txt"),
        ]), context: .empty
      ))
    let copyPayload = try decodeTextPayload(copyResult)
    #expect((copyPayload.objectValue?["operation"]) == (.string("file.copy")))
    #expect(
      (try String(contentsOf: directory.appendingPathComponent("notes/nested/copy.txt")))
        == ("source"))

    let moveResult = try provider.callTool(
      .init(
        name: "file.move",
        arguments: .object([
          "source": .string("notes/nested/copy.txt"),
          "destination": .string("moved/copy.txt"),
          "create_directories": .bool(true),
        ]), context: .empty
      ))
    let movePayload = try decodeTextPayload(moveResult)
    #expect((movePayload.objectValue?["operation"]) == (.string("file.move")))
    #expect(
      !(FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("notes/nested/copy.txt").path)))
    #expect(
      (try String(contentsOf: directory.appendingPathComponent("moved/copy.txt"))) == ("source"))
  }

  @Test
  func testFileOrganizationRejectsOverwriteUnlessRequested() throws {
    let directory = try temporaryDirectory()
    try "source".write(
      to: directory.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
    try "old".write(
      to: directory.appendingPathComponent("target.txt"), atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.copy"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.copy",
          arguments: .object([
            "source": .string("source.txt"),
            "destination": .string("target.txt"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Destination already exists"))
    }

    _ = try provider.callTool(
      .init(
        name: "file.copy",
        arguments: .object([
          "source": .string("source.txt"),
          "destination": .string("target.txt"),
          "overwrite": .bool(true),
        ]), context: .empty
      ))

    #expect((try String(contentsOf: directory.appendingPathComponent("target.txt"))) == ("source"))
  }

  @Test
  func testFileOrganizationRejectsProjectEscape() throws {
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.mkdir", "file.copy", "file.move"]),
          projectDirectory: try temporaryDirectory()
        ), builtinExecutables: builtinExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.mkdir",
          arguments: .object(["path": .string("../outside")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.copy",
          arguments: .object([
            "source": .string("missing.txt"),
            "destination": .string("../outside"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }
  }

  @Test
  func testFileOrganizationDryRunsDoNotMutateProject() throws {
    let directory = try temporaryDirectory()
    let source = directory.appendingPathComponent("source.txt")
    let target = directory.appendingPathComponent("target.txt")
    let obsolete = directory.appendingPathComponent("obsolete.txt")
    try "source".write(to: source, atomically: true, encoding: .utf8)
    try "target".write(to: target, atomically: true, encoding: .utf8)
    try "obsolete".write(to: obsolete, atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(
            enabled: [
              "file.touch", "file.mkdir", "file.copy", "file.move", "file.symlink",
              "file.trash",
            ]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let mkdirResult = try provider.callTool(
      .init(
        name: "file.mkdir",
        arguments: .object([
          "path": .string("notes/nested"),
          "dry_run": .bool(true),
        ]), context: .empty
      ))
    let mkdirPayload = try decodeTextPayload(mkdirResult)
    #expect((mkdirPayload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((mkdirPayload.objectValue?["created"]) == (.bool(false)))
    #expect((mkdirPayload.objectValue?["would_create"]) == (.bool(true)))
    #expect(
      !(FileManager.default.fileExists(atPath: directory.appendingPathComponent("notes").path)))

    let touchResult = try provider.callTool(
      .init(
        name: "file.touch",
        arguments: .object([
          "path": .string("logs/session.txt"),
          "create_directories": .bool(true),
          "dry_run": .bool(true),
        ]), context: .empty
      ))
    let touchPayload = try decodeTextPayload(touchResult)
    #expect((touchPayload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((touchPayload.objectValue?["created"]) == (.bool(false)))
    #expect((touchPayload.objectValue?["would_create"]) == (.bool(true)))
    #expect(
      !(FileManager.default.fileExists(atPath: directory.appendingPathComponent("logs").path)))

    let copyResult = try provider.callTool(
      .init(
        name: "file.copy",
        arguments: .object([
          "source": .string("source.txt"),
          "destination": .string("target.txt"),
          "overwrite": .bool(true),
          "dry_run": .bool(true),
        ]), context: .empty
      ))
    let copyPayload = try decodeTextPayload(copyResult)
    #expect((copyPayload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((copyPayload.objectValue?["copied"]) == (.bool(false)))
    #expect((copyPayload.objectValue?["would_copy"]) == (.bool(true)))
    #expect((copyPayload.objectValue?["would_overwrite"]) == (.bool(true)))
    #expect((try String(contentsOf: target)) == ("target"))

    let moveResult = try provider.callTool(
      .init(
        name: "file.move",
        arguments: .object([
          "source": .string("source.txt"),
          "destination": .string("moved/source.txt"),
          "create_directories": .bool(true),
          "dry_run": .bool(true),
        ]), context: .empty
      ))
    let movePayload = try decodeTextPayload(moveResult)
    #expect((movePayload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((movePayload.objectValue?["moved"]) == (.bool(false)))
    #expect((movePayload.objectValue?["would_move"]) == (.bool(true)))
    #expect((movePayload.objectValue?["source_removed"]) == (.bool(false)))
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(
      !(FileManager.default.fileExists(atPath: directory.appendingPathComponent("moved").path)))

    let symlinkResult = try provider.callTool(
      .init(
        name: "file.symlink",
        arguments: .object([
          "path": .string("links/current"),
          "destination": .string("../source.txt"),
          "create_directories": .bool(true),
          "dry_run": .bool(true),
        ]), context: .empty
      ))
    let symlinkPayload = try decodeTextPayload(symlinkResult)
    #expect((symlinkPayload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((symlinkPayload.objectValue?["created"]) == (.bool(false)))
    #expect((symlinkPayload.objectValue?["would_create"]) == (.bool(true)))
    #expect((symlinkPayload.objectValue?["destination_exists"]) == (.bool(true)))
    #expect(
      !(FileManager.default.fileExists(atPath: directory.appendingPathComponent("links").path)))

    let trashResult = try provider.callTool(
      .init(
        name: "file.trash",
        arguments: .object([
          "path": .string("obsolete.txt"),
          "dry_run": .bool(true),
        ]), context: .empty
      ))
    let trashPayload = try decodeTextPayload(trashResult)
    #expect((trashPayload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((trashPayload.objectValue?["trashed"]) == (.bool(false)))
    #expect((trashPayload.objectValue?["would_trash"]) == (.bool(true)))
    #expect((trashPayload.objectValue?["trashed_path"]) == (.null))
    #expect(FileManager.default.fileExists(atPath: obsolete.path))
  }

  @Test
  func testFileTouchCreatesAndUpdatesProjectFile() throws {
    let directory = try temporaryDirectory()
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.touch"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.touch",
        arguments: .object([
          "path": .string("notes/touched.txt"),
          "create_directories": .bool(true),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let file = directory.appendingPathComponent("notes/touched.txt")

    #expect((payload.objectValue?["operation"]) == (.string("file.touch")))
    #expect((payload.objectValue?["project_relative_path"]) == (.string("notes/touched.txt")))
    #expect((payload.objectValue?["created"]) == (.bool(true)))
    #expect((payload.objectValue?["modified"]) == (.bool(true)))
    #expect((payload.objectValue?["result"]?.objectValue?["type"]) == (.string("file")))
    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect((try Data(contentsOf: file).count) == (0))

    let oldDate = Date(timeIntervalSince1970: 1)
    try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)
    let updateResult = try provider.callTool(
      .init(
        name: "file.touch",
        arguments: .object([
          "path": .string("notes/touched.txt"),
          "create_if_missing": .bool(false),
        ]), context: .empty
      ))
    let updatePayload = try decodeTextPayload(updateResult)
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    let modifiedDate = try #require(attributes[.modificationDate] as? Date)

    #expect((updatePayload.objectValue?["created"]) == (.bool(false)))
    #expect((updatePayload.objectValue?["modified"]) == (.bool(true)))
    #expect((modifiedDate.timeIntervalSince1970) > (oldDate.timeIntervalSince1970))
  }

  @Test
  func testFileTouchRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.touch"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.touch",
          arguments: .object([
            "path": .string("missing.txt"),
            "create_if_missing": .bool(false),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("does not exist"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.touch",
          arguments: .object(["path": .string("nested/missing.txt")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Parent directory"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.touch",
          arguments: .object(["path": .string("folder")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("directory"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.touch",
          arguments: .object(["path": .string("../outside.txt")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }
  }

  @Test
  func testFileSymlinkCreatesProjectLinkWithContainedDestinationByDefault() throws {
    let directory = try temporaryDirectory()
    let target = directory.appendingPathComponent("target.txt")
    try "target".write(to: target, atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.symlink"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.symlink",
        arguments: .object([
          "path": .string("links/current"),
          "destination": .string("../target.txt"),
          "create_directories": .bool(true),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let link = directory.appendingPathComponent("links/current")

    #expect((payload.objectValue?["operation"]) == (.string("file.symlink")))
    #expect((payload.objectValue?["project_relative_path"]) == (.string("links/current")))
    #expect((payload.objectValue?["destination"]) == (.string("../target.txt")))
    #expect((payload.objectValue?["destination_project_contained"]) == (.bool(true)))
    #expect((payload.objectValue?["destination_exists"]) == (.bool(true)))
    #expect(
      (payload.objectValue?["destination_project_relative_path"]) == (.string("target.txt")))
    #expect(
      (try FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == ("../target.txt"))
  }

  @Test
  func testFileSymlinkRejectsExternalDestinationUnlessAllowedAndCanOverwrite() throws {
    let directory = try temporaryDirectory()
    let link = directory.appendingPathComponent("external-link")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "missing")
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.symlink"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.symlink",
          arguments: .object([
            "path": .string("external-link"),
            "destination": .string("/tmp/computer-mcp-external-target"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("outside project"))
    }

    let result = try provider.callTool(
      .init(
        name: "file.symlink",
        arguments: .object([
          "path": .string("external-link"),
          "destination": .string("/tmp/computer-mcp-external-target"),
          "allow_external_destination": .bool(true),
          "overwrite": .bool(true),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["destination_project_contained"]) == (.bool(false)))
    #expect((payload.objectValue?["allow_external_destination"]) == (.bool(true)))
    #expect((payload.objectValue?["overwritten"]) == (.bool(true)))
    #expect(
      (try FileManager.default.destinationOfSymbolicLink(atPath: link.path))
        == ("/tmp/computer-mcp-external-target"))
  }

  @Test
  func testFileSymlinkRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    let outsideDirectory = try temporaryDirectory()
    try FileManager.default.createSymbolicLink(
      atPath: directory.appendingPathComponent("outside-parent").path,
      withDestinationPath: outsideDirectory.path
    )
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.symlink"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.symlink",
          arguments: .object([
            "path": .string("../outside-link"),
            "destination": .string("target"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.symlink",
          arguments: .object([
            "path": .string("outside-parent/link"),
            "destination": .string("target"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("symbolic link"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.symlink",
          arguments: .object([
            "path": .string("empty-link"),
            "destination": .string(""),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("destination"))
    }
  }

  @Test
  func testFileTrashRejectsProjectEscape() throws {
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.trash"]),
          projectDirectory: try temporaryDirectory()
        ), builtinExecutables: builtinExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.trash",
          arguments: .object(["path": .string("../outside")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }
  }

  @Test
  func testFileDownloadDryRunBuildsCurlArgvWithoutWriting() throws {
    let directory = try temporaryDirectory()
    let destination = directory.appendingPathComponent("downloads/report.txt")
    let runner = RecordingCommandRunner()
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.download"]),
          projectDirectory: directory
        ),
        commandRunner: runner, builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.download",
        arguments: .object([
          "url": .string("https://example.com/report.txt"),
          "path": .string("downloads/report.txt"),
          "create_directories": .bool(true),
          "follow_redirects": .bool(true),
          "max_redirects": .number(2),
          "connect_timeout_seconds": .number(3),
          "timeout_ms": .number(4_000),
          "max_download_bytes": .number(512),
          "max_output_bytes": .number(2_048),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect(runner.calls.isEmpty)
    #expect(!(FileManager.default.fileExists(atPath: destination.path)))
    #expect((payload.objectValue?["operation"]) == (.string("file.download")))
    #expect((payload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((payload.objectValue?["confirm_download"]) == (.bool(false)))
    #expect((payload.objectValue?["downloaded"]) == (.bool(false)))
    #expect(
      (payload.objectValue?["destination"]?.objectValue?["project_relative_path"])
        == (.string("downloads/report.txt")))
    #expect(
      (payload.objectValue?["destination"]?.objectValue?["would_create_parent_directories"])
        == (.bool(true)))
    #expect(
      (payload.objectValue?["argv"])
        == (.array([
          .string("--disable"),
          .string("--fail"),
          .string("--silent"),
          .string("--show-error"),
          .string("--max-time"),
          .string("4"),
          .string("--connect-timeout"),
          .string("3"),
          .string("--max-filesize"),
          .string("512"),
          .string("--location"),
          .string("--max-redirs"),
          .string("2"),
          .string("--output"),
          .string("-"),
          .string("--write-out"),
          .string(
            "%{stderr}\n__COMPUTER_MCP_FILE_DOWNLOAD_META__\nhttp_code=%{http_code}\nurl_effective=%{url_effective}\ncontent_type=%{content_type}\nredirect_url=%{redirect_url}\ntime_total=%{time_total}\nsize_download=%{size_download}\n"
          ),
          .string("--"),
          .string("https://example.com/report.txt"),
        ])))
    #expect((payload.objectValue?["result"]) == (.null))
  }

  @Test
  func testFileDownloadStreamsIntoCheckedDestinationAfterConfirmation() throws {
    let directory = try temporaryDirectory()
    let destination = directory.appendingPathComponent("downloads/report.txt")
    let runner = RecordingCommandRunner()
    runner.stdout = "report"
    runner.stderr = """

      __COMPUTER_MCP_FILE_DOWNLOAD_META__
      http_code=200
      url_effective=https://example.com/report.txt
      content_type=text/plain
      redirect_url=
      time_total=0.050000
      size_download=6
      """
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.download"]),
          projectDirectory: directory
        ),
        commandRunner: runner, builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.download",
        arguments: .object([
          "url": .string("https://example.com/report.txt"),
          "path": .string("downloads/report.txt"),
          "create_directories": .bool(true),
          "dry_run": .bool(false),
          "confirm_download": .bool(true),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((runner.calls.first?.executable) == ("curl"))
    #expect((try String(contentsOf: destination, encoding: .utf8)) == ("report"))
    #expect(
      try FileManager.default.contentsOfDirectory(
        atPath: destination.deletingLastPathComponent().path) == ["report.txt"])
    #expect((payload.objectValue?["operation"]) == (.string("file.download")))
    #expect((payload.objectValue?["dry_run"]) == (.bool(false)))
    #expect((payload.objectValue?["confirm_download"]) == (.bool(true)))
    #expect((payload.objectValue?["downloaded"]) == (.bool(true)))
    #expect((payload.objectValue?["http_code"]) == (.number(200)))
    #expect((payload.objectValue?["url_effective"]) == (.string("https://example.com/report.txt")))
    #expect((payload.objectValue?["content_type"]) == (.string("text/plain")))
    #expect((payload.objectValue?["downloaded_size_bytes"]) == (.number(6)))
    #expect(
      (payload.objectValue?["downloaded_file"]?.objectValue?["project_relative_path"])
        == (.string("downloads/report.txt")))
  }

  @Test
  func testFileDownloadRejectsUnsafeInputs() throws {
    let directory = try temporaryDirectory()
    let existing = directory.appendingPathComponent("downloads/report.txt")
    try FileManager.default.createDirectory(
      at: existing.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "existing".write(to: existing, atomically: true, encoding: .utf8)

    let missingConfirmRunner = RecordingCommandRunner()
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.download"]),
          projectDirectory: directory
        ),
        commandRunner: missingConfirmRunner, builtinExecutables: builtinExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.download",
          arguments: .object([
            "url": .string("https://example.com/report.txt"),
            "path": .string("downloads/new.txt"),
            "dry_run": .bool(false),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("confirm_download"))
      #expect(missingConfirmRunner.calls.isEmpty)
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.download",
          arguments: .object([
            "url": .string("https://user:pass@example.com/report.txt"),
            "path": .string("downloads/new.txt"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("userinfo"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.download",
          arguments: .object([
            "url": .string("ftp://example.com/report.txt"),
            "path": .string("downloads/new.txt"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("http or https"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.download",
          arguments: .object([
            "url": .string("https://example.com/report.txt"),
            "path": .string("downloads/report.txt"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("already exists"))
    }

  }

  @Test
  func testFileListReturnsBoundedDirectoryEntries() throws {
    let directory = try temporaryDirectory()
    try "alpha".write(
      to: directory.appendingPathComponent("alpha.txt"), atomically: true, encoding: .utf8)
    try "hidden".write(
      to: directory.appendingPathComponent(".hidden.txt"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("notes"),
      withIntermediateDirectories: true
    )
    try "nested".write(
      to: directory.appendingPathComponent("notes/nested.txt"), atomically: true, encoding: .utf8)

    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.list"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.list",
        arguments: .object(["path": .string(".")]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let entries = try #require(payload.objectValue?["entries"]?.arrayValue)

    #expect((payload.objectValue?["project_relative_path"]) == (.string(".")))
    #expect((payload.objectValue?["truncated"]) == (.bool(false)))
    #expect(
      (entries.map { $0.objectValue?["project_relative_path"] })
        == ([.string("alpha.txt"), .string("notes")]))

    let emptyPathResult = try provider.callTool(
      .init(
        name: "file.list",
        arguments: .object(["path": .string("")]), context: .empty
      ))
    let emptyPathPayload = try decodeTextPayload(emptyPathResult)
    #expect((emptyPathPayload.objectValue?["project_relative_path"]) == (.string(".")))
    #expect((emptyPathPayload.objectValue?["entries"]) == (payload.objectValue?["entries"]))

    let recursiveResult = try provider.callTool(
      .init(
        name: "file.list",
        arguments: .object([
          "path": .string("."),
          "include_hidden": .bool(true),
          "recursive_depth": .number(1),
          "max_entries": .number(2),
        ]), context: .empty
      ))
    let recursivePayload = try decodeTextPayload(recursiveResult)

    #expect((recursivePayload.objectValue?["entry_count"]) == (.number(2)))
    #expect((recursivePayload.objectValue?["truncated"]) == (.bool(true)))
  }

  @Test
  func testFileTreeReturnsBoundedHierarchy() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("Sources/App"),
      withIntermediateDirectories: true
    )
    try "main".write(
      to: directory.appendingPathComponent("Sources/App/main.swift"),
      atomically: true,
      encoding: .utf8
    )
    try "readme".write(
      to: directory.appendingPathComponent("README.md"),
      atomically: true,
      encoding: .utf8
    )
    try "hidden".write(
      to: directory.appendingPathComponent(".hidden"),
      atomically: true,
      encoding: .utf8
    )

    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.tree"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.tree",
        arguments: .object([
          "path": .string("."),
          "max_depth": .number(2),
          "max_entries": .number(10),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let tree = try #require(payload.objectValue?["tree"]?.objectValue)
    let children = try #require(tree["children"]?.arrayValue)

    #expect((payload.objectValue?["project_relative_path"]) == (.string(".")))
    #expect((payload.objectValue?["entry_count"]) == (.number(4)))
    #expect((payload.objectValue?["truncated"]) == (.bool(false)))
    #expect(
      (children.map { $0.objectValue?["project_relative_path"] })
        == ([.string("README.md"), .string("Sources")]))

    let sources = try #require(children[1].objectValue?["children"]?.arrayValue)
    #expect((sources.first?.objectValue?["project_relative_path"]) == (.string("Sources/App")))
  }

  @Test
  func testFileTreeCanReturnDirectoriesOnlyAndTruncate() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("a/b"),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("c"),
      withIntermediateDirectories: true
    )
    try "file".write(
      to: directory.appendingPathComponent("z.txt"), atomically: true, encoding: .utf8)

    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.tree"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.tree",
        arguments: .object([
          "path": .string("."),
          "directories_only": .bool(true),
          "max_depth": .number(2),
          "max_entries": .number(2),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let tree = try #require(payload.objectValue?["tree"]?.objectValue)
    let children = try #require(tree["children"]?.arrayValue)

    #expect((payload.objectValue?["directories_only"]) == (.bool(true)))
    #expect((payload.objectValue?["entry_count"]) == (.number(2)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
    #expect((children.map { $0.objectValue?["type"] }) == ([.string("directory")]))
  }

  @Test
  func testFileTreeRejectsProjectEscapeAndNonDirectory() throws {
    let directory = try temporaryDirectory()
    try "file".write(
      to: directory.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.tree"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.tree",
          arguments: .object(["path": .string("../outside")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.tree",
          arguments: .object(["path": .string("file.txt")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("not a directory"))
    }
  }

  @Test
  func testFileStatReturnsMetadataWithoutReadingContent() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("Package.swift")
    try "swift".write(to: file, atomically: true, encoding: .utf8)

    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.stat"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.stat",
        arguments: .object(["path": .string("Package.swift")]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["project_relative_path"]) == (.string("Package.swift")))
    #expect((payload.objectValue?["type"]) == (.string("file")))
    #expect((payload.objectValue?["size_bytes"]) == (.number(5)))
    #expect((payload.objectValue?["is_readable"]) == (.bool(true)))
    #expect((payload.objectValue?["content"]) == nil)
  }

  @Test
  func testFilePermissionsReturnsPOSIXModeOwnerAndFlags() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("script.sh")
    try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o754],
      ofItemAtPath: file.path
    )
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.permissions"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.permissions",
        arguments: .object(["path": .string("script.sh")]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let permissions = try #require(payload.objectValue?["permissions"]?.objectValue)
    let user = try #require(permissions["user"]?.objectValue)
    let group = try #require(permissions["group"]?.objectValue)
    let other = try #require(permissions["other"]?.objectValue)
    let access = try #require(payload.objectValue?["current_process_access"]?.objectValue)
    let flags = try #require(payload.objectValue?["flags"]?.objectValue)

    #expect((payload.objectValue?["project_relative_path"]) == (.string("script.sh")))
    #expect((payload.objectValue?["type"]) == (.string("file")))
    #expect((payload.objectValue?["mode"]) == (.number(Double(0o754))))
    #expect((payload.objectValue?["mode_octal"]) == (.string("0754")))
    #expect((payload.objectValue?["owner_account_id"]) != nil)
    #expect((payload.objectValue?["group_owner_account_id"]) != nil)
    #expect((user["read"]) == (.bool(true)))
    #expect((user["write"]) == (.bool(true)))
    #expect((user["execute"]) == (.bool(true)))
    #expect((group["read"]) == (.bool(true)))
    #expect((group["write"]) == (.bool(false)))
    #expect((group["execute"]) == (.bool(true)))
    #expect((other["read"]) == (.bool(true)))
    #expect((other["write"]) == (.bool(false)))
    #expect((other["execute"]) == (.bool(false)))
    #expect((permissions["setuid"]) == (.bool(false)))
    #expect((permissions["setgid"]) == (.bool(false)))
    #expect((permissions["sticky"]) == (.bool(false)))
    #expect((access["readable"]) == (.bool(true)))
    #expect((access["executable"]) == (.bool(true)))
    #expect((flags["immutable"]) != nil)
    #expect((flags["append_only"]) != nil)
    #expect((flags["extension_hidden"]) != nil)
  }

  @Test
  func testFilePermissionsRejectsProjectEscapeAndMissingPath() throws {
    let directory = try temporaryDirectory()
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.permissions"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.permissions",
          arguments: .object(["path": .string("../outside")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.permissions",
          arguments: .object(["path": .string("missing.txt")]), context: .empty
        ))
    ) { error in
      #expect(!(error.localizedDescription.isEmpty))
    }
  }

  @Test
  func testFileChmodSetsPOSIXModeWithExpectedCurrentMode() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("script.sh")
    try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: file.path
    )
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.chmod"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.chmod",
        arguments: .object([
          "path": .string("script.sh"),
          "mode": .string("0755"),
          "expected_current_mode": .string("0644"),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    let mode = try #require(attributes[.posixPermissions] as? NSNumber).intValue & 0o7777

    #expect((payload.objectValue?["operation"]) == (.string("file.chmod")))
    #expect((payload.objectValue?["project_relative_path"]) == (.string("script.sh")))
    #expect((payload.objectValue?["mode_before_octal"]) == (.string("0644")))
    #expect((payload.objectValue?["mode_after_octal"]) == (.string("0755")))
    #expect((payload.objectValue?["result"]?.objectValue?["type"]) == (.string("file")))
    #expect((mode) == (0o755))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.chmod",
          arguments: .object([
            "path": .string("script.sh"),
            "mode": .string("0644"),
            "expected_current_mode": .string("0600"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("expected_current_mode"))
    }
  }

  @Test
  func testFileChmodDryRunDoesNotChangeMode() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("script.sh")
    try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: file.path
    )
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.chmod"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.chmod",
        arguments: .object([
          "path": .string("script.sh"),
          "mode": .string("0755"),
          "expected_current_mode": .string("0644"),
          "dry_run": .bool(true),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    let mode = try #require(attributes[.posixPermissions] as? NSNumber).intValue & 0o7777

    #expect((payload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((payload.objectValue?["mode_before_octal"]) == (.string("0644")))
    #expect((payload.objectValue?["mode_after_octal"]) == (.string("0644")))
    #expect((payload.objectValue?["requested_mode_octal"]) == (.string("0755")))
    #expect((payload.objectValue?["would_mode_after_octal"]) == (.string("0755")))
    #expect((payload.objectValue?["would_change"]) == (.bool(true)))
    #expect((payload.objectValue?["changed"]) == (.bool(false)))
    #expect((payload.objectValue?["result"]) == (.null))
    #expect((mode) == (0o644))
  }

  @Test
  func testFileChmodRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("script.sh")
    try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.chmod"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.chmod",
          arguments: .object([
            "path": .string("script.sh"),
            "mode": .string("888"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("octal"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.chmod",
          arguments: .object([
            "path": .string("missing.sh"),
            "mode": .string("0644"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("does not exist"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.chmod",
          arguments: .object([
            "path": .string("../outside.sh"),
            "mode": .string("0644"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }
  }

  @Test
  func testFileFindReturnsBoundedNameMatches() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("Sources"),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent(".hidden"),
      withIntermediateDirectories: true
    )
    try "swift".write(
      to: directory.appendingPathComponent("Sources/App.swift"),
      atomically: true,
      encoding: .utf8
    )
    try "swift".write(
      to: directory.appendingPathComponent(".hidden/Hidden.swift"),
      atomically: true,
      encoding: .utf8
    )

    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.find"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.find",
        arguments: .object([
          "query": .string(".swift"),
          "match": .string("suffix"),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let results = try #require(payload.objectValue?["results"]?.arrayValue)

    #expect((payload.objectValue?["result_count"]) == (.number(1)))
    #expect(
      (results.map { $0.objectValue?["project_relative_path"] })
        == ([.string("Sources/App.swift")]))

    let hiddenResult = try provider.callTool(
      .init(
        name: "file.find",
        arguments: .object([
          "query": .string("Hidden.swift"),
          "match": .string("exact"),
          "include_hidden": .bool(true),
        ]), context: .empty
      ))
    let hiddenPayload = try decodeTextPayload(hiddenResult)

    #expect((hiddenPayload.objectValue?["result_count"]) == (.number(1)))
    #expect(
      (hiddenPayload.objectValue?["results"]?.arrayValue?.first?.objectValue?[
        "project_relative_path"]) == (.string(".hidden/Hidden.swift")))
  }

  @Test
  func testFileFindReportsTruncation() throws {
    let directory = try temporaryDirectory()
    for name in ["a.txt", "b.txt", "c.txt"] {
      try "match".write(
        to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.find"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.find",
        arguments: .object([
          "query": .string(".txt"),
          "match": .string("suffix"),
          "max_results": .number(1),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["result_count"]) == (.number(1)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
  }

  @Test
  func testFileSearchReturnsBoundedTextMatches() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("Sources"),
      withIntermediateDirectories: true
    )
    try "Hello Gateway\nhello again\n".write(
      to: directory.appendingPathComponent("Sources/App.swift"),
      atomically: true,
      encoding: .utf8
    )
    try "other".write(
      to: directory.appendingPathComponent("Notes.txt"), atomically: true, encoding: .utf8)

    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.search"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.search",
        arguments: .object([
          "query": .string("hello"),
          "max_matches": .number(1),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let match = try #require(payload.objectValue?["matches"]?.arrayValue?.first?.objectValue)

    #expect((payload.objectValue?["match_count"]) == (.number(1)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
    #expect((match["project_relative_path"]) == (.string("Sources/App.swift")))
    #expect((match["line"]) == (.number(1)))
    #expect((match["column"]) == (.number(1)))
    #expect((match["preview"]) == (.string("Hello Gateway")))
  }

  @Test
  func testFileSearchSkipsHiddenFilesUnlessEnabled() throws {
    let directory = try temporaryDirectory()
    try "needle".write(
      to: directory.appendingPathComponent(".secret.txt"), atomically: true, encoding: .utf8)

    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.search"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let hiddenDisabled = try provider.callTool(
      .init(
        name: "file.search",
        arguments: .object(["query": .string("needle")]), context: .empty
      ))
    let hiddenDisabledPayload = try decodeTextPayload(hiddenDisabled)
    #expect((hiddenDisabledPayload.objectValue?["match_count"]) == (.number(0)))

    let hiddenEnabled = try provider.callTool(
      .init(
        name: "file.search",
        arguments: .object([
          "query": .string("needle"),
          "include_hidden": .bool(true),
        ]), context: .empty
      ))
    let hiddenEnabledPayload = try decodeTextPayload(hiddenEnabled)
    #expect((hiddenEnabledPayload.objectValue?["match_count"]) == (.number(1)))
  }

  @Test
  func testFileTimelineFiltersSortsAndReturnsContexts() throws {
    let directory = try temporaryDirectory()
    let nested = directory.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

    let oldFile = directory.appendingPathComponent("old.txt")
    let newFile = nested.appendingPathComponent("new.txt")
    let hiddenFile = directory.appendingPathComponent(".hidden.txt")
    try "old".write(to: oldFile, atomically: true, encoding: .utf8)
    try "new".write(to: newFile, atomically: true, encoding: .utf8)
    try "hidden".write(to: hiddenFile, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: oldFile.path)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: newFile.path)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 3_000)], ofItemAtPath: hiddenFile.path)

    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.timeline"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    let result = try provider.callTool(
      .init(
        name: "file.timeline",
        arguments: .object([
          "modified_after": .string("1970-01-01T00:25:00Z"),
          "modified_before": .string("1970-01-01T00:41:40Z"),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let files = try #require(payload.objectValue?["files"]?.arrayValue)
    let first = try #require(files.first?.objectValue)

    #expect((payload.objectValue?["operation"]) == (.string("file.timeline")))
    #expect((payload.objectValue?["project_relative_path"]) == (.string(".")))
    #expect((payload.objectValue?["include_hidden"]) == (.bool(false)))
    #expect((payload.objectValue?["sort"]) == (.string("modified_desc")))
    #expect((payload.objectValue?["matched_file_count"]) == (.number(1)))
    #expect((payload.objectValue?["returned_count"]) == (.number(1)))
    #expect((first["project_relative_path"]) == (.string("nested/new.txt")))
    #expect((first["read_context"]?.objectValue) != nil)
    #expect((first["stat_context"]?.objectValue) != nil)

    let sortedResult = try provider.callTool(
      .init(
        name: "file.timeline",
        arguments: .object([
          "include_hidden": .bool(true),
          "sort": .string("modified_asc"),
          "max_results": .number(2),
        ]), context: .empty
      ))
    let sortedPayload = try decodeTextPayload(sortedResult)
    let sortedFiles = try #require(sortedPayload.objectValue?["files"]?.arrayValue)
    let paths = sortedFiles.compactMap { $0.objectValue?["project_relative_path"]?.stringValue }

    #expect((sortedPayload.objectValue?["matched_file_count"]) == (.number(3)))
    #expect((sortedPayload.objectValue?["returned_count"]) == (.number(2)))
    #expect((sortedPayload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((paths) == (["old.txt", "nested/new.txt"]))
  }

  @Test
  func testFileTimelineRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    try "file".write(
      to: directory.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.timeline"]),
          projectDirectory: directory
        ), builtinExecutables: builtinExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.timeline",
          arguments: .object([
            "path": .string("../outside")
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.timeline",
          arguments: .object([
            "path": .string("file.txt")
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a directory"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.timeline",
          arguments: .object([
            "sort": .string("recent")
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("sort"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.timeline",
          arguments: .object([
            "modified_after": .string("not-a-date")
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("ISO8601"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.timeline",
          arguments: .object([
            "modified_after": .string("1970-01-01T00:00:02Z"),
            "modified_before": .string("1970-01-01T00:00:01Z"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("modified_after"))
    }
  }

  @Test
  func testFileBuiltinRejectsProjectEscape() throws {
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.read"]),
          projectDirectory: try temporaryDirectory()
        ), builtinExecutables: builtinExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.read",
          arguments: .object(["path": .string("../outside.txt")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }
  }

  @Test
  func testSearchBuiltinsRejectProjectEscape() throws {
    let provider = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["file.find", "file.search"]),
          projectDirectory: try temporaryDirectory()
        ), builtinExecutables: builtinExecutables))

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.find",
          arguments: .object([
            "path": .string("../outside"),
            "query": .string("x"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "file.search",
          arguments: .object([
            "path": .string("../outside"),
            "query": .string("x"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }
  }

  private var temporaryDirectories: [ScopedTemporaryDirectory] = []

  private func temporaryDirectory() throws -> URL {
    let directory = try ScopedTemporaryDirectory()
    temporaryDirectories.append(directory)
    return directory.url
  }

  private func decodeTextPayload(_ value: JSONValue) throws -> JSONValue {
    let text = try #require(
      value.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
  }
}
