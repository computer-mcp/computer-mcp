import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPToolsStructured

@Suite(.nativeIntegration, .serialized)
final class StructuredToolProviderTests {
  @Test
  func structuredFileToolsPreserveIntegerIdentity() throws {
    let directory = try temporaryDirectory()
    let values: [String: JSONValue] = [
      "large": .integer(9_007_199_254_740_993), "maximum": .integer(.max),
      "minimum": .integer(.min), "zero": .integer(0), "one": .integer(1),
      "enabled": .bool(true), "fraction": .number(1.25),
    ]
    try JSONEncoder().encode(JSONValue.object(values)).write(
      to: directory.appendingPathComponent("numbers.json"))
    try
      "large = 9007199254740993\nmaximum = 9223372036854775807\nminimum = -9223372036854775808\nzero = 0\none = 1\nenabled = true\nfraction = 1.25\n"
      .write(
        to: directory.appendingPathComponent("numbers.toml"), atomically: true, encoding: .utf8)
    try
      "large: 9007199254740993\nmaximum: 9223372036854775807\nminimum: -9223372036854775808\nzero: 0\none: 1\nenabled: true\nfraction: 1.25\n"
      .write(
        to: directory.appendingPathComponent("numbers.yaml"), atomically: true, encoding: .utf8)
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: [
            "json.read", "toml.read", "yaml.read", "plist.read", "plist.write",
          ]),
          projectDirectory: directory), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")
      ))
    _ = try provider.callTool(
      .init(
        name: "plist.write",
        arguments: .object([
          "path": .string("numbers.plist"), "value": .object(values),
          "dry_run": .bool(false), "confirm_write": .bool(true),
        ]), context: .empty))
    for format in ["json", "toml", "yaml", "plist"] {
      let result = try provider.callTool(
        .init(
          name: "\(format).read",
          arguments: .object([
            "path": .string("numbers.\(format)")
          ]), context: .empty))
      let payload = try decodeTextPayload(result)
      let decoded =
        payload.objectValue?["value"]
        ?? payload.objectValue?["documents"]?.arrayValue?.first?.objectValue?["value"]
      #expect(decoded == .object(values), "Exact values in \(format)")
    }
  }

  @Test
  func testMarkdownLinksReturnsBoundedMechanicalLinks() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("docs/images"),
      withIntermediateDirectories: true
    )
    let readme = directory.appendingPathComponent("docs/README.md")
    try """
    # Guide

    See [Install](install.md#setup "Install docs") and ![Logo](images/logo.png).
    Use [API][api-ref] and <https://example.com/docs>.

    [api-ref]: ../API.md "API Reference"

    ```md
    [ignored](secret.md)
    ```
    """.write(to: readme, atomically: true, encoding: .utf8)
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["markdown.links"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    let result = try provider.callTool(
      .init(
        name: "markdown.links",
        arguments: .object([
          "path": .string("docs/README.md")
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let links = try #require(payload.objectValue?["links"]?.arrayValue)
    let byKind = Dictionary(
      uniqueKeysWithValues: links.map {
        ($0.objectValue?["kind"]?.stringValue ?? "", $0.objectValue ?? [:])
      })

    #expect((payload.objectValue?["operation"]) == (.string("markdown.links")))
    #expect((payload.objectValue?["project_relative_path"]) == (.string("docs/README.md")))
    #expect((payload.objectValue?["link_count"]) == (.number(5)))
    #expect((payload.objectValue?["returned_count"]) == (.number(5)))
    #expect((payload.objectValue?["truncated"]) == (.bool(false)))
    #expect((byKind["inline_link"]?["label"]) == (.string("Install")))
    #expect((byKind["inline_link"]?["destination"]) == (.string("install.md#setup")))
    #expect((byKind["inline_link"]?["title"]) == (.string("Install docs")))
    #expect(
      (byKind["inline_link"]?["target"]?.objectValue?["target_project_relative_path"])
        == (.string("docs/install.md")))
    #expect((byKind["inline_link"]?["target"]?.objectValue?["fragment"]) == (.string("setup")))
    #expect((byKind["inline_image"]?["is_image"]) == (.bool(true)))
    #expect(
      (byKind["inline_image"]?["target"]?.objectValue?["target_project_relative_path"])
        == (.string("docs/images/logo.png")))
    #expect((byKind["reference_link"]?["reference_label"]) == (.string("api-ref")))
    #expect((byKind["reference_link"]?["destination"]) == (.null))
    #expect((byKind["reference_definition"]?["destination"]) == (.string("../API.md")))
    #expect(
      (byKind["reference_definition"]?["target"]?.objectValue?["target_project_relative_path"])
        == (.string("API.md")))
    #expect((byKind["autolink"]?["target"]?.objectValue?["kind"]) == (.string("url")))
    #expect((byKind["autolink"]?["target"]?.objectValue?["scheme"]) == (.string("https")))
  }

  @Test
  func testMarkdownLinksOptionsAndTruncation() throws {
    let directory = try temporaryDirectory()
    let readme = directory.appendingPathComponent("README.md")
    try """
    ![Skip](image.png)
    [One](one.md)
    [Two](two.md)
    ```md
    [Inside](inside.md)
    ```
    """.write(to: readme, atomically: true, encoding: .utf8)
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["markdown.links"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    let result = try provider.callTool(
      .init(
        name: "markdown.links",
        arguments: .object([
          "path": .string("README.md"),
          "include_images": .bool(false),
          "max_links": .number(1),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let links = try #require(payload.objectValue?["links"]?.arrayValue)

    #expect((payload.objectValue?["include_images"]) == (.bool(false)))
    #expect((payload.objectValue?["include_code_blocks"]) == (.bool(false)))
    #expect((payload.objectValue?["link_count"]) == (.number(2)))
    #expect((payload.objectValue?["returned_count"]) == (.number(1)))
    #expect((payload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((links.first?.objectValue?["destination"]) == (.string("one.md")))

    let codeBlockResult = try provider.callTool(
      .init(
        name: "markdown.links",
        arguments: .object([
          "path": .string("README.md"),
          "include_code_blocks": .bool(true),
          "max_links": .number(10),
        ]), context: .empty
      ))
    let codeBlockPayload = try decodeTextPayload(codeBlockResult)
    #expect((codeBlockPayload.objectValue?["link_count"]) == (.number(4)))
  }

  @Test
  func testMarkdownTablesExtractsBoundedPipeTables() throws {
    let directory = try temporaryDirectory()
    let readme = directory.appendingPathComponent("README.md")
    try """
    # Data

    | Name | Count | Note |
    | :--- | ---: | :---: |
    | Alpha | 1 | ok |
    | Beta \\| escaped | 2 | centered |
    | Short | 3 |
    Text

    ```md
    | Hidden | Value |
    | --- | --- |
    | X | Y |
    ```

    Key | Value
    --- | ---
    A | B
    """.write(to: readme, atomically: true, encoding: .utf8)
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["markdown.tables"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    let result = try provider.callTool(
      .init(
        name: "markdown.tables",
        arguments: .object([
          "path": .string("README.md"),
          "max_tables": .number(10),
          "max_rows_per_table": .number(10),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let tables = try #require(payload.objectValue?["tables"]?.arrayValue)
    let first = try #require(tables.first?.objectValue)
    let firstRows = try #require(first["rows"]?.arrayValue)
    let second = try #require(tables.last?.objectValue)

    #expect((payload.objectValue?["operation"]) == (.string("markdown.tables")))
    #expect((payload.objectValue?["project_relative_path"]) == (.string("README.md")))
    #expect((payload.objectValue?["include_code_blocks"]) == (.bool(false)))
    #expect((payload.objectValue?["table_count"]) == (.number(2)))
    #expect((payload.objectValue?["returned_count"]) == (.number(2)))
    #expect((payload.objectValue?["truncated"]) == (.bool(false)))
    #expect((first["start_line"]) == (.number(3)))
    #expect((first["end_line"]) == (.number(7)))
    #expect((first["header_line"]) == (.number(3)))
    #expect((first["delimiter_line"]) == (.number(4)))
    #expect((first["column_count"]) == (.number(3)))
    #expect((first["headers"]) == (.array([.string("Name"), .string("Count"), .string("Note")])))
    #expect(
      (first["alignments"]) == (.array([.string("left"), .string("right"), .string("center")])))
    #expect((first["row_count"]) == (.number(3)))
    #expect((firstRows[1].objectValue?["cells"]?.arrayValue?[0]) == (.string("Beta | escaped")))
    #expect((firstRows[2].objectValue?["missing_cell_count"]) == (.number(1)))
    #expect(
      (firstRows[2].objectValue?["cells"])
        == (.array([.string("Short"), .string("3"), .string("")])))
    #expect((second["start_line"]) == (.number(16)))
    #expect((second["headers"]) == (.array([.string("Key"), .string("Value")])))

    let truncatedResult = try provider.callTool(
      .init(
        name: "markdown.tables",
        arguments: .object([
          "path": .string("README.md"),
          "max_tables": .number(1),
          "max_rows_per_table": .number(2),
        ]), context: .empty
      ))
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    let truncatedTable = try #require(truncatedPayload.objectValue?["tables"]?.arrayValue?.first)
      .objectValue
    #expect((truncatedPayload.objectValue?["table_count"]) == (.number(2)))
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["result_truncated"]) == (.bool(true)))
    #expect((truncatedPayload.objectValue?["row_truncated_table_count"]) == (.number(1)))
    #expect((truncatedTable?["row_result_truncated"]) == (.bool(true)))
    #expect((truncatedTable?["returned_row_count"]) == (.number(2)))

    let codeBlockResult = try provider.callTool(
      .init(
        name: "markdown.tables",
        arguments: .object([
          "path": .string("README.md"),
          "include_code_blocks": .bool(true),
        ]), context: .empty
      ))
    let codeBlockPayload = try decodeTextPayload(codeBlockResult)
    #expect((codeBlockPayload.objectValue?["table_count"]) == (.number(3)))
  }

  @Test
  func testMarkdownTablesRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try Data([0xff, 0xfe]).write(to: directory.appendingPathComponent("bad.md"))
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["markdown.tables"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    expectThrows(
      try provider.callTool(
        .init(
          name: "markdown.tables",
          arguments: .object(["path": .string("../outside.md")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "markdown.tables",
          arguments: .object(["path": .string("folder")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "markdown.tables",
          arguments: .object(["path": .string("bad.md")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("not valid UTF-8"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "markdown.tables",
          arguments: .object([
            "path": .string("bad.md"),
            "max_tables": .number(0),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_tables"))
    }
  }

  @Test
  func testMarkdownSectionExtractsExactHeadingSection() throws {
    let directory = try temporaryDirectory()
    let readme = directory.appendingPathComponent("README.md")
    try """
    # Guide

    Intro

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
    """.write(to: readme, atomically: true, encoding: .utf8)
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["markdown.section"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    let result = try provider.callTool(
      .init(
        name: "markdown.section",
        arguments: .object([
          "path": .string("README.md"),
          "heading": .string("Install"),
          "level": .number(2),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let section = try #require(payload.objectValue?["section"]?.objectValue)
    let followingHeading = try #require(payload.objectValue?["following_heading"]?.objectValue)
    let content = try #require(section["content"]?.stringValue)

    #expect((payload.objectValue?["operation"]) == (.string("markdown.section")))
    #expect((payload.objectValue?["project_relative_path"]) == (.string("README.md")))
    #expect((payload.objectValue?["matched"]) == (.bool(true)))
    #expect((payload.objectValue?["match_count"]) == (.number(2)))
    #expect((payload.objectValue?["matched_heading"]?.objectValue?["line"]) == (.number(5)))
    #expect((followingHeading["name"]) == (.string("Usage")))
    #expect((followingHeading["line"]) == (.number(12)))
    #expect((section["start_line"]) == (.number(5)))
    #expect((section["end_line"]) == (.number(11)))
    #expect((section["line_count"]) == (.number(7)))
    #expect(content.contains("## Install"))
    #expect(content.contains("## Ignored"))
    #expect(!(content.contains("## Usage")))
    #expect((section["section_may_be_truncated"]) == (.bool(false)))
    #expect(
      (payload.objectValue?["outline_context"]?.objectValue?["tool"]) == (.string("file.outline")))

    let secondResult = try provider.callTool(
      .init(
        name: "markdown.section",
        arguments: .object([
          "path": .string("README.md"),
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
    #expect((secondSection["start_line"]) == (.number(16)))
    #expect((secondSection["end_line"]) == (.number(16)))
    #expect((secondSection["content"]) == (.string("Second")))

    let truncatedResult = try provider.callTool(
      .init(
        name: "markdown.section",
        arguments: .object([
          "path": .string("README.md"),
          "heading": .string("Install"),
          "max_section_bytes": .number(8),
        ]), context: .empty
      ))
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    let truncatedSection = try #require(truncatedPayload.objectValue?["section"]?.objectValue)
    #expect((truncatedSection["content_truncated"]) == (.bool(true)))

    let missingResult = try provider.callTool(
      .init(
        name: "markdown.section",
        arguments: .object([
          "path": .string("README.md"),
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
  func testMarkdownSectionRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try Data([0xff, 0xfe]).write(to: directory.appendingPathComponent("bad.md"))
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["markdown.section"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    expectThrows(
      try provider.callTool(
        .init(
          name: "markdown.section",
          arguments: .object([
            "path": .string("../outside.md"),
            "heading": .string("Intro"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "markdown.section",
          arguments: .object([
            "path": .string("folder"),
            "heading": .string("Intro"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "markdown.section",
          arguments: .object([
            "path": .string("bad.md"),
            "heading": .string("Intro"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("not valid UTF-8"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "markdown.section",
          arguments: .object([
            "path": .string("bad.md"),
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
          name: "markdown.section",
          arguments: .object([
            "path": .string("bad.md"),
            "heading": .string("Intro"),
            "occurrence": .number(0),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("occurrence"))
    }
  }

  @Test
  func testMarkdownFrontmatterReadsYAMLAndTOML() throws {
    let directory = try temporaryDirectory()
    try """
    ---
    title: Guide
    tags:
      - mcp
      - gateway
    draft: false
    ---
    # Body
    """.write(to: directory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try """
    +++
    title = "Doc"
    weight = 2
    +++
    # Body
    """.write(to: directory.appendingPathComponent("page.md"), atomically: true, encoding: .utf8)
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["markdown.frontmatter"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    let yamlResult = try provider.callTool(
      .init(
        name: "markdown.frontmatter",
        arguments: .object(["path": .string("README.md")]), context: .empty
      ))
    let yamlPayload = try decodeTextPayload(yamlResult)
    let yamlValue = try #require(yamlPayload.objectValue?["value"]?.objectValue)

    #expect((yamlPayload.objectValue?["operation"]) == (.string("markdown.frontmatter")))
    #expect((yamlPayload.objectValue?["project_relative_path"]) == (.string("README.md")))
    #expect((yamlPayload.objectValue?["found"]) == (.bool(true)))
    #expect((yamlPayload.objectValue?["format"]) == (.string("yaml")))
    #expect((yamlPayload.objectValue?["has_opening_delimiter"]) == (.bool(true)))
    #expect((yamlPayload.objectValue?["has_closing_delimiter"]) == (.bool(true)))
    #expect((yamlPayload.objectValue?["raw_start_line"]) == (.number(2)))
    #expect((yamlPayload.objectValue?["raw_end_line"]) == (.number(6)))
    #expect((yamlPayload.objectValue?["closing_line"]) == (.number(7)))
    #expect((yamlPayload.objectValue?["body_start_line"]) == (.number(8)))
    #expect((yamlPayload.objectValue?["parsed"]) == (.bool(true)))
    #expect((yamlPayload.objectValue?["parse_error"]) == (.null))
    #expect((yamlValue["title"]) == (.string("Guide")))
    #expect((yamlValue["tags"]) == (.array([.string("mcp"), .string("gateway")])))
    #expect((yamlValue["draft"]) == (.bool(false)))

    let tomlResult = try provider.callTool(
      .init(
        name: "markdown.frontmatter",
        arguments: .object([
          "path": .string("page.md"),
          "format": .string("toml"),
        ]), context: .empty
      ))
    let tomlPayload = try decodeTextPayload(tomlResult)
    let tomlValue = try #require(tomlPayload.objectValue?["value"]?.objectValue)

    #expect((tomlPayload.objectValue?["found"]) == (.bool(true)))
    #expect((tomlPayload.objectValue?["format"]) == (.string("toml")))
    #expect((tomlPayload.objectValue?["parsed"]) == (.bool(true)))
    #expect((tomlValue["title"]) == (.string("Doc")))
    #expect((tomlValue["weight"]) == (.number(2)))
  }

  @Test
  func testMarkdownFrontmatterReportsMissingAndMalformed() throws {
    let directory = try temporaryDirectory()
    try "# Body\n".write(
      to: directory.appendingPathComponent("plain.md"),
      atomically: true,
      encoding: .utf8
    )
    try """
    ---
    title: Missing
    # Body
    """.write(
      to: directory.appendingPathComponent("unterminated.md"), atomically: true, encoding: .utf8)
    try """
    ---
    title: [unterminated
    ---
    # Body
    """.write(to: directory.appendingPathComponent("bad.md"), atomically: true, encoding: .utf8)
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["markdown.frontmatter"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    let plainResult = try provider.callTool(
      .init(
        name: "markdown.frontmatter",
        arguments: .object(["path": .string("plain.md")]), context: .empty
      ))
    let plainPayload = try decodeTextPayload(plainResult)
    #expect((plainPayload.objectValue?["found"]) == (.bool(false)))
    #expect(
      (plainPayload.objectValue?["failure"]?.objectValue?["reason"])
        == (.string("missing_frontmatter")))
    #expect((plainPayload.objectValue?["value"]) == (.null))

    let unterminatedResult = try provider.callTool(
      .init(
        name: "markdown.frontmatter",
        arguments: .object(["path": .string("unterminated.md")]), context: .empty
      ))
    let unterminatedPayload = try decodeTextPayload(unterminatedResult)
    #expect((unterminatedPayload.objectValue?["found"]) == (.bool(false)))
    #expect((unterminatedPayload.objectValue?["has_opening_delimiter"]) == (.bool(true)))
    #expect((unterminatedPayload.objectValue?["has_closing_delimiter"]) == (.bool(false)))
    #expect(
      (unterminatedPayload.objectValue?["failure"]?.objectValue?["reason"])
        == (.string("unterminated_frontmatter")))

    let badResult = try provider.callTool(
      .init(
        name: "markdown.frontmatter",
        arguments: .object(["path": .string("bad.md")]), context: .empty
      ))
    let badPayload = try decodeTextPayload(badResult)
    #expect((badPayload.objectValue?["found"]) == (.bool(true)))
    #expect((badPayload.objectValue?["parsed"]) == (.bool(false)))
    #expect((badPayload.objectValue?["parse_error"]?.stringValue) != nil)
    #expect((badPayload.objectValue?["value"]) == (.null))
  }

  @Test
  func testMarkdownFrontmatterRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try Data([0xff, 0xfe]).write(to: directory.appendingPathComponent("bad.md"))
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["markdown.frontmatter"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    expectThrows(
      try provider.callTool(
        .init(
          name: "markdown.frontmatter",
          arguments: .object(["path": .string("../outside.md")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "markdown.frontmatter",
          arguments: .object(["path": .string("folder")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "markdown.frontmatter",
          arguments: .object(["path": .string("bad.md")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("not valid UTF-8"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "markdown.frontmatter",
          arguments: .object([
            "path": .string("bad.md"),
            "format": .string("json"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("format"))
    }
  }

  @Test
  func testMarkdownLinksRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try Data([0xff, 0xfe]).write(to: directory.appendingPathComponent("bad.md"))
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["markdown.links"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    expectThrows(
      try provider.callTool(
        .init(
          name: "markdown.links",
          arguments: .object(["path": .string("../outside.md")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "markdown.links",
          arguments: .object(["path": .string("folder")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "markdown.links",
          arguments: .object([
            "path": .string("bad.md"),
            "max_bytes": .number(2),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("not valid UTF-8"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "markdown.links",
          arguments: .object([
            "path": .string("bad.md"),
            "max_links": .number(0),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_links"))
    }
  }

  @Test
  func testMarkdownLinkCheckReportsLocalBrokenAndUncheckedLinks() throws {
    let directory = try temporaryDirectory()
    let docs = directory.appendingPathComponent("docs")
    let images = docs.appendingPathComponent("images")
    try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
    try Data([0, 1, 2]).write(to: docs.appendingPathComponent("asset.bin"))
    try Data([0xff]).write(to: images.appendingPathComponent("logo.png"))
    try """
    # Setup
    <a id="custom"></a>
    """.write(to: docs.appendingPathComponent("install.md"), atomically: true, encoding: .utf8)
    try """
    # API
    """.write(to: directory.appendingPathComponent("API.md"), atomically: true, encoding: .utf8)
    try """
    # Docs
    [Install](install.md#setup)
    [Missing](missing.md)
    [Bad Fragment](install.md#missing)
    [External](https://example.com/docs)
    [Ref][guide]
    [NoRef][missing-ref]
    ![Logo](images/logo.png)
    [Empty]()
    [Custom](install.md#custom)
    [Binary Fragment](asset.bin#bytes)
    [Guide Definition][guide]

    [guide]: ../API.md#api
    """.write(to: docs.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["markdown.link_check"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    let result = try provider.callTool(
      .init(
        name: "markdown.link_check",
        arguments: .object([
          "path": .string("docs/README.md"),
          "max_links": .number(50),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let checks = try #require(payload.objectValue?["checks"]?.arrayValue)
    let byLabel = Dictionary(
      uniqueKeysWithValues: checks.compactMap { entry -> (String, [String: JSONValue])? in
        guard let object = entry.objectValue,
          let label = object["label"]?.stringValue
        else {
          return nil
        }
        return (label, object)
      })

    #expect((payload.objectValue?["operation"]) == (.string("markdown.link_check")))
    #expect((payload.objectValue?["project_relative_path"]) == (.string("docs/README.md")))
    #expect((payload.objectValue?["check_count"]) == (.number(12)))
    #expect((payload.objectValue?["ok_count"]) == (.number(6)))
    #expect((payload.objectValue?["broken_count"]) == (.number(4)))
    #expect((payload.objectValue?["unchecked_count"]) == (.number(2)))
    #expect((payload.objectValue?["reference_definition_count"]) == (.number(1)))
    #expect((byLabel["Install"]?["status"]) == (.string("ok")))
    #expect((byLabel["Install"]?["target"]?.objectValue?["fragment_found"]) == (.bool(true)))
    #expect((byLabel["Missing"]?["status"]) == (.string("missing_target")))
    #expect((byLabel["Bad Fragment"]?["status"]) == (.string("missing_fragment")))
    #expect((byLabel["External"]?["status"]) == (.string("external_unchecked")))
    #expect((byLabel["Ref"]?["status"]) == (.string("ok")))
    #expect((byLabel["Ref"]?["resolved_via_reference_definition"]) == (.bool(true)))
    #expect((byLabel["Ref"]?["reference_definition_line"]) == (.number(14)))
    #expect((byLabel["NoRef"]?["status"]) == (.string("missing_reference_definition")))
    #expect((byLabel["Logo"]?["status"]) == (.string("ok")))
    #expect((byLabel["Empty"]?["status"]) == (.string("empty_destination")))
    #expect((byLabel["Custom"]?["status"]) == (.string("ok")))
    #expect((byLabel["Binary Fragment"]?["status"]) == (.string("fragment_unchecked")))
    #expect((byLabel["guide"]?["kind"]) == (.string("reference_definition")))
    #expect((byLabel["guide"]?["status"]) == (.string("ok")))

    let noDefinitionsResult = try provider.callTool(
      .init(
        name: "markdown.link_check",
        arguments: .object([
          "path": .string("docs/README.md"),
          "include_reference_definitions": .bool(false),
          "max_links": .number(50),
        ]), context: .empty
      ))
    let noDefinitionsPayload = try decodeTextPayload(noDefinitionsResult)
    #expect((noDefinitionsPayload.objectValue?["check_count"]) == (.number(11)))
    #expect((noDefinitionsPayload.objectValue?["ok_count"]) == (.number(5)))
  }

  @Test
  func testMarkdownLinkCheckRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try Data([0xff, 0xfe]).write(to: directory.appendingPathComponent("bad.md"))
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["markdown.link_check"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    expectThrows(
      try provider.callTool(
        .init(
          name: "markdown.link_check",
          arguments: .object(["path": .string("../outside.md")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "markdown.link_check",
          arguments: .object(["path": .string("folder")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "markdown.link_check",
          arguments: .object([
            "path": .string("bad.md"),
            "max_bytes": .number(2),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("not valid UTF-8"))
    }
  }

  @Test
  func testJSONReadParsesProjectJSONIntoValue() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("config.json")
    try """
    {
      "name": "computer-mcp",
      "enabled": true,
      "retry_count": 3,
      "tags": ["gateway", "json"],
      "nested": {
        "threshold": 0.75
      }
    }
    """.write(to: file, atomically: true, encoding: .utf8)
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["json.read"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    let result = try provider.callTool(
      .init(
        name: "json.read",
        arguments: .object(["path": .string("config.json")]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let value = try #require(payload.objectValue?["value"]?.objectValue)

    #expect((payload.objectValue?["operation"]) == (.string("json.read")))
    #expect((payload.objectValue?["project_relative_path"]) == (.string("config.json")))
    #expect((try #require(payload.objectValue?["bytes_read"]?.numberValue)) > (0))
    #expect((value["name"]) == (.string("computer-mcp")))
    #expect((value["enabled"]) == (.bool(true)))
    #expect((value["retry_count"]) == (.number(3)))
    #expect((value["tags"]) == (.array([.string("gateway"), .string("json")])))
    #expect((value["nested"]?.objectValue?["threshold"]) == (.number(0.75)))
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testJSONReadRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try "{bad".write(
      to: directory.appendingPathComponent("bad.json"),
      atomically: true,
      encoding: .utf8
    )
    try "[1,2,3]".write(
      to: directory.appendingPathComponent("large.json"),
      atomically: true,
      encoding: .utf8
    )
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["json.read"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    expectThrows(
      try provider.callTool(
        .init(
          name: "json.read",
          arguments: .object(["path": .string("../outside.json")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "json.read",
          arguments: .object(["path": .string("folder")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "json.read",
          arguments: .object([
            "path": .string("large.json"),
            "max_bytes": .number(3),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("File exceeds max_bytes"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "json.read",
          arguments: .object(["path": .string("bad.json")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Unable to parse JSON"))
    }
  }

  @Test
  func testJSONLinesReadParsesBoundedRecordsAndErrors() throws {
    let directory = try temporaryDirectory()
    try """
    {"event":"ready","count":1}

    [1,2]
    not json
    {"event":"done"}
    """.write(
      to: directory.appendingPathComponent("events.jsonl"),
      atomically: true,
      encoding: .utf8
    )
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["jsonl.read"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    let result = try provider.callTool(
      .init(
        name: "jsonl.read",
        arguments: .object([
          "path": .string("events.jsonl"),
          "max_records": .number(2),
          "max_errors": .number(1),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let records = try #require(payload.objectValue?["records"]?.arrayValue)
    let errors = try #require(payload.objectValue?["errors"]?.arrayValue)

    #expect((payload.objectValue?["operation"]) == (.string("jsonl.read")))
    #expect((payload.objectValue?["project_relative_path"]) == (.string("events.jsonl")))
    #expect((payload.objectValue?["record_count"]) == (.number(3)))
    #expect((payload.objectValue?["returned_record_count"]) == (.number(2)))
    #expect((payload.objectValue?["record_count_truncated"]) == (.bool(true)))
    #expect((payload.objectValue?["error_count"]) == (.number(1)))
    #expect((payload.objectValue?["returned_error_count"]) == (.number(1)))
    #expect((payload.objectValue?["skipped_blank_line_count"]) == (.number(1)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
    #expect((records[0].objectValue?["line"]) == (.number(1)))
    #expect((records[0].objectValue?["value"]?.objectValue?["event"]) == (.string("ready")))
    #expect((records[0].objectValue?["value"]?.objectValue?["count"]) == (.number(1)))
    #expect((records[1].objectValue?["line"]) == (.number(3)))
    #expect((records[1].objectValue?["value"]) == (.array([.number(1), .number(2)])))
    #expect((errors.first?.objectValue?["line"]) == (.number(4)))
    #expect((errors.first?.objectValue?["raw_preview"]) == (.string("not json")))
  }

  @Test
  func testJSONLinesReadHandlesStartLineAndPartialWindow() throws {
    let directory = try temporaryDirectory()
    try """
    {"a":1}
    {"b":2}
    {"c":3}
    """.write(
      to: directory.appendingPathComponent("events.ndjson"),
      atomically: true,
      encoding: .utf8
    )
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["jsonl.read"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    let result = try provider.callTool(
      .init(
        name: "jsonl.read",
        arguments: .object([
          "path": .string("events.ndjson"),
          "start_line": .number(2),
          "max_bytes": .number(18),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let records = try #require(payload.objectValue?["records"]?.arrayValue)

    #expect((payload.objectValue?["content_truncated"]) == (.bool(true)))
    #expect((payload.objectValue?["last_line_may_be_partial"]) == (.bool(true)))
    #expect((payload.objectValue?["partial_line_dropped"]) == (.bool(true)))
    #expect((payload.objectValue?["record_count"]) == (.number(1)))
    #expect((payload.objectValue?["parse_incomplete"]) == (.bool(true)))
    #expect((records.first?.objectValue?["line"]) == (.number(2)))
    #expect((records.first?.objectValue?["value"]?.objectValue?["b"]) == (.number(2)))

    let partialResult = try provider.callTool(
      .init(
        name: "jsonl.read",
        arguments: .object([
          "path": .string("events.ndjson"),
          "max_bytes": .number(10),
          "include_partial_line": .bool(true),
        ]), context: .empty
      ))
    let partialPayload = try decodeTextPayload(partialResult)
    #expect((partialPayload.objectValue?["partial_line_dropped"]) == (.bool(false)))
    #expect((partialPayload.objectValue?["error_count"]) == (.number(1)))
  }

  @Test
  func testJSONLinesReadRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try Data([0xff, 0xfe]).write(to: directory.appendingPathComponent("bad.jsonl"))
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["jsonl.read"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    expectThrows(
      try provider.callTool(
        .init(
          name: "jsonl.read",
          arguments: .object(["path": .string("../outside.jsonl")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "jsonl.read",
          arguments: .object(["path": .string("folder")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "jsonl.read",
          arguments: .object(["path": .string("bad.jsonl")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("not valid UTF-8"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "jsonl.read",
          arguments: .object([
            "path": .string("bad.jsonl"),
            "max_records": .number(0),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_records"))
    }
  }

  @Test
  func testJSONWriteDryRunAndConfirmedWrite() throws {
    let directory = try temporaryDirectory()
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["json.write", "json.read"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    let dryRunResult = try provider.callTool(
      .init(
        name: "json.write",
        arguments: .object([
          "path": .string("config/out.json"),
          "create_directories": .bool(true),
          "preview_max_bytes": .number(128),
          "value": .object([
            "z": .number(1),
            "a": .array([.string("x")]),
          ]),
        ]), context: .empty
      ))
    let dryRunPayload = try decodeTextPayload(dryRunResult)
    let preview = try #require(
      dryRunPayload.objectValue?["preview"]?.objectValue?["content"]?
        .stringValue)

    #expect((dryRunPayload.objectValue?["operation"]) == (.string("json.write")))
    #expect((dryRunPayload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((dryRunPayload.objectValue?["written"]) == (.bool(false)))
    #expect((dryRunPayload.objectValue?["would_create"]) == (.bool(true)))
    let aKeyRange = try #require(preview.range(of: "\"a\""))
    let zKeyRange = try #require(preview.range(of: "\"z\""))
    #expect(aKeyRange.lowerBound < zKeyRange.lowerBound)
    #expect(
      !(FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("config/out.json").path)))

    expectThrows(
      try provider.callTool(
        .init(
          name: "json.write",
          arguments: .object([
            "path": .string("config/out.json"),
            "create_directories": .bool(true),
            "dry_run": .bool(false),
            "value": .object(["ok": .bool(true)]),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("confirm_write=true"))
    }

    let writeResult = try provider.callTool(
      .init(
        name: "json.write",
        arguments: .object([
          "path": .string("config/out.json"),
          "create_directories": .bool(true),
          "dry_run": .bool(false),
          "confirm_write": .bool(true),
          "value": .object([
            "z": .number(1),
            "a": .array([.string("x")]),
          ]),
        ]), context: .empty
      ))
    let writePayload = try decodeTextPayload(writeResult)

    #expect((writePayload.objectValue?["written"]) == (.bool(true)))
    #expect((try #require(writePayload.objectValue?["bytes_written"]?.numberValue)) > (0))
    #expect(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("config/out.json").path))

    let readResult = try provider.callTool(
      .init(
        name: "json.read",
        arguments: .object(["path": .string("config/out.json")]), context: .empty
      ))
    let readPayload = try decodeTextPayload(readResult)
    let value = try #require(readPayload.objectValue?["value"]?.objectValue)
    #expect((value["z"]) == (.number(1)))
    #expect((value["a"]) == (.array([.string("x")])))
  }

  @Test
  func testJSONWriteRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try "{}".write(
      to: directory.appendingPathComponent("existing.json"),
      atomically: true,
      encoding: .utf8
    )
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["json.write"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    expectThrows(
      try provider.callTool(
        .init(
          name: "json.write",
          arguments: .object([
            "path": .string("../outside.json"),
            "value": .object(["ok": .bool(true)]),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "json.write",
          arguments: .object([
            "path": .string("missing/out.json"),
            "value": .object(["ok": .bool(true)]),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Parent directory does not exist"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "json.write",
          arguments: .object([
            "path": .string("folder"),
            "value": .object(["ok": .bool(true)]),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Path is a directory"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "json.write",
          arguments: .object([
            "path": .string("existing.json"),
            "value": .object(["ok": .bool(true)]),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Refusing to overwrite"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "json.write",
          arguments: .object([
            "path": .string("too-large.json"),
            "max_bytes": .number(4),
            "value": .object(["large": .string("value")]),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Encoded JSON exceeds max_bytes"))
    }
  }

  @Test
  func testTOMLReadParsesProjectTOMLIntoValue() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("config.toml")
    try """
    name = "computer-mcp"
    enabled = true
    retry_count = 3
    threshold = 0.75
    tags = ["gateway", "toml"]
    release_date = 2026-07-07
    start_time = 09:30:15

    [nested]
    mode = "safe"
    """.write(to: file, atomically: true, encoding: .utf8)
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["toml.read"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    let result = try provider.callTool(
      .init(
        name: "toml.read",
        arguments: .object(["path": .string("config.toml")]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let value = try #require(payload.objectValue?["value"]?.objectValue)

    #expect((payload.objectValue?["operation"]) == (.string("toml.read")))
    #expect((payload.objectValue?["project_relative_path"]) == (.string("config.toml")))
    #expect((try #require(payload.objectValue?["bytes_read"]?.numberValue)) > (0))
    #expect((value["name"]) == (.string("computer-mcp")))
    #expect((value["enabled"]) == (.bool(true)))
    #expect((value["retry_count"]) == (.number(3)))
    #expect((value["threshold"]) == (.number(0.75)))
    #expect((value["tags"]) == (.array([.string("gateway"), .string("toml")])))
    #expect((value["nested"]?.objectValue?["mode"]) == (.string("safe")))
    #expect((value["release_date"]?.objectValue?["type"]) == (.string("local_date")))
    #expect((value["release_date"]?.objectValue?["value"]) == (.string("2026-07-07")))
    #expect((value["start_time"]?.objectValue?["type"]) == (.string("local_time")))
    #expect((value["start_time"]?.objectValue?["value"]) == (.string("09:30:15")))
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testTOMLReadRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try "name = ".write(
      to: directory.appendingPathComponent("bad.toml"),
      atomically: true,
      encoding: .utf8
    )
    try "name = \"abcd\"".write(
      to: directory.appendingPathComponent("large.toml"),
      atomically: true,
      encoding: .utf8
    )
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["toml.read"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    expectThrows(
      try provider.callTool(
        .init(
          name: "toml.read",
          arguments: .object(["path": .string("../outside.toml")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "toml.read",
          arguments: .object(["path": .string("folder")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "toml.read",
          arguments: .object([
            "path": .string("large.toml"),
            "max_bytes": .number(3),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("File exceeds max_bytes"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "toml.read",
          arguments: .object(["path": .string("bad.toml")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Unable to parse TOML"))
    }
  }

  @Test
  func testYAMLReadParsesProjectYAMLIntoDocuments() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("config.yaml")
    try """
    name: computer-mcp
    enabled: true
    retry_count: 3
    threshold: 0.75
    created_at: 2026-07-09T01:02:03Z
    tags:
      - gateway
      - yaml
    nested:
      mode: safe
    not_a_number: .nan
    ---
    items:
      - id: 1
        label: first
    """.write(to: file, atomically: true, encoding: .utf8)
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["yaml.read"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    let result = try provider.callTool(
      .init(
        name: "yaml.read",
        arguments: .object([
          "path": .string("config.yaml"),
          "max_documents": .number(10),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let documents = try #require(payload.objectValue?["documents"]?.arrayValue)
    let first = try #require(documents.first?.objectValue?["value"]?.objectValue)
    let second = try #require(documents.last?.objectValue?["value"]?.objectValue)
    let topLevel = try #require(payload.objectValue?["value"]?.arrayValue)

    #expect((payload.objectValue?["operation"]) == (.string("yaml.read")))
    #expect((payload.objectValue?["project_relative_path"]) == (.string("config.yaml")))
    #expect((try #require(payload.objectValue?["bytes_read"]?.numberValue)) > (0))
    #expect((payload.objectValue?["document_count"]) == (.number(2)))
    #expect((payload.objectValue?["returned_document_count"]) == (.number(2)))
    #expect((payload.objectValue?["document_count_truncated"]) == (.bool(false)))
    #expect((topLevel.count) == (2))
    #expect((first["name"]) == (.string("computer-mcp")))
    #expect((first["enabled"]) == (.bool(true)))
    #expect((first["retry_count"]) == (.number(3)))
    #expect((first["threshold"]) == (.number(0.75)))
    #expect((first["tags"]) == (.array([.string("gateway"), .string("yaml")])))
    #expect((first["nested"]?.objectValue?["mode"]) == (.string("safe")))
    #expect((first["created_at"]?.objectValue?["type"]) == (.string("date")))
    #expect((first["not_a_number"]?.objectValue?["type"]) == (.string("non_finite_number")))
    #expect((second["items"]?.arrayValue?.first?.objectValue?["label"]) == (.string("first")))
    #expect((payload.objectValue?["conversion"]?.objectValue?["date_count"]) == (.number(1)))
    #expect(
      (payload.objectValue?["conversion"]?.objectValue?["non_finite_number_count"]) == (.number(1)))
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testYAMLReadRejectsBadInputsAndTruncatesDocuments() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try "name: [unterminated".write(
      to: directory.appendingPathComponent("bad.yaml"),
      atomically: true,
      encoding: .utf8
    )
    try "name: abcd".write(
      to: directory.appendingPathComponent("large.yaml"),
      atomically: true,
      encoding: .utf8
    )
    try "first: true\n---\nsecond: true\n".write(
      to: directory.appendingPathComponent("multi.yaml"),
      atomically: true,
      encoding: .utf8
    )
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["yaml.read"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    let truncatedResult = try provider.callTool(
      .init(
        name: "yaml.read",
        arguments: .object([
          "path": .string("multi.yaml"),
          "max_documents": .number(1),
        ]), context: .empty
      ))
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    #expect((truncatedPayload.objectValue?["document_count"]) == (.number(2)))
    #expect((truncatedPayload.objectValue?["returned_document_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["document_count_truncated"]) == (.bool(true)))

    expectThrows(
      try provider.callTool(
        .init(
          name: "yaml.read",
          arguments: .object(["path": .string("../outside.yaml")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "yaml.read",
          arguments: .object(["path": .string("folder")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "yaml.read",
          arguments: .object([
            "path": .string("large.yaml"),
            "max_bytes": .number(3),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("File exceeds max_bytes"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "yaml.read",
          arguments: .object(["path": .string("bad.yaml")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Unable to parse YAML"))
    }
  }

  @Test
  func testXMLReadParsesProjectXMLIntoElementTree() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("config.xml")
    try """
    <?xml version="1.0" encoding="UTF-8"?>
    <root enabled="true">
      <item id="1">First</item>
      <item id="2"><name>Second</name><![CDATA[raw <cdata>]]></item>
    </root>
    """.write(to: file, atomically: true, encoding: .utf8)
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["xml.read"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    let result = try provider.callTool(
      .init(
        name: "xml.read",
        arguments: .object(["path": .string("config.xml")]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let root = try #require(payload.objectValue?["root"]?.objectValue)
    let children = try #require(root["children"]?.arrayValue)
    let firstItem = try #require(children.first?.objectValue)
    let secondItem = try #require(children.last?.objectValue)
    let nameNode = try #require(secondItem["children"]?.arrayValue?.first?.objectValue)

    #expect((payload.objectValue?["operation"]) == (.string("xml.read")))
    #expect((payload.objectValue?["project_relative_path"]) == (.string("config.xml")))
    #expect((try #require(payload.objectValue?["bytes_read"]?.numberValue)) > (0))
    #expect((payload.objectValue?["element_count"]) == (.number(4)))
    #expect((payload.objectValue?["returned_element_count"]) == (.number(4)))
    #expect((payload.objectValue?["truncated"]) == (.bool(false)))
    #expect((root["name"]) == (.string("root")))
    #expect((root["attributes"]?.objectValue?["enabled"]) == (.string("true")))
    #expect((root["child_count"]) == (.number(2)))
    #expect((root["returned_child_count"]) == (.number(2)))
    #expect((firstItem["name"]) == (.string("item")))
    #expect((firstItem["attributes"]?.objectValue?["id"]) == (.string("1")))
    #expect((firstItem["text"]) == (.string("First")))
    #expect((secondItem["text"]) == (.string("raw <cdata>")))
    #expect((nameNode["name"]) == (.string("name")))
    #expect((nameNode["text"]) == (.string("Second")))
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testXMLReadRejectsBadInputsAndTruncatesTree() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try "<root>".write(
      to: directory.appendingPathComponent("bad.xml"), atomically: true, encoding: .utf8)
    try "<root>abcd</root>".write(
      to: directory.appendingPathComponent("large.xml"), atomically: true, encoding: .utf8)
    try "<root><a/><b/></root>".write(
      to: directory.appendingPathComponent("many.xml"), atomically: true, encoding: .utf8)
    try "<root>abcdef</root>".write(
      to: directory.appendingPathComponent("text.xml"), atomically: true, encoding: .utf8)
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["xml.read"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    let truncatedResult = try provider.callTool(
      .init(
        name: "xml.read",
        arguments: .object([
          "path": .string("many.xml"),
          "max_nodes": .number(2),
        ]), context: .empty
      ))
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    let truncatedRoot = try #require(truncatedPayload.objectValue?["root"]?.objectValue)
    #expect((truncatedPayload.objectValue?["element_count"]) == (.number(3)))
    #expect((truncatedPayload.objectValue?["returned_element_count"]) == (.number(2)))
    #expect((truncatedPayload.objectValue?["node_count_truncated"]) == (.bool(true)))
    #expect((truncatedPayload.objectValue?["truncated"]) == (.bool(true)))
    #expect((truncatedRoot["child_count"]) == (.number(2)))
    #expect((truncatedRoot["returned_child_count"]) == (.number(1)))

    let textResult = try provider.callTool(
      .init(
        name: "xml.read",
        arguments: .object([
          "path": .string("text.xml"),
          "max_text_bytes": .number(3),
        ]), context: .empty
      ))
    let textPayload = try decodeTextPayload(textResult)
    let textRoot = try #require(textPayload.objectValue?["root"]?.objectValue)
    #expect((textRoot["text"]) == (.string("abc")))
    #expect((textRoot["text_truncated"]) == (.bool(true)))
    #expect((textPayload.objectValue?["text_truncated"]) == (.bool(true)))

    expectThrows(
      try provider.callTool(
        .init(
          name: "xml.read",
          arguments: .object(["path": .string("../outside.xml")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "xml.read",
          arguments: .object(["path": .string("folder")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "xml.read",
          arguments: .object([
            "path": .string("large.xml"),
            "max_bytes": .number(3),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("File exceeds max_bytes"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "xml.read",
          arguments: .object(["path": .string("bad.xml")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Unable to parse XML"))
    }
  }

  @Test
  func testPlistReadParsesProjectPropertyListIntoJSON() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("Info.plist")
    let plist: [String: Any] = [
      "CFBundleIdentifier": "com.example.tool",
      "Enabled": true,
      "RetryCount": 3,
      "Tags": ["alpha", "beta"],
      "Payload": Data([0xde, 0xad, 0xbe, 0xef]),
      "CreatedAt": Date(timeIntervalSince1970: 1_700_000_000),
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: plist,
      format: .xml,
      options: 0
    )
    try data.write(to: file)
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["plist.read"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    let result = try provider.callTool(
      .init(
        name: "plist.read",
        arguments: .object(["path": .string("Info.plist")]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let value = try #require(payload.objectValue?["value"]?.objectValue)

    #expect((payload.objectValue?["operation"]) == (.string("plist.read")))
    #expect((payload.objectValue?["project_relative_path"]) == (.string("Info.plist")))
    #expect((payload.objectValue?["format"]) == (.string("xml")))
    #expect((try #require(payload.objectValue?["bytes_read"]?.numberValue)) > (0))
    #expect((value["CFBundleIdentifier"]) == (.string("com.example.tool")))
    #expect((value["Enabled"]) == (.bool(true)))
    #expect((value["RetryCount"]) == (.number(3)))
    #expect((value["Tags"]) == (.array([.string("alpha"), .string("beta")])))
    #expect((value["Payload"]?.objectValue?["type"]) == (.string("data")))
    #expect((value["Payload"]?.objectValue?["base64"]) == (.string("3q2+7w==")))
    #expect((value["CreatedAt"]?.objectValue?["type"]) == (.string("date")))
    #expect((value["CreatedAt"]?.objectValue?["iso8601"]?.stringValue) != nil)
    #expect((payload.objectValue?["processes"]) == nil)
    #expect((payload.objectValue?["environment"]) == nil)
  }

  @Test
  func testPlistReadRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try "not plist".write(
      to: directory.appendingPathComponent("bad.plist"),
      atomically: true,
      encoding: .utf8
    )
    try "abcd".write(
      to: directory.appendingPathComponent("large.plist"),
      atomically: true,
      encoding: .utf8
    )
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["plist.read"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    expectThrows(
      try provider.callTool(
        .init(
          name: "plist.read",
          arguments: .object(["path": .string("../outside.plist")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "plist.read",
          arguments: .object(["path": .string("folder")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "plist.read",
          arguments: .object([
            "path": .string("large.plist"),
            "max_bytes": .number(3),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("File exceeds max_bytes"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "plist.read",
          arguments: .object(["path": .string("bad.plist")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Unable to parse property list"))
    }
  }

  @Test
  func testStructuredGetReadsExactPathsAcrossFormats() throws {
    let directory = try temporaryDirectory()
    let configDirectory = directory.appendingPathComponent("config")
    try FileManager.default.createDirectory(
      at: configDirectory,
      withIntermediateDirectories: true
    )
    try """
    {
      "scripts": {
        "test": "swift test",
        "matrix": [
          {"name": "unit"},
          {"name": "integration"}
        ]
      },
      "enabled": true
    }
    """.write(
      to: configDirectory.appendingPathComponent("package.json"),
      atomically: true,
      encoding: .utf8
    )
    try """
    ---
    jobs:
      build:
        steps:
          - name: Checkout
          - name: Test
    ---
    jobs:
      deploy:
        steps:
          - name: Ship
    """.write(
      to: configDirectory.appendingPathComponent("workflow.yaml"),
      atomically: true,
      encoding: .utf8
    )
    try """
    [server]
    name = "computer-mcp"
    ports = [8080, 9090]
    """.write(
      to: configDirectory.appendingPathComponent("settings.toml"),
      atomically: true,
      encoding: .utf8
    )
    let plist: [String: Any] = [
      "CFBundleIdentifier": "com.example.app",
      "Nested": [
        "Items": ["first", "second"]
      ],
    ]
    let plistData = try PropertyListSerialization.data(
      fromPropertyList: plist,
      format: .xml,
      options: 0
    )
    try plistData.write(to: configDirectory.appendingPathComponent("Info.plist"))
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["structured.get"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    let jsonResult = try provider.callTool(
      .init(
        name: "structured.get",
        arguments: .object([
          "path": .string("config/package.json"),
          "query_path": .array([
            .string("scripts"),
            .string("matrix"),
            .number(1),
            .string("name"),
          ]),
        ]), context: .empty
      ))
    let jsonPayload = try decodeTextPayload(jsonResult)
    #expect((jsonPayload.objectValue?["operation"]) == (.string("structured.get")))
    #expect((jsonPayload.objectValue?["format"]) == (.string("json")))
    #expect((jsonPayload.objectValue?["query_pointer"]) == (.string("/scripts/matrix/1/name")))
    #expect((jsonPayload.objectValue?["matched"]) == (.bool(true)))
    #expect((jsonPayload.objectValue?["value_kind"]) == (.string("string")))
    #expect((jsonPayload.objectValue?["value"]) == (.string("integration")))
    #expect((jsonPayload.objectValue?["failure"]?.objectValue) == nil)

    let yamlResult = try provider.callTool(
      .init(
        name: "structured.get",
        arguments: .object([
          "path": .string("config/workflow.yaml"),
          "query_path": .array([
            .number(1),
            .string("jobs"),
            .string("deploy"),
            .string("steps"),
            .number(0),
            .string("name"),
          ]),
        ]), context: .empty
      ))
    let yamlPayload = try decodeTextPayload(yamlResult)
    let yamlMetadata = try #require(yamlPayload.objectValue?["document_metadata"]?.objectValue)
    #expect((yamlPayload.objectValue?["format"]) == (.string("yaml")))
    #expect((yamlPayload.objectValue?["value"]) == (.string("Ship")))
    #expect((yamlMetadata["kind"]) == (.string("yaml")))
    #expect((yamlMetadata["document_count"]) == (.number(2)))

    let tomlResult = try provider.callTool(
      .init(
        name: "structured.get",
        arguments: .object([
          "path": .string("config/settings.toml"),
          "query_path": .array([
            .string("server"),
            .string("ports"),
            .number(0),
          ]),
        ]), context: .empty
      ))
    let tomlPayload = try decodeTextPayload(tomlResult)
    #expect((tomlPayload.objectValue?["format"]) == (.string("toml")))
    #expect((tomlPayload.objectValue?["value"]) == (.number(8080)))

    let plistResult = try provider.callTool(
      .init(
        name: "structured.get",
        arguments: .object([
          "path": .string("config/Info.plist"),
          "query_path": .array([
            .string("Nested"),
            .string("Items"),
            .number(1),
          ]),
        ]), context: .empty
      ))
    let plistPayload = try decodeTextPayload(plistResult)
    #expect((plistPayload.objectValue?["format"]) == (.string("plist")))
    #expect((plistPayload.objectValue?["value"]) == (.string("second")))

    let missingResult = try provider.callTool(
      .init(
        name: "structured.get",
        arguments: .object([
          "path": .string("config/package.json"),
          "query_path": .array([
            .string("scripts"),
            .string("missing"),
          ]),
        ]), context: .empty
      ))
    let missingPayload = try decodeTextPayload(missingResult)
    let failure = try #require(missingPayload.objectValue?["failure"]?.objectValue)
    #expect((missingPayload.objectValue?["matched"]) == (.bool(false)))
    #expect((missingPayload.objectValue?["value"]) == (.null))
    #expect((failure["reason"]) == (.string("missing_key")))
    #expect((failure["index"]) == (.number(1)))
    #expect((failure["actual_kind"]) == (.string("object")))
  }

  @Test
  func testStructuredGetRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try #"{"items":[1]}"#.write(
      to: directory.appendingPathComponent("data.json"),
      atomically: true,
      encoding: .utf8
    )
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["structured.get"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    expectThrows(
      try provider.callTool(
        .init(
          name: "structured.get",
          arguments: .object([
            "path": .string("../data.json"),
            "query_path": .array([]),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "structured.get",
          arguments: .object([
            "path": .string("folder"),
            "query_path": .array([]),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "structured.get",
          arguments: .object([
            "path": .string("data.json"),
            "query_path": .string("items"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("query_path must be an array"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "structured.get",
          arguments: .object([
            "path": .string("data.json"),
            "query_path": .array([.number(-1)]),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("zero or greater"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "structured.get",
          arguments: .object([
            "path": .string("data.json"),
            "format": .string("jsonpath"),
            "query_path": .array([]),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("format must be one of"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "structured.get",
          arguments: .object([
            "path": .string("data.json"),
            "query_path": .array([]),
            "max_bytes": .number(3),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("File exceeds max_bytes"))
    }
  }

  @Test
  func testPlistWriteDryRunAndConfirmedWrite() throws {
    let directory = try temporaryDirectory()
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["plist.write", "plist.read"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    let value: JSONValue = .object([
      "CFBundleIdentifier": .string("com.example.tool"),
      "Enabled": .bool(true),
      "RetryCount": .number(3),
      "Tags": .array([.string("alpha"), .string("beta")]),
      "Payload": .object([
        "type": .string("data"),
        "base64": .string("3q2+7w=="),
      ]),
      "CreatedAt": .object([
        "type": .string("date"),
        "iso8601": .string("2023-11-14T22:13:20Z"),
      ]),
    ])

    let dryRunResult = try provider.callTool(
      .init(
        name: "plist.write",
        arguments: .object([
          "path": .string("generated/Info.plist"),
          "create_directories": .bool(true),
          "preview_max_bytes": .number(512),
          "value": value,
        ]), context: .empty
      ))
    let dryRunPayload = try decodeTextPayload(dryRunResult)
    let preview = try #require(dryRunPayload.objectValue?["preview"]?.objectValue)

    #expect((dryRunPayload.objectValue?["operation"]) == (.string("plist.write")))
    #expect((dryRunPayload.objectValue?["format"]) == (.string("xml")))
    #expect((dryRunPayload.objectValue?["dry_run"]) == (.bool(true)))
    #expect((dryRunPayload.objectValue?["written"]) == (.bool(false)))
    #expect((dryRunPayload.objectValue?["would_create"]) == (.bool(true)))
    #expect((preview["encoding"]) == (.string("utf8")))
    #expect(preview["content"]?.stringValue?.contains("CFBundleIdentifier") == true)
    #expect(
      !(FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("generated/Info.plist").path)))

    expectThrows(
      try provider.callTool(
        .init(
          name: "plist.write",
          arguments: .object([
            "path": .string("generated/Info.plist"),
            "create_directories": .bool(true),
            "dry_run": .bool(false),
            "value": value,
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("confirm_write=true"))
    }

    let writeResult = try provider.callTool(
      .init(
        name: "plist.write",
        arguments: .object([
          "path": .string("generated/Info.plist"),
          "create_directories": .bool(true),
          "dry_run": .bool(false),
          "confirm_write": .bool(true),
          "value": value,
        ]), context: .empty
      ))
    let writePayload = try decodeTextPayload(writeResult)

    #expect((writePayload.objectValue?["written"]) == (.bool(true)))
    #expect((try #require(writePayload.objectValue?["bytes_written"]?.numberValue)) > (0))
    #expect(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("generated/Info.plist").path))

    let readResult = try provider.callTool(
      .init(
        name: "plist.read",
        arguments: .object(["path": .string("generated/Info.plist")]), context: .empty
      ))
    let readPayload = try decodeTextPayload(readResult)
    let readValue = try #require(readPayload.objectValue?["value"]?.objectValue)
    #expect((readValue["CFBundleIdentifier"]) == (.string("com.example.tool")))
    #expect((readValue["Enabled"]) == (.bool(true)))
    #expect((readValue["RetryCount"]) == (.number(3)))
    #expect((readValue["Payload"]?.objectValue?["type"]) == (.string("data")))
    #expect((readValue["Payload"]?.objectValue?["base64"]) == (.string("3q2+7w==")))
    #expect((readValue["CreatedAt"]?.objectValue?["type"]) == (.string("date")))
    #expect((readValue["CreatedAt"]?.objectValue?["iso8601"]?.stringValue) != nil)
  }

  @Test
  func testPlistWriteRejectsBadInputs() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try "old".write(
      to: directory.appendingPathComponent("existing.plist"),
      atomically: true,
      encoding: .utf8
    )
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["plist.write"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    expectThrows(
      try provider.callTool(
        .init(
          name: "plist.write",
          arguments: .object([
            "path": .string("../outside.plist"),
            "value": .object(["ok": .bool(true)]),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "plist.write",
          arguments: .object([
            "path": .string("missing/out.plist"),
            "value": .object(["ok": .bool(true)]),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Parent directory does not exist"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "plist.write",
          arguments: .object([
            "path": .string("folder"),
            "value": .object(["ok": .bool(true)]),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Path is a directory"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "plist.write",
          arguments: .object([
            "path": .string("existing.plist"),
            "value": .object(["ok": .bool(true)]),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Refusing to overwrite"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "plist.write",
          arguments: .object([
            "path": .string("bad.plist"),
            "format": .string("openstep"),
            "value": .object(["ok": .bool(true)]),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("format must be xml or binary"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "plist.write",
          arguments: .object([
            "path": .string("null.plist"),
            "value": .object(["bad": .null]),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("do not support null"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "plist.write",
          arguments: .object([
            "path": .string("bad-date.plist"),
            "value": .object([
              "CreatedAt": .object([
                "type": .string("date"),
                "iso8601": .string("not-a-date"),
              ])
            ]),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Invalid property list date"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "plist.write",
          arguments: .object([
            "path": .string("too-large.plist"),
            "max_bytes": .number(8),
            "value": .object(["large": .string("value")]),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Encoded property list exceeds max_bytes"))
    }
  }

  @Test
  func testCSVReadParsesDelimitedPreview() throws {
    let directory = try temporaryDirectory()
    let file = directory.appendingPathComponent("data.csv")
    try """
    name,note,count,extra
    Alpha,"hello, world",1,a
    Beta,"two
    lines",2,b
    Gamma,done,3,c
    """.write(to: file, atomically: true, encoding: .utf8)
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["csv.read"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    let result = try provider.callTool(
      .init(
        name: "csv.read",
        arguments: .object([
          "path": .string("data.csv"),
          "max_rows": .number(2),
          "max_columns": .number(3),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let headers = try #require(payload.objectValue?["headers"]?.arrayValue)
    let rows = try #require(payload.objectValue?["rows"]?.arrayValue)
    let firstCells = try #require(rows.first?.objectValue?["cells"]?.arrayValue)
    let secondCells = try #require(rows.last?.objectValue?["cells"]?.arrayValue)

    #expect((payload.objectValue?["operation"]) == (.string("csv.read")))
    #expect((payload.objectValue?["project_relative_path"]) == (.string("data.csv")))
    #expect((payload.objectValue?["delimiter"]) == (.string("comma")))
    #expect((payload.objectValue?["delimiter_source"]) == (.string("auto")))
    #expect((payload.objectValue?["has_header"]) == (.bool(true)))
    #expect((headers) == ([.string("name"), .string("note"), .string("count")]))
    #expect((payload.objectValue?["header_count"]) == (.number(3)))
    #expect((payload.objectValue?["returned_row_count"]) == (.number(2)))
    #expect((rows.first?.objectValue?["record_number"]) == (.number(2)))
    #expect((firstCells) == ([.string("Alpha"), .string("hello, world"), .string("1")]))
    #expect((secondCells) == ([.string("Beta"), .string("two\nlines"), .string("2")]))
    #expect((payload.objectValue?["row_count_truncated"]) == (.bool(true)))
    #expect((payload.objectValue?["column_count_truncated"]) == (.bool(true)))
    #expect((payload.objectValue?["parse_incomplete"]) == (.bool(false)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
  }

  @Test
  func testCSVReadSupportsTSVAndHeaderlessRows() throws {
    let directory = try temporaryDirectory()
    try "a\tb\n1\t2\n".write(
      to: directory.appendingPathComponent("data.tsv"),
      atomically: true,
      encoding: .utf8
    )
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["csv.read"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    let result = try provider.callTool(
      .init(
        name: "csv.read",
        arguments: .object([
          "path": .string("data.tsv"),
          "delimiter": .string("tab"),
          "has_header": .bool(false),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let rows = try #require(payload.objectValue?["rows"]?.arrayValue)

    #expect((payload.objectValue?["delimiter"]) == (.string("tab")))
    #expect((payload.objectValue?["delimiter_character"]) == (.string("\t")))
    #expect((payload.objectValue?["delimiter_source"]) == (.string("configured")))
    #expect((payload.objectValue?["headers"]) == (.array([])))
    #expect((payload.objectValue?["returned_row_count"]) == (.number(2)))
    #expect((rows.first?.objectValue?["record_number"]) == (.number(1)))
    #expect((rows.first?.objectValue?["cells"]?.arrayValue) == ([.string("a"), .string("b")]))
  }

  @Test
  func testCSVReadRejectsBadInputsAndReportsIncompleteWindows() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try Data([0xff, 0xfe]).write(to: directory.appendingPathComponent("invalid.csv"))
    try "a,\"unterminated".write(
      to: directory.appendingPathComponent("partial.csv"),
      atomically: true,
      encoding: .utf8
    )
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["csv.read"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    expectThrows(
      try provider.callTool(
        .init(
          name: "csv.read",
          arguments: .object(["path": .string("../outside.csv")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "csv.read",
          arguments: .object(["path": .string("folder")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "csv.read",
          arguments: .object([
            "path": .string("partial.csv"),
            "delimiter": .string("\n"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("delimiter must be"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "csv.read",
          arguments: .object([
            "path": .string("partial.csv"),
            "max_rows": .number(0),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_rows"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "csv.read",
          arguments: .object([
            "path": .string("partial.csv"),
            "max_columns": .number(0),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_columns"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "csv.read",
          arguments: .object(["path": .string("invalid.csv")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("not valid UTF-8"))
    }

    let truncatedResult = try provider.callTool(
      .init(
        name: "csv.read",
        arguments: .object([
          "path": .string("partial.csv"),
          "max_bytes": .number(6),
        ]), context: .empty
      ))
    let truncatedPayload = try decodeTextPayload(truncatedResult)

    #expect((truncatedPayload.objectValue?["content_truncated"]) == (.bool(true)))
    #expect((truncatedPayload.objectValue?["parse_incomplete"]) == (.bool(true)))
  }

  @Test
  func testSQLiteSchemaUsesReadonlyJSONCLIAndParsesEntries() throws {
    let directory = try temporaryDirectory()
    let database = directory.appendingPathComponent("app.db")
    try "not actually read by fake runner".write(to: database, atomically: true, encoding: .utf8)
    let runner = RecordingCommandRunner()
    let schemaJSON = """
      [
        {
          "type": "table",
          "name": "items",
          "tbl_name": "items",
          "sql": "CREATE TABLE items(id INTEGER, name TEXT)"
        },
        {
          "type": "index",
          "name": "idx_items_name",
          "tbl_name": "items",
          "sql": "CREATE INDEX idx_items_name ON items(name)"
        }
      ]
      """
    runner.outputs = [
      RecordingCommandRunner.Output(stdout: schemaJSON),
      RecordingCommandRunner.Output(
        stdout: """
          [
            {"type":"table","name":"items","tbl_name":"items","sql":null},
            {"type":"table","name":"more","tbl_name":"more","sql":null}
          ]
          """),
    ]
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["sqlite.schema"]),
          projectDirectory: directory
        ),
        commandRunner: runner, sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    let result = try provider.callTool(
      .init(
        name: "sqlite.schema",
        arguments: .object([
          "path": .string("app.db"),
          "max_entries": .number(10),
          "max_output_bytes": .number(4096),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let entries = try #require(payload.objectValue?["entries"]?.arrayValue)
    let firstCall = try #require(runner.calls.first)
    let firstSQL = try #require(firstCall.arguments.last)

    #expect((firstCall.executable) == ("sqlite3"))
    #expect(firstCall.timeoutMilliseconds == 10_000)
    #expect(firstCall.maxOutputBytes == 4096)
    #expect(
      (Array(firstCall.arguments.prefix(7)))
        == (["-init", "/dev/null", "-safe", "-batch", "-readonly", "-json", database.path]))
    #expect(firstSQL.contains("FROM sqlite_schema"))
    #expect(firstSQL.contains("type IN ('table', 'view', 'index', 'trigger')"))
    #expect(firstSQL.contains("name NOT LIKE 'sqlite_%'"))
    #expect(firstSQL.contains("LIMIT 11"))
    #expect((payload.objectValue?["operation"]) == (.string("sqlite.schema")))
    #expect(
      (payload.objectValue?["database"]?.objectValue?["project_relative_path"])
        == (.string("app.db")))
    #expect((payload.objectValue?["include_views"]) == (.bool(true)))
    #expect((payload.objectValue?["include_indexes"]) == (.bool(true)))
    #expect((payload.objectValue?["include_triggers"]) == (.bool(true)))
    #expect((payload.objectValue?["include_internal"]) == (.bool(false)))
    #expect((payload.objectValue?["include_sql"]) == (.bool(true)))
    #expect((payload.objectValue?["returned_count"]) == (.number(2)))
    #expect((payload.objectValue?["truncated"]) == (.bool(false)))
    #expect((entries.first?.objectValue?["name"]) == (.string("items")))
    #expect((entries.first?.objectValue?["type"]) == (.string("table")))
    #expect(
      (payload.objectValue?["result"]?.objectValue?["stdout_bytes"])
        == (.number(Double(schemaJSON.utf8.count))))

    let truncatedResult = try provider.callTool(
      .init(
        name: "sqlite.schema",
        arguments: .object([
          "path": .string("app.db"),
          "include_views": .bool(false),
          "include_indexes": .bool(false),
          "include_triggers": .bool(false),
          "include_sql": .bool(false),
          "max_entries": .number(1),
        ]), context: .empty
      ))
    let truncatedPayload = try decodeTextPayload(truncatedResult)
    let truncatedEntries = try #require(truncatedPayload.objectValue?["entries"]?.arrayValue)
    let secondSQL = try #require(runner.calls.last?.arguments.last)

    #expect(secondSQL.contains("type IN ('table')"))
    #expect(secondSQL.contains("NULL AS sql"))
    #expect(secondSQL.contains("LIMIT 2"))
    #expect((truncatedPayload.objectValue?["include_views"]) == (.bool(false)))
    #expect((truncatedPayload.objectValue?["include_indexes"]) == (.bool(false)))
    #expect((truncatedPayload.objectValue?["include_triggers"]) == (.bool(false)))
    #expect((truncatedPayload.objectValue?["include_sql"]) == (.bool(false)))
    #expect((truncatedPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((truncatedPayload.objectValue?["truncated"]) == (.bool(true)))
    #expect((truncatedEntries.count) == (1))
    #expect((truncatedEntries.first?.objectValue?["sql"]) == (.null))
  }

  @Test
  func testSQLiteSchemaRejectsBadInputsAndCommandFailures() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try "fake".write(
      to: directory.appendingPathComponent("app.db"), atomically: true, encoding: .utf8)
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["sqlite.schema"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    expectThrows(
      try provider.callTool(
        .init(
          name: "sqlite.schema",
          arguments: .object(["path": .string("../outside.db")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "sqlite.schema",
          arguments: .object(["path": .string("folder")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "sqlite.schema",
          arguments: .object([
            "path": .string("app.db"),
            "max_entries": .number(0),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("max_entries"))
    }

    let failingRunner = RecordingCommandRunner()
    failingRunner.exitCode = 1
    failingRunner.stderr = "file is not a database"
    let failingProvider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["sqlite.schema"]),
          projectDirectory: directory
        ),
        commandRunner: failingRunner, sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))
    expectThrows(
      try failingProvider.callTool(
        .init(
          name: "sqlite.schema",
          arguments: .object(["path": .string("app.db")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("sqlite.schema failed"))
      #expect(error.localizedDescription.contains("file is not a database"))
    }

    let truncatedRunner = RecordingCommandRunner()
    truncatedRunner.stdout = "[]"
    truncatedRunner.stdoutTruncated = true
    let truncatedProvider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["sqlite.schema"]),
          projectDirectory: directory
        ),
        commandRunner: truncatedRunner, sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))
    expectThrows(
      try truncatedProvider.callTool(
        .init(
          name: "sqlite.schema",
          arguments: .object(["path": .string("app.db")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("exceeded max_output_bytes"))
    }

    let badJSONRunner = RecordingCommandRunner()
    badJSONRunner.stdout = "{bad"
    let badJSONProvider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["sqlite.schema"]),
          projectDirectory: directory
        ),
        commandRunner: badJSONRunner, sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))
    expectThrows(
      try badJSONProvider.callTool(
        .init(
          name: "sqlite.schema",
          arguments: .object(["path": .string("app.db")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Unable to parse sqlite schema JSON"))
    }
  }

  @Test
  func testSQLiteQueryUsesReadonlyJSONCLIAndBoundsRows() throws {
    let directory = try temporaryDirectory()
    let database = directory.appendingPathComponent("app.db")
    try "not actually read by fake runner".write(to: database, atomically: true, encoding: .utf8)
    let runner = RecordingCommandRunner()
    runner.outputs = [
      RecordingCommandRunner.Output(
        stdout: """
          [
            {"id":1,"name":"alpha"},
            {"id":2,"name":"beta"},
            {"id":3,"name":"gamma"}
          ]
          """),
      RecordingCommandRunner.Output(stdout: #"[{"cid":0,"name":"id","type":"INTEGER"}]"#),
    ]
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["sqlite.query"]),
          projectDirectory: directory
        ),
        commandRunner: runner, sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    let result = try provider.callTool(
      .init(
        name: "sqlite.query",
        arguments: .object([
          "path": .string("app.db"),
          "query": .string("SELECT id, name FROM items ORDER BY id;"),
          "max_rows": .number(2),
          "max_output_bytes": .number(4096),
        ]), context: .empty
      ))
    let payload = try decodeTextPayload(result)
    let rows = try #require(payload.objectValue?["rows"]?.arrayValue)
    let firstCall = try #require(runner.calls.first)
    let firstSQL = try #require(firstCall.arguments.last)

    #expect((firstCall.executable) == ("sqlite3"))
    #expect(firstCall.timeoutMilliseconds == 10_000)
    #expect(firstCall.maxOutputBytes == 4096)
    #expect(
      (Array(firstCall.arguments.prefix(7)))
        == (["-init", "/dev/null", "-safe", "-batch", "-readonly", "-json", database.path]))
    #expect(firstSQL.contains("FROM ("))
    #expect(firstSQL.contains("SELECT id, name FROM items ORDER BY id"))
    #expect(firstSQL.contains("LIMIT 3"))
    #expect((payload.objectValue?["operation"]) == (.string("sqlite.query")))
    #expect((payload.objectValue?["query_kind"]) == (.string("select")))
    #expect((payload.objectValue?["returned_count"]) == (.number(2)))
    #expect((payload.objectValue?["truncated"]) == (.bool(true)))
    #expect((rows.count) == (2))
    #expect((rows.first?.objectValue?["name"]) == (.string("alpha")))

    let pragmaResult = try provider.callTool(
      .init(
        name: "sqlite.query",
        arguments: .object([
          "path": .string("app.db"),
          "query": .string("PRAGMA table_info(items);"),
          "max_rows": .number(10),
        ]), context: .empty
      ))
    let pragmaPayload = try decodeTextPayload(pragmaResult)
    let secondSQL = try #require(runner.calls.last?.arguments.last)

    #expect((secondSQL) == ("PRAGMA table_info(items)"))
    #expect((pragmaPayload.objectValue?["query_kind"]) == (.string("pragma")))
    #expect((pragmaPayload.objectValue?["returned_count"]) == (.number(1)))
    #expect((pragmaPayload.objectValue?["truncated"]) == (.bool(false)))
  }

  @Test
  func testSQLiteQueryRejectsUnsafeInputsAndCommandFailures() throws {
    let directory = try temporaryDirectory()
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder"),
      withIntermediateDirectories: true
    )
    try "fake".write(
      to: directory.appendingPathComponent("app.db"), atomically: true, encoding: .utf8)
    let provider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["sqlite.query"]),
          projectDirectory: directory
        ), sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))

    expectThrows(
      try provider.callTool(
        .init(
          name: "sqlite.query",
          arguments: .object([
            "path": .string("../outside.db"),
            "query": .string("SELECT 1"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("escapes project"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "sqlite.query",
          arguments: .object([
            "path": .string("folder"),
            "query": .string("SELECT 1"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Path is not a file"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "sqlite.query",
          arguments: .object([
            "path": .string("app.db"),
            "query": .string("UPDATE items SET name = 'x'"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("read-only"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "sqlite.query",
          arguments: .object([
            "path": .string("app.db"),
            "query": .string("SELECT 1; SELECT 2"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("one SQL statement"))
    }

    expectThrows(
      try provider.callTool(
        .init(
          name: "sqlite.query",
          arguments: .object([
            "path": .string("app.db"),
            "query": .string("PRAGMA user_version = 1"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("without assignment"))
    }

    let literalRunner = RecordingCommandRunner()
    literalRunner.stdout = #"[{"text":"drop table users"}]"#
    let literalProvider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["sqlite.query"]),
          projectDirectory: directory
        ),
        commandRunner: literalRunner, sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))
    _ = try literalProvider.callTool(
      .init(
        name: "sqlite.query",
        arguments: .object([
          "path": .string("app.db"),
          "query": .string("SELECT 'drop table users' AS text"),
        ]), context: .empty
      ))

    let failingRunner = RecordingCommandRunner()
    failingRunner.exitCode = 1
    failingRunner.stderr = "file is not a database"
    let failingProvider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["sqlite.query"]),
          projectDirectory: directory
        ),
        commandRunner: failingRunner, sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))
    expectThrows(
      try failingProvider.callTool(
        .init(
          name: "sqlite.query",
          arguments: .object([
            "path": .string("app.db"),
            "query": .string("SELECT 1"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("sqlite.query failed"))
      #expect(error.localizedDescription.contains("file is not a database"))
    }

    let truncatedRunner = RecordingCommandRunner()
    truncatedRunner.stdout = "[]"
    truncatedRunner.stdoutTruncated = true
    let truncatedProvider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["sqlite.query"]),
          projectDirectory: directory
        ),
        commandRunner: truncatedRunner, sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))
    expectThrows(
      try truncatedProvider.callTool(
        .init(
          name: "sqlite.query",
          arguments: .object([
            "path": .string("app.db"),
            "query": .string("SELECT 1"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("exceeded max_output_bytes"))
    }

    let badJSONRunner = RecordingCommandRunner()
    badJSONRunner.stdout = "{bad"
    let badJSONProvider = StructuredToolProvider(
      environment: ToolEnvironment(
        configuration: GatewayConfiguration(
          builtin: BuiltinConfig(enabled: ["sqlite.query"]),
          projectDirectory: directory
        ),
        commandRunner: badJSONRunner, sqliteCommand: .init(id: "sqlite3", executable: "sqlite3")))
    expectThrows(
      try badJSONProvider.callTool(
        .init(
          name: "sqlite.query",
          arguments: .object([
            "path": .string("app.db"),
            "query": .string("SELECT 1"),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("Unable to parse sqlite query JSON"))
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
