import Darwin
import Foundation
import Testing

@testable import ComputerMCP

struct BundledPluginsTests {
  @Test
  func productResourcesAreLocatedFromTheRunningExecutableNotCWDOrPATH() {
    let root = URL(fileURLWithPath: "/Applications/Example.app")
    let expected = root.appendingPathComponent("Contents/Resources/Plugins", isDirectory: true)
    for path in ["Contents/MacOS/Example", "Contents/Resources/computer-mcp"] {
      #expect(BundledPlugins.directory(for: root.appendingPathComponent(path)) == expected)
    }
    #expect(BundledPlugins.directory(for: nil) == nil)
    #expect(
      BundledPlugins.directory(for: URL(fileURLWithPath: "/usr/local/bin/computer-mcp")) == nil)
    #expect(
      BundledPlugins.directory(for: URL(fileURLWithPath: "/tmp/Contents/MacOS/Example")) == nil)
    #expect(BundledPlugins.load(directory: nil).packages.isEmpty)
  }

  @Test
  func inventoryIsReadOnlyAndPreservesDenyByDefaultComponentSettings() throws {
    let files = try PluginStoreFixture()
    defer { files.cleanup() }
    let package = try files.makePackage(
      directory: "Plugins/sample", text: PluginStoreFixture.manifest)
    let data = try Data(contentsOf: package.appendingPathComponent(PluginManifest.filename))
    let bundled = BundledPlugins.load(directory: package.deletingLastPathComponent())
    #expect(bundled.issues.isEmpty && bundled.packages.count == 1)
    let snapshot = try PluginHostSnapshot(state: PluginStoreSnapshot(), bundled: bundled)
    #expect(snapshot.state == PluginStoreSnapshot())
    #expect(snapshot.bundled.map(\.manifest.id) == ["test-package"])
    let settings = snapshot.settings(for: "test-package")
    #expect(!settings.enabled)
    #expect(settings.mcp == ["native": PluginMCPSettings()])
    #expect(settings.cli == ["commands": PluginCLISettings()])
    #expect(settings.skills == ["guidance": PluginSkillSettings()])
    #expect(snapshot.contributions.isEmpty && snapshot.diagnostics.isEmpty)
    let decoded = try CanonicalJSONCoding.decoder().decode(
      PluginHostSnapshot.self, from: CanonicalJSONCoding.encoder().encode(snapshot))
    #expect(
      decoded.state == snapshot.state && decoded.effectiveSettings == snapshot.effectiveSettings)
    #expect(decoded.bundled.first?.manifest == bundled.packages.first?.manifest)
    #expect(try Data(contentsOf: package.appendingPathComponent(PluginManifest.filename)) == data)
  }

  @Test
  func malformedPackagesAndDuplicateIdentitiesCannotReplaceValidSources() throws {
    let files = try PluginStoreFixture()
    defer { files.cleanup() }
    let root = files.root.appendingPathComponent("Plugins")
    _ = try files.makePackage(directory: "Plugins/a", text: PluginStoreFixture.manifest)
    _ = try files.makePackage(directory: "Plugins/b", text: PluginStoreFixture.manifest)
    _ = try files.makePackage(directory: "Plugins/broken", text: "id = 'broken'")
    _ = try files.makePackage(
      directory: "Plugins/other",
      text: PluginStoreFixture.manifest.replacingOccurrences(of: "test-package", with: "other"))
    let bundled = BundledPlugins.load(directory: root)
    #expect(bundled.packages.map(\.manifest.id) == ["other"])
    #expect(Set(bundled.issues.map(\.pluginID)) == ["test-package", "broken"])
    let snapshot = try PluginHostSnapshot(state: PluginStoreSnapshot(), bundled: bundled)
    #expect(snapshot.issues == bundled.issues)
    #expect(snapshot.state.settings.isEmpty && snapshot.state.installations.isEmpty)
  }

  @Test(arguments: ["linked-root", "linked-child", "file", "fifo", "too-many", "hidden-too-many"])
  func unsafeOrUnboundedInventoriesAreRejected(kind: String) throws {
    let files = try PluginStoreFixture()
    defer { files.cleanup() }
    let root = files.root.appendingPathComponent("Plugins")
    if kind == "linked-root" {
      try FileManager.default.createSymbolicLink(at: root, withDestinationURL: files.packageRoot)
    } else {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      let child = root.appendingPathComponent("entry")
      switch kind {
      case "linked-child":
        try FileManager.default.createSymbolicLink(at: child, withDestinationURL: files.packageRoot)
      case "file": try Data().write(to: child)
      case "fifo": #expect(mkfifo(child.path, 0o600) == 0)
      default:
        for index in 0..<129 {
          try FileManager.default.createDirectory(
            at: root.appendingPathComponent(
              kind == "hidden-too-many" ? ".p-\(index)" : "p-\(index)"),
            withIntermediateDirectories: false)
        }
      }
    }
    let bundled = BundledPlugins.load(directory: root)
    #expect(bundled.packages.isEmpty && bundled.issues.count == 1)
    #expect(bundled.issues.first?.pluginID == "bundled")
    #expect(
      FileManager.default.fileExists(
        atPath: files.packageRoot.appendingPathComponent(PluginManifest.filename).path))
  }

  @Test
  func sourceSelectionKeepsOverridesAndDoesNotFallBackOnSelectedSourceFailure() async throws {
    let files = try PluginStoreFixture()
    defer { files.cleanup() }
    let root = try files.makePackage(directory: "Plugins/base", text: PluginStoreFixture.manifest)
    let bundled = BundledPlugins.load(directory: root.deletingLastPathComponent())
    let database = try GatewayDatabase(path: files.databaseURL.path)
    let store = PluginStore(database: database)
    var settings = files.settings
    settings.mcp["native"]?.exposure = .gateway
    settings.dependencyExecutables = ["vendor": "/usr/bin/printf"]
    let enabled = try await store.setSettings(settings, for: "test-package", expectedRevision: 0)
    let before = try PluginHostSnapshot(state: enabled, bundled: bundled)
    #expect(
      before.contributions.count == 3
        && before.contributions.allSatisfy { $0.source.kind == .bundled })
    let selected = try await store.registerDevelopment(at: files.packageRoot, expectedRevision: 1)
    let id = try #require(selected.selectedInstallations["test-package"])
    #expect(
      try PluginHostSnapshot(state: selected, bundled: bundled).contributions.allSatisfy {
        $0.source.kind == .development
      })
    try "invalid".write(
      to: files.packageRoot.appendingPathComponent(PluginManifest.filename), atomically: true,
      encoding: .utf8)
    let broken = try PluginHostSnapshot(state: selected, bundled: bundled)
    #expect(broken.contributions.isEmpty && broken.issues.count == 1)
    let restored = try await store.select(
      installationID: nil, for: "test-package", expectedRevision: 2)
    let fallback = try PluginHostSnapshot(state: restored, bundled: bundled)
    #expect(fallback.state.settings["test-package"] == settings)
    #expect(fallback.contributions.count == 3 && fallback.issues.isEmpty)
    #expect(fallback.contributions.allSatisfy { $0.source.kind == .bundled })
    #expect(fallback.state.installations.map(\.id) == [id])
    let reopened = try GatewayDatabase(path: files.databaseURL.path)
    #expect(try reopened.pluginStoreSnapshot() == restored)
    let runtime = try GatewayRuntime(
      configuration: GatewayConfiguration(workspaceDirectory: files.root), database: reopened,
      bundledPlugins: bundled)
    #expect(runtime.pluginOrigins.count == 3 && runtime.pluginIssues.isEmpty)
    await runtime.shutdown()
    let disabled = try await store.setEnabled(false, for: "test-package", expectedRevision: 3)
    #expect(try PluginHostSnapshot(state: disabled, bundled: bundled).contributions.isEmpty)
  }
}
