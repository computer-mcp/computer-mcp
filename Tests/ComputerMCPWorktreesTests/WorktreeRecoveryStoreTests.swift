import Foundation
import Testing

@testable import ComputerMCPWorktrees

private struct RecoveryFixture {
  let fixture: WorktreeFixture
  let identity: WorktreeRepositoryIdentity
  let store: WorktreeRecoveryStore
  let key: String
  let path: URL

  init(_ directory: URL) throws {
    fixture = try WorktreeFixture(directory)
    identity = try fixture.service().identity
    store = WorktreeRecoveryStore(storage: fixture.storage)
    key = try WorktreeRecoveryStore.key(for: identity)
    path = fixture.storage.recovery.appendingPathComponent("stores").appendingPathComponent(key)
    try store.withExclusive(repository: identity, create: true) { _ in }
  }

  func record(generation: UUID, operation: UUID) -> WorktreeRecoveryRecord {
    let oid = String(repeating: "a", count: identity.format.hexCount)
    return WorktreeRecoveryRecord(
      id: UUID(), storeGeneration: generation,
      owner: .init(
        source: fixture.source, branchID: UUID(), branch: "refs/heads/feature",
        worktreeID: UUID(), storageGeneration: UUID()),
      oid: oid, objectType: .commit,
      base: .init(ref: "refs/heads/main", oid: oid, history: nil), revision: 1,
      state: .retaining,
      claims: [
        .init(
          id: UUID(), operationID: operation, reason: .publishedReplacement,
          rootOID: oid, capture: nil)
      ], acknowledgements: [], dependencies: [operation])
  }

  func retain(_ locked: WorktreeRecoveryStore.Locked) throws -> WorktreeRecoveryRecord {
    let operation = UUID()
    let initial = record(generation: locked.generation, operation: operation)
    var retained = initial
    retained.revision += 1
    retained.state = .retained
    retained.dependencies = []
    try locked.admit(
      operationID: operation, kind: .publication,
      requestDigest: String(repeating: "b", count: 64), records: [initial],
      completionSteps: [[retained]])
    try locked.advance(operationID: operation, records: [retained], verifyTerminalOutcome: {})
    return retained
  }
}

private func recoverySnapshot(_ root: URL) throws -> [String: Data] {
  let manager = FileManager.default
  let enumerator = try #require(manager.enumerator(at: root, includingPropertiesForKeys: nil))
  var result: [String: Data] = [:]
  for case let url as URL in enumerator {
    let attributes = try manager.attributesOfItem(atPath: url.path)
    let relative = String(url.path.dropFirst(root.path.count))
    let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    let type = attributes[.type] as? FileAttributeType
    let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
    var value = Data("\(String(describing: type)):\(mode):\(inode):\(modified):".utf8)
    if type == .typeRegular { value.append(try Data(contentsOf: url)) }
    result[relative] = value
  }
  return result
}

struct WorktreeRecoveryStoreTests {
  @Test func missingRootListingIsEmptyAndDoesNotCreateAnything() throws {
    try fixture { directory in
      let database = directory.appendingPathComponent("absent/host.sqlite")
      let storage = try #require(WorktreeStorage(databaseURL: database))
      let before = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      #expect(try WorktreeRecoveryStore(storage: storage).list().isEmpty)
      #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == before)
      #expect(!FileManager.default.fileExists(atPath: storage.recovery.path))
    }
  }

