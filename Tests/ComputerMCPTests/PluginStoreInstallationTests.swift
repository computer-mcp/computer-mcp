import Darwin
import Foundation
import Testing

@testable import ComputerMCP

@Suite(.timeLimit(.minutes(1)))
struct PluginStoreInstallationTests {
  @Test
  func installUpdateRollbackAndUninstallPreserveHostChoicesAndExternalFiles() async throws {
    let fixture = try await PreparationFixture.make()
    defer { fixture.files.remove() }
    let update = try await PreparationFixture.make(
      manifest: PreparationFixture.manifest.replacingOccurrences(of: "1.2.3", with: "1.2.4"))
    defer { update.files.remove() }
    let databaseURL = fixture.files.root.appendingPathComponent("gateway.sqlite")
    let database = try GatewayDatabase(path: databaseURL.path)
    let store = PluginStore(database: database)
    try database.saveWorkspace(
      .init(id: "unrelated", displayName: "Keep", rootPath: fixture.files.root.path))
    let first = try await fixture.install(into: store, revision: 0)
    #expect(first.issues.isEmpty)
    let original = try #require(first.snapshot.installations.first)
    #expect(original.source.kind == .artifact)
    #expect(original.source.artifactSHA256 == fixture.digest)
    #expect(original.source.repository == nil)
    #expect(first.snapshot.settings["combined"]?.enabled == false)
    #expect(first.snapshot.settings["combined"]?.mcp["native"]?.allowedTools == [])
    #expect(first.snapshot.settings["combined"]?.cli["commands"]?.allowAnyArgs == false)
    let root = original.source.root
    #expect(try PluginPackage.load(at: root).manifest.id == "combined")
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("executed").path))
    #expect(
      !FileManager.default.fileExists(
        atPath: root.deletingLastPathComponent().appendingPathComponent("staging").path))
    var settings = try #require(first.snapshot.settings["combined"])
    settings.enabled = true
    settings.mcp["native"] = PluginMCPSettings(
      allowedTools: ["inspect"], args: ["--local-setting", "", "value with spaces"])
    settings.dependencyExecutables["external"] = "/user-owned/vendor"
    _ = try await store.setSettings(settings, for: "combined", expectedRevision: 1)
    let second = try await update.install(
      into: store, revision: 2, storageRoot: fixture.installationRoot, version: "1.2.4")
    let latest = try #require(second.snapshot.installations.last)
    #expect(second.snapshot.installations.count == 2)
    #expect(second.snapshot.settings["combined"] == settings)
    #expect(second.snapshot.selectedInstallations["combined"] == latest.id)
    #expect(FileManager.default.fileExists(atPath: original.source.root.path))
    let rollback = try await store.select(
      installationID: original.id, for: "combined", expectedRevision: 3)
    #expect(rollback.selectedInstallations["combined"] == original.id)
    let reopened = PluginStore(database: try GatewayDatabase(path: databaseURL.path))
    #expect(try await reopened.snapshot() == rollback)
    #expect(try await reopened.recoverInstallations(storageRoot: fixture.installationRoot).isEmpty)
    let removed = try await reopened.uninstallArtifact(
      installationID: latest.id, storageRoot: fixture.installationRoot, expectedRevision: 4)
    #expect(removed.issues.isEmpty)
    #expect(removed.snapshot.selectedInstallations["combined"] == original.id)
    #expect(removed.snapshot.settings["combined"] == settings)
    #expect(!FileManager.default.fileExists(atPath: latest.source.root.path))
    #expect(FileManager.default.fileExists(atPath: original.source.root.path))
    let final = try await reopened.uninstallArtifact(
      installationID: original.id, storageRoot: fixture.installationRoot, expectedRevision: 5)
    #expect(final.snapshot.installations.isEmpty)
    #expect(final.snapshot.selectedInstallations.isEmpty)
    #expect(final.snapshot.settings["combined"] == settings)
    #expect(try database.pluginOwnedDirectories().isEmpty)
    #expect(try database.workspace(id: "unrelated")?.displayName == "Keep")
    #expect(try fixture.currentDigest() == fixture.digest)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.installationRoot.path) == [
        "store.lock"
      ])
  }

  @Test(arguments: ["hash", "manifest", "composition"])
  func failedInstallationDoesNotChangeTheSelectedVersion(failure: String) async throws {
    let fixture = try await PreparationFixture.make()
    defer { fixture.files.remove() }
    let database = try GatewayDatabase(inMemory: ())
    let store = PluginStore(database: database)
    let first = try await fixture.install(into: store, revision: 0)
    let rejecting = PluginStore(database: database) { _ in throw PluginArchiveError.conflictingPath
    }
    if failure == "manifest" {
      let bad = try await PreparationFixture.make(manifest: "invalid")
      defer { bad.files.remove() }
      await #expect(throws: PluginArchiveError.invalidPackage) {
        try await bad.install(into: store, revision: 1, storageRoot: fixture.installationRoot)
      }
    } else {
      await #expect(
        throws: failure == "hash" ? PluginArchiveError.checksumMismatch : .conflictingPath
      ) {
        try await fixture.install(
          into: failure == "hash" ? store : rejecting, revision: 1,
          hash: failure == "hash" ? String(repeating: "0", count: 64) : fixture.digest)
      }
    }
    #expect(try await store.snapshot() == first.snapshot)
    #expect(try database.pluginOwnedDirectories().count == 1)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.installationRoot.path).count == 2)
  }

  @Test
  func suspendedInstallationRechecksRevisionAndHoldsTheCrossStoreLock() async throws {
    let fixture = try await PreparationFixture.make()
    defer { fixture.files.remove() }
    let database = try GatewayDatabase(inMemory: ())
    let store = PluginStore(database: database)
    let other = PluginStore(database: database)
    let ready = fixture.files.root.appendingPathComponent("ready")
    let release = fixture.files.root.appendingPathComponent("release")
    let worker = try await fixture.stub(
      """
      import os, signal, sys, time
      signal.alarm(15)
      open(\(try fixture.literal(ready.path)), 'w').close()
      while not os.path.exists(\(try fixture.literal(release.path))): time.sleep(0.01)
      os.execv(\(try fixture.literal(fixture.preparation.workerExecutable.path)),
        [\(try fixture.literal(fixture.preparation.workerExecutable.path))] + sys.argv[1:])
      """)
    let installing = Task { try await fixture.install(into: store, revision: 0, worker: worker) }
    do {
      try await waitForFile(ready)
      await #expect(throws: PluginStoreError.installationBusy) {
        try await other.recoverInstallations(storageRoot: fixture.installationRoot)
      }
      let changed = try await other.setEnabled(false, for: "another", expectedRevision: 0)
      try Data().write(to: release)
      await #expect(throws: PluginStoreError.staleRevision(expected: 0, actual: 1)) {
        try await installing.value
      }
      #expect(try await store.snapshot() == changed)
      #expect(try database.pluginOwnedDirectories().isEmpty)
      #expect(
        try FileManager.default.contentsOfDirectory(atPath: fixture.installationRoot.path) == [
          "store.lock"
        ])
    } catch {
      installing.cancel()
      _ = try? await installing.value
      throw error
    }
  }

  @Test
  func cancellationReapsWorkerBeforeRemovingOwnedFiles() async throws {
    let fixture = try await PreparationFixture.make()
    defer { fixture.files.remove() }
    let database = try GatewayDatabase(inMemory: ())
    let store = PluginStore(database: database)
    let ready = fixture.files.root.appendingPathComponent("ready")
    let worker = try await fixture.stub(
      """
      import os, signal, time
      signal.alarm(15)
      with open(\(try fixture.literal(ready.path)), 'w') as f: f.write(str(os.getpid()))
      time.sleep(30)
      """)
    let installing = Task { try await fixture.install(into: store, revision: 0, worker: worker) }
    do { try await waitForFile(ready) } catch {
      installing.cancel()
      _ = try? await installing.value
      throw error
    }
    installing.cancel()
    await #expect(throws: CancellationError.self) { try await installing.value }
    let pid = try #require(Int32(String(contentsOf: ready, encoding: .utf8)))
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
    #expect(try await store.snapshot() == PluginStoreSnapshot())
    #expect(try database.pluginOwnedDirectories().isEmpty)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.installationRoot.path) == [
        "store.lock"
      ])
  }

  @Test
  func workerKeepsLockAfterParentReferenceCloses() async throws {
    let fixture = try await PreparationFixture.make()
    defer { fixture.files.remove() }
    var storage: PluginInstallationStorage? = try PluginInstallationStorage(
      at: fixture.installationRoot)
    var preparation = fixture.preparation
    preparation.inheritedLockDescriptor = try #require(storage).lockDescriptor
    let ready = fixture.files.root.appendingPathComponent("ready")
    let worker = try await fixture.stub(
      """
      import os, signal, time
      signal.alarm(15)
      open(\(try fixture.literal(ready.path)), 'w').close()
      time.sleep(30)
      """)
    let lockedPreparation = PluginArchivePreparation(
      workerExecutable: worker, stagingParent: preparation.stagingParent,
      inheritedLockDescriptor: preparation.inheritedLockDescriptor)
    let task = Task {
      try await lockedPreparation.withPreparedPackage(
        archive: fixture.archive, expectedSHA256: fixture.digest,
        pluginID: "combined", version: PluginVersion("1.2.3"), hostVersion: PluginVersion("1.0.0"),
        architecture: "arm64"
      ) { _, _ in
        Issue.record("Sleeping worker cannot produce a package")
      }
    }
    do { try await waitForFile(ready) } catch {
      task.cancel()
      _ = try? await task.value
      throw error
    }
    storage?.close()
    #expect(throws: PluginStoreError.installationBusy) {
      try PluginInstallationStorage(at: fixture.installationRoot)
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    let next = try PluginInstallationStorage(at: fixture.installationRoot)
    storage?.close()
    storage = nil
    // Closing the retained old lease again must not close a reused descriptor.
    #expect(throws: PluginStoreError.installationBusy) {
      try PluginInstallationStorage(at: fixture.installationRoot)
    }
    next.close()
    withExtendedLifetime(next) {}
  }

  @Test
  func recoveryRemovesOnlyReceiptedUncommittedDirectories() async throws {
    let fixture = try await PreparationFixture.make()
    defer { fixture.files.remove() }
    let databaseURL = fixture.files.root.appendingPathComponent("gateway.sqlite")
    let database = try GatewayDatabase(path: databaseURL.path)
    let owned: PluginOwnedDirectory
    do {
      let storage = try PluginInstallationStorage(at: fixture.installationRoot)
      defer { storage.finishTransaction() }
      let identity = try storage.createInstallation()
      owned = PluginOwnedDirectory(
        installationID: identity.url.lastPathComponent, pluginID: "combined", identity: identity)
      try database.recordPluginDirectory(owned)
      try Data("partial".utf8).write(to: identity.url.appendingPathComponent("staging/partial"))
    }
    let unknown = fixture.installationRoot.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: false)
    let store = PluginStore(database: try GatewayDatabase(path: databaseURL.path))
    #expect(try await store.recoverInstallations(storageRoot: fixture.installationRoot).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: owned.identity.url.path))
    #expect(FileManager.default.fileExists(atPath: unknown.path))
    #expect(try database.pluginOwnedDirectories().isEmpty)
    #expect(try await store.snapshot().revision == 0)
    #expect(try await store.recoverInstallations(storageRoot: fixture.installationRoot).isEmpty)
  }

  @Test(arguments: [false, true])
  func recoveryPreservesReplacedAndOutOfRootDirectories(outside: Bool) async throws {
    let fixture = try await PreparationFixture.make()
    defer { fixture.files.remove() }
    let database = try GatewayDatabase(inMemory: ())
    let owned: PluginOwnedDirectory
    do {
      let storage = try PluginInstallationStorage(at: fixture.installationRoot)
      defer { storage.finishTransaction() }
      let identity = try storage.createInstallation()
      owned = PluginOwnedDirectory(
        installationID: identity.url.lastPathComponent, pluginID: "combined", identity: identity)
      try database.recordPluginDirectory(owned)
    }
    if !outside {
      try FileManager.default.moveItem(
        at: owned.identity.url, to: fixture.files.root.appendingPathComponent("moved"))
      try FileManager.default.createDirectory(
        at: owned.identity.url, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    }
    let store = PluginStore(database: database)
    let issues = try await store.recoverInstallations(
      storageRoot: outside
        ? fixture.files.root.appendingPathComponent("other-store") : fixture.installationRoot)
    #expect(issues.count == 1)
    #expect(FileManager.default.fileExists(atPath: owned.identity.url.path))
    #expect(try database.pluginOwnedDirectories() == [owned])
  }

  @Test
  func postCommitCleanupFailureKeepsInstalledPayloadAndRecoversOnReopen() async throws {
    let fixture = try await PreparationFixture.make()
    defer { fixture.files.remove() }
    let database = try GatewayDatabase(inMemory: ())
    let store = PluginStore(database: database) { proposed in
      let record = try #require(proposed.installations.first)
      let staging = record.source.root.deletingLastPathComponent().appendingPathComponent("staging")
      let name = try #require(FileManager.default.contentsOfDirectory(atPath: staging.path).first)
      let job = staging.appendingPathComponent(name)
      try FileManager.default.moveItem(at: job, to: staging.appendingPathComponent("held"))
      try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false)
    }
    let installed = try await fixture.install(into: store, revision: 0)
    #expect(installed.snapshot.revision == 1)
    #expect(installed.issues.count == 1)
    let record = try #require(installed.snapshot.installations.first)
    #expect(try PluginPackage.load(at: record.source.root).manifest.id == "combined")
    #expect(try database.pluginOwnedDirectories().count == 1)
    let reopened = PluginStore(database: database)
    #expect(try await reopened.recoverInstallations(storageRoot: fixture.installationRoot).isEmpty)
    #expect(try await reopened.snapshot() == installed.snapshot)
    #expect(
      !FileManager.default.fileExists(
        atPath: record.source.root.deletingLastPathComponent().appendingPathComponent("staging")
          .path))
  }

  @Test
  func uninstallCommitsRevocationButNeverDeletesAReplacementDirectory() async throws {
    let fixture = try await PreparationFixture.make()
    defer { fixture.files.remove() }
    let database = try GatewayDatabase(inMemory: ())
    let store = PluginStore(database: database)
    let installed = try await fixture.install(into: store, revision: 0)
    let record = try #require(installed.snapshot.installations.first)
    let container = record.source.root.deletingLastPathComponent()
    try FileManager.default.moveItem(
      at: container, to: fixture.files.root.appendingPathComponent("moved"))
    try FileManager.default.createDirectory(
      at: container, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let sentinel = container.appendingPathComponent("keep")
    try Data("user data".utf8).write(to: sentinel)
    let removed = try await store.uninstallArtifact(
      installationID: record.id, storageRoot: fixture.installationRoot, expectedRevision: 1)
    #expect(removed.snapshot.installations.isEmpty)
    #expect(removed.snapshot.revision == 2)
    #expect(removed.issues.count == 1)
    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "user data")
    #expect(try database.pluginOwnedDirectories().count == 1)
  }
}

