import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import Foundation

/// Resolves tool paths against a configured project and projects its file metadata.
package struct ProjectScope: Sendable {
  package let projectDirectory: URL
  package let toolMeta: JSONValue?

  package init(configuration: GatewayConfiguration, toolMeta: JSONValue?) {
    self.projectDirectory = configuration.projectDirectory
    self.toolMeta = toolMeta
  }

  package func resolvedProjectURL(_ path: String) throws -> URL {
    do {
      return try ProjectPathResolver.resolve(
        path,
        relativeTo: projectDirectory
      )
    } catch {
      throw GatewayToolError.invalidArguments(
        "[policy.project_denied] Path escapes project: \(path)")
    }
  }

  package func lexicalProjectURL(_ path: String) throws -> URL {
    let base = projectDirectory.standardizedFileURL.resolvingSymlinksInPath()
    let target =
      path.hasPrefix("/")
      ? URL(fileURLWithPath: path)
      : base.appendingPathComponent(path)
    let standardized = target.standardizedFileURL
    let basePath = base.path
    let basePrefix = basePath.hasSuffix("/") ? basePath : "\(basePath)/"
    guard standardized.path == basePath || standardized.path.hasPrefix(basePrefix) else {
      throw GatewayToolError.invalidArguments(
        "[policy.project_denied] Path escapes project: \(path)")
    }
    return standardized
  }

  package func projectInstructionScopeURL(
    targetURL: URL,
    originalPath: String = ".",
    pathIsDirectory: Bool?,
    targetExists: Bool
  ) throws -> URL {
    if targetExists {
      let targetProjectRelativePath = projectRelativePathPreservingSymlinks(targetURL)
      let resolvedTarget = try resolvedProjectURL(targetProjectRelativePath)
      var isDirectory = ObjCBool(false)
      FileManager.default.fileExists(atPath: resolvedTarget.path, isDirectory: &isDirectory)
      let treatAsDirectory = pathIsDirectory ?? isDirectory.boolValue
      return treatAsDirectory ? resolvedTarget : resolvedTarget.deletingLastPathComponent()
    }

    let treatAsDirectory =
      pathIsDirectory ?? (originalPath == "." || originalPath.hasSuffix("/"))
    return treatAsDirectory ? targetURL : targetURL.deletingLastPathComponent()
  }

  package func projectInstructionScopeDirectories(scopeURL: URL) -> [URL] {
    let base = projectDirectory.standardizedFileURL.resolvingSymlinksInPath()
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

  package func resolvedProjectURLPreservingFinalSymlink(_ path: String) throws -> URL {
    let lexicalBase = ProjectPathResolver.lexicallyNormalized(projectDirectory)
    let canonicalBase: URL
    let base: URL
    do {
      canonicalBase = try ProjectPathResolver.canonicalProject(lexicalBase)
      base = try ProjectPathResolver.resolve(".", relativeTo: lexicalBase)
    } catch {
      throw GatewayToolError.invalidArguments(
        "[policy.project_denied] Unable to resolve project root: \(lexicalBase.path)")
    }
    let isAbsolute = path.hasPrefix("/")
    let target =
      isAbsolute
      ? URL(fileURLWithPath: path)
      : base.appendingPathComponent(path)
    let standardized = ProjectPathResolver.lexicallyNormalized(target)
    guard
      ProjectPathResolver.contains(standardized, in: base)
        || (isAbsolute && ProjectPathResolver.contains(standardized, in: lexicalBase))
        || (isAbsolute && ProjectPathResolver.contains(standardized, in: canonicalBase))
    else {
      throw GatewayToolError.invalidArguments(
        "[policy.project_denied] Path escapes project: \(path)")
    }
    guard standardized.path != base.path else {
      return base
    }
    let parent: URL
    do {
      parent = try ProjectPathResolver.resolve(
        standardized.deletingLastPathComponent().path,
        relativeTo: base
      )
    } catch {
      throw GatewayToolError.invalidArguments(
        "[policy.project_denied] Path escapes project through parent symlink: \(path)")
    }
    return parent.appendingPathComponent(standardized.lastPathComponent)
  }

  package func isProjectContained(_ url: URL) -> Bool {
    (try? ProjectPathResolver.resolve(
      url.path,
      relativeTo: projectDirectory
    )) != nil
  }

  package func projectRelativePath(_ url: URL) -> String {
    let base = projectDirectory.standardizedFileURL.resolvingSymlinksInPath().path
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

  package func projectRelativePathPreservingSymlinks(_ url: URL) -> String {
    let base = projectDirectory.standardizedFileURL.resolvingSymlinksInPath().path
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

  package func projectURL(forRelativeDirectory path: String) -> URL {
    if path.isEmpty || path == "." {
      return projectDirectory
    }
    return projectDirectory.appendingPathComponent(path, isDirectory: true)
  }

  package func fileInfo(url: URL) throws -> FileInfo {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let type = fileType(attributes[.type])
    let symlinkDestination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    let relativePath =
      symlinkDestination == nil
      ? projectRelativePath(url) : projectRelativePathPreservingSymlinks(url)

    return FileInfo(
      path: url.path,
      projectRelativePath: relativePath,
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
