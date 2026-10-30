import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPProcess
import ComputerMCPSandbox
import ComputerMCPTestSupport
import Foundation
import MCP
import Testing

@testable import ComputerMCPDownstream

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.nativeIntegration, .timeLimit(.minutes(1)))
struct MCPChildProcessTransportTests {
  @Test
  func hostServicesRequireAProvidingEnvironmentBeforeLaunch() throws {
    let server = MCPServerConfig(
      id: "hosted", transport: .stdio, command: "/bin/sh", hostServices: true)
    #expect(
      throws: GatewayToolError.executionFailed(
        "The stdio registration requires scoped host services.")
    ) {
      try MCPChildProcessTransport(
        launcher: testExecutionLauncher(),
        server: server, workingDirectory: URL(fileURLWithPath: "/tmp"), environment: [:])
    }
  }

  /// Host services bind only to a prepared provider's verified channel; a registration
  /// without one is refused before ownership or a launch.
  @Test
  func hostServicesRequireAPreparedProviderExecution() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = HostEnvironmentProbe(root: root)
    #expect(
      throws: GatewayToolError.executionFailed(
        "Host services require a prepared provider execution.")
    ) {
      try MCPChildProcessTransport(
        launcher: testExecutionLauncher(),
        server: .init(id: "hosted", transport: .stdio, command: "/bin/sh", hostServices: true),
        workingDirectory: root, environment: [:], hostContext: environment)
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: try #require(environment.processOwnershipRoot).path))
  }
}

private struct HostEnvironmentProbe: MCPHostEnvironment {
  let projectRoot: URL
  let processOwnershipRoot: URL?
  let launchMetadata: MCPHostLaunchMetadata
  let pluginArtifacts: [String: PluginDirectoryIdentity] = [:]
  let providesHostServices = true

  init(root: URL) {
    projectRoot = root
    processOwnershipRoot = root.appendingPathComponent("ownership")
    launchMetadata = .init(
      runtimeID: UUID(), context: .init(caller: .localMCP, profileID: .localAdmin),
      projectID: "test", rootURL: root, readOnly: true)
  }
}
