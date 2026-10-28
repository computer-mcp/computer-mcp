import ComputerMCPPermissions
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPCore
@testable import ComputerMCPGateway

@Suite(.nativeIntegration, .serialized)
struct GatewayWorktreeLifecycleTests {
  @Test func forwardedLifecycleUsesTheSameSandboxAuthority() async throws {
    let fixture = try FixedHostFixture(fullAccess: false, lifecycle: true, callback: true)
    try await fixture.run { fixture in
      try await fixture.initializeRepository()
      let created = try await fixture.runtime.callHostTool(
        name: "git.worktree_add", arguments: ["name": .string("callback")],
        projectID: "fixture", origin: "lifecycle-callback", requestID: UUID().uuidString)
      try #require(created.objectValue?["isError"] != .bool(true), "\(created)")
      let branch = try #require(
        created.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue?["branch"]?
          .stringValue)
      let refused = try await fixture.runtime.callHostTool(
        name: "git.branch_delete", arguments: ["name": .string(branch), "force": .bool(true)],
        projectID: "fixture", origin: "lifecycle-callback", requestID: UUID().uuidString)
      #expect(refused.objectValue?["isError"] == .bool(true))
    }
  }

  @Test func lifecycleToolsFollowTheDerivedProjectAcrossGenerations() async throws {
    let fixture = try FixedHostFixture(fullAccess: false, lifecycle: true)
    try await fixture.run { fixture in
      try await fixture.initializeRepository()
      let generations = GatewayStandaloneGenerations(fixture.runtime)
      do {
        func call(_ name: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
          let result = try await generations.callToolForMCPAsync(
            name: name, arguments: .object(arguments), context: .empty)
          try #require(result.objectValue?["isError"] != .bool(true), "\(result)")
          return try #require(result.objectValue?["structuredContent"]?.objectValue?["result"])
        }
        let created = try await call("git.worktree_add", ["name": .string("remote")])
        let id = try #require(created.objectValue?["project_id"]?.stringValue)
        let branch = try #require(created.objectValue?["branch"]?.stringValue)
        let inventory = try await call("git.worktree_list", ["project_id": .string(id)])
        #expect(inventory.objectValue?["worktrees"]?.arrayValue?.count == 2)
        let refused = try await generations.callToolForMCPAsync(
          name: "git.branch_delete",
          arguments: .object([
            "project_id": .string("fixture"), "name": .string(branch),
            "force": .bool(true), "dry_run": .bool(false), "confirm_delete": .bool(true),
          ]), context: .empty)
        #expect(refused.objectValue?["isError"] == .bool(true))
        _ = try await call(
          "git.merge", ["project_id": .string("fixture"), "branch": .string(branch)])
        let removed = try await call("git.worktree_remove", ["project_id": .string(id)])
        #expect(removed.objectValue?["terminationWarnings"] == .array([]))
        let deleted = try await call(
          "git.branch_delete",
          [
            "project_id": .string("fixture"),
            "name": .string(branch), "dry_run": .bool(false), "confirm_delete": .bool(true),
          ])
        #expect(deleted.objectValue?["deleted"] == .bool(true))
        await generations.shutdown()
      } catch {
        await generations.shutdown()
        throw error
      }
    }
  }
}
