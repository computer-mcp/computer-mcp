import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPProcess
import ComputerMCPTestSupport
import Foundation
import MCP
import Testing

@testable import ComputerMCPDownstream

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
        server: server, workingDirectory: URL(fileURLWithPath: "/tmp"), environment: [:])
    }
  }

  @Test(arguments: [false, true])
  func suppliedSessionOwnsCleanupAndConfirmation(confirmed: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = SessionProbe(confirmed: confirmed)
    let environment = HostEnvironmentProbe(root: root, session: session)
    let transport = try MCPChildProcessTransport(
      server: .init(
        id: "hosted", transport: .stdio, command: "/bin/sh",
        args: ["-c", #"printf '%s\n' "$COMPUTER_MCP_HOST_FD""#],
        env: [MCPHostLaunchMetadata.descriptorEnvironmentKey: "9"], hostServices: true),
      workingDirectory: root, environment: [:], hostContext: environment)
    try await transport.connect()
    var lines: [String] = []
    var streamError: (any Error)?
    do {
      for try await data in await transport.receive() {
        lines.append(String(decoding: data, as: UTF8.self))
      }
    } catch { streamError = error }
    await transport.disconnect()
    #expect(await session.closed)
    #expect(await transport.shutdownConfirmed() == confirmed)
    #if os(Linux)
      #expect(lines.isEmpty)
      #expect(streamError is ManagedLineProcessError)
    #else
      #expect(lines == ["3"])
    #endif
    let receipts = try MCPProcessOwnership.inspect(
      root: try #require(environment.processOwnershipRoot), workspace: root, registration: "hosted")
    if confirmed {
      #expect(receipts.isEmpty)
    } else {
      #expect(receipts.count == 1)
      #expect(receipts.first?.state == "host_cleanup_unconfirmed")
      #expect(receipts.first?.blocksLaunch == true)
    }
  }
}

private struct HostEnvironmentProbe: MCPHostEnvironment {
  let workspaceRoot: URL
  let processOwnershipRoot: URL?
  let launchMetadata: MCPHostLaunchMetadata
  let pluginArtifacts: [String: PluginDirectoryIdentity] = [:]
  let providesHostServices = true
  let session: SessionProbe

  init(root: URL, session: SessionProbe) {
    workspaceRoot = root
    processOwnershipRoot = root.appendingPathComponent("ownership")
    launchMetadata = .init(
      runtimeID: UUID(), context: .init(caller: .localMCP, profileID: .localAdmin),
      workspaceID: "test", rootURL: root, readOnly: true)
    self.session = session
  }

  func makeHostSession(server: MCPServerConfig) throws -> any MCPHostSessionHandle {
    #expect(server.id == "hosted")
    return session
  }
}

private actor SessionProbe: MCPHostSessionHandle {
  nonisolated let childHandle: FileHandle
  private let pipe = Pipe()
  private let confirmed: Bool
  private(set) var closed = false

  init(confirmed: Bool) {
    childHandle = pipe.fileHandleForWriting
    self.confirmed = confirmed
  }

  func close() async {
    try? childHandle.close()
    try? pipe.fileHandleForReading.close()
    closed = true
  }

  func shutdownConfirmed() async -> Bool { closed && confirmed }
}
