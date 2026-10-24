import ComputerMCPCore
import Foundation
import Testing

@testable import ComputerMCPDelivery

@Suite(.nativeIntegration)
struct DeliveryGitConfigurationTests {
  @Test(arguments: ["main", "worktree", "retry", "landed"])
  func symbolicOrigHeadPreservesTargetBranch(checkout: String) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let other = try fixture.git([
        "commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "test: unique external commit",
      ])
      try fixture.git(["branch", "other", other])
      let reflog = try fixture.read(".git/logs/refs/heads/other")
      if ["worktree", "retry"].contains(checkout) { try fixture.advanceDuringCommit() }
      let snapshot = fixture.root.appendingPathComponent(".git/before-orig-head-check")
      let io = DeliveryIO(beforeMergeCheck: { journal in
        guard !FileManager.default.fileExists(atPath: snapshot.path),
          checkout != "retry" || journal.rebase != nil
        else { return }
        if checkout == "landed" { try fixture.git(["merge", "--ff-only", journal.commit!]) }
        let directory =
          checkout == "worktree" ? URL(fileURLWithPath: journal.worktree) : fixture.root
        try fixture.git(["symbolic-ref", "ORIG_HEAD", "refs/heads/other"], at: directory)
        try fixture.write(".git/before-orig-head-check", try fixture.git(["rev-parse", "HEAD"]))
      })
      let result = try fixture.apply(provider: fixture.provider(io: io))
      #expect(result["state"] == .string("committed"))
      #expect(result["reason"] == .string("orig_head_symbolic"))
      #expect(result["branch"] == .string("docs/entry"))
      let commit = try #require(result["commit"]?.stringValue)
      let journal = try #require(fixture.journals().first)
      #expect((journal.rebase != nil) == ["worktree", "retry"].contains(checkout))
      #expect(journal.merged == (checkout == "landed"))
      if checkout == "worktree" { #expect(commit == journal.rebase?.original) }
      let repository = try fixture.repository()
      for _ in 0..<2 {
        #expect(try fixture.git(["rev-parse", "other"]) == other)
        #expect(try fixture.read(".git/logs/refs/heads/other") == reflog)
        #expect(try fixture.git(["rev-parse", "docs/entry"]) == commit)
        #expect(
          try fixture.git(["rev-parse", "HEAD"]) == fixture.read(".git/before-orig-head-check"))
        #expect(
          try fixture.read("notes/log.md")
            == (checkout == "landed" ? "beta\nstable\n" : "alpha\nstable\n"))
        if checkout != "worktree" {
          #expect(try fixture.git(["symbolic-ref", "ORIG_HEAD"]) == "refs/heads/other")
        }
        try fixture.assertClean(retained: true)
        try repository.withLock { try repository.recover() }
        #expect(try fixture.journals().first?.reason?.rawValue == "orig_head_symbolic")
      }
    }
  }

  @Test(arguments: ["advanced", "symbolic", "symbolic-advanced"])
  func rebaseAbortPreservesChangedDeliveryBranch(state: String) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      try fixture.advanceDuringCommit(conflict: true)
      let snapshot = fixture.root.appendingPathComponent(".git/external-index")
      let io = DeliveryIO(afterWorktreeVerification: { journal in
        guard let rebase = journal.rebase,
          !FileManager.default.fileExists(atPath: snapshot.path),
          let identity = journal.creation?.worktree
        else { return }
        let repository = try fixture.repository()
        guard repository.rebaseDirectory(journal) != nil else { return }
        let worktree = URL(fileURLWithPath: journal.worktree)
        let commit =
          state == "symbolic"
          ? rebase.original
          : try fixture.git([
            "commit-tree", "\(rebase.original)^{tree}", "-p", rebase.original,
            "-m", "test: external delivery branch commit",
          ])
        if state == "advanced" {
          try fixture.git(["update-ref", "refs/heads/\(journal.branch)", commit])
        } else {
          try fixture.git(["branch", "other", commit])
          try fixture.git(["symbolic-ref", "refs/heads/\(journal.branch)", "refs/heads/other"])
          try fixture.write(
            ".git/external-other-reflog", try fixture.read(".git/logs/refs/heads/other"))
        }
        try fixture.write(".git/external-tip", commit)
        try fixture.write(".git/external-notes", try fixture.read("notes/log.md", at: worktree))
        try Data(
          contentsOf: URL(fileURLWithPath: identity.directory).appendingPathComponent("index")
        )
        .write(to: snapshot)
      })
      let result = try fixture.apply(provider: fixture.provider(io: io))
      #expect(result["state"] == .string("cleanup_pending"))
      #expect(result["reason"] == .string("rebase_in_progress"))
      #expect(result["branch"] == .string("docs/entry"))
      let journal = try #require(fixture.journals().first)
      #expect(result["commit"]?.stringValue == journal.rebase?.original)
      let directory = URL(fileURLWithPath: try #require(journal.creation?.worktree.directory))
      let worktree = URL(fileURLWithPath: journal.worktree)
      let repository = try fixture.repository()
      for _ in 0..<2 {
        #expect(
          try fixture.git(["rev-parse", journal.branch]) == fixture.read(".git/external-tip"))
        #expect(
          try fixture.git(
            ["symbolic-ref", "--quiet", "refs/heads/\(journal.branch)"], accepting: [0, 1])
            == (state == "advanced" ? "" : "refs/heads/other"))
        if state != "advanced" {
          #expect(try fixture.git(["rev-parse", "other"]) == fixture.read(".git/external-tip"))
          #expect(
            try fixture.read(".git/logs/refs/heads/other")
              == fixture.read(".git/external-other-reflog"))
        }
        #expect(try fixture.git(["rev-parse", "HEAD"], at: worktree) == journal.rebase?.onto)
        #expect(
          try fixture.read("notes/log.md", at: worktree) == fixture.read(".git/external-notes"))
        #expect(try fixture.read("outside.txt", at: worktree) == "untouched\n")
        #expect(
          try Data(contentsOf: directory.appendingPathComponent("index"))
            == Data(contentsOf: snapshot))
        #expect(repository.rebaseDirectory(journal) != nil)
        try repository.withLock { try repository.recover() }
        #expect(try fixture.journals().first?.reason == .rebaseInProgress)
      }
    }
  }

  @Test(arguments: [false, true])
  func configuredRebasePreservesPrivateRefs(conflict: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      try fixture.git(["config", "rebase.rebaseMerges", "true"])
      try fixture.advanceDuringCommit(conflict: conflict)
      let io = DeliveryIO(beforeMergeCheck: { journal in
        guard journal.rebase == nil else { return }
        let worktree = URL(fileURLWithPath: journal.worktree)
        for name in ["onto", "external"] {
          let commit = try fixture.git(
            [
              "commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "test: private \(name) commit",
            ], at: worktree)
          try fixture.git(["update-ref", "refs/rewritten/\(name)", commit], at: worktree)
        }
        try fixture.write(
          ".git/external-private-refs",
          try fixture.git(
            ["for-each-ref", "--format=%(refname) %(objectname)", "refs/rewritten/"], at: worktree))
      })
      let result = try fixture.apply(provider: fixture.provider(io: io))
      #expect(result["state"] == .string("cleanup_pending"))
      #expect(result["reason"] == .string("cleanup_failed"))
      #expect(result["branch"] == .string("docs/entry"))
      let journal = try #require(fixture.journals().first)
      let worktree = URL(fileURLWithPath: journal.worktree)
      let repository = try fixture.repository()
      #expect(journal.merged == !conflict)
      #expect(try fixture.read("notes/log.md") == (conflict ? "gamma\nstable\n" : "beta\nstable\n"))
      for _ in 0..<2 {
        #expect(
          try fixture.git(
            ["for-each-ref", "--format=%(refname) %(objectname)", "refs/rewritten/"], at: worktree)
            == fixture.read(".git/external-private-refs"))
        #expect(try fixture.git(["rev-parse", journal.branch]) == result["commit"]?.stringValue)
        #expect(repository.rebaseDirectory(journal) == nil)
        #expect(try fixture.git(["worktree", "list", "--porcelain"]).contains(journal.worktree))
        try repository.withLock { try repository.recover() }
        #expect(try fixture.journals().first?.reason == .cleanupFailed)
      }
    }
  }

  @Test(arguments: [
    "worktree", "index", "conflict", "resolved", "partial-resolution", "unmerged-index",
    "detached-commit", "missing-snapshot",
  ])
  func rebaseAbortPreservesExternalTrackedChanges(state: String) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      if state == "partial-resolution" {
        try fixture.write("notes/second.md", "alpha\nstable\n")
        try fixture.git(["add", "--", "notes/second.md"])
        try fixture.git(["commit", "-m", "test: second conflict path"])
      }
      let snapshot = fixture.root.appendingPathComponent(".git/external-index")
      let io = DeliveryIO(
        beforeMergeCheck: { _ in
          try fixture.write("notes/log.md", "gamma\nstable\n")
          if state == "partial-resolution" {
            try fixture.write("notes/second.md", "gamma\nstable\n")
          }
          try fixture.git(["commit", "-am", "test: advance with conflict"])
        },
        afterWorktreeVerification: { journal in
          guard journal.rebase != nil, !FileManager.default.fileExists(atPath: snapshot.path),
            let identity = journal.creation?.worktree
          else { return }
          let directory = URL(fileURLWithPath: identity.directory)
          guard
            ["rebase-merge", "rebase-apply"].contains(where: {
              FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
            })
          else { return }
          let worktree = URL(fileURLWithPath: journal.worktree)
          switch state {
          case "worktree", "index":
            try fixture.write("outside.txt", "external tracked work\n", at: worktree)
            if state == "index" {
              try fixture.git(["add", "--", "outside.txt"], at: worktree)
              try fixture.write("outside.txt", "untouched\n", at: worktree)
            }
          case "conflict", "resolved":
            try fixture.write("notes/log.md", "external conflict resolution\n", at: worktree)
            if state == "resolved" { try fixture.git(["add", "--", "notes/log.md"], at: worktree) }
          case "partial-resolution":
            try fixture.git(["add", "--", "notes/log.md"], at: worktree)
          case "unmerged-index":
            let blob = try fixture.git(["rev-parse", "HEAD:outside.txt"], at: worktree)
            let repository = try fixture.repository()
            let verified = try repository.verifiedWorktree(journal)
            let pinned = try #require(verified)
            try pinned.run(
              ["update-index", "--index-info"], at: worktree,
              input: Data("100644 \(blob) 3\tnotes/log.md\n".utf8))
            try fixture.git(["update-index", "--clear-resolve-undo"], at: worktree)
          case "detached-commit":
            let commit = try fixture.git(
              ["commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "test: external detached commit"],
              at: worktree)
            try fixture.git(["update-ref", "--no-deref", "HEAD", commit], at: worktree)
          default:
            try FileManager.default.removeItem(at: directory.appendingPathComponent("AUTO_MERGE"))
          }
          try Data(contentsOf: directory.appendingPathComponent("index")).write(to: snapshot)
          try fixture.write(".git/external-outside", try fixture.read("outside.txt", at: worktree))
          try fixture.write(".git/external-notes", try fixture.read("notes/log.md", at: worktree))
          try fixture.write(
            ".git/external-head", try fixture.git(["rev-parse", "HEAD"], at: worktree))
        })
      var request = try #require(fixture.request().objectValue)
      if state == "partial-resolution" {
        request["edits"] = .array([
          fixture.replace("notes/log.md", "alpha", "beta"),
          fixture.replace("notes/second.md", "alpha", "beta"),
        ])
      }
      let result = try fixture.apply(.object(request), provider: fixture.provider(io: io))
      #expect(result["state"] == .string("cleanup_pending"))
      #expect(result["reason"] == .string("rebase_in_progress"))
      let journal = try #require(fixture.journals().first)
      let directory = URL(fileURLWithPath: try #require(journal.creation?.worktree.directory))
      let worktree = URL(fileURLWithPath: journal.worktree)
      let repository = try fixture.repository()
      for _ in 0..<2 {
        #expect(
          try fixture.read("outside.txt", at: worktree) == fixture.read(".git/external-outside"))
        #expect(
          try fixture.read("notes/log.md", at: worktree) == fixture.read(".git/external-notes"))
        #expect(
          try Data(contentsOf: directory.appendingPathComponent("index"))
            == Data(contentsOf: snapshot))
        #expect(repository.rebaseDirectory(journal) != nil)
        #expect(try fixture.git(["rev-parse", journal.branch]) == journal.rebase?.original)
        #expect(
          try fixture.git(["rev-parse", "HEAD"], at: worktree) == fixture.read(".git/external-head")
        )
        try repository.withLock { try repository.recover() }
        #expect(try fixture.journals().first?.reason == .rebaseInProgress)
      }
    }
  }

  @Test(arguments: ["untracked", "ignored", "--assume-unchanged", "--skip-worktree"])
  func rebasePreservesExternalWorkBeforeCheckout(state: String) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      if state == "ignored" {
        try fixture.write(".gitignore", ".claude/worktrees/\n/future.txt\n")
        try fixture.git(["commit", "-am", "test: ignored path"])
      }
      let path = state.hasPrefix("--") ? "outside.txt" : "future.txt"
      let snapshot = fixture.root.appendingPathComponent(".git/external-index")
      let io = DeliveryIO(
        beforeJournalWrite: { journal in
          guard journal.rebase != nil, !FileManager.default.fileExists(atPath: snapshot.path) else {
            return
          }
          let worktree = URL(fileURLWithPath: journal.worktree)
          try fixture.write(path, "external worktree work\n", at: worktree)
          if state.hasPrefix("--") {
            try fixture.git(["update-index", state, "--", path], at: worktree)
          }
          let directory = URL(fileURLWithPath: try #require(journal.creation?.worktree.directory))
          try Data(contentsOf: directory.appendingPathComponent("index")).write(to: snapshot)
        },
        beforeMergeCheck: { _ in
          try fixture.write(path, "upstream work\n")
          try fixture.git(["add", "-f", "--", path])
          try fixture.git(["commit", "-m", "test: advance default"])
        })
      let result = try fixture.apply(provider: fixture.provider(io: io))
      #expect(result["state"] == .string("cleanup_pending"))
      let journal = try #require(fixture.journals().first)
      let original = try #require(journal.rebase?.original, "Delivery result: \(result)")
      let directory = URL(fileURLWithPath: try #require(journal.creation?.worktree.directory))
      let worktree = URL(fileURLWithPath: journal.worktree)
      let repository = try fixture.repository()
      for _ in 0..<2 {
        #expect(try fixture.git(["rev-parse", journal.branch]) == original)
        #expect(try fixture.read(path, at: worktree) == "external worktree work\n")
        #expect(
          try Data(contentsOf: directory.appendingPathComponent("index"))
            == Data(contentsOf: snapshot))
        #expect(repository.rebaseDirectory(journal) == nil)
        try repository.withLock { try repository.recover() }
        #expect(try fixture.journals().first?.state == .cleanupPending)
      }
      #expect(try fixture.read(path) == "upstream work\n")
    }
  }

  @Test(arguments: [false, true])
  func rebaseAbortPreservesNewUntrackedFiles(ignored: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      if ignored {
        try fixture.write(".gitignore", ".claude/worktrees/\n/outside.txt\n")
        try fixture.git(["commit", "-am", "test: ignored tracked path"])
      }
      let snapshot = fixture.root.appendingPathComponent(".git/external-index")
      let io = DeliveryIO(
        beforeMergeCheck: { _ in
          try fixture.git(["rm", "--", "outside.txt"])
          try fixture.write("notes/log.md", "gamma\nstable\n")
          try fixture.git(["commit", "-am", "test: advance with conflict"])
        },
        afterWorktreeVerification: { journal in
          guard journal.rebase != nil, !FileManager.default.fileExists(atPath: snapshot.path),
            let identity = journal.creation?.worktree
          else { return }
          let directory = URL(fileURLWithPath: identity.directory)
          guard
            ["rebase-merge", "rebase-apply"].contains(where: {
              FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
            })
          else { return }
          try fixture.write(
            "outside.txt", "external abort work\n", at: URL(fileURLWithPath: journal.worktree))
          try Data(contentsOf: directory.appendingPathComponent("index")).write(to: snapshot)
        })
      let result = try fixture.apply(provider: fixture.provider(io: io))
      #expect(result["state"] == .string("cleanup_pending"))
      #expect(result["reason"] == .string("rebase_in_progress"))
      let journal = try #require(fixture.journals().first)
      let directory = URL(fileURLWithPath: try #require(journal.creation?.worktree.directory))
      let worktree = URL(fileURLWithPath: journal.worktree)
      let repository = try fixture.repository()
      for _ in 0..<2 {
        #expect(try fixture.read("outside.txt", at: worktree) == "external abort work\n")
        #expect(
          try Data(contentsOf: directory.appendingPathComponent("index"))
            == Data(contentsOf: snapshot))
        #expect(repository.rebaseDirectory(journal) != nil)
        #expect(try fixture.git(["rev-parse", journal.branch]) == journal.rebase?.original)
        try repository.withLock { try repository.recover() }
        #expect(try fixture.journals().first?.reason == .rebaseInProgress)
      }
    }
  }

  @Test
  func configuredRebaseAbortPreservesOtherBranches() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      try fixture.git(["config", "rebase.updateRefs", "true"])
      try fixture.git(["config", "rebase.autoStash", "true"])
      try fixture.advanceDuringCommit(conflict: true)
      let io = DeliveryIO(beforeMergeCheck: { journal in
        try fixture.git(["branch", "other", journal.commit!])
      })
      let result = try fixture.apply(provider: fixture.provider(io: io))
      #expect(result["state"] == .string("committed"))
      #expect(result["reason"] == .string("rebase_conflict"))
      #expect(try fixture.git(["rev-parse", "other"]) == result["commit"]?.stringValue)
      #expect(try fixture.git(["rev-parse", "docs/entry"]) == result["commit"]?.stringValue)
      #expect(try fixture.read("notes/log.md") == "gamma\nstable\n")
      try fixture.assertClean(retained: true)
    }
  }

  @Test
  func configuredRebasePreservesOtherBranches() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      try fixture.git(["config", "rebase.updateRefs", "true"])
      try fixture.advanceDuringCommit()
      let io = DeliveryIO(beforeMergeCheck: { journal in
        guard journal.rebase == nil else { return }
        try fixture.git(["branch", "other", journal.commit!])
        try fixture.write(
          ".git/other-reflog", try fixture.read(".git/logs/refs/heads/other"))
      })
      let result = try fixture.apply(provider: fixture.provider(io: io))
      let journal = try #require(fixture.journals().first)
      let original = try #require(journal.rebase?.original, "Delivery result: \(result)")
      #expect(result["state"] == .string("merged"))
      #expect(result["commit"]?.stringValue != original)
      #expect(try fixture.git(["rev-parse", "other"]) == original)
      #expect(try fixture.git(["show", "other:notes/log.md"]) == "beta\nstable")
      #expect(try fixture.read(".git/logs/refs/heads/other") == fixture.read(".git/other-reflog"))
      try fixture.assertClean()
    }
  }

  @Test
  func configuredRebasePreservesNotes() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      try fixture.git(["config", "notes.rewrite.rebase", "true"])
      try fixture.git(["config", "notes.rewriteRef", "refs/notes/review"])
      try fixture.git(["config", "notes.rewriteMode", "overwrite"])
      try fixture.advanceDuringCommit()
      let io = DeliveryIO(beforeMergeCheck: { journal in
        guard journal.rebase == nil else { return }
        try fixture.git([
          "notes", "--ref=review", "add", "-m", "external annotation", journal.commit!,
        ])
        try fixture.write(".git/notes-tip", try fixture.git(["rev-parse", "refs/notes/review"]))
      })
      let result = try fixture.apply(provider: fixture.provider(io: io))
      let journal = try #require(fixture.journals().first)
      #expect(result["state"] == .string("merged"))
      #expect(
        try fixture.git(["rev-parse", "refs/notes/review"]) == fixture.read(".git/notes-tip"))
      #expect(
        try fixture.git(["notes", "--ref=review", "show", try #require(journal.rebase?.original)])
          == "external annotation")
      #expect(
        try fixture.git(
          ["notes", "--ref=review", "show", try #require(journal.commit)], accepting: [1]
        ).isEmpty)
    }
  }

  @Test
  func configuredRebasePreservesSharedConflictResolutions() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      try fixture.git(["config", "rerere.enabled", "true"])
      try fixture.git(["config", "rerere.autoupdate", "true"])
      try fixture.advanceDuringCommit(conflict: true)
      let other = fixture.temporary.url.appendingPathComponent("other-worktree")
      let cache = fixture.root.appendingPathComponent(".git/rr-cache")
      let snapshot = fixture.temporary.url.appendingPathComponent("conflict-cache")
      let io = DeliveryIO(beforeMergeCheck: { journal in
        try fixture.git(["worktree", "add", "-b", "other", other.path, journal.commit!])
        try fixture.git(["rebase", "main"], at: other, accepting: [1])
        let conflicts = try FileManager.default.contentsOfDirectory(
          at: cache, includingPropertiesForKeys: nil)
        let conflict = try #require(conflicts.first)
        try fixture.write("notes/log.md", "external resolved content\n", at: other)
        try fixture.git(["add", "--", "notes/log.md"], at: other)
        try fixture.git(["rerere"], at: other)
        #expect(
          FileManager.default.fileExists(atPath: conflict.appendingPathComponent("postimage").path))
        try Data("external conflict image\n".utf8).write(
          to: conflict.appendingPathComponent("thisimage"))
        try Data("external resolution work\n".utf8).write(
          to: conflict.appendingPathComponent("external-resolution"))
        try FileManager.default.copyItem(at: cache, to: snapshot)
        try fixture.write(".git/other-conflict", try fixture.read("notes/log.md", at: other))
      })
      let result = try fixture.apply(provider: fixture.provider(io: io))
      #expect(result["state"] == .string("committed"))
      #expect(result["reason"] == .string("rebase_conflict"))
      let entries = try FileManager.default.subpathsOfDirectory(atPath: snapshot.path)
      #expect(try Set(FileManager.default.subpathsOfDirectory(atPath: cache.path)) == Set(entries))
      for entry in entries {
        let saved = snapshot.appendingPathComponent(entry)
        if try saved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
          #expect(
            try Data(contentsOf: cache.appendingPathComponent(entry)) == Data(contentsOf: saved))
        }
      }
      #expect(try fixture.read("notes/log.md", at: other) == fixture.read(".git/other-conflict"))
      #expect(try fixture.git(["rev-parse", "other"]) == result["commit"]?.stringValue)
      try fixture.git(["-c", "rerere.enabled=false", "rebase", "--abort"], at: other)
    }
  }

  @Test(arguments: [false, true], [false, true])
  func mergeAutostashPreservesMainChanges(target: Bool, staged: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      try fixture.git(["config", "merge.autoStash", "true"])
      try fixture.git(["config", "branch.main.mergeOptions", "--autostash"])
      let path = target ? "notes/log.md" : "outside.txt"
      try fixture.hook(
        "post-merge", body: "cat \(quote(path)) > .git/merge-hook-content")
      let io = DeliveryIO(beforeMergeCheck: { _ in
        try fixture.write(path, "external main work\n")
        if staged { try fixture.git(["add", "--", path]) }
        try Data(contentsOf: fixture.root.appendingPathComponent(".git/index"))
          .write(to: fixture.root.appendingPathComponent(".git/main-index-before-merge"))
      })
      let result = try fixture.apply(provider: fixture.provider(io: io))
      #expect(result["state"] == .string(target ? "committed" : "merged"), "\(result)")
      #expect(try fixture.read(path) == "external main work\n")
      #expect(
        try fixture.git(["diff", "--cached", "--name-only"]) == (staged ? path : ""))
      #expect(
        try fixture.git(["show-ref", "--verify", "--quiet", "refs/stash"], accepting: [1]).isEmpty)
      #expect(
        !FileManager.default.fileExists(
          atPath: fixture.root.appendingPathComponent(".git/MERGE_AUTOSTASH").path))
      if target {
        #expect(result["branch"] == .string("docs/entry"))
        #expect(
          try Data(contentsOf: fixture.root.appendingPathComponent(".git/index"))
            == Data(contentsOf: fixture.root.appendingPathComponent(".git/main-index-before-merge"))
        )
      } else {
        #expect(try fixture.read(".git/merge-hook-content") == "external main work\n")
      }
    }
  }

  @Test(arguments: [false, true])
  func pendingMergeAutostashIsNotApplied(conflict: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let base = try fixture.git(["rev-parse", "HEAD"])
      let content = conflict ? "external current work\n" : "untouched\n"
      let io = DeliveryIO(beforeMergeCheck: { _ in
        try fixture.write("outside.txt", "external stashed work\n")
        let stash = try fixture.git(["stash", "create"])
        #expect(!stash.isEmpty)
        try fixture.git(["restore", "--", "outside.txt"])
        if conflict { try fixture.write("outside.txt", content) }
        try fixture.write(".git/MERGE_AUTOSTASH", stash + "\n")
        try Data(contentsOf: fixture.root.appendingPathComponent(".git/index"))
          .write(to: fixture.root.appendingPathComponent(".git/main-index-before-merge"))
      })
      let result = try fixture.apply(provider: fixture.provider(io: io))
      #expect(result["state"] == .string("committed"))
      #expect(result["reason"] == .string("git_failed"))
      #expect(result["branch"] == .string("docs/entry"))
      #expect(try fixture.git(["rev-parse", "HEAD"]) == base)
      #expect(try fixture.read("outside.txt") == content)
      #expect(
        try Data(contentsOf: fixture.root.appendingPathComponent(".git/index"))
          == Data(contentsOf: fixture.root.appendingPathComponent(".git/main-index-before-merge")))
      #expect(
        !FileManager.default.fileExists(
          atPath: fixture.root.appendingPathComponent(".git/refs/stash").path))
      #expect(
        !FileManager.default.fileExists(
          atPath: fixture.root.appendingPathComponent(".git/logs/refs/stash").path))
      #expect(try fixture.git(["show", "MERGE_AUTOSTASH:outside.txt"]) == "external stashed work")
      #expect(try fixture.git(["rev-parse", "docs/entry"]) == result["commit"]?.stringValue)
    }
  }

  @Test(arguments: [false, true])
  func rebaseAutostashPreservesUserChanges(staged: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      try fixture.git(["config", "rebase.autoStash", "true"])
      try fixture.advanceDuringCommit()
      let snapshot = fixture.root.appendingPathComponent(".git/user-rebase-index")
      let io = DeliveryIO(beforeJournalWrite: { journal in
        guard journal.rebase != nil, !FileManager.default.fileExists(atPath: snapshot.path) else {
          return
        }
        let worktree = URL(fileURLWithPath: journal.worktree)
        try fixture.write("outside.txt", "external rebase work\n", at: worktree)
        if staged { try fixture.git(["add", "--", "outside.txt"], at: worktree) }
        let directory = try #require(journal.creation?.worktree.directory)
        try Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent("index"))
          .write(to: snapshot)
      })
      let result = try fixture.apply(provider: fixture.provider(io: io))
      #expect(result["state"] == .string("cleanup_pending"))
      #expect(result["branch"] == .string("docs/entry"))
      let journal = try #require(fixture.journals().first)
      let original = try #require(journal.rebase?.original, "Delivery result: \(result)")
      let worktree = URL(fileURLWithPath: journal.worktree)
      let directory = URL(fileURLWithPath: try #require(journal.creation?.worktree.directory))
      let repository = try fixture.repository()
      for _ in 0..<2 {
        #expect(try fixture.git(["rev-parse", journal.branch]) == original)
        #expect(try fixture.read("outside.txt", at: worktree) == "external rebase work\n")
        #expect(
          try Data(contentsOf: directory.appendingPathComponent("index"))
            == Data(contentsOf: snapshot))
        #expect(repository.rebaseDirectory(journal) == nil)
        #expect(
          try fixture.git(["show-ref", "--verify", "--quiet", "refs/stash"], accepting: [1]).isEmpty
        )
        try repository.withLock { try repository.recover() }
        #expect(try fixture.journals().first?.state == .cleanupPending)
      }
    }
  }

  @Test
  func automaticMaintenancePreservesMissingWorktree() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let missing = fixture.temporary.url.appendingPathComponent("missing-worktree")
      try fixture.git(["worktree", "add", "-b", "other", missing.path])
      let marker = try fixture.read(".git", at: missing).trimmingCharacters(in: .newlines)
      let directory = URL(fileURLWithPath: String(marker.dropFirst(8)))
      let privateCommit = try fixture.git(
        [
          "commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "test: private worktree commit",
        ], at: missing)
      try fixture.git(["update-ref", "refs/worktree/keep", privateCommit], at: missing)
      let index = try Data(contentsOf: directory.appendingPathComponent("index"))
      try FileManager.default.moveItem(
        at: missing, to: fixture.temporary.url.appendingPathComponent("moved-worktree"))
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 1)],
        ofItemAtPath: directory.appendingPathComponent("gitdir").path)
      try fixture.git(["repack", "-d"])
      try fixture.write("outside.txt", "second pack\n")
      try fixture.git(["commit", "-am", "test: another pack"])
      try fixture.git(["repack", "-d"])
      let packs = try FileManager.default.contentsOfDirectory(
        atPath: fixture.root.appendingPathComponent(".git/objects/pack").path
      ).filter { $0.hasSuffix(".pack") }
      #expect(packs.count > 1)
      try fixture.git(["config", "gc.auto", "1"])
      try fixture.git(["config", "gc.autoPackLimit", "1"])
      try fixture.git(["config", "gc.autoDetach", "false"])
      try fixture.git(["config", "gc.worktreePruneExpire", "now"])
      try fixture.git(["config", "maintenance.auto", "true"])
      let maintenanceMarker = fixture.root.appendingPathComponent(".git/auto-gc-ran")
      try fixture.hook("pre-auto-gc", body: "touch \(quote(maintenanceMarker.path))")
      let result = try fixture.apply()
      #expect(result["state"] == .string("merged"))
      #expect(
        !FileManager.default.fileExists(
          atPath: fixture.root.appendingPathComponent(".git/auto-gc-ran").path))
      #expect(try Data(contentsOf: directory.appendingPathComponent("index")) == index)
      #expect(
        try String(
          contentsOf: directory.appendingPathComponent("refs/worktree/keep"), encoding: .utf8
        ).trimmingCharacters(in: .newlines) == privateCommit)
      #expect(try fixture.git(["worktree", "list", "--porcelain"]).contains(missing.path))
      try fixture.repository().withLock { try fixture.repository().recover() }
      #expect(FileManager.default.fileExists(atPath: directory.path))
      try fixture.git(["maintenance", "run", "--auto"])
      #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
  }

  @Test(arguments: ["command", "textconv"])
  func inspectionDoesNotRunDiffHelpers(helper: String) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      try fixture.write(".gitattributes", "notes/log.md diff=external\n")
      try fixture.git(["add", "--", ".gitattributes"])
      try fixture.git(["commit", "-m", "test: diff attributes"])
      let script = fixture.temporary.url.appendingPathComponent("diff-helper")
      let marker = fixture.root.appendingPathComponent(".git/diff-helper-ran")
      try Data("#!/bin/sh\ntouch \(quote(marker.path))\ncat \"$1\"\n".utf8).write(to: script)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
      try fixture.git(["config", "diff.external.\(helper)", script.path])
      try fixture.git(["config", "diff.external.trustExitCode", "true"])
      try fixture.git(["config", "diff.external.cachetextconv", "true"])
      let io = DeliveryIO(beforeJournalWrite: { journal in
        if journal.phase == .started, journal.staged == nil,
          journal.changes?.allSatisfy({ $0.writeState == .written }) == true
        {
          try fixture.git(
            ["add", "--", "notes/log.md"], at: URL(fileURLWithPath: journal.worktree))
        }
      })
      let result = try fixture.apply(provider: fixture.provider(io: io))
      #expect(result["state"] == .string("cleanup_pending"))
      #expect(try fixture.journals().first?.commit == nil)
      #expect(!FileManager.default.fileExists(atPath: marker.path))
      #expect(try fixture.git(["for-each-ref", "refs/notes/textconv/"]).isEmpty)
      let journal = try #require(fixture.journals().first)
      try fixture.git(["diff", "--cached"], at: URL(fileURLWithPath: journal.worktree))
      #expect(FileManager.default.fileExists(atPath: marker.path))
    }
  }

  @Test(arguments: [false, true])
  func recursiveSubmoduleConfigurationPreservesDetachedWork(sparse: Bool) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let dependency = try DeliveryFixture()
      try fixture.git([
        "-c", "protocol.file.allow=always", "submodule", "add", dependency.root.path, "dependency",
      ])
      try fixture.git(["commit", "-m", "test: local submodule"])
      let nested = fixture.root.appendingPathComponent("dependency")
      let commit = try fixture.git(
        [
          "-c", "user.name=Delivery Test", "-c", "user.email=delivery@example.invalid",
          "commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "test: detached submodule work",
        ], at: nested)
      try fixture.git(["checkout", "--detach", commit], at: nested)
      try fixture.write("notes/log.md", "external submodule work\n", at: nested)
      try fixture.git(["config", "submodule.recurse", "true"])
      var scope = fixture.scope
      scope.sparse = sparse
      let result = try fixture.apply(provider: fixture.provider(scope: scope))
      #expect(result["state"] == .string("merged"), "\(result)")
      #expect(try fixture.git(["rev-parse", "HEAD"], at: nested) == commit)
      #expect(try fixture.read("notes/log.md", at: nested) == "external submodule work\n")
      #expect(try fixture.read("notes/log.md") == "beta\nstable\n")
    }
  }

  @Test(arguments: ["file", "symlink", "directory"])
  func absentJournalPublicationPreservesNewTarget(kind: String) async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let content = "external journal content\n"
      let source = fixture.temporary.url.appendingPathComponent("foreign-journal")
      try Data(content.utf8).write(to: source)
      let provider = fixture.provider(
        io: .init(beforeJournalPublication: { target in
          switch kind {
          case "symlink":
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: source)
          case "directory":
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            try Data(content.utf8).write(to: target.appendingPathComponent("keep"))
          default:
            try Data(content.utf8).write(to: target)
          }
        }))
      let result = try fixture.apply(provider: provider)
      #expect(result["state"] == .string("aborted"))
      #expect(result["reason"] == .string("journal_failed"))
      let directory = fixture.root.appendingPathComponent(".git/computer-mcp/delivery")
      let entries = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
      #expect(entries.count == 1)
      let target = try #require(entries.first)
      #expect(target.pathExtension == "json")
      #expect(
        try String(
          contentsOf: kind == "directory" ? target.appendingPathComponent("keep") : target,
          encoding: .utf8) == content)
      #expect(try String(contentsOf: source, encoding: .utf8) == content)
      try fixture.assertClean()
    }
  }

  @Test
  func missingPromisorObjectDoesNotStartTransport() async throws {
    try await deliveryTest {
      let fixture = try DeliveryFixture()
      let base = try fixture.git(["rev-parse", "HEAD"])
      let object = fixture.root.appendingPathComponent(
        ".git/objects/\(base.prefix(2))/\(base.dropFirst(2))")
      let content = try Data(contentsOf: object)
      let marker = fixture.temporary.url.appendingPathComponent("transport-ran")
      let script = fixture.temporary.url.appendingPathComponent("transport")
      try Data("#!/bin/sh\ntouch \(quote(marker.path))\nexit 1\n".utf8).write(to: script)
      try fixture.git(["config", "core.repositoryFormatVersion", "1"])
      try fixture.git(["config", "extensions.partialClone", "origin"])
      try fixture.git(["config", "remote.origin.promisor", "true"])
      try fixture.git(["config", "remote.origin.url", "ext::/bin/sh \(script.path)"])
      try fixture.git(["config", "protocol.ext.allow", "always"])
      try FileManager.default.removeItem(at: object)
      let provider = DeliveryToolProvider(
        environment: fixture.tools(
          extraEnvironment: ["GIT_NO_LAZY_FETCH": "0", "GIT_ALLOW_PROTOCOL": "ext"],
          commandEnvironment: ["GIT_ALLOW_PROTOCOL": "ext"]),
        io: .init(), startsRecovery: false)
      let result = try fixture.apply(provider: provider)
      #expect(result["state"] == .string("aborted"))
      #expect(result["reason"] == .string("git_failed"))
      #expect(!FileManager.default.fileExists(atPath: marker.path))
      #expect(!FileManager.default.fileExists(atPath: object.path))
      #expect(try fixture.journals().isEmpty)
      try fixture.git(["cat-file", "-p", base], accepting: [128])
      #expect(FileManager.default.fileExists(atPath: marker.path))
      try content.write(to: object)
      try fixture.assertClean()
    }
  }
}
