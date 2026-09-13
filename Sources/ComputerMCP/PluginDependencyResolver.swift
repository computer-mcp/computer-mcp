import AppKit
import Foundation

/// Locates user-owned programs without launching applications or changing their installations.
package enum PluginDependencyResolver {
  struct Binding {
    let executable: URL
    let source: String
  }

  package static func applicationURL(bundleIdentifier: String) -> URL? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
  }

  static func resolve(
    for plugin: PluginPackage, settings: PluginSettings, overrides: [String: URL] = [:],
    searchDirectories: [URL],
    applicationURL: (String) -> URL? = Self.applicationURL
  ) -> [String: Binding] {
    var bindings = overrides.mapValues { Binding(executable: $0, source: "host_override") }
    let environment = ["PATH": searchDirectories.map(\.path).joined(separator: ":")]
    for dependency in plugin.manifest.dependencies where bindings[dependency.id] == nil {
      if let path = settings.dependencyExecutables[dependency.id] {
        bindings[dependency.id] = Binding(
          executable: URL(fileURLWithPath: path), source: "host_override")
        continue
      }
      if !searchDirectories.isEmpty,
        let path = dependency.commands.lazy.compactMap({
          ExecutableInspection.inspect($0, workingDirectory: plugin.root, environment: environment)
            .path
        }).first
      {
        bindings[dependency.id] = Binding(executable: URL(fileURLWithPath: path), source: "path")
        continue
      }
      for locator in dependency.applications {
        guard let application = applicationURL(locator.bundleIdentifier), application.isFileURL,
          let bundle = Bundle(url: application),
          bundle.bundleIdentifier == locator.bundleIdentifier,
          (try? WorkspacePathResolver.resolve(
            locator.executable, relativeTo: application)) != nil
        else { continue }
        bindings[dependency.id] = Binding(
          executable: application.appendingPathComponent(locator.executable),
          source: "application_bundle")
        break
      }
    }
    return bindings
  }
}
