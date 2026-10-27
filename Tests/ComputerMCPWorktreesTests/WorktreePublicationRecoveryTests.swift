import Foundation
import Testing

@testable import ComputerMCPWorktrees

struct WorktreePublicationRecoveryTests {
  @Test func unchangedPublicationRetainsMixedProtectionOutcome() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let original = try f.service()
      let created = try original.create(name: "unchanged-mixed")
      let tip = try f.privateCommit(original, projectID: created.projectID)
      _ = try original.publish(projectID: created.projectID) { _ in }
      let git = PrivateWorktreeGit(
        f: f, topology: try original.topology(projectID: created.projectID))
      var roots: [String] = []
      for message in ["first", "second"] {
        try git.run(["commit", "--allow-empty", "-m", message])
        roots.append(try git.run(["rev-parse", "HEAD"]))
      }
      try git.run(["reset", "--hard", tip])
      let failure = PublicationPhaseFailure(
        phase: "publishing",
        journal: f.storage.journals.appendingPathComponent(
          "publications/" + created.projectID + ".json"))
      let service = try f.service(journalIO: .init(beforeDirectorySync: { try failure.check() }))
      #expect(throws: (any Error).self) {
        try service.publish(projectID: created.projectID, preserving: roots) { _ in }
      }
      let pending = try #require(try original.readPublication(created.projectID))
      try f.raw(["update-ref", original.preservationRef(pending.record, oid: roots[0]), roots[0]])
      #expect(throws: WorktreeError.self) {
        try original.publish(projectID: created.projectID) { _ in }
      }
      #expect(try original.readPublication(created.projectID)?.phase == .publishing)
      #expect(try f.raw(["rev-parse", "refs/heads/" + created.branch]) == tip)
    }
  }

  @Test(arguments: [false, true], [false, true])
  func unchangedPublicationRecoversAcrossRefTransaction(afterCommit: Bool, extraRoots: Bool) throws
  {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let original = try f.service()
      let created = try original.create(name: "unchanged")
      let tip = try f.privateCommit(original, projectID: created.projectID)
      _ = try original.publish(projectID: created.projectID) { _ in }
      let priorReceipt = try f.raw([
        "reflog", "show", "-1", "--format=%gs", "refs/heads/" + created.branch,
      ])
      let git = PrivateWorktreeGit(
        f: f, topology: try original.topology(projectID: created.projectID))
      var roots: [String] = []
      if extraRoots {
        try git.run(["commit", "--allow-empty", "-m", "preserve"])
        roots.append(try git.run(["rev-parse", "HEAD"]))
        try git.run(["reset", "--hard", tip])
      }
      let failure = PublicationPhaseFailure(
        phase: "publishing",
        journal: f.storage.journals.appendingPathComponent(
          "publications/" + created.projectID + ".json"))
      let service =
        try afterCommit
        ? f.service(executor: LostPublicationAcknowledgement(base: f.executor))
        : f.service(journalIO: .init(beforeDirectorySync: { try failure.check() }))
      #expect(throws: (any Error).self) {
        try service.publish(projectID: created.projectID, preserving: roots) { _ in }
      }
      let pending = try #require(try original.readPublication(created.projectID))
      #expect(pending.phase == .publishing)
      #expect(pending.expectedOID == pending.capturedOID)
      #expect(
        try f.raw(["reflog", "show", "-1", "--format=%gs", "refs/heads/" + created.branch])
          == priorReceipt)
      #expect(throws: CancellationError.self) {
        try original.publish(projectID: created.projectID) { _ in throw CancellationError() }
      }
      let result = try original.publish(projectID: created.projectID) { _ in }
      #expect(result.operationID == pending.operationID)
      #expect(result.oid == tip)
      for oid in roots {
        #expect(
          try f.raw(["rev-parse", original.preservationRef(pending.record, oid: oid)]) == oid)
      }
      #expect(try original.readPublication(created.projectID)?.phase == .finished)
    }
  }

  @Test(arguments: [
    "captured", "copied", "verified", "installing", "installed", "publishing", "published",
    "ledger", "finished",
  ])
  func everyDurablePhaseRecoversWithoutRevertingRefs(phase: String) throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let original = try f.service()
      let created = try original.create(name: "crash")
      let tip = try f.privateCommit(original, projectID: created.projectID)
      let failure = PublicationPhaseFailure(
        phase: phase,
        journal: f.storage.journals.appendingPathComponent(
          "publications/" + created.projectID + ".json"))
      let service = try f.service(journalIO: .init(beforeDirectorySync: { try failure.check() }))
      #expect(throws: (any Error).self) {
        try service.publish(projectID: created.projectID) { _ in }
      }
      #expect(failure.fired)
      let recovered = try f.service()
      // Incomplete input is rejected once, then a fresh call captures it again.
      if let pending = try recovered.readPublication(created.projectID),
        [.captured, .copied].contains(pending.phase)
      {
        #expect(throws: WorktreeError.self) {
          try recovered.publish(projectID: created.projectID) { _ in }
        }
      }
      let result = try recovered.publish(projectID: created.projectID) { _ in }
      #expect(result.oid == tip)
      #expect(try f.raw(["rev-parse", "refs/heads/" + created.branch]) == tip)
      #expect(try f.store.records().first?.worktree?.publishedOID == tip)
    }
  }

  @Test(arguments: [false, true])
  func lostRefAcknowledgementReadsBackNewAndRejectsThirdValue(interfere: Bool) throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let original = try f.service()
      let created = try original.create(name: "ack")
      let tip = try f.privateCommit(original, projectID: created.projectID)
      let service = try f.service(executor: LostPublicationAcknowledgement(base: f.executor))
      #expect(throws: (any Error).self) {
        try service.publish(projectID: created.projectID) { _ in }
      }
      #expect(try f.raw(["rev-parse", "refs/heads/" + created.branch]) == tip)
      let recovered = try f.service()
      if interfere {
        try f.raw(["commit", "--allow-empty", "-m", "external"])
        let third = try f.raw(["rev-parse", "HEAD"])
        try f.raw(["update-ref", "refs/heads/" + created.branch, third, tip])
        #expect(throws: WorktreeError.self) {
          try recovered.publish(projectID: created.projectID) { _ in }
        }
        #expect(try f.raw(["rev-parse", "refs/heads/" + created.branch]) == third)
        #expect(try f.raw(["cat-file", "-t", tip]) == "commit")
      } else {
        #expect(try recovered.publish(projectID: created.projectID) { _ in }.oid == tip)
      }
    }
  }

  @Test func revokedAuthorityAndStaleBranchCannotCommit() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let service = try f.service()
      let created = try service.create(name: "revoke")
      let base = try f.raw(["rev-parse", "HEAD"])
      _ = try f.privateCommit(service, projectID: created.projectID)
      var calls = 0
      #expect(throws: CancellationError.self) {
        try service.publish(projectID: created.projectID) { _ in
          calls += 1
          if calls == 4 { throw CancellationError() }
        }
      }
      #expect(calls == 4)
      #expect(try f.raw(["rev-parse", "refs/heads/" + created.branch]) == base)
      try f.raw(["commit", "--allow-empty", "-m", "external"])
      let other = try f.raw(["rev-parse", "HEAD"])
      try f.raw(["update-ref", "refs/heads/" + created.branch, other, base])
      #expect(throws: WorktreeError.self) {
        try service.publish(projectID: created.projectID) { _ in }
      }
      #expect(try f.raw(["rev-parse", "refs/heads/" + created.branch]) == other)
    }
  }
}

