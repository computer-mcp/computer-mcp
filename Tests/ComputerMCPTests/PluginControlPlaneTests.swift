import CryptoKit
import Foundation
import MCP
import Testing

@testable import ComputerMCP

@Suite(.timeLimit(.minutes(1)))
struct PluginControlPlaneTests {
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["COMPUTER_MCP_CODEX_PLUGIN_ARCHIVE"] != nil))
  func installedCodexPackageCompletesWorkflowAndUninstallsThroughOwnerCLI() async throws {
    let environment = ProcessInfo.processInfo.environment
    let archive = URL(
      fileURLWithPath: try #require(environment["COMPUTER_MCP_CODEX_PLUGIN_ARCHIVE"]))
    let driver = try #require(environment["COMPUTER_MCP_CODEX_WORKFLOW_DRIVER"])
    let codex = try #require(environment["COMPUTER_MCP_CODEX_EXECUTABLE"])
    let version = try #require(environment["COMPUTER_MCP_CODEX_PLUGIN_VERSION"])
    let defaultExecutable = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent(".build/debug/computer-mcp")
    let executable =
      environment["COMPUTER_MCP_TEST_GATEWAY_EXECUTABLE"].map {
        URL(fileURLWithPath: $0)
      } ?? defaultExecutable
    let digest = SHA256.hash(data: try Data(contentsOf: archive))
      .map { String(format: "%02x", $0) }.joined()
    let fixture = try PluginControlFixture(worker: executable.path, cliExecutable: executable)
    defer { fixture.remove() }
    try fixture.database.saveWorkspace(
      .init(id: "workflow-fixture", displayName: "Disposable workflow", rootPath: fixture.root.path)
    )
    try fixture.database.saveProfile(
      .init(
        id: .localAdmin, capabilityIDs: ["mcp.tools.call"], workspaceIDs: ["workflow-fixture"],
        allowedCallers: [.localCLI], mode: .workspaceOperations, confirmationPolicy: .never))
    try await fixture.socket.start()
    do {
      let installed = try await fixture.cli([
        "install", archive.path, "--id", "codex", "--version", version, "--sha256", digest,
        "--expected-revision", "0",
      ])
      try #require(installed.exitCode == 0, "\(installed.stdout)\n\(installed.stderr)")
      let snapshot = try CanonicalJSONCoding.decoder().decode(
        PluginHostSnapshot.self, from: Data(installed.stdout.utf8))
      let record = try #require(snapshot.state.installations.first)
      #expect(record.version == (try PluginVersion(version)))
      #expect(!snapshot.settings(for: "codex").enabled && snapshot.contributions.isEmpty)
      #expect(record.source.kind == .artifact && record.source.artifactSHA256 == digest)
      let adapter = record.source.root.appendingPathComponent("bin/codex-mcp-adapter")
      let workflow = try await BlockingOperationExecutor(label: "installed-codex-workflow").perform
      {
        try ProcessCommandRunner().run(
          executable: "/usr/bin/python3",
          arguments: [
            driver, "--adapter", adapter.path, "--codex", codex, "--gateway", executable.path,
            "--database", fixture.directories.database.path,
            "--control-socket", fixture.directories.controlSocket.path,
            "--workspace", fixture.root.path,
          ], workingDirectory: fixture.root, environment: ["PATH": "/usr/bin:/bin"],
          timeoutMilliseconds: 50_000, maxOutputBytes: 1_048_576)
      }
      try #require(workflow.exitCode == 0, "\(workflow.stdout)\n\(workflow.stderr)")
      let receipt = try JSONDecoder().decode(JSONValue.self, from: Data(workflow.stdout.utf8))
      #expect(receipt.objectValue?["northbound"] == .string("installed-plugin-gateway"))
      #expect(receipt.objectValue?["native_approvals"] == .number(1))
      #expect(receipt.objectValue?["private_state_removed"] == .bool(true))
      print("Installed Codex workflow receipt: \(workflow.stdout)")
      let active = try fixture.database.pluginStoreSnapshot()
      try #require(active.revision == 2 && active.settings["codex"]?.enabled == true)
      let launchArguments = try #require(active.settings["codex"]?.mcp["app-server"]?.args)
      #expect(launchArguments.count == 4)
      #expect(launchArguments.first == "--config")
      #expect(launchArguments.dropFirst(2).first == "--state-directory")
      #expect(
        try fixture.database.auditEvents(limit: 200).contains {
          $0.capabilityID == "adapter.codex.app.turn.start" && $0.decision == .allowed
        })
      let disabled = try await fixture.cli(["disable", "codex", "--expected-revision", "2"])
      try #require(disabled.exitCode == 0, "\(disabled.stdout)\n\(disabled.stderr)")
      let retainedSettings = try fixture.database.pluginStoreSnapshot().settings["codex"]
      #expect(try await fixture.host.pluginSnapshot().contributions.isEmpty)
      let removed = try await fixture.cli(["uninstall", record.id, "--expected-revision", "3"])
      try #require(removed.exitCode == 0, "\(removed.stdout)\n\(removed.stderr)")
      let final = try fixture.database.pluginStoreSnapshot()
      #expect(final.installations.isEmpty && final.revision == 4)
      #expect(final.settings["codex"] == retainedSettings)
      #expect(try fixture.database.pluginOwnedDirectories().isEmpty)
      #expect(!FileManager.default.fileExists(atPath: record.source.root.path))
      #expect(FileManager.default.isExecutableFile(atPath: codex))
      #expect(
        SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
          == digest)
    } catch {
      await fixture.socket.stop()
      throw error
    }
    await fixture.socket.stop()
  }

  @Test
  func doctorChecksDisabledPackagesThroughOwnerCLIWithoutChangingHostState() async throws {
    let files = try PluginStoreFixture()
    defer { files.cleanup() }
    let root = try files.makePackage(directory: "Plugins/base", text: PluginStoreFixture.manifest)
    let bundled = BundledPlugins.load(directory: root.deletingLastPathComponent())
    let fixture = try PluginControlFixture(bundled: bundled)
    defer { fixture.remove() }
    try await fixture.socket.start()
    do {
      let missing = try await fixture.cli(["doctor", "test-package"])
      #expect(missing.exitCode == 1, "\(missing.stdout)\n\(missing.stderr)")
      let failed = try CanonicalJSONCoding.decoder().decode(
        PluginDoctorReport.self, from: Data(missing.stdout.utf8))
      #expect(failed.status == .failed && !failed.enabled && failed.revision == 0)
      #expect(failed.checks.filter { $0.dependencyID == "vendor" }.count == 2)
      #expect(failed.dependencies.first?.resolutionSource == "unresolved")
      #expect(try fixture.database.pluginStoreSnapshot() == PluginStoreSnapshot())

      let configured = try await fixture.gateway.changePlugins(
        .settings(
          pluginID: "test-package",
          .init(enabled: false, dependencyExecutables: ["vendor": "/usr/bin/printf"])),
        expectedRevision: 0)
      let checked = try await fixture.cli(["doctor", "test-package"])
      #expect(checked.exitCode == 0, "\(checked.stdout)\n\(checked.stderr)")
      let report = try CanonicalJSONCoding.decoder().decode(
        PluginDoctorReport.self, from: Data(checked.stdout.utf8))
      #expect(report.status == .passed && !report.enabled && report.revision == 1)
      #expect(report.scope == "configuration_and_files")
      #expect(report.notChecked.contains("connection"))
      #expect(report.dependencies.first?.executable == "/usr/bin/printf")
      #expect(report.checks.compactMap(\.enabled).allSatisfy { !$0 })

      let unknown = try await fixture.cli(["doctor", "unknown"])
      #expect(unknown.exitCode == 1)
      let error = try JSONDecoder().decode(JSONValue.self, from: Data(unknown.stdout.utf8))
      #expect(error.objectValue?["error"]?.objectValue?["code"] != nil)
      let state = try fixture.database.pluginStoreSnapshot()
      #expect(state == configured.state && state.installations.isEmpty)
      #expect(try fixture.database.pluginOwnedDirectories().isEmpty)
      #expect(try await fixture.host.pluginSnapshot().contributions.isEmpty)
      let events = try fixture.database.auditEvents(limit: 20)
      #expect(
        events.contains {
          $0.capabilityID == "plugin.doctor" && $0.caller == .localCLI && $0.decision == .allowed
        })
    } catch {
      await fixture.socket.stop()
      throw error
    }
    await fixture.socket.stop()
  }

  @Test
  func bundledInventoryAndHostGrantsShareTheRealOwnerCLIWithoutInstallationRecords() async throws {
    let files = try PluginStoreFixture()
    defer { files.cleanup() }
    let root = try files.makePackage(directory: "Plugins/base", text: PluginStoreFixture.manifest)
    _ = try files.makePackage(
      directory: "Plugins/other",
      text: PluginStoreFixture.manifest.replacingOccurrences(of: "test-package", with: "other"))
    let manifestURL = root.appendingPathComponent(PluginManifest.filename)
    let original = try Data(contentsOf: manifestURL)
    let bundled = BundledPlugins.load(directory: root.deletingLastPathComponent())
    let fixture = try PluginControlFixture(bundled: bundled)
    defer { fixture.remove() }
    try await fixture.socket.start()
    do {
      let listed = try await fixture.cli(["list"])
      #expect(listed.exitCode == 0, "\(listed.stdout)\n\(listed.stderr)")
      let inventory = try CanonicalJSONCoding.decoder().decode(
        PluginHostSnapshot.self, from: Data(listed.stdout.utf8))
      #expect(inventory.bundled.map(\.manifest.id) == ["other", "test-package"])
      #expect(inventory.state == PluginStoreSnapshot())
      #expect(inventory.settings(for: "test-package").mcp["native"] == PluginMCPSettings())
      let shown = try await fixture.cli(["show", "test-package"])
      #expect(shown.exitCode == 0, "\(shown.stdout)\n\(shown.stderr)")
      let detail = try CanonicalJSONCoding.decoder().decode(
        PluginHostSnapshot.self, from: Data(shown.stdout.utf8))
      #expect(detail.bundled.map(\.manifest.id) == ["test-package"])
      #expect(Set(detail.effectiveSettings.keys) == ["test-package"])
      #expect(try fixture.database.pluginStoreSnapshot() == PluginStoreSnapshot())
      var configuration = GatewayConfiguration(workspaceDirectory: fixture.root)
      configuration.knownPluginMCPServerIDs = ["plugin-12-test-package-native"]
      configuration.profiles = [
        .init(id: .chatGPTOperate, mcpServers: ["plugin-12-test-package-native"])
      ]
      #expect(
        try await fixture.host.parseManifest(configuration.exportedTOML()).profiles.count == 1)
      let loader = GatewayManifestConfigurationLoader(
        database: fixture.database, bundledPlugins: bundled)
      let manifest = fixture.root.appendingPathComponent("bundled-profile.toml")
      try configuration.exportedTOML().write(to: manifest, atomically: true, encoding: .utf8)
      #expect(try loader.load(path: manifest.path).profiles.count == 1)
      let enabled = try await fixture.cli(["enable", "test-package", "--expected-revision", "0"])
      #expect(enabled.exitCode == 0, "\(enabled.stdout)\n\(enabled.stderr)")
      let active = try await fixture.host.pluginSnapshot()
      #expect(active.state.revision == 1 && active.state.installations.isEmpty)
      #expect(active.settings(for: "test-package").enabled)
      #expect(active.settings(for: "test-package").mcp["native"]?.allowedTools == [])
      #expect(active.diagnostics.filter { $0.code == .dependencyUnavailable }.count == 2)
      #expect(
        active.contributions.count == 1 && active.contributions.first?.source.kind == .bundled)
      var settings = active.settings(for: "test-package")
      settings.dependencyExecutables = ["vendor": "/usr/bin/printf"]
      let configured = try await fixture.gateway.changePlugins(
        .settings(pluginID: "test-package", settings), expectedRevision: 1)
      #expect(configured.contributions.count == 3 && configured.diagnostics.isEmpty)
      #expect(configured.state.installations.isEmpty)
      let disabled = try await fixture.cli(["disable", "test-package", "--expected-revision", "2"])
      #expect(disabled.exitCode == 0)
      let final = try await fixture.host.pluginSnapshot()
      #expect(final.state.revision == 3 && final.contributions.isEmpty)
      #expect(
        final.state.settings["test-package"]?.dependencyExecutables
          == settings.dependencyExecutables)
      #expect(final.bundled.count == 2 && final.state.installations.isEmpty)
      #expect(try fixture.database.pluginOwnedDirectories().isEmpty)
      #expect(try Data(contentsOf: manifestURL) == original)
      #expect(
        try GatewayDatabase(path: fixture.directories.database.path).pluginStoreSnapshot()
          == final.state)
    } catch {
      await fixture.socket.stop()
      throw error
    }
    await fixture.socket.stop()
  }

  @Test
  func cancellingHostDownloadJoinsAndReleasesItsMutationReservation() async throws {
    let manifest = PreparationFixture.manifest.replacingOccurrences(
      of: "architectures = ['arm64']", with: "architectures = ['arm64', 'x86_64']")
    let archive = try await PreparationFixture.make(manifest: manifest, format: "zip")
    defer { archive.files.remove() }
    let bytes = try Data(contentsOf: archive.archive)
    let server = try await CatalogHTTPFixture.start(script: pluginDownloadHTTPFixture(bytes: bytes))
    defer { server.stop() }
    let http = ReleaseHTTPFake(manifest: manifest, artifactBytes: bytes)
    let artifact = pluginArtifactFixture(bytes: bytes, assetID: 20, manifest: manifest)
    await http.setAssets([releaseAssetFixture(id: 20, artifact: artifact)], page: 1)
    let fixture = try PluginControlFixture(
      worker: archive.preparation.workerExecutable.path, releases: GitHubPluginReleases(http: http),
      download: GitHubPluginDownload(origin: server.origin))
    defer { fixture.remove() }
    let task = Task {
      try await fixture.gateway.changePlugins(.installRelease(artifact), expectedRevision: 0)
    }
    do {
      let ready = try await GitHubCatalogHTTPClient(origin: server.origin).fetch(
        path: "/wait", query: [:], accept: "application/json", maxBytes: 128)
      #expect(try ready.decode(JSONValue.self) == .bool(true))
      #expect(try fixture.database.pluginOwnedDirectories().count == 1)
      await #expect(throws: PluginHostError.changeInProgress) {
        try await fixture.gateway.changePlugins(.recover, expectedRevision: 0)
      }
      task.cancel()
      await #expect(throws: CancellationError.self) { try await task.value }
    } catch {
      task.cancel()
      _ = try? await task.value
      throw error
    }
    #expect(try fixture.database.pluginStoreSnapshot().revision == 0)
    #expect(try fixture.database.pluginOwnedDirectories().isEmpty)
    let recovered = try await fixture.gateway.changePlugins(.recover, expectedRevision: 0)
    #expect(recovered.issues.isEmpty && recovered.state.installations.isEmpty)
  }

  @Test
  func releaseSelectionDownloadAndFailureThroughRealCLIAndOwnerSocket() async throws {
    let manifest = PreparationFixture.manifest.replacingOccurrences(
      of: "architectures = ['arm64']", with: "architectures = ['arm64', 'x86_64']")
    let archive = try await PreparationFixture.make(manifest: manifest, format: "zip")
    defer { archive.files.remove() }
    let bytes = try Data(contentsOf: archive.archive)
    let server = try await CatalogHTTPFixture.start(script: pluginDownloadHTTPFixture(bytes: bytes))
    defer { server.stop() }
    let http = ReleaseHTTPFake(manifest: manifest, artifactBytes: bytes)
    let fixture = try PluginControlFixture(
      worker: archive.preparation.workerExecutable.path, releases: GitHubPluginReleases(http: http),
      download: GitHubPluginDownload(origin: server.origin))
    defer { fixture.remove() }
    try await fixture.socket.start()
    do {
      let listing = try await fixture.cli([
        "artifacts", "computer-mcp/combined", "--repository-id", "7",
      ])
      #expect(listing.exitCode == 0, "\(listing.stdout)\n\(listing.stderr)")
      let catalog = try CanonicalJSONCoding.decoder().decode(
        GitHubPluginReleaseArtifacts.self, from: Data(listing.stdout.utf8))
      let artifact = try #require(catalog.artifacts.first)
      #expect(catalog.tag == "release/1.2.3" && catalog.page == 1)
      #expect(try fixture.database.pluginStoreSnapshot().revision == 0)
      #expect(try fixture.database.pluginOwnedDirectories().isEmpty)
      let selection = fixture.root.appendingPathComponent("selection.json")
      try CanonicalJSONCoding.encoder().encode(artifact).write(to: selection)
      let args = ["install-release", "selection.json", "--expected-revision", "0"]
      let installed = try await fixture.cli(args)
      #expect(installed.exitCode == 0, "\(installed.stdout)\n\(installed.stderr)")
      let snapshot = try CanonicalJSONCoding.decoder().decode(
        PluginHostSnapshot.self, from: Data(installed.stdout.utf8))
      let record = try #require(snapshot.state.installations.first)
      #expect(snapshot.state.revision == 1)
      #expect(record.source.githubRelease == artifact)
      #expect(record.source.artifactSHA256 == archive.digest)
      #expect(snapshot.state.settings["combined"]?.enabled == false)
      #expect(snapshot.state.settings["combined"]?.mcp.count == 1)
      #expect(snapshot.state.settings["combined"]?.cli.count == 1)
      #expect(snapshot.state.settings["combined"]?.skills.count == 1)
      #expect(snapshot.issues.isEmpty)
      #expect(await http.assetPages == ["1", "1", "1"])
      #expect(
        !FileManager.default.fileExists(
          atPath: record.source.root.appendingPathComponent("executed").path))

      let stale = try await fixture.cli(args)
      #expect(stale.exitCode != 0)
      #expect(
        try JSONDecoder().decode(JSONValue.self, from: Data(stale.stdout.utf8))
          .objectValue?["error"]?.objectValue?["code"] == .string("plugin.stale_revision"))
      await http.setAssets([], page: 1)
      let changed = try await fixture.cli([
        "install-release", "selection.json", "--expected-revision", "1",
      ])
      #expect(changed.exitCode != 0)
      #expect(
        try JSONDecoder().decode(JSONValue.self, from: Data(changed.stdout.utf8))
          .objectValue?["error"]?.objectValue?["code"]
          == .string("plugin.catalog.invalid_provenance"))
      #expect(try fixture.database.pluginStoreSnapshot() == snapshot.state)
      try Data("[]".utf8).write(to: selection)
      let malformed = try await fixture.cli(args)
      #expect(malformed.exitCode != 0)
      #expect(
        try JSONDecoder().decode(JSONValue.self, from: Data(malformed.stdout.utf8))
          .objectValue?["error"]?.objectValue?["code"] == .string("plugin.selection.invalid"))
      let removed = try await fixture.cli(["uninstall", record.id, "--expected-revision", "1"])
      #expect(removed.exitCode == 0)
      #expect(try fixture.database.pluginOwnedDirectories().isEmpty)
      #expect(FileManager.default.fileExists(atPath: archive.archive.path))
      let events = try fixture.database.auditEvents(limit: 50)
      for action in ["plugin.artifacts", "plugin.install_release"] {
        #expect(
          events.contains {
            $0.capabilityID == action && $0.decision == .allowed && $0.caller == .localCLI
          })
      }
      #expect(events.contains { $0.errorCode == "plugin.catalog.invalid_provenance" })
      await fixture.socket.stop()
    } catch {
      await fixture.socket.stop()
      throw error
    }
  }

  @Test
  func archiveLifecycleThroughRealCLIAndOwnerSocket() async throws {
    let archive = try await PreparationFixture.make(
      manifest: PreparationFixture.manifest.replacingOccurrences(
        of: "architectures = ['arm64']", with: "architectures = ['arm64', 'x86_64']"))
    defer { archive.files.remove() }
    let fixture = try PluginControlFixture(worker: archive.preparation.workerExecutable.path)
    defer { fixture.remove() }
    try await fixture.socket.start()
    do {
      let args = [
        "install", archive.archive.path, "--id", "combined", "--version", "1.2.3",
        "--sha256", archive.digest, "--expected-revision", "0",
      ]
      let installed = try await fixture.cli(args)
      #expect(installed.exitCode == 0, "\(installed.stderr)\n\(installed.stdout)")
      let snapshot = try CanonicalJSONCoding.decoder().decode(
        PluginHostSnapshot.self, from: Data(installed.stdout.utf8))
      #expect(snapshot.state.revision == 1)
      #expect(snapshot.state.settings["combined"]?.enabled == false)
      #expect(snapshot.issues.isEmpty && snapshot.recoveryError == nil)
      let record = try #require(snapshot.state.installations.first)
      #expect(record.source.kind == .artifact && record.source.artifactSHA256 == archive.digest)
      #expect(record.source.root.path.hasPrefix(fixture.directories.plugins.path + "/"))
      #expect(
        !FileManager.default.fileExists(
          atPath: record.source.root.appendingPathComponent("executed").path))

      let stale = try await fixture.cli(args)
      #expect(stale.exitCode != 0)
      let failure = try JSONDecoder().decode(JSONValue.self, from: Data(stale.stdout.utf8))
      #expect(
        failure.objectValue?["error"]?.objectValue?["code"] == .string("plugin.stale_revision"))
      #expect(try fixture.database.pluginStoreSnapshot() == snapshot.state)

      let update = try await PreparationFixture.make(
        manifest: PreparationFixture.manifest
          .replacingOccurrences(
            of: "architectures = ['arm64']", with: "architectures = ['arm64', 'x86_64']"
          )
          .replacingOccurrences(of: "version = '1.2.3'", with: "version = '1.2.4'"))
      defer { update.files.remove() }
      let updated = try await fixture.cli([
        "install", update.archive.path, "--id", "combined", "--version", "1.2.4",
        "--sha256", update.digest, "--expected-revision", "1",
      ])
      #expect(updated.exitCode == 0, "\(updated.stdout)")
      let updatedState = try fixture.database.pluginStoreSnapshot()
      #expect(updatedState.revision == 2 && updatedState.installations.count == 2)
      #expect(updatedState.settings == snapshot.state.settings)
      let newID = try #require(updatedState.selectedInstallations["combined"])
      #expect(newID != record.id)
      let rollback = try await fixture.cli([
        "select", "combined", "--installation-id", record.id, "--expected-revision", "2",
      ])
      #expect(rollback.exitCode == 0)
      #expect(
        try fixture.database.pluginStoreSnapshot().selectedInstallations["combined"] == record.id)
      let recovery = try await fixture.cli(["recover", "--expected-revision", "3"])
      #expect(recovery.exitCode == 0)
      #expect(try fixture.database.pluginStoreSnapshot().revision == 3)
      let removedUpdate = try await fixture.cli(["uninstall", newID, "--expected-revision", "3"])
      #expect(removedUpdate.exitCode == 0)
      #expect(
        try fixture.database.pluginStoreSnapshot().selectedInstallations["combined"] == record.id)
      let removed = try await fixture.cli(["uninstall", record.id, "--expected-revision", "4"])
      #expect(removed.exitCode == 0, "\(removed.stdout)")
      let final = try CanonicalJSONCoding.decoder().decode(
        PluginHostSnapshot.self, from: Data(removed.stdout.utf8))
      #expect(final.state.revision == 5 && final.state.installations.isEmpty)
      #expect(final.state.settings == snapshot.state.settings)
      #expect(!FileManager.default.fileExists(atPath: record.source.root.path))
      #expect(FileManager.default.fileExists(atPath: archive.archive.path))
      #expect(try fixture.database.pluginOwnedDirectories().isEmpty)
      let events = try fixture.database.auditEvents(limit: 50)
      for action in ["plugin.install", "plugin.uninstall", "plugin.recover"] {
        #expect(
          events.contains {
            $0.capabilityID == action && $0.decision == .allowed && $0.caller == .localCLI
          })
        #expect(AppControlCapabilityCatalog.all.first { $0.id == action }?.readOnly == false)
      }
      #expect(events.contains { $0.errorCode == "plugin.stale_revision" })
      await fixture.socket.stop()
    } catch {
      await fixture.socket.stop()
      throw error
    }
  }

  @Test
  func hostDoesNotResolveArchiveWorkerFromPATH() async throws {
    let fixture = try PluginControlFixture(worker: "computer-mcp")
    defer { fixture.remove() }
    await #expect(throws: PluginHostError.workerUnavailable) {
      try await fixture.gateway.changePlugins(
        .installArchive(
          archive: fixture.root.appendingPathComponent("unused.tar"),
          sha256: String(repeating: "0", count: 64), pluginID: "combined",
          version: PluginVersion("1.2.3")),
        expectedRevision: 0)
    }
    #expect(try fixture.database.pluginStoreSnapshot().revision == 0)
    #expect(!FileManager.default.fileExists(atPath: fixture.directories.plugins.path))
  }

  @Test
  func committedUninstallWarningsSurviveListAndShow() async throws {
    let archive = try await PreparationFixture.make(
      manifest: PreparationFixture.manifest.replacingOccurrences(
        of: "architectures = ['arm64']", with: "architectures = ['arm64', 'x86_64']"))
    defer { archive.files.remove() }
    let fixture = try PluginControlFixture(worker: archive.preparation.workerExecutable.path)
    defer { fixture.remove() }
    let installed = try await fixture.gateway.changePlugins(
      .installArchive(
        archive: archive.archive, sha256: archive.digest, pluginID: "combined",
        version: PluginVersion("1.2.3")),
      expectedRevision: 0)
    let record = try #require(installed.state.installations.first)
    let container = record.source.root.deletingLastPathComponent()
    try FileManager.default.moveItem(at: container, to: fixture.root.appendingPathComponent("held"))
    try FileManager.default.createDirectory(
      at: container, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    try Data("preserve".utf8).write(to: container.appendingPathComponent("keep"))
    let removed = try await fixture.gateway.changePlugins(
      .uninstallArtifact(installationID: record.id), expectedRevision: 1)
    #expect(removed.state.revision == 2 && removed.state.installations.isEmpty)
    #expect(removed.issues.map(\.pluginID) == ["combined"])
    #expect(try await fixture.host.pluginSnapshot().issues == removed.issues)
    #expect(
      try String(contentsOf: container.appendingPathComponent("keep"), encoding: .utf8)
        == "preserve")
    #expect(try fixture.database.pluginOwnedDirectories().count == 1)
    try await fixture.socket.start()
    do {
      let result = try await AppControlPlaneServiceClient(
        socketURL: fixture.directories.controlSocket
      ).call(
        "plugin.show", arguments: .object(["id": .string("combined")]))
      #expect(result.objectValue?["issues"]?.arrayValue?.count == 1)
      #expect(result.objectValue?["state"]?.objectValue?["revision"] == .number(2))
      await fixture.socket.stop()
    } catch {
      await fixture.socket.stop()
      throw error
    }
  }

  @Test
  func startupRecoveryAndManualRetryPreserveReplacedDirectories() async throws {
    let fixture = try PluginControlFixture()
    defer { fixture.remove() }
    let identity: PluginDirectoryIdentity
    let replacement: URL
    do {
      let storage = try PluginInstallationStorage(at: fixture.directories.plugins)
      defer { storage.finishTransaction() }
      identity = try storage.createInstallation()
      try fixture.database.recordPluginDirectory(
        .init(
          installationID: identity.url.lastPathComponent, pluginID: "combined", identity: identity))
      replacement = identity.url
      try FileManager.default.moveItem(
        at: identity.url, to: fixture.root.appendingPathComponent("held"))
      try FileManager.default.createDirectory(
        at: replacement, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      try Data("user-owned".utf8).write(to: replacement.appendingPathComponent("keep"))
    }
    try await fixture.host.recoverPluginsAtStartup()
    let first = try await fixture.host.pluginSnapshot()
    #expect(first.issues.map(\.pluginID) == ["combined"])
    #expect(first.recoveryError == nil)
    #expect(
      try String(contentsOf: replacement.appendingPathComponent("keep"), encoding: .utf8)
        == "user-owned")
    #expect(try fixture.database.pluginOwnedDirectories().count == 1)

    try FileManager.default.moveItem(
      at: replacement, to: fixture.root.appendingPathComponent("preserved"))
    try FileManager.default.moveItem(
      at: fixture.root.appendingPathComponent("held"), to: identity.url)
    let recovered = try await fixture.gateway.changePlugins(.recover, expectedRevision: 0)
    #expect(recovered.issues.isEmpty && recovered.recoveryError == nil)
    #expect(recovered.state.revision == 0)
    #expect(try fixture.database.pluginOwnedDirectories().isEmpty)
    #expect(
      FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("preserved/keep").path))
    #expect(!FileManager.default.fileExists(atPath: identity.url.path))
  }

  @Test
  func busyStartupReportsFailureAndExplicitRecoveryClearsIt() async throws {
    let fixture = try PluginControlFixture()
    defer { fixture.remove() }
    do {
      let storage = try PluginInstallationStorage(at: fixture.directories.plugins)
      defer { storage.finishTransaction() }
      try await fixture.host.recoverPluginsAtStartup()
      #expect(
        try await fixture.host.pluginSnapshot().recoveryError
          == PluginStoreError.installationBusy.errorDescription)
      await #expect(throws: PluginStoreError.installationBusy) {
        try await fixture.gateway.changePlugins(.recover, expectedRevision: 0)
      }
    }
    let recovered = try await fixture.gateway.changePlugins(.recover, expectedRevision: 0)
    #expect(recovered.recoveryError == nil && recovered.state.revision == 0)
  }

  @Test
  func connectedGatewayPreventsArtifactWritesWithoutInterruptingClient() async throws {
    let fixture = try PluginControlFixture()
    defer { fixture.remove() }
    try await fixture.gateway.start(profile: .chatGPTObserve)
    let transport = GatewaySocketTransport(
      configuration: .init(socketURL: fixture.directories.gatewaySocket, clientIdentity: .localCLI))
    let client = Client(name: "artifact-protection", version: "1")
    do {
      _ = try await client.connect(transport: transport)
      for change: PluginHostChange in [.uninstallArtifact(installationID: "unselected"), .recover] {
        await #expect(throws: PluginHostError.connectedClients) {
          try await fixture.gateway.changePlugins(change, expectedRevision: 0)
        }
      }
      _ = try await client.listTools()
      #expect(try fixture.database.pluginStoreSnapshot().revision == 0)
      await client.disconnect()
      await fixture.gateway.stop()
    } catch {
      await client.disconnect()
      await fixture.gateway.stop()
      throw error
    }
  }
}

