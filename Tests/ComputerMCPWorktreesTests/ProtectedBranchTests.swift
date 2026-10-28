import Foundation
import Testing

@testable import ComputerMCPWorktrees

struct ProtectedBranchTests {
  @Test(arguments: [
    "prepared", "committed", "released", "release-before", "release-after", "transaction",
  ])
  func deletionRecoveryRetainsAuthorityAndExactReceipt(interruption: String) async throws {
    try await removalFixture { f in
      let service = try f.service()
      let created = try service.create(name: "delete-recovery")
      _ = try f.privateCommit(service, projectID: created.projectID)
      _ = try await service.remove(
        projectID: created.projectID, terminate: { _, _ in }, authorize: { _, _ in })
      let journals = f.storage.journals.appendingPathComponent("branch-deletions")
      let io = WorktreeJournalIO(beforeDirectorySync: {
        for file
          in (try? FileManager.default.contentsOfDirectory(
            at: journals, includingPropertiesForKeys: nil)) ?? []
        {
          if let data = try? Data(contentsOf: file),
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
        executor: DeletionReceiptFailure(base: f.executor, enabled: interruption == "transaction"),
        journalIO: io)
      #expect(throws: CancellationError.self) {
        try failing.deleteBranch(
          created.branch, authority: .fullAccess, force: true, dryRun: false, confirm: true
        ) { _ in }
      }
      #expect(throws: WorktreeError.self) {
        try service.create(name: "new", branch: created.branch)
      }
      #expect(throws: WorktreeError.self) {
        try service.deleteBranch(created.branch, authority: .sandbox, dryRun: false, confirm: true)
        { _ in }
      }
      #expect(throws: CancellationError.self) {
        try service.deleteBranch(
          created.branch, authority: .fullAccess, force: true, dryRun: false, confirm: true
        ) { _ in throw CancellationError() }
      }
      #expect(
        try service.deleteBranch(
          created.branch, authority: .fullAccess, force: true, dryRun: false, confirm: true
        ) { _ in }.deleted)
      #expect(try f.store.protectedBranches().isEmpty)
      #expect(
        try f.raw(["for-each-ref", "--format=%(refname)", "refs/computer-mcp/deletions/"]).isEmpty)
    }
  }

  @Test(arguments: [false, true], [false, true])
  func publishedReplacementAndPrivateReflogHaveIndependentRetention(
    acknowledge: Bool, retainsReflog: Bool
  )
    async throws
  {
    try await removalFixture { f in
      let service = try f.service()
      let created = try service.create(name: "rewrite-delete")
      let old = try f.privateCommit(service, projectID: created.projectID)
      _ = try service.publish(projectID: created.projectID) { _ in }
      let git = PrivateWorktreeGit(
        f: f, topology: try service.topology(projectID: created.projectID))
      try git.run(["commit", "--amend", "-m", "replacement"])
      let tip = try git.run(["rev-parse", "HEAD"])
      _ = try service.merge(projectID: created.projectID) { _, _ in }
      if acknowledge {
        try service.acknowledgeReplacement(
          projectID: created.projectID, replacedOID: old, expectedPublishedOID: tip
        ) { _ in }
      }
      if !retainsReflog { try git.run(["reflog", "expire", "--expire=now", "--all"]) }
      _ = try await service.remove(
        projectID: created.projectID, terminate: { _, _ in }, authorize: { _, _ in })
      if acknowledge && !retainsReflog {
        #expect(
          try service.deleteBranch(
            created.branch, authority: .sandbox, dryRun: false, confirm: true
          ) { _ in }.deleted)
      } else {
        #expect(throws: WorktreeError.self) {
          try service.deleteBranch(
            created.branch, authority: .sandbox, dryRun: false, confirm: true
          ) { _ in }
        }
        #expect(try f.store.protectedBranches().count == 1)
      }
    }
  }

  @Test func liveDetachedAndForeignCheckoutsPreventDeletion() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let service = try f.service()
      let created = try service.create(name: "live")
      #expect(throws: WorktreeError.self) {
        try service.deleteBranch(
          created.branch, authority: .fullAccess, force: true, dryRun: false, confirm: true
        ) { _ in }
      }
      try f.raw(["branch", "foreign"])
      try f.raw(["worktree", "add", directory.appendingPathComponent("foreign").path, "foreign"])
      #expect(throws: WorktreeError.self) {
        try service.deleteBranch(
          "foreign", authority: .fullAccess, force: true, dryRun: false, confirm: true
        ) { _ in }
      }
      #expect(try f.raw(["rev-parse", "worktree/live"]) == f.raw(["rev-parse", "foreign"]))
    }
  }

  @Test func retainedUnmergedBranchIgnoresUpstreamAndSandboxForce() async throws {
    try await removalFixture { f in
      let service = try f.service()
      let created = try service.create(name: "protected")
      let tip = try f.privateCommit(service, projectID: created.projectID)
      _ = try await service.remove(
        projectID: created.projectID, terminate: { _, _ in }, authorize: { _, _ in })
      try f.raw(["branch", "upstream", tip])
      try f.raw(["branch", "--set-upstream-to=upstream", created.branch])
      for force in [false, true] {
        #expect(throws: WorktreeError.self) {
          try f.service().deleteBranch(
            created.branch, authority: .sandbox, force: force, dryRun: false, confirm: true
          ) { _ in }
        }
      }
      #expect(try f.store.protectedBranches().count == 1)
      #expect(try f.raw(["rev-parse", created.branch]) == tip)
      let result = try f.service().deleteBranch(
        created.branch, authority: .fullAccess, force: true, dryRun: false, confirm: true
      ) { _ in }
      #expect(result.deleted)
      #expect(try f.store.protectedBranches().isEmpty)
      #expect(
        try f.raw(["for-each-ref", "--format=%(refname)", "refs/heads/" + created.branch]).isEmpty)
      _ = try f.service().create(name: "reused", branch: created.branch)
    }
  }

  @Test(arguments: [
    "unchanged", "reset", "base-reused", "missing-base", "branch-reused", "new-tip", "base-race",
  ])
  func deletionChecksBaseAndBranchRegistration(change: String) async throws {
    try await removalFixture { f in
      let service = try f.service()
      let base = try f.raw(["rev-parse", "main"])
      let created = try service.create(name: "merged")
      let tip = try f.privateCommit(service, projectID: created.projectID)
      _ = try service.merge(projectID: created.projectID) { _, _ in }
      _ = try await service.remove(
        projectID: created.projectID, terminate: { _, _ in }, authorize: { _, _ in })
      switch change {
      case "reset":
        try f.raw(["update-ref", "refs/heads/main", base, tip])
        try f.raw(["update-ref", "refs/heads/main", tip, base])
      case "base-reused", "missing-base":
        try f.raw(["update-ref", "-d", "refs/heads/main", tip])
        if change == "base-reused" { try f.raw(["update-ref", "refs/heads/main", tip]) }
      case "branch-reused":
        try f.raw(["update-ref", "-d", "refs/heads/" + created.branch, tip])
        try f.raw(["update-ref", "refs/heads/" + created.branch, tip])
      case "new-tip": try f.raw(["update-ref", "refs/heads/" + created.branch, base, tip])
      default: break
      }
      if change == "unchanged" {
        #expect(try !service.deleteBranch(created.branch, authority: .sandbox) { _ in }.deleted)
        #expect(
          try service.deleteBranch(
            created.branch, authority: .sandbox, dryRun: false, confirm: true
          ) { _ in }.deleted)
        #expect(try f.store.protectedBranches().isEmpty)
      } else {
        var calls = 0
        let authorize: (ProtectedWorktreeBranch?) throws -> Void = { _ in
          calls += 1
          if change == "base-race", calls == 2 {
            #expect(throws: (any Error).self) {
              try f.raw(["update-ref", "refs/heads/main", base, tip])
            }
            throw WorktreeError.busy("Authority revoked while references were locked.")
          }
        }
        #expect(throws: WorktreeError.self) {
          try service.deleteBranch(
            created.branch, authority: .sandbox, dryRun: false, confirm: true, authorize: authorize)
        }
        #expect(try f.store.protectedBranches().count == 1)
        #expect(
          try !f.raw(["for-each-ref", "--format=%(refname)", "refs/heads/" + created.branch])
            .isEmpty)
      }
    }
  }
}

private struct DeletionReceiptFailure: WorktreeGitExecuting {
  let base: WorktreeTestGit
  let enabled: Bool
  func execute(_ command: WorktreeGitCommand) throws -> WorktreeGitResult {
    try base.execute(command)
  }
  func withPreparedTransaction(_ command: WorktreeGitCommand, _ body: () throws -> Void) throws {
    try base.withPreparedTransaction(command, body)
    if enabled,
      String(decoding: command.input, as: UTF8.self).contains("create refs/computer-mcp/deletions/")
    {
      throw CancellationError()
    }
  }
}
