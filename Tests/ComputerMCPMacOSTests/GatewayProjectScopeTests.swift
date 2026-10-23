import ComputerMCPMacOS
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPCore
@testable import ComputerMCPGateway
@testable import ComputerMCPPlatformDarwin

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.timeLimit(.minutes(1)))
struct GatewayProjectScopeTests {
  @Test(
    arguments: ["replacement", "symlink", "missing", "file", "denied", "unresolved", "redirected"],
    [false, true])
  func currentAccessIsCheckedBeforeDispatch(change: String, persisted: Bool) async throws {
    let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let root = container.appendingPathComponent("project")
    let moved = container.appendingPathComponent("original")
    let other = container.appendingPathComponent("other")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: container) }
    try Data("original".utf8).write(to: root.appendingPathComponent("value.txt"))
    try Data("other".utf8).write(to: other.appendingPathComponent("value.txt"))
    let adapter = MutableScopeBookmarkAdapter(root: root)
    let database = try GatewayDatabase(path: container.appendingPathComponent("state.sqlite").path)
    let project = RegisteredProject(
      id: "project", displayName: "Project", rootPath: root.path,
      bookmarkData: Data("original".utf8))
    try database.saveProject(project)
    let runtime = try await GatewayRuntime.make(
      configuration: GatewayConfiguration(
        builtin: .init(enabled: ["file.read"]), projectDirectory: root),
      database: persisted ? database : nil, registeredProjects: persisted ? nil : [project],
      platform: PlatformServices(
        launcher: testExecutionLauncher(),
        projectGrants: ProjectBookmarkService(adapter: adapter),
        pluginDirectories: MacOSPlatform.services(launcher: testExecutionLauncher())
          .pluginDirectories,
        applications: MacOSPlatform.services(launcher: testExecutionLauncher()).applications,
        toolProviders: MacOSPlatform.services(launcher: testExecutionLauncher()).toolProviders,
        managementToolNames: MacOSPlatform.services(launcher: testExecutionLauncher())
          .managementToolNames,
        executableSearchDirectories: MacOSPlatform.services(launcher: testExecutionLauncher())
          .executableSearchDirectories,
        gitExecutable: MacOSPlatform.services(launcher: testExecutionLauncher()).gitExecutable,
        fileChanges: MacOSPlatform.services(launcher: testExecutionLauncher()).fileChanges),
      bundledPlugins: .load(directory: nil))
    do {
      let arguments: JSONValue = .object([
        "project_id": .string(project.id), "path": .string("value.txt"),
      ])
      let read = try runtime.callTool(name: "file.read", arguments: arguments, context: .empty)
      #expect(
        read.objectValue?["structuredContent"]?.objectValue?["result"]?
          .objectValue?["content"] == .string("original"))
      let stored = try database.configurationState()
      let expectedCode: String
      switch change {
      case "denied":
        adapter.set(root: root, allowed: false)
        expectedCode = "project.security_scope_denied"
      case "unresolved":
        adapter.set(root: nil)
        expectedCode = "project.bookmark_resolution_failed"
      case "redirected":
        adapter.set(root: other)
        expectedCode = "project.root_changed"
      default:
        try FileManager.default.moveItem(at: root, to: moved)
        switch change {
        case "replacement":
          try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
          try Data("replacement".utf8).write(to: root.appendingPathComponent("value.txt"))
          expectedCode = "project.root_changed"
        case "symlink":
          try FileManager.default.createSymbolicLink(at: root, withDestinationURL: other)
          expectedCode = "project.root_changed"
        case "file":
          try Data().write(to: root)
          expectedCode = "project.root_not_directory"
        default: expectedCode = "project.root_missing"
        }
      }
      do {
        _ = try runtime.callTool(name: "file.read", arguments: arguments, context: .empty)
        Issue.record("Changed project scope executed a new read: \(change)")
      } catch {
        #expect(GatewayRuntime.auditErrorCode(for: error) == expectedCode)
      }
      let described = try runtime.callTool(
        name: "project.describe", arguments: .object(["project_id": .string(project.id)]),
        context: .empty)
      let access = described.objectValue?["structuredContent"]?.objectValue?["result"]?
        .objectValue?["access"]?.objectValue
      #expect(access?["status"] == .string("unavailable"))
      #expect(access?["error"]?.objectValue?["code"] == .string(expectedCode))
      #expect(try database.configurationState() == stored)
      // Validation borrows a fresh scope; the runtime keeps only its original scope.
      #expect(adapter.activeScopes == 1)
      if ["replacement", "symlink", "file"].contains(change) {
        try FileManager.default.removeItem(at: root)
      }
      if FileManager.default.fileExists(atPath: moved.path) {
        try FileManager.default.moveItem(at: moved, to: root)
      }
      adapter.set(root: root)
      #expect(throws: Never.self) {
        try runtime.callTool(name: "file.read", arguments: arguments, context: .empty)
      }
      await runtime.shutdown()
      #expect(adapter.activeScopes == 0)
    } catch {
      await runtime.shutdown()
      throw error
    }
  }

  @Test
  func executionAndDiagnosticsUseTheCurrentPersistedBookmark() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("value".utf8).write(to: root.appendingPathComponent("value.txt"))
    let adapter = MutableScopeBookmarkAdapter(root: root)
    let database = try GatewayDatabase(inMemory: ())
    try database.saveProject(
      .init(
        id: "project", displayName: "Project", rootPath: root.path,
        bookmarkData: Data("original".utf8)))
    let runtime = try await GatewayRuntime.make(
      configuration: GatewayConfiguration(
        builtin: .init(enabled: ["file.read"]), projectDirectory: root),
      database: database,
      platform: PlatformServices(
        launcher: testExecutionLauncher(),
        projectGrants: ProjectBookmarkService(adapter: adapter),
        pluginDirectories: MacOSPlatform.services(launcher: testExecutionLauncher())
          .pluginDirectories,
        applications: MacOSPlatform.services(launcher: testExecutionLauncher()).applications,
        toolProviders: MacOSPlatform.services(launcher: testExecutionLauncher()).toolProviders,
        managementToolNames: MacOSPlatform.services(launcher: testExecutionLauncher())
          .managementToolNames,
        executableSearchDirectories: MacOSPlatform.services(launcher: testExecutionLauncher())
          .executableSearchDirectories,
        gitExecutable: MacOSPlatform.services(launcher: testExecutionLauncher()).gitExecutable,
        fileChanges: MacOSPlatform.services(launcher: testExecutionLauncher()).fileChanges),
      bundledPlugins: .load(directory: nil))
    do {
      var project = try #require(try database.project(id: "project"))
      project.bookmarkData = Data("invalid".utf8)
      try database.saveProject(project)
      let stored = try database.configurationState()
      do {
        _ = try runtime.callTool(
          name: "file.read", arguments: .object(["path": .string("value.txt")]), context: .empty)
        Issue.record("A stale in-memory bookmark authorized execution")
      } catch {
        #expect(GatewayRuntime.auditErrorCode(for: error) == "project.bookmark_resolution_failed")
      }
      let described = try runtime.callTool(
        name: "project.describe", arguments: .object(["project_id": .string(project.id)]),
        context: .empty)
      #expect(
        described.objectValue?["structuredContent"]?.objectValue?["result"]?
          .objectValue?["access"]?.objectValue?["error"]?.objectValue?["code"]
          == .string("project.bookmark_resolution_failed"))
      #expect(try database.configurationState() == stored)
      #expect(adapter.activeScopes == 1)
      await runtime.shutdown()
      #expect(adapter.activeScopes == 0)
    } catch {
      await runtime.shutdown()
      throw error
    }
  }
}

private final class MutableScopeBookmarkAdapter: ProjectBookmarkAdapter, @unchecked Sendable {
  private let lock = NSLock()
  private var root: URL?
  private var allowed = true
  private var active = 0

  init(root: URL) { self.root = root }

  var activeScopes: Int { lock.withLock { active } }

  func set(root: URL?, allowed: Bool = true) {
    lock.withLock {
      self.root = root
      self.allowed = allowed
    }
  }

  func createBookmark(for url: URL) throws -> Data { Data("original".utf8) }

  func resolveBookmark(_ data: Data) throws -> ProjectBookmarkResolution {
    try lock.withLock {
      guard let root, data == Data("original".utf8) else { throw CocoaError(.fileReadCorruptFile) }
      return ProjectBookmarkResolution(url: root, isStale: false)
    }
  }

  func startAccessing(_ url: URL) -> Bool {
    lock.withLock {
      if allowed { active += 1 }
      return allowed
    }
  }

  func stopAccessing(_ url: URL) { lock.withLock { active -= 1 } }
}
