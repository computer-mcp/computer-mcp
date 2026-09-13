import Foundation
import Testing

@testable import ComputerMCP

struct PluginStoreTests {
  @Test
  func developmentRegistrationIsDisabledUntilTheHostEnablesIt() async throws {
    let fixture = try PluginStoreFixture()
    defer { fixture.cleanup() }
    let store = PluginStore(database: try GatewayDatabase(inMemory: ()))
    let registered = try await store.registerDevelopment(
      at: fixture.packageRoot, expectedRevision: 0)
    #expect(registered.revision == 1)
    let record = try #require(registered.installations.first)
    #expect(record.source.kind == .development)
    #expect(record.source.repository == nil)
    #expect(record.source.artifactSHA256 == nil)
    #expect(record.manifestDigest.count == 64)
    #expect(registered.settings["test-package"]?.enabled == false)
    #expect(registered.settings["test-package"]?.mcp["native"] == PluginMCPSettings())
    #expect(registered.knownMCPRegistrationIDs == ["plugin-12-test-package-native"])
    #expect(try await fixture.resolve(store).plugins.isEmpty)

    let enabled = try await store.setEnabled(true, for: "test-package", expectedRevision: 1)
    let resolved = try await fixture.resolve(store)
    #expect(resolved.revision == enabled.revision)
    #expect(resolved.issues.isEmpty)
    let plugin = try #require(resolved.plugins.first)
    #expect(plugin.origins.count == 3)
    #expect(
      plugin.mcpServers.count == 1 && plugin.cliCommands.count == 1 && plugin.skillRoots.count == 1)
    #expect(!plugin.mcpServers[0].allowAnyTool && plugin.mcpServers[0].allowedTools.isEmpty)
    #expect(!plugin.cliCommands[0].allowAnyArgs)
  }

  @Test
  func reopeningTheDatabasePreservesSourceSelectionOverridesAndUnrelatedWorkspace() async throws {
    let fixture = try PluginStoreFixture()
    defer { fixture.cleanup() }
    var settings = fixture.settings
    settings.mcp["native"]?.args = ["--local-setting", "", "exact value"]
    let expected: PluginStoreSnapshot
    do {
      let database = try GatewayDatabase(path: fixture.databaseURL.path)
      try database.saveWorkspace(
        .init(id: "personal", displayName: "Personal", rootPath: fixture.root.path))
      let store = PluginStore(database: database)
      _ = try await store.registerDevelopment(at: fixture.packageRoot, expectedRevision: 0)
      expected = try await store.setSettings(
        settings, for: "test-package", expectedRevision: 1)
    }
    let reopened = try GatewayDatabase(path: fixture.databaseURL.path)
    let store = PluginStore(database: reopened)
    #expect(try await store.snapshot() == expected)
    #expect(try reopened.workspace(id: "personal")?.displayName == "Personal")
    let plugin = try #require(try await fixture.resolve(store).plugins.first)
    #expect(plugin.mcpServers[0].id == "chosen-mcp")
    #expect(plugin.mcpServers[0].allowedTools == ["inspect"])
    #expect(plugin.mcpServers[0].toolRisks == ["inspect": .readOnly])
    #expect(plugin.mcpServers[0].args == ["--local-setting", "", "exact value"])
    #expect(plugin.cliCommands[0].id == "chosen-cli")
    #expect(plugin.skillRoots[0].id == "chosen-skills")
  }

  @Test
  func independentStoresCannotOverwriteTheSameRevision() async throws {
    let fixture = try PluginStoreFixture()
    defer { fixture.cleanup() }
    let first = PluginStore(database: try GatewayDatabase(path: fixture.databaseURL.path))
    let second = PluginStore(database: try GatewayDatabase(path: fixture.databaseURL.path))
    let initial = try await first.snapshot()
    #expect(try await second.snapshot() == initial)
    let results = await withTaskGroup(of: StoreMutationOutcome.self) { group in
      for (store, id) in [(first, "first"), (second, "second")] {
        group.addTask {
          do {
            _ = try await store.setEnabled(true, for: id, expectedRevision: initial.revision)
            return .saved(id)
          } catch let error as PluginStoreError {
            return .rejected(error)
          } catch {
            return .unexpected(error.localizedDescription)
          }
        }
      }
      var values: [StoreMutationOutcome] = []
      for await value in group { values.append(value) }
      return values
    }
    let winners = results.compactMap { result -> String? in
      if case .saved(let id) = result { return id }
      return nil
    }
    #expect(winners.count == 1)
    #expect(results.contains(.rejected(.staleRevision(expected: 0, actual: 1))))
    let final = try await first.snapshot()
    #expect(final.revision == 1)
    #expect(Set(final.settings.keys) == Set(winners))
    #expect(try await second.snapshot() == final)
  }

  @Test
  func databaseRevisionComparisonRejectsAnAlreadyPreparedStaleSnapshot() throws {
    let fixture = try PluginStoreFixture()
    defer { fixture.cleanup() }
    let first = try GatewayDatabase(path: fixture.databaseURL.path)
    let second = try GatewayDatabase(path: fixture.databaseURL.path)
    var proposal = try first.pluginStoreSnapshot()
    proposal.revision = 1
    proposal.settings["first"] = PluginSettings(enabled: true)
    var competitor = try second.pluginStoreSnapshot()
    competitor.revision = 1
    competitor.settings["second"] = PluginSettings(enabled: true)
    try first.savePluginStoreSnapshot(proposal, expectedRevision: 0)
    #expect(throws: PluginStoreError.staleRevision(expected: 0, actual: 1)) {
      try second.savePluginStoreSnapshot(competitor, expectedRevision: 0)
    }
    #expect(try second.pluginStoreSnapshot() == proposal)
  }

  @Test(arguments: ["", "../plugin", "Plugin", "space id", "nul\0id"])
  func hostSettingsCannotPersistInvalidPackageIdentities(id: String) async throws {
    let store = PluginStore(database: try GatewayDatabase(inMemory: ()))
    await #expect(throws: PluginManifestError.self) {
      try await store.setEnabled(true, for: id, expectedRevision: 0)
    }
    #expect(try await store.snapshot() == PluginStoreSnapshot())
  }

  @Test
  func malformedDevelopmentPackageDoesNotChangeTheSelectionOrSettings() async throws {
    let fixture = try PluginStoreFixture()
    defer { fixture.cleanup() }
    let store = PluginStore(database: try GatewayDatabase(inMemory: ()))
    let original = try await store.registerDevelopment(at: fixture.packageRoot, expectedRevision: 0)
    let invalid = try fixture.makePackage(directory: "invalid", text: "id = 'incomplete'")
    await #expect(throws: (any Error).self) {
      try await store.registerDevelopment(at: invalid, expectedRevision: original.revision)
    }
    #expect(try await store.snapshot() == original)
  }

  @Test
  func versionsCanBeSelectedAndBundledFallbackRetainsHostChoices() async throws {
    let fixture = try PluginStoreFixture()
    defer { fixture.cleanup() }
    let store = PluginStore(database: try GatewayDatabase(inMemory: ()))
    let first = try await store.registerDevelopment(at: fixture.packageRoot, expectedRevision: 0)
    let firstID = try #require(first.selectedInstallations["test-package"])
    _ = try await store.setSettings(fixture.settings, for: "test-package", expectedRevision: 1)
    let newerRoot = try fixture.makePackage(
      directory: "newer",
      text: PluginStoreFixture.manifest.replacingOccurrences(of: "1.2.3", with: "1.3.0"))
    let newer = try await store.registerDevelopment(at: newerRoot, expectedRevision: 2)
    let newerID = try #require(newer.selectedInstallations["test-package"])
    #expect(newerID != firstID)
    #expect(newer.installations.count == 2)
    #expect(newer.settings["test-package"] == fixture.settings)
    #expect(
      try await fixture.resolve(store).plugins.first?.origins.values.first?.version
        == PluginVersion("1.3.0"))

    _ = try await store.select(installationID: firstID, for: "test-package", expectedRevision: 3)
    #expect(
      try await fixture.resolve(store).plugins.first?.origins.values.first?.version
        == PluginVersion("1.2.3"))
    let bundledRoot = try fixture.makePackage(
      directory: "bundled", text: PluginStoreFixture.manifest)
    let bundled = try PluginPackage.load(at: bundledRoot)
    _ = try await store.select(installationID: nil, for: "test-package", expectedRevision: 4)
    let fallback = try #require(try await fixture.resolve(store, bundled: [bundled]).plugins.first)
    #expect(fallback.origins.count == 3)
    #expect(fallback.origins.values.allSatisfy { $0.source.kind == .bundled })
    #expect(fallback.mcpServers[0].id == "chosen-mcp")
    #expect(fallback.mcpServers[0].allowedTools == ["inspect"])
    let disabled = try await store.setEnabled(false, for: "test-package", expectedRevision: 5)
    #expect(disabled.settings["test-package"]?.mcp == fixture.settings.mcp)
    #expect(try await fixture.resolve(store, bundled: [bundled]).plugins.isEmpty)
  }

  @Test
  func changedDevelopmentDeclarationRequiresExplicitRefreshAndNeverSilentlyFallsBack() async throws
  {
    let fixture = try PluginStoreFixture()
    defer { fixture.cleanup() }
    let store = PluginStore(database: try GatewayDatabase(inMemory: ()))
    _ = try await store.registerDevelopment(at: fixture.packageRoot, expectedRevision: 0)
    _ = try await store.setSettings(fixture.settings, for: "test-package", expectedRevision: 1)
    let bundledRoot = try fixture.makePackage(
      directory: "bundled", text: PluginStoreFixture.manifest)
    let bundled = try PluginPackage.load(at: bundledRoot)
    try PluginStoreFixture.manifest.replacingOccurrences(
      of: "args = ['mcp']", with: "args = ['different']"
    )
    .write(
      to: fixture.packageRoot.appendingPathComponent(PluginManifest.filename), atomically: true,
      encoding: .utf8)
    let rejected = try await fixture.resolve(store, bundled: [bundled])
    #expect(rejected.plugins.isEmpty)
    #expect(rejected.issues.count == 1)
    #expect(
      rejected.issues[0].message
        == PluginStoreError.manifestChanged("test-package").localizedDescription)
    let refreshed = try await store.registerDevelopment(
      at: fixture.packageRoot, expectedRevision: 2)
    #expect(refreshed.settings["test-package"] == fixture.settings)
    #expect(try await fixture.resolve(store).plugins.first?.mcpServers.first?.args == ["different"])
    let oldID = refreshed.installations[0].id
    _ = try await store.select(installationID: oldID, for: "test-package", expectedRevision: 3)
    #expect(try await fixture.resolve(store).issues.count == 1)
  }

  @Test
  func repeatedRegistrationReusesTheRecordAndRemovalOnlyWithdrawsItsReferences() async throws {
    let fixture = try PluginStoreFixture()
    defer { fixture.cleanup() }
    let store = PluginStore(database: try GatewayDatabase(inMemory: ()))
    let original = try await store.registerDevelopment(at: fixture.packageRoot, expectedRevision: 0)
    let repeated = try await store.registerDevelopment(at: fixture.packageRoot, expectedRevision: 1)
    #expect(original.installations == repeated.installations)
    _ = try await store.setSettings(fixture.settings, for: "test-package", expectedRevision: 2)
    let record = try #require(repeated.installations.first)
    let removed = try await store.removeDevelopment(installationID: record.id, expectedRevision: 3)
    #expect(removed.installations.isEmpty && removed.selectedInstallations.isEmpty)
    #expect(removed.settings["test-package"] == fixture.settings)
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.packageRoot.appendingPathComponent("skills/example/SKILL.md").path))
    #expect(FileManager.default.isExecutableFile(atPath: "/usr/bin/printf"))
    let resolution = try await fixture.resolve(store)
    #expect(resolution.plugins.isEmpty)
    #expect(resolution.issues.map(\.pluginID) == ["test-package"])
  }

  @Test
  func missingSelectedPackageIsIsolatedFromAnotherEnabledPackage() async throws {
    let fixture = try PluginStoreFixture()
    defer { fixture.cleanup() }
    let store = PluginStore(database: try GatewayDatabase(inMemory: ()))
    _ = try await store.registerDevelopment(at: fixture.packageRoot, expectedRevision: 0)
    _ = try await store.setEnabled(true, for: "test-package", expectedRevision: 1)
    let otherRoot = try fixture.makePackage(
      directory: "other",
      text: PluginStoreFixture.manifest.replacingOccurrences(
        of: "id = 'test-package'", with: "id = 'other'"))
    let bundled = try PluginPackage.load(at: otherRoot)
    _ = try await store.setEnabled(true, for: "other", expectedRevision: 2)
    try FileManager.default.moveItem(
      at: fixture.packageRoot, to: fixture.root.appendingPathComponent("moved"))
    let result = try await fixture.resolve(store, bundled: [bundled])
    #expect(result.plugins.map(\.id) == ["other"])
    #expect(result.issues.map(\.pluginID) == ["test-package"])
  }

  @Test
  func invalidOrOversizedSettingsAndStaleWritesLeaveTheDatabaseUnchanged() async throws {
    let fixture = try PluginStoreFixture()
    defer { fixture.cleanup() }
    let database = try GatewayDatabase(inMemory: ())
    let store = PluginStore(database: database)
    let initial = try await store.setSettings(
      fixture.settings, for: "test-package", expectedRevision: 0)
    var invalid = fixture.settings
    invalid.mcp["native"]?.allowAnyTool = true
    await #expect(throws: ConfigurationError.self) {
      try await store.setSettings(invalid, for: "test-package", expectedRevision: 1)
    }
    var huge = fixture.settings
    huge.mcp["native"]?.allowedTools = [String(repeating: "a", count: 4_194_304)]
    await #expect(throws: PluginStoreError.invalidState) {
      try await store.setSettings(huge, for: "test-package", expectedRevision: 1)
    }
    await #expect(throws: PluginStoreError.staleRevision(expected: 0, actual: 1)) {
      try await store.setEnabled(false, for: "test-package", expectedRevision: 0)
    }
    var forged = initial
    forged.revision = 2
    forged.selectedInstallations["test-package"] = "nonexistent"
    #expect(throws: PluginStoreError.invalidState) {
      try database.savePluginStoreSnapshot(forged, expectedRevision: 1)
    }
    #expect(try await store.snapshot() == initial)
  }

  @Test
  func selectionCannotBorrowAnotherPluginsInstallation() async throws {
    let fixture = try PluginStoreFixture()
    defer { fixture.cleanup() }
    let store = PluginStore(database: try GatewayDatabase(inMemory: ()))
    let initial = try await store.registerDevelopment(at: fixture.packageRoot, expectedRevision: 0)
    let id = try #require(initial.installations.first?.id)
    await #expect(throws: PluginStoreError.unknownInstallation(id)) {
      try await store.select(installationID: id, for: "different", expectedRevision: 1)
    }
    #expect(try await store.snapshot() == initial)
  }
}

