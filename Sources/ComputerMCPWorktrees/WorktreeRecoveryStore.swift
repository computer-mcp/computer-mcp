import ComputerMCPPlatformPOSIX
import Foundation

struct WorktreeRecoveryStore {
  let storage: WorktreeStorage
  var io = WorktreeJournalIO()

  struct Snapshot {
    let repository: WorktreeRepositoryIdentity
    let catalog: WorktreeRecoveryCatalog
  }

  static func key(for repository: WorktreeRepositoryIdentity) throws -> String {
    try repository.validateRecoveryIdentity()
    struct KeyInput: Encodable {
      let version = 1
      let repository: WorktreeRepositoryIdentity
    }
    return WorktreeObjectSnapshot.digest(try recoveryJSON(KeyInput(repository: repository)))
  }

  func list() throws -> [Snapshot] {
    guard let root = try rootIfPresent() else { return [] }
    return try reading {
      let layout = try Layout(root)
      let keys = try layout.storeKeys()
      let snapshots = try keys.map { key in
        let lock = try FileLock(sharingExisting: layout.lockPath(key))
        let opened = try open(key, layout: layout, lock: lock)
        let catalog = try opened.readCatalog().catalog
        try opened.verify()
        return Snapshot(repository: opened.identity.repository, catalog: catalog)
      }
      try layout.verify()
      return snapshots
    }
  }

  func withExclusive<Result>(
    repository: WorktreeRepositoryIdentity, create: Bool = false,
    _ operation: (Locked) throws -> Result
  ) throws -> Result {
    let key = try Self.key(for: repository)
    let layout: Layout
    if let existing = try rootIfPresent() {
      layout = try Layout(existing)
    } else {
      guard create else { throw invalidRecoveryMetadata() }
      try repository.verify()
      let root = try WorktreeDirectory(storage.base).child(
        storage.recovery.lastPathComponent, create: true, exclusive: true)
      layout = try Layout(root, create: true)
    }
    let lockPath = layout.lockPath(key)
    let lock: FileLock
    if try layout.locks.hasEntry(key + ".lock") {
      lock = try FileLock(lockingExisting: lockPath)
    } else {
      guard create, try !layout.stores.hasEntry(key),
        try !layout.locks.hasEntry(layout.intentName(key))
      else { throw invalidRecoveryMetadata() }
      try repository.verify()
      lock = try FileLock.createExclusive(path: lockPath)
      try layout.locks.synchronize()
      let intent = CreationIntent(
        repository: repository, generation: UUID(), lock: try lock.identity(),
        layout: layout.identities)
      try io.write(
        recoveryJSON(intent), name: layout.intentName(key), in: layout.locks, replacing: nil)
    }
    defer { lock.release() }
    if create, try layout.locks.hasEntry(layout.intentName(key)) {
      try repository.verify()
      try resumeCreation(key, repository: repository, layout: layout, lock: lock)
    }
    let opened = try open(key, layout: layout, lock: lock)
    guard opened.identity.repository == repository else { throw invalidRecoveryMetadata() }
    // A visible removal of the creation intent may follow a failed directory sync.
    try layout.locks.synchronize()
    try opened.verify()
    return try operation(Locked(opened: opened))
  }

  private func rootIfPresent() throws -> WorktreeDirectory? {
    do {
      return try WorktreeDirectory(storage.recovery)
    } catch let error as POSIXError where error.code == .ENOENT {
      return nil
    } catch {
      throw WorktreeError.recoveryRequired("Recovery storage is unavailable.")
    }
  }

  private func reading<Result>(_ body: () throws -> Result) throws -> Result {
    do {
      return try body()
    } catch FileLockError.held {
      throw WorktreeError.busy("Recovery store is in use.")
    } catch {
      throw WorktreeError.recoveryRequired("Recovery storage is unavailable or inconsistent.")
    }
  }

