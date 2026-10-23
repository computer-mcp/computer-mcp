import ComputerMCPCore
import Foundation
import Testing

@testable import ComputerMCPConfiguration

struct ProjectManifestUpgradeTests {
  @Test(
    arguments: [
      "[[workspaces]]\nid='x'\ndisplay_name='X'\npath='/tmp'",
      "[[profiles]]\nid='local-admin'\nworkspaces=[]",
      "[[profiles]]\nid='local-admin'\ncapabilities=['workspace.list']",
      "[[profiles]]\nid='local-admin'\nmode='workspace-operations'",
      "[builtin]\nenabled=['workspace.instructions']",
      "[runtime]\nworkspace_id='x'",
      "[[cli.commands]]\nid='x'\ncommand='/bin/true'\ncwd='workspace'",
    ], [false, true])
  func standaloneRejectsOldNamesWithReplacementGuidance(fragment: String, fromFile: Bool) throws {
    let text = "schema_version=1\n" + fragment
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
      if fromFile {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("computer-mcp.toml")
        try text.write(to: file, atomically: true, encoding: .utf8)
        _ = try GatewayConfiguration.load(path: file.path)
      } else {
        _ = try GatewayConfiguration.load(text: text)
      }
      Issue.record("Old configuration was accepted")
    } catch {
      #expect(error.localizedDescription.contains("projects instead of workspaces"))
      #expect(error.localizedDescription.contains("project-operations"))
    }
  }

  @Test func upgradePreservesOpaqueValuesAndRejectsConflicts() throws {
    let text = """
      schema_version=1
      [[workspaces]]
      id='workspace.id'
      display_name='workspace.list'
      path='/tmp/workspace'
      [[profiles]]
      id='local-admin'
      workspaces=['workspace.id']
      capabilities=['workspace.list', 'mcp.workspace.list']
      mode='workspace-operations'
      [[cli.commands]]
      id='x'
      command='/bin/echo'
      args=['workspace.list']
      cwd='workspace'
      risk='workspace-write-capable'
      """
    let upgraded = try #require(try ProjectManifestUpgrade.upgraded(text))
    #expect(upgraded.contains("workspace.id"))
    #expect(upgraded.contains("/tmp/workspace"))
    #expect(upgraded.contains("mcp.workspace.list"))
    #expect(upgraded.contains("project.list"))
    #expect(upgraded.contains("project-write-capable"))
    #expect(try ProjectManifestUpgrade.upgraded(upgraded) == nil)
    #expect(throws: ConfigurationError.self) {
      try ProjectManifestUpgrade.upgraded("workspaces=[]\nprojects=[]")
    }
  }
}
