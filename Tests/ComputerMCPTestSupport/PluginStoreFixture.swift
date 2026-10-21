import ComputerMCPCore
import ComputerMCPPlugins
import Foundation

package struct PluginStoreFixture {
  package let root: URL
  package var packageRoot: URL { root.appendingPathComponent("source") }
  package var databaseURL: URL { root.appendingPathComponent("state.sqlite") }
  package let settings = PluginSettings(
    enabled: true,
    mcp: [
      "native": .init(
        registrationID: "chosen-mcp", exposure: .reexport, prefix: "chosen",
        allowedTools: ["inspect"], toolRisks: ["inspect": .readOnly]),
      "removed-component": .init(allowAnyTool: true),
    ],
    cli: ["commands": .init(registrationID: "chosen-cli")],
    skills: ["guidance": .init(registrationID: "chosen-skills")])

  package static let manifest = PluginManifestFixture.combined.replacingOccurrences(
    of: "tree = { kind = 'introspection', args = ['schema', '--json'] }\n", with: "")

  package init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "plugin-store-\(UUID().uuidString)")
    _ = try makePackage(directory: "source", text: Self.manifest)
  }

  package func makePackage(directory: String, text: String) throws -> URL {
    let location = root.appendingPathComponent(directory)
    try FileManager.default.createDirectory(
      at: location.appendingPathComponent("skills/example"), withIntermediateDirectories: true)
    try text.write(
      to: location.appendingPathComponent(PluginManifest.filename), atomically: true,
      encoding: .utf8)
    try "---\nname: example\ndescription: Test guidance.\n---\nRead safely.\n"
      .write(
        to: location.appendingPathComponent("skills/example/SKILL.md"), atomically: true,
        encoding: .utf8)
    return location
  }

  package func resolve(_ store: PluginStore, bundled: [PluginPackage] = []) async throws
    -> PluginStoreResolution
  {
    try await store.resolve(
      bundled: bundled,
      dependencyExecutables: [
        "test-package": ["vendor": URL(fileURLWithPath: try testExecutable("printf"))]
      ],
      hostVersion: PluginVersion("1.0.29"), architecture: "arm64")
  }

  package func cleanup() { try? FileManager.default.removeItem(at: root) }
}