  private func open(_ key: String, layout: Layout, lock: FileLock) throws -> OpenStore {
    try layout.verify()
    try lock.verifyIdentity()
    guard try !layout.locks.hasEntry(layout.intentName(key)) else {
      throw invalidRecoveryMetadata()
    }
    let directories = try StoreDirectories(layout: layout, key: key)
    guard let bytes = try io.read("identity.json", in: directories.store, limit: Self.identityLimit)
    else { throw invalidRecoveryMetadata() }
    let identity = try JSONDecoder().decode(StoreIdentity.self, from: bytes)
    guard identity.version == 1, try Self.key(for: identity.repository) == key,
      identity.layout == layout.identities, identity.directories == directories.identities,
      try identity.lock == lock.identity()
    else { throw invalidRecoveryMetadata() }
    let opened = OpenStore(
      layout: layout, directories: directories, lock: lock, identity: identity,
      identityBytes: bytes, io: io)
    try opened.verify()
    return opened
  }

  private static let identityLimit = 128 * 1024

  private func resumeCreation(
    _ key: String, repository: WorktreeRepositoryIdentity, layout: Layout, lock: FileLock
  ) throws {
    let name = layout.intentName(key)
    guard var bytes = try io.read(name, in: layout.locks, limit: Self.identityLimit)
    else { throw invalidRecoveryMetadata() }
    var intent = try JSONDecoder().decode(CreationIntent.self, from: bytes)
    guard intent.version == 1, intent.repository == repository,
      intent.layout == layout.identities, try intent.lock == lock.identity()
    else { throw invalidRecoveryMetadata() }
    try io.synchronize(name, in: layout.locks, expecting: bytes)
    var directoryIndex = 0
    func directory(_ nameInParent: String, in parent: WorktreeDirectory) throws -> WorktreeDirectory
    {
      try layout.verify()
      try lock.verifyIdentity()
      defer { directoryIndex += 1 }
      if directoryIndex < intent.directories.count {
        let existing = try parent.child(nameInParent)
        guard existing.identity == intent.directories[directoryIndex] else {
          throw invalidRecoveryMetadata()
        }
        return existing
      }
      guard try !parent.hasEntry(nameInParent) else { throw invalidRecoveryMetadata() }
      let created = try parent.child(nameInParent, create: true, exclusive: true)
      intent.directories.append(created.identity)
      let next = try recoveryJSON(intent)
      guard next.count <= Self.identityLimit else { throw invalidRecoveryMetadata() }
      try io.write(next, name: name, in: layout.locks, replacing: bytes)
      bytes = next
      return created
    }
    let store = try directory(key, in: layout.stores)
    let git = try directory("repository.git", in: store)
    _ = try directory("objects", in: git)
    _ = try directory("refs", in: git)
    _ = try directory("staging", in: store)
    _ = try directory("released", in: store)
    let directories = try StoreDirectories(layout: layout, key: key)
    guard intent.directories == directories.identities else { throw invalidRecoveryMetadata() }

    let identity = StoreIdentity(
      repository: repository, generation: intent.generation, lock: intent.lock,
      layout: layout.identities, directories: directories.identities)
    let identityBytes = try recoveryJSON(identity)
    guard identityBytes.count <= Self.identityLimit else { throw invalidRecoveryMetadata() }
    try publishCreationFile(Self.config(repository.format), name: "config", in: git)
    try publishCreationFile(Self.head, name: "HEAD", in: git)
    try publishCreationFile(identityBytes, name: "identity.json", in: store)
    try publishCreationFile(
      recoveryJSON(WorktreeRecoveryCatalog(generation: intent.generation)), name: "catalog.json",
      in: store)
    try OpenStore(
      layout: layout, directories: directories, lock: lock, identity: identity,
      identityBytes: identityBytes, io: io
    ).verify()
    try io.remove(name, in: layout.locks, expecting: bytes)
  }

  private func publishCreationFile(
    _ content: Data, name: String, in directory: WorktreeDirectory
  ) throws {
    if let current = try io.read(name, in: directory, limit: content.count) {
      guard current == content else { throw invalidRecoveryMetadata() }
      try io.synchronize(name, in: directory, expecting: content)
    } else {
      try io.write(content, name: name, in: directory, replacing: nil)
    }
  }

  private static let head = Data("ref: refs/heads/main\n".utf8)

  private static func config(_ format: WorktreeObjectFormat) -> Data {
    let version = format == .sha256 ? 1 : 0
    let extensionConfig = format == .sha256 ? "[extensions]\n\tobjectFormat = sha256\n" : ""
    return Data(
      ("[core]\n\trepositoryFormatVersion = \(version)\n\tbare = true\n\tlogAllRefUpdates = false\n"
        + "[gc]\n\tauto = 0\n[maintenance]\n\tauto = false\n" + extensionConfig).utf8)
  }
}

