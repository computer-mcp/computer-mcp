import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import Foundation

/// Resolves tool paths against a configured workspace and projects its file metadata.
package struct WorkspaceScope: Sendable {
  package let workspaceDirectory: URL
  package let toolMeta: JSONValue?

  package init(configuration: GatewayConfiguration, toolMeta: JSONValue?) {
    self.workspaceDirectory = configuration.workspaceDirectory
    self.toolMeta = toolMeta
  }

  package func resolvedWorkspaceURL(_ path: String) throws -> URL {
    do {
      return try WorkspacePathResolver.resolve(
        path,
        relativeTo: workspaceDirectory
      )
    } catch {
      throw GatewayToolError.invalidArguments(
        "[policy.workspace_denied] Path escapes workspace: \(path)")
    }
  }

  package func lexicalWorkspaceURL(_ path: String) throws -> URL {
    let base = workspaceDirectory.standardizedFileURL.resolvingSymlinksInPath()
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

  package func workspaceInstructionScopeURL(
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

  package func workspaceInstructionScopeDirectories(scopeURL: URL) -> [URL] {
    let base = workspaceDirectory.standardizedFileURL.resolvingSymlinksInPath()
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

  package func resolvedWorkspaceURLPreservingFinalSymlink(_ path: String) throws -> URL {
    let lexicalBase = WorkspacePathResolver.lexicallyNormalized(workspaceDirectory)
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

  package func isWorkspaceContained(_ url: URL) -> Bool {
    (try? WorkspacePathResolver.resolve(
      url.path,
      relativeTo: workspaceDirectory
    )) != nil
  }

  package func workspaceRelativePath(_ url: URL) -> String {
    let base = workspaceDirectory.standardizedFileURL.resolvingSymlinksInPath().path
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

  package func workspaceRelativePathPreservingSymlinks(_ url: URL) -> String {
    let base = workspaceDirectory.standardizedFileURL.resolvingSymlinksInPath().path
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

  package func workspaceURL(forRelativeDirectory path: String) -> URL {
    if path.isEmpty || path == "." {
      return workspaceDirectory
    }
    return workspaceDirectory.appendingPathComponent(path, isDirectory: true)
  }

  package func fileInfo(url: URL) throws -> FileInfo {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let type = fileType(attributes[.type])
    let symlinkDestination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    let relativePath =
      symlinkDestination == nil
      ? workspaceRelativePath(url) : workspaceRelativePathPreservingSymlinks(url)

    return FileInfo(
      path: url.path,
      workspaceRelativePath: relativePath,
      type: symlinkDestination == nil ? type : "symlink",
      size: (attributes[.size] as? NSNumber)?.int64Value,
      createdAt: attributes[.creationDate] as? Date,
      modifiedAt: attributes[.modificationDate] as? Date,
      isReadable: FileManager.default.isReadableFile(atPath: url.path),
      isWritable: FileManager.default.isWritableFile(atPath: url.path),
      isExecutable: FileManager.default.isExecutableFile(atPath: url.path),
      isSymlink: symlinkDestination != nil,
      symlinkDestination: symlinkDestination
    )
  }
}
