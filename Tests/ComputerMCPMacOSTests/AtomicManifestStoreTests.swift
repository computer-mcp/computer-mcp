import ComputerMCPMacOS
import ComputerMCPPermissions
import ComputerMCPPlatformDarwin
import ComputerMCPPlatformPOSIX
import ComputerMCPTestSupport
import CryptoKit
import Foundation
import GRDB
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPControlPlane
@testable import ComputerMCPCore
@testable import ComputerMCPGateway

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite

final class AtomicManifestStoreTests {
  @Test(arguments: [false, true])
  func installedBuiltinUpgradePublishesCurrentManifestAndPreservesHistory(legacyProfiles: Bool)
    throws
  {
    let fixture = try ManifestStoreFixture(persistent: true)
    defer { fixture.cleanup() }
    let profiles =
      legacyProfiles
      ? "[[profiles]]\nid='local-admin'\nmode='read-only'\ncapabilities=['git.worktrees']\n"
      : "[[profiles]]\nid='local-admin'\nallowed_callers=['local-cli']\n"
    let text =
      "schema_version=1\n[builtin]\nenabled=['git.worktrees','delivery.apply','delivery.scopes.list']\n"
      + profiles
    try Data(text.utf8).write(to: fixture.manifestURL)
    let historical = ConfigurationRevision(
      digest: try AtomicManifestStore.digest(of: Data(text.utf8)), manifest: text)
    try fixture.database.saveConfigurationRevision(historical)
    let platform = MacOSPlatform.services(launcher: testExecutionLauncher())
    let report = try #require(
      try AtomicManifestStore.activatePermissionMigration(
        manifestURL: fixture.manifestURL, database: fixture.database,
        applications: platform.applications,
        bundledPlugins: .init(packages: [], issues: [])))
    #expect(report.removedBuiltinIDs == ["delivery.apply", "delivery.scopes.list"])
    let reopened = try AtomicManifestStore(
      manifestURL: fixture.manifestURL, database: fixture.database,
      loader: GatewayManifestConfigurationLoader(
        database: fixture.database, applications: platform.applications))
    #expect(try reopened.activeConfiguration().builtin.enabled == ["git.worktree_list"])
    #expect(try fixture.database.configurationRevision(id: historical.id)?.manifest == text)
    let current = try Data(contentsOf: fixture.manifestURL)
    _ = try AtomicManifestStore(
      manifestURL: fixture.manifestURL, database: fixture.database,
      loader: GatewayManifestConfigurationLoader(
        database: fixture.database, applications: platform.applications))
    #expect(try Data(contentsOf: fixture.manifestURL) == current)
  }

  @Test(arguments: [false, true])
  func startupReconcilesEditedProfileSourceWithoutRewritingItsBytes(unconfirmed: Bool) throws {
    let fixture = try ManifestStoreFixture(persistent: true)
    defer { fixture.cleanup() }
    var grant = ProfileGrant(id: .chatGPTOperate, allowedCallers: [.localMCP])
    var configuration = GatewayConfiguration(profiles: [.init(grant: grant)])
    let original = try fixture.store.activate(manifest: configuration.exportedTOML())
    let before = try fixture.database.configurationState()
    #expect(
      before.profiles.first { $0.id == grant.id }?.permissions.state(for: .screen) == .notGranted)
    if unconfirmed {
      try fixture.database.connection.writer.write {
        try $0.execute(
          sql: "UPDATE permissionProfiles SET authorityEpoch = NULL WHERE id = ?",
          arguments: [grant.id.rawValue])
      }
    }
    try grant.permissions.set(.granted(.access), for: .screen)
    configuration.profiles = [.init(grant: grant)]
    let edited = Data(try configuration.exportedTOML().utf8)
    try edited.write(to: fixture.manifestURL, options: .atomic)
    let fingerprint = try #require(FileFingerprint.current(of: fixture.manifestURL))
    let platform = MacOSPlatform.services(launcher: testExecutionLauncher())
    let reopened = try AtomicManifestStore(
      manifestURL: fixture.manifestURL, database: fixture.database,
      loader: GatewayManifestConfigurationLoader(
        database: fixture.database, applications: platform.applications))
    #expect(
      try reopened.activeConfiguration().profiles.first?.grant.permissions.state(for: .screen)
        == .granted(.access))
    #expect(try Data(contentsOf: fixture.manifestURL) == edited)
    #expect(FileFingerprint.current(of: fixture.manifestURL) == fingerprint)
    let state = try fixture.database.configurationState()
    if unconfirmed {
      #expect(state.profileSource == before.profileSource)
      #expect(state.profiles == before.profiles)
      let owner = try GatewayPermissionOwner(
        context: .init(
          caller: .localApp, profileID: .localAdmin, trustedPrincipalID: "fixture-owner"),
        validate: {})
      let view = try fixture.database.permissionRuntime(platform: platform).service.view(
        owner: owner)
      #expect(view.unconfirmedProfileIDs.contains(grant.id))
      #expect(try reopened.history().map(\.id) == [original.id])
    } else {
      #expect(
        state.profileSource
          == Data(try PermissionProfileManifest.encode(configuration.profiles.map(\.grant)).utf8))
      #expect(
        state.profiles.first { $0.id == grant.id }?.permissions.state(for: .screen)
          == .granted(.access))
      #expect(try reopened.history().count == 2)
      _ = try AtomicManifestStore(
        manifestURL: fixture.manifestURL, database: fixture.database,
        loader: GatewayManifestConfigurationLoader(
          database: fixture.database, applications: platform.applications))
      #expect(try reopened.history().count == 2)
    }
  }

  @Test(arguments: [nil, Data(), Data([0xFF]), Data("schema_version = 999\n".utf8)] as [Data?])
  func rejectedExternalBytesRemainUnmodifiedAndUnadmitted(data: Data?) throws {
    let fixture = try ManifestStoreFixture()
    defer { fixture.cleanup() }
    let original = try fixture.store.activate(
      manifest: Self.manifest(name: "original"),
      expectedDigest: try? fixture.store.admittedDigest(for: fixture.store.activeConfiguration()))
    if let data {
      try data.write(to: fixture.manifestURL, options: .atomic)
    } else {
      try FileManager.default.removeItem(at: fixture.manifestURL)
    }
    #expect(throws: (any Error).self) {
      let input = try #require(try fixture.store.externalInput())
      _ = try fixture.store.commit(
        fixture.store.prepare(
          manifest: input.manifest, reason: .externalReload, expectedDigest: input.digest))
    }
    #expect(try fixture.files.currentData() == data)
    #expect(try fixture.store.activeConfiguration().server.name == "original")
    #expect(try fixture.store.history().map(\.id) == [original.id])
  }

  @Test
  func rejectedExternalDatabaseCommitDoesNotRewriteTheEditorFile() throws {
    let fixture = try ManifestStoreFixture(persistent: true)
    defer { fixture.cleanup() }
    let original = try fixture.store.activate(
      manifest: Self.manifest(name: "original"),
      expectedDigest: try? fixture.store.admittedDigest(for: fixture.store.activeConfiguration()))
    let text = Self.manifest(name: "external")
    try Data(text.utf8).write(to: fixture.manifestURL, options: .atomic)
    let before = try #require(FileFingerprint.current(of: fixture.manifestURL))
    let input = try #require(try fixture.store.externalInput())
    let prepared = try fixture.store.prepare(
      manifest: input.manifest, reason: .externalReload, expectedDigest: input.digest)
    let connection = fixture.database.connection.writer
    try connection.write {
      try $0.execute(
        sql: """
          CREATE TABLE externalManifestParent (id INTEGER PRIMARY KEY);
          CREATE TABLE externalManifestChild (
            id INTEGER REFERENCES externalManifestParent(id) DEFERRABLE INITIALLY DEFERRED);
          CREATE TRIGGER refuse_external_commit AFTER INSERT ON configurationRevisions
          BEGIN INSERT INTO externalManifestChild VALUES (1); END;
          """)
    }
    do {
      _ = try fixture.store.commit(prepared)
      Issue.record("The deferred foreign key must reject the manifest commit.")
    } catch let error as DatabaseError {
      #expect(error.resultCode == .SQLITE_CONSTRAINT)
    }
    #expect(FileFingerprint.current(of: fixture.manifestURL) == before)
    #expect(try Data(contentsOf: fixture.manifestURL) == Data(text.utf8))
    #expect(try fixture.store.activeConfiguration().server.name == "original")
    #expect(try fixture.store.history().map(\.id) == [original.id])
    #expect(!FileManager.default.fileExists(atPath: fixture.files.recoveryURL.path))
  }

  @Test(arguments: ["publish", "conflict", "file"])
  func preparedPublicationCommitsFileAndResolutionTogether(outcome: String) throws {
    let fixture = try ManifestStoreFixture()
    defer { fixture.cleanup() }
    let original = try fixture.store.activate(
      manifest: Self.manifest(name: "original"),
      expectedDigest: try? fixture.store.admittedDigest(for: fixture.store.activeConfiguration()))
    try fixture.database.saveProject(
      .init(id: "project", displayName: "Project", rootPath: fixture.root.path))
    let before = try fixture.database.configurationState()
    let store = try AtomicManifestStore(
      manifestURL: fixture.manifestURL, database: fixture.database,
      loader: GatewayManifestConfigurationLoader(
        database: fixture.database,
        applications: MacOSPlatform.services(launcher: testExecutionLauncher()).applications),
      fileManager: outcome == "file"
        ? RejectingManifestMetadata(manifestURL: fixture.manifestURL) : .default)
    let candidate = try store.prepare(
      manifest: Self.manifest(name: "candidate"), expectedDigest: original.digest)
    #expect(try store.activeConfiguration().server.name == "original")
    #expect(try fixture.database.configurationState() == before)
    #expect(try store.history().map(\.id) == [original.id])
    let project = try #require(before.projects.first)
    var refreshed = project
    refreshed.bookmarkData = Data([1, 2, 3])
    let resolution = GatewayConfigurationResolution(projects: [
      .init(original: project, resolved: refreshed)
    ])
    if outcome == "conflict" { try fixture.database.saveProfile(.operate) }
    var installed: GatewayDatabase.ConfigurationState?
    if outcome == "publish" {
      _ = try store.commit(candidate, resolution: resolution) { installed = $0 }
      #expect(installed == (try fixture.database.configurationState()))
      #expect(
        try fixture.database.project(id: project.id)?.bookmarkData == refreshed.bookmarkData)
      #expect(try store.activeConfiguration().server.name == "candidate")
      #expect(try store.history().count == 2)
    } else {
      #expect(throws: (any Error).self) {
        try store.commit(candidate, resolution: resolution) { installed = $0 }
      }
      #expect(installed == nil)
      #expect(try fixture.database.project(id: project.id) == project)
      #expect(try Data(contentsOf: fixture.manifestURL) == Data(original.manifest.utf8))
      #expect(try store.activeConfiguration().server.name == "original")
      #expect(try store.history().map(\.id) == [original.id])
    }
  }

  @Test
  func failedMetadataWriteRestoresFileAndRevisionAuthority() throws {
    let fixture = try ManifestStoreFixture()
    defer { fixture.cleanup() }
    let original = try fixture.store.activate(
      manifest: Self.manifest(name: "original"),
      expectedDigest: try? fixture.store.admittedDigest(for: fixture.store.activeConfiguration()))
    let manager = RejectingManifestMetadata(manifestURL: fixture.manifestURL)
    let store = try AtomicManifestStore(
      manifestURL: fixture.manifestURL, database: fixture.database,
      loader: GatewayManifestConfigurationLoader(
        database: fixture.database,
        applications: MacOSPlatform.services(launcher: testExecutionLauncher()).applications),
      fileManager: manager)
    #expect(try store.activeConfiguration().server.name == "original")
    #expect(throws: ManifestWriteFailure.self) {
      try store.activate(
        manifest: Self.manifest(name: "rejected"),
        expectedDigest: try? store.admittedDigest(for: store.activeConfiguration()))
    }
    #expect(manager.didReject)
    #expect(try Data(contentsOf: fixture.manifestURL) == Data(original.manifest.utf8))
    #expect(try store.activeConfiguration().server.name == "original")
    #expect(try store.history().map(\.id) == [original.id])
    let reopened = try AtomicManifestStore(
      manifestURL: fixture.manifestURL, database: fixture.database,
      loader: GatewayManifestConfigurationLoader(
        database: fixture.database,
        applications: MacOSPlatform.services(launcher: testExecutionLauncher()).applications))
    #expect(try reopened.activeConfiguration().server.name == "original")
  }

  @Test
  func deferredDatabaseCommitFailureRestoresReplacedFile() throws {
    let fixture = try ManifestStoreFixture(persistent: true)
    defer { fixture.cleanup() }
    let original = try fixture.store.activate(
      manifest: Self.manifest(name: "original"),
      expectedDigest: try? fixture.store.admittedDigest(for: fixture.store.activeConfiguration()))
    let connection = fixture.database.connection.writer
    try connection.write {
      try $0.execute(
        sql: """
          CREATE TABLE manifestFailureParent (id INTEGER PRIMARY KEY);
          CREATE TABLE manifestFailureChild (
            id INTEGER REFERENCES manifestFailureParent(id) DEFERRABLE INITIALLY DEFERRED);
          CREATE TRIGGER refuse_manifest_commit AFTER INSERT ON configurationRevisions
          BEGIN INSERT INTO manifestFailureChild VALUES (1); END;
          """)
    }
    let manager = ManifestMetadataProbe(manifestURL: fixture.manifestURL)
    let store = try AtomicManifestStore(
      manifestURL: fixture.manifestURL, database: fixture.database,
      loader: GatewayManifestConfigurationLoader(
        database: fixture.database,
        applications: MacOSPlatform.services(launcher: testExecutionLauncher()).applications),
      fileManager: manager)
    let proposed = Self.manifest(name: "rejected")
    do {
      _ = try store.activate(
        manifest: proposed,
        expectedDigest: try? store.admittedDigest(for: store.activeConfiguration()))
      Issue.record("The deferred foreign key must reject the manifest commit.")
    } catch let error as DatabaseError {
      #expect(error.resultCode == .SQLITE_CONSTRAINT)
    }
    // The deferred constraint fails at COMMIT, after the real replacement completed.
    #expect(manager.replacedData == Data(proposed.utf8))
    #expect(try Data(contentsOf: fixture.manifestURL) == Data(original.manifest.utf8))
    #expect(try store.history().map(\.id) == [original.id])
    #expect(try store.activeConfiguration().server.name == "original")
    #expect(!FileManager.default.fileExists(atPath: fixture.files.recoveryURL.path))
  }

  @Test
  func failedInitialActivationLeavesNoActiveFile() throws {
    let fixture = try ManifestStoreFixture()
    defer { fixture.cleanup() }
    let manager = RejectingManifestMetadata(manifestURL: fixture.manifestURL)
    let store = try AtomicManifestStore(
      manifestURL: fixture.manifestURL, database: fixture.database,
      loader: GatewayManifestConfigurationLoader(
        database: fixture.database,
        applications: MacOSPlatform.services(launcher: testExecutionLauncher()).applications),
      fileManager: manager)
    #expect(throws: ManifestWriteFailure.self) {
      try store.activate(
        manifest: Self.manifest(name: "rejected"),
        expectedDigest: try? store.admittedDigest(for: store.activeConfiguration()))
    }
    #expect(manager.didReject)
    #expect(try fixture.files.currentData() == nil)
    #expect(try store.history().isEmpty)
    #expect(throws: AtomicManifestStoreError.manifestMissing) { try store.activeConfiguration() }
    #expect(!FileManager.default.fileExists(atPath: fixture.files.recoveryURL.path))
  }

  @Test(arguments: [false, true])
  func concurrentEditsDuringValidationNeverPublishStaleBytes(editActive: Bool) throws {
    let fixture = try ManifestStoreFixture()
    defer { fixture.cleanup() }
    let original = try fixture.store.activate(
      manifest: Self.manifest(name: "original"),
      expectedDigest: try? fixture.store.admittedDigest(for: fixture.store.activeConfiguration()))
    let external = Self.manifest(name: "external")
    let loader = MutatingManifestLoader(
      externalURL: editActive ? fixture.manifestURL : nil, replacement: external)
    let store = try AtomicManifestStore(
      manifestURL: fixture.manifestURL, database: fixture.database, loader: loader)
    loader.arm()
    #expect(throws: AtomicManifestStoreError.staleDigest) {
      try store.activate(
        manifest: Self.manifest(name: "candidate"), expectedDigest: original.digest)
    }
    #expect(loader.didMutate)
    #expect(
      try Data(contentsOf: fixture.manifestURL)
        == Data((editActive ? external : original.manifest).utf8))
    #expect(try store.history().map(\.id) == [original.id])
    #expect(!FileManager.default.fileExists(atPath: fixture.files.recoveryURL.path))
  }

  @Test(arguments: [
    (false, false, false), (false, false, true), (false, true, false), (false, true, true),
    (true, false, false), (true, false, true), (true, true, false), (true, true, true),
  ])
  func startupRecoversTheDurableRevision(
    committed: Bool, diskReplaced: Bool, initialActivation: Bool
  ) throws {
    let fixture = try ManifestStoreFixture(persistent: true)
    defer { fixture.cleanup() }
    let previous: Data?
    if initialActivation {
      try fixture.database.bootstrapPermissionProfiles([])
      previous = nil
    } else {
      _ = try fixture.store.activate(
        manifest: Self.manifest(name: "original"),
        expectedDigest: try? fixture.store.admittedDigest(for: fixture.store.activeConfiguration()))
      previous = try Data(contentsOf: fixture.manifestURL)
    }
    let revision = Self.recoveryRevision(name: "candidate")
    try fixture.writeJournal(revision, previous: previous)
    if diskReplaced {
      try Data(revision.manifest.utf8).write(to: fixture.manifestURL)
    }
    if committed { try fixture.database.saveConfigurationRevision(revision) }
    // Store restart borrows this host's authority; a separate SQL reader verifies
    // the durable commit decision without creating another execution coordinator.
    let reopenedDatabase = try GatewayDatabase(path: try #require(fixture.database.fileURL).path)
    _ = reopenedDatabase.permissionStore(counter: fixture.counter)
    let persistedRevision = try reopenedDatabase.configurationRevision(id: revision.id)
    if committed {
      let persisted = try #require(persistedRevision)
      #expect(persisted.id == revision.id)
      #expect(persisted.digest == revision.digest)
      #expect(persisted.manifest == revision.manifest)
      #expect(persisted.activationError == revision.activationError)
      // GRDB's default Date codec persists UTC SQL text at millisecond precision.
      #expect(persisted.createdAt.databaseValue == revision.createdAt.databaseValue)
      #expect(persisted.activatedAt?.databaseValue == revision.activatedAt?.databaseValue)
    } else {
      #expect(persistedRevision == nil)
    }
    let platform = MacOSPlatform.services(launcher: testExecutionLauncher())
    let reopened = try AtomicManifestStore(
      manifestURL: fixture.manifestURL, database: fixture.database,
      loader: GatewayManifestConfigurationLoader(
        database: fixture.database, applications: platform.applications))
    #expect(
      try fixture.files.currentData() == (committed ? Data(revision.manifest.utf8) : previous))
    if committed || !initialActivation {
      #expect(
        try reopened.activeConfiguration().server.name == (committed ? "candidate" : "original"))
    } else {
      #expect(throws: AtomicManifestStoreError.manifestMissing) {
        try reopened.activeConfiguration()
      }
    }
    #expect(try reopened.history().count == (initialActivation ? 0 : 1) + (committed ? 1 : 0))
    #expect(try reopened.history() == reopenedDatabase.configurationRevisions())
    #expect(try fixture.database.configurationState() == reopenedDatabase.configurationState())
    #expect(!FileManager.default.fileExists(atPath: fixture.files.recoveryURL.path))
  }

  @Test(arguments: [false, true])
  func recoveryPreservesUnrecognizedExternalEdits(committed: Bool) throws {
    let fixture = try ManifestStoreFixture()
    defer { fixture.cleanup() }
    _ = try fixture.store.activate(
      manifest: Self.manifest(name: "original"),
      expectedDigest: try? fixture.store.admittedDigest(for: fixture.store.activeConfiguration()))
    let previous = try Data(contentsOf: fixture.manifestURL)
    let revision = Self.recoveryRevision(name: "candidate")
    try fixture.writeJournal(revision, previous: previous)
    if committed { try fixture.database.saveConfigurationRevision(revision) }
    let journal = try Data(contentsOf: fixture.files.recoveryURL)
    let external = Data(Self.manifest(name: "external").utf8)
    try external.write(to: fixture.manifestURL)
    #expect(throws: AtomicManifestStoreError.recoveryConflict(fixture.manifestURL.path)) {
      try AtomicManifestStore(
        manifestURL: fixture.manifestURL, database: fixture.database,
        loader: GatewayManifestConfigurationLoader(
          database: fixture.database,
          applications: MacOSPlatform.services(launcher: testExecutionLauncher()).applications))
    }
    #expect(try Data(contentsOf: fixture.manifestURL) == external)
    #expect(try Data(contentsOf: fixture.files.recoveryURL) == journal)
    // Once the external edit is preserved elsewhere and a known state is restored,
    // the same journal can recover without inventing another activated revision.
    try Data(revision.manifest.utf8).write(to: fixture.manifestURL)
    let reopened = try AtomicManifestStore(
      manifestURL: fixture.manifestURL, database: fixture.database,
      loader: GatewayManifestConfigurationLoader(
        database: fixture.database,
        applications: MacOSPlatform.services(launcher: testExecutionLauncher()).applications))
    #expect(
      try reopened.activeConfiguration().server.name == (committed ? "candidate" : "original"))
    #expect(try reopened.history().count == (committed ? 2 : 1))
  }

  @Test(arguments: ["malformed", "digest", "version", "symlink", "revision"])
  func invalidRecoveryEvidenceDoesNotMutateFiles(kind: String) throws {
    let fixture = try ManifestStoreFixture()
    defer { fixture.cleanup() }
    _ = try fixture.store.activate(
      manifest: Self.manifest(name: "original"),
      expectedDigest: try? fixture.store.admittedDigest(for: fixture.store.activeConfiguration()))
    let previous = try Data(contentsOf: fixture.manifestURL)
    var revision = Self.recoveryRevision(name: "candidate")
    if kind == "digest" { revision.digest = "invalid" }
    try fixture.writeJournal(revision, previous: previous, version: kind == "version" ? 2 : 1)
    if kind == "malformed" { try Data("{".utf8).write(to: fixture.files.recoveryURL) }
    if kind == "revision" {
      revision.manifest = Self.manifest(name: "different")
      try fixture.database.saveConfigurationRevision(revision)
    }
    if kind == "symlink" {
      try FileManager.default.removeItem(at: fixture.files.recoveryURL)
      try FileManager.default.createSymbolicLink(
        at: fixture.files.recoveryURL, withDestinationURL: fixture.manifestURL)
    }
    let journal = try Data(contentsOf: fixture.files.recoveryURL)
    #expect(throws: AtomicManifestStoreError.invalidRecoveryJournal) {
      try AtomicManifestStore(
        manifestURL: fixture.manifestURL, database: fixture.database,
        loader: GatewayManifestConfigurationLoader(
          database: fixture.database,
          applications: MacOSPlatform.services(launcher: testExecutionLauncher()).applications))
    }
    #expect(try Data(contentsOf: fixture.manifestURL) == previous)
    #expect(try Data(contentsOf: fixture.files.recoveryURL) == journal)
  }

  @Test
  func cooperatingStoresSerializeReviewedPublication() throws {
    let fixture = try ManifestStoreFixture()
    defer { fixture.cleanup() }
    let first = try fixture.store.activate(
      manifest: Self.manifest(name: "first"),
      expectedDigest: try? fixture.store.admittedDigest(for: fixture.store.activeConfiguration()))
    let other = try AtomicManifestStore(
      manifestURL: fixture.manifestURL, database: fixture.database,
      loader: GatewayManifestConfigurationLoader(
        database: fixture.database,
        applications: MacOSPlatform.services(launcher: testExecutionLauncher()).applications))
    try fixture.files.withExclusiveAccess { () throws -> Void in
      #expect(throws: AtomicManifestStoreError.changeInProgress) {
        try other.activate(manifest: Self.manifest(name: "contended"), expectedDigest: first.digest)
      }
      #expect(try fixture.store.activeConfiguration().server.name == "first")
    }
    _ = try other.activate(manifest: Self.manifest(name: "second"), expectedDigest: first.digest)
    #expect(throws: AtomicManifestStoreError.staleDigest) {
      try fixture.store.activate(manifest: first.manifest, expectedDigest: first.digest)
    }
    #expect(try other.activeConfiguration().server.name == "second")
    #expect(try fixture.store.history().count == 2)
  }

  @Test
  func committedRevisionSurvivesRecoveryRecordCleanupFailure() throws {
    let fixture = try ManifestStoreFixture()
    defer { fixture.cleanup() }
    _ = try fixture.store.activate(
      manifest: Self.manifest(name: "original"),
      expectedDigest: try? fixture.store.admittedDigest(for: fixture.store.activeConfiguration()))
    let manager = RejectingRecoveryCleanup(recoveryURL: fixture.files.recoveryURL)
    let store = try AtomicManifestStore(
      manifestURL: fixture.manifestURL, database: fixture.database,
      loader: GatewayManifestConfigurationLoader(
        database: fixture.database,
        applications: MacOSPlatform.services(launcher: testExecutionLauncher()).applications),
      fileManager: manager)
    let revision = try store.activate(
      manifest: Self.manifest(name: "committed"),
      expectedDigest: try? store.admittedDigest(for: store.activeConfiguration()))
    #expect(try store.activeConfiguration().server.name == "committed")
    #expect(try fixture.database.configurationRevision(id: revision.id)?.digest == revision.digest)
    #expect(try permissions(at: fixture.files.recoveryURL) == 0o600)
    #expect(try permissions(at: fixture.manifestURL) == 0o600)
    let reopened = try AtomicManifestStore(
      manifestURL: fixture.manifestURL, database: fixture.database,
      loader: GatewayManifestConfigurationLoader(
        database: fixture.database,
        applications: MacOSPlatform.services(launcher: testExecutionLauncher()).applications))
    #expect(try reopened.activeConfiguration().server.name == "committed")
    #expect(try reopened.history().count == 2)
    #expect(!FileManager.default.fileExists(atPath: fixture.files.recoveryURL.path))
  }

  private static func recoveryRevision(name: String) -> ConfigurationRevision {
    let text = manifest(name: name)
    return ConfigurationRevision(
      digest: SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(),
      manifest: text, activatedAt: Date())
  }

  @Test(arguments: ["schema_version = 999\n", Self.manifest(name: "pending")])
  func unadmittedDiskChangesPreserveActiveReadsAndInvalidatePublication(text: String) throws {
    let fixture = try ManifestStoreFixture()
    defer { fixture.cleanup() }
    _ = try fixture.store.activate(
      manifest: Self.manifest(name: "original"),
      expectedDigest: try? fixture.store.admittedDigest(for: fixture.store.activeConfiguration()))
    let original = try fixture.store.activeConfiguration()
    try text.write(to: fixture.manifestURL, atomically: true, encoding: .utf8)
    #expect(try fixture.store.activeConfiguration() == original)
    var published = false
    #expect(throws: AtomicManifestStoreError.staleDigest) {
      try fixture.store.withCurrentConfiguration(original) { published = true }
    }
    #expect(!published)
    #expect(try fixture.store.history().count == 1)
    #expect(throws: AtomicManifestStoreError.staleDigest) {
      try fixture.store.activate(manifest: Self.manifest(name: "managed"))
    }
    _ = try fixture.store.activate(
      manifest: Self.manifest(name: "managed"),
      expectedDigest: try AtomicManifestStore.digest(of: Data(text.utf8)))
    #expect(try fixture.store.activeConfiguration().server.name == "managed")
    #expect(throws: AtomicManifestStoreError.staleDigest) {
      try fixture.store.withCurrentConfiguration(original) { published = true }
    }
    #expect(!published)
    let current = try fixture.store.activeConfiguration()
    try fixture.store.withCurrentConfiguration(current) { published = true }
    #expect(published)
  }

  @Test(.timeLimit(.minutes(1)))
  func externalFileNotificationsRequireExplicitAdmission() async throws {
    let fixture = try ManifestStoreFixture()
    defer { fixture.cleanup() }
    _ = try fixture.store.activate(
      manifest: Self.manifest(name: "original"),
      expectedDigest: try? fixture.store.admittedDigest(for: fixture.store.activeConfiguration()))
    let monitor = try DirectoryEventFileChangeMonitor(fileURL: fixture.manifestURL)
    var invalidations = monitor.changes.makeAsyncIterator()
    _ = await invalidations.next()
    let stream = fixture.store.changes()
    let change = Task { await stream.first(where: { $0.reason == .externalReload }) }
    defer { change.cancel() }
    try Self.manifest(name: "external").write(
      to: fixture.manifestURL, atomically: true, encoding: .utf8)
    _ = await invalidations.next()
    #expect(try fixture.store.activeConfiguration().server.name == "original")
    #expect(try fixture.store.history().count == 1)
    let input = try #require(try fixture.store.externalInput())
    _ = try fixture.store.commit(
      fixture.store.prepare(
        manifest: input.manifest, reason: .externalReload, expectedDigest: input.digest))
    let event = try #require(await change.value)
    #expect(event.reason == .externalReload)
    #expect(try fixture.store.activeConfiguration().server.name == "external")
    #expect(try fixture.store.history().count == 2)
    await monitor.close()
  }

  @Test
  func testActivationValidatesPersistsSynchronizesAndPublishes() async throws {
    let fixture = try ManifestStoreFixture()
    defer { fixture.cleanup() }
    let stream = fixture.store.changes()
    let eventTask = Task { await stream.first(where: { _ in true }) }

    let revision = try fixture.store.activate(
      manifest: validManifest(name: "first"),
      expectedDigest: try? fixture.store.admittedDigest(for: fixture.store.activeConfiguration()))
    let event = await eventTask.value

    #expect((event?.revision.id) == (revision.id))
    #expect((event?.reason) == (.activated))
    #expect((try fixture.store.activeConfiguration().server.name) == ("first"))
    let stored = try #require(try fixture.database.configurationRevisions().first)
    #expect((stored.id) == (revision.id))
    #expect((stored.digest) == (revision.digest))
    #expect((stored.manifest) == (revision.manifest))
    #expect((stored.activatedAt) != nil)
    #expect((stored.activationError) == nil)
    #expect((try permissions(at: fixture.manifestURL)) == (0o600))
    #expect(
      !(try FileManager.default.contentsOfDirectory(
        atPath: fixture.manifestURL.deletingLastPathComponent().path
      ).contains { $0.contains(".staged.") }))
  }

  @Test
  func testInvalidManifestDoesNotReplaceActiveConfiguration() throws {
    let fixture = try ManifestStoreFixture()
    defer { fixture.cleanup() }
    let original = validManifest(name: "original")
    _ = try fixture.store.activate(
      manifest: original,
      expectedDigest: try? fixture.store.admittedDigest(for: fixture.store.activeConfiguration()))

    expectThrows(
      try fixture.store.activate(
        manifest: "schema_version = 999\n",
        expectedDigest: try? fixture.store.admittedDigest(for: fixture.store.activeConfiguration()))
    )

    #expect((try String(contentsOf: fixture.manifestURL, encoding: .utf8)) == (original))
    #expect((try fixture.store.activeConfiguration().server.name) == ("original"))
  }

  @Test
  func testRollbackCreatesNewActivatedRevision() throws {
    let fixture = try ManifestStoreFixture()
    defer { fixture.cleanup() }
    let first = try fixture.store.activate(
      manifest: validManifest(name: "first"),
      expectedDigest: try? fixture.store.admittedDigest(for: fixture.store.activeConfiguration()))
    _ = try fixture.store.activate(
      manifest: validManifest(name: "second"),
      expectedDigest: try? fixture.store.admittedDigest(for: fixture.store.activeConfiguration()))

    let rollback = try fixture.store.rollback(
      to: first.id,
      expectedDigest: try fixture.store.admittedDigest(for: fixture.store.activeConfiguration()))

    #expect((rollback.id) != (first.id))
    #expect((rollback.digest) == (first.digest))
    #expect((try fixture.store.activeConfiguration().server.name) == ("first"))
    #expect((try fixture.store.history().count) == (3))
  }

  @Test
  func testUnknownRollbackAndMissingManifestFailClosed() throws {
    let fixture = try ManifestStoreFixture()
    defer { fixture.cleanup() }

    expectThrows(try fixture.store.activeConfiguration()) { error in
      #expect((error as? AtomicManifestStoreError) == (.manifestMissing))
    }
    expectThrows(try fixture.store.rollback(to: "missing", expectedDigest: "unavailable")) {
      error in
      #expect((error as? AtomicManifestStoreError) == (.unknownRevision("missing")))
    }
  }

  private func validManifest(name: String) -> String {
    Self.manifest(name: name)
  }

  @Test
  func concurrentReviewedChangesOnlyActivateOneRevision() async throws {
    let fixture = try ManifestStoreFixture()
    defer { fixture.cleanup() }
    let store = fixture.store
    let original = try store.activate(
      manifest: Self.manifest(name: "original"),
      expectedDigest: try? store.admittedDigest(for: store.activeConfiguration()))
    let winners = try await withThrowingTaskGroup(of: String?.self) { group in
      for name in ["first", "second"] {
        group.addTask {
          do {
            _ = try store.activate(
              manifest: Self.manifest(name: name), expectedDigest: original.digest)
            return name
          } catch let error as AtomicManifestStoreError
            where error == .staleDigest || error == .changeInProgress
          {
            return nil
          }
        }
      }
      var winners: [String] = []
      for try await name in group { if let name { winners.append(name) } }
      return winners
    }
    try #require(winners.count == 1)
    #expect(try store.activeConfiguration().server.name == winners[0])
    #expect(try store.history().count == 2)
    #expect(throws: AtomicManifestStoreError.staleDigest) {
      try store.activate(manifest: original.manifest, expectedDigest: original.digest)
    }
    #expect(try store.activeConfiguration().server.name == winners[0])
    #expect(try store.history().count == 2)
  }

  @Test(arguments: ["success", "file", "database", "validation"])
  func projectManifestUpgradeIsAtomicAndRetryable(failure: String) throws {
    let fixture = try ManifestStoreFixture(persistent: true)
    defer { fixture.cleanup() }
    let text = """
      schema_version = 1
      [builtin]
      enabled = ["workspace.instructions"]
      [[workspaces]]
      id = "workspace-id"
      display_name = "workspace.list"
      path = "/tmp/workspace"
      [[profiles]]
      id = "local-admin"
      mode = "workspace-operations"
      capabilities = ["workspace.list"]
      workspaces = ["workspace-id"]
      allowed_callers = ["local-cli"]
      """
    try Data(text.utf8).write(to: fixture.manifestURL)
    let historical = ConfigurationRevision(
      digest: try AtomicManifestStore.digest(of: Data(text.utf8)), manifest: text)
    try fixture.database.saveConfigurationRevision(historical)
    let platform = MacOSPlatform.services(launcher: testExecutionLauncher())
    let loader = GatewayManifestConfigurationLoader(
      database: fixture.database,
      applications: platform.applications)
    let connection = fixture.database.connection.writer
    if failure == "database" {
      try connection.write {
        try $0.execute(
          sql:
            "CREATE TRIGGER refuse_upgrade BEFORE INSERT ON configurationRevisions BEGIN SELECT RAISE(ABORT, 'fixture'); END"
        )
      }
    }
    if failure == "validation" {
      try Data((text + "unknown = true\n").utf8).write(to: fixture.manifestURL)
    }
    let original = try Data(contentsOf: fixture.manifestURL)
    if failure != "success" {
      #expect(throws: (any Error).self) {
        _ = try AtomicManifestStore.activatePermissionMigration(
          manifestURL: fixture.manifestURL, database: fixture.database,
          applications: platform.applications)
        _ = try AtomicManifestStore(
          manifestURL: fixture.manifestURL, database: fixture.database, loader: loader,
          fileManager: failure == "file"
            ? RejectingManifestMetadata(manifestURL: fixture.manifestURL) : .default)
      }
      #expect(try Data(contentsOf: fixture.manifestURL) == original)
      #expect(try fixture.database.configurationRevisions().count == 1)
      if failure == "database" {
        try connection.write { try $0.execute(sql: "DROP TRIGGER refuse_upgrade") }
      }
      if failure == "validation" { try Data(text.utf8).write(to: fixture.manifestURL) }
    }
    let admissionDatabase = fixture.database
    _ = admissionDatabase.permissionStore(counter: fixture.counter)
    _ = try AtomicManifestStore.activatePermissionMigration(
      manifestURL: fixture.manifestURL, database: admissionDatabase,
      applications: platform.applications)
    let store = try AtomicManifestStore(
      manifestURL: fixture.manifestURL, database: admissionDatabase, loader: loader)
    let config = try store.activeConfiguration()
    #expect(config.projects.first?.id == "workspace-id")
    #expect(config.projects.first?.displayName == "workspace.list")
    #expect(
      config.profiles.first?.grant.permissions.state(for: .project("workspace-id"))
        == .granted(.read))
    #expect(config.profiles.first?.grant.fullAccess == false)
    #expect(config.builtin.enabled == ["project.instructions"])
    #expect(try store.history().count == 2)
    #expect(try admissionDatabase.configurationRevision(id: historical.id)?.manifest == text)
    let bytes = try Data(contentsOf: fixture.manifestURL)
    _ = try AtomicManifestStore(
      manifestURL: fixture.manifestURL, database: admissionDatabase, loader: loader)
    #expect(try Data(contentsOf: fixture.manifestURL) == bytes)
    #expect(try store.history().count == 2)

    let savedHistorical = try #require(
      try admissionDatabase.configurationRevision(id: historical.id))
    #expect(throws: (any Error).self) {
      try store.rollback(to: historical.id, expectedDigest: AtomicManifestStore.digest(of: bytes))
    }
    #expect(try store.activeConfiguration() == config)
    #expect(try Data(contentsOf: fixture.manifestURL) == bytes)
    #expect(try store.history().count == 2)
    #expect(try admissionDatabase.configurationRevision(id: historical.id) == savedHistorical)
  }

  private static func manifest(name: String) -> String {
    """
    schema_version = 1

    [server]
    name = "\(name)"
    """
  }

  private func permissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
  }
}