extension WorktreeRecoveryStore {
  struct Locked {
    fileprivate let opened: OpenStore

    var generation: UUID { opened.identity.generation }

    func catalog() throws -> WorktreeRecoveryCatalog { try durableCatalog().catalog }

    /// New record IDs are admitted in their retaining state. Completion steps can
    /// advance those records, but need no additional record slots.
    func admit(
      operationID: UUID, kind: WorktreeRecoveryIntent.Kind, requestDigest: String,
      records: [WorktreeRecoveryRecord], completionSteps: [[WorktreeRecoveryRecord]]
    ) throws {
      let previous = try durableCatalog()
      guard kind != .release, requestDigest.isRecoveryDigest, !records.isEmpty
      else { throw invalidRecoveryMetadata() }
      var next = previous.catalog
      let indices = recordIndices(next)
      let changes = try uniqueRecords(records)
      let reserve = try completionReserve(from: changes, steps: completionSteps)
      let intent = WorktreeRecoveryIntent(
        id: operationID, kind: kind, requestDigest: requestDigest,
        selections: records.map(\.selection), completion: reserve)
      if let existing = next.intents.first(where: { $0.id == operationID }) {
        guard existing == intent,
          records.allSatisfy({ record in
            indices[record.id].map { next.records[$0] == record } == true
          })
        else { throw invalidRecoveryMetadata() }
        return
      }
      for record in records {
        if let index = indices[record.id] {
          let old = next.records[index]
          guard old.state == .retained, record.state == .retained, record.follows(old),
            Set(record.dependencies) == Set(old.dependencies).union([operationID])
          else { throw invalidRecoveryMetadata() }
          next.records[index] = record
        } else {
          guard record.state == .retaining, record.revision == 1,
            record.dependencies == [operationID], try releaseReceipt(recordID: record.id) == nil
          else { throw invalidRecoveryMetadata() }
          next.records.append(record)
        }
      }
      next.intents.append(intent)
      try write(next, replacing: previous.bytes)
    }

    private func completionReserve(
      from records: [UUID: WorktreeRecoveryRecord], steps: [[WorktreeRecoveryRecord]]
    ) throws -> WorktreeRecoveryGrowth {
      var projection = records
      var reserve = WorktreeRecoveryGrowth()
      for step in steps {
        for record in try uniqueRecords(step).values {
          guard let old = projection[record.id], record.follows(old), record.state != .releasing
          else { throw invalidRecoveryMetadata() }
          try record.validate(repository: opened.identity.repository, generation: generation)
          try reserve.add(.increase(from: old, to: record))
          projection[record.id] = record
        }
      }
      return reserve
    }

    func advance(
      operationID: UUID, records: [WorktreeRecoveryRecord],
      verifyTerminalOutcome: (() throws -> Void)? = nil
    ) throws {
      let previous = try durableCatalog()
      var next = previous.catalog
      guard let intentIndex = next.intents.firstIndex(where: { $0.id == operationID }),
        next.intents[intentIndex].kind != .release
      else { throw invalidRecoveryMetadata() }
      let selected = Set(next.intents[intentIndex].selections.map(\.recordID))
      let updates = try uniqueRecords(records)
      guard Set(updates.keys).isSubset(of: selected),
        verifyTerminalOutcome == nil || Set(updates.keys) == selected
      else { throw invalidRecoveryMetadata() }
      let indices = recordIndices(next)
      var growth = WorktreeRecoveryGrowth()
      for (id, update) in updates {
        guard let index = indices[id] else { throw invalidRecoveryMetadata() }
        let old = next.records[index]
        if old == update, verifyTerminalOutcome == nil { continue }
        var dependencies = Set(old.dependencies)
        if verifyTerminalOutcome != nil { dependencies.remove(operationID) }
        guard update.follows(old), old.state != .releasing, update.state != .releasing,
          old.state == .retaining || update.state == .retained,
          Set(update.dependencies) == dependencies
        else { throw invalidRecoveryMetadata() }
        try growth.add(.increase(from: old, to: update))
        next.records[index] = update
      }
      try next.intents[intentIndex].completion.consume(growth)
      if let verifyTerminalOutcome {
        try verifyTerminalOutcome()
        next.intents.remove(at: intentIndex)
      }
      try write(next, replacing: previous.bytes)
    }

