import Foundation
import Testing

@testable import ComputerMCP

@Suite(.timeLimit(.minutes(1)))
struct GatewayWorkspaceAvailabilityTests {
  @Test(arguments: [GatewayCallerKind.localMCP, .secureTunnel])
  func inaccessibleFirstWorkspaceDoesNotBlockHealthyWorkspace(caller: GatewayCallerKind)
    async throws
  {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("healthy".utf8).write(to: root.appendingPathComponent("value.txt"))
    let gateway = try await makeGateway(root: root, caller: caller)
    let names = try gateway.listTools().map(\.name)
    #expect(names.contains("file.read"))
    let listed = try result(gateway.callTool(name: "workspace.list", arguments: .object([:])))
    let rows = try #require(listed.objectValue?["workspaces"]?.arrayValue)
    #expect(rows.count == 2)
    #expect(rows[0].objectValue?["access"]?.objectValue?["status"] == .string("unavailable"))
    #expect(rows[1].objectValue?["access"]?.objectValue?["status"] == .string("available"))
    let read = try result(
      gateway.callTool(
        name: "file.read",
        arguments: .object([
          "workspace_id": .string("healthy"), "path": .string("value.txt"),
        ])))
    #expect(read.objectValue?["content"] == .string("healthy"))
    await gateway.shutdown()
  }

  @Test(arguments: [false, true])
  func badWorkspaceIsNotReplacedOrDisclosedWithoutGrant(grantMissing: Bool) async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("must not be read".utf8).write(to: root.appendingPathComponent("value.txt"))
    let gateway = try await makeGateway(root: root, grantMissing: grantMissing)
    do {
      _ = try gateway.callTool(
        name: "file.read",
        arguments: .object([
          "workspace_id": .string("missing"), "path": .string("value.txt"),
        ]))
      Issue.record("An inaccessible workspace cannot execute a file operation")
    } catch {
      #expect(
        GatewayRuntime.auditErrorCode(for: error)
          == (grantMissing ? "workspace.root_missing" : "policy.workspace_denied"))
      if !grantMissing { #expect(!error.localizedDescription.contains(root.path)) }
    }
    let listed = try result(gateway.callTool(name: "workspace.list", arguments: .object([:])))
    #expect(listed.objectValue?["workspaces"]?.arrayValue?.count == (grantMissing ? 2 : 1))
    #expect(throws: (any Error).self) {
      try gateway.callTool(name: "file.read", arguments: .object(["path": .string("value.txt")]))
    }
    await gateway.shutdown()
  }

  @Test
  func allInaccessibleWorkspacesStillExposeDiagnosticsAndRecoverOnReconnect() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let missing = root.appendingPathComponent("missing", isDirectory: true)
    let gateway = try await makeGateway(root: root, includeHealthy: false)
    #expect(Set(try gateway.listTools().map(\.name)) == ["workspace.list", "workspace.describe"])
    let described = try result(
      gateway.callTool(
        name: "workspace.describe", arguments: .object(["workspace_id": .string("missing")]))
    )
    #expect(
      described.objectValue?["access"]?.objectValue?["error"]?.objectValue?["code"]
        == .string("workspace.root_missing"))
    #expect(throws: (any Error).self) {
      try gateway.callTool(name: "file.read", arguments: .object(["path": .string("value.txt")]))
    }
    await gateway.shutdown()
    try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
    try Data("restored".utf8).write(to: missing.appendingPathComponent("value.txt"))
    let restored = try await makeGateway(root: root, includeHealthy: false)
    let read = try result(
      restored.callTool(name: "file.read", arguments: .object(["path": .string("value.txt")]))
    )
    #expect(read.objectValue?["content"] == .string("restored"))
    await restored.shutdown()
  }

  @Test
  func unavailableWorkspaceDoesNotHideDuplicateRegistration() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = RegisteredWorkspace(
      id: "duplicate", displayName: "Duplicate",
      rootPath: root.appendingPathComponent("missing").path)
    await #expect(throws: GatewayRuntimeError.duplicateWorkspaceID("duplicate")) {
      try await GatewayRuntime.make(
        configuration: GatewayConfiguration(workspaceDirectory: root),
        registeredWorkspaces: [workspace, workspace], bundledPlugins: .load(directory: nil))
    }
  }

  @Test
  func derivedObserveCatalogUsesAnAccessibleWorkspace() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let gateway = try await GatewayRuntime.make(
      configuration: GatewayConfiguration(
        runtime: .init(caller: .secureTunnel, profileID: .chatGPTObserve),
        builtin: .init(enabled: ["file.read"]), workspaceDirectory: root),
      registeredWorkspaces: workspaces(root: root), bundledPlugins: .load(directory: nil))
    #expect(try gateway.listTools().contains { $0.name == "file.read" })
    await gateway.shutdown()
  }

  private func makeGateway(
    root: URL, caller: GatewayCallerKind = .secureTunnel, grantMissing: Bool = true,
    includeHealthy: Bool = true
  ) async throws -> GatewayRuntime {
    let workspaces = workspaces(root: root).filter { includeHealthy || $0.id == "missing" }
    return try await GatewayRuntime.make(
      configuration: GatewayConfiguration(
        runtime: .init(caller: caller, profileID: .chatGPTOperate),
        profiles: [
          .init(
            id: .chatGPTOperate,
            capabilities: ["workspace.list", "workspace.describe", "file.read"],
            workspaces: workspaces.filter { grantMissing || $0.id != "missing" }.map(\.id),
            allowedCallers: [caller])
        ],
        builtin: .init(enabled: ["file.read"]), workspaceDirectory: root),
      registeredWorkspaces: workspaces, bundledPlugins: .load(directory: nil))
  }

  private func workspaces(root: URL) -> [RegisteredWorkspace] {
    [
      .init(
        id: "missing", displayName: "Missing", rootPath: root.appendingPathComponent("missing").path
      ),
      .init(id: "healthy", displayName: "Healthy", rootPath: root.path),
    ]
  }

  private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func result(_ envelope: JSONValue) throws -> JSONValue {
    try #require(envelope.objectValue?["structuredContent"]?.objectValue?["result"])
  }
}
