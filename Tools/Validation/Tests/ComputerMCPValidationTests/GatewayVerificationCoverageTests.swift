import Foundation
import Testing

@testable import ComputerMCPValidation

@Suite

final class GatewayProbeVerifyCoverageTests {
  @Test
  func testGeneratedLocalAdminMutableBuiltinCatalogMatchesValidationDomains() throws {
    let tools = try defaultLocalAdminTools()
    let domains = Set(["archive", "file", "git", "json", "plist", "workspace"])
    let mutableTools = tools.filter { tool in
      guard tool.annotations?.readOnlyHint == false,
        let domain = tool.name.split(separator: ".", maxSplits: 1).first.map(String.init)
      else {
        return false
      }
      return domains.contains(domain)
    }

    #expect(
      (Set(mutableTools.map(\.name)))
        == (Set([
          "archive.create",
          "archive.extract",
          "file.append",
          "file.chmod",
          "file.copy",
          "file.download",
          "file.insert_text",
          "file.mkdir",
          "file.move",
          "file.remove_xattr",
          "file.replace_lines",
          "file.replace_text",
          "file.symlink",
          "file.touch",
          "file.trash",
          "file.write",
          "file.write_files",
          "git.add",
          "git.branch_create",
          "git.branch_delete",
          "git.branch_rename",
          "git.branch_switch",
          "git.clean",
          "git.commit",
          "git.restore_worktree",
          "git.stash_push",
          "git.tag_create",
          "git.tag_delete",
          "git.unstage",
          "json.write",
          "plist.write",
          "workspace.open",
          "workspace.reveal",
        ])))
    #expect((mutableTools.count) == (33))
  }

  @Test
  func testEveryMutableBuiltinHasMachineReadableObjectSchemaAndRiskAnnotations() throws {
    let tools = try defaultLocalAdminTools()
    let domains = Set(["archive", "file", "git", "json", "plist", "workspace"])
    let mutableTools = tools.filter { tool in
      guard tool.annotations?.readOnlyHint == false,
        let domain = tool.name.split(separator: ".", maxSplits: 1).first.map(String.init)
      else {
        return false
      }
      return domains.contains(domain)
    }

    for tool in mutableTools {
      let comment = Comment(rawValue: tool.name)
      #expect((tool.inputSchema.objectValue?["type"]) == (.string("object")), comment)
      #expect((tool.inputSchema.objectValue?["properties"]?.objectValue) != nil, comment)
      #expect((tool.annotations?.destructiveHint) != nil, comment)
    }
  }

  private func defaultLocalAdminTools() throws -> [MCPTool] {
    let manifestURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("computer-mcp-local-admin-\(UUID().uuidString).toml")
    defer { try? FileManager.default.removeItem(at: manifestURL) }
    try ValidationDefaultManifest.write(to: manifestURL)
    return try ValidationToolInventoryContract.load(
      configurationURL: manifestURL,
      caller: .localMCP,
      profileID: .localAdmin
    ).tools.map(\.tool)
  }
}
