import ComputerMCPPlatform
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

package enum PackageFileError: Error, Equatable, LocalizedError, Sendable {
  case invalid(String)

  package var errorDescription: String? {
    switch self {
    case .invalid(let reason): "Invalid plugin package: \(reason)"
    }
  }
}

/// Reuses workspace canonicalization, then opens each component without following new symlinks.
/// The descriptors anchor reads if a mutable development checkout is renamed during inspection.
package struct PackageFiles {
  package enum Kind { case file, executable, directory }
  package let root: URL

  package init(root: URL) throws {
    guard root.isFileURL else {
      throw PackageFileError.invalid("Package root must be a file URL.")
    }
    self.root = try WorkspacePathResolver.canonicalWorkspace(root)
  }

  package func read(_ path: String, maximumBytes: Int) throws -> Data {
    guard maximumBytes >= 0, maximumBytes < Int.max else {
      throw PackageFileError.invalid("Invalid package read limit.")
    }
    return try withFile(path, kind: .file) { descriptor, status in
      guard status.st_size <= maximumBytes else {
        throw PackageFileError.invalid("Package file exceeds its read limit: \(path).")
      }
      var result = Data()
      var buffer = [UInt8](repeating: 0, count: 16_384)
      while true {
        let available = min(buffer.count, maximumBytes - result.count + 1)
        let count = buffer.withUnsafeMutableBytes {
          #if canImport(Darwin)
            Darwin.read(descriptor, $0.baseAddress, available)
          #elseif canImport(Glibc)
            Glibc.read(descriptor, $0.baseAddress, available)
          #elseif canImport(Musl)
            Musl.read(descriptor, $0.baseAddress, available)
          #endif
        }
        if count < 0 {
          if errno == EINTR { continue }
          throw PackageFileError.invalid("Cannot read package file: \(path).")
        }
        if count == 0 { return result }
        guard count <= maximumBytes - result.count else {
          throw PackageFileError.invalid("Package file exceeds its read limit: \(path).")
        }
        result.append(contentsOf: buffer.prefix(count))
      }
    }
  }

  package func validate(_ path: String, kind: Kind) throws {
    try withFile(path, kind: kind) { _, _ in }
  }

  private func withFile<Result>(_ path: String, kind: Kind, body: (Int32, stat) throws -> Result)
    throws -> Result
  {
    guard PluginExecutablePaths.isNormalizedRelativePath(path) else {
      throw PackageFileError.invalid("Package paths must be normalized relative paths.")
    }
    let target = try WorkspacePathResolver.resolve(path, relativeTo: root)
    let canonicalTarget = try WorkspacePathResolver.canonicalWorkspace(target)
    guard WorkspacePathResolver.contains(canonicalTarget, in: root), canonicalTarget != root else {
      throw PackageFileError.invalid("Package path escapes its root: \(path).")
    }
    let parts = canonicalTarget.pathComponents.dropFirst(root.pathComponents.count)
    var descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw PackageFileError.invalid("Cannot open package root.") }
    defer { close(descriptor) }
    for (index, component) in parts.enumerated() {
      let last = index == parts.count - 1
      let flags =
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        | ((!last || kind == .directory) ? O_DIRECTORY : 0)
      let child = openat(descriptor, component, flags)
      guard child >= 0 else {
        throw PackageFileError.invalid("Cannot safely open package path: \(path).")
      }
      close(descriptor)
      descriptor = child
    }
    var status = stat()
    guard fstat(descriptor, &status) == 0 else {
      throw PackageFileError.invalid("Cannot inspect package path: \(path).")
    }
    let type = status.st_mode & S_IFMT
    guard kind == .directory ? type == S_IFDIR : type == S_IFREG else {
      throw PackageFileError.invalid("Unexpected package file type: \(path).")
    }
    if kind == .executable, status.st_mode & 0o111 == 0 {
      throw PackageFileError.invalid("Package helper is not executable: \(path).")
    }
    return try body(descriptor, status)
  }
}
