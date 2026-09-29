import Foundation

extension GatewayToolRegistry {
  internal func resolvedWorkspaceURL(_ path: String) throws -> URL {
    do {
      return try WorkspacePathResolver.resolve(
        path,
        relativeTo: configuration.workspaceDirectory
      )
    } catch {
      throw GatewayToolError.invalidArguments(
        "[policy.workspace_denied] Path escapes workspace: \(path)")
    }
  }

  internal func lexicalWorkspaceURL(_ path: String) throws -> URL {
    let base = configuration.workspaceDirectory.standardizedFileURL.resolvingSymlinksInPath()
    let target =
      path.hasPrefix("/")
      ? URL(fileURLWithPath: path)
      : base.appendingPathComponent(path)
    let standardized = target.standardizedFileURL
    let basePath = base.path
    let basePrefix = basePath.hasSuffix("/") ? basePath : "\(basePath)/"
    guard standardized.path == basePath || standardized.path.hasPrefix(basePrefix) else {
      throw GatewayToolError.invalidArguments(
        "[policy.workspace_denied] Path escapes workspace: \(path)")
    }
    return standardized
  }

  internal func workspaceInstructionScopeURL(
    targetURL: URL,
    originalPath: String = ".",
    pathIsDirectory: Bool?,
    targetExists: Bool
  ) throws -> URL {
    if targetExists {
      let targetWorkspaceRelativePath = workspaceRelativePathPreservingSymlinks(targetURL)
      let resolvedTarget = try resolvedWorkspaceURL(targetWorkspaceRelativePath)
      var isDirectory = ObjCBool(false)
      FileManager.default.fileExists(atPath: resolvedTarget.path, isDirectory: &isDirectory)
      let treatAsDirectory = pathIsDirectory ?? isDirectory.boolValue
      return treatAsDirectory ? resolvedTarget : resolvedTarget.deletingLastPathComponent()
    }

    let treatAsDirectory =
      pathIsDirectory ?? (originalPath == "." || originalPath.hasSuffix("/"))
    return treatAsDirectory ? targetURL : targetURL.deletingLastPathComponent()
  }

  internal func workspaceInstructionScopeDirectories(scopeURL: URL) -> [URL] {
    let base = configuration.workspaceDirectory.standardizedFileURL.resolvingSymlinksInPath()
    let basePath = base.path
    let basePrefix = basePath.hasSuffix("/") ? basePath : "\(basePath)/"
    let scope = scopeURL.standardizedFileURL
    guard scope.path == basePath || scope.path.hasPrefix(basePrefix) else {
      return [base]
    }

    var directories: [URL] = []
    var current = scope
    while current.path != basePath {
      directories.append(current)
      let parent = current.deletingLastPathComponent()
      guard parent.path != current.path else {
        break
      }
      current = parent
    }
    directories.append(base)
    return directories.reversed()
  }

  internal func resolvedWorkspaceURLPreservingFinalSymlink(_ path: String) throws -> URL {
    let lexicalBase = WorkspacePathResolver.lexicallyNormalized(configuration.workspaceDirectory)
    let canonicalBase: URL
    let base: URL
    do {
      canonicalBase = try WorkspacePathResolver.canonicalWorkspace(lexicalBase)
      base = try WorkspacePathResolver.resolve(".", relativeTo: lexicalBase)
    } catch {
      throw GatewayToolError.invalidArguments(
        "[policy.workspace_denied] Unable to resolve workspace root: \(lexicalBase.path)")
    }
    let isAbsolute = path.hasPrefix("/")
    let target =
      isAbsolute
      ? URL(fileURLWithPath: path)
      : base.appendingPathComponent(path)
    let standardized = WorkspacePathResolver.lexicallyNormalized(target)
    guard
      WorkspacePathResolver.contains(standardized, in: base)
        || (isAbsolute && WorkspacePathResolver.contains(standardized, in: lexicalBase))
        || (isAbsolute && WorkspacePathResolver.contains(standardized, in: canonicalBase))
    else {
      throw GatewayToolError.invalidArguments(
        "[policy.workspace_denied] Path escapes workspace: \(path)")
    }
    guard standardized.path != base.path else {
      return base
    }
    let parent: URL
    do {
      parent = try WorkspacePathResolver.resolve(
        standardized.deletingLastPathComponent().path,
        relativeTo: base
      )
    } catch {
      throw GatewayToolError.invalidArguments(
        "[policy.workspace_denied] Path escapes workspace through parent symlink: \(path)")
    }
    return parent.appendingPathComponent(standardized.lastPathComponent)
  }

  internal func isWorkspaceContained(_ url: URL) -> Bool {
    (try? WorkspacePathResolver.resolve(
      url.path,
      relativeTo: configuration.workspaceDirectory
    )) != nil
  }

  internal func workspaceRelativePath(_ url: URL) -> String {
    let base = configuration.workspaceDirectory.standardizedFileURL.resolvingSymlinksInPath().path
    let path = url.standardizedFileURL.resolvingSymlinksInPath().path
    if path == base {
      return "."
    }
    let prefix = base.hasSuffix("/") ? base : "\(base)/"
    if path.hasPrefix(prefix) {
      return String(path.dropFirst(prefix.count))
    }
    return path
  }

  internal func workspaceRelativePathPreservingSymlinks(_ url: URL) -> String {
    let base = configuration.workspaceDirectory.standardizedFileURL.resolvingSymlinksInPath().path
    let path = url.standardizedFileURL.path
    if path == base {
      return "."
    }
    let prefix = base.hasSuffix("/") ? base : "\(base)/"
    if path.hasPrefix(prefix) {
      return String(path.dropFirst(prefix.count))
    }
    return path
  }

  internal func relativePath(fromDirectoryPath rootPath: String, to url: URL) -> String {
    let path = url.standardizedFileURL.resolvingSymlinksInPath().path
    let prefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
    guard path.hasPrefix(prefix) else {
      return url.lastPathComponent
    }
    return String(path.dropFirst(prefix.count))
  }

  internal func workspaceURL(forRelativeDirectory path: String) -> URL {
    if path.isEmpty || path == "." {
      return configuration.workspaceDirectory
    }
    return configuration.workspaceDirectory.appendingPathComponent(path, isDirectory: true)
  }
}
