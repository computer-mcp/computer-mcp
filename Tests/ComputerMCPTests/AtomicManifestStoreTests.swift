import CryptoKit
import Foundation
import GRDB
import Testing

@testable import ComputerMCP

@Suite

final class AtomicManifestStoreTests {
  @Test(arguments: ["publish", "conflict", "file"])
  func preparedPublicationCommitsFileAndResolutionTogether(outcome: String) throws {
    let fixture = try ManifestStoreFixture()
    defer { fixture.cleanup() }
    let original = try fixture.store.activate(manifest: Self.manifest(name: "original"))
    try fixture.database.saveWorkspace(
      .init(id: "workspace", displayName: "Workspace", rootPath: fixture.root.path))
    let before = try fixture.database.configurationState()
    let store = try AtomicManifestStore(
      manifestURL: fixture.manifestURL, database: fixture.database,
      fileManager: outcome == "file"
        ? RejectingManifestMetadata(manifestURL: fixture.manifestURL) : .default)
    let candidate = try store.prepare(
      manifest: Self.manifest(name: "candidate"), expectedDigest: original.digest)
    #expect(try store.activeConfiguration().server.name == "original")
    #expect(try fixture.database.configurationState() == before)
    #expect(try store.history().map(\.id) == [original.id])
    let workspace = try #require(before.workspaces.first)
    var refreshed = workspace
    refreshed.bookmarkData = Data([1, 2, 3])
    let resolution = GatewayConfigurationResolution(workspaces: [
      .init(original: workspace, resolved: refreshed)
    ])
    if outcome == "conflict" { try fixture.database.saveProfile(.operate) }
    var installed: GatewayDatabase.ConfigurationState?
    if outcome == "publish" {
      _ = try store.commit(candidate, resolution: resolution) { installed = $0 }
      #expect(installed == (try fixture.database.configurationState()))
      #expect(
        try fixture.database.workspace(id: workspace.id)?.bookmarkData == refreshed.bookmarkData)
      #expect(try store.activeConfiguration().server.name == "candidate")
      #expect(try store.history().count == 2)
    } else {
      #expect(throws: (any Error).self) {
        try store.commit(candidate, resolution: resolution) { installed = $0 }
      }
      #expect(installed == nil)
      #expect(try fixture.database.workspace(id: workspace.id) == workspace)
      #expect(try Data(contentsOf: fixture.manifestURL) == Data(original.manifest.utf8))
      #expect(try store.activeConfiguration().server.name == "original")
      #expect(try store.history().map(\.id) == [original.id])
    }
  }

  @Test
  func failedMetadataWriteRestoresFileAndRevisionAuthority() throws {
    let fixture = try ManifestStoreFixture()
    defer { fixture.cleanup() }
    let original = try fixture.store.activate(manifest: Self.manifest(name: "original"))
    let manager = RejectingManifestMetadata(manifestURL: fixture.manifestURL)
    let store = try AtomicManifestStore(
      manifestURL: fixture.manifestURL, database: fixture.database, fileManager: manager)
    #expect(try store.activeConfiguration().server.name == "original")
    #expect(throws: ManifestWriteFailure.self) {
      try store.activate(manifest: Self.manifest(name: "rejected"))
    }
    #expect(manager.didReject)
    #expect(try Data(contentsOf: fixture.manifestURL) == Data(original.manifest.utf8))
    #expect(try store.activeConfiguration().server.name == "original")
    #expect(try store.history().map(\.id) == [original.id])
    let reopened = try AtomicManifestStore(
      manifestURL: fixture.manifestURL, database: fixture.database)
    #expect(try reopened.activeConfiguration().server.name == "original")
  }

  @Test
  func deferredDatabaseCommitFailureRestoresReplacedFile() throws {
    let fixture = try ManifestStoreFixture(persistent: true)
    defer { fixture.cleanup() }
    let original = try fixture.store.activate(manifest: Self.manifest(name: "original"))
    let connection = try DatabaseQueue(path: try #require(fixture.database.fileURL).path)
    defer { try? connection.close() }
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
      manifestURL: fixture.manifestURL, database: fixture.database, fileManager: manager)
    let proposed = Self.manifest(name: "rejected")
    #expect(throws: DatabaseError.self) { try store.activate(manifest: proposed) }
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
      manifestURL: fixture.manifestURL, database: fixture.database, fileManager: manager)
    #expect(throws: ManifestWriteFailure.self) {
      try store.activate(manifest: Self.manifest(name: "rejected"))
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
    let original = try fixture.store.activate(manifest: Self.manifest(name: "original"))
    let external = Self.manifest(name: "external")
    let store = try AtomicManifestStore(
      manifestURL: fixture.manifestURL, database: fixture.database,
      loader: MutatingManifestLoader(
        externalURL: editActive ? fixture.manifestURL : nil, replacement: external))
    #expect(throws: AtomicManifestStoreError.staleDigest) {
      try store.activate(
        manifest: Self.manifest(name: "candidate"), expectedDigest: original.digest)
    }
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
      previous = nil
    } else {
      _ = try fixture.store.activate(manifest: Self.manifest(name: "original"))
      previous = try Data(contentsOf: fixture.manifestURL)
    }
    let revision = Self.recoveryRevision(name: "candidate")
    try fixture.writeJournal(revision, previous: previous)
    if diskReplaced {
      try Data(revision.manifest.utf8).write(to: fixture.manifestURL)
    }
    if committed { try fixture.database.saveConfigurationRevision(revision) }
    let reopenedDatabase = try GatewayDatabase(path: try #require(fixture.database.fileURL).path)
    let reopened = try AtomicManifestStore(
      manifestURL: fixture.manifestURL, database: reopenedDatabase)
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
    #expect(!FileManager.default.fileExists(atPath: fixture.files.recoveryURL.path))
  }

  @Test(arguments: [false, true])
  func recoveryPreservesUnrecognizedExternalEdits(committed: Bool) throws {
    let fixture = try ManifestStoreFixture()
    defer { fixture.cleanup() }
    _ = try fixture.store.activate(manifest: Self.manifest(name: "original"))
    let previous = try Data(contentsOf: fixture.manifestURL)
    let revision = Self.recoveryRevision(name: "candidate")
    try fixture.writeJournal(revision, previous: previous)
    if committed { try fixture.database.saveConfigurationRevision(revision) }
    let journal = try Data(contentsOf: fixture.files.recoveryURL)
    let external = Data(Self.manifest(name: "external").utf8)
    try external.write(to: fixture.manifestURL)
    #expect(throws: AtomicManifestStoreError.recoveryConflict(fixture.manifestURL.path)) {
      try AtomicManifestStore(manifestURL: fixture.manifestURL, database: fixture.database)
    }
    #expect(try Data(contentsOf: fixture.manifestURL) == external)
    #expect(try Data(contentsOf: fixture.files.recoveryURL) == journal)
    // Once the external edit is preserved elsewhere and a known state is restored,
    // the same journal can recover without inventing another activated revision.
    try Data(revision.manifest.utf8).write(to: fixture.manifestURL)
    let reopened = try AtomicManifestStore(
      manifestURL: fixture.manifestURL, database: fixture.database)
    #expect(
      try reopened.activeConfiguration().server.name == (committed ? "candidate" : "original"))
    #expect(try reopened.history().count == (committed ? 2 : 1))
  }

  @Test(arguments: ["malformed", "digest", "version", "symlink", "revision"])
  func invalidRecoveryEvidenceDoesNotMutateFiles(kind: String) throws {
    let fixture = try ManifestStoreFixture()
    defer { fixture.cleanup() }
    _ = try fixture.store.activate(manifest: Self.manifest(name: "original"))
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
      try AtomicManifestStore(manifestURL: fixture.manifestURL, database: fixture.database)
    }
    #expect(try Data(contentsOf: fixture.manifestURL) == previous)
    #expect(try Data(contentsOf: fixture.files.recoveryURL) == journal)
  }

  @Test
  func cooperatingStoresSerializeReviewedPublication() throws {
    let fixture = try ManifestStoreFixture()
    defer { fixture.cleanup() }
    let first = try fixture.store.activate(manifest: Self.manifest(name: "first"))
    let other = try AtomicManifestStore(
      manifestURL: fixture.manifestURL, database: fixture.database)
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
    _ = try fixture.store.activate(manifest: Self.manifest(name: "original"))
    let manager = RejectingRecoveryCleanup(recoveryURL: fixture.files.recoveryURL)
    let store = try AtomicManifestStore(
      manifestURL: fixture.manifestURL, database: fixture.database, fileManager: manager)
    let revision = try store.activate(manifest: Self.manifest(name: "committed"))
    #expect(try store.activeConfiguration().server.name == "committed")
    #expect(try fixture.database.configurationRevision(id: revision.id)?.digest == revision.digest)
    #expect(try permissions(at: fixture.files.recoveryURL) == 0o600)
    #expect(try permissions(at: fixture.manifestURL) == 0o600)
    let reopened = try AtomicManifestStore(
      manifestURL: fixture.manifestURL, database: fixture.database)
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
    _ = try fixture.store.activate(manifest: Self.manifest(name: "original"))
    let original = try fixture.store.activeConfiguration()
    try text.write(to: fixture.manifestURL, atomically: true, encoding: .utf8)
    #expect(try fixture.store.activeConfiguration() == original)
    var published = false
    #expect(throws: AtomicManifestStoreError.staleDigest) {
      try fixture.store.withCurrentConfiguration(original) { published = true }
    }
    #expect(!published)
    #expect(try fixture.store.history().count == 1)
    _ = try fixture.store.activate(manifest: Self.manifest(name: "managed"))
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
  func externalReloadAdmitsValidatedConfiguration() async throws {
    let fixture = try ManifestStoreFixture()
    defer { fixture.cleanup() }
    _ = try fixture.store.activate(manifest: Self.manifest(name: "original"))
    try fixture.store.startHotReloadMonitoring()
    defer { fixture.store.stopHotReloadMonitoring() }
    let stream = fixture.store.changes()
    let change = Task { await stream.first(where: { $0.reason == .externalReload }) }
    defer { change.cancel() }
    try Self.manifest(name: "external").write(
      to: fixture.manifestURL, atomically: true, encoding: .utf8)
    let event = try #require(await change.value)
    #expect(event.reason == .externalReload)
    #expect(try fixture.store.activeConfiguration().server.name == "external")
    #expect(try fixture.store.history().count == 2)
  }

  @Test
  func testActivationValidatesPersistsSynchronizesAndPublishes() async throws {
    let fixture = try ManifestStoreFixture()
    defer { fixture.cleanup() }
    let stream = fixture.store.changes()
    let eventTask = Task { await stream.first(where: { _ in true }) }

    let revision = try fixture.store.activate(manifest: validManifest(name: "first"))
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
    _ = try fixture.store.activate(manifest: original)

    expectThrows(try fixture.store.activate(manifest: "schema_version = 999\n"))

    #expect((try String(contentsOf: fixture.manifestURL, encoding: .utf8)) == (original))
    #expect((try fixture.store.activeConfiguration().server.name) == ("original"))
  }

  @Test
  func testRollbackCreatesNewActivatedRevision() throws {
    let fixture = try ManifestStoreFixture()
    defer { fixture.cleanup() }
    let first = try fixture.store.activate(manifest: validManifest(name: "first"))
    _ = try fixture.store.activate(manifest: validManifest(name: "second"))

    let rollback = try fixture.store.rollback(to: first.id)

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
    expectThrows(try fixture.store.rollback(to: "missing")) { error in
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
    let original = try store.activate(manifest: Self.manifest(name: "original"))
    let winners = try await withThrowingTaskGroup(of: String?.self) { group in
      for name in ["first", "second"] {
        group.addTask {
          do {
            _ = try store.activate(
              manifest: Self.manifest(name: name), expectedDigest: original.digest)
            return name
          } catch AtomicManifestStoreError.staleDigest {
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

private struct MutatingManifestLoader: ManifestConfigurationLoading {
  let externalURL: URL?
  let replacement: String

  func load(path: String) throws -> GatewayConfiguration {
    let loaded = try GatewayConfiguration.load(path: path)
    try replacement.write(
      to: externalURL ?? URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
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
    store = try AtomicManifestStore(manifestURL: manifestURL, database: database)
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