private enum StoreMutationOutcome: Equatable, Sendable {
  case saved(String)
  case rejected(PluginStoreError)
  case unexpected(String)
}

struct PluginStoreFixture {
  let root: URL
  var packageRoot: URL { root.appendingPathComponent("source") }
  var databaseURL: URL { root.appendingPathComponent("state.sqlite") }
  let settings = PluginSettings(
    enabled: true,
    mcp: [
      "native": .init(
        registrationID: "chosen-mcp", exposure: .reexport, prefix: "chosen",
        allowedTools: ["inspect"], toolRisks: ["inspect": .readOnly]),
      "removed-component": .init(allowAnyTool: true),
    ],
    cli: ["commands": .init(registrationID: "chosen-cli")],
    skills: ["guidance": .init(registrationID: "chosen-skills")])

  static let manifest = PluginManifestTests.combined.replacingOccurrences(
    of: "tree = { kind = 'introspection', args = ['schema', '--json'] }\n", with: "")

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "plugin-store-\(UUID().uuidString)")
    _ = try makePackage(directory: "source", text: Self.manifest)
  }

  func makePackage(directory: String, text: String) throws -> URL {
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

  func resolve(_ store: PluginStore, bundled: [PluginPackage] = []) async throws
    -> PluginStoreResolution
  {
    try await store.resolve(
      bundled: bundled,
      dependencyExecutables: ["test-package": ["vendor": URL(fileURLWithPath: "/usr/bin/printf")]],
      hostVersion: PluginVersion("1.0.29"), architecture: "arm64")
  }

  func cleanup() { try? FileManager.default.removeItem(at: root) }
}
