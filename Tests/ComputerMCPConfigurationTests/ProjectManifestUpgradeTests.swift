import ComputerMCPCore
import Foundation
import Testing

@testable import ComputerMCPConfiguration

struct ProjectManifestUpgradeTests {
  @Test(arguments: ["git.worktrees", "delivery.apply", "delivery.scopes.list"])
  func historicalBuiltinsTranslateOnlyDuringUpgrade(id: String) throws {
    let text = "schema_version=1\n[builtin]\nenabled=['system.info', '\(id)']\n"
    #expect(throws: ConfigurationError.self) { try GatewayConfiguration.load(text: text) }
    let result = try #require(try ProjectManifestUpgrade.upgraded(text))
    let configuration = try GatewayConfiguration.load(text: result.manifest)
    if id == "git.worktrees" {
      #expect(configuration.builtin.enabled == ["system.info", "git.worktree_list"])
      #expect(result.renamedBuiltinIDs == [id: "git.worktree_list"])
      #expect(result.removedBuiltinIDs.isEmpty)
    } else {
      #expect(configuration.builtin.enabled == ["system.info"])
      #expect(result.removedBuiltinIDs == [id])
      #expect(result.renamedBuiltinIDs.isEmpty)
    }
    #expect(try ProjectManifestUpgrade.upgraded(result.manifest) == nil)
  }

  @Test(
    arguments: [
      "[[workspaces]]\nid='x'\ndisplay_name='X'\npath='/tmp'",
      "[[profiles]]\nid='local-admin'\nworkspaces=[]",
      "[[profiles]]\nid='local-admin'\ncapabilities=['workspace.list']",
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
    }
  }

  @Test(
    arguments: [
      "[delivery]",
      "[[delivery.scopes]]\nid='notes'\nworkspace='source'",
      "[[delivery.scopes]]\nid='notes'\nproject='source'",
      "[builtin]\nenabled=['delivery.apply']",
      "[builtin]\nenabled=['delivery.scopes.list']",
    ], [false, true])
  func retiredDeliveryInputRequiresWorktreeReplacement(fragment: String, fromFile: Bool) throws {
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
      Issue.record("Retired delivery input was accepted")
    } catch {
      #expect(error.localizedDescription.contains("Delivery configuration and tools are retired"))
      #expect(error.localizedDescription.contains("git.worktree_add"))
      #expect(error.localizedDescription.contains("git.merge"))
    }
    if fragment.hasPrefix("[delivery") || fragment.hasPrefix("[[delivery") {
      #expect(throws: ConfigurationError.self) { try ProjectManifestUpgrade.upgraded(text) }
    }
  }

  @Test func retiredDeliveryCannotEnterThroughDirectDecoding() throws {
    #expect(throws: ConfigurationError.self) {
      try JSONDecoder().decode(
        GatewayConfiguration.self, from: Data(#"{"schema_version":1,"delivery":{}}"#.utf8))
    }
    let current = GatewayConfiguration()
    let encoded = try JSONEncoder().encode(current)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["delivery"] == nil)
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
    let upgraded = try #require(try ProjectManifestUpgrade.upgraded(text)?.manifest)
    #expect(upgraded.contains("workspace.id"))
    #expect(upgraded.contains("/tmp/workspace"))
    #expect(upgraded.contains("mcp.workspace.list"))
    #expect(upgraded.contains("project.list"))
    #expect(upgraded.contains("project-write-capable"))
    #expect(upgraded.contains("project-operations"))
    #expect(try ProjectManifestUpgrade.upgraded(upgraded) == nil)
    #expect(throws: ConfigurationError.self) {
      try ProjectManifestUpgrade.upgraded("workspaces=[]\nprojects=[]")
    }
  }

  @Test(
    arguments: [
      "'workspace-operations'", "'project-operations'", "'read-only'", "'local-full-access'",
      "''", "'unknown'", "false",
    ], [false, true])
  func legacyModeRequiresRemoval(value: String, fromFile: Bool) throws {
    let profile = "[[profiles]]\nid='fixture'\nallowed_callers=[]\nmode=\(value)\n"
    let text = "schema_version=1\n" + profile
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    func check(_ load: () throws -> Void) {
      do {
        try load()
        Issue.record("Accepted an obsolete mode field")
      } catch {
        let message = error.localizedDescription
        #expect(message.contains("profiles.mode is obsolete; remove it"))
        #expect(message.contains("full_access and the profile permission tables"))
        #expect(!message.contains("project-operations"))
      }
    }
    check { _ = try PermissionProfileManifest.decode(profile) }
    if fromFile {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let file = directory.appendingPathComponent("computer-mcp.toml")
      try text.write(to: file, atomically: true, encoding: .utf8)
      check { _ = try GatewayConfiguration.load(path: file.path) }
    } else {
      check { _ = try GatewayConfiguration.load(text: text) }
    }
  }
}
