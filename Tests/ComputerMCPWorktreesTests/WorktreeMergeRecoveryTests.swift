import Foundation
import Testing

@testable import ComputerMCPWorktrees

struct WorktreeMergeRecoveryTests {
  @Test(arguments: ["dirty", "captured", "prepared"])
  func preCheckoutCandidateCanBeReplacedAfterOwnerCommitAndRebase(interruption: String) throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let original = try f.service()
      let created = try original.create(name: "retry")
      let old = try f.raw(["rev-parse", "HEAD"])
      _ = try f.privateCommit(original, projectID: created.projectID)
      let failure = MergePhaseFailure(
        phase: interruption,
        url: f.storage.journals.appendingPathComponent("merges/" + created.projectID + ".json"))
      if interruption == "dirty" {
        try Data("owner\n".utf8).write(to: f.repository.appendingPathComponent("file.txt"))
      }
      let service = try f.service(journalIO: .init(beforeDirectorySync: { try failure.check() }))
      #expect(throws: (any Error).self) {
        try service.merge(projectID: created.projectID) { _, _ in }
      }
      let pending = try #require(try original.readMerge(created.projectID))
      #expect([.captured, .prepared].contains(pending.phase))
      if interruption == "dirty" {
        try f.raw(["add", "file.txt"])
        try f.raw(["commit", "-m", "owner"])
      } else {
        try f.raw(["commit", "--allow-empty", "-m", "owner"])
      }
      let ownerTip = try f.raw(["rev-parse", "HEAD"])
      let git = PrivateWorktreeGit(
        f: f, topology: try original.topology(projectID: created.projectID))
      try git.run(["fetch", "origin"])
      try git.run(["rebase", "-X", "theirs", "--onto", ownerTip, old])
      let rebased = try git.run(["rev-parse", "HEAD"])
      if interruption == "prepared" {
        let abandoned = MergePhaseFailure(
          phase: "abandoned",
          url: f.storage.journals.appendingPathComponent("merges/" + created.projectID + ".json"))
        let retry = try f.service(journalIO: .init(beforeDirectorySync: { try abandoned.check() }))
        #expect(throws: CancellationError.self) {
          try retry.merge(projectID: created.projectID) { _, _ in }
        }
        #expect(abandoned.fired)
        #expect(try f.raw(["rev-parse", "HEAD"]) == ownerTip)
      }
      let result = try original.merge(projectID: created.projectID) { _, _ in }
      #expect(result.operationID != pending.operationID)
      #expect(result.oid == rebased)
      #expect(try f.raw(["rev-parse", "HEAD"]) == rebased)
      #expect(try f.raw(["merge-base", ownerTip, rebased]) == ownerTip)
      #expect(
        try f.raw(["rev-parse", original.preservationRef(pending.record, oid: pending.target)])
          == pending.target)
      if let stage = pending.staging {
        #expect(!FileManager.default.fileExists(atPath: stage.path))
      }
    }
  }

  @Test(arguments: ["captured", "prepared", "checkout", "ready", "published", "ledger", "finished"])
  func durablePhasesReconcileWithoutReset(phase: String) throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let original = try f.service()
      let created = try original.create(name: "crash")
      let tip = try f.privateCommit(original, projectID: created.projectID)
      let fault = MergePhaseFailure(
        phase: phase,
        url: f.storage.journals.appendingPathComponent("merges/" + created.projectID + ".json"))
      let service = try f.service(journalIO: .init(beforeDirectorySync: { try fault.check() }))
      #expect(throws: (any Error).self) {
        try service.merge(projectID: created.projectID) { _, _ in }
      }
      #expect(fault.fired)
      let result = try f.service().merge(projectID: created.projectID) { _, _ in }
      #expect(result.oid == tip)
      #expect(try f.raw(["rev-parse", "HEAD"]) == tip)
      #expect(try f.store.records().first?.worktree?.mergedOID == tip)
    }
  }

  @Test(arguments: ["none", "edit", "third"])
  func lostCommitAcknowledgementRequiresMatchingCheckoutAndOwnedRef(interference: String) throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let original = try f.service()
      let created = try original.create(name: "ack")
      let tip = try f.privateCommit(original, projectID: created.projectID)
      let service = try f.service(
        executor: MergeTestExecutor(base: f.executor, afterCommit: { throw CancellationError() }))
      #expect(throws: CancellationError.self) {
        try service.merge(projectID: created.projectID) { _, _ in }
      }
      #expect(try f.raw(["rev-parse", "HEAD"]) == tip)
      if interference == "edit" {
        try Data("owner\n".utf8).write(to: f.repository.appendingPathComponent("file.txt"))
      }
      if interference == "third" { try f.raw(["commit", "--allow-empty", "-m", "owner"]) }
      let observed = try f.raw(["rev-parse", "HEAD"])
      if interference == "none" {
        #expect(try f.service().merge(projectID: created.projectID) { _, _ in }.oid == tip)
      } else {
        #expect(throws: WorktreeError.self) {
          try f.service().merge(projectID: created.projectID) { _, _ in }
        }
        #expect(try f.raw(["rev-parse", "HEAD"]) == observed)
        if interference == "edit" {
          #expect(
            try String(contentsOf: f.repository.appendingPathComponent("file.txt"), encoding: .utf8)
              == "owner\n")
        }
      }
    }
  }

  @Test(arguments: ["head", "base", "source"])
  func movementBeforePrepareCannotCheckout(kind: String) throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let original = try f.service()
      let created = try original.create(name: "race")
      let old = try f.raw(["rev-parse", "HEAD"])
      let tip = try f.privateCommit(original, projectID: created.projectID)
      try f.raw(["branch", "other", old])
      let service = try f.service(
        executor: MergeTestExecutor(
          base: f.executor,
          beforePrepare: {
            switch kind {
            case "head": try f.raw(["symbolic-ref", "HEAD", "refs/heads/other"])
            case "base": try f.raw(["update-ref", "refs/heads/main", tip, old])
            default: try f.raw(["update-ref", "refs/heads/" + created.branch, old, tip])
            }
          }))
      #expect(throws: (any Error).self) {
        try service.merge(projectID: created.projectID) { _, _ in }
      }
      #expect(
        try String(contentsOf: f.repository.appendingPathComponent("file.txt"), encoding: .utf8)
          == "initial\n")
      #expect(try f.raw(["rev-parse", "other"]) == old)
    }
  }

  @Test func partialCheckoutAndLaterOwnerEditAreRetained() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let original = try f.service()
      let created = try original.create(name: "partial")
      let old = try f.raw(["rev-parse", "HEAD"])
      _ = try f.privateCommit(original, projectID: created.projectID)
      let service = try f.service(
        executor: MergeTestExecutor(
          base: f.executor,
          afterCheckout: {
            throw POSIXError(.ENOSPC)
          }))
      #expect(throws: POSIXError.self) {
        try service.merge(projectID: created.projectID) { _, _ in }
      }
      #expect(try original.readMerge(created.projectID)?.phase == .checkout)
      #expect(
        try String(contentsOf: f.repository.appendingPathComponent("file.txt"), encoding: .utf8)
          == "private\n")
      try Data("owner after interruption\n".utf8).write(
        to: f.repository.appendingPathComponent("file.txt"))
      let index = try Data(contentsOf: f.repository.appendingPathComponent(".git/index"))
      #expect(throws: WorktreeError.self) {
        try f.service().merge(projectID: created.projectID) { _, _ in }
      }
      #expect(try f.raw(["rev-parse", "HEAD"]) == old)
      #expect(try Data(contentsOf: f.repository.appendingPathComponent(".git/index")) == index)
      #expect(
        try String(contentsOf: f.repository.appendingPathComponent("file.txt"), encoding: .utf8)
          == "owner after interruption\n")
    }
  }

  @Test func revocationAfterCheckoutAbortsRefAndCanOnlyResumeWithAuthority() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let service = try f.service()
      let created = try service.create(name: "revoke")
      let old = try f.raw(["rev-parse", "HEAD"])
      let tip = try f.privateCommit(service, projectID: created.projectID)
      #expect(throws: CancellationError.self) {
        try service.merge(projectID: created.projectID) { _, paths in
          if !paths.isEmpty, try service.readMerge(created.projectID)?.phase == .ready {
            throw CancellationError()
          }
        }
      }
      #expect(try f.raw(["rev-parse", "HEAD"]) == old)
      #expect(try service.readMerge(created.projectID)?.phase == .ready)
      #expect(throws: CancellationError.self) {
        try service.merge(projectID: created.projectID) { _, _ in throw CancellationError() }
      }
      #expect(try f.raw(["rev-parse", "HEAD"]) == old)
      #expect(try service.merge(projectID: created.projectID) { _, _ in }.oid == tip)
    }
  }

  @Test func hooksDriversAndSigningConfigurationDoNotExecute() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let service = try f.service()
      let created = try service.create(name: "programs")
      let tip = try f.privateCommit(service, projectID: created.projectID)
      let marker = directory.appendingPathComponent("executed")
      let hooks = f.repository.appendingPathComponent(".git/hooks")
      for name in ["post-checkout", "post-merge", "reference-transaction"] {
        let file = hooks.appendingPathComponent(name)
        try Data(("#!/bin/sh\ntouch '" + marker.path + "'\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
      }
      try f.raw(["config", "merge.sentinel.driver", "touch " + marker.path])
      try f.raw(["config", "gpg.program", "/usr/bin/false"])
      try f.raw(["config", "commit.gpgSign", "true"])
      #expect(try service.merge(projectID: created.projectID) { _, _ in }.oid == tip)
      #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
  }
}

