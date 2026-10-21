import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import Foundation

/// A validated package directory; loading never executes helpers or dependency installers.
package struct PluginPackage: Equatable, Sendable {
  package let root: URL
  package let manifest: PluginManifest

  package static func load(at root: URL) throws -> PluginPackage {
    do {
      let files = try PackageFiles(root: root)
      let data = try files.read(PluginManifest.filename, maximumBytes: 1_048_576)
      guard let text = String(data: data, encoding: .utf8) else {
        throw PluginManifestError.invalid("Manifest must be UTF-8.")
      }
      let manifest = try PluginManifest.parse(text)
      for executable in manifest.mcp.compactMap(\.executable) + manifest.cli.map(\.executable)
        + manifest.cli.compactMap({ $0.tree?.helper })
      {
        if let path = try executable.packagePath() { try files.validate(path, kind: .executable) }
      }
      for cwd in manifest.mcp.compactMap(\.cwd) + manifest.cli.compactMap(\.cwd) {
        try files.validate(cwd, kind: .directory)
      }
      for path in manifest.cli.compactMap({ $0.tree?.path }) {
        try files.validate(path, kind: .file)
      }
      for skill in manifest.skills { try files.validate(skill.path, kind: .directory) }
      return PluginPackage(root: files.root, manifest: manifest)
    } catch PackageFileError.invalid(let reason) {
      throw PluginManifestError.invalid(reason)
    }
  }
}
