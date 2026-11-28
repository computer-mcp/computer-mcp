import Foundation
import Testing

@testable import ComputerMCPWorktrees

struct ProtectedBranchRetentionTests {
  @Test(arguments: [
    "prepared", "transaction-before", "transaction-after", "committed",
    "release-before", "release-after", "released", "finished",
  ])
  func retainedObjectsOutliveDeletionRecoveryAndBranchReuse(interruption: String) async throws {
    try await removalFixture { f in
      let service = try f.service()
      let created = try service.create(name: "retention")
      let old = try f.privateCommit(service, projectID: created.projectID)
      let git = PrivateWorktreeGit(
        f: f, topology: try service.topology(projectID: created.projectID))
      try git.run(["commit", "--amend", "-m", "replacement"])
      let tip = try git.run(["rev-parse", "HEAD"])
      try git.run(["tag", "-a", "merged-tag", "-m", "independent tag", tip])
      let tag = try git.run(["rev-parse", "refs/tags/merged-tag"])
      let blob = try git.run(["hash-object", "-w", "--stdin"], input: Data("retained blob".utf8))
      try git.run(["update-ref", "refs/retained/blob", blob])
      let tree = try git.run(["mktree"], input: Data("100644 blob \(blob)\tretained.txt\n".utf8))
      try git.run(["update-ref", "refs/retained/tree", tree])
      // This root is in the base closure and must be released, unlike the tag above it.
      let mergedBlob = try git.run(["rev-parse", "HEAD:file.txt"])
      try git.run(["update-ref", "refs/retained/merged-blob", mergedBlob])
      _ = try service.merge(projectID: created.projectID) { _, _ in }
      _ = try await service.remove(
        projectID: created.projectID, terminate: { _, _ in }, authorize: { _, _ in })
      let roots = [old, tag, blob, tree]
      let journals = f.storage.journals.appendingPathComponent("branch-deletions")
      let failing = try f.service(
        store: LifecycleFailureStore(
          base: f.store, operation: interruption.hasPrefix("release-") ? "release" : "none",
          after: interruption == "release-after"),
        journalIO: deletionInterruption(interruption, fixture: f))
      var authorizations = 0
      let authorize: (ProtectedWorktreeBranch?) throws -> Void = { _ in
        authorizations += 1
        if interruption == "transaction-after", authorizations == 2 {
          #expect(throws: WorktreeError.self) {
            try service.deleteBranch(
              created.branch, authority: .fullAccess, force: true, dryRun: false, confirm: true
            ) { _ in }
          }
        }
      }
      #expect(throws: CancellationError.self) {
        try failing.deleteBranch(
          created.branch, authority: .sandbox, dryRun: false, confirm: true, authorize: authorize)
      }
      if interruption != "finished" {
        #expect(throws: CancellationError.self) {
          try service.deleteBranch(
            created.branch, authority: .sandbox, dryRun: false, confirm: true
          ) { _ in
            throw CancellationError()
          }
        }
        #expect(
          try f.service().deleteBranch(
            created.branch, authority: .sandbox, dryRun: false, confirm: true
          ) { _ in }.deleted)
      } else {
        #expect(throws: WorktreeError.self) {
          try service.deleteBranch(
            created.branch, authority: .sandbox, dryRun: false, confirm: true
          ) { _ in }
        }
      }
      #expect(try f.store.protectedBranches().isEmpty)
      let files = try FileManager.default.contentsOfDirectory(
        at: journals, includingPropertiesForKeys: nil)

      #expect(files.count == 1)
      let file = try #require(files.first)
      let record = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
      let selection = try JSONDecoder().decode(
        WorktreeRecoveryBranchSelection.self,
        from: JSONSerialization.data(withJSONObject: try #require(record["selection"])))
      let retained = selection.retained
      let released = selection.released
      #expect(Set(roots).isSubset(of: Set(retained.map(\.oid))))
      #expect(!retained.contains { $0.oid == mergedBlob })
      #expect(record["phase"] as? String == "finished")
      let activeIDs = Set(try f.recoveryRecords().map(\.id))
      #expect(released.allSatisfy { !activeIDs.contains($0.selection.recordID) })
      let receipt = try Data(contentsOf: file)
      // A new registration with the same branch name has a fresh UUID namespace.
      let reused = try service.create(name: "reused", branch: created.branch)
      _ = try await service.remove(
        projectID: reused.projectID, terminate: { _, _ in }, authorize: { _, _ in })
      #expect(
        try service.deleteBranch(
          reused.branch, authority: .fullAccess, force: true, dryRun: false, confirm: true
        ) { _ in }.deleted)
      #expect(try Data(contentsOf: file) == receipt)
      try f.raw(["reflog", "expire", "--expire=now", "--all"])
      try f.raw(["gc", "--prune=now"])
      let recovery = try f.recoveryGitDirectory()
      try FileManager.default.removeItem(at: f.repository)
      #expect(try Set(roots).isSubset(of: f.recoveryRecords().map(\.oid)))
      for record in retained {
        #expect(
          try f.raw(
            [
              "--git-dir=" + recovery.path, "rev-parse",
              "refs/recovery/" + record.recordID.uuidString.lowercased(),
            ], root: f.directory) == record.oid)
      }
      for oid in roots {
        try f.raw(["--git-dir=" + recovery.path, "cat-file", "-p", oid], root: f.directory)
      }
      try f.raw(
        ["--git-dir=" + recovery.path, "fsck", "--full", "--strict", "--no-dangling"],
        root: f.directory)
    }
  }

  @Test func deletionWithoutStoreOwnershipRefusesAndRetainsItsExactSelection() async throws {
    try await removalFixture { f in
      let service = try f.service()
      let created = try service.create(name: "legacy")
      _ = try await service.remove(
        projectID: created.projectID, terminate: { _, _ in }, authorize: { _, _ in })
      let failing = try f.service(journalIO: deletionInterruption("transaction-before", fixture: f))
      #expect(throws: CancellationError.self) {
        try failing.deleteBranch(created.branch, authority: .sandbox, dryRun: false, confirm: true)
        { _ in }
      }
      let files = try FileManager.default.contentsOfDirectory(
        at: f.storage.journals.appendingPathComponent("branch-deletions"),
        includingPropertiesForKeys: nil)
      let file = try #require(files.first)
      let owned = try Data(contentsOf: file)
      var legacy = try #require(JSONSerialization.jsonObject(with: owned) as? [String: Any])
      for key in ["version", "selection", "guards", "sourceDeletion"] {
        legacy.removeValue(forKey: key)
      }
      legacy["roots"] = [:] as [String: String]
      let before = try f.recoveryRecords()
      try JSONSerialization.data(withJSONObject: legacy, options: .sortedKeys).write(to: file)
      #expect(throws: WorktreeError.self) {
        try service.deleteBranch(created.branch, authority: .sandbox, dryRun: false, confirm: true)
        { _ in }
      }
      #expect(try f.recoveryRecords() == before)
      try owned.write(to: file)
      #expect(
        try service.deleteBranch(
          created.branch, authority: .sandbox, dryRun: false, confirm: true
        ) { _ in }.deleted)
    }
  }

  @Test(arguments: [false, true])
  func pendingDeletionRefusesChangedBaseAndBranch(force: Bool) async throws {
    for changed in ["main", "branch"] {
      try await removalFixture { f in
        let service = try f.service()
        let created = try service.create(name: "expected")
        let initial = try f.raw(["rev-parse", "main"])
        _ = try f.privateCommit(service, projectID: created.projectID)
        _ = try service.merge(projectID: created.projectID) { _, _ in }
        _ = try await service.remove(
          projectID: created.projectID, terminate: { _, _ in }, authorize: { _, _ in })
        let failing = try f.service(
          journalIO: deletionInterruption("transaction-before", fixture: f))
        #expect(throws: CancellationError.self) {
          try failing.deleteBranch(
            created.branch, authority: .fullAccess, force: force, dryRun: false, confirm: true
          ) { _ in }
        }
        let roots = try f.recoveryRecords()
        let ref = "refs/heads/" + (changed == "main" ? "main" : created.branch)
        #expect(throws: WorktreeError.self) {
          try f.raw(["-c", "core.filesRefLockTimeout=0", "update-ref", ref, initial])
        }
        try Data((initial + "\n").utf8).write(
          to: f.repository.appendingPathComponent(".git/" + ref), options: .atomic)
        #expect(throws: (any Error).self) {
          try service.deleteBranch(
            created.branch, authority: .fullAccess, force: force, dryRun: false, confirm: true
          ) { _ in }
        }
        #expect(try f.recoveryRecords() == roots)
        #expect(try f.store.protectedBranches().count == 1)
      }
    }
  }
}
