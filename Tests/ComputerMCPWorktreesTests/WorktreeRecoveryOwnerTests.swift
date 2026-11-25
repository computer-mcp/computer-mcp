import ComputerMCPPersistence
import Foundation
import Testing

@testable import ComputerMCPWorktrees

struct WorktreeRecoveryOwnerTests {
  @Test func liveReleaseUsesExactReviewAndCannotPassAReservedWriter() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let worktrees = try f.service()
      let owner = try ownerService(f)
      #expect(try owner.list().isEmpty)
      #expect(!FileManager.default.fileExists(atPath: f.storage.recovery.path))
      let created = try worktrees.create(name: "writer")
      let privateGit = PrivateWorktreeGit(
        f: f, topology: try worktrees.topology(projectID: created.projectID))
      let blob = try privateGit.run(
        ["hash-object", "-w", "--stdin"], input: Data("owner blob".utf8))
      try privateGit.run(["update-ref", "refs/tags/blob", blob])
      _ = try worktrees.publish(projectID: created.projectID) { _ in }
      let view = try #require(try owner.list().first)
      let record = try #require(view.records.first { $0.oid == blob })
      let common = f.repository.appendingPathComponent(".git/computer-mcp/admission")
      let reviewed = try owner.reviewRelease(
        key: view.key, generation: view.generation, selections: [record.selection],
        principal: principal)
      #expect(!FileManager.default.fileExists(atPath: common.path))
      guard case .unsubmitted = try owner.operation(reviewed.handle, principal: principal) else {
        Issue.record("Review reserved an operation.")
        return
      }
      #expect(throws: WorktreeRecoveryOwnerError.unsubmitted) {
        try owner.resume(reviewed.handle, principal: principal)
      }
      let admission = try worktrees.admission(projectID: created.projectID)
      let writer = try admission.reserve(ownerID: UUID(), executionID: UUID())
      let refusal = try owner.confirm(reviewed, principal: principal)
      guard case .busy = refusal.outcome else {
        Issue.record("A reserved writer did not block release.")
        return
      }
      try admission.requireOpen(writer)
      try admission.acknowledge(writer)
      #expect(try owner.resume(reviewed.handle, principal: principal) == refusal)
      let fresh = try owner.reviewRelease(
        key: view.key, generation: view.generation, selections: [record.selection],
        principal: principal)
      let competing = try owner.reviewRelease(
        key: view.key, generation: view.generation, selections: [record.selection],
        principal: principal)
      let released = try owner.confirm(fresh, principal: principal)
      #expect(released.outcome == .released)
      let stale = try owner.confirm(competing, principal: principal)
      #expect(stale.outcome == .stale)
      #expect(stale.request.handle == competing.handle)
      #expect(released.gates.map(\.cleanup) == [.cleared])
      #expect(try owner.confirm(fresh, principal: principal) == released)
      #expect(try !#require(owner.list().first).records.contains { $0.id == record.id })
      let nextWriter = try admission.reserve(ownerID: UUID(), executionID: UUID())
      try admission.acknowledge(nextWriter)
    }
  }

  @Test func admittedReleaseFinishesAfterLosingTheSourceAndGate() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let worktrees = try f.service()
      let owner = try ownerService(f)
      let created = try worktrees.create(name: "restart")
      let privateGit = PrivateWorktreeGit(
        f: f, topology: try worktrees.topology(projectID: created.projectID))
      let blob = try privateGit.run(["hash-object", "-w", "--stdin"], input: Data("restart".utf8))
      try privateGit.run(["update-ref", "refs/tags/blob", blob])
      _ = try worktrees.publish(projectID: created.projectID) { _ in }
      let view = try #require(owner.list().first)
      let record = try #require(view.records.first { $0.oid == blob })
      let review = try owner.reviewRelease(
        key: view.key, generation: view.generation, selections: [record.selection],
        principal: principal)
      let recoveryGit = try f.recoveryGitDirectory()
      let anchor = recoveryGit.appendingPathComponent(
        "refs/recovery/" + record.id.uuidString.lowercased())
      let interruption = WorktreeJournalIO(beforeDirectorySync: {
        if !FileManager.default.fileExists(atPath: anchor.path) { throw CancellationError() }
      })
      #expect(throws: CancellationError.self) {
        try ownerService(f, journalIO: interruption).confirm(review, principal: principal)
      }
      try FileManager.default.removeItem(at: f.repository)
      let resumed = try owner.resume(review.handle, principal: principal)
      #expect(resumed.outcome == .released)
      #expect(resumed.request.handle == review.handle)
      #expect(resumed.gates.map(\.cleanup) == [.pending])
      guard case .submitted(let readback) = try owner.operation(review.handle, principal: principal)
      else {
        Issue.record("Logical release did not publish the original result.")
        return
      }
      #expect(readback == resumed)
    }
  }

  @Test func completedBranchDeletionMakesMixedReviewStaleOnItsOriginalHandle() async throws {
    try await removalFixture { f in
      let worktrees = try f.service()
      let owner = try ownerService(f)
      let created = try worktrees.create(name: "deletion")
      let privateGit = PrivateWorktreeGit(
        f: f, topology: try worktrees.topology(projectID: created.projectID))
      let blob = try f.raw(["rev-parse", "HEAD:file.txt"])
      try privateGit.run(["update-ref", "refs/tags/base-blob", blob])
      try privateGit.run(["tag", "-a", "independent", "-m", "independent root"])
      let tag = try privateGit.run(["rev-parse", "refs/tags/independent"])
      _ = try await worktrees.remove(projectID: created.projectID, terminate: { _, _ in }) { _, _ in
      }
      let view = try #require(owner.list().first)
      let selection = view.records.filter { [blob, tag].contains($0.oid) }.map(\.selection)
      #expect(selection.count == 2)
      let reviewed = try owner.reviewRelease(
        key: view.key, generation: view.generation, selections: selection, principal: principal)
      #expect(
        try worktrees.deleteBranch(
          created.branch, authority: .sandbox, dryRun: false, confirm: true
        ) { _ in }.deleted)
      let stale = try owner.confirm(reviewed, principal: principal)
      #expect(stale.outcome == .stale)
      #expect(stale.request.handle == reviewed.handle)
      #expect(try owner.resume(reviewed.handle, principal: principal) == stale)
      let current = try #require(owner.list().first)
      let survivor = try #require(current.records.first { $0.oid == tag })
      #expect(!current.records.contains { $0.oid == blob })

      try FileManager.default.removeItem(at: f.repository)
      let inactive = try owner.reviewRelease(
        key: view.key, generation: view.generation, selections: [survivor.selection],
        principal: principal)
      let result = try owner.confirm(inactive, principal: principal)
      #expect(result.outcome == .released)
      #expect(try owner.resume(inactive.handle, principal: principal) == result)
    }
  }

  enum ForeignDeletionEvidence: Sendable {
    case intact, requestDigest, selectionDigest, missingJournal
  }

  @Test(arguments: [
    ForeignDeletionEvidence.intact, .requestDigest, .selectionDigest, .missingJournal,
  ])
  func singleRetiredRecordRequiresFrozenDeletionEvidence(
    evidence: ForeignDeletionEvidence
  ) async throws {
    try await removalFixture { f in
      let worktrees = try f.service()
      let owner = try ownerService(f)
      let created = try worktrees.create(name: "receipt")
      let privateGit = PrivateWorktreeGit(
        f: f, topology: try worktrees.topology(projectID: created.projectID))
      let blob = try f.raw(["rev-parse", "HEAD:file.txt"])
      try privateGit.run(["update-ref", "refs/tags/base-blob", blob])
      try privateGit.run(["tag", "-a", "survivor", "-m", "independent root"])
      let tag = try privateGit.run(["rev-parse", "refs/tags/survivor"])
      _ = try await worktrees.remove(projectID: created.projectID, terminate: { _, _ in }) { _, _ in
      }
      let view = try #require(owner.list().first)
      let retired = try #require(view.records.first { $0.oid == blob })
      let survivor = try #require(view.records.first { $0.oid == tag })
      let reviewed = try owner.reviewRelease(
        key: view.key, generation: view.generation, selections: [retired.selection],
        principal: principal)
      #expect(
        try worktrees.deleteBranch(
          created.branch, authority: .sandbox, dryRun: false, confirm: true
        ) { _ in }.deleted)

      let git = try f.recoveryGitDirectory()
      let store = git.deletingLastPathComponent()
      let receiptURL = store.appendingPathComponent(
        "released/" + retired.id.uuidString.lowercased() + ".json")
      let original = try Data(contentsOf: receiptURL)
      let receipt = try JSONDecoder().decode(WorktreeRecoveryReleaseReceipt.self, from: original)
      #expect(try receipt.encoded() == original)
      #expect(receipt.selection.revision > retired.revision)
      switch evidence {
      case .intact: break
      case .requestDigest, .selectionDigest:
        func changedDigest(_ original: String) -> String {
          String(repeating: original.first == "f" ? "e" : "f", count: 64)
        }
        let changed = WorktreeRecoveryReleaseReceipt(
          storeGeneration: receipt.storeGeneration, owner: receipt.owner,
          selection: receipt.selection,
          operationID: receipt.operationID,
          requestDigest: evidence == .requestDigest
            ? changedDigest(receipt.requestDigest) : receipt.requestDigest,
          selectionDigest: evidence == .selectionDigest
            ? changedDigest(receipt.selectionDigest) : receipt.selectionDigest)
        try changed.encoded().write(to: receiptURL)
      case .missingJournal:
        try FileManager.default.removeItem(
          at: f.storage.journals.appendingPathComponent("branch-deletions"))
      }
      let expectedReceipt = try Data(contentsOf: receiptURL)
      let anchor = git.appendingPathComponent(
        "refs/recovery/" + survivor.id.uuidString.lowercased())
      let expectedAnchor = try Data(contentsOf: anchor)
      try FileManager.default.removeItem(at: f.repository)

      let status = try owner.confirm(reviewed, principal: principal)
      if evidence == .intact {
        #expect(status.outcome == .stale)
      } else if case .recoveryRequired = status.outcome {
        #expect(
          !FileManager.default.fileExists(
            atPath: store.appendingPathComponent(
              RecoveryOwnerJournal.resultName(reviewed.handle.id)
            ).path))
      } else {
        Issue.record("Unprovable retired release returned \(status.outcome).")
      }
      #expect(status.request.handle == reviewed.handle)
      #expect(try owner.resume(reviewed.handle, principal: principal) == status)
      #expect(try Data(contentsOf: receiptURL) == expectedReceipt)
      #expect(try Data(contentsOf: anchor) == expectedAnchor)
    }
  }

  @Test(arguments: ["sha1", "sha256"])
  func maintenanceReplaysMeasurementAfterLastUnlink(format: String) throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory, format: format)
      let worktrees = try f.service()
      let owner = try ownerService(f)
      let created = try worktrees.create(name: "maintenance")
      let privateGit = PrivateWorktreeGit(
        f: f, topology: try worktrees.topology(projectID: created.projectID))
      _ = try f.privateCommit(worktrees, projectID: created.projectID)
      _ = try worktrees.publish(projectID: created.projectID) { _ in }
      let initial = try #require(owner.list().first)
      guard
        case .reviewed(let zero) = try owner.prepareMaintenance(
          key: initial.key, generation: initial.generation, principal: principal
        )
      else {
        Issue.record("Expected a complete one-pair proof.")
        return
      }
      #expect(zero.packHash == nil)
      let noCandidate = try owner.run(zero, principal: principal)
      guard case .measured(let before) = noCandidate.outcome else {
        Issue.record("Expected a measured zero.")
        return
      }
      #expect(before.reclaimedBytes == 0)

      let blob = try privateGit.run(
        ["hash-object", "-w", "--stdin"], input: Data("standalone".utf8))
      let tree = try privateGit.run(["mktree"], input: Data("100644 blob \(blob)\tvalue\n".utf8))
      try privateGit.run(["update-ref", "refs/tags/tree", tree])
      try privateGit.run(["tag", "-a", "nested", "-m", "inner"])
      try privateGit.run(["tag", "-a", "outer", "-m", "outer", "nested"])
      _ = try worktrees.publish(projectID: created.projectID) { _ in }
      let view = try #require(owner.list().first)
      guard
        case .reviewed(let review) = try owner.prepareMaintenance(
          key: view.key, generation: view.generation, principal: principal
        )
      else {
        Issue.record("Expected a complete redundant-pair proof.")
        return
      }
      let selected = try #require(review.packHash)
      let recoveryGit = try f.recoveryGitDirectory()
      let directory = recoveryGit.appendingPathComponent("objects/pack")
      let active = recoveryGit.deletingLastPathComponent().appendingPathComponent(
        "owner-operation.json")
      let hook = WorktreeJournalIO(beforeDirectorySync: {
        guard let bytes = try? Data(contentsOf: active),
          let operation = try? JSONDecoder().decode(RecoveryOwnerJournal.self, from: bytes),
          operation.maintenance?.phase == .disposing,
          !FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("pack-\(selected).pack").path),
          try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy({
            !$0.hasSuffix(".quarantine")
          })
        else { return }
        throw CancellationError()
      })
      let interrupted = try ownerService(f, journalIO: hook)
      #expect(throws: CancellationError.self) { try interrupted.run(review, principal: principal) }
      #expect(throws: (any Error).self) {
        try worktrees.publish(projectID: created.projectID) { _ in }
      }
      let result = try owner.resume(review.handle, principal: principal)
      guard case .measured(let allocation) = result.outcome else {
        Issue.record("Expected reclaimed allocation after replay, observed \(result.outcome).")
        return
      }
      #expect(allocation.baselineBytes == review.baselineBytes)
      #expect(allocation.reclaimedBytes > 0)
      #expect(allocation.finalBytes + allocation.reclaimedBytes == allocation.baselineBytes)
      #expect(try owner.run(review, principal: principal) == result)
      #expect(try #require(owner.list().first).records == view.records)
      #expect(try f.raw(["--git-dir=" + recoveryGit.path, "cat-file", "-p", blob]) == "standalone")
    }
  }
}

