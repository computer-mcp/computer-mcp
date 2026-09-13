import Darwin
import Foundation

/// A validated package directory; loading never executes helpers or dependency installers.
package struct PluginPackage: Equatable, Sendable {
  package let root: URL
  package let manifest: PluginManifest

  package static func load(at root: URL) throws -> PluginPackage {
    let files = try PluginPackageFiles(root: root)
    let data = try files.read(PluginManifest.filename, maximumBytes: 1_048_576)
    guard let text = String(data: data, encoding: .utf8) else {
      throw PluginManifestError.invalid("Manifest must be UTF-8.")
    }
    let manifest = try PluginManifest.parse(text)
    for executable in manifest.mcp.compactMap(\.executable) + manifest.cli.map(\.executable)
      + manifest.cli.compactMap({ $0.tree?.helper })
    {
      if let path = executable.path { try files.validate(path, kind: .executable) }
    }
    for cwd in manifest.mcp.compactMap(\.cwd) + manifest.cli.compactMap(\.cwd) {
      try files.validate(cwd, kind: .directory)
    }
    for path in manifest.cli.compactMap({ $0.tree?.path }) {
      try files.validate(path, kind: .file)
    }
    for skill in manifest.skills { try files.validate(skill.path, kind: .directory) }
    return PluginPackage(root: files.root, manifest: manifest)
  }
}

/// Reuses workspace canonicalization, then opens each component without following new symlinks.
/// The descriptors anchor reads if a mutable development checkout is renamed during inspection.
struct PluginPackageFiles {
  enum Kind { case file, executable, directory }
  let root: URL

  init(root: URL) throws {
    guard root.isFileURL else {
      throw PluginManifestError.invalid("Package root must be a file URL.")
    }
    self.root = try WorkspacePathResolver.canonicalWorkspace(root)
  }

  func read(_ path: String, maximumBytes: Int) throws -> Data {
    guard maximumBytes >= 0, maximumBytes < Int.max else {
      throw PluginManifestError.invalid("Invalid package read limit.")
    }
    return try withFile(path, kind: .file) { descriptor, status in
      guard status.st_size <= maximumBytes else {
        throw PluginManifestError.invalid("Package file exceeds its read limit: \(path).")
      }
      var result = Data()
      var buffer = [UInt8](repeating: 0, count: 16_384)
      while true {
        let available = min(buffer.count, maximumBytes - result.count + 1)
        let count = buffer.withUnsafeMutableBytes {
          Darwin.read(descriptor, $0.baseAddress, available)
        }
        if count < 0 {
          if errno == EINTR { continue }
          throw PluginManifestError.invalid("Cannot read package file: \(path).")
        }
        if count == 0 { return result }
        guard count <= maximumBytes - result.count else {
          throw PluginManifestError.invalid("Package file exceeds its read limit: \(path).")
        }
        result.append(contentsOf: buffer.prefix(count))
      }
    }
  }

  func validate(_ path: String, kind: Kind) throws {
    try withFile(path, kind: kind) { _, _ in }
  }

  private func withFile<Result>(_ path: String, kind: Kind, body: (Int32, stat) throws -> Result)
    throws -> Result
  {
    try validatePluginRelativePath(path)
    let target = try WorkspacePathResolver.resolve(path, relativeTo: root)
    let canonicalTarget = try WorkspacePathResolver.canonicalWorkspace(target)
    guard WorkspacePathResolver.contains(canonicalTarget, in: root), canonicalTarget != root else {
      throw PluginManifestError.invalid("Package path escapes its root: \(path).")
    }
    let parts = canonicalTarget.pathComponents.dropFirst(root.pathComponents.count)
    var descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw PluginManifestError.invalid("Cannot open package root.") }
    defer { Darwin.close(descriptor) }
    for (index, component) in parts.enumerated() {
      let last = index == parts.count - 1
      let flags =
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        | ((!last || kind == .directory) ? O_DIRECTORY : 0)
      let child = openat(descriptor, component, flags)
      guard child >= 0 else {
        throw PluginManifestError.invalid("Cannot safely open package path: \(path).")
      }
      Darwin.close(descriptor)
      descriptor = child
    }
    var status = stat()
    guard fstat(descriptor, &status) == 0 else {
      throw PluginManifestError.invalid("Cannot inspect package path: \(path).")
    }
    let type = status.st_mode & S_IFMT
    guard kind == .directory ? type == S_IFDIR : type == S_IFREG else {
      throw PluginManifestError.invalid("Unexpected package file type: \(path).")
    }
    if kind == .executable, status.st_mode & 0o111 == 0 {
      throw PluginManifestError.invalid("Package helper is not executable: \(path).")
    }
    return try body(descriptor, status)
  }
}