private struct ManifestWriteFailure: Error {}

private final class MutatingManifestLoader: ManifestConfigurationLoading, @unchecked Sendable {
  let externalURL: URL?
  let replacement: String
  private let lock = NSLock()
  private var armed = false
  private var mutationApplied = false

  init(externalURL: URL?, replacement: String) {
    self.externalURL = externalURL
    self.replacement = replacement
  }

  var didMutate: Bool { lock.withLock { mutationApplied } }

  func arm() { lock.withLock { armed = true } }

  func load(path: String) throws -> GatewayConfiguration {
    let loaded = try GatewayConfiguration.load(path: path)
    let shouldMutate = lock.withLock {
      guard armed else { return false }
      armed = false
      return true
    }
    if shouldMutate {
      try replacement.write(
        to: externalURL ?? URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
      lock.withLock { mutationApplied = true }
    }
    return loaded
  }
}

private final class ManifestMetadataProbe: FileManager, @unchecked Sendable {
  let manifestURL: URL
  private(set) var replacedData: Data?

  init(manifestURL: URL) {
    self.manifestURL = manifestURL
    super.init()
  }

  override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String)
    throws
  {
    if path == manifestURL.path { replacedData = try Data(contentsOf: manifestURL) }
    try super.setAttributes(attributes, ofItemAtPath: path)
  }
}