    func releaseReceipt(recordID: UUID) throws -> WorktreeRecoveryReleaseReceipt? {
      try opened.verify()
      guard
        let data = try opened.io.read(
          receiptName(recordID), in: opened.directories.released,
          limit: WorktreeRecoveryReleaseReceipt.byteLimit)
      else { return nil }
      let receipt = try JSONDecoder().decode(WorktreeRecoveryReleaseReceipt.self, from: data)
      try receipt.validate(
        repository: opened.identity.repository, generation: generation, recordID: recordID)
      return receipt
    }

    func prepareRelease(_ receipts: [WorktreeRecoveryReleaseReceipt]) throws {
      let batch = try releaseBatch(receipts)
      let previous = try durableCatalog()
      var next = previous.catalog
      if try releaseIsArchived(batch, catalog: next) { return }
      if let intent = next.intents.first(where: { $0.id == batch.operationID }) {
        try requireRelease(batch, intent: intent, catalog: next)
        return
      }
      let indices = recordIndices(next)
      for item in batch.items {
        let receipt = item.receipt
        let id = receipt.selection.recordID
        guard let index = indices[id], try releaseReceipt(recordID: id) == nil
        else { throw invalidRecoveryMetadata() }
        var record = next.records[index]
        guard record.selection == receipt.selection, record.owner == receipt.owner,
          record.state == .retained, record.dependencies.isEmpty
        else { throw invalidRecoveryMetadata() }
        record.state = .releasing
        record.revision += 1
        record.dependencies = [batch.operationID]
        next.records[index] = record
      }
      next.intents.append(
        .init(
          id: batch.operationID, kind: .release, requestDigest: batch.digest,
          selections: batch.items.map(\.receipt.selection), completion: .init()))
      try write(next, replacing: previous.bytes)
    }

    func finishRelease(
      _ receipts: [WorktreeRecoveryReleaseReceipt], verifyAnchorsRemoved: () throws -> Void
    ) throws {
      let batch = try releaseBatch(receipts)
      let previous = try durableCatalog()
      var next = previous.catalog
      if try releaseIsArchived(batch, catalog: next) { return }
      guard let index = next.intents.firstIndex(where: { $0.id == batch.operationID })
      else { throw invalidRecoveryMetadata() }
      let intent = next.intents[index]
      try requireRelease(batch, intent: intent, catalog: next)
      try verifyAnchorsRemoved()
      for item in batch.items {
        try opened.verify()
        let name = receiptName(item.receipt.selection.recordID)
        let directory = opened.directories.released
        if let existing = try opened.io.read(name, in: directory, limit: item.bytes.count) {
          guard existing == item.bytes else { throw invalidRecoveryMetadata() }
          try opened.io.synchronize(name, in: directory, expecting: item.bytes)
        } else {
          try opened.io.write(item.bytes, name: name, in: directory, replacing: nil)
        }
      }
      let removed = Set(intent.selections.map(\.recordID))
      next.records.removeAll { removed.contains($0.id) }
      next.intents.remove(at: index)
      try write(next, replacing: previous.bytes)
    }

    private func durableCatalog() throws -> (catalog: WorktreeRecoveryCatalog, bytes: Data) {
      let current = try opened.readCatalog()
      try opened.io.synchronize(
        "catalog.json", in: opened.directories.store, expecting: current.bytes)
      try opened.verify()
      return current
    }

    private func write(_ catalog: WorktreeRecoveryCatalog, replacing previous: Data) throws {
      let bytes = try recoveryJSON(catalog)
      try catalog.validate(
        repository: opened.identity.repository, generation: generation, byteCount: bytes.count)
      try opened.verify()
      if bytes != previous {
        try opened.io.write(
          bytes, name: "catalog.json", in: opened.directories.store, replacing: previous)
      }
      try opened.verify()
    }

    private func recordIndices(_ catalog: WorktreeRecoveryCatalog) -> [UUID: Int] {
      Dictionary(uniqueKeysWithValues: catalog.records.enumerated().map { ($1.id, $0) })
    }

    private func uniqueRecords(_ records: [WorktreeRecoveryRecord]) throws
      -> [UUID: WorktreeRecoveryRecord]
    {
      var result: [UUID: WorktreeRecoveryRecord] = [:]
      for record in records {
        guard result.updateValue(record, forKey: record.id) == nil
        else { throw invalidRecoveryMetadata() }
      }
      return result
    }

