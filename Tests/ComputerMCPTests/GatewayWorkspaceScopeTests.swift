import Foundation
import Testing

@testable import ComputerMCP

@Suite(.timeLimit(.minutes(1)))
struct GatewayWorkspaceScopeTests {
  @Test(
    arguments: ["replacement", "symlink", "missing", "file", "denied", "unresolved", "redirected"],
    [false, true])
  func currentAccessIsCheckedBeforeDispatch(change: String, persisted: Bool) async throws {
    let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let root = container.appendingPathComponent("workspace")
    let moved = container.appendingPathComponent("original")
    let other = container.appendingPathComponent("other")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: container) }
    try Data("original".utf8).write(to: root.appendingPathComponent("value.txt"))
    try Data("other".utf8).write(to: other.appendingPathComponent("value.txt"))
    let adapter = MutableScopeBookmarkAdapter(root: root)
    let database = try GatewayDatabase(path: container.appendingPathComponent("state.sqlite").path)
    let workspace = RegisteredWorkspace(
      id: "project", displayName: "Project", rootPath: root.path,
      bookmarkData: Data("original".utf8))
    try database.saveWorkspace(workspace)
    let runtime = try await GatewayRuntime.make(
      configuration: GatewayConfiguration(
        builtin: .init(enabled: ["file.read"]), workspaceDirectory: root),
      database: persisted ? database : nil, registeredWorkspaces: persisted ? nil : [workspace],
      bookmarkService: WorkspaceBookmarkService(adapter: adapter),
      bundledPlugins: .load(directory: nil))
    do {
      let arguments: JSONValue = .object([
        "workspace_id": .string(workspace.id), "path": .string("value.txt"),
      ])
      let read = try runtime.callTool(name: "file.read", arguments: arguments)
      #expect(
        read.objectValue?["structuredContent"]?.objectValue?["result"]?
          .objectValue?["content"] == .string("original"))
      let stored = try database.configurationState()
      let expectedCode: String
      switch change {
      case "denied":
        adapter.set(root: root, allowed: false)
        expectedCode = "workspace.security_scope_denied"
      case "unresolved":
        adapter.set(root: nil)
        expectedCode = "workspace.bookmark_resolution_failed"
      case "redirected":
        adapter.set(root: other)
        expectedCode = "workspace.root_changed"
      default:
        try FileManager.default.moveItem(at: root, to: moved)
        switch change {
        case "replacement":
          try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
          try Data("replacement".utf8).write(to: root.appendingPathComponent("value.txt"))
          expectedCode = "workspace.root_changed"
        case "symlink":
          try FileManager.default.createSymbolicLink(at: root, withDestinationURL: other)
          expectedCode = "workspace.root_changed"
        case "file":
          try Data().write(to: root)
          expectedCode = "workspace.root_not_directory"
        default: expectedCode = "workspace.root_missing"
        }
      }
      do {
        _ = try runtime.callTool(name: "file.read", arguments: arguments)
        Issue.record("Changed workspace scope executed a new read: \(change)")
      } catch {
        #expect(GatewayRuntime.auditErrorCode(for: error) == expectedCode)
      }
      let described = try runtime.callTool(
        name: "workspace.describe", arguments: .object(["workspace_id": .string(workspace.id)]))
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
      #expect(throws: Never.self) { try runtime.callTool(name: "file.read", arguments: arguments) }
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
    try database.saveWorkspace(
      .init(
        id: "project", displayName: "Project", rootPath: root.path,
        bookmarkData: Data("original".utf8)))
    let runtime = try await GatewayRuntime.make(
      configuration: GatewayConfiguration(
        builtin: .init(enabled: ["file.read"]), workspaceDirectory: root),
      database: database, bookmarkService: WorkspaceBookmarkService(adapter: adapter),
      bundledPlugins: .load(directory: nil))
    do {
      var workspace = try #require(try database.workspace(id: "project"))
      workspace.bookmarkData = Data("invalid".utf8)
      try database.saveWorkspace(workspace)
      let stored = try database.configurationState()
      do {
        _ = try runtime.callTool(
          name: "file.read", arguments: .object(["path": .string("value.txt")]))
        Issue.record("A stale in-memory bookmark authorized execution")
      } catch {
        #expect(GatewayRuntime.auditErrorCode(for: error) == "workspace.bookmark_resolution_failed")
      }
      let described = try runtime.callTool(
        name: "workspace.describe", arguments: .object(["workspace_id": .string(workspace.id)]))
      #expect(
        described.objectValue?["structuredContent"]?.objectValue?["result"]?
          .objectValue?["access"]?.objectValue?["error"]?.objectValue?["code"]
          == .string("workspace.bookmark_resolution_failed"))
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

private final class MutableScopeBookmarkAdapter: WorkspaceBookmarkAdapter, @unchecked Sendable {
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

  func resolveBookmark(_ data: Data) throws -> WorkspaceBookmarkResolution {
    try lock.withLock {
      guard let root, data == Data("original".utf8) else { throw CocoaError(.fileReadCorruptFile) }
      return WorkspaceBookmarkResolution(url: root, isStale: false)
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
