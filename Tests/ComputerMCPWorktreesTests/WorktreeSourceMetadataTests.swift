import Foundation
import Testing

@testable import ComputerMCPWorktrees

struct WorktreeSourceMetadataTests {
  @Test func guardPreparationResumesFromDurableTemporaryIdentity() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let service = try f.service()
      let repositoryLock = try service.acquireLock(validateHead: false)
      defer { repositoryLock.release() }
      let metadata = try service.sourceMetadata()
      let heads = metadata.common.url.appendingPathComponent("refs/heads")
      let branch = "refs/heads/main"
      var ownership = try WorktreeSourceGuardJournal(
        operationID: UUID(), common: metadata.common.identity, branches: [branch],
        guardingHead: false)
      var persisted = Data()
      let fault = WorktreeJournalIO(beforeDirectorySync: {
        let names = try FileManager.default.contentsOfDirectory(atPath: heads.path)
        if names.contains(where: { $0.hasPrefix(".computer-mcp-guard-") }) {
          throw SourceSyncFailure.interrupted
        }
      })
      let interruptible = sourceMetadata(metadata, io: fault)
      #expect(throws: SourceSyncFailure.interrupted) {
        _ = try WorktreeSourceGuards.acquire(
          &ownership, metadata: interruptible, repositoryLock: repositoryLock,
          branches: [branch], guardingHead: false,
          persist: { persisted = try JSONEncoder().encode($0) })
      }
      #expect(!FileManager.default.fileExists(atPath: heads.path + "/main.lock"))
      ownership = try JSONDecoder().decode(WorktreeSourceGuardJournal.self, from: persisted)
      let guards = try WorktreeSourceGuards.acquire(
        &ownership, metadata: metadata, repositoryLock: repositoryLock,
        branches: [branch], guardingHead: false, persist: { _ in })
      try guards.verify(covering: [branch, "packed-refs"])
      try guards.release(&ownership, branches: [branch], guardingHead: false, persist: { _ in })
      #expect(!FileManager.default.fileExists(atPath: heads.path + "/main.lock"))
    }
  }

  @Test func packedContentionRollsBackOnlyOwnedLocks() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let oid = try f.raw(["rev-parse", "HEAD"])
      let service = try f.service()
      let repositoryLock = try service.acquireLock(validateHead: false)
      defer { repositoryLock.release() }
      let metadata = try service.sourceMetadata()
      let foreign = metadata.common.url.appendingPathComponent("packed-refs.lock")
      let bytes = Data(repeating: 33, count: 8192)
      try bytes.write(to: foreign)
      let branch = "refs/heads/main"
      let branches = [branch, branch]
      var journal = try WorktreeSourceGuardJournal(
        operationID: UUID(), common: metadata.common.identity, branches: branches,
        guardingHead: true)
      #expect(throws: WorktreeError.self) {
        _ = try WorktreeSourceGuards.acquire(
          &journal, metadata: metadata, repositoryLock: repositoryLock,
          branches: branches, guardingHead: true, persist: { _ in })
      }
      #expect(try Data(contentsOf: foreign) == bytes)
      #expect(!FileManager.default.fileExists(atPath: metadata.common.url.path + "/HEAD.lock"))
      #expect(
        !FileManager.default.fileExists(atPath: metadata.common.url.path + "/" + branch + ".lock"))
      try FileManager.default.removeItem(at: foreign)
      let guards = try WorktreeSourceGuards.acquire(
        &journal, metadata: metadata, repositoryLock: repositoryLock,
        branches: branches, guardingHead: true, persist: { _ in })
      #expect(throws: WorktreeError.self) {
        try f.raw(["-c", "core.filesRefLockTimeout=0", "update-ref", branch, oid, oid])
      }
      let installed = try Data(contentsOf: foreign)
      try installed.write(to: foreign, options: .atomic)
      #expect(throws: WorktreeError.self) { try guards.verify() }
      #expect(try Data(contentsOf: foreign) == installed)
    }
  }

  @Test(arguments: [false, true])
  func deletionReplaysReceiptWithoutSourceObjectAndRefusesRecreation(recreate: Bool) throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let (base, target) = try sourceTips(f)
      let branch = "refs/heads/topic"
      let branches = [branch, "refs/heads/main"]
      try f.raw(["tag", "-a", "-m", "preserve peel", "keep", base])
      try f.raw(["pack-refs", "--all"])
      let service = try f.service()
      let repositoryLock = try service.acquireLock(validateHead: false)
      defer { repositoryLock.release() }
      let metadata = try service.sourceMetadata()
      let loose = metadata.common.url.appendingPathComponent(branch)
      let receipt = metadata.common.url.appendingPathComponent(branch + ".lock")
      let expected = Data((target + "\n").utf8)
      let fault = WorktreeJournalIO(beforeDirectorySync: {
        if !FileManager.default.fileExists(atPath: loose.path),
          (try? Data(contentsOf: receipt)) == expected
        {
          throw SourceSyncFailure.interrupted
        }
      })
      let interruptible = sourceMetadata(metadata, io: fault)
      var ownership = try WorktreeSourceGuardJournal(
        operationID: UUID(), common: metadata.common.identity, branches: branches,
        guardingHead: true)
      let guards = try WorktreeSourceGuards.acquire(
        &ownership, metadata: interruptible, repositoryLock: repositoryLock,
        branches: branches, guardingHead: true,
        persist: { _ in })
      var deletion = try WorktreeSourceDeletion(
        branch: branch, expected: target, base: branches[1], expectedBase: base,
        requireSymbolicHead: true, guards: guards)
      var journal = Data()
      #expect(throws: SourceSyncFailure.interrupted) {
        try deletion.completeSource(
          guards: guards, revalidate: { _ in },
          persist: { journal = try JSONEncoder().encode($0) })
      }
      #expect(!FileManager.default.fileExists(atPath: loose.path))
      #expect(try Data(contentsOf: receipt) == expected)
      let object = metadata.common.url.appendingPathComponent(
        "objects/" + target.prefix(2) + "/" + target.dropFirst(2))
      try FileManager.default.removeItem(at: object)
      if recreate { try expected.write(to: loose, options: .atomic) }
      deletion = try JSONDecoder().decode(WorktreeSourceDeletion.self, from: journal)
      #expect(deletion.phase == .armed)
      let reopened = try WorktreeSourceGuards.acquire(
        &ownership, metadata: metadata, repositoryLock: repositoryLock,
        branches: branches, guardingHead: true,
        deletionReceipts: deletion.deletionReceipts, persist: { _ in })
      if recreate {
        #expect(throws: WorktreeError.self) {
          try deletion.completeSource(guards: reopened, revalidate: { _ in }, persist: { _ in })
        }
        #expect(try Data(contentsOf: loose) == expected)
        #expect(try Data(contentsOf: receipt) == expected)
      } else {
        try deletion.completeSource(guards: reopened, revalidate: { _ in }, persist: { _ in })
        #expect(deletion.phase == .sourceDeleted)
        #expect(try metadata.read("logs/" + branch) == nil)
        #expect(try f.raw(["rev-parse", "refs/tags/keep^{}"]) == base)
        try reopened.release(
          &ownership, branches: branches, guardingHead: true,
          deletionReceipts: deletion.deletionReceipts, persist: { _ in })
        try WorktreeSourceGuards.finishCleanup(
          ownership, metadata: metadata, repositoryLock: repositoryLock,
          branches: branches, guardingHead: true,
          deletionReceipts: deletion.deletionReceipts)
        #expect(!FileManager.default.fileExists(atPath: receipt.path))
      }
    }
  }

  @Test(arguments: [false, true])
  func publicationRequiresOwnedRawReflogAndSync(foreign: Bool) throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let (base, target) = try sourceTips(f)
      let branch = "refs/heads/topic"
      try f.raw(["update-ref", "-m", "set expected", branch, base, target])
      let service = try f.service()
      let repositoryLock = try service.acquireLock(validateHead: false)
      defer { repositoryLock.release() }
      let metadata = try service.sourceMetadata()
      let operationID = UUID()
      let message = "computer-mcp publish " + operationID.uuidString.lowercased()
      let proof = try WorktreeSourcePublicationProof(
        operationID: operationID, branch: branch, expected: base, target: target,
        message: message, metadata: metadata)
      try f.raw([
        "update-ref", "--create-reflog", "-m", foreign ? "foreign" : message, branch, target, base,
      ])
      let fault = SourceSyncFailureSwitch()
      let interruptible = sourceMetadata(
        metadata, io: .init(beforeDirectorySync: { try fault.check() }))
      var ownership = try WorktreeSourceGuardJournal(
        operationID: operationID, common: metadata.common.identity, branches: [branch],
        guardingHead: false)
      let guards = try WorktreeSourceGuards.acquire(
        &ownership, metadata: interruptible, repositoryLock: repositoryLock,
        branches: [branch], guardingHead: false,
        persist: { _ in })
      if foreign {
        #expect(throws: WorktreeError.self) {
          _ = try proof.proveAndSynchronize(guards: guards, revalidate: {})
        }
      } else {
        fault.arm()
        #expect(throws: SourceSyncFailure.interrupted) {
          _ = try proof.proveAndSynchronize(guards: guards, revalidate: {})
        }
        let reopened = try WorktreeSourceGuards.acquire(
          &ownership, metadata: metadata, repositoryLock: repositoryLock,
          branches: [branch], guardingHead: false,
          persist: { _ in })
        #expect(try proof.proveAndSynchronize(guards: reopened, revalidate: {}) == .durable)
      }
    }
  }

  @Test func unchangedPublicationUsesOnlyGuardedDirectValue() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let (_, target) = try sourceTips(f)
      let branch = "refs/heads/topic"
      let service = try f.service()
      let repositoryLock = try service.acquireLock(validateHead: false)
      defer { repositoryLock.release() }
      let metadata = try service.sourceMetadata()
      let operationID = UUID()
      let history = try #require(try metadata.read("logs/" + branch)?.proof)
      let proof = try WorktreeSourcePublicationProof(
        operationID: operationID, branch: branch, expected: target, target: target,
        message: "computer-mcp no-op", metadata: metadata)
      var ownership = try WorktreeSourceGuardJournal(
        operationID: operationID, common: metadata.common.identity, branches: [branch],
        guardingHead: false)
      let guards = try WorktreeSourceGuards.acquire(
        &ownership, metadata: metadata, repositoryLock: repositoryLock,
        branches: [branch], guardingHead: false, persist: { _ in })
      #expect(try proof.proveAndSynchronize(guards: guards, revalidate: {}) == .durable)
      #expect(try metadata.read("logs/" + branch)?.proof == history)
      try guards.release(&ownership, branches: [branch], guardingHead: false, persist: { _ in })
    }
  }

  @Test func mergeResumesDurableReflogBeforeSingleRefCommit() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let (base, target) = try sourceTips(f)
      try f.raw(["config", "core.sharedRepository", "group"])
      let service = try f.service()
      let repositoryLock = try service.acquireLock(validateHead: false)
      defer { repositoryLock.release() }
      let metadata = try service.sourceMetadata()
      let headLog = metadata.common.url.appendingPathComponent("logs/HEAD")
      let baseLog = metadata.common.url.appendingPathComponent("logs/refs/heads/main")
      try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: baseLog.path)
      let initialHeadLog = try Data(contentsOf: headLog)
      let initialBaseLog = try #require(try metadata.read("logs/refs/heads/main")?.contents)
      let initialIndex = try Data(contentsOf: metadata.common.url.appendingPathComponent("index"))
      let branches = ["refs/heads/main", "refs/heads/topic"]
      let fault = WorktreeJournalIO(beforeDirectorySync: {
        if try Data(contentsOf: headLog) != initialHeadLog { throw SourceSyncFailure.interrupted }
      })
      let interruptible = sourceMetadata(metadata, io: fault)
      var ownership = try WorktreeSourceGuardJournal(
        operationID: UUID(), common: metadata.common.identity, branches: branches,
        guardingHead: true)
      let guards = try WorktreeSourceGuards.acquire(
        &ownership, metadata: interruptible, repositoryLock: repositoryLock,
        branches: branches, guardingHead: true,
        persist: { _ in })
      let committer = try service.sourceMergeCommitter()
      let message = "computer-mcp worktree merge " + ownership.operationID.uuidString.lowercased()
      let suffix = Data((base + " " + target + " " + committer + "\t" + message + "\n").utf8)
      var merge = try WorktreeSourceMerge(
        base: branches[0], managed: branches[1], expected: base, target: target,
        message: message, committer: committer, guards: guards)
      var journal = Data()
      #expect(throws: SourceSyncFailure.interrupted) {
        try merge.completeSource(
          guards: guards, revalidate: {}, persist: { journal = try JSONEncoder().encode($0) })
      }
      #expect(try f.raw(["rev-parse", "HEAD"]) == base)
      #expect(try Data(contentsOf: headLog) == initialHeadLog + suffix)
      merge = try JSONDecoder().decode(WorktreeSourceMerge.self, from: journal)
      let reopened = try WorktreeSourceGuards.acquire(
        &ownership, metadata: metadata, repositoryLock: repositoryLock,
        branches: branches, guardingHead: true, persist: { _ in })
      try merge.completeSource(guards: reopened, revalidate: {}, persist: { _ in })
      try merge.completeSource(guards: reopened, revalidate: {}, persist: { _ in })
      #expect(try f.raw(["rev-parse", "HEAD"]) == target)
      #expect(try f.raw(["symbolic-ref", "HEAD"]) == branches[0])
      #expect(try Data(contentsOf: headLog) == initialHeadLog + suffix)
      #expect(try metadata.read("logs/refs/heads/main")?.contents == initialBaseLog + suffix)
      #expect(try metadata.read("logs/refs/heads/main")?.proof.mode == 0o664)
      #expect(
        try Data(contentsOf: metadata.common.url.appendingPathComponent("index")) == initialIndex)
    }
  }

  @Test func packedNormalizationComparesRawRefNamesAndRejectsMalformedImages() throws {
    let oid = String(repeating: "a", count: 40)
    let canonical = "refs/heads/é"
    let distinct = "refs/heads/e\u{301}"
    let remaining = Data(
      ("# header\n" + oid + " " + distinct + "\n" + oid + " refs/tags/keep\n^" + oid + "\n").utf8)
    let contents = remaining + Data((oid + " " + canonical + "\n^" + oid + "\n").utf8)
    let packed = try WorktreePackedRefs(contents, format: .sha1)
    #expect(packed.removing(canonical) == remaining)
    for invalid in [
      contents + Data((oid + " " + canonical + "\n").utf8),
      Data(("^" + oid + "\n").utf8),
      Data(contents.dropLast()),
      Data(
        ("# pack-refs with: sorted \n" + oid + " refs/heads/z\n" + oid + " refs/heads/a\n").utf8),
    ] {
      #expect(throws: WorktreeError.self) { _ = try WorktreePackedRefs(invalid, format: .sha1) }
    }
  }

  private func sourceTips(_ f: WorktreeFixture) throws -> (String, String) {
    let base = try f.raw(["rev-parse", "HEAD"])
    let tree = try f.raw(["rev-parse", "HEAD^{tree}"])
    let tip = try f.raw(["commit-tree", tree, "-p", base, "-m", "topic"])
    try f.raw(["update-ref", "--create-reflog", "-m", "create topic", "refs/heads/topic", tip])
    return (base, tip)
  }

  private func sourceMetadata(_ metadata: WorktreeSourceMetadata, io: WorktreeJournalIO)
    -> WorktreeSourceMetadata
  {
    .init(
      common: metadata.common, format: metadata.format, permissions: metadata.permissions, io: io)
  }
}

private enum SourceSyncFailure: Error, Equatable {
  case interrupted
}

private final class SourceSyncFailureSwitch: @unchecked Sendable {
  private let lock = NSLock()
  private var armed = false

  func arm() { lock.withLock { armed = true } }

  func check() throws {
    guard !lock.withLock({ armed }) else { throw SourceSyncFailure.interrupted }
  }
}
