import Darwin
import Foundation

/// Read-only package inventory from the running product, separate from user installations and grants.
package struct BundledPlugins: Sendable {
  package let packages: [PluginPackage]
  package let issues: [PluginStoreIssue]

  package static var current: Self {
    load(directory: directory(for: Bundle.main.executableURL))
  }

  /// Both the App and its embedded CLI resolve the same resource directory. A standalone CLI has none.
  static func directory(for executable: URL?) -> URL? {
    guard let executable, executable.isFileURL else { return nil }
    let parent = executable.resolvingSymlinksInPath().deletingLastPathComponent()
    let contents = parent.deletingLastPathComponent()
    guard ["MacOS", "Resources"].contains(parent.lastPathComponent),
      contents.lastPathComponent == "Contents",
      contents.deletingLastPathComponent().pathExtension == "app"
    else { return nil }
    return contents.appendingPathComponent("Resources/Plugins", isDirectory: true)
  }

  package static func load(directory: URL?) -> Self {
    guard let directory else { return Self(packages: [], issues: []) }
    do {
      let names = try children(of: directory)
      let root = directory.resolvingSymlinksInPath().standardizedFileURL
      var packages: [PluginPackage] = []
      var issues: [PluginStoreIssue] = []
      for name in names {
        do {
          let package = try PluginPackage.load(at: directory.appendingPathComponent(name))
          guard package.root.deletingLastPathComponent().standardizedFileURL == root else {
            throw PluginManifestError.invalid("Bundled package escapes the resource directory.")
          }
          packages.append(package)
        } catch {
          issues.append(.init(pluginID: name, message: error.localizedDescription))
        }
      }
      let duplicates = Dictionary(grouping: packages, by: { $0.manifest.id })
        .filter { $0.value.count > 1 }.keys.sorted()
      for id in duplicates {
        issues.append(
          .init(pluginID: id, message: "Multiple bundled sources have the same plugin ID."))
      }
      let duplicateIDs = Set(duplicates)
      return Self(
        packages: packages.filter { !duplicateIDs.contains($0.manifest.id) }
          .sorted { $0.manifest.id < $1.manifest.id },
        issues: issues)
    } catch {
      return Self(
        packages: [], issues: [.init(pluginID: "bundled", message: error.localizedDescription)])
    }
  }

  private static func children(of root: URL) throws -> [String] {
    guard root.isFileURL, !root.path.contains("\0"), root.query == nil, root.fragment == nil,
      root.host.map({ $0.isEmpty || $0 == "localhost" }) != false
    else { throw PluginManifestError.invalid("Invalid bundled resource directory.") }
    let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      if errno == ENOENT { return [] }
      throw PluginManifestError.invalid("Cannot safely open bundled resource directory.")
    }
    guard let stream = fdopendir(descriptor) else {
      close(descriptor)
      throw PluginManifestError.invalid("Cannot inspect bundled resource directory.")
    }
    defer { closedir(stream) }
    var names: [String] = []
    var inspectedEntries = 0
    while true {
      errno = 0
      guard let entry = readdir(stream) else {
        guard errno == 0 else {
          throw PluginManifestError.invalid("Cannot read bundled resource directory.")
        }
        break
      }
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
          String(validatingCString: $0)
        }
      }
      guard let name else {
        throw PluginManifestError.invalid("Bundled package name is not UTF-8.")
      }
      if name == "." || name == ".." { continue }
      guard inspectedEntries < 128 else {
        throw PluginManifestError.invalid("Bundled inventory exceeds 128 packages.")
      }
      inspectedEntries += 1
      if name.hasPrefix(".") { continue }
      var status = stat()
      guard fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0,
        status.st_mode & S_IFMT == S_IFDIR
      else {
        throw PluginManifestError.invalid(
          "Bundled entries must be directories, not links or files.")
      }
      names.append(name)
    }
    return names.sorted()
  }
}

/// An output-only description; decoding it does not register a source or grant access.
package struct BundledPluginDescription: Codable, Sendable {
  package let root: URL
  package let manifest: PluginManifest
}

extension PluginStoreSnapshot {
  /// Missing component settings use deny-by-default host values, never manifest recommendations.
  func includingBundledDefaults(_ manifests: [PluginManifest]) -> Self {
    var result = self
    for manifest in manifests where selectedInstallations[manifest.id] == nil {
      PluginStore.addMissingSettings(for: manifest, to: &result)
    }
    return result
  }
}
