import ComputerMCPCore
import Foundation
import Testing

@testable import ComputerMCPDelivery

@Suite(.nativeIntegration)
struct DeliveryWriteTests {
  @Test(arguments: [false, true])
  func changedSourceBeforeWriteIsPreserved(duringIndexRead: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let provider: DeliveryToolProvider
      if duringIndexRead {
        provider = try fixture.provider(
          wrappingGit: """
            case "$PWD" in
              */.claude/worktrees/*)
                for argument do
                  if test "$argument" = ls-files && ! test -f changed; then
                    printf 'external work\\n' > notes/log.md
                    touch changed
                  fi
                done ;;
            esac
            """)
      } else {
        provider = fixture.provider(
          io: .init(beforeJournalWrite: { journal in
            if journal.phase == .started, journal.changes != nil, journal.staged == nil {
              try fixture.write(
                "notes/log.md", "external work\n", at: URL(fileURLWithPath: journal.worktree))
            }
          }))
      }
      let result = try fixture.apply(provider: provider)
      #expect(result["state"] == .string("cleanup_pending"))
      let journal = try #require(fixture.journals().first)
      #expect(journal.commit == nil)
      #expect(try fixture.git(["rev-parse", journal.branch]) == journal.base)
      let worktree = URL(fileURLWithPath: journal.worktree)
      #expect(try fixture.read("notes/log.md", at: worktree) == "external work\n")
      let change = try #require(journal.changes?.first)
      #expect(change.original == Data("alpha\nstable\n".utf8))
      #expect(change.written == Data("beta\nstable\n".utf8))
      let repository = try fixture.repository()
      try repository.withLock { try repository.recover() }
      #expect(try fixture.read("notes/log.md", at: worktree) == "external work\n")
      #expect(try fixture.journals().first?.phase == .cleanupPending)
    }
  }

  @Test
  func newlyAppearedFileIsNotOverwritten() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let provider = fixture.provider(
        io: .init(beforeFileWrite: { change, path in
          if change.original == nil { try Data("external creation\n".utf8).write(to: path) }
        }))
      var request = try #require(fixture.request().objectValue)
      request["edits"] = .array([fixture.create("notes/new.md", "delivery creation\n")])
      let result = try fixture.apply(.object(request), provider: provider)
      #expect(result["state"] == .string("cleanup_pending"))
      let journal = try #require(fixture.journals().first)
      #expect(journal.commit == nil)
      #expect(
        try fixture.read("notes/new.md", at: URL(fileURLWithPath: journal.worktree))
          == "external creation\n")
      #expect(try fixture.git(["rev-parse", journal.branch]) == journal.base)
    }
  }

  @Test(arguments: [false, true])
  func externalIndexBlobIsNotCommitted(afterJournal: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let provider: DeliveryToolProvider
      if afterJournal {
        provider = fixture.provider(
          io: .init(beforeJournalWrite: { journal in
            if journal.phase == .started, journal.staged != nil {
              let worktree = URL(fileURLWithPath: journal.worktree)
              let blob = try fixture.git(["hash-object", "-w", "outside.txt"], at: worktree)
              try fixture.git(
                ["update-index", "--cacheinfo", "100644,\(blob),notes/log.md"], at: worktree)
            }
          }))
      } else {
        provider = try fixture.provider(
          wrappingGit: """
            for argument do
              if test "$argument" = add; then
                \(quote(fixture.executable)) "$@" || exit $?
                blob=$(\(quote(fixture.executable)) hash-object -w outside.txt) || exit $?
                \(quote(fixture.executable)) update-index --cacheinfo "100644,$blob,notes/log.md"
                exit $?
              fi
            done
            """)
      }
      let result = try fixture.apply(provider: provider)
      #expect(result["state"] == .string("cleanup_pending"))
      let journal = try #require(fixture.journals().first)
      #expect(journal.commit == nil)
      #expect(try fixture.git(["rev-parse", journal.branch]) == journal.base)
      let worktree = URL(fileURLWithPath: journal.worktree)
      #expect(try fixture.git(["show", ":notes/log.md"], at: worktree) == "untouched")
      let repository = try fixture.repository()
      try repository.withLock { try repository.recover() }
      #expect(try fixture.git(["show", ":notes/log.md"], at: worktree) == "untouched")
      #expect(try fixture.journals().first?.phase == .cleanupPending)
    }
  }

  @Test
  func changedWorktreeHeadIsNotCommitted() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let io = DeliveryIO(beforeJournalWrite: { journal in
        if journal.phase == .started, journal.staged != nil {
          let commit = try fixture.git([
            "commit-tree", "\(journal.base)^{tree}", "-p", journal.base, "-m",
            "test: external commit",
          ])
          try fixture.git(["update-ref", "refs/heads/\(journal.branch)", commit, journal.base])
          try fixture.write(".git/external-commit", commit)
        }
      })
      let result = try fixture.apply(provider: fixture.provider(io: io))
      #expect(result["state"] == .string("cleanup_pending"))
      let external = try fixture.read(".git/external-commit")
      #expect(try fixture.git(["rev-parse", "docs/entry"]) == external)
      #expect(
        try fixture.git(["log", "--format=%s", "main..docs/entry"]) == "test: external commit")
      #expect(try fixture.read("notes/log.md") == "alpha\nstable\n")
    }
  }

  @Test(arguments: ["edit", "journal", "write"], [false, true])
  func repeatedEditsRecoverAcrossFailures(failure: String, retryCleanup: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let io = DeliveryIO(
        beforeJournalWrite: { journal in
          if failure == "journal", journal.phase == .started, journal.changes != nil {
            throw CocoaError(.fileWriteNoPermission)
          }
        },
        beforeCleanup: { journal in
          let worktree = URL(fileURLWithPath: journal.worktree)
          #expect(
            try fixture.read("notes/log.md", at: worktree)
              == (failure == "write" ? "final\nstable\n" : "alpha\nstable\n"))
          if retryCleanup { throw CocoaError(.fileWriteNoPermission) }
        },
        beforeFileWrite: { change, _ in
          if change.path == "notes/second.md" { throw CocoaError(.fileWriteNoPermission) }
        })
      var request = try #require(fixture.request().objectValue)
      request["edits"] = .array([
        fixture.replace("notes/log.md", "alpha", "beta"),
        fixture.replace("notes/log.md", "beta", "final"),
        failure == "edit"
          ? fixture.replace("notes/log.md", "missing", "never")
          : fixture.create("notes/second.md", "second\n"),
      ])
      let result = try fixture.apply(.object(request), provider: fixture.provider(io: io))
      #expect(result["state"] == .string(retryCleanup ? "cleanup_pending" : "aborted"))
      let repository = try fixture.repository()
      try repository.withLock { try repository.recover() }
      #expect(try fixture.journals().first?.phase == .finished)
      #expect(try fixture.journals().first?.state == .aborted)
      #expect(try fixture.read("notes/log.md") == "alpha\nstable\n")
      try fixture.assertClean()
    }
  }

  @Test
  func repeatedEditsWriteFinalContentOnceWithDurableDigests() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let io = DeliveryIO(beforeFileWrite: { change, path in
        let journal = try #require(fixture.journals().first)
        let saved = try #require(journal.changes?.first(where: { $0.path == change.path }))
        #expect(saved.original == change.original && saved.written == change.written)
        #expect(
          saved.originalDigest == change.originalDigest && saved.finalDigest == change.finalDigest)
        let repository = try fixture.repository()
        #expect(change.finalDigest == (try repository.git.blobID(change.written, at: fixture.root)))
        if let original = change.original {
          #expect(try Data(contentsOf: path) == original)
          #expect(change.originalDigest == (try repository.git.blobID(original, at: fixture.root)))
        }
        try fixture.write(
          ".git/write-count", ((try? fixture.read(".git/write-count")) ?? "") + "\(change.path)\n")
      })
      var request = try #require(fixture.request().objectValue)
      request["edits"] = .array([
        fixture.replace("notes/log.md", "alpha", "beta"),
        fixture.replace("notes/log.md", "beta", "final"),
        fixture.create("notes/new.md", "one\n"),
        fixture.replace("notes/new.md", "one", "two"),
      ])
      #expect(
        try fixture.apply(.object(request), provider: fixture.provider(io: io))["state"]
          == .string("merged"))
      #expect(try fixture.read(".git/write-count") == "notes/log.md\nnotes/new.md\n")
      #expect(try fixture.read("notes/log.md") == "final\nstable\n")
      #expect(try fixture.read("notes/new.md") == "two\n")
      try fixture.assertClean()
    }
  }
}
