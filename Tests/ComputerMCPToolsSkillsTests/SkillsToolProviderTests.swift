import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPToolsSkills

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.nativeIntegration, .serialized)
final class SkillsToolProviderTests {
  @Test
  func testSkillsToolsExposeOnlyWhenEnabled() throws {
    let disabledProvider = SkillsToolProvider(
      environment: ToolEnvironment(launcher: testExecutionLauncher(), configuration: .fixture()))
    let disabledNames = try disabledProvider.definitions().map(\.tool).map(\.name)

    #expect(!(disabledNames.contains("skills.list")))
    expectThrows(
      try disabledProvider.callTool(
        .init(name: "skills.list", arguments: .object([:]), context: .empty))
    ) { error in
      #expect(error.localizedDescription.contains("skills tools are disabled"))
    }

    let root = try temporaryDirectory()
    let enabledProvider = SkillsToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: .fixture(
          skills: SkillsConfig(
            enabled: true,
            roots: [SkillRootConfig(id: "local", path: root.path, description: "Local skills")]
          ))
      ))
    let enabledTools = try enabledProvider.definitions().map(\.tool)
    let enabledNames = enabledTools.map(\.name)

    #expect(enabledNames.contains("skills.roots"))
    #expect(enabledNames.contains("skills.list"))
    #expect(enabledNames.contains("skills.describe"))
    #expect(enabledNames.contains("skills.validate"))
    #expect(enabledNames.contains("skills.frontmatter"))
    #expect(enabledNames.contains("skills.read"))
    #expect(enabledNames.contains("skills.files"))
    #expect(enabledNames.contains("skills.read_file"))
    #expect(enabledNames.contains("skills.read_files"))
    #expect(enabledNames.contains("skills.read_package"))
    #expect(enabledNames.contains("skills.outline"))
    #expect(enabledNames.contains("skills.section"))
    #expect(enabledNames.contains("skills.tables"))
    #expect(enabledNames.contains("skills.links"))
    #expect(enabledNames.contains("skills.link_check"))
    #expect(enabledNames.contains("skills.search"))
    #expect(enabledNames.contains("skills.search_files"))
    #expect(
      enabledTools.first { $0.name == "skills.roots" }?.description.contains(
        "main MCP gateway") == true)
    #expect(
      enabledTools.first { $0.name == "skills.list" }?.description.contains(
        "separate local or coding-provider execution path") == true)
    #expect(
      enabledTools.first { $0.name == "skills.read" }?.description.contains(
        "same gateway") == true)
    #expect(
      enabledTools.first { $0.name == "skills.read_package" }?.description.contains(
        "any authorized MCP client") == true)
    #expect(
      (enabledTools.first { $0.name == "skills.read" }?.inputSchema.objectValue?["required"])
        == (.array([.string("name")])))
    #expect(
      (enabledTools.first { $0.name == "skills.read_file" }?.inputSchema.objectValue?["required"])
        == (.array([.string("name"), .string("path")])))
    #expect(
      (enabledTools.first { $0.name == "skills.read_files" }?.inputSchema.objectValue?[
        "required"]) == (.array([.string("name"), .string("paths")])))
    #expect(
      (enabledTools.first { $0.name == "skills.read_package" }?.inputSchema.objectValue?[
        "required"]) == (.array([.string("name")])))
    #expect(
      (enabledTools.first { $0.name == "skills.outline" }?.inputSchema.objectValue?["required"])
        == (.array([.string("name")])))
    #expect(
      (enabledTools.first { $0.name == "skills.section" }?.inputSchema.objectValue?["required"])
        == (.array([.string("name"), .string("heading")])))
    #expect(
      (enabledTools.first { $0.name == "skills.tables" }?.inputSchema.objectValue?["required"])
        == (.array([.string("name")])))
    #expect(
      (enabledTools.first { $0.name == "skills.links" }?.inputSchema.objectValue?["required"])
        == (.array([.string("name")])))
    #expect(
      (enabledTools.first { $0.name == "skills.link_check" }?.inputSchema.objectValue?[
        "required"]) == (.array([.string("name")])))
    #expect(
      (enabledTools.first { $0.name == "skills.validate" }?.inputSchema.objectValue?["required"])
        == (.array([.string("name")])))
    #expect(
      (enabledTools.first { $0.name == "skills.frontmatter" }?.inputSchema.objectValue?[
        "required"]) == (.array([.string("name")])))
    #expect(
      (enabledTools.first { $0.name == "skills.search_files" }?.inputSchema.objectValue?[
        "required"]) == (.array([.string("name"), .string("query")])))
  }

  @Test
  func testSkillsListReadAndSearchConfiguredRoots() throws {
    let root = try temporaryDirectory()
    try writeSkill(
      root: root,
      directory: "alpha",
      content:
        """
        ---
        name: alpha-skill
        description: >-
          Alpha helper
          skill.
        ---
        # Alpha

        Use cli.exec for alpha work.
        """
    )
    try writeSkill(
      root: root,
      directory: "beta",
      content:
        """
        ---
        name: beta-skill
        description: Beta helper skill.
        ---
        # Beta
        """
    )

    let provider = SkillsToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: .fixture(
          skills: SkillsConfig(
            enabled: true,
            roots: [SkillRootConfig(id: "local", path: root.path, description: "Local skills")]
          ))
      ))

    let rootsResult = try provider.callTool(
      .init(
        name: "skills.roots", arguments: .object([:]), context: .empty))
    let rootsPayload = try decodeTextPayload(rootsResult)
    let rootPayload = try #require(rootsPayload.objectValue?["roots"]?.arrayValue?.first)
      .objectValue
    #expect((rootPayload?["id"]) == (.string("local")))
    #expect((rootPayload?["exists"]) == (.bool(true)))
    #expect((rootPayload?["is_readable"]) == (.bool(true)))

    let listResult = try provider.callTool(
      .init(
        name: "skills.list",
        arguments: .object(["root_id": .string("local")]), context: .empty
      ))
    let listPayload = try decodeTextPayload(listResult)
    let skills = try #require(listPayload.objectValue?["skills"]?.arrayValue)

    #expect((listPayload.objectValue?["skill_count"]) == (.number(2)))
    #expect(
      (skills.map { $0.objectValue?["name"] }) == ([.string("alpha-skill"), .string("beta-skill")]))
    #expect((skills.first?.objectValue?["description"]) == (.string("Alpha helper skill.")))
    #expect(
      (skills.first?.objectValue?["read_context"]?.objectValue?["tool"]) == (.string("skills.read"))
    )
    #expect(
      (skills.first?.objectValue?["files_context"]?.objectValue?["tool"])
        == (.string("skills.files")))

    let readResult = try provider.callTool(
      .init(
        name: "skills.read",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("alpha-skill"),
        ]), context: .empty
      ))
    let readPayload = try decodeTextPayload(readResult)

    #expect((readPayload.objectValue?["name"]) == (.string("alpha-skill")))
    #expect((readPayload.objectValue?["valid_utf8"]) == (.bool(true)))
    #expect((readPayload.objectValue?["content_truncated"]) == (.bool(false)))
    #expect(readPayload.objectValue?["content"]?.stringValue?.contains("Use cli.exec") == true)

    let metadataSearch = try provider.callTool(
      .init(
        name: "skills.search",
        arguments: .object([
          "root_id": .string("local"),
          "query": .string("alpha"),
        ]), context: .empty
      ))
    let metadataPayload = try decodeTextPayload(metadataSearch)
    let metadataMatch = try #require(metadataPayload.objectValue?["matches"]?.arrayValue?.first)
      .objectValue

    #expect((metadataPayload.objectValue?["match_count"]) == (.number(1)))
    #expect((metadataMatch?["name"]) == (.string("alpha-skill")))
    #expect((metadataMatch?["matched_fields"]?.arrayValue?.contains(.string("name"))) == (true))

    let contentSearch = try provider.callTool(
      .init(
        name: "skills.search",
        arguments: .object([
          "root_id": .string("local"),
          "query": .string("cli.exec"),
          "search_content": .bool(true),
        ]), context: .empty
      ))
    let contentPayload = try decodeTextPayload(contentSearch)
    let contentMatch = try #require(contentPayload.objectValue?["matches"]?.arrayValue?.first)
      .objectValue

    #expect((contentPayload.objectValue?["match_count"]) == (.number(1)))
    #expect((contentMatch?["content_searched"]) == (.bool(true)))
    #expect((contentMatch?["content_match_count"]) == (.number(1)))
  }

  @Test
  func testSkillsFilesAndReadFileExposeWholeSkillFolderReadOnly() throws {
    let root = try temporaryDirectory()
    try writeSkill(
      root: root,
      directory: "skill-creator-lite",
      content:
        """
        ---
        name: skill-creator-lite
        description: >-
          Test skill
          folder.
        ---
        # Skill Creator Lite
        """
    )
    let skillDirectory = root.appendingPathComponent("skill-creator-lite", isDirectory: true)
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("agents", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("references", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("scripts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("assets", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("eval-viewer", isDirectory: true),
      withIntermediateDirectories: true
    )
    try "display_name: Skill Creator Lite\n".write(
      to: skillDirectory.appendingPathComponent("agents/openai.yaml"),
      atomically: true,
      encoding: .utf8
    )
    try """
    ---
    title: Guide
    audience: agents
    ---
    Use skills.read_file for references.

    | Phase | Owner |
    | --- | --- |
    | Read | Agent |
    """.write(
      to: skillDirectory.appendingPathComponent("references/guide.md"),
      atomically: true,
      encoding: .utf8
    )
    try "print('do not execute')\n".write(
      to: skillDirectory.appendingPathComponent("scripts/check.py"),
      atomically: true,
      encoding: .utf8
    )
    try Data([0, 1, 2, 255]).write(to: skillDirectory.appendingPathComponent("assets/blob.bin"))
    try "print('review')\n".write(
      to: skillDirectory.appendingPathComponent("eval-viewer/generate_review.py"),
      atomically: true,
      encoding: .utf8
    )
    try "Example license.\n".write(
      to: skillDirectory.appendingPathComponent("license.txt"),
      atomically: true,
      encoding: .utf8
    )

    let provider = SkillsToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: .fixture(
          skills: SkillsConfig(
            enabled: true,
            roots: [SkillRootConfig(id: "local", path: root.path)]
          ))
      ))

    let describeResult = try provider.callTool(
      .init(
        name: "skills.describe",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("skill-creator-lite"),
          "max_depth": .number(3),
        ]), context: .empty
      ))
    let describePayload = try decodeTextPayload(describeResult)
    let resourcePayloads = try #require(describePayload.objectValue?["resources"]?.arrayValue)
    func resource(_ kind: String) -> [String: JSONValue]? {
      resourcePayloads.first { $0.objectValue?["kind"] == .string(kind) }?.objectValue
    }

    #expect((describePayload.objectValue?["operation"]) == (.string("skills.describe")))
    #expect((describePayload.objectValue?["name"]) == (.string("skill-creator-lite")))
    #expect((describePayload.objectValue?["description"]) == (.string("Test skill folder.")))
    #expect(
      (describePayload.objectValue?["entrypoint"]?.objectValue?["path"]) == (.string("SKILL.md")))
    #expect(
      (describePayload.objectValue?["entrypoint"]?.objectValue?["read_context"]?.objectValue?[
        "tool"]) == (.string("skills.read")))
    #expect((describePayload.objectValue?["content"]) == nil)
    #expect((resource("agents")?["exists"]) == (.bool(true)))
    #expect((resource("agents")?["file_count"]) == (.number(1)))
    #expect((resource("references")?["exists"]) == (.bool(true)))
    #expect((resource("references")?["file_count"]) == (.number(1)))
    #expect((resource("scripts")?["exists"]) == (.bool(true)))
    #expect((resource("scripts")?["file_count"]) == (.number(1)))
    #expect((resource("assets")?["exists"]) == (.bool(true)))
    #expect((resource("assets")?["file_count"]) == (.number(1)))
    #expect((resource("other")?["file_count"]) == (.number(2)))
    #expect((resource("other")?["directory_count"]) == (.number(1)))
    #expect(
      (resource("references")?["list_context"]?.objectValue?["tool"]) == (.string("skills.files")))

    let validateResult = try provider.callTool(
      .init(
        name: "skills.validate",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("skill-creator-lite"),
        ]), context: .empty
      ))
    let validatePayload = try decodeTextPayload(validateResult)
    #expect((validatePayload.objectValue?["operation"]) == (.string("skills.validate")))
    #expect((validatePayload.objectValue?["valid"]) == (.bool(true)))
    #expect((validatePayload.objectValue?["error_count"]) == (.number(0)))
    #expect(
      (validatePayload.objectValue?["frontmatter"]?.objectValue?["name"])
        == (.string("skill-creator-lite")))
    #expect(
      (validatePayload.objectValue?["frontmatter"]?.objectValue?["description"])
        == (.string("Test skill folder.")))
    #expect(
      (validatePayload.objectValue?["describe_context"]?.objectValue?["tool"])
        == (.string("skills.describe")))

    let pathSearchResult = try provider.callTool(
      .init(
        name: "skills.search_files",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("skill-creator-lite"),
          "query": .string("blob"),
        ]), context: .empty
      ))
    let pathSearchPayload = try decodeTextPayload(pathSearchResult)
    let pathMatch = try #require(pathSearchPayload.objectValue?["matches"]?.arrayValue?.first)
      .objectValue
    #expect((pathSearchPayload.objectValue?["operation"]) == (.string("skills.search_files")))
    #expect((pathSearchPayload.objectValue?["match_count"]) == (.number(1)))
    #expect((pathMatch?["path"]) == (.string("assets/blob.bin")))
    #expect((pathMatch?["matched_fields"]) == (.array([.string("path")])))
    #expect((pathMatch?["content_searched"]) == (.bool(false)))
    #expect((pathMatch?["read_context"]?.objectValue?["tool"]) == (.string("skills.read_file")))

    let contentSearchResult = try provider.callTool(
      .init(
        name: "skills.search_files",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("skill-creator-lite"),
          "query": .string("references"),
          "search_content": .bool(true),
        ]), context: .empty
      ))
    let contentSearchPayload = try decodeTextPayload(contentSearchResult)
    let contentMatches = try #require(contentSearchPayload.objectValue?["matches"]?.arrayValue)
    let guideMatch = try #require(
      contentMatches.first { $0.objectValue?["path"] == .string("references/guide.md") }
    )
    #expect((guideMatch.objectValue?["content_searched"]) == (.bool(true)))
    #expect((guideMatch.objectValue?["content_match_count"]) == (.number(1)))
    #expect((guideMatch.objectValue?["valid_utf8"]) == (.bool(true)))

    let filesResult = try provider.callTool(
      .init(
        name: "skills.files",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("skill-creator-lite"),
          "max_depth": .number(3),
        ]), context: .empty
      ))
    let filesPayload = try decodeTextPayload(filesResult)
    let files = try #require(filesPayload.objectValue?["files"]?.arrayValue)
    let paths = files.compactMap { $0.objectValue?["path"]?.stringValue }

    #expect(paths.contains("SKILL.md"))
    #expect(paths.contains("references"))
    #expect(paths.contains("references/guide.md"))
    #expect(paths.contains("scripts/check.py"))
    #expect(paths.contains("assets/blob.bin"))
    #expect(paths.contains("eval-viewer/generate_review.py"))
    #expect(
      (files.first { $0.objectValue?["path"] == .string("references") }?
        .objectValue?["list_context"]?.objectValue?["tool"]) == (.string("skills.files")))
    #expect(
      (files.first { $0.objectValue?["path"] == .string("references/guide.md") }?
        .objectValue?["read_context"]?.objectValue?["tool"]) == (.string("skills.read_file")))
    #expect(
      (files.first { $0.objectValue?["path"] == .string("SKILL.md") }?
        .objectValue?["outline_context"]?.objectValue?["tool"]) == (.string("skills.outline")))
    #expect(
      (files.first { $0.objectValue?["path"] == .string("references/guide.md") }?
        .objectValue?["outline_language"]) == (.string("markdown")))
    #expect(
      (files.first { $0.objectValue?["path"] == .string("references/guide.md") }?
        .objectValue?["outline_context"]?.objectValue?["arguments"]?.objectValue?["path"])
        == (.string("references/guide.md")))
    #expect(
      (files.first { $0.objectValue?["path"] == .string("references/guide.md") }?
        .objectValue?["frontmatter_context"]?.objectValue?["tool"])
        == (.string("skills.frontmatter")))
    #expect(
      (files.first { $0.objectValue?["path"] == .string("references/guide.md") }?
        .objectValue?["frontmatter_context"]?.objectValue?["arguments"]?.objectValue?["path"])
        == (.string("references/guide.md")))
    #expect(
      (files.first { $0.objectValue?["path"] == .string("references/guide.md") }?
        .objectValue?["section_context"]?.objectValue?["tool"]) == (.string("skills.section")))
    #expect(
      (files.first { $0.objectValue?["path"] == .string("references/guide.md") }?
        .objectValue?["section_context"]?.objectValue?["required_arguments"])
        == (.array([.string("heading")])))
    #expect(
      (files.first { $0.objectValue?["path"] == .string("references/guide.md") }?
        .objectValue?["tables_context"]?.objectValue?["tool"]) == (.string("skills.tables")))
    #expect(
      (files.first { $0.objectValue?["path"] == .string("references/guide.md") }?
        .objectValue?["tables_context"]?.objectValue?["arguments"]?.objectValue?["path"])
        == (.string("references/guide.md")))
    #expect(
      (files.first { $0.objectValue?["path"] == .string("references/guide.md") }?
        .objectValue?["links_context"]?.objectValue?["tool"]) == (.string("skills.links")))
    #expect(
      (files.first { $0.objectValue?["path"] == .string("references/guide.md") }?
        .objectValue?["links_context"]?.objectValue?["arguments"]?.objectValue?["path"])
        == (.string("references/guide.md")))
    #expect(
      (files.first { $0.objectValue?["path"] == .string("SKILL.md") }?
        .objectValue?["link_check_context"]?.objectValue?["tool"]) == (.string("skills.link_check"))
    )
    #expect(
      (files.first { $0.objectValue?["path"] == .string("references/guide.md") }?
        .objectValue?["link_check_context"]?.objectValue?["arguments"]?.objectValue?["path"])
        == (.string("references/guide.md")))
    #expect(
      (files.first { $0.objectValue?["path"] == .string("assets/blob.bin") }?
        .objectValue?["link_check_context"]) == (.null))

    let rootFilesResult = try provider.callTool(
      .init(
        name: "skills.files",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("skill-creator-lite"),
          "path": .string(""),
          "max_depth": .number(1),
        ]), context: .empty
      ))
    let rootFilesPayload = try decodeTextPayload(rootFilesResult)
    #expect((rootFilesPayload.objectValue?["path"]) == (.string(".")))

    let referenceResult = try provider.callTool(
      .init(
        name: "skills.read_file",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("skill-creator-lite"),
          "path": .string("references/guide.md"),
        ]), context: .empty
      ))
    let referencePayload = try decodeTextPayload(referenceResult)
    #expect((referencePayload.objectValue?["encoding"]) == (.string("utf8")))
    #expect(
      referencePayload.objectValue?["content"]?.stringValue?.contains("Use skills.read_file")
        == true)

    let binaryResult = try provider.callTool(
      .init(
        name: "skills.read_file",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("skill-creator-lite"),
          "path": .string("assets/blob.bin"),
          "encoding": .string("base64"),
        ]), context: .empty
      ))
    let binaryPayload = try decodeTextPayload(binaryResult)
    #expect((binaryPayload.objectValue?["encoding"]) == (.string("base64")))
    #expect(
      (binaryPayload.objectValue?["content"])
        == (.string(Data([0, 1, 2, 255]).base64EncodedString())))
    #expect((binaryPayload.objectValue?["valid_utf8"]) == (.bool(false)))

    let autoBinaryResult = try provider.callTool(
      .init(
        name: "skills.read_file",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("skill-creator-lite"),
          "path": .string("assets/blob.bin"),
          "encoding": .string("auto"),
        ]), context: .empty
      ))
    let autoBinaryPayload = try decodeTextPayload(autoBinaryResult)
    #expect((autoBinaryPayload.objectValue?["encoding"]) == (.string("base64")))
    #expect(
      (autoBinaryPayload.objectValue?["content"])
        == (.string(Data([0, 1, 2, 255]).base64EncodedString())))

    let batchResult = try provider.callTool(
      .init(
        name: "skills.read_files",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("skill-creator-lite"),
          "paths": .array([
            .string("agents/openai.yaml"),
            .string("references/guide.md"),
          ]),
          "max_bytes_per_file": .number(1024),
        ]), context: .empty
      ))
    let batchPayload = try decodeTextPayload(batchResult)
    let batchFiles = try #require(batchPayload.objectValue?["files"]?.arrayValue)
    #expect((batchPayload.objectValue?["operation"]) == (.string("skills.read_files")))
    #expect((batchPayload.objectValue?["file_count"]) == (.number(2)))
    #expect((batchPayload.objectValue?["truncated_file_count"]) == (.number(0)))
    #expect(
      (batchFiles.map { $0.objectValue?["path"] })
        == ([
          .string("agents/openai.yaml"),
          .string("references/guide.md"),
        ]))
    #expect(batchFiles[0].objectValue?["content"]?.stringValue?.contains("display_name") == true)
    #expect(
      batchFiles[1].objectValue?["content"]?.stringValue?.contains("skills.read_file") == true)

    let autoBatchResult = try provider.callTool(
      .init(
        name: "skills.read_files",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("skill-creator-lite"),
          "paths": .array([
            .string("agents/openai.yaml"),
            .string("assets/blob.bin"),
          ]),
          "encoding": .string("auto"),
        ]), context: .empty
      ))
    let autoBatchPayload = try decodeTextPayload(autoBatchResult)
    let autoBatchFiles = try #require(autoBatchPayload.objectValue?["files"]?.arrayValue)
    #expect((autoBatchPayload.objectValue?["encoding"]) == (.string("auto")))
    #expect((autoBatchFiles[0].objectValue?["encoding"]) == (.string("utf8")))
    #expect((autoBatchFiles[1].objectValue?["encoding"]) == (.string("base64")))

    let packageResult = try provider.callTool(
      .init(
        name: "skills.read_package",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("skill-creator-lite"),
          "encoding": .string("auto"),
          "max_depth": .number(3),
          "max_files": .number(10),
          "max_total_bytes": .number(4096),
        ]), context: .empty
      ))
    let packagePayload = try decodeTextPayload(packageResult)
    let packageFiles = try #require(packagePayload.objectValue?["files"]?.arrayValue)
    let packageSkipped = try #require(packagePayload.objectValue?["skipped"]?.arrayValue)
    let packageByPath = Dictionary(
      uniqueKeysWithValues: packageFiles.compactMap { file -> (String, [String: JSONValue])? in
        guard let object = file.objectValue, let path = object["path"]?.stringValue else {
          return nil
        }
        return (path, object)
      })

    #expect((packagePayload.objectValue?["operation"]) == (.string("skills.read_package")))
    #expect((packagePayload.objectValue?["file_count"]) == (.number(7)))
    #expect((packagePayload.objectValue?["truncated"]) == (.bool(false)))
    #expect(packageSkipped.contains { $0.objectValue?["reason"] == .string("not_file") })
    #expect(packageByPath.keys.contains("SKILL.md"))
    #expect(packageByPath.keys.contains("eval-viewer/generate_review.py"))
    #expect(
      packageByPath["agents/openai.yaml"]?["content"]?.stringValue?.contains("display_name")
        == true)
    #expect(
      packageByPath["references/guide.md"]?["content"]?.stringValue?.contains(
        "skills.read_file")
        == true)
    #expect((packageByPath["assets/blob.bin"]?["encoding"]) == (.string("base64")))
    #expect(
      (packageByPath["assets/blob.bin"]?["content"])
        == (.string(Data([0, 1, 2, 255]).base64EncodedString())))
    #expect(
      (packagePayload.objectValue?["files_context"]?.objectValue?["tool"])
        == (.string("skills.files")))

    let rootPackageResult = try provider.callTool(
      .init(
        name: "skills.read_package",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("skill-creator-lite"),
          "path": .string(""),
          "encoding": .string("auto"),
          "max_depth": .number(1),
          "max_files": .number(2),
        ]), context: .empty
      ))
    let rootPackagePayload = try decodeTextPayload(rootPackageResult)
    #expect((rootPackagePayload.objectValue?["path"]) == (.string(".")))

    let smallPackageResult = try provider.callTool(
      .init(
        name: "skills.read_package",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("skill-creator-lite"),
          "encoding": .string("utf8"),
          "max_depth": .number(3),
          "max_files": .number(10),
          "max_bytes_per_file": .number(30),
          "max_total_bytes": .number(30),
        ]), context: .empty
      ))
    let smallPackagePayload = try decodeTextPayload(smallPackageResult)
    let smallPackageFiles = try #require(smallPackagePayload.objectValue?["files"]?.arrayValue)
    #expect((smallPackagePayload.objectValue?["file_count"]) == (.number(1)))
    #expect((smallPackageFiles.first?.objectValue?["path"]) == (.string("SKILL.md")))
    #expect((smallPackageFiles.first?.objectValue?["content_truncated"]) == (.bool(true)))

    expectThrows(
      try provider.callTool(
        .init(
          name: "skills.read_file",
          arguments: .object([
            "root_id": .string("local"),
            "name": .string("skill-creator-lite"),
            "path": .string("../outside.md"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escape"))
    }
  }

  @Test
  func testSkillsFrontmatterReadsSkillPackageMarkdownMetadata() throws {
    let root = try temporaryDirectory()
    try writeSkill(
      root: root,
      directory: "skill-frontmatter",
      content:
        """
        ---
        name: skill-frontmatter
        description: Read metadata.
        tags:
          - gateway
        ---
        # Body
        """
    )
    let skillDirectory = root.appendingPathComponent("skill-frontmatter", isDirectory: true)
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("references", isDirectory: true),
      withIntermediateDirectories: true
    )
    try """
    +++
    title = "Reference"
    weight = 3
    +++
    # Reference
    """.write(
      to: skillDirectory.appendingPathComponent("references/page.md"), atomically: true,
      encoding: .utf8)
    try "# Plain\n".write(
      to: skillDirectory.appendingPathComponent("references/plain.md"),
      atomically: true,
      encoding: .utf8
    )
    try """
    ---
    title: [unterminated
    ---
    # Bad
    """.write(
      to: skillDirectory.appendingPathComponent("references/bad.md"), atomically: true,
      encoding: .utf8)
    let provider = SkillsToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: .fixture(
          skills: SkillsConfig(
            enabled: true,
            roots: [SkillRootConfig(id: "local", path: root.path)]
          ))
      ))

    let skillResult = try provider.callTool(
      .init(
        name: "skills.frontmatter",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("skill-frontmatter"),
        ]), context: .empty
      ))
    let skillPayload = try decodeTextPayload(skillResult)
    let skillValue = try #require(skillPayload.objectValue?["value"]?.objectValue)

    #expect((skillPayload.objectValue?["operation"]) == (.string("skills.frontmatter")))
    #expect((skillPayload.objectValue?["root_id"]) == (.string("local")))
    #expect((skillPayload.objectValue?["name"]) == (.string("skill-frontmatter")))
    #expect((skillPayload.objectValue?["path"]) == (.string("SKILL.md")))
    #expect((skillPayload.objectValue?["found"]) == (.bool(true)))
    #expect((skillPayload.objectValue?["format"]) == (.string("yaml")))
    #expect((skillPayload.objectValue?["parsed"]) == (.bool(true)))
    #expect((skillPayload.objectValue?["raw_start_line"]) == (.number(2)))
    #expect((skillPayload.objectValue?["raw_end_line"]) == (.number(5)))
    #expect((skillPayload.objectValue?["closing_line"]) == (.number(6)))
    #expect((skillPayload.objectValue?["body_start_line"]) == (.number(7)))
    #expect((skillValue["name"]) == (.string("skill-frontmatter")))
    #expect((skillValue["description"]) == (.string("Read metadata.")))
    #expect((skillValue["tags"]) == (.array([.string("gateway")])))
    #expect(
      (skillPayload.objectValue?["read_file_context"]?.objectValue?["tool"])
        == (.string("skills.read_file")))

    let tomlResult = try provider.callTool(
      .init(
        name: "skills.frontmatter",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("skill-frontmatter"),
          "path": .string("references/page.md"),
          "format": .string("toml"),
        ]), context: .empty
      ))
    let tomlPayload = try decodeTextPayload(tomlResult)
    let tomlValue = try #require(tomlPayload.objectValue?["value"]?.objectValue)
    #expect((tomlPayload.objectValue?["path"]) == (.string("references/page.md")))
    #expect((tomlPayload.objectValue?["format"]) == (.string("toml")))
    #expect((tomlPayload.objectValue?["found"]) == (.bool(true)))
    #expect((tomlValue["title"]) == (.string("Reference")))
    #expect((tomlValue["weight"]) == (.number(3)))

    let missingResult = try provider.callTool(
      .init(
        name: "skills.frontmatter",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("skill-frontmatter"),
          "path": .string("references/plain.md"),
        ]), context: .empty
      ))
    let missingPayload = try decodeTextPayload(missingResult)
    #expect((missingPayload.objectValue?["found"]) == (.bool(false)))
    #expect(
      (missingPayload.objectValue?["failure"]?.objectValue?["reason"])
        == (.string("missing_frontmatter")))

    let badResult = try provider.callTool(
      .init(
        name: "skills.frontmatter",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("skill-frontmatter"),
          "path": .string("references/bad.md"),
        ]), context: .empty
      ))
    let badPayload = try decodeTextPayload(badResult)
    #expect((badPayload.objectValue?["found"]) == (.bool(true)))
    #expect((badPayload.objectValue?["parsed"]) == (.bool(false)))
    #expect((badPayload.objectValue?["parse_error"]?.stringValue) != nil)
    #expect((badPayload.objectValue?["value"]) == (.null))
  }

  @Test
  func testSkillsFrontmatterRejectsBadInputs() throws {
    let root = try temporaryDirectory()
    try writeSkill(
      root: root,
      directory: "skill-frontmatter",
      content:
        """
        ---
        name: skill-frontmatter
        description: Read metadata.
        ---
        # Body
        """
    )
    let skillDirectory = root.appendingPathComponent("skill-frontmatter", isDirectory: true)
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("references", isDirectory: true),
      withIntermediateDirectories: true
    )
    try Data([0xff, 0xfe]).write(to: skillDirectory.appendingPathComponent("bad.md"))
    let provider = SkillsToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: .fixture(
          skills: SkillsConfig(
            enabled: true,
            roots: [SkillRootConfig(id: "local", path: root.path)]
          ))
      ))

    expectThrows(
      try provider.callTool(
        .init(
          name: "skills.frontmatter",
          arguments: .object([
            "root_id": .string("local"),
            "name": .string("skill-frontmatter"),
            "path": .string("../outside.md"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escape"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "skills.frontmatter",
          arguments: .object([
            "root_id": .string("local"),
            "name": .string("skill-frontmatter"),
            "path": .string("references"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("directory"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "skills.frontmatter",
          arguments: .object([
            "root_id": .string("local"),
            "name": .string("skill-frontmatter"),
            "path": .string("bad.md"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("not valid UTF-8"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "skills.frontmatter",
          arguments: .object([
            "root_id": .string("local"),
            "name": .string("skill-frontmatter"),
            "format": .string("json"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("format"))
    }
  }

  @Test
  func testSkillsTablesExtractsSkillPackageMarkdownTables() throws {
    let root = try temporaryDirectory()
    try writeSkill(
      root: root,
      directory: "table-skill",
      content:
        """
        ---
        name: table-skill
        description: Table skill.
        ---
        # Table Skill
        """
    )
    let skillDirectory = root.appendingPathComponent("table-skill", isDirectory: true)
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("references", isDirectory: true),
      withIntermediateDirectories: true
    )
    try """
    # Reference

    | Name | Count | Note |
    | :--- | ---: | :---: |
    | Alpha | 1 | ok |
    | Short | 3 |

    ```md
    | Hidden | Value |
    | --- | --- |
    | X | Y |
    ```
    """.write(
      to: skillDirectory.appendingPathComponent("references/table.md"),
      atomically: true,
      encoding: .utf8
    )

    let provider = SkillsToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: .fixture(
          skills: SkillsConfig(
            enabled: true,
            roots: [SkillRootConfig(id: "local", path: root.path)]
          ))
      ))

    let result = try provider.callTool(
      .init(
        name: "skills.tables",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("table-skill"),
          "path": .string("references/table.md"),
          "max_tables": .number(10),
          "max_rows_per_table": .number(10),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let tables = try #require(payload.objectValue?["tables"]?.arrayValue)
    let first = try #require(tables.first?.objectValue)
    let firstRows = try #require(first["rows"]?.arrayValue)

    #expect((payload.objectValue?["operation"]) == (.string("skills.tables")))
    #expect((payload.objectValue?["root_id"]) == (.string("local")))
    #expect((payload.objectValue?["name"]) == (.string("table-skill")))
    #expect((payload.objectValue?["path"]) == (.string("references/table.md")))
    #expect((payload.objectValue?["include_code_blocks"]) == (.bool(false)))
    #expect((payload.objectValue?["table_count"]) == (.number(1)))
    #expect((payload.objectValue?["returned_count"]) == (.number(1)))
    #expect((payload.objectValue?["truncated"]) == (.bool(false)))
    #expect((first["start_line"]) == (.number(3)))
    #expect((first["headers"]) == (.array([.string("Name"), .string("Count"), .string("Note")])))
    #expect(
      (first["alignments"]) == (.array([.string("left"), .string("right"), .string("center")])))
    #expect((first["row_count"]) == (.number(2)))
    #expect(
      (firstRows[0].objectValue?["cells"])
        == (.array([.string("Alpha"), .string("1"), .string("ok")])))
    #expect((firstRows[1].objectValue?["missing_cell_count"]) == (.number(1)))
    #expect(
      (firstRows[1].objectValue?["cells"])
        == (.array([.string("Short"), .string("3"), .string("")])))
    #expect(
      (payload.objectValue?["read_file_context"]?.objectValue?["tool"])
        == (.string("skills.read_file")))
    #expect(
      (payload.objectValue?["link_check_context"]?.objectValue?["tool"])
        == (.string("skills.link_check")))

    let codeBlockResult = try provider.callTool(
      .init(
        name: "skills.tables",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("table-skill"),
          "path": .string("references/table.md"),
          "include_code_blocks": .bool(true),
        ]), context: .empty
      ))
    let codeBlockPayload = try decodeTextPayload(codeBlockResult)
    #expect((codeBlockPayload.objectValue?["table_count"]) == (.number(2)))

    let truncatedResult = try provider.callTool(
      .init(
        name: "skills.tables",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("table-skill"),
          "path": .string("references/table.md"),
          "max_rows_per_table": .number(1),
        ]), context: .empty
      ))
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    let truncatedTable = try #require(
      truncatedPayload.objectValue?["tables"]?.arrayValue?.first
    ).objectValue
    #expect((truncatedPayload.objectValue?["row_truncated_table_count"]) == (.number(1)))
    #expect((truncatedTable?["row_result_truncated"]) == (.bool(true)))
    #expect((truncatedTable?["returned_row_count"]) == (.number(1)))
  }

  @Test
  func testSkillsTablesRejectsBadInputs() throws {
    let root = try temporaryDirectory()
    try writeSkill(
      root: root,
      directory: "table-bad-skill",
      content:
        """
        ---
        name: table-bad-skill
        description: Bad table skill.
        ---
        # Table Bad Skill
        """
    )
    let skillDirectory = root.appendingPathComponent("table-bad-skill", isDirectory: true)
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("references", isDirectory: true),
      withIntermediateDirectories: true
    )
    try Data([0xff, 0xfe]).write(
      to: skillDirectory.appendingPathComponent("references/binary.md")
    )

    let provider = SkillsToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: .fixture(
          skills: SkillsConfig(
            enabled: true,
            roots: [SkillRootConfig(id: "local", path: root.path)],
            maxBytesPerSkill: 128
          ))
      ))

    expectThrows(
      try provider.callTool(
        .init(
          name: "skills.tables",
          arguments: .object([
            "root_id": .string("local"),
            "name": .string("table-bad-skill"),
            "path": .string("../outside.md"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escape"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "skills.tables",
          arguments: .object([
            "root_id": .string("local"),
            "name": .string("table-bad-skill"),
            "path": .string("references"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("directory"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "skills.tables",
          arguments: .object([
            "root_id": .string("local"),
            "name": .string("table-bad-skill"),
            "path": .string("references/binary.md"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("valid UTF-8"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "skills.tables",
          arguments: .object([
            "root_id": .string("local"),
            "name": .string("table-bad-skill"),
            "max_tables": .number(0),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_tables"))
    }
  }

  @Test
  func testSkillsLinksReturnsBoundedMechanicalSkillLinks() throws {
    let root = try temporaryDirectory()
    try writeSkill(
      root: root,
      directory: "link-skill",
      content:
        """
        ---
        name: link-skill
        description: Link skill.
        ---
        # Link Skill

        See [Guide](references/guide.md#usage "Guide docs") and ![Asset](assets/icon.png).
        Use [API][api-ref] and [MissingRef][missing-ref].
        Visit <https://example.com/docs>.

        [api-ref]: references/guide.md#custom "Guide Reference"

        ```md
        [Ignored](secret.md)
        ```
        """
    )
    let skillDirectory = root.appendingPathComponent("link-skill", isDirectory: true)
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("references", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("assets", isDirectory: true),
      withIntermediateDirectories: true
    )
    try "# Usage\n\n<a id=\"custom\"></a>\n".write(
      to: skillDirectory.appendingPathComponent("references/guide.md"),
      atomically: true,
      encoding: .utf8
    )
    try Data([137, 80, 78, 71]).write(to: skillDirectory.appendingPathComponent("assets/icon.png"))

    let provider = SkillsToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: .fixture(
          skills: SkillsConfig(
            enabled: true,
            roots: [SkillRootConfig(id: "local", path: root.path)]
          ))
      ))

    let result = try provider.callTool(
      .init(
        name: "skills.links",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("link-skill"),
          "max_links": .number(10),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let links = try #require(payload.objectValue?["links"]?.arrayValue)
    func link(label: String) -> [String: JSONValue]? {
      links.first { $0.objectValue?["label"] == .string(label) }?.objectValue
    }
    let guide = try #require(link(label: "Guide"))
    let asset = try #require(link(label: "Asset"))
    let api = try #require(link(label: "API"))
    let missingRef = try #require(link(label: "MissingRef"))
    let definition = try #require(
      links.first { $0.objectValue?["kind"] == .string("reference_definition") }?.objectValue)
    let autolink = try #require(
      links.first { $0.objectValue?["kind"] == .string("autolink") }?.objectValue)

    #expect((payload.objectValue?["operation"]) == (.string("skills.links")))
    #expect((payload.objectValue?["root_id"]) == (.string("local")))
    #expect((payload.objectValue?["name"]) == (.string("link-skill")))
    #expect((payload.objectValue?["path"]) == (.string("SKILL.md")))
    #expect((payload.objectValue?["link_count"]) == (.number(6)))
    #expect((payload.objectValue?["returned_count"]) == (.number(6)))
    #expect((payload.objectValue?["local_count"]) == (.number(4)))
    #expect((payload.objectValue?["external_count"]) == (.number(1)))
    #expect((payload.objectValue?["image_count"]) == (.number(1)))
    #expect((payload.objectValue?["reference_definition_count"]) == (.number(1)))
    #expect((payload.objectValue?["truncated"]) == (.bool(false)))
    #expect((guide["destination"]) == (.string("references/guide.md#usage")))
    #expect((guide["resolved_destination"]) == (.string("references/guide.md#usage")))
    #expect(
      (guide["target"]?.objectValue?["target_skill_relative_path"])
        == (.string("references/guide.md")))
    #expect((guide["target"]?.objectValue?["fragment"]) == (.string("usage")))
    #expect(
      (guide["target_context"]?.objectValue?["read_context"]?.objectValue?["arguments"]?
        .objectValue?["path"]) == (.string("references/guide.md")))
    #expect((asset["is_image"]) == (.bool(true)))
    #expect(
      (asset["target"]?.objectValue?["target_skill_relative_path"]) == (.string("assets/icon.png")))
    #expect((api["destination"]) == (.null))
    #expect((api["resolved_destination"]) == (.string("references/guide.md#custom")))
    #expect((api["resolved_via_reference_definition"]) == (.bool(true)))
    #expect((api["reference_definition_line"]) == (.number(11)))
    #expect((api["target"]?.objectValue?["fragment"]) == (.string("custom")))
    #expect((missingRef["resolved_destination"]) == (.null))
    #expect((missingRef["target"]) == (.null))
    #expect((definition["destination"]) == (.string("references/guide.md#custom")))
    #expect((definition["title"]) == (.string("Guide Reference")))
    #expect((autolink["target"]?.objectValue?["kind"]) == (.string("url")))
    #expect((autolink["target"]?.objectValue?["scheme"]) == (.string("https")))
    #expect(
      (payload.objectValue?["link_check_context"]?.objectValue?["tool"])
        == (.string("skills.link_check")))

    let truncatedResult = try provider.callTool(
      .init(
        name: "skills.links",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("link-skill"),
          "include_images": .bool(false),
          "max_links": .number(1),
        ]), context: .empty
      ))
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["include_images"]) == (.bool(false)))
    #expect((truncatedPayload.objectValue?["link_count"]) == (.number(5)))
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))

    let codeBlockResult = try provider.callTool(
      .init(
        name: "skills.links",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("link-skill"),
          "include_code_blocks": .bool(true),
          "max_links": .number(10),
        ]), context: .empty
      ))
    let codeBlockPayload = try decodeTextPayload(codeBlockResult)
    #expect((codeBlockPayload.objectValue?["link_count"]) == (.number(7)))
  }

  @Test
  func testSkillsLinksRejectsBadInputs() throws {
    let root = try temporaryDirectory()
    try writeSkill(
      root: root,
      directory: "link-bad-skill",
      content:
        """
        ---
        name: link-bad-skill
        description: Bad link inventory skill.
        ---
        # Bad Link Skill
        """
    )
    let skillDirectory = root.appendingPathComponent("link-bad-skill", isDirectory: true)
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("references", isDirectory: true),
      withIntermediateDirectories: true
    )
    try Data([0xff, 0xfe]).write(
      to: skillDirectory.appendingPathComponent("references/binary.md")
    )

    let provider = SkillsToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: .fixture(
          skills: SkillsConfig(
            enabled: true,
            roots: [SkillRootConfig(id: "local", path: root.path)],
            maxBytesPerSkill: 128
          ))
      ))

    expectThrows(
      try provider.callTool(
        .init(
          name: "skills.links",
          arguments: .object([
            "root_id": .string("local"),
            "name": .string("link-bad-skill"),
            "path": .string("../outside.md"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escape"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "skills.links",
          arguments: .object([
            "root_id": .string("local"),
            "name": .string("link-bad-skill"),
            "path": .string("references"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("directory"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "skills.links",
          arguments: .object([
            "root_id": .string("local"),
            "name": .string("link-bad-skill"),
            "path": .string("references/binary.md"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("valid UTF-8"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "skills.links",
          arguments: .object([
            "root_id": .string("local"),
            "name": .string("link-bad-skill"),
            "max_links": .number(0),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_links"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "skills.links",
          arguments: .object([
            "root_id": .string("local"),
            "name": .string("link-bad-skill"),
            "max_bytes": .number(1024),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("skills.max_bytes_per_skill"))
    }
  }

  @Test
  func testSkillsLinkCheckReportsSkillLocalBrokenAndUncheckedLinks() throws {
    let root = try temporaryDirectory()
    try writeSkill(
      root: root,
      directory: "doc-skill",
      content:
        """
        ---
        name: doc-skill
        description: Documentation skill.
        ---
        # Doc Skill

        [Guide](references/guide.md#usage)
        [Missing](references/missing.md)
        [Outside](../outside.md)
        [External](https://example.com)
        [Ref][guide-ref]
        [NoRef][missing-ref]
        ![Asset](assets/icon.png)
        [Bad Fragment](references/guide.md#missing)
        [Script](scripts/check.py)
        [Empty]()

        [guide-ref]: references/guide.md#custom
        """
    )
    let skillDirectory = root.appendingPathComponent("doc-skill", isDirectory: true)
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("references", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("assets", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("scripts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try """
    # Usage

    <a id="custom"></a>
    """.write(
      to: skillDirectory.appendingPathComponent("references/guide.md"),
      atomically: true,
      encoding: .utf8
    )
    try Data([137, 80, 78, 71]).write(to: skillDirectory.appendingPathComponent("assets/icon.png"))
    try "print('noop')\n".write(
      to: skillDirectory.appendingPathComponent("scripts/check.py"),
      atomically: true,
      encoding: .utf8
    )

    let provider = SkillsToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: .fixture(
          skills: SkillsConfig(
            enabled: true,
            roots: [SkillRootConfig(id: "local", path: root.path)]
          ))
      ))

    let result = try provider.callTool(
      .init(
        name: "skills.link_check",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("doc-skill"),
          "max_target_bytes": .number(4096),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let checks = try #require(payload.objectValue?["checks"]?.arrayValue)
    let byLabel = Dictionary(
      uniqueKeysWithValues: checks.compactMap { check -> (String, [String: JSONValue])? in
        guard let object = check.objectValue,
          let label = object["label"]?.stringValue
        else {
          return nil
        }
        return (label, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("skills.link_check")))
    #expect((payload.objectValue?["path"]) == (.string("SKILL.md")))
    #expect((payload.objectValue?["check_count"]) == (.number(11)))
    #expect((payload.objectValue?["ok_count"]) == (.number(5)))
    #expect((payload.objectValue?["broken_count"]) == (.number(5)))
    #expect((payload.objectValue?["unchecked_count"]) == (.number(1)))
    #expect((payload.objectValue?["reference_definition_count"]) == (.number(1)))
    #expect((byLabel["Guide"]?["status"]) == (.string("ok")))
    #expect(
      (byLabel["Guide"]?["target"]?.objectValue?["target_skill_relative_path"])
        == (.string("references/guide.md")))
    #expect((byLabel["Guide"]?["target"]?.objectValue?["fragment_found"]) == (.bool(true)))
    #expect((byLabel["Missing"]?["status"]) == (.string("missing_target")))
    #expect((byLabel["Outside"]?["status"]) == (.string("outside_skill")))
    #expect((byLabel["Outside"]?["target"]?.objectValue?["target_inside_skill"]) == (.bool(false)))
    #expect((byLabel["External"]?["status"]) == (.string("external_unchecked")))
    #expect((byLabel["Ref"]?["status"]) == (.string("ok")))
    #expect((byLabel["Ref"]?["resolved_via_reference_definition"]) == (.bool(true)))
    #expect((byLabel["NoRef"]?["status"]) == (.string("missing_reference_definition")))
    #expect((byLabel["Asset"]?["status"]) == (.string("ok")))
    #expect((byLabel["Bad Fragment"]?["status"]) == (.string("missing_fragment")))
    #expect((byLabel["Script"]?["status"]) == (.string("ok")))
    #expect((byLabel["Empty"]?["status"]) == (.string("empty_destination")))

    let withoutDefinitionsResult = try provider.callTool(
      .init(
        name: "skills.link_check",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("doc-skill"),
          "include_reference_definitions": .bool(false),
        ]), context: .empty
      ))
    let withoutDefinitionsPayload = try decodeTextPayload(withoutDefinitionsResult)
    #expect((withoutDefinitionsPayload.objectValue?["check_count"]) == (.number(10)))
    #expect((withoutDefinitionsPayload.objectValue?["ok_count"]) == (.number(4)))
  }

  @Test
  func testSkillsOutlineReturnsBoundedMechanicalSkillFileMarkers() throws {
    let root = try temporaryDirectory()
    try writeSkill(
      root: root,
      directory: "outline-skill",
      content:
        """
        ---
        name: outline-skill
        description: Outline skill.
        ---
        # Outline Skill

        ## Setup

        ```markdown
        # Not a heading
        ```

        ### Details
        """
    )
    let skillDirectory = root.appendingPathComponent("outline-skill", isDirectory: true)
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("scripts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try """
    import Foundation

    public struct Runner {
      func run() {}
    }
    """.write(
      to: skillDirectory.appendingPathComponent("scripts/runner.swift"),
      atomically: true,
      encoding: .utf8
    )

    let provider = SkillsToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: .fixture(
          skills: SkillsConfig(
            enabled: true,
            roots: [SkillRootConfig(id: "local", path: root.path)]
          ))
      ))

    let markdownResult = try provider.callTool(
      .init(
        name: "skills.outline",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("outline-skill"),
          "max_results": .number(2),
        ]), context: .empty
      ))
    let markdownPayload = try decodeTextPayload(markdownResult)
    let markdownItems = try #require(markdownPayload.objectValue?["items"]?.arrayValue)

    #expect((markdownPayload.objectValue?["operation"]) == (.string("skills.outline")))
    #expect((markdownPayload.objectValue?["path"]) == (.string("SKILL.md")))
    #expect((markdownPayload.objectValue?["language"]) == (.string("markdown")))
    #expect((markdownPayload.objectValue?["outline_count"]) == (.number(3)))
    #expect((markdownPayload.objectValue?["returned_count"]) == (.number(2)))
    #expect((markdownPayload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((markdownItems[0].objectValue?["kind"]) == (.string("heading")))
    #expect((markdownItems[0].objectValue?["name"]) == (.string("Outline Skill")))
    #expect((markdownItems[1].objectValue?["level"]) == (.number(2)))
    #expect(
      (markdownPayload.objectValue?["read_file_context"]?.objectValue?["tool"])
        == (.string("skills.read_file")))
    #expect(
      (markdownPayload.objectValue?["link_check_context"]?.objectValue?["tool"])
        == (.string("skills.link_check")))

    let sourceResult = try provider.callTool(
      .init(
        name: "skills.outline",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("outline-skill"),
          "path": .string("scripts/runner.swift"),
          "include_imports": .bool(true),
        ]), context: .empty
      ))
    let sourcePayload = try decodeTextPayload(sourceResult)
    let sourceItems = try #require(sourcePayload.objectValue?["items"]?.arrayValue)

    #expect((sourcePayload.objectValue?["language"]) == (.string("swift")))
    #expect((sourcePayload.objectValue?["link_check_context"]) == (.null))
    #expect((sourceItems[0].objectValue?["kind"]) == (.string("import")))
    #expect((sourceItems[0].objectValue?["name"]) == (.string("Foundation")))
    #expect((sourceItems[1].objectValue?["kind"]) == (.string("struct")))
    #expect((sourceItems[1].objectValue?["name"]) == (.string("Runner")))
    #expect((sourceItems[2].objectValue?["kind"]) == (.string("function")))
    #expect((sourceItems[2].objectValue?["name"]) == (.string("run")))
  }

  @Test
  func testSkillsOutlineRejectsBadInputs() throws {
    let root = try temporaryDirectory()
    try writeSkill(
      root: root,
      directory: "outline-bad-skill",
      content:
        """
        ---
        name: outline-bad-skill
        description: Outline bad skill.
        ---
        # Outline Bad Skill
        """
    )
    let skillDirectory = root.appendingPathComponent("outline-bad-skill", isDirectory: true)
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("references", isDirectory: true),
      withIntermediateDirectories: true
    )
    try Data([0, 1, 2, 255]).write(
      to: skillDirectory.appendingPathComponent("references/binary.md"))

    let provider = SkillsToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: .fixture(
          skills: SkillsConfig(
            enabled: true,
            roots: [SkillRootConfig(id: "local", path: root.path)],
            maxBytesPerSkill: 128
          ))
      ))

    expectThrows(
      try provider.callTool(
        .init(
          name: "skills.outline",
          arguments: .object([
            "root_id": .string("local"),
            "name": .string("outline-bad-skill"),
            "path": .string("../outside.md"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escape"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "skills.outline",
          arguments: .object([
            "root_id": .string("local"),
            "name": .string("outline-bad-skill"),
            "path": .string("references"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("directory"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "skills.outline",
          arguments: .object([
            "root_id": .string("local"),
            "name": .string("outline-bad-skill"),
            "path": .string("references/binary.md"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("valid UTF-8"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "skills.outline",
          arguments: .object([
            "root_id": .string("local"),
            "name": .string("outline-bad-skill"),
            "max_bytes": .number(1024),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("skills.max_bytes_per_skill"))
    }
  }

  @Test
  func testSkillsSectionExtractsExactHeadingSection() throws {
    let root = try temporaryDirectory()
    try writeSkill(
      root: root,
      directory: "section-skill",
      content:
        """
        ---
        name: section-skill
        description: Section skill.
        ---
        # Section Skill

        ## Install
        First
        ### Details
        Deep
        ```md
        ## Ignored
        ```
        ## Usage
        Use it

        ## Install
        Second
        """
    )

    let provider = SkillsToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: .fixture(
          skills: SkillsConfig(
            enabled: true,
            roots: [SkillRootConfig(id: "local", path: root.path)]
          ))
      ))

    let result = try provider.callTool(
      .init(
        name: "skills.section",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("section-skill"),
          "heading": .string("Install"),
          "level": .number(2),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let section = try #require(payload.objectValue?["section"]?.objectValue)
    let followingHeading = try #require(payload.objectValue?["following_heading"]?.objectValue)
    let content = try #require(section["content"]?.stringValue)

    #expect((payload.objectValue?["operation"]) == (.string("skills.section")))
    #expect((payload.objectValue?["root_id"]) == (.string("local")))
    #expect((payload.objectValue?["name"]) == (.string("section-skill")))
    #expect((payload.objectValue?["path"]) == (.string("SKILL.md")))
    #expect((payload.objectValue?["matched"]) == (.bool(true)))
    #expect((payload.objectValue?["match_count"]) == (.number(2)))
    #expect((payload.objectValue?["matched_heading"]?.objectValue?["line"]) == (.number(7)))
    #expect((followingHeading["name"]) == (.string("Usage")))
    #expect((followingHeading["line"]) == (.number(14)))
    #expect((section["start_line"]) == (.number(7)))
    #expect((section["end_line"]) == (.number(13)))
    #expect((section["line_count"]) == (.number(7)))
    #expect(content.contains("## Install"))
    #expect(content.contains("## Ignored"))
    #expect(!(content.contains("## Usage")))
    #expect((section["section_may_be_truncated"]) == (.bool(false)))
    #expect(
      (payload.objectValue?["read_file_context"]?.objectValue?["tool"])
        == (.string("skills.read_file")))
    #expect(
      (payload.objectValue?["outline_context"]?.objectValue?["tool"]) == (.string("skills.outline"))
    )

    let secondResult = try provider.callTool(
      .init(
        name: "skills.section",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("section-skill"),
          "heading": .string("Install"),
          "level": .number(2),
          "occurrence": .number(2),
          "include_heading": .bool(false),
        ]), context: .empty
      ))
    let secondPayload = try decodeTextPayload(secondResult)
    let secondSection = try #require(secondPayload.objectValue?["section"]?.objectValue)
    #expect((secondPayload.objectValue?["matched"]) == (.bool(true)))
    #expect((secondPayload.objectValue?["following_heading"]) == (.null))
    #expect((secondSection["start_line"]) == (.number(18)))
    #expect((secondSection["end_line"]) == (.number(18)))
    #expect((secondSection["content"]) == (.string("Second")))

    let truncatedResult = try provider.callTool(
      .init(
        name: "skills.section",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("section-skill"),
          "heading": .string("Install"),
          "max_section_bytes": .number(8),
        ]), context: .empty
      ))
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    let truncatedSection = try #require(truncatedPayload.objectValue?["section"]?.objectValue)
    #expect((truncatedSection["content_truncated"]) == (.bool(true)))

    let missingResult = try provider.callTool(
      .init(
        name: "skills.section",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("section-skill"),
          "heading": .string("Missing"),
        ]), context: .empty
      ))
    let missingPayload = try decodeTextPayload(missingResult)
    #expect((missingPayload.objectValue?["matched"]) == (.bool(false)))
    #expect((missingPayload.objectValue?["section"]) == (.null))
    #expect(
      (missingPayload.objectValue?["failure"]?.objectValue?["reason"])
        == (.string("missing_heading")))
  }

  @Test
  func testSkillsSectionRejectsBadInputs() throws {
    let root = try temporaryDirectory()
    try writeSkill(
      root: root,
      directory: "section-bad-skill",
      content:
        """
        ---
        name: section-bad-skill
        description: Bad section skill.
        ---
        # Section Bad Skill
        """
    )
    let skillDirectory = root.appendingPathComponent("section-bad-skill", isDirectory: true)
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("references", isDirectory: true),
      withIntermediateDirectories: true
    )
    try Data([0xff, 0xfe]).write(
      to: skillDirectory.appendingPathComponent("references/binary.md")
    )

    let provider = SkillsToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: .fixture(
          skills: SkillsConfig(
            enabled: true,
            roots: [SkillRootConfig(id: "local", path: root.path)],
            maxBytesPerSkill: 128
          ))
      ))

    expectThrows(
      try provider.callTool(
        .init(
          name: "skills.section",
          arguments: .object([
            "root_id": .string("local"),
            "name": .string("section-bad-skill"),
            "path": .string("../outside.md"),
            "heading": .string("Intro"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escape"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "skills.section",
          arguments: .object([
            "root_id": .string("local"),
            "name": .string("section-bad-skill"),
            "path": .string("references"),
            "heading": .string("Intro"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("directory"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "skills.section",
          arguments: .object([
            "root_id": .string("local"),
            "name": .string("section-bad-skill"),
            "path": .string("references/binary.md"),
            "heading": .string("Intro"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("valid UTF-8"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "skills.section",
          arguments: .object([
            "root_id": .string("local"),
            "name": .string("section-bad-skill"),
            "heading": .string("Intro"),
            "level": .number(7),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("level"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "skills.section",
          arguments: .object([
            "root_id": .string("local"),
            "name": .string("section-bad-skill"),
            "heading": .string("Intro"),
            "occurrence": .number(0),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("occurrence"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "skills.section",
          arguments: .object([
            "root_id": .string("local"),
            "name": .string("section-bad-skill"),
            "heading": .string("Intro"),
            "max_section_bytes": .number(1024),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("skills.max_bytes_per_skill"))
    }
  }

  @Test
  func testSkillsLinkCheckRejectsBadInputs() throws {
    let root = try temporaryDirectory()
    try writeSkill(
      root: root,
      directory: "bad-link-skill",
      content:
        """
        ---
        name: bad-link-skill
        description: Bad link skill.
        ---
        # Bad Link Skill
        """
    )
    let skillDirectory = root.appendingPathComponent("bad-link-skill", isDirectory: true)
    try FileManager.default.createDirectory(
      at: skillDirectory.appendingPathComponent("references", isDirectory: true),
      withIntermediateDirectories: true
    )
    try Data([0, 1, 2, 255]).write(
      to: skillDirectory.appendingPathComponent("references/binary.md"))

    let provider = SkillsToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: .fixture(
          skills: SkillsConfig(
            enabled: true,
            roots: [SkillRootConfig(id: "local", path: root.path)],
            maxBytesPerSkill: 128
          ))
      ))

    expectThrows(
      try provider.callTool(
        .init(
          name: "skills.link_check",
          arguments: .object([
            "root_id": .string("local"),
            "name": .string("bad-link-skill"),
            "path": .string("../outside.md"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escape"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "skills.link_check",
          arguments: .object([
            "root_id": .string("local"),
            "name": .string("bad-link-skill"),
            "path": .string("references"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("directory"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "skills.link_check",
          arguments: .object([
            "root_id": .string("local"),
            "name": .string("bad-link-skill"),
            "path": .string("references/binary.md"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("valid UTF-8"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "skills.link_check",
          arguments: .object([
            "root_id": .string("local"),
            "name": .string("bad-link-skill"),
            "max_bytes": .number(1024),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("skills.max_bytes_per_skill"))
    }
  }

  @Test
  func testSkillsValidateReportsPackageIssues() throws {
    let root = try temporaryDirectory()
    let badSkill = root.appendingPathComponent("bad-skill", isDirectory: true)
    try FileManager.default.createDirectory(at: badSkill, withIntermediateDirectories: true)
    try """
    ---
    name: Bad_Skill
    ---
    # Bad Skill
    """.write(
      to: badSkill.appendingPathComponent("SKILL.md"),
      atomically: true,
      encoding: .utf8
    )
    let outside = root.appendingPathComponent("outside.txt")
    try "outside\n".write(to: outside, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: badSkill.appendingPathComponent("outside-link"),
      withDestinationURL: outside
    )

    let provider = SkillsToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: .fixture(
          skills: SkillsConfig(
            enabled: true,
            roots: [SkillRootConfig(id: "local", path: root.path)]
          ))
      ))

    let result = try provider.callTool(
      .init(
        name: "skills.validate",
        arguments: .object([
          "root_id": .string("local"),
          "name": .string("bad-skill"),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let issues = try #require(payload.objectValue?["issues"]?.arrayValue)
    let codes = issues.compactMap { $0.objectValue?["code"]?.stringValue }

    #expect((payload.objectValue?["valid"]) == (.bool(false)))
    #expect(codes.contains("missing_description"))
    #expect(codes.contains("noncanonical_name"))
    #expect(codes.contains("directory_name_mismatch"))
    #expect(codes.contains("symlink_escape"))
    #expect((payload.objectValue?["error_count"]) == (.number(2)))
    #expect(
      (payload.objectValue?["frontmatter"]?.objectValue?["has_opening_delimiter"]) == (.bool(true)))
    #expect(
      (payload.objectValue?["frontmatter"]?.objectValue?["has_closing_delimiter"]) == (.bool(true)))
  }

  @Test
  func testSkillsReadRejectsAmbiguousOrUnknownSkill() throws {
    let firstRoot = try temporaryDirectory()
    let secondRoot = try temporaryDirectory()
    try writeSkill(root: firstRoot, directory: "shared", content: "---\nname: shared\n---\n# One\n")
    try writeSkill(
      root: secondRoot, directory: "shared", content: "---\nname: shared\n---\n# Two\n")

    let provider = SkillsToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: .fixture(
          skills: SkillsConfig(
            enabled: true,
            roots: [
              SkillRootConfig(id: "one", path: firstRoot.path),
              SkillRootConfig(id: "two", path: secondRoot.path),
            ]
          ))
      ))

    expectThrows(
      try provider.callTool(
        .init(
          name: "skills.read",
          arguments: .object(["name": .string("shared")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("ambiguous"))
    }

    let result = try provider.callTool(
      .init(
        name: "skills.read",
        arguments: .object([
          "root_id": .string("two"),
          "name": .string("shared"),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)

    #expect((payload.objectValue?["root_id"]) == (.string("two")))
    #expect(payload.objectValue?["content"]?.stringValue?.contains("# Two") == true)

    expectThrows(
      try provider.callTool(
        .init(
          name: "skills.read",
          arguments: .object(["name": .string("missing")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Unknown skill"))
    }
  }

  @Test
  func testSkillsReadRespectsByteLimitAndRejectsSymlinkEscapes() throws {
    let root = try temporaryDirectory()
    try writeSkill(
      root: root,
      directory: "long",
      content: "---\nname: long-skill\n---\n" + String(repeating: "x", count: 80)
    )

    let outside = try temporaryDirectory()
    try writeSkill(
      root: outside,
      directory: "escaped",
      content: "---\nname: escaped-skill\n---\n# Escape\n"
    )
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("escaped-link"),
      withDestinationURL: outside.appendingPathComponent("escaped")
    )

    let provider = SkillsToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: .fixture(
          skills: SkillsConfig(
            enabled: true,
            roots: [SkillRootConfig(id: "local", path: root.path)],
            maxBytesPerSkill: 32
          ))
      ))

    let readResult = try provider.callTool(
      .init(
        name: "skills.read",
        arguments: .object(["name": .string("long-skill")]), context: .empty
      ))
    let readPayload = try decodeTextPayload(readResult)

    #expect((readPayload.objectValue?["max_bytes"]) == (.number(32)))
    #expect((readPayload.objectValue?["content_truncated"]) == (.bool(true)))
    #expect((readPayload.objectValue?["valid_utf8"]) == (.bool(true)))

    let listResult = try provider.callTool(
      .init(
        name: "skills.list", arguments: .object([:]), context: .empty))
    let listPayload = try decodeTextPayload(listResult)
    let names = listPayload.objectValue?["skills"]?.arrayValue?.map { $0.objectValue?["name"] }

    #expect((names) == ([.string("long-skill")]))

    expectThrows(
      try provider.callTool(
        .init(
          name: "skills.read",
          arguments: .object([
            "name": .string("long-skill"),
            "max_bytes": .number(33),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("skills.max_bytes_per_skill"))
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

  private func writeSkill(root: URL, directory: String, content: String) throws {
    let skillDirectory = root.appendingPathComponent(directory, isDirectory: true)
    try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
    try content.write(
      to: skillDirectory.appendingPathComponent("SKILL.md"),
      atomically: true,
      encoding: .utf8
    )
  }
}