private final class RejectingRecoveryCleanup: FileManager, @unchecked Sendable {
  let recoveryURL: URL

  init(recoveryURL: URL) {
    self.recoveryURL = recoveryURL
    super.init()
  }

  override func removeItem(at url: URL) throws {
    if url == recoveryURL { throw ManifestWriteFailure() }
    try super.removeItem(at: url)
  }
}

private final class RejectingManifestMetadata: FileManager, @unchecked Sendable {
  let manifestURL: URL
  private(set) var didReject = false

  init(manifestURL: URL) {
    self.manifestURL = manifestURL
    super.init()
  }

  override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String)
    throws
  {
    if path == manifestURL.path {
      didReject = true
      throw ManifestWriteFailure()
    }
    try super.setAttributes(attributes, ofItemAtPath: path)
  }
}

private final class ManifestStoreFixture {
  let root: URL
  let manifestURL: URL
  let database: GatewayDatabase
  let store: AtomicManifestStore
  let counter = TestAuthorizationEpochCounter()

  init(persistent: Bool = false) throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    manifestURL = root.appendingPathComponent("Configuration/computer-mcp.toml")
    if persistent {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      database = try GatewayDatabase(path: root.appendingPathComponent("state.sqlite").path)
    } else {
      database = try GatewayDatabase(inMemory: ())
    }
    _ = database.permissionStore(counter: counter)
    var platform = MacOSPlatform.services(launcher: testExecutionLauncher())
    platform.permissionPolicyReader = TestManagedPolicyReader()
    _ = try database.permissionRuntime(platform: platform)
    store = try AtomicManifestStore(
      manifestURL: manifestURL, database: database,
      loader: GatewayManifestConfigurationLoader(
        database: database,
        applications: MacOSPlatform.services(launcher: testExecutionLauncher()).applications))
  }

  var files: ManifestFileTransaction {
    ManifestFileTransaction(manifestURL: manifestURL, database: database, fileManager: .default)
  }

  func writeJournal(_ revision: ConfigurationRevision, previous: Data?, version: Int = 1) throws {
    try ManifestFileTransaction.writeAndSynchronize(
      JSONEncoder().encode(
        ManifestRecoveryRecord(version: version, revision: revision, previous: previous)),
      to: files.recoveryURL)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }
}