private final class PublicationPhaseFailure: @unchecked Sendable {
  let phase: String
  let journal: URL
  var fired = false
  init(phase: String, journal: URL) {
    self.phase = phase
    self.journal = journal
  }
  func check() throws {
    if fired { throw CancellationError() }
    if let data = try? Data(contentsOf: journal),
      let value = try? JSONDecoder().decode(WorktreePublicationJournal.self, from: data),
      value.phase.rawValue == phase
    {
      fired = true
      throw CancellationError()
    }
  }
}

private struct LostPublicationAcknowledgement: WorktreeGitExecuting {
  let base: WorktreeTestGit
  func execute(_ command: WorktreeGitCommand) throws -> WorktreeGitResult {
    try base.execute(command)
  }
  func withPreparedTransaction(_ command: WorktreeGitCommand, _ body: () throws -> Void) throws {
    try base.withPreparedTransaction(command, body)
    throw CancellationError()
  }
}

extension WorktreePublicationRecoveryTests {
  @Test func installedPackSurvivesGarbageCollectionBeforeRefPublication() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let service = try f.service()
      let created = try service.create(name: "gc")
      let tip = try f.privateCommit(service, projectID: created.projectID)
      var calls = 0
      let result = try service.publish(projectID: created.projectID) { _ in
        calls += 1
        if calls == 3 { try f.raw(["gc", "--prune=now"]) }
      }
      #expect(result.oid == tip)
      #expect(try f.raw(["cat-file", "-t", tip]) == "commit")
      let journal = try service.readPublication(created.projectID)!
      let keep = f.repository.appendingPathComponent(".git/objects/pack/" + journal.pack! + ".keep")
      #expect(!FileManager.default.fileExists(atPath: keep.path))
    }
  }

  @Test func packDirectorySyncFailureRetainsOwnedKeepAndResumesInstallation() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let original = try f.service()
      let created = try original.create(name: "space")
      let tip = try f.privateCommit(original, projectID: created.projectID)
      let failure = PackInstallFailure(
        journal: f.storage.journals.appendingPathComponent(
          "publications/" + created.projectID + ".json"))
      let service = try f.service(journalIO: .init(beforeDirectorySync: { try failure.check() }))
      #expect(throws: POSIXError.self) {
        try service.publish(projectID: created.projectID) { _ in }
      }
      #expect(failure.fired)
      let journal = try original.readPublication(created.projectID)!
      let directory = URL(fileURLWithPath: journal.repository.objects.path).appendingPathComponent(
        "pack")
      #expect(
        FileManager.default.fileExists(
          atPath: directory.appendingPathComponent(journal.pack! + ".pack").path))
      #expect(
        FileManager.default.fileExists(
          atPath: directory.appendingPathComponent(journal.pack! + ".keep").path))
      do {
        try f.raw(["gc", "--prune=now"])
      } catch WorktreeError.commandFailed(let message) {
        // An incomplete shared pack cannot resolve this private worktree HEAD.
        #expect(message.contains("bad object"))
      }
      #expect(
        FileManager.default.fileExists(
          atPath: directory.appendingPathComponent(journal.pack! + ".pack").path))
      #expect(try original.publish(projectID: created.projectID) { _ in }.oid == tip)
      try f.raw(["gc", "--prune=now"])
    }
  }
}

