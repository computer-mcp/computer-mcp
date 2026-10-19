import Foundation

package enum WorkspaceBookmarkError: Error, Equatable, Sendable {
  case notFileURL
  case rootDoesNotExist(path: String)
  case rootIsNotDirectory(path: String)
  case rootIdentityUnavailable(path: String)
  case rootChanged(workspaceID: String)
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
    case .rootIdentityUnavailable:
      "workspace.root_identity_unavailable"
    case .rootChanged:
      "workspace.root_changed"
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
    case .rootIdentityUnavailable(let path):
      "Could not verify the workspace folder's identity: \(path)"
    case .rootChanged(let workspaceID):
      "The workspace folder no longer matches this runtime: \(workspaceID)"
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
