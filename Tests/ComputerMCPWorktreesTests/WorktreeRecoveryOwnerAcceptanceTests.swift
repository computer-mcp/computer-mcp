import ComputerMCPPersistence
import Foundation
import Testing

@testable import ComputerMCPWorktrees

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

struct WorktreeRecoveryOwnerAcceptanceTests {
  @Test func readOnlyReviewAndUnsubmittedLookupDoNotCreateFiles() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let owner = try OwnerAcceptanceFixture(f)
      let before = try owner.snapshot()
      #expect(try owner.service().list().isEmpty)
      #expect(try owner.snapshot() == before)

      let record = try owner.captureBlob()
      let service = try owner.service()
      let view = try #require(try service.list().first)
      let captured = try owner.snapshot()
      let review = try service.reviewRelease(
        key: view.key, generation: view.generation, selections: [record.selection],
        principal: owner.principal)
      guard case .unsubmitted = try service.operation(review.handle, principal: owner.principal)
      else {
        Issue.record("A review alone submitted an operation")
        return
      }
      #expect(throws: WorktreeRecoveryOwnerError.unsubmitted) {
        try service.resume(review.handle, principal: owner.principal)
      }
      #expect(try owner.snapshot() == captured)
    }
  }

  @Test func interruptedConfirmationReopensAndKeepsItsIdentity() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let owner = try OwnerAcceptanceFixture(f)
      let record = try owner.captureBlob()
      let normal = try owner.service()
      let view = try #require(try normal.list().first)
      let review = try normal.reviewRelease(
        key: view.key, generation: view.generation, selections: [record.selection],
        principal: owner.principal)
      let active = owner.storeDirectory(view.key).appendingPathComponent("owner-operation.json")
      let interruption = OwnerConfirmationInterruption(active: active)
      let interrupted = try owner.service(
        io: .init(beforeDirectorySync: { try interruption.check() }))
      #expect(throws: OwnerConfirmationInterruption.Failure.self) {
        try interrupted.confirm(review, principal: owner.principal)
      }
      #expect(interruption.fired)
      let reopened = try owner.service()
      guard
        case .submitted(let pending) = try reopened.operation(
          review.handle, principal: owner.principal)
      else {
        Issue.record("Visible confirmation was not found after reopening")
        return
      }
      #expect(pending.request == .release(review))
      #expect(pending.outcome == .pending)
      let wrongDigest = RecoveryOperationHandle(
        storeKey: review.handle.storeKey, generation: review.handle.generation,
        action: review.handle.action, id: review.handle.id,
        requestDigest: String(repeating: "a", count: 64))
      #expect(throws: WorktreeRecoveryOwnerError.identityConflict) {
        try reopened.operation(wrongDigest, principal: owner.principal)
      }
      let wrongAction = RecoveryOperationHandle(
        storeKey: review.handle.storeKey, generation: review.handle.generation,
        action: .maintenance, id: review.handle.id, requestDigest: review.handle.requestDigest)
      let wrongGeneration = RecoveryOperationHandle(
        storeKey: review.handle.storeKey, generation: UUID(), action: review.handle.action,
        id: review.handle.id, requestDigest: review.handle.requestDigest)
      #expect(throws: WorktreeRecoveryOwnerError.identityConflict) {
        try reopened.operation(wrongAction, principal: owner.principal)
      }
      #expect(throws: WorktreeRecoveryOwnerError.storeChanged) {
        try reopened.operation(wrongGeneration, principal: owner.principal)
      }
      #expect(throws: WorktreeRecoveryOwnerError.identityConflict) {
        try reopened.resume(review.handle, principal: "another-owner")
      }
      let result = try reopened.resume(review.handle, principal: owner.principal)
      #expect(result.request == .release(review))
      #expect(result.outcome == .released)
      #expect(!result.gates.contains { $0.cleanup == .pending })
      #expect(try reopened.resume(review.handle, principal: owner.principal) == result)
      #expect(try !f.recoveryRecords().contains { $0.id == record.id })
      let receiptURL = owner.storeDirectory(view.key).appendingPathComponent(
        "released/" + record.id.uuidString.lowercased() + ".json")
      let receipt = try JSONDecoder().decode(
        WorktreeRecoveryReleaseReceipt.self, from: Data(contentsOf: receiptURL))
      #expect(receipt.operationID == review.handle.id)
      #expect(receipt.selection == record.selection)
      #expect(receipt.owner == record.owner)
      #expect(receipt.requestDigest == review.handle.requestDigest)
    }
  }

  @Test func confirmationInterruptedInAnotherProcessResumesFromFileBackedState() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let fixture = try OwnerAcceptanceFixture(f)
      let record = try fixture.captureBlob()
      let owner = try fixture.service()
      let view = try #require(try owner.list().first)
      let review = try owner.reviewRelease(
        key: view.key, generation: view.generation, selections: [record.selection],
        principal: fixture.principal)
      let active = fixture.storeDirectory(view.key).appendingPathComponent("owner-operation.json")
      let child = fork()
      guard child >= 0 else { throw POSIXError(.EAGAIN) }
      if child == 0 {
        do {
          let store = try SQLiteDerivedProjectStore(
            connection: GatewayDatabaseConnection(path: f.database.path))
          let interruption = OwnerConfirmationInterruption(active: active)
          let service = try WorktreeRecoveryOwnerService(
            storage: f.storage, derived: store,
            dependencies: OwnerAcceptanceEvidence(source: f.source, store: store),
            executor: WorktreeTestGit(),
            journalIO: .init(beforeDirectorySync: { try interruption.check() }))
          do {
            _ = try service.confirm(review, principal: fixture.principal)
            _exit(2)
          } catch is OwnerConfirmationInterruption.Failure {
            _exit(interruption.fired ? 0 : 3)
          } catch {
            _exit(4)
          }
        } catch {
          _exit(5)
        }
      }
      var status: Int32 = 0
      let deadline = ContinuousClock.now.advanced(by: .seconds(30))
      var waited: pid_t = 0
      while waited == 0 && ContinuousClock.now < deadline {
        waited = waitpid(child, &status, WNOHANG)
        if waited == 0 { Thread.sleep(forTimeInterval: 0.01) }
      }
      if waited == 0 {
        _ = kill(child, SIGKILL)
        _ = waitpid(child, &status, 0)
        Issue.record("Child confirmation exceeded its deadline")
        return
      }
      guard waited == child, status == 0 else {
        Issue.record("Child confirmation failed, wait status: \(status)")
        return
      }
      guard
        case .submitted(let pending) = try owner.operation(
          review.handle, principal: fixture.principal)
      else {
        Issue.record("Child did not publish confirmation")
        return
      }
      #expect(pending.outcome == .pending)
      let result = try owner.resume(review.handle, principal: fixture.principal)
      #expect(result.outcome == .released)
      #expect(result.request == .release(review))
      #expect(try !f.recoveryRecords().contains { $0.id == record.id })
      let receipt = fixture.storeDirectory(view.key).appendingPathComponent(
        "released/" + record.id.uuidString.lowercased() + ".json")
      let decoded = try JSONDecoder().decode(
        WorktreeRecoveryReleaseReceipt.self, from: Data(contentsOf: receipt))
      #expect(decoded.operationID == review.handle.id)
      #expect(decoded.selection == record.selection)
    }
  }

  @Test(arguments: [false, true])
  func deletionReceiptMustMatchItsFrozenSelection(contradictory: Bool) async throws {
    try await removalFixture { f in
      let fixture = try OwnerAcceptanceFixture(f)
      let worktrees = try f.service()
      let created = try worktrees.create(name: "foreign-deletion")
      let git = PrivateWorktreeGit(
        f: f, topology: try worktrees.topology(projectID: created.projectID))
      let blob = try f.raw(["rev-parse", "HEAD:file.txt"])
      try git.run(["update-ref", "refs/tags/base-blob", blob])
      try git.run(["tag", "-a", "independent", "-m", "independent root"])
      let tag = try git.run(["rev-parse", "refs/tags/independent"])
      _ = try await worktrees.remove(
        projectID: created.projectID, terminate: { _, _ in }, authorize: { _, _ in })
      let owner = try fixture.service()
      let view = try #require(try owner.list().first)
      let retired = try #require(view.records.first { $0.oid == blob })
      let survivor = try #require(view.records.first { $0.oid == tag })
      let review = try owner.reviewRelease(
        key: view.key, generation: view.generation,
        selections: [retired.selection, survivor.selection], principal: fixture.principal)
      #expect(
        try worktrees.deleteBranch(
          created.branch, authority: .sandbox, dryRun: false, confirm: true
        ) { _ in }.deleted)
      let receiptURL = fixture.storeDirectory(view.key).appendingPathComponent(
        "released/" + retired.id.uuidString.lowercased() + ".json")
      let original = try Data(contentsOf: receiptURL)
      if contradictory {
        var receipt = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        receipt["requestDigest"] = String(repeating: "f", count: 64)
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]).write(
          to: receiptURL)
      }
      let expectedReceipt = try Data(contentsOf: receiptURL)
      let anchor = fixture.storeDirectory(view.key).appendingPathComponent(
        "repository.git/refs/recovery/" + survivor.id.uuidString.lowercased())
      let anchorBytes = try Data(contentsOf: anchor)
      let status = try owner.confirm(review, principal: fixture.principal)
      if contradictory {
        guard case .recoveryRequired = status.outcome else {
          Issue.record("Contradictory D5 receipt was accepted: \(status.outcome)")
          return
        }
      } else {
        #expect(status.outcome == .stale)
      }
      #expect(status.request == .release(review))
      #expect(try Data(contentsOf: receiptURL) == expectedReceipt)
      #expect(try Data(contentsOf: anchor) == anchorBytes)
      #expect(try f.recoveryRecords().contains { $0.id == survivor.id })
      #expect(
        !FileManager.default.fileExists(
          atPath: fixture.storeDirectory(view.key)
            .appendingPathComponent("released/" + survivor.id.uuidString.lowercased() + ".json")
            .path))
    }
  }

  @Test(arguments: ["sha1", "sha256"])
  func maintenanceMeasuresOneRedundantPairAndKeepsRealObjects(format: String) throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory, format: format)
      let fixture = try OwnerAcceptanceFixture(f)
      let worktrees = try f.service()
      let created = try worktrees.create(name: "measured-packs")
      _ = try f.privateCommit(worktrees, projectID: created.projectID)
      _ = try worktrees.publish(projectID: created.projectID) { _ in }
      let git = PrivateWorktreeGit(
        f: f, topology: try worktrees.topology(projectID: created.projectID))
      try git.run(["commit", "--allow-empty", "-m", "shared history"])
      _ = try worktrees.publish(projectID: created.projectID) { _ in }
      let owner = try fixture.service()
      let view = try #require(try owner.list().first)
      let recovery = try f.recoveryGitDirectory()
      let packDirectory = recovery.appendingPathComponent("objects/pack")
      let before = try ownerPackAllocation(packDirectory)
      guard
        case .reviewed(let review) = try owner.prepareMaintenance(
          key: view.key, generation: view.generation, principal: fixture.principal)
      else {
        Issue.record("Expected a maintenance proof")
        return
      }
      let hash = try #require(review.packHash)
      #expect(review.baselineBytes == before.bytes)
      let result = try owner.run(review, principal: fixture.principal)
      guard case .measured(let measured) = result.outcome else {
        Issue.record("Expected measured reclamation: \(result.outcome)")
        return
      }
      let after = try ownerPackAllocation(packDirectory)
      #expect(measured.baselineBytes == before.bytes)
      #expect(measured.finalBytes == after.bytes)
      #expect(measured.reclaimedBytes == before.bytes - after.bytes)
      #expect(measured.reclaimedBytes > 0)
      #expect(before.names.subtracting(after.names) == ["pack-\(hash).pack", "pack-\(hash).idx"])
      #expect(after.names.subtracting(before.names).isEmpty)
      #expect(try #require(owner.list().first).records == view.records)
      for record in view.records {
        let anchor = recovery.appendingPathComponent(
          "refs/recovery/" + record.id.uuidString.lowercased())
        #expect(try Data(contentsOf: anchor) == Data((record.oid + "\n").utf8))
        #expect(
          try f.raw(["--git-dir=" + recovery.path, "cat-file", "-t", record.oid])
            == record.objectType.rawValue)
      }
      #expect(try owner.resume(review.handle, principal: fixture.principal) == result)
    }
  }

  @Test func unexplainedMissingReceiptRequiresRecoveryAndPreservesSurvivor() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let owner = try OwnerAcceptanceFixture(f)
      let first = try owner.captureBlob()
      let second = try owner.captureBlob(content: "second independent blob")
      let service = try owner.service()
      let view = try #require(try service.list().first)
      let review = try service.reviewRelease(
        key: view.key, generation: view.generation,
        selections: [first.selection, second.selection], principal: owner.principal)
      let foreignID = UUID()
      let foreign = try WorktreeRecoveryReleaseReceipt.batch(
        for: [first], operationID: foreignID, requestDigest: String(repeating: "b", count: 64))
      let store = WorktreeRecoveryStore(storage: f.storage)
      try store.withExclusive(repository: view.repository) { locked in
        try locked.prepareRelease(foreign)
        try locked.releaseAnchors(foreign, verifyAuthority: {})
      }
      let foreignReceipt = owner.storeDirectory(view.key).appendingPathComponent(
        "released/" + first.id.uuidString.lowercased() + ".json")
      try FileManager.default.removeItem(at: foreignReceipt)
      let survivorAnchor = owner.storeDirectory(view.key).appendingPathComponent(
        "repository.git/refs/recovery/" + second.id.uuidString.lowercased())
      let survivorBytes = try Data(contentsOf: survivorAnchor)
      let status = try service.confirm(review, principal: owner.principal)
      guard case .recoveryRequired = status.outcome else {
        Issue.record("Missing retirement evidence did not require recovery: \(status.outcome)")
        return
      }
      #expect(status.request == .release(review))
      #expect(try Data(contentsOf: survivorAnchor) == survivorBytes)
      #expect(try f.recoveryRecords().contains(second))
      try store.withExclusive(repository: view.repository) { locked in
        #expect(try locked.releaseReceipt(recordID: first.id) == nil)
        #expect(try locked.releaseReceipt(recordID: second.id) == nil)
      }
    }
  }
}

