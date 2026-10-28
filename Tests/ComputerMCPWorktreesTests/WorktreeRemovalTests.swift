import ComputerMCPPersistence
import Foundation
import Testing

@testable import ComputerMCPWorktrees

struct WorktreeRemovalTests {
  @Test func unconfinedTerminationWarningsSurviveRemovalAndRetry() async throws {
    try await removalFixture { f in
      let service = try f.service()
      let created = try service.create(name: "unconfined")
      let admission = try service.admission(projectID: created.projectID)
      let use = try admission.reserve(ownerID: UUID(), executionID: UUID(), unconfined: true)
      let result = try await service.remove(
        projectID: created.projectID,
        terminate: { gate, operation in
          try gate.acknowledgeUnconfined(
            use, operationID: operation,
            unconfirmedTermination: "PID 42 exit unconfirmed")
        }, authorize: { _, _ in })
      #expect(!FileManager.default.fileExists(atPath: created.path.path))
      #expect(result.terminationWarnings.contains { $0.contains("PID 42") })
      let retry = try await f.service().remove(
        projectID: created.projectID,
        terminate: { _, _ in Issue.record("Finished removal terminated writers again") },
        authorize: { _, _ in })
      #expect(retry.terminationWarnings == result.terminationWarnings)
    }
  }

