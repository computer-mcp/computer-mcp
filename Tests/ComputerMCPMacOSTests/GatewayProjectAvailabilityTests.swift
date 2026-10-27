import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPGateway

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

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
    let names = try await gateway.listToolsAsync(context: .empty).map(\.name)
    #expect(names.contains("file.read"))
    let listed = try result(
      await gateway.callToolAsync(name: "project.list", arguments: .object([:]), context: .empty))
    let rows = try #require(listed.objectValue?["projects"]?.arrayValue)
    #expect(rows.count == 2)
    for row in rows {
      #expect(row.objectValue?["caller_access"] == .string("read"))
      #expect(row.objectValue?["root_path"] == nil && row.objectValue?["access"] == nil)
    }
    for (id, status) in [("missing", "unavailable"), ("healthy", "available")] {
      let described = try result(
        await gateway.callToolAsync(
          name: "project.describe", arguments: .object(["project_id": .string(id)]), context: .empty
        ))
      #expect(described.objectValue?["access"]?.objectValue?["status"] == .string(status))
    }
    let read = try result(
      await gateway.callToolAsync(
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
      _ = try await gateway.callToolAsync(
        name: "file.read",
        arguments: .object([
          "project_id": .string("missing"), "path": .string("value.txt"),
        ]), context: .empty)
      Issue.record("An inaccessible project cannot execute a file operation")
    } catch {
      #expect(
        GatewayRuntime.auditErrorCode(for: error)
          == (grantMissing ? "project.root_missing" : "permission.required"),
        "Unexpected project access error: \(error)")
      if !grantMissing { #expect(!error.localizedDescription.contains(root.path)) }
    }
    let listed = try result(
      await gateway.callToolAsync(name: "project.list", arguments: .object([:]), context: .empty))
    let rows = try #require(listed.objectValue?["projects"]?.arrayValue)
    #expect(rows.count == 2)
    let missing = try #require(rows.first { $0.objectValue?["id"] == .string("missing") })
    #expect(
      missing.objectValue?["caller_access"] == .string(grantMissing ? "read" : "not_granted"))
    #expect(missing.objectValue?["root_path"] == nil && missing.objectValue?["access"] == nil)
    if !grantMissing {
      let described = try result(
        await gateway.callToolAsync(
          name: "project.describe", arguments: .object(["project_id": .string("missing")]),
          context: .empty))
      #expect(described.objectValue?["root_path"] == nil && described.objectValue?["access"] == nil)
    }
    await #expect(throws: (any Error).self) {
      try await gateway.callToolAsync(
        name: "file.read", arguments: .object(["path": .string("value.txt")]), context: .empty)
    }
    await gateway.shutdown()
  }

  @Test
  func unavailableProjectsKeepRequestableToolsAndRecoverOnReconnect() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let missing = root.appendingPathComponent("missing", isDirectory: true)
    let gateway = try await makeGateway(root: root, includeHealthy: false)
    let tools = try await gateway.listToolsAsync(context: .empty)
    let listed = Set(tools.map(\.name))
    #expect(
      listed.isSuperset(of: [
        "project.list", "project.describe", "policy.probe", "runtime.owners.list",
        "runtime.owners.call", "file.read", "computer.screenshot",
      ]))
    for tool in tools {
      #expect(tool.meta?.objectValue?["computer_mcp"]?.objectValue?["requirements"] != nil)
    }
    let described = try result(
      await gateway.callToolAsync(
        name: "project.describe", arguments: .object(["project_id": .string("missing")]),
        context: .empty)
    )
    #expect(
      described.objectValue?["access"]?.objectValue?["error"]?.objectValue?["code"]
        == .string("project.root_missing"))
    do {
      _ = try await gateway.callToolAsync(
        name: "file.read", arguments: .object(["path": .string("value.txt")]), context: .empty)
      Issue.record("A granted call cannot read an unavailable Project")
    } catch {
      #expect(GatewayRuntime.auditErrorCode(for: error) == "project.root_missing")
    }
    await gateway.shutdown()
    try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
    try Data("restored".utf8).write(to: missing.appendingPathComponent("value.txt"))
    let restored = try await makeGateway(root: root, includeHealthy: false)
    let read = try result(
      await restored.callToolAsync(
        name: "file.read", arguments: .object(["path": .string("value.txt")]), context: .empty)
    )
    #expect(read.objectValue?["content"] == .string("restored"))
    await restored.shutdown()
  }

  @Test
  func unavailableProjectDoesNotHideDuplicateRegistration() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = ComputerMCPCore.RegisteredProject(
      id: "duplicate", displayName: "Duplicate",
      rootPath: root.appendingPathComponent("missing").path)
    await #expect(throws: GatewayRuntimeError.duplicateProjectID("duplicate")) {
      try await GatewayRuntime.make(
        configuration: GatewayConfiguration(projectDirectory: root),
        registeredProjects: [project, project],
        platform: MacOSPlatform.services(launcher: testExecutionLauncher()),
        bundledPlugins: .load(directory: nil))
    }
  }

  @Test
  func derivedObserveCatalogUsesAnAccessibleProject() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let gateway = try await makeGateway(root: root, profileID: .chatGPTObserve)
    #expect(try await gateway.listToolsAsync(context: .empty).contains { $0.name == "file.read" })
    await gateway.shutdown()
  }

  @Test
  func unauthenticatedCallDoesNotDiscloseAnUnavailableProject() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let gateway = try await makeGateway(root: root, authenticated: false)
    do {
      _ = try await gateway.callToolAsync(
        name: "file.read",
        arguments: .object(["project_id": .string("missing"), "path": .string("value.txt")]),
        context: .empty)
      Issue.record("An unauthenticated call must not reach project access checks")
    } catch {
      #expect(error as? GatewayPermissionError == .unauthenticated)
      #expect(!error.localizedDescription.contains(root.path))
    }
    await gateway.shutdown()
  }

  private func makeGateway(
    root: URL, caller: GatewayCallerKind = .secureTunnel, grantMissing: Bool = true,
    includeHealthy: Bool = true, profileID: GatewayProfileID = .chatGPTOperate,
    authenticated: Bool = true
  ) async throws -> GatewayRuntime {
    let projects = projects(root: root).filter { includeHealthy || $0.id == "missing" }
    let profile = ProfileGrantConfig(
      id: profileID,
      permissions: fixturePermissions(
        Dictionary(
          uniqueKeysWithValues: projects.filter { grantMissing || $0.id != "missing" }.map {
            (Permission.project($0.id), PermissionState.granted(.read))
          })),
      allowedCallers: [caller])
    let configuration = GatewayConfiguration(
      runtime: .init(caller: caller, profileID: profileID), profiles: [profile],
      builtin: .init(enabled: ["file.read"]), projectDirectory: root)
    let database = try fixturePermissionDatabase(
      path: root.appendingPathComponent("availability-\(UUID().uuidString).sqlite").path)
    try database.bootstrapPermissionProfiles([profile.grant])
    for project in projects { try database.saveProject(project) }
    var platform = MacOSPlatform.services(launcher: testExecutionLauncher())
    platform.permissionPolicyReader = TestManagedPolicyReader()
    return try await GatewayRuntime.make(
      configuration: configuration,
      context: .init(
        caller: caller, profileID: profileID,
        trustedPrincipalID: authenticated ? "availability-fixture" : nil),
      database: database, registeredProjects: projects, platform: platform,
      bundledPlugins: .load(directory: nil))
  }

  private func projects(root: URL) -> [ComputerMCPCore.RegisteredProject] {
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
    return try ProjectPathResolver.canonicalProject(root)
  }

  private func result(_ envelope: JSONValue) throws -> JSONValue {
    try #require(envelope.objectValue?["structuredContent"]?.objectValue?["result"])
  }
}
