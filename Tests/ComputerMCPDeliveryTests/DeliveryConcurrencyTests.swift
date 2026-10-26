import ComputerMCPConfiguration
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPDelivery

@Suite(.nativeIntegration)
struct DeliveryConcurrencyTests {
  @Test
  func ignoredMainFileBeforeLandingIsPreserved() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let baseline = try fixture.git(["rev-parse", "HEAD"])
      let provider = fixture.provider(
        io: .init(beforeMergeCheck: { _ in
          try fixture.write(".gitignore", ".claude/worktrees/\nnotes/new.md\n")
          try fixture.write("notes/new.md", "external ignored file\n")
        }))
      var request = try #require(fixture.request().objectValue)
      request["edits"] = .array([fixture.create("notes/new.md", "delivery creation\n")])
      let result = try fixture.apply(.object(request), provider: provider)
      #expect(result["state"] == .string("committed"))
      #expect(result["reason"] == .string("not_fast_forward"))
      #expect(result["branch"] == .string("docs/entry"))
      #expect(try fixture.git(["rev-parse", "HEAD"]) == baseline)
      #expect(try fixture.read("notes/new.md") == "external ignored file\n")
      #expect(try fixture.read(".gitignore") == ".claude/worktrees/\nnotes/new.md\n")
      #expect(try fixture.git(["show", "docs/entry:notes/new.md"]) == "delivery creation")
      #expect(try fixture.git(["diff", "--name-only", baseline, "docs/entry"]) == "notes/new.md")
      #expect(try fixture.git(["rev-parse", "docs/entry"]) == result["commit"]?.stringValue)
      #expect(try fixture.journals().first?.phase == .finished)
      #expect(
        try fixture.git(["worktree", "list", "--porcelain"]).components(separatedBy: "worktree ")
          .count == 2)
    }
  }

  @Test
  func abortedCleanupRequiresConsistentDefaultAndHeadSamples() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let parent = try fixture.git(["rev-parse", "HEAD"])
      try fixture.write("outside.txt", "baseline work\n")
      try fixture.git(["commit", "-am", "test: unique baseline"])
      let baseline = try fixture.git(["rev-parse", "HEAD"])
      let marker = quote(fixture.root.appendingPathComponent(".git/cleanup-head-check").path)
      let git = quote(fixture.executable)
      let provider = try fixture.provider(
        wrappingGit: """
          case " $* " in *" worktree remove "*)
            \(git) "$@" || exit $?
            touch \(marker)
            exit 0
          esac
          if test -f \(marker); then
            for argument do
              if test "$argument" = 'HEAD^{commit}'; then
                \(git) reset --hard \(quote(parent)) >/dev/null || exit $?
                rm \(marker)
              fi
            done
          fi
          """)
      let result = try fixture.apply(fixture.request(old: "absent"), provider: provider)
      #expect(result["state"] == .string("cleanup_pending"))
      #expect(result["reason"] == .string("cleanup_failed"))
      #expect(result["branch"] == .string("docs/entry"))
      #expect(try fixture.git(["rev-parse", "main"]) == parent)
      #expect(try fixture.git(["rev-parse", "docs/entry"]) == baseline)
      #expect(try fixture.git(["show", "docs/entry:outside.txt"]) == "baseline work")
      try fixture.assertClean(retained: true)
    }
  }

  @Test(arguments: [false, true])
  func abortedCleanupRetainsBaselineAfterDefaultRewind(beforeDeletion: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let parent = try fixture.git(["rev-parse", "HEAD"])
      try fixture.write("outside.txt", "baseline work\n")
      try fixture.git(["commit", "-am", "test: unique baseline"])
      let baseline = try fixture.git(["rev-parse", "HEAD"])
      let io = DeliveryIO(
        beforeCleanup: { _ in
          if !beforeDeletion { try fixture.git(["reset", "--hard", parent]) }
        },
        beforeBranchDeletion: { _, _ in
          if beforeDeletion { try fixture.git(["reset", "--hard", parent]) }
        })
      let result = try fixture.apply(
        fixture.request(old: "absent"), provider: fixture.provider(io: io))
      #expect(result["state"] == .string("cleanup_pending"))
      #expect(result["reason"] == .string("cleanup_failed"))
      #expect(result["branch"] == .string("docs/entry"))
      #expect(try fixture.git(["rev-parse", "docs/entry"]) == baseline)
      #expect(try fixture.git(["rev-parse", "main"]) == parent)
      #expect(try fixture.git(["show", "docs/entry:outside.txt"]) == "baseline work")
      try fixture.assertClean(retained: true)
      let repository = try fixture.repository()
      try repository.withLock { try repository.recover() }
      #expect(try fixture.journals().first?.state == .cleanupPending)
      #expect(try fixture.git(["rev-parse", "docs/entry"]) == baseline)
    }
  }

  @Test(arguments: [false, true])
  func defaultRewindBeforeEitherMergeDoesNotRestoreBaselineChanges(rebased: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let parent = try fixture.git(["rev-parse", "HEAD"])
      try fixture.write("outside.txt", "baseline work\n")
      try fixture.git(["commit", "-am", "test: out of scope baseline"])
      if rebased { try fixture.advanceDuringCommit() }
      let io = DeliveryIO(beforeMergeCheck: { _ in
        let count = Int((try? fixture.read(".git/merge-check-count")) ?? "0") ?? 0
        try fixture.write(".git/merge-check-count", String(count + 1))
        if count == (rebased ? 1 : 0) { try fixture.git(["reset", "--hard", parent]) }
      })
      let result = try fixture.apply(provider: fixture.provider(io: io))
      #expect(result["state"] == .string("committed"))
      #expect(result["reason"] == .string(rebased ? "not_fast_forward" : "scope_changed"))
      #expect(result["branch"] == .string("docs/entry"))
      #expect(try fixture.git(["rev-parse", "HEAD"]) == parent)
      #expect(try fixture.read("outside.txt") == "untouched\n")
      #expect(try fixture.read("notes/log.md") == "alpha\nstable\n")
      #expect(try fixture.git(["rev-parse", "docs/entry"]) == result["commit"]?.stringValue)
      #expect(try fixture.git(["show", "docs/entry:outside.txt"]) == "baseline work")
      #expect(try fixture.read(".git/merge-check-count") == (rebased ? "2" : "1"))
      try fixture.assertClean(retained: true)
    }
  }

  @Test(arguments: ["accepted_failure", "exception", "timeout"])
  func completedRebaseFailureRecordsActualTip(outcome: String) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      try fixture.advanceDuringCommit()
      let original = fixture.temporary.url.appendingPathComponent("original-commit")
      let git = quote(fixture.executable)
      let ending = outcome == "timeout" ? "sleep 5" : "exit \(outcome == "exception" ? 79 : 1)"
      let provider = try fixture.provider(
        wrappingGit: """
          for argument do
            if test "$argument" = rebase; then
              \(git) rev-parse refs/heads/docs/entry > \(quote(original.path)) || exit
              \(git) "$@" || exit $?
              \(ending)
            fi
          done
          """, timeout: outcome == "timeout" ? 1500 : nil)
      let result = try fixture.apply(provider: provider)
      let actual = try fixture.git(["rev-parse", "docs/entry"])
      let old = try String(contentsOf: original, encoding: .utf8).trimmingCharacters(in: .newlines)
      #expect(actual != old)
      #expect(result["state"] == .string("committed"), "\(result)")
      #expect(result["reason"] == .string("git_failed"))
      #expect(result["branch"] == .string("docs/entry"))
      #expect(result["commit"] == .string(actual))
      let journal = try #require(fixture.journals().first)
      #expect(journal.phase == .finished && journal.state == .committed)
      #expect(journal.commit == actual)
      #expect(try fixture.git(["diff", "--name-only", "main", actual]) == "notes/log.md")
      try fixture.assertClean(retained: true)
      let repository = try fixture.repository()
      try repository.withLock { try repository.recover() }
      #expect(try fixture.journals().first?.commit == actual)
    }
  }

  @Test
  func completedRebaseFailureRevalidatesActualPaths() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      try fixture.advanceDuringCommit()
      try fixture.interceptGit(
        "after-rebase",
        body: """
          mkdir -p private
          git mv notes/log.md private/log.md
          git -c core.hooksPath=/dev/null commit -m 'test: rewrite moves target'
          """)
      let provider = try fixture.provider(
        wrappingGit: """
          for argument do
            if test "$argument" = rebase; then
              \(quote(fixture.interceptedExecutable)) "$@" || exit $?
              exit 79
            fi
          done
          """)
      let result = try fixture.apply(provider: provider)
      #expect(result["state"] == .string("committed"))
      #expect(result["reason"] == .string("scope_changed"))
      #expect(result["branch"] == .string("docs/entry"))
      #expect(result["commit"]?.stringValue == (try fixture.git(["rev-parse", "docs/entry"])))
      #expect(try fixture.journals().first?.commit == result["commit"]?.stringValue)
      #expect(try fixture.read("notes/log.md") == "alpha\nstable\n")
      #expect(try fixture.git(["show", "docs/entry:private/log.md"]) == "beta\nstable")
      try fixture.assertClean(retained: true)
    }
  }

  @Test(arguments: [false, true], [false, true])
  func headChangeBeforeBranchDeletionRetainsBranch(detached: Bool, sameCommit: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let base = try fixture.git(["rev-parse", "HEAD"])
      let io = DeliveryIO(beforeBranchDeletion: { _, commit in
        let target = sameCommit ? commit : base
        try fixture.git(
          detached ? ["checkout", "--detach", target] : ["switch", "-c", "other", target])
      })
      let result = try fixture.apply(provider: fixture.provider(io: io))
      #expect(result["state"] == .string("cleanup_pending"))
      #expect(result["reason"] == .string("cleanup_failed"))
      #expect(result["message"]?.stringValue?.contains("Main checkout HEAD") == true)
      #expect(result["branch"] == .string("docs/entry"))
      #expect(try fixture.git(["rev-parse", "docs/entry"]) == result["commit"]?.stringValue)
      #expect(try fixture.git(["rev-parse", "main"]) == result["commit"]?.stringValue)
      #expect(try fixture.journals().first?.phase == .cleanupPending)
    }
  }

  @Test(arguments: ["tracked", "staged", "untracked", "ignored", "replaced", "created"])
  func abortedCleanupUndoesOnlyOwnedEdits(otherChange: String) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let io = DeliveryIO(beforeCleanup: { journal in
        let worktree = URL(fileURLWithPath: journal.worktree)
        let path: String
        switch otherChange {
        case "untracked": path = "other.txt"
        case "ignored": path = ".claude/worktrees/other.txt"
        case "replaced": path = "notes/log.md"
        case "created": path = "notes/new.md"
        default: path = "outside.txt"
        }
        try fixture.write(path, "external work\n", at: worktree)
        if otherChange == "staged" { try fixture.git(["add", "--", path], at: worktree) }
      })
      var request = try #require(fixture.request().objectValue)
      request["edits"] = .array([
        fixture.replace("notes/log.md", "alpha", "beta"),
        fixture.create("notes/new.md", "own creation\n"),
        fixture.replace("notes/log.md", "missing", "never"),
      ])
      let result = try fixture.apply(.object(request), provider: fixture.provider(io: io))
      #expect(result["state"] == .string("cleanup_pending"))
      #expect(result["reason"] == .string("cleanup_failed"))
      #expect(result["branch"] == .string("docs/entry"))
      let journal = try #require(fixture.journals().first)
      let worktree = URL(fileURLWithPath: journal.worktree)
      #expect(
        try fixture.read("notes/log.md", at: worktree)
          == (otherChange == "replaced" ? "external work\n" : "alpha\nstable\n"))
      if otherChange == "created" {
        #expect(try fixture.read("notes/new.md", at: worktree) == "external work\n")
      } else {
        #expect(
          !FileManager.default.fileExists(
            atPath: worktree.appendingPathComponent("notes/new.md").path))
      }
      if otherChange == "staged" {
        #expect(try fixture.git(["show", ":outside.txt"], at: worktree) == "external work")
      }
      let repository = try fixture.repository()
      try repository.withLock { try repository.recover() }
      #expect(try fixture.journals().first?.phase == .cleanupPending)
      #expect(try fixture.read("notes/log.md") == "alpha\nstable\n")
    }
  }

  @Test(arguments: [DeliveryScope.Mode.land, .commitOnly])
  func committedCleanupPreservesOtherWorktreeFiles(mode: DeliveryScope.Mode) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      var scope = fixture.scope
      scope.mode = mode
      let io = DeliveryIO(beforeCleanup: { journal in
        try fixture.write("keep.txt", "external work\n", at: URL(fileURLWithPath: journal.worktree))
      })
      let result = try fixture.apply(provider: fixture.provider(scope: scope, io: io))
      #expect(result["state"] == .string("cleanup_pending"))
      #expect(result["branch"] == .string("docs/entry"))
      let journal = try #require(fixture.journals().first)
      let worktree = URL(fileURLWithPath: journal.worktree)
      #expect(try fixture.read("keep.txt", at: worktree) == "external work\n")
      #expect(try fixture.git(["rev-parse", "docs/entry"]) == result["commit"]?.stringValue)
      try FileManager.default.removeItem(at: worktree.appendingPathComponent("keep.txt"))
      let repository = try fixture.repository(scope: scope)
      try repository.withLock { try repository.recover() }
      try fixture.assertClean(retained: mode == .commitOnly)
    }
  }
}
