import Darwin
import Foundation

package enum WorkspacePathResolutionError: Error, Equatable, Sendable {
  case escapesWorkspace
  case cannotInspectExistingAncestor(path: String, code: Int32)
}

package enum WorkspacePathResolver {
  package static func resolve(_ path: String, relativeTo workspaceURL: URL) throws -> URL {
    let lexicalWorkspace = lexicallyNormalized(workspaceURL)
    let workspace = try canonicalWorkspace(lexicalWorkspace)
    let isAbsolute = path.hasPrefix("/")
    let target =
      isAbsolute
      ? lexicallyNormalized(URL(fileURLWithPath: path))
      : lexicallyNormalized(workspace.appendingPathComponent(path))

    guard
      contains(target, in: workspace)
        || (isAbsolute && contains(target, in: lexicalWorkspace))
    else {
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
    resolved = lexicallyNormalized(resolved)
    guard contains(resolved, in: workspace) else {
      throw WorkspacePathResolutionError.escapesWorkspace
    }

    let systemNormalizedWorkspace = workspace.standardizedFileURL
    guard systemNormalizedWorkspace.path == lexicalWorkspace.path else {
      return resolved
    }
    let workspacePrefix = workspace.path.hasSuffix("/") ? workspace.path : "\(workspace.path)/"
    guard resolved.path.hasPrefix(workspacePrefix) else {
      return lexicalWorkspace
    }
    let relativePath = String(resolved.path.dropFirst(workspacePrefix.count))
    return lexicallyNormalized(lexicalWorkspace.appendingPathComponent(relativePath))
  }

  package static func canonicalWorkspace(_ workspaceURL: URL) throws -> URL {
    try canonicalExistingURL(lexicallyNormalized(workspaceURL))
  }

  package static func lexicallyNormalized(_ url: URL) -> URL {
    var components: [Substring] = []
    for component in url.path.split(separator: "/", omittingEmptySubsequences: true) {
      switch component {
      case ".":
        continue
      case "..":
        if !components.isEmpty {
          components.removeLast()
        }
      default:
        components.append(component)
      }
    }
    return URL(fileURLWithPath: "/" + components.joined(separator: "/"))
  }

  package static func contains(_ candidate: URL, in workspace: URL) -> Bool {
    let rootPath = lexicallyNormalized(workspace).path
    let candidatePath = lexicallyNormalized(candidate).path
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
    return URL(fileURLWithPath: String(cString: resolvedPath))
  }
}