  @Test func sourceAbsentReadOnlyListingDoesNotMutateStore() throws {
    try fixture { directory in
      let f = try RecoveryFixture(directory)
      let retained = try f.store.withExclusive(repository: f.identity) { try f.retain($0) }
      try FileManager.default.removeItem(at: f.fixture.repository)
      let root = f.fixture.storage.recovery
      let enumerator = try #require(
        FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
      var directories = [root]
      for case let url as URL in enumerator {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if attributes[.type] as? FileAttributeType == .typeDirectory {
          directories.append(url)
        } else {
          try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        }
      }
      for url in directories.reversed() {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
      }
      defer {
        for url in directories {
          try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
      }
      let before = try recoverySnapshot(root)
      let listed = try f.store.list()
      #expect(listed.count == 1)
      #expect(listed.first?.repository == f.identity)
      #expect(listed.first?.catalog.records == [retained])
      #expect(try recoverySnapshot(root) == before)
      #expect(!FileManager.default.fileExists(atPath: f.fixture.repository.path))
    }
  }

  @Test(arguments: [
    "incomplete", "missing-lock", "directory", "lock", "identity", "repository", "catalog",
    "alternates",
  ])
  func invalidOrReplacedStoreRefusesListing(_ mutation: String) throws {
    try fixture { directory in
      let f = try RecoveryFixture(directory)
      let manager = FileManager.default
      let root = f.fixture.storage.recovery
      switch mutation {
      case "incomplete":
        try manager.removeItem(at: f.path.appendingPathComponent("catalog.json"))
      case "missing-lock":
        try manager.removeItem(at: root.appendingPathComponent("locks/\(f.key).lock"))
      case "directory":
        let original = f.path.appendingPathComponent("staging")
        try manager.moveItem(at: original, to: f.path.appendingPathComponent("old-staging"))
        try manager.createDirectory(at: original, withIntermediateDirectories: false)
      case "lock":
        let lock = root.appendingPathComponent("locks/\(f.key).lock")
        try manager.moveItem(at: lock, to: directory.appendingPathComponent("old.lock"))
        try Data().write(to: lock)
      case "identity":
        let url = f.path.appendingPathComponent("identity.json")
        var object = try #require(
          JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["generation"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
      case "repository":
        let url = f.path.appendingPathComponent("identity.json")
        var object = try #require(
          JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var repository = try #require(object["repository"] as? [String: Any])
        var source = try #require(repository["source"] as? [String: Any])
        source["path"] = directory.appendingPathComponent("other-source").path
        repository["source"] = source
        object["repository"] = repository
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
      case "catalog":
        let url = f.path.appendingPathComponent("catalog.json")
        var object = try #require(
          JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["version"] = 99
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
      default:
        let info = f.path.appendingPathComponent("repository.git/objects/info")
        try manager.createDirectory(at: info, withIntermediateDirectories: false)
        try Data("/outside\n".utf8).write(to: info.appendingPathComponent("alternates"))
      }
      let before = try recoverySnapshot(root)
      do {
        _ = try f.store.list()
        Issue.record("An invalid recovery store was accepted: \(mutation)")
      } catch WorktreeError.recoveryRequired {
      } catch {
        Issue.record("Expected recovery-required for \(mutation), got \(error)")
      }
      #expect(try recoverySnapshot(root) == before)
    }
  }

  @Test func invalidCatalogIdentitiesAndOversizedReservesAreRejected() throws {
    try fixture { directory in
      let f = try RecoveryFixture(directory)
      try f.store.withExclusive(repository: f.identity) { locked in
        let operation = UUID()
        let record = f.record(generation: locked.generation, operation: operation)
        let digest = String(repeating: "b", count: 64)
        let intent = WorktreeRecoveryIntent(
          id: operation, kind: .publication,
          requestDigest: digest, selections: [record.selection], completion: .init())
        var catalog = WorktreeRecoveryCatalog(
          generation: locked.generation,
          records: [record], intents: [intent])
        try catalog.validate(repository: f.identity, generation: locked.generation, byteCount: 0)
        catalog.records.append(record)
        #expect(throws: WorktreeError.self) {
          try catalog.validate(repository: f.identity, generation: locked.generation, byteCount: 0)
        }
        catalog.records.removeLast()
        catalog.intents[0].completion.bytes = WorktreeRecoveryCatalog.byteLimit + 1
        #expect(throws: WorktreeError.self) {
          try catalog.validate(repository: f.identity, generation: locked.generation, byteCount: 0)
        }
        catalog.intents[0].completion.bytes = 0
        catalog.intents[0].completion.references = WorktreeRecoveryCatalog.referenceLimit + 1
        #expect(throws: WorktreeError.self) {
          try catalog.validate(repository: f.identity, generation: locked.generation, byteCount: 0)
        }
      }
    }
  }

  @Test func reserveRejectsUnplannedGrowthWithoutChangingCatalog() throws {
    try fixture { directory in
      let f = try RecoveryFixture(directory)
      try f.store.withExclusive(repository: f.identity) { locked in
        let operation = UUID()
        let initial = f.record(generation: locked.generation, operation: operation)
        try locked.admit(
          operationID: operation, kind: .publication,
          requestDigest: String(repeating: "b", count: 64), records: [initial], completionSteps: [])
        let before = try locked.catalog()
        var grown = initial
        grown.revision += 1
        grown.claims.append(
          .init(
            id: UUID(), operationID: operation, reason: .publishedReplacement,
            rootOID: initial.oid, capture: nil))
        #expect(throws: WorktreeError.self) {
          try locked.advance(operationID: operation, records: [grown])
        }
        #expect(try locked.catalog() == before)
      }
    }
  }

  @Test func releaseReceiptReplaysExactlyAndReleasedIDCannotBeReadmitted() throws {
    try fixture { directory in
      let f = try RecoveryFixture(directory)
      try f.store.withExclusive(repository: f.identity) { locked in
        let record = try f.retain(locked)
        let operation = UUID()
        let digest = String(repeating: "c", count: 64)
        let receipt = WorktreeRecoveryReleaseReceipt(
          storeGeneration: locked.generation,
          owner: record.owner, selection: record.selection, operationID: operation,
          requestDigest: digest,
          selectionDigest: try WorktreeRecoveryReleaseReceipt.digest(of: [record.selection]))
        try locked.prepareRelease([receipt])
        try locked.prepareRelease([receipt])
        var verified = 0
        try locked.finishRelease([receipt]) { verified += 1 }
        #expect(verified == 1)
        #expect(try locked.releaseReceipt(recordID: record.id) == receipt)
        #expect(try locked.catalog().records.isEmpty)
        try locked.prepareRelease([receipt])
        try locked.finishRelease([receipt]) { verified += 1 }
        #expect(verified == 1)
        let wrong = WorktreeRecoveryReleaseReceipt(
          storeGeneration: locked.generation,
          owner: record.owner, selection: record.selection, operationID: operation,
          requestDigest: String(repeating: "d", count: 64), selectionDigest: receipt.selectionDigest
        )
        #expect(throws: WorktreeError.self) { try locked.prepareRelease([wrong]) }
        var reused = record
        let newOperation = UUID()
        reused.revision = 1
        reused.state = .retaining
        reused.dependencies = [newOperation]
        #expect(throws: WorktreeError.self) {
          try locked.admit(
            operationID: newOperation, kind: .publication,
            requestDigest: digest, records: [reused], completionSteps: [])
        }
        #expect(try locked.releaseReceipt(recordID: record.id) == receipt)
        #expect(try locked.catalog().records.isEmpty)
      }
    }
  }
}
