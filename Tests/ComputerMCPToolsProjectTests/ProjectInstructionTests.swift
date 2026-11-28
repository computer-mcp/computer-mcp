import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPToolsProject

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.nativeIntegration)
struct ProjectInstructionTests {
  @Test
  func rootAndNestedPackagesKeepRawContentsSourcesAndScopes() throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url.resolvingSymlinksInPath()
    let raw = "\u{FEFF}---\r\nname: sample\r\n---\r\n\r\n保留  spaces\t\n"
    let paths = [
      "AGENTS.md", "skills/alpha/SKILL.md", "skills/zeta/SKILL.md",
      ".agents/skills/shared/SKILL.md", ".claude/skills/shared/SKILL.md",
      ".codex/skills/shared/SKILL.md", ".github/skills/shared/SKILL.md",
      "app/CLAUDE.md", "app/skills/feature/SKILL.md",
    ]
    for path in paths.reversed() { try write(raw, at: path, root: root) }
    try write("unrelated", at: "other/skills/unrelated/SKILL.md", root: root)
    try write("not an entrypoint", at: "skills/alpha/references/notes.md", root: root)
    let provider = provider(root: root)
    let result = try call(provider, arguments: ["path": .string("app/future/New.swift")])
    let rows = try #require(result["files"]?.arrayValue)
    #expect(rows.compactMap { $0.objectValue?["project_relative_path"]?.stringValue } == paths)
    #expect(result["target_exists"] == .bool(false))
    #expect(result["scope_project_relative_path"] == .string("app/future"))
    for (index, row) in rows.enumerated() {
      let value = try #require(row.objectValue)
      let content = try #require(value["content"]?.stringValue)
      #expect(Data(content.utf8) == Data(raw.utf8))
      #expect(value["content_truncated"] == .bool(false))
      #expect(value["apply_order"] == .integer(Int64(index)))
      #expect(value["scope_project_relative_path"] == .string(index < 7 ? "." : "app"))
      let isSkill = paths[index].hasSuffix("SKILL.md")
      #expect(value["source"] == .string(isSkill ? "skills_directory" : "filename"))
    }
    let repeated = try call(provider, arguments: ["path": .string("app/future/New.swift")])
    #expect(repeated["files"] == result["files"])
    let futureDirectory = try call(
      provider, arguments: ["path": .string("app/future"), "path_is_directory": .bool(true)])
    #expect(futureDirectory["files"] == result["files"])
    #expect(futureDirectory["scope_project_relative_path"] == .string("app/future"))
  }

  @Test
  func skillOutputHonorsContentAndResultBounds() throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url.resolvingSymlinksInPath()
    for name in ["second", "first"] {
      try write("raw\r\ncontent\n", at: "skills/\(name)/SKILL.md", root: root)
    }
    let provider = provider(root: root)
    let bounded = try call(
      provider, arguments: ["max_results": .integer(1), "max_bytes_per_file": .integer(5)])
    let rows = try #require(bounded["files"]?.arrayValue)
    #expect(rows.count == 1)
    #expect(bounded["result_truncated"] == .bool(true))
    #expect(rows.first?.objectValue?["project_relative_path"] == .string("skills/first/SKILL.md"))
    #expect(rows.first?.objectValue?["content"] == .string("raw\r\n"))
    #expect(rows.first?.objectValue?["content_bytes_read"] == .integer(5))
    #expect(rows.first?.objectValue?["content_truncated"] == .bool(true))
    let metadata = try call(provider, arguments: ["include_content": .bool(false)])
    for row in try #require(metadata["files"]?.arrayValue) {
      #expect(row.objectValue?["content"] == .null)
      #expect(row.objectValue?["content_included"] == .bool(false))
    }
  }

  @Test
  func missingScopesReturnInheritedInstructionsOrAnEmptyList() throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url.resolvingSymlinksInPath()
    let provider = provider(root: root)
    let empty = try call(provider, arguments: ["path": .string("missing/deeper/File.swift")])
    #expect(empty["files"] == .array([]))
    try write("root", at: "AGENTS.md", root: root)
    let inherited = try call(provider, arguments: ["path": .string("missing/deeper/")])
    #expect(inherited["scope_project_relative_path"] == .string("missing/deeper"))
    #expect(inherited["files"]?.arrayValue?.count == 1)
  }

  @Test(arguments: ["é", "中", "🙂"], ["", "\u{FEFF}保留\r\n"])
  func boundedUTF8ReturnsTheLongestCompleteUnchangedPrefix(scalar: String, prefix: String) throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url.resolvingSymlinksInPath()
    try write(prefix + scalar + "tail", at: "AGENTS.md", root: root)
    for scalarBytes in 1...scalar.utf8.count {
      let maxBytes = prefix.utf8.count + scalarBytes
      let result = try call(
        provider(root: root), arguments: ["max_bytes_per_file": .integer(Int64(maxBytes))])
      let row = try #require(result["files"]?.arrayValue?.first?.objectValue)
      let expected = scalarBytes == scalar.utf8.count ? prefix + scalar : prefix
      let content = try #require(row["content"]?.stringValue)
      #expect(Data(content.utf8) == Data(expected.utf8))
      #expect(row["valid_utf8"] == .bool(true))
      #expect(row["content_truncated"] == .bool(true))
      #expect(row["content_bytes_read"] == .integer(Int64(expected.utf8.count)))
    }
  }

  @Test(
    arguments: [
      [0xC3, 0x28], [0x80, 0x61], [0xC0, 0xAF], [0xE0, 0x80, 0x80],
      [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xF0, 0x9F],
    ] as [[UInt8]])
  func malformedUTF8AtTheBoundRemainsExplicit(suffix: [UInt8]) throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url.resolvingSymlinksInPath()
    let data = Data("ok".utf8) + Data(suffix)
    try data.write(to: root.appendingPathComponent("AGENTS.md"))
    for maxBytes in 3...data.count {
      let result = try call(
        provider(root: root), arguments: ["max_bytes_per_file": .integer(Int64(maxBytes))])
      let row = try #require(result["files"]?.arrayValue?.first?.objectValue)
      #expect(row["content"] == .null)
      #expect(row["valid_utf8"] == .bool(false))
      #expect(row["content_truncated"] == .bool(maxBytes < data.count))
      #expect(row["content_bytes_read"] == .integer(Int64(maxBytes)))
    }
  }

  @Test
  func invalidBytesBeforeAnIncompleteScalarRemainExplicit() throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url.resolvingSymlinksInPath()
    let data = Data([0xFF]) + Data("中".utf8)
    try data.write(to: root.appendingPathComponent("AGENTS.md"))
    let result = try call(
      provider(root: root), arguments: ["max_bytes_per_file": .integer(2)])
    let row = try #require(result["files"]?.arrayValue?.first?.objectValue)
    #expect(row["content"] == .null)
    #expect(row["valid_utf8"] == .bool(false))
    #expect(row["content_truncated"] == .bool(true))
    #expect(row["content_bytes_read"] == .integer(2))
  }

  @Test(arguments: [false, true])
  func deniedNestedTargetsFailBeforeReturningInheritedMetadata(targetExists: Bool) throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url.resolvingSymlinksInPath()
    try write("root instructions", at: "AGENTS.md", root: root)
    let nested = root.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    if targetExists { try write("private", at: "nested/File.swift", root: root) }
    let provider = provider(root: root, access: InstructionPathAccess(denied: nested))
    #expect(throws: (any Error).self) {
      try call(
        provider,
        arguments: ["path": .string("nested/File.swift"), "include_content": .bool(false)])
    }
  }

  @Test(arguments: [false, true])
  func everyInstructionAndSkillFileRequiresReadAccess(includeContent: Bool) throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url.resolvingSymlinksInPath()
    let skillPath = "skills/private/SKILL.md"
    try write("private", at: skillPath, root: root)
    let provider = provider(
      root: root, access: InstructionPathAccess(denied: root.appendingPathComponent(skillPath)))
    #expect(throws: (any Error).self) {
      try call(provider, arguments: ["include_content": .bool(includeContent)])
    }
  }

  @Test
  func deniedSkillPackagesAreNotDisclosedThroughDirectoryListings() throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url.resolvingSymlinksInPath()
    try write("private", at: "skills/private/SKILL.md", root: root)
    try write("visible", at: "skills/visible/SKILL.md", root: root)
    let provider = provider(
      root: root,
      access: InstructionPathAccess(denied: root.appendingPathComponent("skills/private")))
    let result = try call(provider)
    let paths = try #require(result["files"]?.arrayValue)
      .compactMap { $0.objectValue?["project_relative_path"]?.stringValue }
    #expect(paths == ["skills/visible/SKILL.md"])
  }

  @Test(arguments: ["skills/escape", "link"])
  func symlinkedPackagesAndFutureTargetsCannotEscapeTheProject(linkPath: String) throws {
    let temporary = try ScopedTemporaryDirectory()
    let container = temporary.url.resolvingSymlinksInPath()
    let root = container.appendingPathComponent("project")
    let outside = container.appendingPathComponent("outside")
    try write("secret", at: "SKILL.md", root: outside)
    let link = root.appendingPathComponent(linkPath)
    try FileManager.default.createDirectory(
      at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    let arguments: [String: JSONValue] =
      linkPath == "link" ? ["path": .string("link/future/File.swift")] : [:]
    #expect(throws: (any Error).self) { try call(provider(root: root), arguments: arguments) }
  }

  private func provider(root: URL, access: (any HostPathAccessChecking)? = nil)
    -> ProjectToolProvider
  {
    ProjectToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["project.instructions"]), projectDirectory: root),
        pathAccess: access))
  }

  private func call(_ provider: ProjectToolProvider, arguments: [String: JSONValue] = [:]) throws
    -> [String: JSONValue]
  {
    let result = try provider.callTool(
      .init(name: "project.instructions", arguments: .object(arguments), context: .empty))
    let text = try #require(
      result.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    return try #require(JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)).objectValue)
  }

  private func write(_ content: String, at path: String, root: URL) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(content.utf8).write(to: url)
  }
}

private struct InstructionPathAccess: HostPathAccessChecking {
  let denied: URL

  func check(_ url: URL, operation: HostPathOperation) throws {
    let path = url.resolvingSymlinksInPath().path
    if path == denied.path || path.hasPrefix(denied.path + "/") {
      throw CocoaError(.fileReadNoPermission)
    }
  }
}
