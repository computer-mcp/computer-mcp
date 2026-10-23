import Foundation

package enum ProjectBookmarkError: Error, Equatable, Sendable {
  case notFileURL
  case rootDoesNotExist(path: String)
  case rootIsNotDirectory(path: String)
  case rootIdentityUnavailable(path: String)
  case rootChanged(projectID: String)
  case bookmarkCreationFailed(path: String)
  case bookmarkResolutionFailed(projectID: String)
  case securityScopeAccessDenied(projectID: String)
  case bookmarkRefreshFailed(projectID: String)

  package var code: String {
    switch self {
    case .notFileURL:
      "project.not_file_url"
    case .rootDoesNotExist:
      "project.root_missing"
    case .rootIsNotDirectory:
      "project.root_not_directory"
    case .rootIdentityUnavailable:
      "project.root_identity_unavailable"
    case .rootChanged:
      "project.root_changed"
    case .bookmarkCreationFailed:
      "project.bookmark_creation_failed"
    case .bookmarkResolutionFailed:
      "project.bookmark_resolution_failed"
    case .securityScopeAccessDenied:
      "project.security_scope_denied"
    case .bookmarkRefreshFailed:
      "project.bookmark_refresh_failed"
    }
  }
}

extension ProjectBookmarkError: LocalizedError {
  package var errorDescription: String? {
    switch self {
    case .notFileURL:
      "Project root must be a file URL."
    case .rootDoesNotExist(let path):
      "Project root does not exist: \(path)"
    case .rootIsNotDirectory(let path):
      "Project root is not a directory: \(path)"
    case .rootIdentityUnavailable(let path):
      "Could not verify the project folder's identity: \(path)"
    case .rootChanged(let projectID):
      "The project folder no longer matches this runtime: \(projectID)"
    case .bookmarkCreationFailed(let path):
      "Could not create a security-scoped bookmark for project root: \(path)"
    case .bookmarkResolutionFailed(let projectID):
      "Could not resolve the security-scoped bookmark for project: \(projectID)"
    case .securityScopeAccessDenied(let projectID):
      "Could not access the security-scoped project: \(projectID)"
    case .bookmarkRefreshFailed(let projectID):
      "Could not refresh the stale security-scoped bookmark for project: \(projectID)"
    }
  }
}
