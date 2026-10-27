import ComputerMCPPersistence
import Foundation
import Testing

@testable import ComputerMCPWorktrees

struct WorktreeCreationTests {
  @Test(arguments: ["sha1", "sha256"])
  func detachedCreationAndPrivateCommitsSurviveReopen(format: String) throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory, format: format)
      let service = try f.service()
      let original = try f.raw(["rev-parse", "HEAD"])
      let objectsBefore = try f.raw([
        "cat-file", "--batch-all-objects", "--batch-check=%(objectname)",
      ])
      let created = try service.create(name: "new-feature")
      #expect(created.branch == "worktree/new-feature")
      #expect(created.base == "main")
      #expect(
        created.path.deletingLastPathComponent().deletingLastPathComponent().path
          == f.storage.content.path)
      #expect(
        try String(contentsOf: created.path.appendingPathComponent("file.txt"), encoding: .utf8)
          == "initial\n")
      let record = try #require(f.store.records().first)
      #expect(record.state == .active && record.revision == 2)
      #expect(record.source == f.source)
      let privateHead = try f.privateCommit(service, projectID: created.projectID)
      #expect(privateHead != original)
      #expect(try f.raw(["rev-parse", created.branch]) == original)
      #expect(
        try f.raw(["cat-file", "--batch-all-objects", "--batch-check=%(objectname)"])
          == objectsBefore)
      let reopened = try SQLiteDerivedProjectStore(
        connection: GatewayDatabaseConnection(path: f.database.path))
      let restarted = try f.service(store: reopened)
      let topology = try restarted.topology(projectID: created.projectID)
      #expect(
        try restarted.directHead(
          root: topology.root.url, administrative: topology.gitDirectory.url,
          objects: topology.objects.url) == privateHead)
      #expect(
        try FileManager.default.contentsOfDirectory(atPath: topology.objects.url.path).count > 0)
    }
  }

  @Test func namesBranchesAndCollisionsRefuseWithoutActivation() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let service = try f.service()
      for name in [
        "", "../escape", "Upper", "two--hyphens", "valid\n", String(repeating: "a", count: 49),
      ] {
        #expect(throws: WorktreeError.self) { try service.create(name: name) }
      }
      for branch in ["HEAD", "-bad", "x\ncreate refs/heads/injected HEAD", "a..b", "bad.lock"] {
        #expect(throws: WorktreeError.self) { try service.create(name: "valid", branch: branch) }
      }
      #expect(throws: WorktreeError.self) { try service.create(name: "existing", branch: "main") }
      #expect(throws: WorktreeError.self) { try service.create(name: "missing", base: "absent") }
      #expect(try f.store.records().isEmpty)
      let first = try service.create(name: "one", branch: "feature/explicit", base: "main")
      #expect(first.branch == "feature/explicit")
      #expect(throws: WorktreeError.self) {
        try service.create(name: "two", branch: "feature/explicit")
      }
      #expect(try f.store.records().count == 1)
    }
  }

  @Test func detachedMainRequiresExplicitBase() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      try f.raw(["checkout", "--detach"])
      let service = try f.service()
      #expect(throws: WorktreeError.self) { try service.create(name: "default") }
      #expect(try service.create(name: "explicit", base: "main").base == "main")
    }
  }

  @Test func unbornBareAndSubdirectoryRefuse() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory, commit: false)
      #expect(throws: WorktreeError.self) { try f.service().create(name: "unborn") }
      try FileManager.default.createDirectory(
        at: f.repository.appendingPathComponent("nested"), withIntermediateDirectories: false)
      func source(_ root: URL) throws -> WorktreeRepository {
        try WorktreeRepository(
          source: .init(id: "other", root: root.path, registeredAt: f.source.registeredAt),
          store: f.store, storage: f.storage, executor: f.executor, registeredProjectRoots: [root],
          timeoutMilliseconds: 10_000, maxOutputBytes: 1_048_576, lockTimeout: .seconds(1))
      }
      #expect(throws: WorktreeError.self) {
        try source(f.repository.appendingPathComponent("nested"))
      }
      let bare = directory.appendingPathComponent("bare")
      try f.raw(["init", "--bare", bare.path])
      #expect(throws: WorktreeError.self) { try source(bare) }
    }
  }

  @Test func storageLayoutsAndOverlappingProjects() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      #expect(WorktreeStorage(databaseURL: nil) == nil)
      let app = try #require(
        WorktreeStorage(databaseURL: f.database, applicationSupportRoot: directory))
      #expect(app.content.path == directory.appendingPathComponent("Worktrees").path)
      #expect(
        f.storage.content.path
          == f.database.deletingLastPathComponent().appendingPathComponent("worktrees").path)
      for root in [
        directory, f.storage.content, f.storage.objects.appendingPathComponent("nested"),
      ] {
        #expect(throws: WorktreeError.self) { try f.service(roots: [f.repository, root]) }
      }
      try FileManager.default.createSymbolicLink(
        at: f.storage.content, withDestinationURL: f.repository)
      #expect(throws: (any Error).self) { try f.service().create(name: "alias") }
      #expect(
        !FileManager.default.fileExists(
          atPath: f.repository.appendingPathComponent("owner.json").path))
    }
  }

  @Test func unsupportedConfigurationDoesNotRunProgramsOrFetch() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      try f.raw(["config", "include.path", "/unreadable/fixture"])
      #expect(throws: WorktreeError.self) { try f.service() }
      try f.raw(["config", "--unset", "include.path"])
      try f.raw(["config", "remote.origin.promisor", "true"])
      #expect(throws: WorktreeError.self) { try f.service() }
      #expect(try f.store.records().isEmpty)
    }
  }
}
