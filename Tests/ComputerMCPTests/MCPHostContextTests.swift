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
  func scopedProxyRejectsUnsupportedHostEnvironmentBeforeLaunching() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = root.appendingPathComponent("ownership")
    let hostContext = NonGatewayHostEnvironment(
      launchMetadata: .init(
        runtimeID: UUID(), context: .init(caller: .localCLI, profileID: .chatGPTObserve),
        workspaceID: "fixture", rootURL: root, readOnly: true),
      workspaceRoot: root, processOwnershipRoot: storage)
    let client = MCPProxyClient()
    let scoped = client.makeScopedClient(
      workingDirectory: root, environment: [:], hostContext: hostContext)
    let marker = root.appendingPathComponent("launched")
    let server = MCPServerConfig(
      id: "unsupported-host", transport: .stdio, command: "/usr/bin/touch", args: [marker.path],
      hostServices: false)
    try await BlockingOperationExecutor(label: "unsupported-host-proxy-test").perform {
      #expect(
        throws: GatewayToolError.executionFailed(
          "Gateway MCP connections require a gateway host environment.")
      ) {
        try scoped.listTools(server: server, context: .empty)
      }
      let status = try scoped.connectionStatus(server: server, context: .empty)
      #expect(status.objectValue?["state"] == .string("not_started"))
    }
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(!FileManager.default.fileExists(atPath: storage.path))
    await scoped.shutdown()
    await client.shutdown()
  }

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

private struct NonGatewayHostEnvironment: MCPHostEnvironment {
  let launchMetadata: MCPHostLaunchMetadata
  let workspaceRoot: URL
  let processOwnershipRoot: URL?
  let pluginArtifacts: [String: PluginDirectoryIdentity] = [:]
  let providesHostServices = false

  func makeHostSession(server: MCPServerConfig) throws -> any MCPHostSessionHandle {
    throw GatewayToolError.executionFailed("Host services are unavailable.")
  }
}
