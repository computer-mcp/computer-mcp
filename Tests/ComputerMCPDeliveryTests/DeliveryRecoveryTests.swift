import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatformPOSIX
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPDelivery

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.nativeIntegration)
struct DeliveryRecoveryTests {
  enum Interruption: String, CaseIterable, Sendable {
    case beforeWorktree, beforeCommit, afterCommitBeforeJournal, afterCommit, beforeMerge,
      afterMerge, duringRebase
  }

  @Test(arguments: [false, true])
  func recoveryReadsProjectIdentityFromVersionOneJournals(finished: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let journal = try interrupted(fixture, at: .beforeWorktree)
      let repository = try fixture.repository()
      if finished { try repository.withLock { try repository.recover() } }
      let url = fixture.root.appendingPathComponent(
        ".git/computer-mcp/delivery/\(journal.operationID).json")
      var object = try #require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
      object["workspace"] = object.removeValue(forKey: "project")
      let original = try JSONSerialization.data(withJSONObject: object)
      try original.write(to: url)
      try repository.withLock { try repository.recover() }
      let recovered = try DeliveryJournal.read(from: url)
      #expect(recovered.project == journal.project)
      #expect(recovered.phase == .finished)
      let after = try Data(contentsOf: url)
      if finished {
        #expect(after == original)
      } else {
        let current = try #require(try JSONSerialization.jsonObject(with: after) as? [String: Any])
        #expect(current["workspace"] == nil)
        #expect(current["project"] as? String == journal.project)
      }
      try fixture.assertClean()
    }
  }

  @Test(arguments: Interruption.allCases)
  func recoverInterruptedGitStates(at point: Interruption) async throws {
    try await deliveryTest {

      let fixture = try DeliveryFixture()
      let journal = try interrupted(fixture, at: point)
      let repository = try fixture.repository()
      try repository.withLock { try repository.recover() }
      if point == .duringRebase {
        let pending = try #require(fixture.journals().first)
        #expect(pending.phase == .cleanupPending && pending.reason == .rebaseInProgress)
        #expect(repository.rebaseDirectory(pending) != nil)
        try fixture.git(["rebase", "--abort"], at: URL(fileURLWithPath: journal.worktree))
        try repository.withLock { try repository.recover() }
      }
      let recovered = try #require(fixture.journals().first)
      #expect(recovered.phase == .finished)
      let committed = point != .beforeWorktree && point != .beforeCommit
      #expect(
        recovered.state == (point == .afterMerge ? .merged : committed ? .committed : .aborted))
      #expect(recovered.reason == (point == .afterMerge ? nil : .interrupted))
      #expect((recovered.commit != nil) == committed)
      if committed && point != .afterMerge {
        #expect(try fixture.git(["show", "\(journal.branch):notes/log.md"]) == "beta\nstable")
      }
      try fixture.assertClean(retained: committed && point != .afterMerge)
      try repository.withLock { try repository.recover() }
      #expect(try fixture.journals().first?.phase == .finished)
    }
  }

  @Test(arguments: [false, true])
  func journalFailureAfterCommitRetainsUndeliveredBranch(persistent: Bool) async throws {
    try await deliveryTest {

      let fixture = try DeliveryFixture()
      let io = DeliveryIO(beforeJournalWrite: { journal in
        if journal.phase == .committed || (persistent && journal.commit != nil) {
          throw CocoaError(.fileWriteNoPermission)
        }
      })
      let result = try fixture.apply(provider: fixture.provider(io: io))
      #expect(result["state"] == .string("committed"))
      #expect(result["reason"] == .string("journal_failed"))
      #expect(result["commit"]?.stringValue == (try fixture.git(["rev-parse", "docs/entry"])))
      #expect(try fixture.read("notes/log.md") == "alpha\nstable\n")
      try fixture.assertClean(retained: true)
      if persistent {
        #expect(try fixture.journals().first?.phase == .started)
        let repository = try fixture.repository()
        try repository.withLock { try repository.recover() }
        #expect(try fixture.journals().first?.state == .committed)
        #expect(try fixture.journals().first?.reason == .interrupted)
        try fixture.assertClean(retained: true)
      }
    }
  }

  @Test
  func initialJournalFailureDoesNotCreateBranchOrWorktree() async throws {
    try await deliveryTest {

      let fixture = try DeliveryFixture()
      let result = try fixture.apply(
        provider: fixture.provider(
          io: .init(beforeJournalWrite: { _ in throw CocoaError(.fileWriteNoPermission) })))
      #expect(result["state"] == .string("aborted"))
      #expect(result["reason"] == .string("journal_failed"))
      #expect(try fixture.journals().isEmpty)
      try fixture.assertClean()
    }
  }

  @Test(arguments: [".git", ".git/computer-mcp"])
  func journalParentSyncFailurePreventsGitMutation(path: String) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let head = try fixture.git(["rev-parse", "HEAD"])
      let io = DeliveryIO(beforeDirectorySync: { directory in
        if directory.path == fixture.root.appendingPathComponent(path).path {
          throw POSIXError(.EIO)
        }
      })
      let result = try fixture.apply(provider: fixture.provider(io: io))
      #expect(result["state"] == .string("aborted"))
      #expect(try fixture.git(["rev-parse", "HEAD"]) == head)
      #expect(try fixture.journals().isEmpty)
      try fixture.assertClean()
    }
  }

  @Test(arguments: [false, true])
  func cleanupFailureBeforeAndAfterCommitRetries(committed: Bool) async throws {
    try await deliveryTest {

      let fixture = try DeliveryFixture()
      var scope = fixture.scope
      scope.mode = .commitOnly
      let io = DeliveryIO(beforeCleanup: { _ in throw CocoaError(.fileWriteNoPermission) })
      let result = try fixture.apply(
        fixture.request(old: committed ? "alpha" : "missing"),
        provider: fixture.provider(scope: scope, io: io))
      #expect(result["state"] == .string("cleanup_pending"))
      #expect(result["reason"] == .string("cleanup_failed"))
      let pending = try #require(fixture.journals().first)
      #expect(pending.phase == .cleanupPending)
      #expect((pending.commit != nil) == committed)
      #expect(!pending.merged)
      let repository = try fixture.repository(scope: scope)
      try repository.withLock { try repository.recover() }
      let recovered = try #require(fixture.journals().first)
      #expect(recovered.phase == .finished)
      #expect(recovered.state == (committed ? .committed : .aborted))
      try fixture.assertClean(retained: committed)
    }
  }

  @Test
  func mergedCleanupFailureRetriesAndDeletesBranch() async throws {
    try await deliveryTest {

      let fixture = try DeliveryFixture()
      let result = try fixture.apply(
        provider: fixture.provider(
          io: .init(beforeCleanup: { _ in throw CocoaError(.fileWriteNoPermission) })))
      #expect(result["state"] == .string("cleanup_pending"))
      #expect(try fixture.journals().first?.merged == true)
      let repository = try fixture.repository()
      try repository.withLock { try repository.recover() }
      #expect(try fixture.journals().first?.state == .merged)
      try fixture.assertClean()
    }
  }

  @Test(arguments: [false, true])
  func branchAdvancementAfterDeletionCheckRetainsNewCommit(merged: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let io = DeliveryIO(beforeBranchDeletion: { branch, checkedCommit in
        #expect(branch == "docs/entry")
        #expect(try fixture.git(["rev-parse", "main"]) == checkedCommit)
        let advanced = try fixture.git([
          "commit-tree", "\(checkedCommit)^{tree}", "-p", checkedCommit,
          "-m", "test: external branch advancement",
        ])
        try fixture.git(["update-ref", "refs/heads/\(branch)", advanced, checkedCommit])
        try fixture.write(".git/advanced-commit", advanced)
      })
      let result = try fixture.apply(
        fixture.request(old: merged ? "alpha" : "absent"), provider: fixture.provider(io: io))
      #expect(result["state"] == .string("cleanup_pending"))
      #expect(result["reason"] == .string("cleanup_failed"))
      #expect(result["branch"] == .string("docs/entry"))
      let advanced = try fixture.read(".git/advanced-commit")
      #expect(try fixture.git(["rev-parse", "docs/entry"]) == advanced)
      try fixture.git(["cat-file", "-e", "\(advanced)^{commit}"])
      let repository = try fixture.repository()
      #expect(try !repository.git.isAncestor(advanced, of: "main", at: fixture.root))
      let pending = try #require(fixture.journals().first)
      #expect(pending.phase == .cleanupPending)
      #expect(pending.merged == merged)
      #expect((pending.commit != nil) == merged)
      try fixture.assertClean(retained: true)

      try repository.withLock { try repository.recover() }
      let recovered = try #require(fixture.journals().first)
      #expect(recovered.phase == .finished)
      #expect(recovered.state == .committed)
      #expect(recovered.reason == .interrupted)
      #expect(recovered.commit == advanced)
      #expect(try fixture.git(["rev-parse", "docs/entry"]) == advanced)
      try fixture.assertClean(retained: true)
    }
  }

  @Test
  func cleanupKeepsRetryingWhileFailurePersists() async throws {
    try await deliveryTest {

      let fixture = try DeliveryFixture()
      _ = try interrupted(fixture, at: .afterCommit)
      let repository = try fixture.repository(
        io: .init(beforeCleanup: { _ in throw CocoaError(.fileWriteNoPermission) }))
      for _ in 0..<2 {
        try repository.withLock { try repository.recover() }
        #expect(try fixture.journals().first?.phase == .cleanupPending)
        #expect(!(try fixture.git(["branch", "--list", "docs/entry"])).isEmpty)
      }
      let retry = try fixture.repository()
      try retry.withLock { try retry.recover() }
      try fixture.assertClean(retained: true)
    }
  }

  @Test
  func defaultBranchResetBeforeDeletionRetainsUndeliveredCommit() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let base = try fixture.git(["rev-parse", "HEAD"])
      let io = DeliveryIO(beforeBranchDeletion: { branch, checkedCommit in
        #expect(branch == "docs/entry")
        #expect(try fixture.git(["rev-parse", "main"]) == checkedCommit)
        try fixture.git(["reset", "--hard", base])
      })
      let result = try fixture.apply(provider: fixture.provider(io: io))
      #expect(result["state"] == .string("cleanup_pending"))
      #expect(result["reason"] == .string("cleanup_failed"))
      #expect(result["branch"] == .string("docs/entry"))
      #expect(try fixture.git(["rev-parse", "main"]) == base)
      #expect(try fixture.git(["rev-parse", "docs/entry"]) == result["commit"]?.stringValue)
      #expect(try fixture.git(["show", "docs/entry:notes/log.md"]) == "beta\nstable")
      #expect(try fixture.journals().first?.phase == .cleanupPending)
      try fixture.assertClean(retained: true)

      let repository = try fixture.repository()
      try repository.withLock { try repository.recover() }
      let recovered = try #require(fixture.journals().first)
      #expect(recovered.state == .committed && recovered.phase == .finished)
      #expect(recovered.reason == .interrupted && !recovered.merged)
      try fixture.assertClean(retained: true)
    }
  }

  @Test
  func recoveryCleansCommitReachableFromAdvancedDefault() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let journal = try interrupted(fixture, at: .afterMerge)
      try fixture.git(["commit", "--allow-empty", "-m", "test: advance landed default"])
      let repository = try fixture.repository()
      try repository.withLock { try repository.recover() }
      let recovered = try #require(fixture.journals().first)
      #expect(recovered.state == .merged && recovered.phase == .finished && recovered.merged)
      #expect(recovered.commit == journal.commit)
      try fixture.assertClean()
    }
  }

  @Test(arguments: [false, true], [false, true])
  func recoveryPreservesMissingAndEmptyWorktreeRegistration(empty: Bool, committed: Bool)
    async throws
  {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let journal = try interrupted(fixture, at: committed ? .afterCommit : .beforeCommit)
      let worktree = URL(fileURLWithPath: journal.worktree)
      try FileManager.default.removeItem(at: worktree)
      if empty {
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
      }
      #expect(try fixture.git(["worktree", "list", "--porcelain"]).contains(worktree.path))
      let repository = try fixture.repository()
      try repository.withLock { try repository.recover() }
      let recovered = try #require(fixture.journals().first)
      #expect(recovered.phase == .cleanupPending && recovered.state == .cleanupPending)
      #expect(recovered.reason == .worktreeRegistrationRetained)
      #expect(
        recovered.message?.contains(try #require(journal.creation).worktree.directory) == true)
      #expect(!FileManager.default.fileExists(atPath: worktree.path))
      #expect(try fixture.git(["worktree", "list", "--porcelain"]).contains(worktree.path))
      #expect(try fixture.git(["rev-parse", journal.branch]) == (journal.commit ?? journal.base))
      try fixture.git(["worktree", "prune", "--expire", "now"])
      try repository.withLock { try repository.recover() }
      #expect(try fixture.journals().first?.phase == .finished)
      try fixture.assertClean(retained: committed)
    }
  }

  @Test
  func recoveryPreservesMissingWorktreeAtRecordedDetachedCommit() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let journal = try interrupted(fixture, at: .afterCommit)
      let worktree = URL(fileURLWithPath: journal.worktree)
      try fixture.git(["checkout", "--detach", try #require(journal.commit)], at: worktree)
      try FileManager.default.removeItem(at: worktree)
      let repository = try fixture.repository()
      try repository.withLock { try repository.recover() }
      #expect(try fixture.journals().first?.reason == .worktreeRegistrationRetained)
      #expect(try fixture.git(["worktree", "list", "--porcelain"]).contains(worktree.path))
      #expect(try fixture.git(["rev-parse", journal.branch]) == journal.commit)
    }
  }

  @Test(arguments: [false, true])
  func recoveryPreservesMovedWorktreeWithChangedHead(detached: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let journal = try interrupted(fixture, at: .afterCommit)
      let worktree = URL(fileURLWithPath: journal.worktree)
      try fixture.git(
        detached ? ["checkout", "--detach"] : ["switch", "-c", "other"], at: worktree)
      try fixture.write("outside.txt", "unique worktree commit\n", at: worktree)
      try fixture.git(["commit", "-am", "test: unique worktree commit"], at: worktree)
      let unique = try fixture.git(["rev-parse", "HEAD"], at: worktree)
      let directory = URL(fileURLWithPath: try #require(journal.creation).worktree.directory)
      let head = try Data(contentsOf: directory.appendingPathComponent("HEAD"))
      let reflog = try Data(contentsOf: directory.appendingPathComponent("logs/HEAD"))
      let moved = fixture.temporary.url.appendingPathComponent("moved")
      try FileManager.default.moveItem(at: worktree, to: moved)
      let repository = try fixture.repository()
      for _ in 0..<2 {
        try repository.withLock { try repository.recover() }
        let pending = try #require(fixture.journals().first)
        #expect(pending.state == .cleanupPending && pending.reason == .worktreeRegistrationRetained)
        #expect(pending.message?.contains(directory.path) == true)
        #expect(try Data(contentsOf: directory.appendingPathComponent("HEAD")) == head)
        #expect(try Data(contentsOf: directory.appendingPathComponent("logs/HEAD")) == reflog)
        #expect(try fixture.git(["--git-dir=\(directory.path)", "rev-parse", "HEAD"]) == unique)
        #expect(try fixture.git(["rev-parse", journal.branch]) == journal.commit)
        #expect(try fixture.read("outside.txt", at: moved) == "unique worktree commit\n")
      }
      try fixture.git(["worktree", "repair", moved.path])
      #expect(try fixture.git(["rev-parse", "HEAD"], at: moved) == unique)
    }
  }

  @Test
  func fileAppearingBeforeEmptyDirectoryRemovalIsPreserved() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let journal = try interrupted(fixture, at: .beforeCommit)
      let worktree = URL(fileURLWithPath: journal.worktree)
      try FileManager.default.removeItem(at: worktree)
      try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
      let repository = try fixture.repository(
        io: .init(beforeEmptyDirectoryRemoval: { directory in
          #expect(directory == worktree)
          #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
          try fixture.write("keep.txt", "external creation\n", at: directory)
        }))
      try repository.withLock { try repository.recover() }
      let retry = try fixture.repository()
      try retry.withLock { try retry.recover() }
      let pending = try #require(fixture.journals().first)
      #expect(pending.state == .cleanupPending && pending.reason == .worktreeUnrecognized)
      #expect(pending.message?.contains(worktree.path) == true)
      #expect(try fixture.read("keep.txt", at: worktree) == "external creation\n")
      #expect(try fixture.git(["rev-parse", journal.branch]) == journal.base)
      #expect(try fixture.git(["worktree", "list", "--porcelain"]).contains(worktree.path))
      try FileManager.default.removeItem(at: worktree.appendingPathComponent("keep.txt"))
      try retry.withLock { try retry.recover() }
      #expect(try fixture.journals().first?.reason == .worktreeRegistrationRetained)
      try fixture.git(["worktree", "prune", "--expire", "now"])
      try retry.withLock { try retry.recover() }
      #expect(try fixture.journals().first?.state == .aborted)
      try fixture.assertClean()
    }
  }

  @Test
  func missingWorktreeRegistrationSurvivesUnlock() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let journal = try interrupted(fixture, at: .afterCommit)
      try fixture.git(["worktree", "lock", journal.worktree])
      try FileManager.default.removeItem(at: URL(fileURLWithPath: journal.worktree))
      let repository = try fixture.repository()
      try repository.withLock { try repository.recover() }
      let pending = try #require(fixture.journals().first)
      #expect(pending.state == .cleanupPending && pending.phase == .cleanupPending)
      #expect(pending.reason == .worktreeRegistrationRetained)
      #expect(try fixture.git(["worktree", "list", "--porcelain"]).contains(journal.worktree))
      #expect(try fixture.git(["rev-parse", journal.branch]) == journal.commit)
      try fixture.git(["worktree", "unlock", journal.worktree])
      try repository.withLock { try repository.recover() }
      #expect(try fixture.journals().first?.reason == .worktreeRegistrationRetained)
      try fixture.git(["worktree", "prune", "--expire", "now"])
      try repository.withLock { try repository.recover() }
      #expect(try fixture.journals().first?.state == .committed)
      try fixture.assertClean(retained: true)
    }
  }

  @Test(arguments: [false, true])
  func recoveryPreservesUnrelatedMissingWorktreeRegistration(empty: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let journal = try interrupted(fixture, at: .afterCommit)
      let other = fixture.temporary.url.appendingPathComponent("unrelated")
      try fixture.git(["worktree", "add", "--detach", other.path, "main"])
      try fixture.write("outside.txt", "unique detached work\n", at: other)
      try fixture.git(["commit", "-am", "test: detached work"], at: other)
      let unique = try fixture.git(["rev-parse", "HEAD"], at: other)
      let otherDirectory = URL(
        fileURLWithPath: try fixture.git(["rev-parse", "--git-dir"], at: other))
      let names = try FileManager.default.subpathsOfDirectory(atPath: otherDirectory.path)
      let before = Dictionary(
        uniqueKeysWithValues: names.compactMap { name -> (String, Data)? in
          let path = otherDirectory.appendingPathComponent(name)
          guard let data = try? Data(contentsOf: path) else { return nil }
          return (name, data)
        })
      try FileManager.default.removeItem(at: other)
      let worktree = URL(fileURLWithPath: journal.worktree)
      try FileManager.default.removeItem(at: worktree)
      if empty {
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
      }
      let repository = try fixture.repository()
      try repository.withLock { try repository.recover() }
      #expect(try fixture.journals().first?.reason == .worktreeRegistrationRetained)
      #expect(try fixture.git(["worktree", "list", "--porcelain"]).contains(other.path))
      #expect(try fixture.git(["worktree", "list", "--porcelain"]).contains(journal.worktree))
      for (name, bytes) in before {
        #expect(try Data(contentsOf: otherDirectory.appendingPathComponent(name)) == bytes)
      }
      #expect(
        try fixture.git(["rev-parse", "worktrees/\(otherDirectory.lastPathComponent)/HEAD"])
          == unique)
      #expect(try fixture.git(["show", "\(unique):outside.txt"]) == "unique detached work")
    }
  }

  @Test
  func missingWorktreeWithChangedBacklinkIsRetained() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let journal = try interrupted(fixture, at: .afterCommit)
      let identity = try #require(journal.creation).worktree
      let directory = URL(fileURLWithPath: identity.directory)
      try FileManager.default.removeItem(at: URL(fileURLWithPath: journal.worktree))
      let changed = Data((identity.gitdir + "\n").utf8)
      try changed.write(to: directory.appendingPathComponent("gitdir"))
      let repository = try fixture.repository()
      try repository.withLock { try repository.recover() }
      #expect(try fixture.journals().first?.phase == .cleanupPending)
      #expect(try fixture.journals().first?.reason == .worktreeRegistrationRetained)
      #expect(try Data(contentsOf: directory.appendingPathComponent("gitdir")) == changed)
      #expect(try fixture.git(["rev-parse", journal.branch]) == journal.commit)
      try Data(identity.gitdir.utf8).write(to: directory.appendingPathComponent("gitdir"))
      try repository.withLock { try repository.recover() }
      #expect(try fixture.journals().first?.reason == .worktreeRegistrationRetained)
      try fixture.git(["worktree", "prune", "--expire", "now"])
      try repository.withLock { try repository.recover() }
      try fixture.assertClean(retained: true)
    }
  }

  @Test(arguments: ["matching", "unrecorded", "orig-head", "onto"], [false, true])
  func recoveryPreservesInProgressRebase(ownership: String, resolved: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      var journal = try interrupted(
        fixture, at: ownership == "unrecorded" ? .afterCommit : .duringRebase)
      let worktree = URL(fileURLWithPath: journal.worktree)
      if ownership == "unrecorded" {
        try fixture.write("notes/log.md", "user rebase target\nstable\n")
        try fixture.git(["commit", "-am", "test: user rebase target"])
        try fixture.git(["rebase", "main"], at: worktree, accepting: [1])
        #expect(journal.rebase == nil)
      } else if ownership == "orig-head" {
        journal.rebase?.original = journal.base
      } else if ownership == "onto" {
        journal.rebase?.onto = journal.base
      }
      let repository = try fixture.repository()
      try repository.io.write(journal, to: repository.journals)
      if resolved {
        try fixture.write("notes/log.md", "user conflict resolution\n", at: worktree)
        try fixture.git(["add", "notes/log.md"], at: worktree)
      }
      let directory = URL(fileURLWithPath: try #require(journal.creation).worktree.directory)
      let index = try Data(contentsOf: directory.appendingPathComponent("index"))
      let content = try fixture.read("notes/log.md", at: worktree)
      let head = try fixture.git(["rev-parse", "HEAD"], at: worktree)
      let rebase = try #require(repository.rebaseDirectory(journal))
      let original = try Data(contentsOf: rebase.appendingPathComponent("orig-head"))
      let onto = try Data(contentsOf: rebase.appendingPathComponent("onto"))
      if ownership == "matching" {
        #expect(
          String(data: original, encoding: .utf8)?.trimmingCharacters(in: .newlines)
            == journal.rebase?.original)
        #expect(
          String(data: onto, encoding: .utf8)?.trimmingCharacters(in: .newlines)
            == journal.rebase?.onto)
      }
      for _ in 0..<2 {
        try repository.withLock { try repository.recover() }
        #expect(try fixture.journals().first?.phase == .cleanupPending)
        #expect(try fixture.journals().first?.reason == .rebaseInProgress)
        #expect(try fixture.journals().first?.message?.contains(worktree.path) == true)
        #expect(try Data(contentsOf: directory.appendingPathComponent("index")) == index)
        #expect(try fixture.read("notes/log.md", at: worktree) == content)
        #expect(try fixture.git(["rev-parse", "HEAD"], at: worktree) == head)
        #expect(try Data(contentsOf: rebase.appendingPathComponent("orig-head")) == original)
        #expect(try Data(contentsOf: rebase.appendingPathComponent("onto")) == onto)
        #expect(try fixture.git(["rev-parse", journal.branch]) == journal.commit)
      }
      try fixture.git(["rebase", "--abort"], at: worktree)
      try repository.withLock { try repository.recover() }
      try fixture.assertClean(retained: true)
    }
  }

  @Test
  func applyRecoversBeforeItsOwnPreflight() async throws {
    try await deliveryTest {

      let fixture = try DeliveryFixture()
      _ = try interrupted(fixture, at: .beforeCommit)
      #expect(try fixture.apply()["state"] == .string("merged"))
      #expect(try fixture.journals().count == 2)
      try fixture.assertClean()
    }
  }

  @Test(arguments: [false, true])
  func recoveryKeepsUnrecognizedWorktreeAndMainRebase(registered: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      var journal = try interrupted(fixture, at: .beforeWorktree)
      let worktree = URL(fileURLWithPath: journal.worktree)
      var gitfile: Data?
      if registered {
        try fixture.git(["worktree", "add", "-b", journal.branch, worktree.path, journal.base])
        try fixture.repository().recordCreation(&journal)
        gitfile = try Data(contentsOf: worktree.appendingPathComponent(".git"))
        try FileManager.default.removeItem(at: worktree.appendingPathComponent(".git"))
      } else {
        try fixture.write("keep.txt", "unrecognized content\n", at: worktree)
      }
      try fixture.git(["switch", "-c", "docs/main-rebase"])
      try fixture.write("notes/log.md", "topic\nstable\n")
      try fixture.git(["commit", "-am", "test: topic change"])
      try fixture.git(["switch", "main"])
      try fixture.write("notes/log.md", "main\nstable\n")
      try fixture.git(["commit", "-am", "test: main change"])
      try fixture.git(["rebase", "docs/main-rebase"], accepting: [1])
      let head = try fixture.git(["rev-parse", "HEAD"])
      let index = try Data(contentsOf: fixture.root.appendingPathComponent(".git/index"))
      let conflict = try fixture.read("notes/log.md")

      let trace = fixture.temporary.url.appendingPathComponent("git-directories")
      let wrapper = fixture.temporary.url.appendingPathComponent("git-wrapper")
      let script = """
        #!\(try testExecutable("sh"))
        printf '%s\\n' "$PWD" >> \(quote(trace.path))
        case " $* " in
          *" --no-optional-locks "*) ;;
          *" rev-parse "*|*" merge-base "*|*" show-ref "*|*" worktree list "*) exit 88 ;;
        esac
        exec \(quote(fixture.executable)) "$@"
        """
      try Data(script.utf8).write(to: wrapper)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
      var configuration = fixture.tools().configuration
      configuration.cli.commands[0].executable = wrapper.path
      let tools = ToolEnvironment(
        launcher: testExecutionLauncher(), configuration: configuration,
        environment: fixture.environment)
      let repository = try DeliveryRepository(
        scope: fixture.scope, project: fixture.root, git: DeliveryGit(environment: tools))
      try repository.withLock { try repository.recover() }
      let pending = try #require(fixture.journals().first)
      #expect(pending.phase == .cleanupPending)
      #expect(pending.state == .cleanupPending)
      #expect(pending.reason == .worktreeUnrecognized)
      #expect(pending.worktree == worktree.path)
      #expect(FileManager.default.fileExists(atPath: worktree.path))
      #expect(
        FileManager.default.fileExists(
          atPath: fixture.root.appendingPathComponent(".git/rebase-merge").path))
      #expect(try fixture.git(["rev-parse", "HEAD"]) == head)
      #expect(try Data(contentsOf: fixture.root.appendingPathComponent(".git/index")) == index)
      #expect(try fixture.read("notes/log.md") == conflict)
      let directories = try String(contentsOf: trace, encoding: .utf8).split(separator: "\n")
      #expect(!directories.contains(Substring(worktree.path)))

      try fixture.git(["rebase", "--abort"])
      if let gitfile {
        try gitfile.write(to: worktree.appendingPathComponent(".git"))
      } else {
        #expect(try fixture.read("keep.txt", at: worktree) == "unrecognized content\n")
        try FileManager.default.removeItem(at: worktree.appendingPathComponent("keep.txt"))
      }
      try repository.withLock { try repository.recover() }
      #expect(try fixture.journals().first?.phase == .finished)
      #expect(!FileManager.default.fileExists(atPath: worktree.path))
      try fixture.assertClean()
    }
  }

  @Test
  func recoveryRejectsGitfileForAnotherWorktree() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let journal = try interrupted(fixture, at: .afterCommit)
      let worktree = URL(fileURLWithPath: journal.worktree)
      let linked = fixture.temporary.url.appendingPathComponent("linked")
      try fixture.git(["worktree", "add", "-b", "other", linked.path])
      let gitfile = try Data(contentsOf: worktree.appendingPathComponent(".git"))
      let otherGitfile = try Data(contentsOf: linked.appendingPathComponent(".git"))
      try otherGitfile.write(to: worktree.appendingPathComponent(".git"))
      let repository = try fixture.repository()
      try repository.withLock { try repository.recover() }
      #expect(try fixture.journals().first?.reason == .worktreeUnrecognized)
      #expect(try fixture.read("notes/log.md", at: worktree) == "beta\nstable\n")
      #expect(try fixture.read("notes/log.md", at: linked) == "alpha\nstable\n")
      try gitfile.write(to: worktree.appendingPathComponent(".git"))
      try repository.withLock { try repository.recover() }
      try fixture.git(["worktree", "remove", linked.path])
      try fixture.assertClean(retained: true)
    }
  }

  @Test
  func providerStartupRecoversAndShutdownJoins() async throws {
    let fixture = try DeliveryFixture()
    _ = try interrupted(fixture, at: .afterMerge)
    let provider = DeliveryToolProvider(environment: fixture.tools())
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while try fixture.journals().first?.phase != .finished && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    await provider.shutdown()
    #expect(try fixture.journals().first?.phase == .finished)
    try fixture.assertClean()
  }

  @Test
  func concurrentCallsSerializeAcrossProviders() async throws {
    let fixture = try DeliveryFixture()
    // The first commit holds the repository lock long enough for the second call to queue.
    let entered = fixture.root.appendingPathComponent(".git/entered")
    let release = fixture.root.appendingPathComponent(".git/release")
    try fixture.hook(
      "pre-commit",
      body:
        "touch \(quote(entered.path))\nwhile ! test -f \(quote(release.path)); do sleep 0.02; done")
    let first = fixture.provider()
    let second = fixture.provider()
    let firstCall = Task {
      try await first.callToolAsync(
        .init(name: "delivery.apply", arguments: fixture.request(), context: .empty))
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !FileManager.default.fileExists(atPath: entered.path) && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(FileManager.default.fileExists(atPath: entered.path))
    let secondCall = Task {
      try await second.callToolAsync(
        .init(
          name: "delivery.apply",
          arguments: fixture.request(old: "beta", new: "gamma", slug: "second"), context: .empty))
    }
    try await Task.sleep(for: .milliseconds(100))
    #expect(try fixture.journals().count == 1)
    try Data().write(to: release)
    let results = try await [firstCall.value, secondCall.value]
    for envelope in results {
      #expect(
        envelope.objectValue?["structuredContent"]?.objectValue?["result"]?.objectValue?["state"]
          == .string("merged"))
    }
    #expect(try fixture.read("notes/log.md") == "gamma\nstable\n")
    try fixture.assertClean()
    #expect(try fixture.git(["branch", "--list", "docs/second"]).isEmpty)
  }

  @Test
  func cancellationBeforeDispatchDoesNotCreateJournal() async throws {
    let fixture = try DeliveryFixture()
    let provider = fixture.provider()
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await provider.callToolAsync(
        .init(name: "delivery.apply", arguments: fixture.request(), context: .empty))
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try fixture.journals().isEmpty)
  }

  @Test
  func finalJournalFailureReportsOnlyAnActuallyRetainedBranch() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let provider = fixture.provider(
        io: .init(beforeJournalWrite: { journal in
          if journal.phase == .finished { throw CocoaError(.fileWriteNoPermission) }
        }))
      let result = try fixture.apply(provider: provider)
      #expect(result["state"] == .string("cleanup_pending"))
      #expect(result["branch"] == nil)
      #expect(try fixture.journals().first?.merged == true)
      let repository = try fixture.repository()
      try repository.withLock { try repository.recover() }
      #expect(try fixture.journals().first?.state == .merged)
      try fixture.assertClean()
    }
  }

  @Test
  func sharedCommonDirectoryRecoveryAcrossRegisteredCheckouts() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let linked = fixture.temporary.url.appendingPathComponent("linked")
      try fixture.git(["worktree", "add", "-b", "other", linked.path])
      var configuration = fixture.tools().configuration
      configuration.projectDirectory = linked
      configuration.projects[0].path = linked.path
      let provider = DeliveryToolProvider(
        environment: .init(
          launcher: testExecutionLauncher(), configuration: configuration,
          environment: fixture.environment),
        io: .init(beforeCleanup: { _ in throw CocoaError(.fileWriteNoPermission) }),
        startsRecovery: false)
      #expect(try fixture.apply(provider: provider)["state"] == .string("cleanup_pending"))
      let repository = try fixture.repository()
      try repository.withLock { try repository.recover() }
      #expect(try fixture.journals().first?.state == .merged)
      try repository.withLock { try repository.recover() }
      try fixture.git(["worktree", "remove", "--force", linked.path])
      try fixture.git(["branch", "-D", "other"])
      try fixture.assertClean()
    }
  }

  @Test
  func recoveryPreservesMovedWorktreeAndReplacement() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let journal = try interrupted(fixture, at: .afterCommit)
      let worktree = URL(fileURLWithPath: journal.worktree)
      let moved = fixture.temporary.url.appendingPathComponent("moved")
      try fixture.git(["worktree", "move", worktree.path, moved.path])
      try fixture.git(["worktree", "add", "-b", "other", worktree.path, "main"])
      try fixture.write("outside.txt", "replacement staged work\n", at: worktree)
      try fixture.git(["add", "outside.txt"], at: worktree)
      try fixture.write("notes/log.md", "replacement unstaged work\n", at: worktree)
      try fixture.write("keep.txt", "untracked work\n", at: worktree)
      let replacementGitfile = try fixture.read(".git", at: worktree)
      let repository = try fixture.repository()
      try repository.withLock { try repository.recover() }
      let pending = try #require(fixture.journals().first)
      #expect(pending.phase == .cleanupPending && pending.reason == .worktreeUnrecognized)
      #expect(try fixture.read(".git", at: worktree) == replacementGitfile)
      #expect(try fixture.git(["branch", "--show-current"], at: worktree) == "other")
      #expect(try fixture.git(["show", ":outside.txt"], at: worktree) == "replacement staged work")
      #expect(try fixture.read("notes/log.md", at: worktree) == "replacement unstaged work\n")
      #expect(try fixture.read("keep.txt", at: worktree) == "untracked work\n")
      #expect(try fixture.read("notes/log.md", at: moved) == "beta\nstable\n")
      #expect(try fixture.git(["rev-parse", journal.branch]) == journal.commit)
    }
  }

  @Test(arguments: [false, true])
  func recoveryRejectsChangedWorktreeBranchOrBacklink(changedBranch: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let journal = try interrupted(fixture, at: .afterCommit)
      let worktree = URL(fileURLWithPath: journal.worktree)
      if changedBranch {
        try fixture.git(["switch", "-c", "other"], at: worktree)
      } else {
        let directory = URL(fileURLWithPath: try #require(journal.creation).worktree.directory)
        try Data((worktree.appendingPathComponent(".git").path + "\n\n").utf8)
          .write(to: directory.appendingPathComponent("gitdir"))
      }
      let repository = try fixture.repository()
      try repository.withLock { try repository.recover() }
      #expect(try fixture.journals().first?.reason == .worktreeUnrecognized)
      #expect(try fixture.read("notes/log.md", at: worktree) == "beta\nstable\n")
      #expect(try fixture.git(["rev-parse", journal.branch]) == journal.commit)
    }
  }

  @Test
  func gitfileDisappearanceAfterVerificationCannotAbortMainRebase() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let journal = try interrupted(fixture, at: .duringRebase)
      let worktree = URL(fileURLWithPath: journal.worktree)
      try fixture.git(["switch", "-c", "topic"])
      try fixture.write("notes/log.md", "topic\nstable\n")
      try fixture.git(["commit", "-am", "test: topic"])
      try fixture.git(["switch", "main"])
      try fixture.write("notes/log.md", "main\nstable\n")
      try fixture.git(["commit", "-am", "test: main"])
      try fixture.git(["rebase", "topic"], accepting: [1])
      let head = try fixture.git(["rev-parse", "HEAD"])
      let index = try Data(contentsOf: fixture.root.appendingPathComponent(".git/index"))
      let conflict = try fixture.read("notes/log.md")
      let gitfile = try Data(contentsOf: worktree.appendingPathComponent(".git"))
      let deliveryConflict = try fixture.read("notes/log.md", at: worktree)
      let io = DeliveryIO(afterWorktreeVerification: { _ in
        let path = worktree.appendingPathComponent(".git")
        if FileManager.default.fileExists(atPath: path.path) {
          try FileManager.default.removeItem(at: path)
        }
      })
      let repository = try fixture.repository(io: io)
      try repository.withLock { try repository.recover() }
      #expect(try fixture.journals().first?.reason == .rebaseInProgress)
      try repository.withLock { try repository.recover() }
      #expect(try fixture.journals().first?.reason == .worktreeUnrecognized)
      #expect(try fixture.git(["rev-parse", "HEAD"]) == head)
      #expect(try Data(contentsOf: fixture.root.appendingPathComponent(".git/index")) == index)
      #expect(try fixture.read("notes/log.md") == conflict)
      #expect(
        FileManager.default.fileExists(
          atPath: fixture.root.appendingPathComponent(".git/rebase-merge").path))
      let directory = URL(fileURLWithPath: try #require(journal.creation).worktree.directory)
      #expect(
        FileManager.default.fileExists(
          atPath: directory.appendingPathComponent("rebase-merge").path))
      #expect(try fixture.read("notes/log.md", at: worktree) == deliveryConflict)
      try gitfile.write(to: worktree.appendingPathComponent(".git"))
      try fixture.git(["rebase", "--abort"], at: worktree)
      try fixture.git(["rebase", "--abort"])
    }
  }

  private func interrupted(_ fixture: DeliveryFixture, at point: Interruption) throws
    -> DeliveryJournal
  {
    let repository = try fixture.repository()
    let operationID = UUID().uuidString.lowercased()
    let worktree = fixture.root.appendingPathComponent(".claude/worktrees/" + operationID)
    var journal = DeliveryJournal(
      operationID: operationID, project: "fixture", scope: "notes",
      repository: fixture.root.path, defaultBranch: "main", branch: "docs/entry",
      worktree: worktree.path,
      base: try fixture.git(["rev-parse", "main"]))
    try repository.io.write(journal, to: repository.journals)
    if point == .beforeWorktree { return journal }
    try fixture.git(["worktree", "add", "-b", journal.branch, worktree.path, journal.base])
    try repository.recordCreation(&journal)
    let pinned = try #require(try repository.verifiedWorktree(journal))
    _ = try repository.edit(
      DeliveryRequest(arguments: fixture.request()), journal: &journal, git: pinned)
    try fixture.git(["add", "notes/log.md"], at: worktree)
    journal.staged = [
      "notes/log.md": try pinned.run(
        ["--no-optional-locks", "ls-files", "--stage", "-z", "--", "notes/log.md"], at: worktree
      ).stdout
    ]
    try repository.io.write(journal, to: repository.journals)
    if point == .beforeCommit { return journal }
    try fixture.git(["commit", "-m", "docs: interrupted entry"], at: worktree)
    let commit = try fixture.git(["rev-parse", "HEAD"], at: worktree)
    if point == .afterCommitBeforeJournal { return journal }
    journal.phase = .committed
    journal.commit = commit
    try repository.io.write(journal, to: repository.journals)
    if point == .duringRebase {
      try fixture.write("notes/log.md", "gamma\nstable\n")
      try fixture.git(["add", "notes/log.md"])
      try fixture.git(["commit", "-m", "test: concurrent conflict"])
      journal.rebase = .init(original: commit, onto: try fixture.git(["rev-parse", "main"]))
      try repository.io.write(journal, to: repository.journals)
      try fixture.git(["rebase", "main"], at: worktree, accepting: [1])
    }
    if point == .afterMerge { try fixture.git(["merge", "--ff-only", journal.branch]) }
    return journal
  }
}
