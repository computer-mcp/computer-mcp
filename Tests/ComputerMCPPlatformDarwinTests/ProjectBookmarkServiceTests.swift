import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPCore
@testable import ComputerMCPPlatform
@testable import ComputerMCPPlatformDarwin

@Suite

final class ProjectBookmarkServiceTests {
  @Test(arguments: [false, true])
  func inspectionReportsAccessAndClosesOwnedScope(accessAllowed: Bool) throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let adapter = TestProjectBookmarkAdapter(
      resolution: ProjectBookmarkResolution(url: root, isStale: false),
      accessAllowed: accessAllowed)
    let service = ProjectBookmarkService(adapter: adapter)
    let project = RegisteredProject(
      id: "inspection", displayName: "Inspection", rootPath: root.path,
      bookmarkData: Data("bookmark".utf8))
    let report = try service.inspect(project)
    #expect(report.project == project)
    #expect(
      report.error == (accessAllowed ? nil : .securityScopeAccessDenied(projectID: project.id)))
    #expect(
      report.json.objectValue?["status"] == .string(accessAllowed ? "available" : "unavailable"))
    #expect(adapter.startCount == 1)
    #expect(adapter.stopCount == (accessAllowed ? 1 : 0))
  }

  @Test
  func testPathOnlyFallbackResolvesDevelopmentRecordWithoutSecurityScope() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let adapter = TestProjectBookmarkAdapter()
    let service = ProjectBookmarkService(adapter: adapter)
    let project = RegisteredProject(
      id: "project-path-only",
      displayName: "Development",
      rootPath: root.path
    )

    let access = try service.resolve(project)

    #expect((access.project) == (project))
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
  func testStaleBookmarkRefreshPreservesStableProjectIDAndLifecycle() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let oldBookmark = Data("old-bookmark".utf8)
    let newBookmark = Data("new-bookmark".utf8)
    let adapter = TestProjectBookmarkAdapter(
      createdBookmark: newBookmark,
      resolution: ProjectBookmarkResolution(url: root, isStale: true),
      accessAllowed: true
    )
    let timestamp = Date(timeIntervalSince1970: 2_000)
    let service = ProjectBookmarkService(adapter: adapter, now: { timestamp })
    let project = RegisteredProject(
      id: "stable-project-id",
      displayName: "User Label",
      rootPath: "/previous/location",
      bookmarkData: oldBookmark,
      bookmarkIsStale: false,
      createdAt: Date(timeIntervalSince1970: 1_000),
      updatedAt: Date(timeIntervalSince1970: 1_000)
    )

    let access = try service.resolve(project)

    #expect((access.project.id) == (project.id))
    #expect((access.project.displayName) == (project.displayName))
    #expect((access.project.rootPath) == (root.standardizedFileURL.path))
    #expect((access.project.bookmarkData) == (newBookmark))
    #expect(!(access.project.bookmarkIsStale))
    #expect((access.project.createdAt) == (project.createdAt))
    #expect((access.project.updatedAt) == (timestamp))
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

    let adapter = TestProjectBookmarkAdapter(
      resolution: ProjectBookmarkResolution(url: root, isStale: false),
      accessAllowed: true
    )
    let service = ProjectBookmarkService(adapter: adapter)
    let project = RegisteredProject(
      id: "project-deinit",
      displayName: "Deinit",
      rootPath: root.path,
      bookmarkData: Data("bookmark".utf8)
    )

    var access: ResolvedProjectAccess? = try service.resolve(project)
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

    let service = ProjectBookmarkService(adapter: TestProjectBookmarkAdapter())
    let missingURL = container.appendingPathComponent("missing", isDirectory: true)
    let fileURL = container.appendingPathComponent("file.txt", isDirectory: false)
    #expect(FileManager.default.createFile(atPath: fileURL.path, contents: Data()))

    expectThrows(
      try service.resolve(
        RegisteredProject(displayName: "Missing", rootPath: missingURL.path)
      )
    ) { error in
      #expect(
        (error as? ProjectBookmarkError)
          == (.rootDoesNotExist(path: missingURL.standardizedFileURL.path)))
    }

    expectThrows(
      try service.resolve(
        RegisteredProject(displayName: "File", rootPath: fileURL.path)
      )
    ) { error in
      #expect(
        (error as? ProjectBookmarkError)
          == (.rootIsNotDirectory(path: fileURL.standardizedFileURL.path)))
    }
  }

  @Test
  func testRegistrationCreatesBookmarkAndBalancesTemporaryScope() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let bookmark = Data("registered".utf8)
    let adapter = TestProjectBookmarkAdapter(
      createdBookmark: bookmark,
      accessAllowed: true
    )
    let timestamp = Date(timeIntervalSince1970: 3_000)
    let service = ProjectBookmarkService(adapter: adapter, now: { timestamp })

    let project = try service.registerFolder(at: root, displayName: "  Project  ")

    #expect(!(project.id.isEmpty))
    #expect((project.displayName) == ("Project"))
    #expect((project.rootPath) == (root.standardizedFileURL.path))
    #expect((project.bookmarkData) == (bookmark))
    #expect(!(project.bookmarkIsStale))
    #expect((project.createdAt) == (timestamp))
    #expect((project.updatedAt) == (timestamp))
    #expect((adapter.startCount) == (1))
    #expect((adapter.stopCount) == (1))
  }

  @Test
  func testResolutionAndSecurityScopeFailuresHaveStableTypedCodes() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let project = RegisteredProject(
      id: "project-errors",
      displayName: "Errors",
      rootPath: root.path,
      bookmarkData: Data("bookmark".utf8)
    )
    let resolutionFailure = ProjectBookmarkService(
      adapter: TestProjectBookmarkAdapter(resolveError: TestError.failed)
    )
    expectThrows(try resolutionFailure.resolve(project)) { error in
      let typedError = error as? ProjectBookmarkError
      #expect((typedError) == (.bookmarkResolutionFailed(projectID: project.id)))
      #expect((typedError?.code) == ("project.bookmark_resolution_failed"))
    }

    let denied = ProjectBookmarkService(
      adapter: TestProjectBookmarkAdapter(
        resolution: ProjectBookmarkResolution(url: root, isStale: false),
        accessAllowed: false
      )
    )
    expectThrows(try denied.resolve(project)) { error in
      let typedError = error as? ProjectBookmarkError
      #expect((typedError) == (.securityScopeAccessDenied(projectID: project.id)))
      #expect((typedError?.code) == ("project.security_scope_denied"))
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

private final class TestProjectBookmarkAdapter: ProjectBookmarkAdapter, @unchecked Sendable {
  private let lock = NSLock()
  private let createdBookmark: Data
  private let resolution: ProjectBookmarkResolution?
  private let accessAllowed: Bool
  private let createError: (any Error)?
  private let resolveError: (any Error)?
  private var starts = 0
  private var stops = 0

  init(
    createdBookmark: Data = Data("created".utf8),
    resolution: ProjectBookmarkResolution? = nil,
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

  func resolveBookmark(_ data: Data) throws -> ProjectBookmarkResolution {
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