@Suite(.timeLimit(.minutes(1)))
struct PluginInstallationStorageTests {
  @Test
  func completedTransactionReleasesLockEvenWhileAnUnrelatedDuplicateSurvives() async throws {
    let fixture = try await PreparationFixture.make()
    defer { fixture.files.remove() }
    let storage = try PluginInstallationStorage(at: fixture.installationRoot)
    let duplicate = fcntl(storage.lockDescriptor, F_DUPFD_CLOEXEC, 0)
    try #require(duplicate >= 0)
    defer { close(duplicate) }
    storage.finishTransaction()
    let next = try PluginInstallationStorage(at: fixture.installationRoot)
    defer { next.finishTransaction() }
    storage.finishTransaction()
    #expect(throws: PluginStoreError.installationBusy) {
      try PluginInstallationStorage(at: fixture.installationRoot)
    }
    #expect(throws: PluginArchiveError.fileSystemFailure) { try storage.createInstallation() }
  }

  @Test(arguments: ["missing", "symlink", "file", "public"])
  func recoveryReportsInvalidCommittedPayloadWithoutRevokingItsRecord(kind: String) async throws {
    let fixture = try await PreparationFixture.make()
    defer { fixture.files.remove() }
    let database = try GatewayDatabase(inMemory: ())
    let store = PluginStore(database: database)
    let installed = try await fixture.install(into: store, revision: 0)
    let record = try #require(installed.snapshot.installations.first)
    if kind == "public" {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: record.source.root.path)
    } else {
      try FileManager.default.removeItem(at: record.source.root)
      if kind == "symlink" {
        try FileManager.default.createSymbolicLink(
          at: record.source.root, withDestinationURL: fixture.staging)
      } else if kind == "file" {
        try Data("keep".utf8).write(to: record.source.root)
      }
    }
    let issues = try await store.recoverInstallations(storageRoot: fixture.installationRoot)
    #expect(issues.count == 1)
    #expect(try await store.snapshot() == installed.snapshot)
    #expect(try database.pluginOwnedDirectories().count == 1)
    #expect(FileManager.default.fileExists(atPath: fixture.staging.path))
  }

  @Test
  func anotherRegistrationInsideThePackagePreventsUninstall() async throws {
    let fixture = try await PreparationFixture.make()
    defer { fixture.files.remove() }
    let database = try GatewayDatabase(inMemory: ())
    let store = PluginStore(database: database)
    let installed = try await fixture.install(into: store, revision: 0)
    let record = try #require(installed.snapshot.installations.first)
    let registered = try await store.registerDevelopment(
      at: record.source.root, expectedRevision: 1)
    await #expect(throws: PluginStoreError.invalidState) {
      try await store.uninstallArtifact(
        installationID: record.id, storageRoot: fixture.installationRoot, expectedRevision: 2)
    }
    #expect(try await store.snapshot() == registered)
    #expect(FileManager.default.fileExists(atPath: record.source.root.path))
  }

  @Test
  func recoveryForgetsAlreadyMissingUncommittedDirectoryWithoutChangingSettings() async throws {
    let fixture = try await PreparationFixture.make()
    defer { fixture.files.remove() }
    let database = try GatewayDatabase(inMemory: ())
    do {
      let storage = try PluginInstallationStorage(at: fixture.installationRoot)
      defer { storage.finishTransaction() }
      let identity = try storage.createInstallation()
      try database.recordPluginDirectory(
        .init(
          installationID: identity.url.lastPathComponent, pluginID: "combined", identity: identity))
      try storage.clean(identity, keepingPackage: false)
    }
    let store = PluginStore(database: database)
    #expect(try await store.recoverInstallations(storageRoot: fixture.installationRoot).isEmpty)
    #expect(try database.pluginOwnedDirectories().isEmpty)
    #expect(try await store.snapshot() == PluginStoreSnapshot())
  }

  @Test(arguments: [
    "root-symlink", "root-public", "lock-symlink", "lock-fifo", "lock-public", "lock-hardlink",
  ])
  func rejectsUnsafeStorageWithoutChangingExternalFiles(kind: String) async throws {
    let fixture = try await PreparationFixture.make()
    defer { fixture.files.remove() }
    let external = fixture.files.root.appendingPathComponent("external")
    try Data("keep".utf8).write(to: external)
    let root = fixture.installationRoot
    if kind == "root-symlink" {
      try FileManager.default.createSymbolicLink(at: root, withDestinationURL: fixture.staging)
    } else {
      try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: false,
        attributes: [.posixPermissions: kind == "root-public" ? 0o755 : 0o700])
      let lock = root.appendingPathComponent("store.lock")
      switch kind {
      case "lock-symlink":
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: external)
      case "lock-fifo":
        try #require(mkfifo(lock.path, 0o600) == 0)
      case "lock-public":
        try Data().write(to: lock)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lock.path)
      case "lock-hardlink":
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o600], ofItemAtPath: external.path)
        try #require(link(external.path, lock.path) == 0)
      default: break
      }
    }
    #expect(throws: PluginArchiveError.self) { try PluginInstallationStorage(at: root) }
    #expect(try String(contentsOf: external, encoding: .utf8) == "keep")
  }
}

extension PreparationFixture {
  fileprivate var installationRoot: URL {
    files.root.appendingPathComponent("installations", isDirectory: true)
  }

  fileprivate func install(
    into store: PluginStore, revision: Int64, storageRoot: URL? = nil,
    version: String = "1.2.3", hash: String? = nil, worker: URL? = nil
  ) async throws -> PluginStoreMutation {
    return try await store.installArchive(
      at: archive, expectedSHA256: hash ?? digest, pluginID: "combined",
      version: PluginVersion(version), hostVersion: PluginVersion("1.0.0"), architecture: "arm64",
      storageRoot: storageRoot ?? installationRoot,
      workerExecutable: worker ?? preparation.workerExecutable,
      expectedRevision: revision)
  }
}

private func waitForFile(_ url: URL) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(10))
  while !FileManager.default.fileExists(atPath: url.path), ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
  try #require(FileManager.default.fileExists(atPath: url.path))
}
