import ComputerMCPCore
import ComputerMCPPlatform
import Foundation

package struct WorkspaceBookmarkService: WorkspaceBookmarkServicing, Sendable {
  private let adapter: any WorkspaceBookmarkAdapter
  private let now: @Sendable () -> Date

  package init() {
    self.init(
      adapter: FoundationWorkspaceBookmarkAdapter(),
      now: Date.init
    )
  }

  init(
    adapter: any WorkspaceBookmarkAdapter,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.adapter = adapter
    self.now = now
  }

  package func registerFolder(
    at url: URL,
    displayName: String? = nil
  ) throws -> RegisteredWorkspace {
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
      throw WorkspaceBookmarkError.bookmarkCreationFailed(path: rootURL.path)
    }

    let timestamp = now()
    return RegisteredWorkspace(
      displayName: normalizedDisplayName(displayName, for: rootURL),
      rootPath: rootURL.path,
      bookmarkData: bookmarkData,
      bookmarkIsStale: false,
      createdAt: timestamp,
      updatedAt: timestamp
    )
  }

  package func resolve(
    _ workspace: RegisteredWorkspace
  ) throws -> ResolvedWorkspaceAccess {
    guard let bookmarkData = workspace.bookmarkData else {
      let rootURL = try validatedDirectoryURL(
        URL(fileURLWithPath: workspace.rootPath, isDirectory: true)
      )
      var resolvedWorkspace = workspace
      resolvedWorkspace.rootPath = rootURL.path
      resolvedWorkspace.bookmarkIsStale = false
      return try ResolvedWorkspaceAccess(
        workspace: resolvedWorkspace,
        rootURL: rootURL,
        bookmarkWasRefreshed: false,
        stopAccessing: nil
      )
    }

    let resolution: WorkspaceBookmarkResolution
    do {
      resolution = try adapter.resolveBookmark(bookmarkData)
    } catch {
      throw WorkspaceBookmarkError.bookmarkResolutionFailed(workspaceID: workspace.id)
    }

    let rootURL = resolution.url.standardizedFileURL
    guard adapter.startAccessing(rootURL) else {
      throw WorkspaceBookmarkError.securityScopeAccessDenied(workspaceID: workspace.id)
    }

    var ownsSecurityScope = true
    defer {
      if ownsSecurityScope {
        adapter.stopAccessing(rootURL)
      }
    }

    _ = try validatedDirectoryURL(rootURL)

    var resolvedWorkspace = workspace
    let pathChanged = resolvedWorkspace.rootPath != rootURL.path
    resolvedWorkspace.rootPath = rootURL.path
    resolvedWorkspace.bookmarkIsStale = false

    if resolution.isStale {
      do {
        resolvedWorkspace.bookmarkData = try adapter.createBookmark(for: rootURL)
      } catch {
        throw WorkspaceBookmarkError.bookmarkRefreshFailed(workspaceID: workspace.id)
      }
    }

    if resolution.isStale || pathChanged || workspace.bookmarkIsStale {
      resolvedWorkspace.updatedAt = now()
    }

    let access = try ResolvedWorkspaceAccess(
      workspace: resolvedWorkspace,
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
      throw WorkspaceBookmarkError.notFileURL
    }

    let standardizedURL = url.standardizedFileURL
    var isDirectory = ObjCBool(false)
    guard
      FileManager.default.fileExists(
        atPath: standardizedURL.path,
        isDirectory: &isDirectory
      )
    else {
      throw WorkspaceBookmarkError.rootDoesNotExist(path: standardizedURL.path)
    }
    guard isDirectory.boolValue else {
      throw WorkspaceBookmarkError.rootIsNotDirectory(path: standardizedURL.path)
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

struct WorkspaceBookmarkResolution: Sendable {
  var url: URL
  var isStale: Bool
}

protocol WorkspaceBookmarkAdapter: Sendable {
  func createBookmark(for url: URL) throws -> Data
  func resolveBookmark(_ data: Data) throws -> WorkspaceBookmarkResolution
  func startAccessing(_ url: URL) -> Bool
  func stopAccessing(_ url: URL)
}

private struct FoundationWorkspaceBookmarkAdapter: WorkspaceBookmarkAdapter {
  func createBookmark(for url: URL) throws -> Data {
    try url.bookmarkData(
      options: .withSecurityScope,
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
  }

  func resolveBookmark(_ data: Data) throws -> WorkspaceBookmarkResolution {
    var isStale = false
    let url = try URL(
      resolvingBookmarkData: data,
      options: [.withSecurityScope, .withoutUI],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    )
    return WorkspaceBookmarkResolution(url: url, isStale: isStale)
  }

  func startAccessing(_ url: URL) -> Bool {
    url.startAccessingSecurityScopedResource()
  }

  func stopAccessing(_ url: URL) {
    url.stopAccessingSecurityScopedResource()
  }
}