private final class MergePhaseFailure: @unchecked Sendable {
  let phase: String
  let url: URL
  var fired = false
  init(phase: String, url: URL) {
    self.phase = phase
    self.url = url
  }
  func check() throws {
    if fired { throw CancellationError() }
    if let bytes = try? Data(contentsOf: url),
      let journal = try? JSONDecoder().decode(WorktreeMergeJournal.self, from: bytes),
      journal.phase.rawValue == phase
    {
      fired = true
      throw CancellationError()
    }
  }
}

private struct MergeTestExecutor: WorktreeGitExecuting {
  let base: WorktreeTestGit
  var beforePrepare: @Sendable () throws -> Void = {}
  var afterCheckout: @Sendable () throws -> Void = {}
  var afterCommit: @Sendable () throws -> Void = {}
  func execute(_ command: WorktreeGitCommand) throws -> WorktreeGitResult {
    let result = try base.execute(command)
    if command.arguments.contains("read-tree"), command.arguments.contains("-u"),
      !command.arguments.contains("-n")
    {
      try afterCheckout()
    }
    return result
  }
  func withPreparedTransaction(_ command: WorktreeGitCommand, _ body: () throws -> Void) throws {
    let merging = String(decoding: command.input, as: UTF8.self).contains("update HEAD ")
    if merging { try beforePrepare() }
    try base.withPreparedTransaction(command, body)
    if merging { try afterCommit() }
  }
}