struct PluginControlFixture: Sendable {
  let root: URL
  let directories: AppControlPlaneServiceDirectories
  let database: GatewayDatabase
  let host: AppControlPlaneService
  let gateway: AppGatewayService
  let socket: ControlSocketService
  let cliExecutable: URL

  init(
    worker: String = "computer-mcp", releases: GitHubPluginReleases = GitHubPluginReleases(),
    download: GitHubPluginDownload = GitHubPluginDownload(),
    bundled: BundledPlugins = .current,
    cliExecutable: URL? = nil
  ) throws {
    self.cliExecutable =
      cliExecutable
      ?? URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent(".build/debug/computer-mcp")
    root = URL(fileURLWithPath: "/private/tmp/cm-pc-\(UUID().uuidString.prefix(8))")
    directories = AppControlPlaneServiceDirectories(
      applicationSupport: root.appendingPathComponent("support"),
      logs: root.appendingPathComponent("logs"))
    try directories.prepare()
    database = try GatewayDatabase(path: directories.database.path)
    let manifestStore = try AtomicManifestStore(
      manifestURL: directories.manifest, database: database,
      loader: GatewayManifestConfigurationLoader(database: database, bundledPlugins: bundled))
    _ = try manifestStore.activate(
      manifest: GatewayConfiguration(workspaceDirectory: root).exportedTOML())
    let secrets = try KeychainSecretStore(adapter: MemoryKeychainAdapter())
    host = AppControlPlaneService(
      directories: directories, database: database, manifestStore: manifestStore,
      secretStore: secrets, openAITunnelSupervisor: OpenAITunnelSupervisor(secretStore: secrets),
      gatewayExecutablePath: worker, pluginReleases: releases, pluginDownload: download,
      bundledPlugins: bundled)
    gateway = AppGatewayService.live(controlPlane: host, directories: directories)
    socket = ControlSocketService(
      controlPlane: host, gatewayService: gateway, socketURL: directories.controlSocket)
  }

  func cli(_ arguments: [String]) async throws -> CommandResult {
    let executable = cliExecutable
    return try await BlockingOperationExecutor(label: "plugin-cli-test").perform {
      try ProcessCommandRunner().run(
        executable: executable.path,
        arguments: ["plugins"] + arguments + ["--control-socket", directories.controlSocket.path],
        workingDirectory: root, environment: [:], timeoutMilliseconds: 30_000,
        maxOutputBytes: 1_048_576)
    }
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}
