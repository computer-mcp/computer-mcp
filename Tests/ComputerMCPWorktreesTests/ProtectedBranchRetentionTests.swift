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
      let io = WorktreeJournalIO(beforeDirectorySync: {
        for file
          in (try? FileManager.default.contentsOfDirectory(
            at: journals, includingPropertiesForKeys: nil)) ?? []
        {
          if let value = try? JSONSerialization.jsonObject(with: Data(contentsOf: file))
            as? [String: Any],
            value["phase"] as? String == interruption
          {
            throw CancellationError()
          }
        }
      })
      let failing = try f.service(
        store: LifecycleFailureStore(
          base: f.store, operation: interruption.hasPrefix("release-") ? "release" : "none",
          after: interruption == "release-after"),
        executor: RetentionTransactionFailure(base: f.executor, interruption: interruption),
        journalIO: io)
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
      let retained = try #require(record["retainedRoots"] as? [String: String])
      let released = try #require(record["releasedRoots"] as? [String: String])
      #expect(Set(roots).isSubset(of: Set(retained.values)))
      #expect(!retained.values.contains(mergedBlob))
      #expect(record["phase"] as? String == "finished")
      for ref in released.keys { #expect(try service.objectRevision(ref) == nil) }
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
      for (ref, oid) in retained { try f.service().requireObjectRef(ref, oid: oid) }
      for oid in roots { try f.raw(["cat-file", "-p", oid]) }
      try f.raw(["fsck", "--full", "--strict", "--no-dangling"])
    }
  }

  @Test func legacyDeletionJournalResumesItsExactReleaseSet() async throws {
    try await removalFixture { f in
      let service = try f.service()
      let created = try service.create(name: "legacy")
      _ = try await service.remove(
        projectID: created.projectID, terminate: { _, _ in }, authorize: { _, _ in })
      let failing = try f.service(
        executor: RetentionTransactionFailure(base: f.executor, interruption: "transaction-before"))
      #expect(throws: CancellationError.self) {
        try failing.deleteBranch(created.branch, authority: .sandbox, dryRun: false, confirm: true)
        { _ in }
      }
      let files = try FileManager.default.contentsOfDirectory(
        at: f.storage.journals.appendingPathComponent("branch-deletions"),
        includingPropertiesForKeys: nil)
      let file = try #require(files.first)
      var legacy = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
      legacy["roots"] = legacy.removeValue(forKey: "releasedRoots")
      legacy.removeValue(forKey: "retainedRoots")
      try JSONSerialization.data(withJSONObject: legacy, options: .sortedKeys).write(to: file)
      #expect(
        try service.deleteBranch(
          created.branch, authority: .sandbox, dryRun: false, confirm: true
        ) { _ in }.deleted)
      let finished = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
      #expect(finished["phase"] as? String == "finished")
      #expect(finished["roots"] == nil)
      #expect(finished["retainedRoots"] as? [String: String] == [:])
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
          executor: RetentionTransactionFailure(
            base: f.executor, interruption: "transaction-before"))
        #expect(throws: CancellationError.self) {
          try failing.deleteBranch(
            created.branch, authority: .fullAccess, force: force, dryRun: false, confirm: true
          ) { _ in }
        }
        let roots = try f.raw(["for-each-ref", "refs/computer-mcp/recovery/"])
        try f.raw([
          "update-ref", changed == "main" ? "refs/heads/main" : "refs/heads/" + created.branch,
          initial,
        ])
        #expect(throws: (any Error).self) {
          try service.deleteBranch(
            created.branch, authority: .fullAccess, force: force, dryRun: false, confirm: true
          ) { _ in }
        }
        #expect(try f.raw(["for-each-ref", "refs/computer-mcp/recovery/"]) == roots)
        #expect(try f.store.protectedBranches().count == 1)
      }
    }
  }
}

private struct RetentionTransactionFailure: WorktreeGitExecuting {
  let base: WorktreeTestGit
  let interruption: String
  func execute(_ command: WorktreeGitCommand) throws -> WorktreeGitResult {
    try base.execute(command)
  }
  func withPreparedTransaction(_ command: WorktreeGitCommand, _ body: () throws -> Void) throws {
    let deleting = String(decoding: command.input, as: UTF8.self).contains(
      "create refs/computer-mcp/deletions/")
    try base.withPreparedTransaction(command) {
      try body()
      if deleting, interruption == "transaction-before" { throw CancellationError() }
    }
    if deleting, interruption == "transaction-after" { throw CancellationError() }
  }
}
