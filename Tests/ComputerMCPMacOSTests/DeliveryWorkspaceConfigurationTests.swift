import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPGateway
import ComputerMCPMacOS
import ComputerMCPTestSupport
import Foundation
import Testing

struct DeliveryWorkspaceConfigurationTests {
  @Test
  func eachWorkspaceReceivesOnlyItsDeclaredScopes() async throws {
    let first = try ScopedTemporaryDirectory()
    let second = try ScopedTemporaryDirectory()
    let configuration = GatewayConfiguration(
      workspaces: [
        .init(id: "first", path: first.url.path), .init(id: "second", path: second.url.path),
      ],
      builtin: .init(enabled: ["delivery.scopes.list"]),
      delivery: .init(scopes: [
        .init(id: "first-notes", workspace: "first", paths: ["notes/**"], defaultBranch: "main"),
        .init(
          id: "second-exports", workspace: "second", paths: ["exports/**"], defaultBranch: "main"),
      ]))
    try configuration.validate()
    let runtime = try await GatewayRuntime.make(
      configuration: configuration,
      platform: MacOSPlatform.services, plugins: [], bundledPlugins: .load(directory: nil))
    do {
      for (workspace, scope) in [("first", "first-notes"), ("second", "second-exports")] {
        let response = try runtime.callTool(
          name: "delivery.scopes.list",
          arguments: .object(["workspace_id": .string(workspace)]), context: .empty)
        let scopes = try #require(
          response.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue?[
            "scopes"]?.arrayValue)
        #expect(scopes.count == 1)
        #expect(scopes.first?.objectValue?["id"] == .string(scope))
      }
      await runtime.shutdown()
    } catch {
      await runtime.shutdown()
      throw error
    }
  }
}
