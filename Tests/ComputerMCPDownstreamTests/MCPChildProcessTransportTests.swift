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
  #if canImport(Darwin)
    @Test
    func writtenRequestIDIsSettledWhenDisconnectJoinsInput() async throws {
      let root = try ScopedTemporaryDirectory()
      let environment = ["PATH": "/usr/bin:/bin"]
      let transport = try MCPChildProcessTransport(
        launcher: testExecutionLauncher(),
        server: .init(id: "write-join", transport: .stdio, command: "/bin/cat"),
        workingDirectory: root.url, environment: environment,
        hostContext: HostEnvironmentProbe(root: root.url))
      let administration = ExecutionAdministration(
        mode: .fullAccess, environment: try .init(fullAccessVariables: environment))
      try await ExecutionAdministration.$current.withValue(administration) {
        try await transport.connect()
      }

      let call = MCPStdioCall()
      let frame = Data(#"{"jsonrpc":"2.0","id":"held-write","method":"tools/call"}"#.utf8)
      let parked = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
      let release = AsyncStream<Void>.makeStream()
      let send = Task {
        defer { parked.continuation.finish() }
        try await MCPStdioCall.$current.withValue(call) {
          try await transport.send(frame) {
            parked.continuation.yield(true)
            parked.continuation.finish()
            for await _ in release.stream {}
          }
        }
      }
      do {
        var checkpoint = parked.stream.makeAsyncIterator()
        try #require(await checkpoint.next() == true)
        var inbound = await transport.receive().makeAsyncIterator()
        #expect(try await inbound.next() == frame)
        await transport.disconnect()
        #expect(await transport.shutdownConfirmed())
        #expect(call.writtenRequestID == .string("held-write"))
      } catch {
        release.continuation.finish()
        await transport.disconnect()
        _ = await send.result
        throw error
      }
      release.continuation.finish()
      try await send.value
    }
  #endif

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
