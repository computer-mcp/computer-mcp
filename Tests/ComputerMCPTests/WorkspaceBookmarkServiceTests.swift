import Foundation
import Testing

@testable import ComputerMCP

@Suite

final class WorkspaceBookmarkServiceTests {
  @Test
  func testPathOnlyFallbackResolvesDevelopmentRecordWithoutSecurityScope() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let adapter = TestWorkspaceBookmarkAdapter()
    let service = WorkspaceBookmarkService(adapter: adapter)
    let workspace = RegisteredWorkspace(
      id: "workspace-path-only",
      displayName: "Development",
      rootPath: root.path
    )

    let access = try service.resolve(workspace)

    #expect((access.workspace) == (workspace))
    #expect((access.rootURL) == (root.standardizedFileURL))
    #expect(!(access.bookmarkWasRefreshed))
    #expect(access.isActive)
    #expect((adapter.startCount) == (0))
    #expect((adapter.stopCount) == (0))

    access.close()
    #expect(!(access.isActive))
    #expect((adapter.stopCount) == (0))
  }

  @Test
  func testStaleBookmarkRefreshPreservesStableWorkspaceIDAndLifecycle() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let oldBookmark = Data("old-bookmark".utf8)
    let newBookmark = Data("new-bookmark".utf8)
    let adapter = TestWorkspaceBookmarkAdapter(
      createdBookmark: newBookmark,
      resolution: WorkspaceBookmarkResolution(url: root, isStale: true),
      accessAllowed: true
    )
    let timestamp = Date(timeIntervalSince1970: 2_000)
    let service = WorkspaceBookmarkService(adapter: adapter, now: { timestamp })
    let workspace = RegisteredWorkspace(
      id: "stable-workspace-id",
      displayName: "User Label",
      rootPath: "/previous/location",
      bookmarkData: oldBookmark,
      bookmarkIsStale: false,
      createdAt: Date(timeIntervalSince1970: 1_000),
      updatedAt: Date(timeIntervalSince1970: 1_000)
    )

    let access = try service.resolve(workspace)

    #expect((access.workspace.id) == (workspace.id))
    #expect((access.workspace.displayName) == (workspace.displayName))
    #expect((access.workspace.rootPath) == (root.standardizedFileURL.path))
    #expect((access.workspace.bookmarkData) == (newBookmark))
    #expect(!(access.workspace.bookmarkIsStale))
    #expect((access.workspace.createdAt) == (workspace.createdAt))
    #expect((access.workspace.updatedAt) == (timestamp))
    #expect(access.bookmarkWasRefreshed)
    #expect((adapter.startCount) == (1))
    #expect((adapter.stopCount) == (0))

    access.close()
    access.close()
    #expect(!(access.isActive))
    #expect((adapter.stopCount) == (1))
  }

  @Test
  func testAccessHandleStopsSecurityScopeOnDeinitialization() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let adapter = TestWorkspaceBookmarkAdapter(
      resolution: WorkspaceBookmarkResolution(url: root, isStale: false),
      accessAllowed: true
    )
    let service = WorkspaceBookmarkService(adapter: adapter)
    let workspace = RegisteredWorkspace(
      id: "workspace-deinit",
      displayName: "Deinit",
      rootPath: root.path,
      bookmarkData: Data("bookmark".utf8)
    )

    var access: ResolvedWorkspaceAccess? = try service.resolve(workspace)
    #expect((access) != nil)
    #expect((adapter.stopCount) == (0))

    access = nil
    #expect((access) == nil)
    #expect((adapter.stopCount) == (1))
  }

  @Test
  func testMissingAndNonDirectoryRootsReturnTypedErrors() throws {
    let container = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: container) }

    let service = WorkspaceBookmarkService(adapter: TestWorkspaceBookmarkAdapter())
    let missingURL = container.appendingPathComponent("missing", isDirectory: true)
    let fileURL = container.appendingPathComponent("file.txt", isDirectory: false)
    #expect(FileManager.default.createFile(atPath: fileURL.path, contents: Data()))

    expectThrows(
      try service.resolve(
        RegisteredWorkspace(displayName: "Missing", rootPath: missingURL.path)
      )
    ) { error in
      #expect(
        (error as? WorkspaceBookmarkError)
          == (.rootDoesNotExist(path: missingURL.standardizedFileURL.path)))
    }

    expectThrows(
      try service.resolve(
        RegisteredWorkspace(displayName: "File", rootPath: fileURL.path)
      )
    ) { error in
      #expect(
        (error as? WorkspaceBookmarkError)
          == (.rootIsNotDirectory(path: fileURL.standardizedFileURL.path)))
    }
  }

  @Test
  func testRegistrationCreatesBookmarkAndBalancesTemporaryScope() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let bookmark = Data("registered".utf8)
    let adapter = TestWorkspaceBookmarkAdapter(
      createdBookmark: bookmark,
      accessAllowed: true
    )
    let timestamp = Date(timeIntervalSince1970: 3_000)
    let service = WorkspaceBookmarkService(adapter: adapter, now: { timestamp })

    let workspace = try service.registerFolder(at: root, displayName: "  Project  ")

    #expect(!(workspace.id.isEmpty))
    #expect((workspace.displayName) == ("Project"))
    #expect((workspace.rootPath) == (root.standardizedFileURL.path))
    #expect((workspace.bookmarkData) == (bookmark))
    #expect(!(workspace.bookmarkIsStale))
    #expect((workspace.createdAt) == (timestamp))
    #expect((workspace.updatedAt) == (timestamp))
    #expect((adapter.startCount) == (1))
    #expect((adapter.stopCount) == (1))
  }

  @Test
  func testResolutionAndSecurityScopeFailuresHaveStableTypedCodes() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let workspace = RegisteredWorkspace(
      id: "workspace-errors",
      displayName: "Errors",
      rootPath: root.path,
      bookmarkData: Data("bookmark".utf8)
    )
    let resolutionFailure = WorkspaceBookmarkService(
      adapter: TestWorkspaceBookmarkAdapter(resolveError: TestError.failed)
    )
    expectThrows(try resolutionFailure.resolve(workspace)) { error in
      let typedError = error as? WorkspaceBookmarkError
      #expect((typedError) == (.bookmarkResolutionFailed(workspaceID: workspace.id)))
      #expect((typedError?.code) == ("workspace.bookmark_resolution_failed"))
    }

    let denied = WorkspaceBookmarkService(
      adapter: TestWorkspaceBookmarkAdapter(
        resolution: WorkspaceBookmarkResolution(url: root, isStale: false),
        accessAllowed: false
      )
    )
    expectThrows(try denied.resolve(workspace)) { error in
      let typedError = error as? WorkspaceBookmarkError
      #expect((typedError) == (.securityScopeAccessDenied(workspaceID: workspace.id)))
      #expect((typedError?.code) == ("workspace.security_scope_denied"))
    }
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true
    )
    return url.standardizedFileURL
  }
}

