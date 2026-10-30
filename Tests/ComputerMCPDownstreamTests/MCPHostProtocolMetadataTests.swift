import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPProcess
import ComputerMCPSandbox
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPDownstream

@Suite(.timeLimit(.minutes(1)))
struct MCPHostProtocolMetadataTests {
  @Test
  func transportRebuildsHostMetadataWithoutRegistrationEnvironment() async throws {
    let root = try ScopedTemporaryDirectory()
    let platform = MetadataTransportPlatform()
    let host = MetadataEnvironmentProbe(root: root.url)
    let selected = ["HOME": "/prepared/home", "TMPDIR": "/prepared/tmp", "PATH": "/prepared/bin"]
    let forged = [
      "HOME": "/forged", "TMPDIR": "/forged", "PATH": "/forged",
      "PLUGIN_SECRET": "forged", "COMPUTER_MCP_HOST_CONTEXT": "forged",
      "COMPUTER_MCP_HOST_FD": "9", "COMPUTER_MCP_HOST_READ_HANDLE": "17",
      "COMPUTER_MCP_HOST_WRITE_HANDLE": "18",
    ]
    let transport = try MCPChildProcessTransport(
      launcher: ExecutionLauncher(platform: platform),
      server: .init(
        id: "metadata", transport: .stdio, command: "/bin/sh", env: forged),
      workingDirectory: root.url, environment: forged, hostContext: host)
    let administration = ExecutionAdministration(
      mode: .fullAccess, environment: try ExecutionEnvironment(fullAccessVariables: selected))
    // This backend captures the command and rejects before executing any program.
    try await ExecutionAdministration.$current.withValue(administration) {
      try await transport.connect()
      do {
        for try await _ in await transport.receive() {}
        Issue.record("A recording-only backend unexpectedly launched a protocol process")
      } catch {}
      await transport.disconnect()
    }
    let command = try #require(platform.commands.first)
    #expect(platform.commands.count == 1)
    let context = try #require(command.environment[MCPHostLaunchMetadata.environmentKey])
    #expect(
      try JSONDecoder().decode(JSONValue.self, from: Data(context.utf8))
        == JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(host.launchMetadata)))
    var expected = selected
    expected[MCPHostLaunchMetadata.environmentKey] = context
    #expect(command.environment == expected)
    #expect(command.inheritedDescriptors[3] == nil)
  }
}

private final class MetadataTransportPlatform: ExecutionPlatform, @unchecked Sendable {
  private let lock = NSLock()
  private var observed: [ExecutionCommand] = []
  var commands: [ExecutionCommand] { lock.withLock { observed } }

  func start(
    _ command: ExecutionCommand, sandbox: SandboxConfiguration?, method: ExecutionLaunchMethod,
    input: Int32, output: Int32, error: Int32,
    bindOwnership: @Sendable (any ExecutionOwnership) -> Void
  ) async throws -> any ExecutionOwnership {
    lock.withLock { observed.append(command) }
    throw ExecutionEnvironmentError.launchFailed("Recording backend does not execute programs")
  }
}

private struct MetadataEnvironmentProbe: MCPHostEnvironment {
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
      projectID: "host-selected", rootURL: root, readOnly: true)
  }
}
