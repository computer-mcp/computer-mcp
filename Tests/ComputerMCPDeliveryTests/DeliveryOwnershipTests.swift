import Foundation
import Testing

@testable import ComputerMCPDelivery

@Suite(.nativeIntegration)
struct DeliveryOwnershipTests {
  @Test(arguments: ["index", "private-ref", "both"])
  func movedWorktreePreservesAdministrativeStateWithUnchangedHead(state: String) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      var scope = fixture.scope
      scope.mode = .commitOnly
      _ = try fixture.apply(
        provider: fixture.provider(
          scope: scope,
          io: .init(beforeCleanup: { _ in
            throw CocoaError(.fileWriteNoPermission)
          })))
      let journal = try #require(fixture.journals().first)
      let worktree = URL(fileURLWithPath: journal.worktree)
      let directory = URL(fileURLWithPath: try #require(journal.creation).worktree.directory)
      if state != "private-ref" {
        try fixture.write("outside.txt", "external staged work\n", at: worktree)
        try fixture.git(["add", "outside.txt"], at: worktree)
        try fixture.git(
          ["restore", "--worktree", "--source=HEAD", "--", "outside.txt"], at: worktree)
      }
      var unique: String?
      if state != "index" {
        unique = try fixture.git(
          [
            "commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "test: private worktree commit",
          ], at: worktree)
        try fixture.git(["update-ref", "refs/worktree/keep", try #require(unique)], at: worktree)
      }
      let names = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
      let before = Dictionary(
        uniqueKeysWithValues: names.compactMap { name -> (String, Data)? in
          guard let bytes = try? Data(contentsOf: directory.appendingPathComponent(name)) else {
            return nil
          }
          return (name, bytes)
        })
      let moved = fixture.temporary.url.appendingPathComponent("moved")
      try FileManager.default.moveItem(at: worktree, to: moved)
      let repository = try fixture.repository()
      for _ in 0..<2 {
        try repository.withLock { try repository.recover() }
        let pending = try #require(fixture.journals().first)
        #expect(pending.state == .cleanupPending && pending.reason == .worktreeRegistrationRetained)
        #expect(pending.message?.contains(directory.path) == true)
        #expect(try fixture.git(["rev-parse", journal.branch]) == journal.commit)
        for (name, bytes) in before {
          #expect(try Data(contentsOf: directory.appendingPathComponent(name)) == bytes)
        }
        #expect(
          try fixture.git(["--git-dir=\(directory.path)", "rev-parse", "HEAD"]) == journal.commit)
        if let unique {
          #expect(
            try fixture.git(["--git-dir=\(directory.path)", "rev-parse", "refs/worktree/keep"])
              == unique)
        }
        if state != "private-ref" {
          #expect(
            try fixture.git(["--git-dir=\(directory.path)", "show", ":outside.txt"])
              == "external staged work")
        }
        #expect(try fixture.read("outside.txt", at: moved) == "untouched\n")
      }
    }
  }

  @Test(arguments: [false, true])
  func branchWithoutCreationEvidenceIsRetained(uniqueCommit: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let repository = try fixture.repository()
      let operationID = UUID().uuidString.lowercased()
      let base = try fixture.git(["rev-parse", "main"])
      let journal = DeliveryJournal(
        operationID: operationID, workspace: "fixture", scope: "notes",
        repository: fixture.root.path, defaultBranch: "main", branch: "docs/entry",
        worktree: fixture.root.appendingPathComponent(".claude/worktrees/" + operationID).path,
        base: base)
      try repository.io.write(journal, to: repository.journals)
      let external =
        uniqueCommit
        ? try fixture.git([
          "commit-tree", "\(base)^{tree}", "-p", base, "-m", "test: external branch",
        ]) : base
      try fixture.git(["branch", journal.branch, external])
      for _ in 0..<2 {
        try repository.withLock { try repository.recover() }
        let pending = try #require(fixture.journals().first)
        #expect(pending.state == .cleanupPending && pending.reason == .branchUnproven)
        #expect(pending.message?.contains(journal.branch) == true)
        #expect(try fixture.git(["rev-parse", journal.branch]) == external)
        #expect(pending.creation == nil)
      }
    }
  }

  @Test(arguments: [false, true])
  func failedCreationDoesNotAuthorizeBranchCleanup(journalFailure: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let provider: DeliveryToolProvider
      if journalFailure {
        provider = fixture.provider(
          io: .init(beforeJournalWrite: { journal in
            if journal.creation != nil { throw CocoaError(.fileWriteNoPermission) }
          }))
      } else {
        provider = try fixture.provider(
          wrappingGit: """
            case " $* " in *" worktree add "*)
              \(quote(fixture.executable)) branch docs/entry main || exit $?
            esac
            """)
      }
      let result = try fixture.apply(provider: provider)
      #expect(result["state"] == .string("cleanup_pending"))
      #expect(result["reason"] == .string("branch_unproven"))
      #expect(result["branch"] == .string("docs/entry"))
      let journal = try #require(fixture.journals().first)
      #expect(journal.creation == nil)
      #expect(try fixture.git(["rev-parse", journal.branch]) == journal.base)
      let repository = try fixture.repository()
      try repository.withLock { try repository.recover() }
      #expect(try fixture.journals().first?.reason == .branchUnproven)
      #expect(try fixture.git(["rev-parse", journal.branch]) == journal.base)
      if journalFailure {
        #expect(
          try fixture.read("notes/log.md", at: URL(fileURLWithPath: journal.worktree))
            == "alpha\nstable\n")
      }
    }
  }

  @Test(arguments: [false, true], [false, true])
  func symbolicDeliveryRefCannotDeleteAnotherBranch(afterCheck: Bool, merged: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let io = DeliveryIO(beforeBranchDeletion: { branch, expected in
        try fixture.git(["branch", "other", expected])
        if !afterCheck {
          try fixture.git(["symbolic-ref", "refs/heads/\(branch)", "refs/heads/other"])
        }
      })
      let provider =
        afterCheck
        ? try fixture.provider(
          wrappingGit: """
            case " $* " in *" update-ref "*)
              \(quote(fixture.executable)) symbolic-ref refs/heads/docs/entry refs/heads/other || exit $?
            esac
            """, io: io) : fixture.provider(io: io)
      let result = try fixture.apply(
        fixture.request(old: merged ? "alpha" : "absent"), provider: provider)
      let expected = try fixture.git(["rev-parse", "main"])
      #expect(try fixture.git(["rev-parse", "other"]) == expected)
      if afterCheck {
        #expect(result["state"] == .string(merged ? "merged" : "aborted"))
        #expect(result["branch"] == nil)
        #expect(try fixture.git(["branch", "--list", "docs/entry"]).isEmpty)
      } else {
        #expect(result["state"] == .string("cleanup_pending"))
        #expect(result["reason"] == .string("cleanup_failed"))
        #expect(result["branch"] == .string("docs/entry"))
        #expect(try fixture.git(["symbolic-ref", "refs/heads/docs/entry"]) == "refs/heads/other")
      }
      let repository = try fixture.repository()
      try repository.withLock { try repository.recover() }
      #expect(
        try fixture.journals().first?.state
          == (afterCheck ? (merged ? .merged : .aborted) : .cleanupPending))
      #expect(try fixture.git(["rev-parse", "other"]) == expected)
    }
  }

  @Test(arguments: [false, true])
  func rollbackRefusesDirectoryReplacingFile(created: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let path = created ? "notes/first.md" : "notes/log.md"
      let provider = fixture.provider(
        io: .init(
          beforeFileWrite: { change, _ in
            if change.path == "notes/second.md" { throw CocoaError(.fileWriteNoPermission) }
          },
          beforeFileRollback: { target in
            #expect(target.lastPathComponent == (created ? "first.md" : "log.md"))
            try FileManager.default.moveItem(
              at: target, to: fixture.temporary.url.appendingPathComponent("delivery-file"))
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            try fixture.write("keep.txt", "external directory content\n", at: target)
          }))
      var request = try #require(fixture.request().objectValue)
      request["edits"] = .array([
        created ? fixture.create(path, "created\n") : fixture.replace(path, "alpha", "beta"),
        fixture.create("notes/second.md", "second\n"),
      ])
      let result = try fixture.apply(.object(request), provider: provider)
      #expect(result["state"] == .string("cleanup_pending"))
      let journal = try #require(fixture.journals().first)
      let directory = URL(fileURLWithPath: journal.worktree).appendingPathComponent(path)
      let repository = try fixture.repository()
      for _ in 0..<2 {
        try repository.withLock { try repository.recover() }
        #expect(try fixture.read("keep.txt", at: directory) == "external directory content\n")
        #expect(try fixture.git(["rev-parse", journal.branch]) == journal.base)
        #expect(try fixture.journals().first?.state == .cleanupPending)
      }
    }
  }

  @Test
  func replacementRollbackDoesNotTruncateHardlinkTarget() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let external = fixture.temporary.url.appendingPathComponent("external")
      try Data("beta\nstable\n".utf8).write(to: external)
      let provider = fixture.provider(
        io: .init(
          beforeFileWrite: { change, _ in
            if change.path == "notes/second.md" { throw CocoaError(.fileWriteNoPermission) }
          },
          beforeFileRollback: { target in
            try FileManager.default.removeItem(at: target)
            try FileManager.default.linkItem(at: external, to: target)
          }))
      var request = try #require(fixture.request().objectValue)
      request["edits"] = .array([
        fixture.replace("notes/log.md", "alpha", "beta"),
        fixture.create("notes/second.md", "second\n"),
      ])
      #expect(
        try fixture.apply(.object(request), provider: provider)["state"] == .string("aborted"))
      #expect(try String(contentsOf: external, encoding: .utf8) == "beta\nstable\n")
      try fixture.assertClean()
    }
  }

  @Test(arguments: [false, true])
  func cleanupPreservesPrivateRefsInExistingWorktree(merged: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let provider = fixture.provider(
        io: .init(beforeCleanup: { journal in
          let unique = try fixture.git([
            "commit-tree", "\(journal.base)^{tree}", "-p", journal.base, "-m",
            "test: private commit",
          ])
          try fixture.git(
            ["update-ref", "refs/worktree/keep", unique], at: URL(fileURLWithPath: journal.worktree)
          )
        }))
      let result = try fixture.apply(
        fixture.request(old: merged ? "alpha" : "absent"), provider: provider)
      #expect(result["state"] == .string("cleanup_pending"))
      let journal = try #require(fixture.journals().first)
      let worktree = URL(fileURLWithPath: journal.worktree)
      let unique = try fixture.git(["rev-parse", "refs/worktree/keep"], at: worktree)
      let repository = try fixture.repository()
      for _ in 0..<2 {
        try repository.withLock { try repository.recover() }
        #expect(try fixture.git(["rev-parse", "refs/worktree/keep"], at: worktree) == unique)
        #expect(try fixture.git(["rev-parse", journal.branch]) == (journal.commit ?? journal.base))
        #expect(try fixture.journals().first?.state == .cleanupPending)
      }
    }
  }

  @Test(arguments: [false, true])
  func changedWorktreeBranchIsNotStagedOrCommitted(afterStaging: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      try fixture.git(["branch", "other", "main"])
      let provider = fixture.provider(
        io: .init(beforeJournalWrite: { journal in
          guard journal.phase == .started,
            journal.changes?.allSatisfy({ $0.writeState == .written }) == true,
            (journal.staged != nil) == afterStaging
          else { return }
          try fixture.git(
            ["symbolic-ref", "HEAD", "refs/heads/other"], at: URL(fileURLWithPath: journal.worktree)
          )
        }))
      let result = try fixture.apply(provider: provider)
      #expect(result["state"] == .string("cleanup_pending"))
      #expect(result["reason"] == .string("worktree_unrecognized"))
      let journal = try #require(fixture.journals().first)
      let worktree = URL(fileURLWithPath: journal.worktree)
      #expect(try fixture.git(["rev-parse", "other"]) == journal.base)
      #expect(try fixture.git(["rev-parse", journal.branch]) == journal.base)
      #expect(
        try fixture.git(["show", ":notes/log.md"], at: worktree)
          == (afterStaging ? "beta\nstable" : "alpha\nstable"))
      #expect(try fixture.read("notes/log.md", at: worktree) == "beta\nstable\n")
    }
  }

  @Test
  func changedWorktreeBranchIsNotRebased() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      try fixture.advanceDuringCommit()
      let provider = fixture.provider(
        io: .init(beforeJournalWrite: { journal in
          guard journal.phase == .committed, journal.rebase != nil else { return }
          try fixture.git(["branch", "other", try #require(journal.commit)])
          try fixture.git(
            ["symbolic-ref", "HEAD", "refs/heads/other"], at: URL(fileURLWithPath: journal.worktree)
          )
        }))
      let result = try fixture.apply(provider: provider)
      #expect(result["state"] == .string("cleanup_pending"))
      #expect(result["reason"] == .string("worktree_unrecognized"))
      let journal = try #require(fixture.journals().first)
      #expect(try fixture.git(["rev-parse", "other"]) == journal.commit)
      #expect(try fixture.git(["rev-parse", journal.branch]) == journal.commit)
      #expect(try fixture.repository().rebaseDirectory(journal) == nil)
    }
  }

  @Test
  func changedWorktreeBranchIsNotCheckedOut() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      var scope = fixture.scope
      scope.sparse = true
      let provider = try fixture.provider(
        wrappingGit: """
          for argument do
            if test "$argument" = sparse-checkout; then
              \(quote(fixture.executable)) "$@" || exit $?
              \(quote(fixture.executable)) branch other HEAD || exit $?
              \(quote(fixture.executable)) symbolic-ref HEAD refs/heads/other
              exit $?
            fi
            if test "$argument" = checkout; then
              touch \(quote(fixture.temporary.url.appendingPathComponent("checkout-ran").path))
            fi
          done
          """, scope: scope)
      let result = try fixture.apply(provider: provider)
      #expect(result["state"] == .string("cleanup_pending"))
      #expect(result["reason"] == .string("worktree_unrecognized"))
      let journal = try #require(fixture.journals().first)
      #expect(try fixture.git(["rev-parse", "other"]) == journal.base)
      #expect(
        !FileManager.default.fileExists(
          atPath: fixture.temporary.url.appendingPathComponent("checkout-ran").path))
    }
  }

  @Test(arguments: ["ORIG_HEAD", "FETCH_HEAD", "BISECT_HEAD", "AUTO_MERGE"])
  func cleanupPreservesUnprovenPseudorefs(ref: String) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let result = try fixture.apply(
        provider: fixture.provider(
          io: .init(beforeCleanup: { journal in
            let worktree = URL(fileURLWithPath: journal.worktree)
            let unique = try fixture.git([
              "commit-tree", "\(journal.base)^{tree}", "-p", journal.base, "-m",
              "test: pseudoref commit",
            ])
            if ref == "FETCH_HEAD" {
              let directory = URL(
                fileURLWithPath: try #require(journal.creation).worktree.directory)
              try fixture.write(
                ref, "\(journal.base)\t\tbaseline\n\(unique)\t\tunique\n", at: directory)
            } else {
              try fixture.git(["update-ref", ref, unique], at: worktree)
            }
          })))
      #expect(result["state"] == .string("cleanup_pending"))
      let journal = try #require(fixture.journals().first)
      let directory = URL(fileURLWithPath: try #require(journal.creation).worktree.directory)
      let content = try Data(contentsOf: directory.appendingPathComponent(ref))
      let repository = try fixture.repository()
      for _ in 0..<2 {
        try repository.withLock { try repository.recover() }
        #expect(try fixture.journals().first?.state == .cleanupPending)
        #expect(try Data(contentsOf: directory.appendingPathComponent(ref)) == content)
        #expect(try fixture.git(["rev-parse", journal.branch]) == journal.commit)
      }
    }
  }

  @Test(arguments: ["--assume-unchanged", "--skip-worktree"], [false, true])
  func cleanupPreservesIndexFlagsAndHiddenWork(flag: String, sparse: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      var scope = fixture.scope
      scope.mode = .commitOnly
      scope.sparse = sparse
      let result = try fixture.apply(
        provider: fixture.provider(
          scope: scope,
          io: .init(beforeCleanup: { journal in
            let worktree = URL(fileURLWithPath: journal.worktree)
            try fixture.git(["update-index", flag, "outside.txt"], at: worktree)
            try fixture.write("outside.txt", "hidden external work\n", at: worktree)
            if !sparse {
              #expect(
                try fixture.git(["--no-optional-locks", "status", "--porcelain"], at: worktree)
                  .isEmpty)
            }
          })))
      #expect(result["state"] == .string("cleanup_pending"))
      let journal = try #require(fixture.journals().first)
      let worktree = URL(fileURLWithPath: journal.worktree)
      let flags = try fixture.git(["ls-files", "-v"], at: worktree)
      let repository = try fixture.repository()
      for _ in 0..<2 {
        try repository.withLock { try repository.recover() }
        #expect(try fixture.journals().first?.state == .cleanupPending)
        #expect(try fixture.read("outside.txt", at: worktree) == "hidden external work\n")
        #expect(try fixture.git(["ls-files", "-v"], at: worktree) == flags)
        #expect(try fixture.git(["rev-parse", journal.branch]) == journal.commit)
      }
    }
  }

  @Test
  func matchingExternalRebaseBeforeInvocationIsPreserved() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      try fixture.advanceDuringCommit(conflict: true)
      let result = try fixture.apply(
        provider: fixture.provider(
          io: .init(beforeJournalWrite: { journal in
            guard journal.phase == .committed, let rebase = journal.rebase else { return }
            let worktree = URL(fileURLWithPath: journal.worktree)
            try fixture.git(["rebase", rebase.onto], at: worktree, accepting: [1])
            try fixture.write("notes/log.md", "external staged resolution\n", at: worktree)
            try fixture.git(["add", "notes/log.md"], at: worktree)
          })))
      #expect(result["state"] == .string("cleanup_pending"))
      #expect(result["reason"] == .string("rebase_in_progress"))
      let journal = try #require(fixture.journals().first)
      let worktree = URL(fileURLWithPath: journal.worktree)
      let repository = try fixture.repository()
      for _ in 0..<2 {
        try repository.withLock { try repository.recover() }
        #expect(repository.rebaseDirectory(journal) != nil)
        #expect(try fixture.read("notes/log.md", at: worktree) == "external staged resolution\n")
        #expect(
          try fixture.git(["show", ":notes/log.md"], at: worktree) == "external staged resolution")
        #expect(try fixture.git(["rev-parse", journal.branch]) == journal.commit)
      }
    }
  }

  @Test
  func branchRewindBeforeRebaseKeepsSavedCommitInResult() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      try fixture.advanceDuringCommit()
      let result = try fixture.apply(
        provider: fixture.provider(
          io: .init(beforeJournalWrite: { journal in
            guard journal.phase == .committed, journal.rebase != nil else { return }
            try fixture.git(
              ["reset", "--hard", journal.base], at: URL(fileURLWithPath: journal.worktree))
          })))
      #expect(result["state"] == .string("committed"))
      let commit = try #require(result["commit"]?.stringValue)
      let journal = try #require(fixture.journals().first)
      #expect(commit != journal.base)
      #expect(try fixture.git(["show", "\(commit):notes/log.md"]) == "beta\nstable")
      #expect(try fixture.git(["rev-parse", journal.branch]) == journal.base)
    }
  }

  @Test
  func sparseCheckoutPreservesFilesAppearingAfterCreation() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      var scope = fixture.scope
      scope.sparse = true
      let result = try fixture.apply(
        provider: fixture.provider(
          scope: scope,
          io: .init(beforeJournalWrite: { journal in
            guard journal.creation != nil, journal.changes == nil, journal.phase == .started else {
              return
            }
            try fixture.write(
              "outside.txt", "external sparse content\n", at: URL(fileURLWithPath: journal.worktree)
            )
          })))
      #expect(result["state"] == .string("cleanup_pending"))
      let journal = try #require(fixture.journals().first)
      #expect(
        try fixture.read("outside.txt", at: URL(fileURLWithPath: journal.worktree))
          == "external sparse content\n")
      #expect(try fixture.git(["rev-parse", journal.branch]) == journal.base)
    }
  }

  @Test(arguments: ["index.lock", "refs/worktree/pending.lock"])
  func cleanupPreservesPendingGitLocks(lock: String) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let result = try fixture.apply(
        provider: fixture.provider(
          io: .init(beforeCleanup: { journal in
            let worktree = URL(fileURLWithPath: journal.worktree)
            let directory = URL(fileURLWithPath: try #require(journal.creation).worktree.directory)
            let index = directory.appendingPathComponent("index")
            let published = try Data(contentsOf: index)
            try fixture.write("outside.txt", "pending external staging\n", at: worktree)
            try fixture.git(["add", "outside.txt"], at: worktree)
            let pending = try Data(contentsOf: index)
            #expect(pending != published)
            try fixture.git(
              ["restore", "--worktree", "--source=HEAD", "--", "outside.txt"], at: worktree)
            try published.write(to: index)
            let target = directory.appendingPathComponent(lock)
            try FileManager.default.createDirectory(
              at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try pending.write(to: target)
            #expect(
              try fixture.git(["--no-optional-locks", "status", "--porcelain"], at: worktree)
                .isEmpty)
          })))
      #expect(result["state"] == .string("cleanup_pending"))
      let journal = try #require(fixture.journals().first)
      let directory = URL(fileURLWithPath: try #require(journal.creation).worktree.directory)
      let pending = try Data(contentsOf: directory.appendingPathComponent(lock))
      let repository = try fixture.repository()
      for _ in 0..<2 {
        try repository.withLock { try repository.recover() }
        #expect(try fixture.journals().first?.state == .cleanupPending)
        #expect(try Data(contentsOf: directory.appendingPathComponent(lock)) == pending)
        #expect(try fixture.git(["rev-parse", journal.branch]) == journal.commit)
      }
    }
  }

  @Test(arguments: ["MERGE_HEAD", "CHERRY_PICK_HEAD"])
  func abortedRollbackPreservesOtherGitOperation(ref: String) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let result = try fixture.apply(
        provider: fixture.provider(
          io: .init(beforeJournalWrite: { journal in
            guard journal.phase == .started, journal.staged != nil else { return }
            let unique = try fixture.git([
              "commit-tree", "\(journal.base)^{tree}", "-p", journal.base, "-m",
              "test: external operation",
            ])
            let directory = URL(fileURLWithPath: try #require(journal.creation).worktree.directory)
            try fixture.write(ref, unique + "\n", at: directory)
            throw CocoaError(.fileWriteNoPermission)
          })))
      #expect(result["state"] == .string("cleanup_pending"))
      let journal = try #require(fixture.journals().first)
      let worktree = URL(fileURLWithPath: journal.worktree)
      let directory = URL(fileURLWithPath: try #require(journal.creation).worktree.directory)
      let index = try Data(contentsOf: directory.appendingPathComponent("index"))
      let unique = try fixture.git(["rev-parse", ref], at: worktree)
      let repository = try fixture.repository()
      for _ in 0..<2 {
        try repository.withLock { try repository.recover() }
        #expect(try fixture.journals().first?.state == .cleanupPending)
        #expect(try fixture.read("notes/log.md", at: worktree) == "beta\nstable\n")
        #expect(try fixture.git(["show", ":notes/log.md"], at: worktree) == "beta\nstable")
        #expect(try Data(contentsOf: directory.appendingPathComponent("index")) == index)
        #expect(try fixture.git(["rev-parse", ref], at: worktree) == unique)
      }
    }
  }

  @Test(arguments: [false, true])
  func journalReplacementRequiresMatchingOperation(replaced: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let provider = fixture.provider(
        io: .init(beforeJournalWrite: { journal in
          guard journal.phase == .started, (journal.creation != nil) == replaced else { return }
          try fixture.write(
            ".git/computer-mcp/delivery/\(journal.operationID).json", "external journal content\n")
        }))
      let result = try fixture.apply(provider: provider)
      #expect(result["state"] == .string(replaced ? "cleanup_pending" : "aborted"))
      let directory = fixture.root.appendingPathComponent(".git/computer-mcp/delivery")
      let journal = try #require(
        FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
          .first { $0.pathExtension == "json" })
      #expect(try String(contentsOf: journal, encoding: .utf8) == "external journal content\n")
      if replaced {
        #expect(result["reason"] == .string("branch_unproven"))
        #expect(
          try fixture.git(["rev-parse", "docs/entry"]) == fixture.git(["rev-parse", "main"]))
      } else {
        #expect(result["reason"] == .string("journal_failed"))
        try fixture.assertClean()
      }
    }
  }

  @Test
  func recoveryPreservesSavedCommitAfterDeliveryBranchRewrite() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      var scope = fixture.scope
      scope.mode = .commitOnly
      _ = try fixture.apply(
        provider: fixture.provider(
          scope: scope,
          io: .init(beforeCleanup: { _ in
            throw CocoaError(.fileWriteNoPermission)
          })))
      let journal = try #require(fixture.journals().first)
      let saved = try #require(journal.commit)
      let worktree = URL(fileURLWithPath: journal.worktree)
      try fixture.write("outside.txt", "new default work\n")
      try fixture.git(["commit", "-am", "test: advance default"])
      let current = try fixture.git(["rev-parse", "main"])
      try fixture.git(["update-ref", "refs/heads/\(journal.branch)", current, saved])
      try fixture.git(["read-tree", "--reset", "-u", current], at: worktree)
      #expect(try fixture.git(["status", "--porcelain"], at: worktree).isEmpty)
      let reflog = try fixture.git(["reflog", "show", "--format=%H", journal.branch])
      #expect(reflog.contains(saved))
      let repository = try fixture.repository()
      for _ in 0..<2 {
        try repository.withLock { try repository.recover() }
        let pending = try #require(fixture.journals().first)
        #expect(pending.state == .cleanupPending && pending.commit == saved)
        #expect(pending.message?.contains(saved) == true)
        #expect(pending.message?.contains(current) == true)
        #expect(try fixture.git(["rev-parse", journal.branch]) == current)
        #expect(try fixture.git(["reflog", "show", "--format=%H", journal.branch]) == reflog)
        #expect(FileManager.default.fileExists(atPath: worktree.path))
      }
      try fixture.git(["update-ref", "refs/heads/\(journal.branch)", saved, current])
      try fixture.git(["read-tree", "--reset", "-u", saved], at: worktree)
      try repository.withLock { try repository.recover() }
      #expect(try fixture.journals().first?.state == .committed)
      #expect(try fixture.git(["rev-parse", journal.branch]) == saved)
      try fixture.assertClean(retained: true)
    }
  }
}