    private struct ReleaseBatch {
      let operationID: UUID
      let digest: String
      let items: [(receipt: WorktreeRecoveryReleaseReceipt, bytes: Data)]
    }

    private func releaseBatch(_ receipts: [WorktreeRecoveryReleaseReceipt]) throws -> ReleaseBatch {
      guard let first = receipts.first, receipts.count <= WorktreeRecoveryCatalog.referenceLimit
      else { throw invalidRecoveryMetadata() }
      var ids: Set<UUID> = []
      for receipt in receipts {
        let id = receipt.selection.recordID
        try receipt.validate(
          repository: opened.identity.repository, generation: generation, recordID: id)
        guard ids.insert(id).inserted, receipt.operationID == first.operationID,
          receipt.requestDigest == first.requestDigest
        else { throw invalidRecoveryMetadata() }
      }
      let selections = try WorktreeRecoveryReleaseReceipt.digest(of: receipts.map(\.selection))
      var count = 0
      let items = try receipts.map { receipt in
        guard receipt.selectionDigest == selections else { throw invalidRecoveryMetadata() }
        let bytes = try receipt.encoded()
        count = try recoverySum(count, bytes.count)
        guard count <= WorktreeRecoveryReleaseReceipt.operationByteLimit else {
          throw WorktreeError.busy("Recovery release exceeds its receipt byte limit.")
        }
        return (receipt: receipt, bytes: bytes)
      }
      return ReleaseBatch(operationID: first.operationID, digest: first.requestDigest, items: items)
    }

    private func requireRelease(
      _ batch: ReleaseBatch, intent: WorktreeRecoveryIntent, catalog: WorktreeRecoveryCatalog
    ) throws {
      let records = Dictionary(uniqueKeysWithValues: catalog.records.map { ($0.id, $0) })
      let selections = Dictionary(uniqueKeysWithValues: intent.selections.map { ($0.recordID, $0) })
      guard intent.kind == .release, intent.requestDigest == batch.digest,
        selections.count == batch.items.count
      else { throw invalidRecoveryMetadata() }
      for item in batch.items {
        let receipt = item.receipt
        let id = receipt.selection.recordID
        guard let record = records[id], selections[id] == receipt.selection,
          record.owner == receipt.owner,
          try releaseReceipt(recordID: id).map({ $0 == receipt }) ?? true
        else { throw invalidRecoveryMetadata() }
      }
    }

    private func releaseIsArchived(_ batch: ReleaseBatch, catalog: WorktreeRecoveryCatalog) throws
      -> Bool
    {
      let active = Set(catalog.records.map(\.id))
      guard batch.items.allSatisfy({ !active.contains($0.receipt.selection.recordID) })
      else { return false }
      guard !catalog.intents.contains(where: { $0.id == batch.operationID })
      else { throw invalidRecoveryMetadata() }
      for item in batch.items {
        guard try releaseReceipt(recordID: item.receipt.selection.recordID) == item.receipt
        else { throw invalidRecoveryMetadata() }
        try opened.io.synchronize(
          receiptName(item.receipt.selection.recordID), in: opened.directories.released,
          expecting: item.bytes)
      }
      return true
    }

    private func receiptName(_ id: UUID) -> String { id.uuidString.lowercased() + ".json" }
  }

  fileprivate struct Layout {
    let root: WorktreeDirectory
    let locks: WorktreeDirectory
    let stores: WorktreeDirectory

    init(_ root: WorktreeDirectory, create: Bool = false) throws {
      self.root = root
      locks = try root.child("locks", create: create)
      stores = try root.child("stores", create: create)
    }

    var identities: [WorktreeDirectoryIdentity] {
      [root.identity, locks.identity, stores.identity]
    }

    func verify() throws {
      try root.verify()
      try locks.verify()
      try stores.verify()
    }

    func lockPath(_ key: String) -> String { locks.url.appendingPathComponent(key + ".lock").path }
    func intentName(_ key: String) -> String { key + ".creating.json" }

    func storeKeys() throws -> [String] {
      var keys = Set(try stores.entries(limit: WorktreeRecoveryCatalog.recordLimit))
      for name in try locks.entries(limit: WorktreeRecoveryCatalog.recordLimit) {
        if name.hasSuffix(".lock") {
          keys.insert(String(name.dropLast(".lock".count)))
        } else if name.hasSuffix(".creating.json") {
          keys.insert(String(name.dropLast(".creating.json".count)))
        } else {
          throw invalidRecoveryMetadata()
        }
      }
      guard keys.allSatisfy(\.isRecoveryDigest) else { throw invalidRecoveryMetadata() }
      return keys.sorted()
    }
  }

