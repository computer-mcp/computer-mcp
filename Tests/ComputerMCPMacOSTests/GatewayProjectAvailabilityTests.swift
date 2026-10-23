import ComputerMCPMacOS
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPGateway

@Suite(.timeLimit(.minutes(1)))
struct GatewayProjectAvailabilityTests {
  @Test(arguments: [GatewayCallerKind.localMCP, .secureTunnel])
  func inaccessibleFirstProjectDoesNotBlockHealthyProject(caller: GatewayCallerKind)
    async throws
  {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("healthy".utf8).write(to: root.appendingPathComponent("value.txt"))
    let gateway = try await makeGateway(root: root, caller: caller)
    let names = try gateway.listTools(context: .empty).map(\.name)
    #expect(names.contains("file.read"))
    let listed = try result(
      gateway.callTool(name: "project.list", arguments: .object([:]), context: .empty))
    let rows = try #require(listed.objectValue?["projects"]?.arrayValue)
    #expect(rows.count == 2)
    #expect(rows[0].objectValue?["access"]?.objectValue?["status"] == .string("unavailable"))
    #expect(rows[1].objectValue?["access"]?.objectValue?["status"] == .string("available"))
    let read = try result(
      gateway.callTool(
        name: "file.read",
        arguments: .object([
          "project_id": .string("healthy"), "path": .string("value.txt"),
        ]), context: .empty))
    #expect(read.objectValue?["content"] == .string("healthy"))
    await gateway.shutdown()
  }

  @Test(arguments: [false, true])
  func badProjectIsNotReplacedOrDisclosedWithoutGrant(grantMissing: Bool) async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("must not be read".utf8).write(to: root.appendingPathComponent("value.txt"))
    let gateway = try await makeGateway(root: root, grantMissing: grantMissing)
    do {
      _ = try gateway.callTool(
        name: "file.read",
        arguments: .object([
          "project_id": .string("missing"), "path": .string("value.txt"),
        ]), context: .empty)
      Issue.record("An inaccessible project cannot execute a file operation")
    } catch {
      #expect(
        GatewayRuntime.auditErrorCode(for: error)
          == (grantMissing ? "project.root_missing" : "policy.project_denied"))
      if !grantMissing { #expect(!error.localizedDescription.contains(root.path)) }
    }
    let listed = try result(
      gateway.callTool(name: "project.list", arguments: .object([:]), context: .empty))
    #expect(listed.objectValue?["projects"]?.arrayValue?.count == (grantMissing ? 2 : 1))
    #expect(throws: (any Error).self) {
      try gateway.callTool(
        name: "file.read", arguments: .object(["path": .string("value.txt")]), context: .empty)
    }
    await gateway.shutdown()
  }

  @Test
  func allInaccessibleProjectsStillExposeDiagnosticsAndRecoverOnReconnect() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let missing = root.appendingPathComponent("missing", isDirectory: true)
    let gateway = try await makeGateway(root: root, includeHealthy: false)
    #expect(
      Set(try gateway.listTools(context: .empty).map(\.name)) == [
        "project.list", "project.describe",
      ])
    let described = try result(
      gateway.callTool(
        name: "project.describe", arguments: .object(["project_id": .string("missing")]),
        context: .empty)
    )
    #expect(
      described.objectValue?["access"]?.objectValue?["error"]?.objectValue?["code"]
        == .string("project.root_missing"))
    #expect(throws: (any Error).self) {
      try gateway.callTool(
        name: "file.read", arguments: .object(["path": .string("value.txt")]), context: .empty)
    }
    await gateway.shutdown()
    try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
    try Data("restored".utf8).write(to: missing.appendingPathComponent("value.txt"))
    let restored = try await makeGateway(root: root, includeHealthy: false)
    let read = try result(
      restored.callTool(
        name: "file.read", arguments: .object(["path": .string("value.txt")]), context: .empty)
    )
    #expect(read.objectValue?["content"] == .string("restored"))
    await restored.shutdown()
  }

  @Test
  func unavailableProjectDoesNotHideDuplicateRegistration() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = RegisteredProject(
      id: "duplicate", displayName: "Duplicate",
      rootPath: root.appendingPathComponent("missing").path)
    await #expect(throws: GatewayRuntimeError.duplicateProjectID("duplicate")) {
      try await GatewayRuntime.make(
        configuration: GatewayConfiguration(projectDirectory: root),
        registeredProjects: [project, project], platform: MacOSPlatform.services,
        bundledPlugins: .load(directory: nil))
    }
  }

  @Test
  func derivedObserveCatalogUsesAnAccessibleProject() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let gateway = try await GatewayRuntime.make(
      configuration: GatewayConfiguration(
        runtime: .init(caller: .secureTunnel, profileID: .chatGPTObserve),
        builtin: .init(enabled: ["file.read"]), projectDirectory: root),
      registeredProjects: projects(root: root), platform: MacOSPlatform.services,
      bundledPlugins: .load(directory: nil))
    #expect(try gateway.listTools(context: .empty).contains { $0.name == "file.read" })
    await gateway.shutdown()
  }

  private func makeGateway(
    root: URL, caller: GatewayCallerKind = .secureTunnel, grantMissing: Bool = true,
    includeHealthy: Bool = true
  ) async throws -> GatewayRuntime {
    let projects = projects(root: root).filter { includeHealthy || $0.id == "missing" }
    return try await GatewayRuntime.make(
      configuration: GatewayConfiguration(
        runtime: .init(caller: caller, profileID: .chatGPTOperate),
        profiles: [
          .init(
            id: .chatGPTOperate,
            capabilities: ["project.list", "project.describe", "file.read"],
            projects: projects.filter { grantMissing || $0.id != "missing" }.map(\.id),
            allowedCallers: [caller])
        ],
        builtin: .init(enabled: ["file.read"]), projectDirectory: root),
      registeredProjects: projects, platform: MacOSPlatform.services,
      bundledPlugins: .load(directory: nil))
  }

  private func projects(root: URL) -> [RegisteredProject] {
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
