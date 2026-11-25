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
      let input = OwnerChildInput(
        databasePath: f.database.path, source: f.source, principal: fixture.principal,
        request: .release(review), projectID: nil)
      let child = try OwnerChildRunner(directory: directory, input: input)
      let exit = try child.run("interrupt-confirmation", expecting: 71)
      #expect(exit == 71)
      #expect(try child.readPhase("interrupt-confirmation") == "confirmation-published")
      let active = fixture.storeDirectory(view.key).appendingPathComponent("owner-operation.json")
      let journal = try JSONDecoder().decode(
        RecoveryOwnerJournal.self, from: Data(contentsOf: active))
      #expect(journal.request == .release(review))
      #expect(journal.outcome == .pending)
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

  @Test func maintenanceAfterLastUnlinkExcludesAnotherProcessUntilRestart() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let fixture = try OwnerAcceptanceFixture(f)
      let worktrees = try f.service()
      let created = try worktrees.create(name: "maintenance-crash")
      _ = try f.privateCommit(worktrees, projectID: created.projectID)
      _ = try worktrees.publish(projectID: created.projectID) { _ in }
      let git = PrivateWorktreeGit(
        f: f, topology: try worktrees.topology(projectID: created.projectID))
      try git.run(["commit", "--allow-empty", "-m", "shared history"])
      _ = try worktrees.publish(projectID: created.projectID) { _ in }
      let owner = try fixture.service()
      let view = try #require(try owner.list().first)
      guard
        case .reviewed(let review) = try owner.prepareMaintenance(
          key: view.key, generation: view.generation, principal: fixture.principal)
      else {
        Issue.record("Expected a maintenance proof")
        return
      }
      let hash = try #require(review.packHash)
      let input = OwnerChildInput(
        databasePath: f.database.path, source: f.source, principal: fixture.principal,
        request: .maintenance(review), projectID: created.projectID)
      let child = try OwnerChildRunner(directory: directory, input: input)
      #expect(try child.run("interrupt-maintenance", expecting: 71) == 71)
      #expect(try child.readPhase("interrupt-maintenance") == "last-unlink")
      let store = fixture.storeDirectory(view.key)
      let active = store.appendingPathComponent("owner-operation.json")
      let activeBytes = try Data(contentsOf: active)
      let interrupted = try JSONDecoder().decode(RecoveryOwnerJournal.self, from: activeBytes)
      #expect(interrupted.request == .maintenance(review))
      #expect(interrupted.maintenance?.phase == .disposing)
      let resultURL = store.appendingPathComponent(
        RecoveryOwnerJournal.resultName(review.handle.id))
      #expect(!FileManager.default.fileExists(atPath: resultURL.path))
      let catalog = store.appendingPathComponent("catalog.json")
      let catalogBytes = try Data(contentsOf: catalog)
      let packDirectory = store.appendingPathComponent("repository.git/objects/pack")
      let afterUnlink = try ownerPackAllocation(packDirectory)
      let survivingFiles = try ownerPackFiles(packDirectory)
      #expect(!afterUnlink.names.contains("pack-\(hash).pack"))
      #expect(!afterUnlink.names.contains("pack-\(hash).idx"))
      #expect(!afterUnlink.names.contains { $0.hasSuffix(".quarantine") })
      #expect(try child.run("conflicting-publication") == 0)
      #expect(try child.readPhase("conflicting-publication").contains("Recovery maintenance"))
      #expect(try Data(contentsOf: active) == activeBytes)
      #expect(try Data(contentsOf: catalog) == catalogBytes)
      #expect(try ownerPackAllocation(packDirectory).names == afterUnlink.names)
      #expect(try ownerPackFiles(packDirectory) == survivingFiles)
      #expect(!FileManager.default.fileExists(atPath: resultURL.path))
      #expect(try child.run("resume") == 0)
      let first = try child.readStatus("resume")
      guard case .measured(let measurement) = first.outcome else {
        Issue.record("Restart did not measure the disposed pair: \(first.outcome)")
        return
      }
      #expect(first.request == .maintenance(review))
      #expect(measurement.baselineBytes == review.baselineBytes)
      #expect(measurement.finalBytes == afterUnlink.bytes)
      #expect(measurement.reclaimedBytes == review.baselineBytes - afterUnlink.bytes)
      #expect(measurement.reclaimedBytes > 0)
      #expect(try child.run("resume-again") == 0)
      #expect(try child.readStatus("resume-again") == first)
      #expect(!FileManager.default.fileExists(atPath: active.path))
      #expect(FileManager.default.fileExists(atPath: resultURL.path))
      #expect(
        try !ownerPackAllocation(packDirectory).names.contains { $0.hasSuffix(".quarantine") })
      #expect(try ownerPackFiles(packDirectory) == survivingFiles)
      #expect(try #require(owner.list().first).records == view.records)
      let recovery = try f.recoveryGitDirectory()
      for record in view.records {
        #expect(
          try f.raw(["--git-dir=" + recovery.path, "cat-file", "-t", record.oid])
            == record.objectType.rawValue)
      }
    }
  }

  @Test func ownerAcceptanceChildProcess() throws {
    guard let directory = ProcessInfo.processInfo.environment["OWNER_ACCEPTANCE_CHILD_DIRECTORY"],
      let mode = ProcessInfo.processInfo.environment["OWNER_ACCEPTANCE_CHILD_MODE"]
    else { return }
    try runOwnerAcceptanceChild(directory: URL(fileURLWithPath: directory), mode: mode)
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
        let firstReceipt = try locked.releaseReceipt(recordID: first.id)
        let secondReceipt = try locked.releaseReceipt(recordID: second.id)
        #expect(firstReceipt == nil)
        #expect(secondReceipt == nil)
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

private struct OwnerChildInput: Codable, Sendable {
  let databasePath: String
  let source: DerivedProjectSource
  let principal: String
  let request: RecoveryReviewedRequest
  let projectID: String?
}

private struct OwnerChildRunner {
  let directory: URL

  init(directory: URL, input: OwnerChildInput) throws {
    self.directory = directory
    try JSONEncoder().encode(input).write(
      to: directory.appendingPathComponent("owner-child-input.json"))
  }

  func run(_ mode: String, expecting expected: Int32 = 0) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    var arguments = [
      "--testing-library", "swift-testing", "--filter", "ownerAcceptanceChildProcess",
    ]
    if let index = CommandLine.arguments.firstIndex(of: "--test-bundle-path"),
      CommandLine.arguments.indices.contains(index + 1)
    {
      let bundle = CommandLine.arguments[index + 1]
      arguments = ["--test-bundle-path", bundle, bundle] + arguments
    }
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["OWNER_ACCEPTANCE_CHILD_DIRECTORY"] = directory.path
    environment["OWNER_ACCEPTANCE_CHILD_MODE"] = mode
    process.environment = environment
    let log = directory.appendingPathComponent("owner-child-\(mode).log")
    try Data().write(to: log)
    let output = try FileHandle(forWritingTo: log)
    process.standardOutput = output
    process.standardError = output
    try process.run()
    try output.close()
    let deadline = ContinuousClock.now.advanced(by: .seconds(90))
    while process.isRunning && ContinuousClock.now < deadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    if process.isRunning {
      process.terminate()
      let stop = ContinuousClock.now.advanced(by: .seconds(2))
      while process.isRunning && ContinuousClock.now < stop {
        Thread.sleep(forTimeInterval: 0.02)
      }
      if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
      process.waitUntilExit()
      throw OwnerChildFailure.timeout
    }
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == expected else {
      let diagnostics = (try? String(contentsOf: log, encoding: .utf8)) ?? "unavailable"
      throw WorktreeError.commandFailed(
        "Owner child \(mode) exited \(process.terminationStatus), expected \(expected): \(diagnostics)"
      )
    }
    return process.terminationStatus
  }

  func readPhase(_ mode: String) throws -> String {
    try String(
      contentsOf: directory.appendingPathComponent("owner-child-\(mode).phase"), encoding: .utf8)
  }

  func readStatus(_ mode: String) throws -> RecoveryOperationStatus {
    try JSONDecoder().decode(
      RecoveryOperationStatus.self,
      from: Data(contentsOf: directory.appendingPathComponent("owner-child-\(mode).status")))
  }
}

