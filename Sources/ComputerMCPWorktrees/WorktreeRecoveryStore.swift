import ComputerMCPPlatformPOSIX
import Foundation

struct WorktreeRecoveryStore {
  let storage: WorktreeStorage
  var io = WorktreeJournalIO()

  struct Snapshot {
    let key: String
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
        return Snapshot(key: key, repository: opened.identity.repository, catalog: catalog)
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
    let store = Locked(opened: opened)
    try store.requireMaintenanceIdle()
    // Confirm that an observed active-journal retirement is durable before a
    // different operation mutates the inventory.
    try store.directory.synchronize()
    return try operation(store)
  }

  /// Opens an already installed generation. Owner operations and lookup use
  /// the same lock and identity verification as ordinary lifecycle mutations.
  func withExisting<Result>(
    key: String, generation: UUID, exclusive: Bool,
    _ operation: (Locked) throws -> Result
  ) throws -> Result {
    guard key.isRecoveryDigest, let root = try rootIfPresent()
    else { throw WorktreeRecoveryOwnerError.unavailable }
    let layout = try Layout(root)
    let lock: FileLock
    do {
      lock =
        try exclusive
        ? FileLock(lockingExisting: layout.lockPath(key))
        : FileLock(sharingExisting: layout.lockPath(key))
    } catch FileLockError.held {
      throw WorktreeError.busy("Recovery store is in use.")
    } catch {
      throw WorktreeRecoveryOwnerError.unavailable
    }
    defer { lock.release() }
    let opened: OpenStore
    do { opened = try open(key, layout: layout, lock: lock) } catch let error as POSIXError
      where [.ENOENT, .EACCES, .EPERM].contains(error.code)
    {
      throw WorktreeRecoveryOwnerError.unavailable
    }
    guard opened.identity.generation == generation else {
      throw WorktreeRecoveryOwnerError.storeChanged
    }
    if exclusive { try layout.locks.synchronize() }
    return try operation(Locked(opened: opened))
  }