private struct OwnerAcceptanceFixture {
  let f: WorktreeFixture
  let principal = "test-local-app-owner"

  init(_ f: WorktreeFixture) throws { self.f = f }

  func service(io: WorktreeJournalIO = .init()) throws -> WorktreeRecoveryOwnerService {
    try .init(
      storage: f.storage, derived: f.store,
      dependencies: OwnerAcceptanceEvidence(source: f.source, store: f.store),
      executor: f.executor, journalIO: io)
  }

  func captureBlob(content: String = "independent blob") throws -> WorktreeRecoveryRecord {
    let repository = try f.service()
    let created = try repository.create(name: "owner-" + UUID().uuidString.lowercased())
    let git = PrivateWorktreeGit(
      f: f, topology: try repository.topology(projectID: created.projectID))
    let oid = try git.run(["hash-object", "-w", "--stdin"], input: Data(content.utf8))
    try git.run(["update-ref", "refs/tags/owner-blob", oid])
    _ = try repository.publish(projectID: created.projectID) { _ in }
    return try #require(try f.recoveryRecords().first { $0.oid == oid })
  }

  func storeDirectory(_ key: String) -> URL {
    f.storage.recovery.appendingPathComponent("stores/" + key)
  }

  func snapshot() throws -> [String: Data] {
    let root = f.directory
    let enumerator = try #require(
      FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
    var result: [String: Data] = [:]
    for case let url as URL in enumerator {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      let type = attributes[.type] as? FileAttributeType
      let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
      var value = Data("\(String(describing: type)):\(inode):".utf8)
      if type == .typeRegular { value.append(try Data(contentsOf: url)) }
      result[String(url.path.dropFirst(root.path.count))] = value
    }
    return result
  }
}

