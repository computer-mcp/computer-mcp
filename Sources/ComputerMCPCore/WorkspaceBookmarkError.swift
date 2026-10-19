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
