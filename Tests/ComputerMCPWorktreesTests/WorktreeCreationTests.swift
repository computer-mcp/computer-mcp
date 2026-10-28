import ComputerMCPPersistence
import Foundation
import Testing

@testable import ComputerMCPWorktrees

struct WorktreeCreationTests {
  @Test func sharedStorageRecognizesEachRepositorysVerifiedContent() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let first = try f.service().create(name: "first")
      let other = directory.appendingPathComponent("other-repository")
      try f.raw(["init", "--initial-branch=main", "--object-format=sha256", other.path])
      try f.raw(
        [
          "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
          "commit", "--allow-empty", "-m", "initial",
        ], root: other)
      let otherSource = DerivedProjectSource(
        id: "other-source", root: other.path,
        registeredAt: f.source.registeredAt)
      func otherService(_ roots: [URL]) throws -> WorktreeRepository {
        try WorktreeRepository(
          source: otherSource, store: f.store, storage: f.storage,
          executor: f.executor, registeredProjectRoots: roots,
          timeoutMilliseconds: 10_000, maxOutputBytes: 1_048_576, lockTimeout: .seconds(1))
      }
      let initialRoots = [f.repository, other, first.path]
      let second = try otherService(initialRoots).create(name: "second")
      let allRoots = initialRoots + [second.path]
      let firstService = try f.service(roots: allRoots)
      let secondService = try otherService(allRoots)
      #expect(
        try firstService.topology(projectID: first.projectID).root.url.path == first.path.path)
      #expect(
        try secondService.topology(projectID: second.projectID).root.url.path == second.path.path)
      #expect(throws: WorktreeError.self) { try secondService.topology(projectID: first.projectID) }
      let listed = try secondService.inventory { _ in true }
      #expect(listed.compactMap(\.projectID) == [second.projectID])
      #expect(try f.store.records().count == 2)
      #expect(throws: WorktreeError.self) {
        try otherService(allRoots + [f.storage.content.appendingPathComponent("unowned")])
      }
      try Data("different owner".utf8).write(
        to: first.path.deletingLastPathComponent().appendingPathComponent("owner.json"))
      #expect(throws: WorktreeError.self) { try otherService(allRoots) }
      #expect(throws: WorktreeError.self) { try secondService.inventory { _ in true } }
    }
  }

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
        try restarted.privateMetadata(topology).head == privateHead)
      #expect(
        try FileManager.default.contentsOfDirectory(atPath: topology.objects.url.path).count > 0)
    }
  }

  @Test func submoduleAndLFSConditionsAreReportedWithoutSourceConfiguration() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let base = try f.raw(["rev-parse", "HEAD"])
      try Data("asset filter=lfs\n".utf8).write(
        to: f.repository.appendingPathComponent(".gitattributes"))
      let pointer =
        "version https://git-lfs.github.com/spec/v1\noid sha256:"
        + String(repeating: "a", count: 64) + "\nsize 1\n"
      try Data(pointer.utf8).write(to: f.repository.appendingPathComponent("asset"))
      try f.raw(["add", "."])
      try f.raw(["update-index", "--add", "--cacheinfo", "160000," + base + ",submodule"])
      try f.raw(["commit", "-m", "special content"])
      try f.raw(["config", "custom.owner", "not copied"])
      let service = try f.service()
      let created = try service.create(name: "content")
      #expect(created.warnings.count == 2)
      #expect(
        try String(contentsOf: created.path.appendingPathComponent("asset"), encoding: .utf8)
          == pointer)
      let topology = try service.topology(projectID: created.projectID)
      #expect(
        try !String(
          contentsOf: topology.gitDirectory.url.appendingPathComponent("config"), encoding: .utf8
        ).contains("custom"))
      #expect(
        try FileManager.default.contentsOfDirectory(
          atPath: created.path.appendingPathComponent("submodule").path
        ).isEmpty)
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
        directory, f.storage.content, f.storage.repositories.appendingPathComponent("nested"),
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
