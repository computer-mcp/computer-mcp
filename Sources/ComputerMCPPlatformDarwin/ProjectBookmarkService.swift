import ComputerMCPCore
import ComputerMCPPlatform
import Foundation

package struct ProjectBookmarkService: ProjectBookmarkServicing, Sendable {
  private let adapter: any ProjectBookmarkAdapter
  private let now: @Sendable () -> Date

  package init() {
    self.init(
      adapter: FoundationProjectBookmarkAdapter(),
      now: Date.init
    )
  }

  init(
    adapter: any ProjectBookmarkAdapter,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.adapter = adapter
    self.now = now
  }

  package func registerFolder(
    at url: URL,
    displayName: String? = nil
  ) throws -> RegisteredProject {
    let rootURL = try validatedDirectoryURL(url)
    let didStartAccessing = adapter.startAccessing(rootURL)
    defer {
      if didStartAccessing {
        adapter.stopAccessing(rootURL)
      }
    }

    let bookmarkData: Data
    do {
      bookmarkData = try adapter.createBookmark(for: rootURL)
    } catch {
      throw ProjectBookmarkError.bookmarkCreationFailed(path: rootURL.path)
    }

    let timestamp = now()
    return RegisteredProject(
      displayName: normalizedDisplayName(displayName, for: rootURL),
      rootPath: rootURL.path,
      bookmarkData: bookmarkData,
      bookmarkIsStale: false,
      createdAt: timestamp,
      updatedAt: timestamp
    )
  }

  package func resolve(
    _ project: RegisteredProject
  ) throws -> ResolvedProjectAccess {
    guard let bookmarkData = project.bookmarkData else {
      let rootURL = try validatedDirectoryURL(
        URL(fileURLWithPath: project.rootPath, isDirectory: true)
      )
      var resolvedProject = project
      resolvedProject.rootPath = rootURL.path
      resolvedProject.bookmarkIsStale = false
      return try ResolvedProjectAccess(
        project: resolvedProject,
        rootURL: rootURL,
        bookmarkWasRefreshed: false,
        stopAccessing: nil
      )
    }

    let resolution: ProjectBookmarkResolution
    do {
      resolution = try adapter.resolveBookmark(bookmarkData)
    } catch {
      throw ProjectBookmarkError.bookmarkResolutionFailed(projectID: project.id)
    }

    let rootURL = resolution.url.standardizedFileURL
    guard adapter.startAccessing(rootURL) else {
      throw ProjectBookmarkError.securityScopeAccessDenied(projectID: project.id)
    }

    var ownsSecurityScope = true
    defer {
      if ownsSecurityScope {
        adapter.stopAccessing(rootURL)
      }
    }

    _ = try validatedDirectoryURL(rootURL)

    var resolvedProject = project
    let pathChanged = resolvedProject.rootPath != rootURL.path
    resolvedProject.rootPath = rootURL.path
    resolvedProject.bookmarkIsStale = false

    if resolution.isStale {
      do {
        resolvedProject.bookmarkData = try adapter.createBookmark(for: rootURL)
      } catch {
        throw ProjectBookmarkError.bookmarkRefreshFailed(projectID: project.id)
      }
    }

    if resolution.isStale || pathChanged || project.bookmarkIsStale {
      resolvedProject.updatedAt = now()
    }

    let access = try ResolvedProjectAccess(
      project: resolvedProject,
      rootURL: rootURL,
      bookmarkWasRefreshed: resolution.isStale,
      stopAccessing: { [adapter] in
        adapter.stopAccessing(rootURL)
      }
    )
    ownsSecurityScope = false
    return access
  }

  private func validatedDirectoryURL(_ url: URL) throws -> URL {
    guard url.isFileURL else {
      throw ProjectBookmarkError.notFileURL
    }

    let standardizedURL = url.standardizedFileURL
    var isDirectory = ObjCBool(false)
    guard
      FileManager.default.fileExists(
        atPath: standardizedURL.path,
        isDirectory: &isDirectory
      )
    else {
      throw ProjectBookmarkError.rootDoesNotExist(path: standardizedURL.path)
    }
    guard isDirectory.boolValue else {
      throw ProjectBookmarkError.rootIsNotDirectory(path: standardizedURL.path)
    }
    return standardizedURL.resolvingSymlinksInPath()
  }

  private func normalizedDisplayName(_ displayName: String?, for url: URL) -> String {
    let candidate = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !candidate.isEmpty {
      return candidate
    }
    let lastPathComponent = url.lastPathComponent
    return lastPathComponent.isEmpty ? url.path : lastPathComponent
  }
}

struct ProjectBookmarkResolution: Sendable {
  var url: URL
  var isStale: Bool
}

protocol ProjectBookmarkAdapter: Sendable {
  func createBookmark(for url: URL) throws -> Data
  func resolveBookmark(_ data: Data) throws -> ProjectBookmarkResolution
  func startAccessing(_ url: URL) -> Bool
  func stopAccessing(_ url: URL)
}

private struct FoundationProjectBookmarkAdapter: ProjectBookmarkAdapter {
  func createBookmark(for url: URL) throws -> Data {
    try url.bookmarkData(
      options: .withSecurityScope,
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
  }

  func resolveBookmark(_ data: Data) throws -> ProjectBookmarkResolution {
    var isStale = false
    let url = try URL(
      resolvingBookmarkData: data,
      options: [.withSecurityScope, .withoutUI],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    )
    return ProjectBookmarkResolution(url: url, isStale: isStale)
  }

  func startAccessing(_ url: URL) -> Bool {
    url.startAccessingSecurityScopedResource()
  }

  func stopAccessing(_ url: URL) {
    url.stopAccessingSecurityScopedResource()
  }
}
