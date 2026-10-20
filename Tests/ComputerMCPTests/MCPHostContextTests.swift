import ComputerMCPDownstream
import Foundation
import Testing

@testable import ComputerMCP
@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPPlatform

@Suite
struct MCPHostContextTests {
  @Test
  func scopedProxyUsesHostStorageOverrideBeforeLaunching() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = root.appendingPathComponent("ownership")
    let owner = try MCPProcessOwnership.acquire(
      root: storage, workspace: root, registration: "owned")
    try owner.finish(confirmed: false)
    let context = MCPHostContext(
      runtimeID: UUID(), context: .init(caller: .localCLI, profileID: .chatGPTObserve),
      workspaceID: "fixture", rootURL: root, readOnly: true)
    let client = MCPProxyClient(processOwnershipRoot: storage)
    let scoped = client.makeScopedClient(
      workingDirectory: root, environment: [:], hostContext: context)
    let marker = root.appendingPathComponent("launched")
    let server = MCPServerConfig(
      id: "owned", transport: .stdio, command: "/usr/bin/touch", args: [marker.path])
    let message = try await BlockingOperationExecutor(label: "ownership-proxy-test").perform {
      do {
        _ = try scoped.listTools(server: server, context: .empty)
        return "unexpected success"
      } catch { return String(describing: error) }
    }
    #expect(message.contains("mcp.cleanup_failed"))
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    await scoped.shutdown()
    await client.shutdown()
  }

  @Test
  func transientDatabasesHaveIndependentProcessOwnership() throws {
    let first = try GatewayDatabase(inMemory: ())
    let second = try GatewayDatabase(inMemory: ())
    let root = try #require(first.mcpProcessOwnershipRoot)
    #expect(root == first.mcpProcessOwnershipRoot)
    #expect(root != second.mcpProcessOwnershipRoot)
    #expect(root != MCPProcessOwnership.defaultRoot)
  }

}