private final class PackInstallFailure: @unchecked Sendable {
  let journal: URL
  var fired = false
  init(journal: URL) { self.journal = journal }
  func check() throws {
    guard !fired, let data = try? Data(contentsOf: journal),
      let value = try? JSONDecoder().decode(WorktreePublicationJournal.self, from: data),
      value.phase == .installing, let pack = value.pack,
      FileManager.default.fileExists(
        atPath:
          URL(fileURLWithPath: value.repository.objects.path).appendingPathComponent(
            "pack/" + pack + ".pack"
          ).path)
    else { return }
    fired = true
    throw POSIXError(.ENOSPC)
  }
}

extension WorktreePublicationRecoveryTests {
  @Test func mixedRefTransactionIsRetainedForReconciliation() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let original = try f.service()
      let created = try original.create(name: "mixed")
      let base = try f.raw(["rev-parse", "HEAD"])
      let tip = try f.privateCommit(original, projectID: created.projectID)
      let failure = PublicationPhaseFailure(
        phase: "publishing",
        journal: f.storage.journals.appendingPathComponent(
          "publications/" + created.projectID + ".json"))
      let service = try f.service(journalIO: .init(beforeDirectorySync: { try failure.check() }))
      #expect(throws: (any Error).self) {
        try service.publish(projectID: created.projectID) { _ in }
      }
      let journal = try original.readPublication(created.projectID)!
      try f.raw(["update-ref", original.preservationRef(journal.record, oid: tip), tip])
      #expect(throws: WorktreeError.self) {
        try original.publish(projectID: created.projectID) { _ in }
      }
      #expect(try f.raw(["rev-parse", "refs/heads/" + created.branch]) == base)
      #expect(try f.raw(["cat-file", "-t", tip]) == "commit")
    }
  }
}