  /// A lifecycle caller already holds repository coordination. This check
  /// precedes publishing an intent whose effects may need the store.
  func requireMaintenanceIdle(repository: WorktreeRepositoryIdentity) throws {
    guard let root = try rootIfPresent() else { return }
    let layout = try Layout(root)
    let key = try Self.key(for: repository)
    guard try layout.locks.hasEntry(key + ".lock") else {
      guard try !layout.stores.hasEntry(key) else { throw invalidRecoveryMetadata() }
      return
    }
    let lock = try FileLock(sharingExisting: layout.lockPath(key))
    defer { lock.release() }
    if try layout.locks.hasEntry(layout.intentName(key)) { return }
    let store = Locked(opened: try open(key, layout: layout, lock: lock))
    try store.requireMaintenanceIdle()
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
    var repository: WorktreeRepositoryIdentity { opened.identity.repository }
    var directory: WorktreeDirectory { opened.directories.store }
    var gitDirectory: WorktreeDirectory { opened.directories.git }
    var objectsDirectory: WorktreeDirectory { opened.directories.objects }
    var stagingDirectory: WorktreeDirectory { opened.directories.staging }
    var journalIO: WorktreeJournalIO { opened.io }

    func checkIdentity() throws { try opened.verify() }

    func observedCatalog() throws -> (catalog: WorktreeRecoveryCatalog, bytes: Data) {
      try opened.readCatalog()
    }

    func validateAnchorContents(for catalog: WorktreeRecoveryCatalog) throws {
      guard let anchors = try validateAnchors(for: catalog) else { return }
      for record in catalog.records {
        let bytes = anchorBytes(record)
        let observed = try opened.io.read(anchor(record.id), in: anchors, limit: bytes.count)
        guard observed == bytes || (observed == nil && record.state != .retained) else {
          throw invalidRecoveryMetadata()
        }
      }
    }

    func objectsForExpected(
      oid: String, owner: WorktreeRecoveryRecord.Owner
    ) throws -> WorktreeDirectory? {
      let catalog = try durableCatalog().catalog
      let anchors = try validateAnchors(for: catalog)
      guard
        let record = catalog.records.first(where: {
          $0.state == .retained && $0.oid == oid && $0.owner == owner && $0.objectType == .commit
        })
      else { return nil }
      guard let anchors else { throw invalidRecoveryMetadata() }
      try synchronizeAnchor(record, in: anchors)
      return opened.directories.objects
    }

    func packDirectory() throws -> WorktreeDirectory {
      try opened.verify()
      let directory = try opened.directories.objects.child("pack", create: true)
      try opened.verify()
      return directory
    }

    func admitRetention(_ retention: WorktreeRecoveryRetention) throws {
      let current = try durableCatalog().catalog
      try retention.validate(in: current, repository: opened.identity.repository)
      _ = try validateAnchors(for: current)
      if let intent = current.intents.first(where: { $0.id == retention.operationID }) {
        try requireRetention(retention, intent: intent, catalog: current)
        return
      }
      let retained = zip(retention.admitted, retention.retained).compactMap { before, after in
        before == after ? nil : after
      }
      let terminal = retention.retained.map { record in
        var next = record
        next.revision += 1
        next.dependencies.removeAll { $0 == retention.operationID }
        return next
      }
      try admit(
        operationID: retention.operationID, kind: retention.kind,
        requestDigest: retention.requestDigest(), records: retention.admitted,
        completionSteps: [retained, terminal],
        releaseCandidates: Set(terminal.filter { $0.claims.isEmpty }.map(\.id)))
    }

    /// The journal has frozen the pack receipt and retention IDs. The caller
    /// seals the retained lifecycle phase only after this durable readback.
    func retainInstalledPack(
      _ retention: WorktreeRecoveryRetention, installation: WorktreeRecoveryPackInstall,
      git: WorktreeGit, budget: WorktreeObjectBudget
    ) throws {
      let current = try durableCatalog().catalog
      guard installation.generation == generation,
        installation.operationID == retention.operationID,
        let intent = current.intents.first(where: { $0.id == retention.operationID })
      else { throw invalidRecoveryMetadata() }
      try requireRetention(retention, intent: intent, catalog: current)
      let existing = try validateAnchors(for: current)
      let anchors = try existing ?? opened.directories.refs.child("recovery", create: true)
      let created = Set(retention.admitted.filter { $0.state == .retaining }.map(\.id))
      try installation.synchronizeInstalled(
        in: packDirectory(), format: opened.identity.repository.format, io: opened.io,
        deadline: budget.deadline)
      for record in retention.retained {
        try budget.check()
        try opened.verify()
        let name = anchor(record.id)
        let contents = anchorBytes(record)
        if try anchors.hasEntry(name) {
          try synchronizeAnchor(record, in: anchors)
        } else {
          guard record.revision == 2, created.contains(record.id)
          else { throw invalidRecoveryMetadata() }
          try opened.io.write(contents, name: name, in: anchors, replacing: nil)
        }
      }
      try verifyRetentionClosure(retention, git: git, budget: budget)
      try advance(operationID: retention.operationID, records: retention.retained)
      try requireRetained(retention)
    }

    func requireRetained(_ retention: WorktreeRecoveryRetention) throws {
      let current = try durableCatalog().catalog
      try retention.validate(in: current, repository: opened.identity.repository)
      guard let intent = current.intents.first(where: { $0.id == retention.operationID }),
        intent.kind == retention.kind, try intent.requestDigest == retention.requestDigest(),
        intent.selections == retention.admitted.map(\.selection),
        let anchors = try validateAnchors(for: current)
      else { throw invalidRecoveryMetadata() }
      let byID = recordIndices(current)
      for record in retention.retained {
        guard let index = byID[record.id] else { throw invalidRecoveryMetadata() }
        var observed = current.records[index]
        guard observed.revision >= record.revision,
          Set(record.dependencies).isSubset(of: observed.dependencies)
        else { throw invalidRecoveryMetadata() }
        observed.revision = record.revision
        observed.dependencies = record.dependencies
        guard observed == record else {
          throw invalidRecoveryMetadata()
        }
        let contents = anchorBytes(record)
        guard try opened.io.read(anchor(record.id), in: anchors, limit: contents.count) == contents
        else { throw invalidRecoveryMetadata() }
      }
    }

    func verifyRetentionClosure(
      _ retention: WorktreeRecoveryRetention, git: WorktreeGit, budget: WorktreeObjectBudget
    ) throws {
      try opened.verify()
      let objects = WorktreeStagedObjects(
        directory: opened.directories.objects, repository: opened.directories.git, git: git,
        format: opened.identity.repository.format, deadline: budget.deadline, limits: budget.limits)
      let roots = Set(retention.roots).union([retention.expectedOID]).sorted()
      guard let manifest = try objects.manifest(roots: roots) else {
        throw invalidRecoveryMetadata()
      }
      try retention.verifyManifest(manifest)
      try opened.verify()
    }

    func verifyRetainedRecords(
      _ selection: [WorktreeRecoveryRecord.Selection], owner: WorktreeRecoveryRecord.Owner,
      git: WorktreeGit, budget: WorktreeObjectBudget
    ) throws {
      let catalog = try durableCatalog().catalog
      let anchors = try validateAnchors(for: catalog)
      guard !selection.isEmpty else { return }
      guard let anchors, Set(selection.map(\.recordID)).count == selection.count
      else { throw invalidRecoveryMetadata() }
      let indices = recordIndices(catalog)
      let expected = try selection.map { selected in
        try budget.check()
        guard let index = indices[selected.recordID] else { throw invalidRecoveryMetadata() }
        let record = catalog.records[index]
        guard record.owner == owner, record.selection == selected, record.state == .retained
        else { throw invalidRecoveryMetadata() }
        try synchronizeAnchor(record, in: anchors)
        return record
      }
      let pool = WorktreeStagedObjects(
        directory: opened.directories.objects, repository: opened.directories.git, git: git,
        format: opened.identity.repository.format, deadline: budget.deadline, limits: budget.limits)
      let roots = Set(expected.map(\.oid)).sorted()
      guard let manifest = try pool.manifest(roots: roots),
        expected.allSatisfy({ manifest.entries[$0.oid]?.type == $0.objectType })
      else { throw invalidRecoveryMetadata() }
      try opened.verify()
    }

    /// Preview the exact state after retiring this operation's pin. The caller
    /// journals the release selection before committing the catalog transition.
    func retentionCompletion(_ retention: WorktreeRecoveryRetention)
      throws -> (pending: Bool, records: [WorktreeRecoveryRecord])
    {
      let current = try durableCatalog().catalog
      try retention.validate(in: current, repository: opened.identity.repository)
      let indices = recordIndices(current)
      let records = try retention.retained.map { planned in
        guard let index = indices[planned.id] else { throw invalidRecoveryMetadata() }
        let record = current.records[index]
        guard record.state == .retained, record.revision >= planned.revision,
          record.owner == planned.owner, record.oid == planned.oid, record.base == planned.base,
          record.objectType == planned.objectType
        else { throw invalidRecoveryMetadata() }
        return record
      }
      guard let intent = current.intents.first(where: { $0.id == retention.operationID }) else {
        guard records.allSatisfy({ !$0.dependencies.contains(retention.operationID) })
        else { throw invalidRecoveryMetadata() }
        return (false, records)
      }
      guard intent.kind == retention.kind, try intent.requestDigest == retention.requestDigest(),
        intent.selections == retention.admitted.map(\.selection)
      else { throw invalidRecoveryMetadata() }
      let updates = try records.map { record in
        guard record.dependencies.contains(retention.operationID), record.revision < Int64.max - 1
        else { throw invalidRecoveryMetadata() }
        var next = record
        next.revision += 1
        next.dependencies.removeAll { $0 == retention.operationID }
        return next
      }
      return (true, updates)
    }

    /// The lifecycle caller has frozen the exact release request and authorized
    /// it under its parent guards before entering this receipt transaction.
    func releaseAnchors(
      _ receipts: [WorktreeRecoveryReleaseReceipt], verifyAuthority: () throws -> Void
    ) throws {
      try verifyAuthority()
      try prepareRelease(receipts)
      let current = try durableCatalog().catalog
      let anchors = try validateAnchors(for: current)
      if let intent = current.intents.first(where: { $0.id == receipts.first?.operationID }) {
        guard intent.kind == .release, let anchors else { throw invalidRecoveryMetadata() }
        for receipt in receipts {
          try verifyAuthority()
          try opened.verify()
          let name = anchor(receipt.selection.recordID)
          if try anchors.hasEntry(name) {
            try opened.io.remove(
              name, in: anchors, expecting: Data((receipt.selection.oid + "\n").utf8))
          }
        }
      }
      try finishRelease(receipts) {
        try verifyAuthority()
        if let anchors {
          for receipt in receipts where try anchors.hasEntry(anchor(receipt.selection.recordID)) {
            throw invalidRecoveryMetadata()
          }
          try opened.io.beforeDirectorySync()
          try anchors.synchronize()
        }
      }
    }

    private func requireRetention(
      _ retention: WorktreeRecoveryRetention, intent: WorktreeRecoveryIntent,
      catalog: WorktreeRecoveryCatalog
    ) throws {
      try retention.validate(in: catalog, repository: opened.identity.repository)
      guard intent.kind == retention.kind, try intent.requestDigest == retention.requestDigest(),
        intent.selections == retention.admitted.map(\.selection)
      else { throw invalidRecoveryMetadata() }
      let indices = recordIndices(catalog)
      for (before, after) in zip(retention.admitted, retention.retained) {
        guard let index = indices[before.id],
          catalog.records[index] == before || catalog.records[index] == after
        else { throw invalidRecoveryMetadata() }
      }
    }

    private func validateAnchors(for catalog: WorktreeRecoveryCatalog) throws -> WorktreeDirectory?
    {
      try opened.verify()
      let git = opened.directories.git
      let refs = opened.directories.refs
      guard try !git.hasEntry("packed-refs"), try !git.hasEntry("logs")
      else { throw invalidRecoveryMetadata() }
      let entries = try refs.entries(limit: 1)
      guard entries.isEmpty || entries == ["recovery"] else { throw invalidRecoveryMetadata() }
      let anchors = entries.isEmpty ? nil : try refs.child("recovery")
      let names = try Set(anchors?.entries(limit: WorktreeRecoveryCatalog.recordLimit) ?? [])
      let allowed = Set(catalog.records.map { anchor($0.id) })
      let required = Set(catalog.records.filter { $0.state == .retained }.map { anchor($0.id) })
      guard names.isSubset(of: allowed), required.isSubset(of: names)
      else { throw invalidRecoveryMetadata() }
      return anchors
    }

    private func anchor(_ id: UUID) -> String { id.uuidString.lowercased() }

    private func anchorBytes(_ record: WorktreeRecoveryRecord) -> Data {
      Data((record.oid + "\n").utf8)
    }

    private func synchronizeAnchor(
      _ record: WorktreeRecoveryRecord, in anchors: WorktreeDirectory
    ) throws {
      try opened.io.synchronize(anchor(record.id), in: anchors, expecting: anchorBytes(record))
    }

    func withStaging<Result>(
      operationID: UUID, inputLimit: Int, completionMetadataBytes: Int,
      _ operation: (WorktreeRecoveryStaging) throws -> Result
    ) throws -> Result {
      let stage = try WorktreeRecoveryStaging(
        parent: opened.directories.staging, operationID: operationID, generation: generation,
        format: opened.identity.repository.format, inputLimit: inputLimit,
        completionBytes: completionMetadataBytes, io: opened.io,
        sourceObjects: opened.identity.repository.objects, verifyStore: opened.verify)
      let result: Result
      do {
        result = try operation(stage)
      } catch {
        try? stage.finishAfterFailure()
        throw error
      }
      try stage.finish()
      return result
    }

    func resumeStaging<Result>(
      operationID: UUID, _ operation: (WorktreeRecoveryStaging) throws -> Result
    ) throws -> Result {
      let stage = try WorktreeRecoveryStaging(
        reopening: operationID, parent: opened.directories.staging, generation: generation,
        format: opened.identity.repository.format, io: opened.io,
        sourceObjects: opened.identity.repository.objects, verifyStore: opened.verify)
      let result = try operation(stage)
      try stage.finish()
      return result
    }

    func finishStagingDisposal(operationID: UUID) throws {
      if try WorktreeRecoveryStaging.finishRecordedDisposal(
        operationID: operationID, parent: opened.directories.staging, generation: generation,
        io: opened.io, verifyStore: opened.verify)
      {
        return
      }
      try resumeStaging(operationID: operationID) { _ in }
    }

    func catalog() throws -> WorktreeRecoveryCatalog { try durableCatalog().catalog }

    /// New record IDs are admitted in their retaining state. Completion steps can
    /// advance those records, but need no additional record slots.
    func admit(
      operationID: UUID, kind: WorktreeRecoveryIntent.Kind, requestDigest: String,
      records: [WorktreeRecoveryRecord], completionSteps: [[WorktreeRecoveryRecord]],
      releaseCandidates: Set<UUID> = []
    ) throws {
      let previous = try durableCatalog()
      guard kind != .release, requestDigest.isRecoveryDigest, !records.isEmpty
      else { throw invalidRecoveryMetadata() }
      var next = previous.catalog
      let indices = recordIndices(next)
      let changes = try uniqueRecords(records)
      var intent = WorktreeRecoveryIntent(
        id: operationID, kind: kind, requestDigest: requestDigest,
        selections: records.map(\.selection), completion: .init())
      try intent.completion.add(intent.followOnReleaseGrowth(for: releaseCandidates))
      try intent.completion.add(completionReserve(from: changes, steps: completionSteps))
      if !releaseCandidates.isEmpty {
        // Bound the immutable output with the same revision width allowed by
        // the pending intent. Receipt ownership fields never change.
        let possible = records.compactMap { record -> WorktreeRecoveryRecord? in
          guard releaseCandidates.contains(record.id) else { return nil }
          var projected = record
          projected.revision = Int64.max - 2
          return projected
        }
        _ = try WorktreeRecoveryReleaseReceipt.batch(
          for: possible, operationID: operationID, requestDigest: requestDigest)
      }
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
      verifyTerminalOutcome: (() throws -> Void)? = nil,
      releasing receipts: [WorktreeRecoveryReleaseReceipt] = []
    ) throws {
      let previous = try durableCatalog()
      var next = previous.catalog
      guard let intentIndex = next.intents.firstIndex(where: { $0.id == operationID }),
        next.intents[intentIndex].kind != .release
      else { throw invalidRecoveryMetadata() }
      let selected = Set(next.intents[intentIndex].selections.map(\.recordID))
      let updates = try uniqueRecords(records)
      guard Set(updates.keys).isSubset(of: selected),
        verifyTerminalOutcome == nil || Set(updates.keys) == selected,
        receipts.isEmpty || verifyTerminalOutcome != nil
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
        if !receipts.isEmpty {
          let batch = try releaseBatch(receipts)
          guard batch.operationID != operationID,
            batch.items.allSatisfy({ updates[$0.receipt.selection.recordID] != nil })
          else { throw invalidRecoveryMetadata() }
          try insertRelease(batch, in: &next)
        }
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
      guard try receipt.encoded() == data else { throw invalidRecoveryMetadata() }
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
      try insertRelease(batch, in: &next)
      try write(next, replacing: previous.bytes)
    }

    private func insertRelease(_ batch: ReleaseBatch, in next: inout WorktreeRecoveryCatalog)
      throws
    {
      guard !next.intents.contains(where: { $0.id == batch.operationID })
      else { throw invalidRecoveryMetadata() }
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
