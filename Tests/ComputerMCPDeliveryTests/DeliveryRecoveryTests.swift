import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatformPOSIX
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPDelivery

@Suite(.nativeIntegration)
struct DeliveryRecoveryTests {
  enum Interruption: String, CaseIterable, Sendable {
    case beforeWorktree, beforeCommit, afterCommitBeforeJournal, afterCommit, beforeMerge,
      afterMerge, duringRebase
  }

  @Test(arguments: Interruption.allCases)
  func recoverInterruptedGitStates(at point: Interruption) async throws {
    try await deliveryTest {

      let fixture = try DeliveryFixture()
      let journal = try interrupted(fixture, at: point)
      let repository = try fixture.repository()
      try repository.withLock { try repository.recover() }
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
      let journal = try interrupted(fixture, at: .beforeWorktree)
      let worktree = URL(fileURLWithPath: journal.worktree)
      var gitfile: Data?
      if registered {
        try fixture.git(["worktree", "add", "-b", journal.branch, worktree.path, journal.base])
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
        exec \(quote(fixture.executable)) "$@"
        """
      try Data(script.utf8).write(to: wrapper)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
      var configuration = fixture.tools().configuration
      configuration.cli.commands[0].executable = wrapper.path
      let tools = ToolEnvironment(configuration: configuration, environment: fixture.environment)
      let repository = try DeliveryRepository(
        scope: fixture.scope, workspace: fixture.root, git: DeliveryGit(environment: tools))
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
      configuration.workspaceDirectory = linked
      configuration.workspaces[0].path = linked.path
      let provider = DeliveryToolProvider(
        environment: .init(configuration: configuration, environment: fixture.environment),
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

  private func interrupted(_ fixture: DeliveryFixture, at point: Interruption) throws
    -> DeliveryJournal
  {
    let repository = try fixture.repository()
    let operationID = UUID().uuidString.lowercased()
    let worktree = fixture.root.appendingPathComponent(".claude/worktrees/" + operationID)
    var journal = DeliveryJournal(
      operationID: operationID, workspace: "fixture", scope: "notes",
      repository: fixture.root.path, defaultBranch: "main", branch: "docs/entry",
      worktree: worktree.path,
      base: try fixture.git(["rev-parse", "main"]))
    try repository.io.write(journal, to: repository.journals)
    if point == .beforeWorktree { return journal }
    try fixture.git(["worktree", "add", "-b", journal.branch, worktree.path, journal.base])
    try fixture.write("notes/log.md", "beta\nstable\n", at: worktree)
    try fixture.git(["add", "notes/log.md"], at: worktree)
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
      try fixture.git(["rebase", "main"], at: worktree, accepting: [1])
    }
    if point == .afterMerge { try fixture.git(["merge", "--ff-only", journal.branch]) }
    return journal
  }
}