  @Test func interruptedDirtyRefusalReopensBeforeFreshCapture() async throws {
    try await removalFixture { f in
      let service = try f.service()
      let created = try service.create(name: "dirty-recovery")
      try Data("uncommitted".utf8).write(to: created.path.appendingPathComponent("file.txt"))
      let path = f.storage.journals.appendingPathComponent(
        "removals/" + created.projectID + ".json")
      let io = WorktreeJournalIO(beforeDirectorySync: {
        if let data = try? Data(contentsOf: path),
          let value = try? JSONDecoder().decode(WorktreeRemovalJournal.self, from: data),
          value.phase == .abandoned
        {
          throw CancellationError()
        }
      })
      await #expect(throws: CancellationError.self) {
        try await f.service(journalIO: io).remove(
          projectID: created.projectID, terminate: { _, _ in }, authorize: { _, _ in })
      }
      let gate = try service.admission(projectID: created.projectID)
      #expect(throws: WorktreeError.self) { try gate.reserve(ownerID: UUID(), executionID: UUID()) }
      _ = try await service.remove(
        projectID: created.projectID, force: true, terminate: { _, _ in }, authorize: { _, _ in })
      #expect(try f.store.records().isEmpty)
    }
  }

  @Test(arguments: ["mark", "remove"], [false, true])
  func databaseFailureRetainsResumableRemoval(operation: String, after: Bool) async throws {
    try await removalFixture { f in
      let service = try f.service()
      let created = try service.create(name: "database")
      let failing = LifecycleFailureStore(base: f.store, operation: operation, after: after)
      await #expect(throws: CancellationError.self) {
        try await f.service(store: failing).remove(
          projectID: created.projectID, terminate: { _, _ in }, authorize: { _, _ in })
      }
      #expect(try f.store.protectedBranches().count == 1)
      if operation == "mark" { #expect(FileManager.default.fileExists(atPath: created.path.path)) }
      _ = try await f.service().remove(
        projectID: created.projectID, terminate: { _, _ in }, authorize: { _, _ in })
      #expect(try f.store.records().isEmpty)
      #expect(try f.store.protectedBranches().count == 1)
    }
  }

  @Test(arguments: ["publication", "prepared", "ready", "interfered"])
  func removalReconcilesDependenciesBeforeDestruction(dependency: String) async throws {
    try await removalFixture { f in
      let service = try f.service()
      let created = try service.create(name: "dependency")
      let tip = try f.privateCommit(service, projectID: created.projectID)
      let kind = dependency == "publication" ? "publications" : "merges"
      let phase =
        dependency == "publication" ? "published" : dependency == "prepared" ? "prepared" : "ready"
      let path = f.storage.journals.appendingPathComponent(kind + "/" + created.projectID + ".json")
      let failing = try f.service(
        journalIO: .init(beforeDirectorySync: {
          if let data = try? Data(contentsOf: path),
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            value["phase"] as? String == phase
          {
            throw CancellationError()
          }
        }))
      #expect(throws: CancellationError.self) {
        if dependency == "publication" {
          _ = try failing.publish(projectID: created.projectID) { _ in }
        } else {
          _ = try failing.merge(projectID: created.projectID) { _, _ in }
        }
      }
      if dependency == "interfered" {
        try Data("owner edit".utf8).write(to: f.repository.appendingPathComponent("file.txt"))
        await #expect(throws: WorktreeError.self) {
          try await service.remove(
            projectID: created.projectID, force: true, terminate: { _, _ in },
            authorize: { _, _ in })
        }
        #expect(FileManager.default.fileExists(atPath: created.path.path))
        #expect(try f.store.records().count == 1)
        #expect(
          try String(contentsOf: f.repository.appendingPathComponent("file.txt"), encoding: .utf8)
            == "owner edit")
      } else {
        let result = try await service.remove(
          projectID: created.projectID, terminate: { _, _ in }, authorize: { _, _ in })
        #expect(result.oid == tip)
        #expect(try f.store.records().isEmpty)
        if dependency == "ready" { #expect(try f.raw(["rev-parse", "HEAD"]) == tip) }
      }
    }
  }

  @Test func removalSerializesMergeAndBranchDeletionWhileAwaitingWriters() async throws {
    try await removalFixture { f in
      let service = try f.service()
      let created = try service.create(name: "serialize")
      let competitor = try f.service()
      _ = try await service.remove(
        projectID: created.projectID,
        terminate: { _, _ in
          #expect(throws: WorktreeError.self) {
            try competitor.merge(projectID: created.projectID) { _, _ in }
          }
          #expect(throws: WorktreeError.self) {
            try competitor.deleteBranch(
              created.branch, authority: .fullAccess, force: true, dryRun: false, confirm: true
            ) { _ in }
          }
          await #expect(throws: WorktreeError.self) {
            try await competitor.remove(
              projectID: created.projectID,
              terminate: { _, _ in Issue.record("Concurrent removal entered") },
              authorize: { _, _ in })
          }
        }, authorize: { _, _ in })
    }
  }

  @Test(arguments: ["tracked", "staged", "untracked", "ignored"])
  func dirtyRemovalReopensAdmissionAndForcePreservesCommits(kind: String) async throws {
    try await removalFixture { f in
      let service = try f.service()
      let created = try service.create(name: "dirty")
      let tip = try f.privateCommit(service, projectID: created.projectID)
      let topology = try service.topology(projectID: created.projectID)
      let git = PrivateWorktreeGit(f: f, topology: topology)
      let name = ["tracked", "staged"].contains(kind) ? "file.txt" : "extra"
      try Data("uncommitted\n".utf8).write(to: created.path.appendingPathComponent(name))
      if kind == "staged" { try git.run(["add", name]) }
      if kind == "ignored" {
        try f.raw([
          "config", "core.excludesFile", f.directory.appendingPathComponent("ignore").path,
        ])
        try Data("extra\n".utf8).write(to: f.directory.appendingPathComponent("ignore"))
      }
      await #expect(throws: WorktreeError.self) {
        try await service.remove(
          projectID: created.projectID, terminate: { _, _ in }, authorize: { _, _ in })
      }
      let gate = try service.admission(projectID: created.projectID)
      let use = try gate.reserve(ownerID: UUID(), executionID: UUID())
      try gate.acknowledge(use)
      let result = try await service.remove(
        projectID: created.projectID, force: true,
        terminate: { _, _ in }, authorize: { _, _ in })
      #expect(result.oid == tip)
      #expect(try f.store.records().isEmpty)
      #expect(try f.store.protectedBranches().count == 1)
      #expect(!FileManager.default.fileExists(atPath: created.path.path))
      #expect(try f.raw(["show", "worktree/dirty:file.txt"]) == "private")
      let restarted = try f.service()
      try restarted.recover()
      _ = try await restarted.remove(
        projectID: created.projectID, force: true,
        terminate: { _, _ in Issue.record("Completed removal must not terminate again.") },
        authorize: { _, _ in })
      #expect(try restarted.readJournal(created.projectID)?.phase == .removed)
    }
  }

  @Test func terminationFailureAndForeignOwnerNeverDestroy() async throws {
    try await removalFixture { f in
      let service = try f.service()
      let created = try service.create(name: "writer")
      let gate = try service.admission(projectID: created.projectID)
      let use = try gate.reserve(ownerID: UUID(), executionID: UUID())
      let terminate: (WorktreeAdmission, UUID) async throws -> Void = { admission, operation in
        let uses = try admission.close(operationID: operation)
        #expect(uses == [use])
        #expect(throws: WorktreeError.self) {
          try admission.reserve(ownerID: UUID(), executionID: UUID())
        }
      }
      await #expect(throws: WorktreeError.self) {
        try await service.remove(
          projectID: created.projectID, force: true,
          terminate: terminate, authorize: { _, _ in })
      }
      #expect(
        FileManager.default.fileExists(atPath: created.path.appendingPathComponent("file.txt").path)
      )
      #expect(try service.readPublication(created.projectID) == nil)
      _ = try await service.remove(
        projectID: created.projectID, force: true,
        terminate: { admission, _ in
          try admission.acknowledge(use)
        }, authorize: { _, _ in })
    }
  }

  @Test(arguments: [false, true])
  func retentionFollowsReflogRootsRatherThanDanglingObjects(unproven: Bool) async throws {
    try await removalFixture { f in
      let service = try f.service()
      let created = try service.create(name: "rewrite")
      let displaced = try f.privateCommit(service, projectID: created.projectID)
      let topology = try service.topology(projectID: created.projectID)
      let git = PrivateWorktreeGit(f: f, topology: topology)
      try git.run(["commit", "--amend", "-m", "replacement"])
      let tip = try git.run(["rev-parse", "HEAD"])
      if unproven {
        try FileManager.default.removeItem(
          at: topology.gitDirectory.url.appendingPathComponent("logs/HEAD"))
        _ = try await service.remove(
          projectID: created.projectID, force: true,
          terminate: { _, _ in }, authorize: { _, _ in })
        #expect(try f.store.records().isEmpty)
      } else {
        _ = try await service.remove(
          projectID: created.projectID,
          terminate: { _, _ in }, authorize: { _, _ in })
        #expect(try f.raw(["rev-parse", "worktree/rewrite"]) == tip)
        #expect(try f.raw(["cat-file", "-t", displaced]) == "commit")
        #expect(
          try f.raw(["for-each-ref", "--format=%(objectname)", "refs/computer-mcp/recovery/"])
            .contains(displaced))
      }
    }
  }

  @Test(arguments: [
    "preserved", "content", "repository", "runtime", "unregistering", "finished",
  ])
  func interruptedCleanupResumesOnlyOwnedSteps(phase: String) async throws {
    try await removalFixture { f in
      let service = try f.service()
      let created = try service.create(name: "recover-remove")
      let tip = try f.privateCommit(service, projectID: created.projectID)
      let journalPath = f.storage.journals.appendingPathComponent(
        "removals/" + created.projectID + ".json")
      let io = WorktreeJournalIO(beforeDirectorySync: {
        guard let data = try? Data(contentsOf: journalPath),
          let journal = try? JSONDecoder().decode(WorktreeRemovalJournal.self, from: data),
          journal.phase.rawValue == phase
        else { return }
        throw WorktreeError.recoveryRequired("Injected interruption.")
      })
      await #expect(throws: WorktreeError.self) {
        try await f.service(journalIO: io).remove(
          projectID: created.projectID,
          terminate: { _, _ in }, authorize: { _, _ in })
      }
      let reopened = SQLiteDerivedProjectStore(
        connection: try GatewayDatabaseConnection(path: f.database.path))
      let result = try await f.service(store: reopened).remove(
        projectID: created.projectID,
        terminate: { _, _ in }, authorize: { _, _ in })
      #expect(result.oid == tip)
      #expect(try reopened.records().isEmpty)
      #expect(try f.raw(["rev-parse", "worktree/recover-remove"]) == tip)
    }
  }

  @Test func foreignReplacementSurvivesInterruptedRemoval() async throws {
    try await removalFixture { f in
      let service = try f.service()
      let created = try service.create(name: "replacement")
      let journalPath = f.storage.journals.appendingPathComponent(
        "removals/" + created.projectID + ".json")
      let io = WorktreeJournalIO(beforeDirectorySync: {
        guard let data = try? Data(contentsOf: journalPath),
          let journal = try? JSONDecoder().decode(WorktreeRemovalJournal.self, from: data),
          journal.phase == .content
        else { return }
        throw WorktreeError.recoveryRequired("Injected interruption.")
      })
      await #expect(throws: WorktreeError.self) {
        try await f.service(journalIO: io).remove(
          projectID: created.projectID,
          terminate: { _, _ in }, authorize: { _, _ in })
      }
      try FileManager.default.moveItem(
        at: created.path, to: f.directory.appendingPathComponent("saved"))
      try FileManager.default.createDirectory(at: created.path, withIntermediateDirectories: false)
      try Data("foreign".utf8).write(to: created.path.appendingPathComponent("sentinel"))
      await #expect(throws: WorktreeError.self) {
        try await f.service().remove(
          projectID: created.projectID,
          terminate: { _, _ in }, authorize: { _, _ in })
      }
      #expect(
        try String(contentsOf: created.path.appendingPathComponent("sentinel"), encoding: .utf8)
          == "foreign")
    }
  }
}

func removalFixture(_ action: (WorktreeFixture) async throws -> Void) async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    .resolvingSymlinksInPath()
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: directory) }
  try await action(WorktreeFixture(directory))
}