private enum OwnerChildFailure: Error { case timeout, unexpectedMode, didNotInterrupt }

private func runOwnerAcceptanceChild(directory: URL, mode: String) throws {
  let input = try JSONDecoder().decode(
    OwnerChildInput.self,
    from: Data(contentsOf: directory.appendingPathComponent("owner-child-input.json")))
  let store = try SQLiteDerivedProjectStore(
    connection: GatewayDatabaseConnection(path: input.databasePath))
  let storage = try #require(WorktreeStorage(databaseURL: URL(fileURLWithPath: input.databasePath)))
  let active = storage.recovery.appendingPathComponent(
    "stores/\(input.request.handle.storeKey)/owner-operation.json")
  let phase = directory.appendingPathComponent("owner-child-\(mode).phase")
  let journalIO = WorktreeJournalIO(beforeDirectorySync: {
    guard let data = try? Data(contentsOf: active),
      let journal = try? JSONDecoder().decode(RecoveryOwnerJournal.self, from: data),
      journal.request == input.request
    else { return }
    if mode == "interrupt-confirmation" {
      try Data("confirmation-published".utf8).write(to: phase)
      _exit(71)
    }
    if mode == "interrupt-maintenance", journal.maintenance?.phase == .disposing,
      case .maintenance(let review) = input.request, let hash = review.packHash
    {
      let packs = active.deletingLastPathComponent().appendingPathComponent(
        "repository.git/objects/pack")
      let names = try FileManager.default.contentsOfDirectory(atPath: packs.path)
      guard !names.contains("pack-\(hash).pack"), !names.contains("pack-\(hash).idx"),
        !names.contains(where: { $0.hasSuffix(".quarantine") })
      else { return }
      try Data("last-unlink".utf8).write(to: phase)
      _exit(71)
    }
  })
  let service = try WorktreeRecoveryOwnerService(
    storage: storage, derived: store,
    dependencies: OwnerAcceptanceEvidence(source: input.source, store: store),
    executor: WorktreeTestGit(), journalIO: journalIO)
  switch mode {
  case "interrupt-confirmation":
    guard case .release(let review) = input.request else { throw OwnerChildFailure.unexpectedMode }
    _ = try service.confirm(review, principal: input.principal)
    throw OwnerChildFailure.didNotInterrupt
  case "interrupt-maintenance":
    guard case .maintenance(let review) = input.request else {
      throw OwnerChildFailure.unexpectedMode
    }
    _ = try service.run(review, principal: input.principal)
    throw OwnerChildFailure.didNotInterrupt
  case "conflicting-publication":
    do {
      let worktrees = try WorktreeRepository(
        source: input.source, store: store, storage: storage, executor: WorktreeTestGit(),
        registeredProjectRoots: [URL(fileURLWithPath: input.source.root)],
        timeoutMilliseconds: 10_000, maxOutputBytes: 1_048_576, lockTimeout: .seconds(1))
      _ = try worktrees.publish(projectID: #require(input.projectID)) { _ in }
      try Data("admitted".utf8).write(to: phase)
    } catch WorktreeError.busy(let reason) {
      try Data(reason.utf8).write(to: phase)
    }
  case "resume", "resume-again":
    let status = try service.resume(input.request.handle, principal: input.principal)
    try JSONEncoder().encode(status).write(
      to: directory.appendingPathComponent("owner-child-\(mode).status"))
  default: throw OwnerChildFailure.unexpectedMode
  }
}

private func ownerPackFiles(_ directory: URL) throws -> [String: Data] {
  var result: [String: Data] = [:]
  for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
    let url = directory.appendingPathComponent(name)
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw POSIXError(.EIO) }
    var bytes = Data("\(info.st_dev):\(info.st_ino):\(info.st_mode):\(info.st_blocks):".utf8)
    bytes.append(try Data(contentsOf: url))
    result[name] = bytes
  }
  return result
}