private let principal = "local-app"

private func ownerService(_ fixture: WorktreeFixture, journalIO: WorktreeJournalIO = .init()) throws
  -> WorktreeRecoveryOwnerService
{
  try .init(
    storage: fixture.storage, derived: fixture.store,
    dependencies: FixtureRecoveryDependencies(fixture: fixture), executor: fixture.executor,
    journalIO: journalIO)
}

private struct FixtureRecoveryDependencies: WorktreeRecoveryDependencyReading {
  let store: SQLiteDerivedProjectStore
  let source: DerivedProjectSource

  init(fixture: WorktreeFixture) {
    store = fixture.store
    source = fixture.source
  }

  func recoveryEvidence(
    for repository: WorktreeRepositoryIdentity, sources: Set<DerivedProjectSource>
  )
    throws -> WorktreeRecoveryDependencyEvidence
  {
    try .init(
      registrations: [source], derived: store.records(), protections: store.protectedBranches(),
      unfinishedOperations: [], executions: [])
  }

  func validateRecoveryEvidence(
    _ expected: WorktreeRecoveryDependencyEvidence,
    for repository: WorktreeRepositoryIdentity, sources: Set<DerivedProjectSource>,
    commit: () throws -> Void
  ) throws -> Bool {
    guard try recoveryEvidence(for: repository, sources: sources) == expected else { return false }
    try commit()
    return true
  }
}
