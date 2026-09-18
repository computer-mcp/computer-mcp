import Foundation
import Testing

@testable import ComputerMCP

@Suite(.timeLimit(.minutes(1)))
struct GatewayHostRecoveryTests {
  @Test(arguments: [false, true])
  func hostCrashReapsOwnedDescendantsAndDoesNotReplayAnUnacknowledgedWrite(pauseCleanup: Bool)
    async throws
  {
    let receipt = try await runDriver(mode: pauseCleanup ? "driver-pending" : "driver")
    #expect(receipt.objectValue?["generations"] == .number(2))
    #expect(receipt.objectValue?["writes"] == .number(1))
    #expect(receipt.objectValue?["owned_processes_exited"] == .bool(true))
    #expect(receipt.objectValue?["consumed_ticket_rejected"] == .bool(true))
    #expect(receipt.objectValue?["pending_cleanup_blocked"] == .bool(pauseCleanup))
  }

  @Test(arguments: ["process-entry", "initialize", "catalog"], ["host", "native"])
  func startupCrashCannotPublishPartialCatalogOrOverlapGenerations(stage: String, failure: String)
    async throws
  {
    let receipt = try await runDriver(mode: "driver-startup", parameters: [stage, failure])
    #expect(receipt.objectValue?["stage"] == .string(stage))
    #expect(receipt.objectValue?["failure"] == .string(failure))
    #expect(receipt.objectValue?["generations"] == .number(2))
    #expect(receipt.objectValue?["writes"] == .number(0))
    #expect(receipt.objectValue?["initial_catalog_published"] == .bool(false))
    #expect(receipt.objectValue?["owned_processes_exited"] == .bool(true))
    #expect(receipt.objectValue?["receipts_remaining"] == .number(0))
  }

  private func runDriver(mode: String, parameters: [String] = []) async throws -> JSONValue {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = root.appendingPathComponent("workspace")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let fixture = try #require(
      Bundle.module.url(
        forResource: "mcp_host_crash", withExtension: "py", subdirectory: "Fixtures"))
    let configuration = GatewayConfiguration(
      runtime: .init(caller: .localCLI, profileID: .localAdmin),
      workspaces: [.init(id: "fixture", path: workspace.path)],
      // This standalone operator fixture tests crash recovery after a permitted write.
      profiles: [
        .init(
          id: .localAdmin, capabilities: ["*"], workspaces: ["fixture"],
          allowedCallers: [.localCLI], mode: .localFullAccess, confirmationPolicy: .never)
      ],
      mcp: .init(servers: [
        .init(
          id: "owned", transport: .stdio, command: "/usr/bin/python3",
          args: [fixture.path, "server", root.path], exposure: .reexport, prefix: "owned",
          allowedTools: ["inspect", "write"], requestTimeoutMs: 15_000,
          toolRisks: ["inspect": .readOnly, "write": .destructive])
      ]), workspaceDirectory: root)
    let manifest = root.appendingPathComponent("config.toml")
    try Data(configuration.exportedTOML().utf8).write(to: manifest)
    let executable = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent(".build/debug/computer-mcp")
    let result = try await BlockingOperationExecutor(label: "gateway-host-crash-test").perform {
      try ProcessCommandRunner().run(
        executable: "/usr/bin/python3",
        arguments: [
          fixture.path, mode, root.path, executable.path,
          manifest.path,
        ] + parameters,
        workingDirectory: root, environment: [:], timeoutMilliseconds: 45_000,
        maxOutputBytes: 1_048_576)
    }
    try #require(result.exitCode == 0, "\(result.stdout)\n\(result.stderr)")
    return try JSONDecoder().decode(JSONValue.self, from: Data(result.stdout.utf8))
  }
}
