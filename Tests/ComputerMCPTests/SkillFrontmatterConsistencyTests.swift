import Foundation
import Testing

@testable import ComputerMCP

@Suite
final class SkillFrontmatterConsistencyTests {
  @Test
  func testFoldedAndLiteralDescriptionsAreConsistentAcrossSkillTools() throws {
    let temporaryDirectory = try ScopedTemporaryDirectory()
    let root = temporaryDirectory.url
    try writeSkill(
      root: root,
      directory: "folded-skill",
      content:
        """
        ---
        name: folded-skill
        description: >-
          Draft, revise, or review interaction copy
          while preserving the product voice.
        ---
        # Folded
        """
    )
    try writeSkill(
      root: root,
      directory: "literal-skill",
      content:
        """
        ---
        name: literal-skill
        description: |
          First line.
          Second line.
        ---
        # Literal
        """
    )
    let registry = registry(root: root)

    try assertDescriptionConsistency(
      registry: registry,
      name: "folded-skill",
      expected: "Draft, revise, or review interaction copy while preserving the product voice."
    )
    try assertDescriptionConsistency(
      registry: registry,
      name: "literal-skill",
      expected: "First line.\nSecond line."
    )
  }

  @Test
  func testMalformedFrontmatterIsReportedConsistently() throws {
    let temporaryDirectory = try ScopedTemporaryDirectory()
    let root = temporaryDirectory.url
    try writeSkill(
      root: root,
      directory: "malformed-skill",
      content:
        """
        ---
        name: malformed-skill
        description: [unterminated
        ---
        # Malformed
        """
    )
    let registry = registry(root: root)

    let list = try payload(registry.callTool(name: "skills.list", arguments: .object([:])))
    let listed = try #require(
      list.objectValue?["skills"]?.arrayValue?.first {
        $0.objectValue?["directory_name"] == .string("malformed-skill")
      }?.objectValue
    )
    #expect((listed["name"]) == (.string("malformed-skill")))
    #expect((listed["description"]) == (.null))

    let describe = try call(registry, tool: "skills.describe", name: "malformed-skill")
    #expect((describe.objectValue?["description"]) == (.null))

    let validate = try call(registry, tool: "skills.validate", name: "malformed-skill")
    let issueCodes = validate.objectValue?["issues"]?.arrayValue?.compactMap {
      $0.objectValue?["code"]?.stringValue
    }
    #expect((validate.objectValue?["valid"]) == (.bool(false)))
    #expect(issueCodes?.contains("invalid_frontmatter_yaml") == true)
    #expect((validate.objectValue?["frontmatter"]?.objectValue?["parse_error"]?.stringValue) != nil)

    let frontmatter = try call(registry, tool: "skills.frontmatter", name: "malformed-skill")
    #expect((frontmatter.objectValue?["found"]) == (.bool(true)))
    #expect((frontmatter.objectValue?["parsed"]) == (.bool(false)))
    #expect((frontmatter.objectValue?["value"]) == (.null))
    #expect((frontmatter.objectValue?["parse_error"]?.stringValue) != nil)
  }

  private func assertDescriptionConsistency(
    registry: GatewayToolRegistry,
    name: String,
    expected: String
  ) throws {
    let list = try payload(registry.callTool(name: "skills.list", arguments: .object([:])))
    let listed = try #require(
      list.objectValue?["skills"]?.arrayValue?.first {
        $0.objectValue?["name"] == .string(name)
      }?.objectValue
    )
    let describe = try call(registry, tool: "skills.describe", name: name)
    let validate = try call(registry, tool: "skills.validate", name: name)
    let frontmatter = try call(registry, tool: "skills.frontmatter", name: name)

    let descriptions = [
      listed["description"]?.stringValue,
      describe.objectValue?["description"]?.stringValue,
      validate.objectValue?["frontmatter"]?.objectValue?["description"]?.stringValue,
      frontmatter.objectValue?["value"]?.objectValue?["description"]?.stringValue,
    ]
    #expect((descriptions) == (Array(repeating: expected, count: 4)))
    #expect((validate.objectValue?["valid"]) == (.bool(true)))
    #expect((validate.objectValue?["frontmatter"]?.objectValue?["parse_error"]) == (.null))
    #expect((frontmatter.objectValue?["parsed"]) == (.bool(true)))
  }

  private func registry(root: URL) -> GatewayToolRegistry {
    GatewayToolRegistry(
      configuration: .fixture(
        skills: SkillsConfig(
          enabled: true,
          roots: [SkillRootConfig(id: "fixtures", path: root.path)]
        )
      )
    )
  }

  private func call(
    _ registry: GatewayToolRegistry,
    tool: String,
    name: String
  ) throws -> JSONValue {
    try payload(
      registry.callTool(
        name: tool,
        arguments: .object([
          "root_id": .string("fixtures"),
          "name": .string(name),
        ])
      )
    )
  }

  private func payload(_ value: JSONValue) throws -> JSONValue {
    let text = try #require(
      value.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue
    )
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
