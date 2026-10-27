import ComputerMCPPersistence
import Foundation
import Testing

@testable import ComputerMCPWorktrees

struct WorktreeCreationRecoveryTests {
  @Test func collidingDirectoryIsNeverAdoptedOrRemoved() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let storage = f.storage
      let io = WorktreeJournalIO(beforePublication: {
        for name in try FileManager.default.contentsOfDirectory(atPath: storage.journals.path)
        where name.hasSuffix(".tmp") {
          let data = try Data(contentsOf: storage.journals.appendingPathComponent(name))
          guard let journal = try? JSONDecoder().decode(WorktreeCreationJournal.self, from: data),
            journal.phase == .reserved
          else { continue }
          let root = URL(fileURLWithPath: journal.record.root)
          try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
          try Data("external owner".utf8).write(to: root.appendingPathComponent("sentinel"))
        }
      })
      let service = try WorktreeRepository(
        source: f.source, store: f.store, storage: storage,
        executor: f.executor, registeredProjectRoots: [f.repository], timeoutMilliseconds: 10_000,
        maxOutputBytes: 1_048_576, lockTimeout: .seconds(1), journalIO: io)
      #expect(throws: (any Error).self) { try service.create(name: "collision") }
      let record = try #require(f.store.records().first)
      #expect(record.state == .creating)
      #expect(throws: WorktreeError.self) { try f.service().recover() }
      #expect(
        try String(contentsOfFile: record.root + "/sentinel", encoding: .utf8) == "external owner")
      #expect(
        try f.raw(["for-each-ref", "--format=%(refname)", "refs/heads/worktree/collision"]).isEmpty)
    }
  }

  @Test func databaseFailureAfterGitCreationReconcilesOnRestart() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let failing = try f.service(store: WorktreeActivationFailure(f.store))
      #expect(throws: DerivedProjectStoreError.self) { try failing.create(name: "recover") }
      let before = try #require(f.store.records().first)
      #expect(before.state == .creating)
      #expect(try f.raw(["rev-parse", "worktree/recover"]) == f.raw(["rev-parse", "main"]))
      let connection = try GatewayDatabaseConnection(path: f.database.path)
      let store = SQLiteDerivedProjectStore(connection: connection)
      let restarted = try f.service(store: store)
      try restarted.recover()
      try restarted.recover()
      let active = try #require(store.records().first)
      #expect(active.state == .active && active.revision == 2)
      _ = try restarted.topology(projectID: active.projectID)
    }
  }

  @Test func externalRefChangeRetainsCreationAndContent() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      #expect(throws: DerivedProjectStoreError.self) {
        try f.service(store: WorktreeActivationFailure(f.store)).create(name: "retain")
      }
      let record = try #require(f.store.records().first)
      try f.raw(["commit", "--allow-empty", "-m", "advance"])
      try f.raw(["branch", "--force", "worktree/retain", "HEAD"])
      #expect(throws: WorktreeError.self) { try f.service().recover() }
      #expect(try f.store.records().first?.state == .creating)
      #expect(FileManager.default.fileExists(atPath: record.root + "/file.txt"))
    }
  }

  @Test func corruptedJournalCannotInjectRefsOrAdoptDirectories() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let service = try f.service()
      let created = try service.create(name: "corrupt")
      let url = f.storage.journals.appendingPathComponent(created.projectID + ".json")
      var journal = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
      journal["branch"] = "refs/heads/valid\ncreate refs/heads/injected HEAD"
      try JSONSerialization.data(withJSONObject: journal).write(to: url)
      #expect(throws: WorktreeError.self) { try service.topology(projectID: created.projectID) }
      #expect(throws: WorktreeError.self) { try service.recover() }
      #expect(try f.raw(["for-each-ref", "--format=%(refname)", "refs/heads/injected"]).isEmpty)
      #expect(
        FileManager.default.fileExists(atPath: created.path.appendingPathComponent("file.txt").path)
      )
    }
  }

  @Test func journalCannotRewriteActiveLedgerTopology() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let service = try f.service()
      let created = try service.create(name: "bound")
      let url = f.storage.journals.appendingPathComponent(created.projectID + ".json")
      var journal = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
      journal["branch"] = "refs/heads/different"
      try JSONSerialization.data(withJSONObject: journal).write(to: url)
      #expect(throws: WorktreeError.self) { try service.topology(projectID: created.projectID) }
      #expect(try f.store.records().first?.worktree?.branch == "refs/heads/worktree/bound")
    }
  }

  @Test func generationAndDirectoryReplacementInvalidateTopology() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let service = try f.service()
      let created = try service.create(name: "identity")
      let topology = try service.topology(projectID: created.projectID)
      let retained = created.path.appendingPathExtension("retained")
      try FileManager.default.moveItem(at: created.path, to: retained)
      try FileManager.default.createDirectory(at: created.path, withIntermediateDirectories: false)
      #expect(throws: WorktreeError.self) { try topology.verifyDirectories() }
      #expect(throws: WorktreeError.self) { try service.topology(projectID: created.projectID) }
      try FileManager.default.removeItem(at: created.path)
      try FileManager.default.moveItem(at: retained, to: created.path)
      try Data("different generation\n".utf8).write(
        to: created.path.deletingLastPathComponent().appendingPathComponent("owner.json"))
      #expect(throws: WorktreeError.self) { try service.topology(projectID: created.projectID) }
    }
  }
}
