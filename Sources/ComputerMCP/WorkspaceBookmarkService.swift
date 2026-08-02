import Foundation

package protocol WorkspaceBookmarkServicing: Sendable {
  func registerFolder(
    at url: URL,
    displayName: String?
  ) throws -> RegisteredWorkspace

  func resolve(
    _ workspace: RegisteredWorkspace
  ) throws -> ResolvedWorkspaceAccess
}

package enum WorkspaceBookmarkError: Error, Equatable, Sendable {
  case notFileURL
  case rootDoesNotExist(path: String)
  case rootIsNotDirectory(path: String)
  case bookmarkCreationFailed(path: String)
  case bookmarkResolutionFailed(workspaceID: String)
  case securityScopeAccessDenied(workspaceID: String)
  case bookmarkRefreshFailed(workspaceID: String)

  package var code: String {
    switch self {
    case .notFileURL:
      "workspace.not_file_url"
    case .rootDoesNotExist:
      "workspace.root_missing"
    case .rootIsNotDirectory:
      "workspace.root_not_directory"
    case .bookmarkCreationFailed:
      "workspace.bookmark_creation_failed"
    case .bookmarkResolutionFailed:
      "workspace.bookmark_resolution_failed"
    case .securityScopeAccessDenied:
      "workspace.security_scope_denied"
    case .bookmarkRefreshFailed:
      "workspace.bookmark_refresh_failed"
    }
  }
}

extension WorkspaceBookmarkError: LocalizedError {
  package var errorDescription: String? {
    switch self {
    case .notFileURL:
      "Workspace root must be a file URL."
    case .rootDoesNotExist(let path):
      "Workspace root does not exist: \(path)"
    case .rootIsNotDirectory(let path):
      "Workspace root is not a directory: \(path)"
    case .bookmarkCreationFailed(let path):
      "Could not create a security-scoped bookmark for workspace root: \(path)"
    case .bookmarkResolutionFailed(let workspaceID):
      "Could not resolve the security-scoped bookmark for workspace: \(workspaceID)"
    case .securityScopeAccessDenied(let workspaceID):
      "Could not access the security-scoped workspace: \(workspaceID)"
    case .bookmarkRefreshFailed(let workspaceID):
      "Could not refresh the stale security-scoped bookmark for workspace: \(workspaceID)"
    }
  }
}

package final class ResolvedWorkspaceAccess: @unchecked Sendable {
  package let workspace: RegisteredWorkspace
  package let rootURL: URL
  package let bookmarkWasRefreshed: Bool

  private let lock = NSLock()
  private var active = true
  private var stopAccessing: (@Sendable () -> Void)?

  fileprivate init(
    workspace: RegisteredWorkspace,
    rootURL: URL,
    bookmarkWasRefreshed: Bool,
    stopAccessing: (@Sendable () -> Void)?
  ) {
    self.workspace = workspace
    self.rootURL = rootURL
    self.bookmarkWasRefreshed = bookmarkWasRefreshed
    self.stopAccessing = stopAccessing
  }

  package var isActive: Bool {
    lock.withLock { active }
  }

  package func close() {
    let stop = lock.withLock { () -> (@Sendable () -> Void)? in
      guard active else {
        return nil
      }
      active = false
      defer { stopAccessing = nil }
      return stopAccessing
    }
    stop?()
  }

  deinit {
    close()
  }
}

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
      return ResolvedWorkspaceAccess(
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

    ownsSecurityScope = false
    return ResolvedWorkspaceAccess(
      workspace: resolvedWorkspace,
      rootURL: rootURL,
      bookmarkWasRefreshed: resolution.isStale,
      stopAccessing: { [adapter] in
        adapter.stopAccessing(rootURL)
      }
    )
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
    return standardizedURL
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
      options: .withSecurityScope,
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
