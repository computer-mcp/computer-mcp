import Foundation
import Testing

@testable import ComputerMCP

@Suite

final class AtomicManifestStoreTests {
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

private final class ManifestStoreFixture {
  let root: URL
  let manifestURL: URL
  let database: GatewayDatabase
  let store: AtomicManifestStore

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    manifestURL = root.appendingPathComponent("Configuration/computer-mcp.toml")
    database = try GatewayDatabase(inMemory: ())
    store = try AtomicManifestStore(manifestURL: manifestURL, database: database)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }
}
