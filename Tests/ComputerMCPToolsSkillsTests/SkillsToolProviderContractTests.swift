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

struct SkillsToolProviderContractTests {
  @Test
  func testSkillsToolCountMatchesTheFullCatalog() throws {
    let skills = try SkillsToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(), configuration: .fixture(skills: .init(enabled: true)))
    )
    .definitions()
    #expect(!skills.isEmpty)
    #expect(SkillsToolProvider.toolCount == skills.count)
  }

  @Test
  func rejectsNamesOutsideItsDomain() throws {
    let provider = SkillsToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: .fixture(
          builtin: .init(enabled: ["json.read"]), skills: .init(enabled: true))))
    #expect(provider.id == "skills")
    #expect(throws: GatewayToolError.unknownTool("json.read")) {
      try provider.callTool(.init(name: "json.read", arguments: nil, context: .empty))
    }
  }

  @Test
  func listsToolsInCatalogOrder() throws {
    let provider = SkillsToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(), configuration: .fixture(skills: .init(enabled: true))))
    #expect(
      try provider.definitions().map(\.tool.name) == [
        "skills.roots", "skills.list", "skills.describe", "skills.validate", "skills.frontmatter",
        "skills.read", "skills.files", "skills.read_file", "skills.read_files",
        "skills.read_package", "skills.outline", "skills.section", "skills.tables",
        "skills.links", "skills.link_check", "skills.search", "skills.search_files",
      ])
  }

  @Test
  func asynchronousFrontmatterUsesSharedParsingOutsideProject() async throws {
    let root = try ScopedTemporaryDirectory()
    let project = try ScopedTemporaryDirectory()
    let skill = root.url.appendingPathComponent("example")
    try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
    try """
    ---
    name: example
    description: Shared parsing fixture.
    count: 9007199254740993
    ---
    # Example
    """.write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    let provider = SkillsToolProvider(
      environment: ToolEnvironment(
        launcher: testExecutionLauncher(),
        configuration: GatewayConfiguration(
          skills: .init(enabled: true, roots: [.init(id: "fixture", path: root.url.path)]),
          projectDirectory: project.url)))
    let invocation = ToolInvocation(
      name: "skills.frontmatter",
      arguments: .object(["root_id": .string("fixture"), "name": .string("example")]),
      context: .empty)
    let response = try await provider.callToolAsync(invocation)
    #expect(response == (try provider.callTool(invocation)))
    let text = try #require(
      response.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    #expect(payload.objectValue?["parsed"] == .bool(true))
    #expect(payload.objectValue?["value"]?.objectValue?["count"] == .integer(9_007_199_254_740_993))
  }
}