  fileprivate struct StoreDirectories {
    let store: WorktreeDirectory
    let git: WorktreeDirectory
    let objects: WorktreeDirectory
    let refs: WorktreeDirectory
    let staging: WorktreeDirectory
    let released: WorktreeDirectory

    init(layout: Layout, key: String) throws {
      store = try layout.stores.child(key)
      git = try store.child("repository.git")
      objects = try git.child("objects")
      refs = try git.child("refs")
      staging = try store.child("staging")
      released = try store.child("released")
    }

    var all: [WorktreeDirectory] { [store, git, objects, refs, staging, released] }
    var identities: [WorktreeDirectoryIdentity] { all.map(\.identity) }
  }

  fileprivate struct StoreIdentity: Codable {
    var version = 1
    let repository: WorktreeRepositoryIdentity
    let generation: UUID
    let lock: FileLock.Identity
    let layout: [WorktreeDirectoryIdentity]
    let directories: [WorktreeDirectoryIdentity]
  }

  private struct CreationIntent: Codable {
    var version = 1
    let repository: WorktreeRepositoryIdentity
    let generation: UUID
    let lock: FileLock.Identity
    let layout: [WorktreeDirectoryIdentity]
    var directories: [WorktreeDirectoryIdentity] = []
  }

  fileprivate struct OpenStore {
    let layout: Layout
    let directories: StoreDirectories
    let lock: FileLock
    let identity: StoreIdentity
    let identityBytes: Data
    let io: WorktreeJournalIO

    func verify() throws {
      try layout.verify()
      guard try lock.identity() == identity.lock else { throw invalidRecoveryMetadata() }
      for directory in directories.all { try directory.verify() }
      let git = directories.git
      let config = WorktreeRecoveryStore.config(identity.repository.format)
      let head = WorktreeRecoveryStore.head
      guard
        try io.read("identity.json", in: directories.store, limit: identityBytes.count)
          == identityBytes,
        try io.read("config", in: git, limit: config.count) == config,
        try io.read("HEAD", in: git, limit: head.count) == head,
        try !git.hasEntry("commondir"), try !git.hasEntry("shallow"),
        try !directories.refs.hasEntry("replace")
      else { throw invalidRecoveryMetadata() }
      if try directories.objects.hasEntry("info") {
        let info = try directories.objects.child("info")
        guard try !info.hasEntry("alternates"), try !info.hasEntry("http-alternates")
        else { throw invalidRecoveryMetadata() }
      }
    }

    func readCatalog() throws -> (catalog: WorktreeRecoveryCatalog, bytes: Data) {
      try verify()
      guard
        let bytes = try io.read(
          "catalog.json", in: directories.store, limit: WorktreeRecoveryCatalog.byteLimit)
      else { throw invalidRecoveryMetadata() }
      let catalog = try JSONDecoder().decode(WorktreeRecoveryCatalog.self, from: bytes)
      try catalog.validate(
        repository: identity.repository, generation: identity.generation, byteCount: bytes.count)
      return (catalog, bytes)
    }
  }
}

extension WorktreeRepositoryIdentity {
  fileprivate func validateRecoveryIdentity() throws {
    for directory in [source, main, common, objects] {
      let path = directory.path
      guard path.hasPrefix("/"),
        !path.unicodeScalars.contains(where: { $0.value < 32 }),
        path == "/"
          || path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
        directory.inode != 0,
        (directory.birthSeconds == nil) == (directory.birthNanoseconds == nil),
        directory.birthNanoseconds.map({ (0..<1_000_000_000).contains($0) }) ?? true
      else { throw invalidRecoveryMetadata() }
    }
    guard (common.path == "/" ? "/objects" : common.path + "/objects") == objects.path
    else { throw invalidRecoveryMetadata() }
  }
}
