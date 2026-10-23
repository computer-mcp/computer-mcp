import ComputerMCPPlatform
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

extension ProjectPathResolver {
  package static func resolve(_ path: String, relativeTo projectURL: URL) throws -> URL {
    let lexicalProject = lexicallyNormalized(projectURL)
    let project = try canonicalProject(lexicalProject)
    let isAbsolute = path.hasPrefix("/")
    let target =
      isAbsolute
      ? lexicallyNormalized(URL(fileURLWithPath: path))
      : lexicallyNormalized(project.appendingPathComponent(path))

    guard
      contains(target, in: project)
        || (isAbsolute && contains(target, in: lexicalProject))
    else {
      throw ProjectPathResolutionError.escapesProject
    }

    var existingAncestor = target
    var missingComponents: [String] = []
    while existingAncestor.path != project.path {
      var status = stat()
      if lstat(existingAncestor.path, &status) == 0 {
        break
      }
      let code = errno
      guard code == ENOENT || code == ENOTDIR else {
        throw ProjectPathResolutionError.cannotInspectExistingAncestor(
          path: existingAncestor.path,
          code: code
        )
      }
      missingComponents.insert(existingAncestor.lastPathComponent, at: 0)
      let parent = existingAncestor.deletingLastPathComponent()
      guard parent.path != existingAncestor.path else {
        throw ProjectPathResolutionError.escapesProject
      }
      existingAncestor = parent
    }

    var resolved = try canonicalExistingURL(existingAncestor)
    guard contains(resolved, in: project) else {
      throw ProjectPathResolutionError.escapesProject
    }
    for component in missingComponents {
      resolved.appendPathComponent(component)
    }
    resolved = lexicallyNormalized(resolved)
    guard contains(resolved, in: project) else {
      throw ProjectPathResolutionError.escapesProject
    }

    let systemNormalizedProject = project.standardizedFileURL
    guard systemNormalizedProject.path == lexicalProject.path else {
      return resolved
    }
    let projectPrefix = project.path.hasSuffix("/") ? project.path : "\(project.path)/"
    guard resolved.path.hasPrefix(projectPrefix) else {
      return lexicalProject
    }
    let relativePath = String(resolved.path.dropFirst(projectPrefix.count))
    return lexicallyNormalized(lexicalProject.appendingPathComponent(relativePath))
  }

  package static func canonicalProject(_ projectURL: URL) throws -> URL {
    try canonicalExistingURL(lexicallyNormalized(projectURL))
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

  package static func contains(_ candidate: URL, in project: URL) -> Bool {
    let rootPath = lexicallyNormalized(project).path
    let candidatePath = lexicallyNormalized(candidate).path
    let prefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
    return candidatePath == rootPath || candidatePath.hasPrefix(prefix)
  }

  private static func canonicalExistingURL(_ url: URL) throws -> URL {
    errno = 0
    guard let resolvedPath = realpath(url.path, nil) else {
      throw ProjectPathResolutionError.cannotInspectExistingAncestor(
        path: url.path,
        code: errno
      )
    }
    defer { free(resolvedPath) }
    return URL(fileURLWithPath: String(cString: resolvedPath))
  }
}
