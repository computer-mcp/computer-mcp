import Darwin
import Foundation

package enum WorkspacePathResolutionError: Error, Equatable, Sendable {
  case escapesWorkspace
  case cannotInspectExistingAncestor(path: String, code: Int32)
}

package enum WorkspacePathResolver {
  package static func resolve(_ path: String, relativeTo workspaceURL: URL) throws -> URL {
    let workspace = try canonicalExistingURL(workspaceURL.standardizedFileURL)
    let target =
      path.hasPrefix("/")
      ? URL(fileURLWithPath: path).standardizedFileURL
      : workspace.appendingPathComponent(path).standardizedFileURL

    guard contains(target, in: workspace) else {
      throw WorkspacePathResolutionError.escapesWorkspace
    }

    var existingAncestor = target
    var missingComponents: [String] = []
    while existingAncestor.path != workspace.path {
      var status = stat()
      if lstat(existingAncestor.path, &status) == 0 {
        break
      }
      let code = errno
      guard code == ENOENT || code == ENOTDIR else {
        throw WorkspacePathResolutionError.cannotInspectExistingAncestor(
          path: existingAncestor.path,
          code: code
        )
      }
      missingComponents.insert(existingAncestor.lastPathComponent, at: 0)
      let parent = existingAncestor.deletingLastPathComponent()
      guard parent.path != existingAncestor.path else {
        throw WorkspacePathResolutionError.escapesWorkspace
      }
      existingAncestor = parent
    }

    var resolved = try canonicalExistingURL(existingAncestor)
    guard contains(resolved, in: workspace) else {
      throw WorkspacePathResolutionError.escapesWorkspace
    }
    for component in missingComponents {
      resolved.appendPathComponent(component)
    }
    resolved = resolved.standardizedFileURL
    guard contains(resolved, in: workspace) else {
      throw WorkspacePathResolutionError.escapesWorkspace
    }
    return resolved
  }

  package static func contains(_ candidate: URL, in workspace: URL) -> Bool {
    let rootPath = workspace.standardizedFileURL.path
    let candidatePath = candidate.standardizedFileURL.path
    let prefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
    return candidatePath == rootPath || candidatePath.hasPrefix(prefix)
  }

  private static func canonicalExistingURL(_ url: URL) throws -> URL {
    errno = 0
    guard let resolvedPath = realpath(url.path, nil) else {
      throw WorkspacePathResolutionError.cannotInspectExistingAncestor(
        path: url.path,
        code: errno
      )
    }
    defer { free(resolvedPath) }
    return URL(fileURLWithPath: String(cString: resolvedPath)).standardizedFileURL
  }
}