private enum TestError: Error {
  case failed
}

private final class TestWorkspaceBookmarkAdapter: WorkspaceBookmarkAdapter, @unchecked Sendable {
  private let lock = NSLock()
  private let createdBookmark: Data
  private let resolution: WorkspaceBookmarkResolution?
  private let accessAllowed: Bool
  private let createError: (any Error)?
  private let resolveError: (any Error)?
  private var starts = 0
  private var stops = 0

  init(
    createdBookmark: Data = Data("created".utf8),
    resolution: WorkspaceBookmarkResolution? = nil,
    accessAllowed: Bool = false,
    createError: (any Error)? = nil,
    resolveError: (any Error)? = nil
  ) {
    self.createdBookmark = createdBookmark
    self.resolution = resolution
    self.accessAllowed = accessAllowed
    self.createError = createError
    self.resolveError = resolveError
  }

  var startCount: Int {
    lock.withLock { starts }
  }

  var stopCount: Int {
    lock.withLock { stops }
  }

  func createBookmark(for url: URL) throws -> Data {
    if let createError {
      throw createError
    }
    return createdBookmark
  }

  func resolveBookmark(_ data: Data) throws -> WorkspaceBookmarkResolution {
    if let resolveError {
      throw resolveError
    }
    guard let resolution else {
      throw TestError.failed
    }
    return resolution
  }

  func startAccessing(_ url: URL) -> Bool {
    lock.withLock {
      starts += 1
    }
    return accessAllowed
  }

  func stopAccessing(_ url: URL) {
    lock.withLock {
      stops += 1
    }
  }
}