private struct OwnerAcceptanceEvidence: WorktreeRecoveryDependencyReading {
  let source: DerivedProjectSource
  let store: SQLiteDerivedProjectStore

  func recoveryEvidence(
    for repository: WorktreeRepositoryIdentity, sources: Set<DerivedProjectSource>
  ) throws -> WorktreeRecoveryDependencyEvidence {
    .init(
      registrations: sources.contains(source) ? [source] : [], derived: try store.records(),
      protections: try store.protectedBranches(), unfinishedOperations: [], executions: [])
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

private final class OwnerConfirmationInterruption: @unchecked Sendable {
  enum Failure: Error { case injected }
  let active: URL
  private(set) var fired = false

  init(active: URL) { self.active = active }

  func check() throws {
    if !fired && FileManager.default.fileExists(atPath: active.path) {
      fired = true
      throw Failure.injected
    }
  }
}

private func ownerPackAllocation(_ directory: URL) throws -> (names: Set<String>, bytes: Int64) {
  let names = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
  var bytes: Int64 = 0
  for name in names where name.hasSuffix(".pack") || name.hasSuffix(".idx") {
    var info = stat()
    guard lstat(directory.appendingPathComponent(name).path, &info) == 0 else {
      throw POSIXError(.EIO)
    }
    bytes += Int64(info.st_blocks) * 512
  }
  return (names, bytes)
}
