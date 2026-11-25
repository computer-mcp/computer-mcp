import ComputerMCPPersistence
import Foundation
import Testing

@testable import ComputerMCPWorktrees

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
      #expect(!result.gateCleanup.contains(.pending))
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
