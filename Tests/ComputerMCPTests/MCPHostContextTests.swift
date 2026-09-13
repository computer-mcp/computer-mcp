import Foundation
import Testing

@testable import ComputerMCP

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
        _ = try scoped.listTools(server: server)
        return "unexpected success"
      } catch { return String(describing: error) }
    }
    #expect(message.contains("mcp.cleanup_failed"))
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    await scoped.shutdown()
    await client.shutdown()
  }

  @Test
  func trustedContextReplacesInheritedAndRegistrationValues() throws {
    let context = MCPHostContext(
      runtimeID: UUID(), context: .init(caller: .localCLI, profileID: .localAdmin),
      workspaceID: "project", rootURL: URL(fileURLWithPath: "/tmp"), readOnly: false,
      processOwnershipRoot: URL(fileURLWithPath: "/private/host-ownership"))
    let environment = try MCPHostContext.launchEnvironment(
      inherited: [MCPHostContext.environmentKey: "ancestor", "KEEP": "inherited"],
      overrides: [MCPHostContext.environmentKey: "registration", "EMPTY": ""], context: context)
    let value = try JSONDecoder().decode(
      JSONValue.self, from: Data(try #require(environment[MCPHostContext.environmentKey]).utf8))
    #expect(value.objectValue?["caller"] == .string("local-cli"))
    #expect(value.objectValue?["runtimeID"] == .string(context.runtimeID.uuidString))
    #expect(environment["KEEP"] == "inherited")
    #expect(environment["EMPTY"] == "")
    #expect(value.objectValue?["processOwnershipRoot"] == nil)
  }

  @Test
  func excessiveProvenanceFailsBeforeLaunch() {
    let context = MCPHostContext(
      runtimeID: UUID(),
      context: .init(
        caller: .localMCP, profileID: .localAdmin,
        transportTrace: .init(transport: String(repeating: "x", count: 16_384))),
      workspaceID: "project", rootURL: URL(fileURLWithPath: "/tmp"), readOnly: false)
    #expect(throws: (any Error).self) {
      try MCPHostContext.launchEnvironment(inherited: [:], overrides: [:], context: context)
    }
  }
}
