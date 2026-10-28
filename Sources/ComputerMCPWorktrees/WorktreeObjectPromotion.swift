import Foundation

package struct WorktreePublication: Sendable {
  package let projectID: String
  package let operationID: UUID
  package let oid: String
}

extension WorktreeRepository {
  /// The adapter revalidates live source authority at capture and under the
  /// prepared ref locks. Preservation roots come only from host lifecycle logic.
  package func publish(
    projectID: String, preserving roots: [String] = [],
    limits: WorktreePromotionLimits = .init(),
    authorize: (DerivedProjectRecord) throws -> Void
  ) throws -> WorktreePublication {
    try limits.validate()
    return try withLock(validateHead: false) { lock in
      try publishLocked(
        projectID: projectID, preserving: roots, limits: limits, lock: lock, authorize: authorize)
    }
  }

  func publishLocked(
    projectID: String, preserving roots: [String], limits: WorktreePromotionLimits,
    lock: RepositoryLock,
    authorize: (DerivedProjectRecord) throws -> Void
  ) throws -> WorktreePublication {
    if var pending = try readPublication(projectID),
      ![.finished, .rejected].contains(pending.phase)
    {
      return try recoverPublication(&pending, lock: lock, authorize: authorize)
    }
    if let previous = try readPublication(projectID) { try cleanPublicationStaging(previous) }
    guard let record = try store.records().first(where: { $0.projectID == projectID }),
      let registration = record.worktree, let creation = try readJournal(projectID),
      creation.phase == .active, try matchesActiveRecord(creation, record),
      roots.allSatisfy(identity.format.contains)
    else { throw WorktreeError.recoveryRequired("No active publication registration.") }
    try authorize(record)
    let topology = try verifyTopology(
      creation, repository: identity, source: source, validateHead: false)
    let expected = registration.publishedOID ?? registration.baseOID
    try requireDirectRef(registration.branch, oid: expected)
    // This is the publication's only read of live HEAD. No later operation
    // resolves a mutable private ref or asks Git to open private objects.
    let captured: String
    do { captured = try privateMetadata(topology).head } catch {
      throw WorktreeError.busy("Worktree HEAD changed or cannot be captured; retry publication.")
    }
    var journal = WorktreePublicationJournal(
      version: 1, operationID: UUID(), repository: identity, record: record,
      expectedOID: expected, capturedOID: captured, maxPackBytes: limits.inputBytes,
      roots: Array(Set([captured] + roots)).sorted(),
      preservationRef: preservationRef(record, oid: expected), phase: .captured)
    let previousJournal = try readPublication(projectID)
    journal.replacementAcknowledgements = previousJournal?.replacementAcknowledgements
    let previous = try previousJournal.map(publicationBytes)
    try savePublication(journal, replacing: previous)
    do {
      let staging = try publicationDirectory().child(
        journal.operationID.uuidString.lowercased(), create: true, exclusive: true)
      try io.write(publicationOwner(journal), name: "owner.json", in: staging, replacing: nil)
      let old = try publicationBytes(journal)
      journal.staging = staging.identity
      try savePublication(journal, replacing: old)
      let objects = try staging.child("objects", create: true, exclusive: true)
      var budget = try WorktreeObjectBudget(limits)
      let snapshot = WorktreeObjectSnapshot(io: io, format: identity.format)
      let files = try snapshot.copy(from: topology.objects, to: objects, budget: &budget)
      let uncopied = try publicationBytes(journal)
      journal.files = files
      journal.phase = .copied
      try savePublication(journal, replacing: uncopied)
      try snapshot.validateRaw(files, in: objects, budget: &budget)
      try verifyPublication(&journal, budget: &budget)
    } catch {
      // A rejected attempt cannot install objects. Retain the input worktree;
      // a retry captures a fresh HEAD instead of trusting a partial snapshot.
      let reason =
        (error as? WorktreeError)?.errorDescription
        ?? (error is CancellationError
          ? "Object capture was cancelled." : "Object capture I/O failed.")
      if [.captured, .copied].contains(journal.phase) {
        let previous = try publicationBytes(journal)
        journal.rejection = String(reason.prefix(512))
        journal.phase = .rejected
        try savePublication(journal, replacing: previous)
        try cleanPublicationStaging(journal)
      }
      if error is CancellationError { throw error }
      if case WorktreeError.recoveryRequired = error { throw error }
      throw WorktreeError.busy(
        "Private object publication is busy: " + String(reason.prefix(512)))
    }
    return try finishPublication(&journal, lock: lock, authorize: authorize)
  }

  func requireDirectRef(_ ref: String, oid: String) throws {
    guard try command(["symbolic-ref", "--quiet", ref], accepting: [0, 1]).exitCode == 1,
      try revision(ref) == oid
    else { throw WorktreeError.recoveryRequired("The expected direct branch changed.") }
  }

  private func verifyPublication(
    _ journal: inout WorktreePublicationJournal, budget: inout WorktreeObjectBudget
  ) throws {
    let staging = try publicationStaging(journal)
    let objects = try staging.child("objects")
    let repository = try staging.child("repository", create: true, exclusive: true)
    _ = try git.run(
      [
        "init", "--bare", "--template=", "--object-format=" + identity.format.rawValue,
        repository.url.path,
      ],
      at: staging.url)
    func run(_ args: [String], input: Data = Data(), accepting: Set<Int32> = [0]) throws
      -> WorktreeGitResult
    {
      try git.run(
        args, at: staging.url, gitDirectory: repository.url,
        objects: objects.url,
        input: input, accepting: accepting)
    }
    // Validate indexes against the copied packs; indexes never authorize an OID.
    for file in journal.files where file.name.hasSuffix(".idx") {
      try budget.check()
      _ = try run(["verify-pack", objects.url.appendingPathComponent(file.name).path])
    }
    guard try run(["cat-file", "-t", journal.capturedOID]).output == Data("commit\n".utf8) else {
      throw WorktreeError.busy("Published HEAD must name a commit.")
    }
    guard
      try run(
        ["merge-base", "--is-ancestor", journal.record.worktree!.baseOID, journal.capturedOID],
        accepting: [0, 1]
      ).exitCode == 0
    else {
      throw WorktreeError.busy("Captured commit is unrelated to the recorded base.")
    }
    let manifestOutput = try run(["rev-list", "--objects", "--no-object-names"] + journal.roots)
      .output
    let manifest = String(decoding: manifestOutput, as: UTF8.self).split(separator: "\n").map(
      String.init
    ).sorted()
    guard !manifest.isEmpty, manifest.count <= budget.limits.objectCount,
      Set(manifest).count == manifest.count, manifest.allSatisfy(identity.format.contains)
    else { throw WorktreeError.busy("Invalid or excessive reachable object manifest.") }
    // Verify the complete closure; only the expected managed branch may supply omitted objects.
    let sizes = try run(
      ["cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)"],
      input: Data((manifest.joined(separator: "\n") + "\n").utf8)
    ).output
    var closureBudget = try WorktreeObjectBudget(budget.limits)
    let lines = String(decoding: sizes, as: UTF8.self).split(separator: "\n")
    guard lines.count == manifest.count else {
      throw WorktreeError.busy("Missing object metadata.")
    }
    for (index, line) in lines.enumerated() {
      let fields = line.split(separator: " ")
      guard fields.count == 3, fields[0] == manifest[index],
        ["commit", "tree", "blob", "tag"].contains(fields[1]), let size = Int(fields[2])
      else { throw WorktreeError.busy("Invalid object metadata.") }
      try closureBudget.object(size)
    }
    try budget.check()
    _ = try run(["fsck", "--full", "--strict", "--no-reflogs", "--no-dangling"] + journal.roots)
    let omittedOutput = try command([
      "rev-list", "--objects", "--no-object-names", journal.expectedOID,
    ]).output
    let omitted = Set(
      String(decoding: omittedOutput, as: UTF8.self).split(separator: "\n").map(String.init))
    guard omitted.allSatisfy(identity.format.contains) else {
      throw WorktreeError.busy("Invalid expected branch closure.")
    }
    let installedManifest = manifest.filter { !omitted.contains($0) }
    let output = try staging.child("verified", create: true, exclusive: true)
    let packHash = try run(
      [
        "pack-objects", "--no-reuse-object", "--no-reuse-delta", "--window=0", "--threads=1",
        output.url.appendingPathComponent("pack").path,
      ],
      input: Data(
        (installedManifest.joined(separator: "\n") + (installedManifest.isEmpty ? "" : "\n")).utf8)
    ).output
    let hash = String(decoding: packHash, as: UTF8.self).trimmingCharacters(in: .newlines)
    guard identity.format.contains(hash) else {
      throw WorktreeError.busy("Invalid generated pack ID.")
    }
    let pack = "pack-" + hash
    // The output has no deltas, cannot depend on omitted objects, and has a
    // separately enforced compressed-size ceiling before installation.
    guard let packBytes = try io.read(pack + ".pack", in: output, limit: budget.limits.inputBytes),
      let indexBytes = try io.read(pack + ".idx", in: output, limit: budget.limits.inputBytes)
    else { throw WorktreeError.busy("Generated pack is incomplete.") }
    _ = try run([
      "index-pack", "--strict", "--index-version=2", "-o",
      output.url.appendingPathComponent("checked.idx").path,
      output.url.appendingPathComponent(pack + ".pack").path,
    ])
    guard try io.read("checked.idx", in: output, limit: budget.limits.inputBytes) == indexBytes
    else {
      throw WorktreeError.busy("Generated pack index differs from strict verification.")
    }
    let inventory = try run(["show-index"], input: indexBytes).output
    let installed = String(decoding: inventory, as: UTF8.self).split(separator: "\n").map {
      $0.split(separator: " ").dropFirst().first.map(String.init) ?? ""
    }.sorted()
    guard installed == installedManifest else {
      throw WorktreeError.busy("Pack contains unexpected objects.")
    }
    try budget.check()
    let previous = try publicationBytes(journal)
    journal.manifest = manifest
    journal.pack = pack
    journal.packDigest = WorktreeObjectSnapshot.digest(packBytes)
    journal.indexDigest = WorktreeObjectSnapshot.digest(indexBytes)
    journal.phase = .verified
    try savePublication(journal, replacing: previous)
  }

  private func finishPublication(
    _ journal: inout WorktreePublicationJournal, lock: RepositoryLock,
    authorize: (DerivedProjectRecord) throws -> Void
  ) throws -> WorktreePublication {
    if [.verified, .installing].contains(journal.phase) {
      try authorize(journal.record)
      try requirePublicationRecord(journal)
      try requireDirectRef(journal.branch, oid: journal.expectedOID)
      try advancePublication(&journal, to: .installing)
      try installPublication(journal)
      try advancePublication(&journal, to: .installed)
    }
    if [.installed, .publishing].contains(journal.phase) {
      try lock.verify()
      try authorize(journal.record)
      try requirePublicationRecord(journal)
      try requireDirectRef(journal.branch, oid: journal.expectedOID)
      let protections = Array(Set(journal.roots + [journal.expectedOID])).sorted()
      var preservation = ""
      var protectionsBefore: [String: String] = [:]
      for oid in protections {
        let ref = preservationRef(journal.record, oid: oid)
        if try objectRevision(ref) == nil {
          preservation += "create \(ref) \(oid)\n"
        } else {
          try requireObjectRef(ref, oid: oid)
          protectionsBefore[ref] = oid
          preservation += "verify \(ref) \(oid)\n"
        }
      }
      let installed = try publicationBytes(journal)
      journal.protectionsBefore = protectionsBefore
      journal.phase = .publishing
      try savePublication(journal, replacing: installed)
      let input =
        "start\nupdate \(journal.branch) \(journal.capturedOID) \(journal.expectedOID)\n"
        + preservation + "prepare\n"
      try git.transaction(
        input, at: URL(fileURLWithPath: identity.main.path),
        gitDirectory: URL(fileURLWithPath: identity.common.path),
        message: publicationMessage(journal)
      ) {
        try lock.verify()
        try authorize(journal.record)
        try requirePublicationRecord(journal)
        try requireDirectRef(journal.branch, oid: journal.expectedOID)
        for oid in protections {
          let ref = preservationRef(journal.record, oid: oid)
          if try objectRevision(ref) != nil { try requireObjectRef(ref, oid: oid) }
        }
      }
      try requirePublicationRoots(journal)
      try advancePublication(&journal, to: .published)
    }
    if journal.phase == .published {
      try requirePublicationRoots(journal)
      var next = journal.record
      next.revision += 1
      next.worktree!.publishedOID = journal.capturedOID
      let existing = try store.records().first { $0.projectID == next.projectID }
      if existing != next {
        guard existing == journal.record else { throw DerivedProjectStoreError.revisionConflict }
        let registration = next.worktree!
        guard case .host(let worktreeID, _) = next.provenance else {
          throw DerivedProjectStoreError.invalidRecord
        }
        try store.commit(
          next, expecting: journal.record.revision,
          protecting: .init(
            repository: identity.common, branchID: registration.branchID,
            branch: registration.branch, base: registration.base, baseOID: registration.baseOID,
            publishedOID: journal.capturedOID, worktreeID: worktreeID,
            mergedOID: registration.mergedOID, baseHistory: registration.baseHistory))
      }
      try advancePublication(&journal, to: .ledger)
    }
    if journal.phase == .ledger {
      try requireDirectRef(journal.branch, oid: journal.capturedOID)
      try advancePublication(&journal, to: .finished)
    }
    guard journal.phase == .finished else {
      throw WorktreeError.recoveryRequired("Publication has no completed outcome.")
    }
    try cleanPublicationStaging(journal)
    return .init(
      projectID: journal.record.projectID, operationID: journal.operationID,
      oid: journal.capturedOID)
  }

  private func requirePublicationRecord(_ journal: WorktreePublicationJournal) throws {
    guard
      try store.records().first(where: { $0.projectID == journal.record.projectID })
        == journal.record
    else {
      throw DerivedProjectStoreError.revisionConflict
    }
  }

  private func publicationMessage(_ journal: WorktreePublicationJournal) -> String {
    "computer-mcp publication " + journal.operationID.uuidString.lowercased()
  }

  private func installPublication(_ journal: WorktreePublicationJournal) throws {
    let verified = try publicationStaging(journal).child("verified")
    guard let pack = journal.pack, let packDigest = journal.packDigest,
      let indexDigest = journal.indexDigest
    else {
      throw WorktreeError.recoveryRequired("Verified pack receipt is missing.")
    }
    let shared = try WorktreeDirectory(URL(fileURLWithPath: identity.objects.path)).child(
      "pack", create: true)
    // Keep precedes either object file. Never remove an existing/ambiguous keep
    // or pack on failure; a concurrent GC or foreign ref may depend on them.
    let keep = Data((publicationMessage(journal) + "\n").utf8)
    if try io.read(pack + ".keep", in: shared, limit: 4096) == nil {
      try io.write(keep, name: pack + ".keep", in: shared, replacing: nil)
    }
    for (suffix, digest) in [(".pack", packDigest), (".idx", indexDigest)] {
      guard let data = try io.read(pack + suffix, in: verified, limit: journal.maxPackBytes),
        WorktreeObjectSnapshot.digest(data) == digest
      else { throw WorktreeError.recoveryRequired("Verified pack bytes changed.") }
      if let existing = try io.read(pack + suffix, in: shared, limit: data.count, synchronize: true)
      {
        guard existing == data else {
          throw WorktreeError.recoveryRequired("Shared pack content differs.")
        }
      } else {
        try io.write(data, name: pack + suffix, in: shared, replacing: nil)
      }
    }
    try shared.synchronize()
  }

  func recoverPublication(
    _ journal: inout WorktreePublicationJournal, lock: RepositoryLock,
    authorize: (DerivedProjectRecord) throws -> Void
  ) throws -> WorktreePublication {
    if [.captured, .copied].contains(journal.phase) {
      try advancePublication(&journal, to: .rejected)
      try cleanPublicationStaging(journal)
      throw WorktreeError.busy("Incomplete object capture was discarded; retry publication.")
    }
    if journal.phase == .publishing {
      let branch = try revision(journal.branch)
      let preserved = try objectRevision(journal.preservationRef)
      if journal.expectedOID == journal.capturedOID {
        // Git writes no branch reflog entry for an unchanged OID. Accept only
        // a complete before/after protection set, then replay the transaction
        // under current authority and expected-value locks.
        try requireDirectRef(journal.branch, oid: journal.expectedOID)
        guard let before = journal.protectionsBefore else {
          throw WorktreeError.recoveryRequired("Publication protection receipt is missing.")
        }
        var matchesBefore = true
        var matchesAfter = true
        for oid in Set(journal.roots + [journal.expectedOID]) {
          let ref = preservationRef(journal.record, oid: oid)
          let current = try objectRevision(ref)
          if let current { try requireObjectRef(ref, oid: current) }
          matchesBefore = matchesBefore && current == before[ref]
          matchesAfter = matchesAfter && current == oid
        }
        guard matchesBefore || matchesAfter else {
          throw WorktreeError.recoveryRequired("Publication refs have a mixed transaction outcome.")
        }
      } else if branch == journal.capturedOID, preserved == journal.expectedOID {
        try requireDirectRef(journal.branch, oid: journal.capturedOID)
        let receipt = try command(["reflog", "show", "-1", "--format=%H%x00%gs", journal.branch])
          .output
        guard
          receipt == Data((journal.capturedOID + "\0" + publicationMessage(journal) + "\n").utf8)
        else {
          throw WorktreeError.recoveryRequired("Publication ownership cannot be proved.")
        }
        try requirePublicationRoots(journal)
        try advancePublication(&journal, to: .published)
      } else {
        guard branch == journal.expectedOID, let before = journal.protectionsBefore else {
          throw WorktreeError.recoveryRequired("Publication refs have an unknown outcome.")
        }
        for oid in Set(journal.roots + [journal.expectedOID]) {
          let ref = preservationRef(journal.record, oid: oid)
          guard try objectRevision(ref) == before[ref] else {
            throw WorktreeError.recoveryRequired(
              "Publication refs have a mixed transaction outcome.")
          }
        }
      }
    }
    return try finishPublication(&journal, lock: lock, authorize: authorize)
  }

  private func requirePublicationRoots(_ journal: WorktreePublicationJournal) throws {
    try requireDirectRef(journal.branch, oid: journal.capturedOID)
    for oid in Set(journal.roots + [journal.expectedOID]) {
      try requireObjectRef(preservationRef(journal.record, oid: oid), oid: oid)
    }
  }

  func cleanPublicationStaging(_ journal: WorktreePublicationJournal) throws {
    if journal.phase == .finished, let pack = journal.pack {
      let shared = try WorktreeDirectory(URL(fileURLWithPath: identity.objects.path)).child("pack")
      let owned = Data((publicationMessage(journal) + "\n").utf8)
      if try io.read(pack + ".keep", in: shared, limit: 4096) == owned {
        try requirePublicationRoots(journal)
        try io.remove(pack + ".keep", in: shared, expecting: owned)
      }
    }
    guard let expected = journal.staging else { return }
    guard FileManager.default.fileExists(atPath: expected.path) else { return }
    let directory = try publicationStaging(journal)
    try directory.verify()
    try FileManager.default.removeItem(at: directory.url)
    try publicationDirectory().synchronize()
  }
}

extension WorktreeRepository {
  /// Explicit acknowledgement releases just this obsolete host recovery root.
  /// Ordinary rebase/publication retains it and never ages it out automatically.
  package func acknowledgeReplacement(
    projectID: String, replacedOID: String, expectedPublishedOID: String,
    authorize: (DerivedProjectRecord) throws -> Void
  ) throws {
    try withLock(validateHead: false) { lock in
      guard identity.format.contains(replacedOID), replacedOID != expectedPublishedOID,
        let record = try store.records().first(where: { $0.projectID == projectID }),
        let registration = record.worktree, registration.publishedOID == expectedPublishedOID,
        var journal = try readPublication(projectID), journal.phase == .finished
      else { throw WorktreeError.recoveryRequired("Replacement acknowledgement is stale.") }
      try cleanPublicationStaging(journal)
      try authorize(record)
      let ref = preservationRef(record, oid: replacedOID)
      try requireDirectRef(registration.branch, oid: expectedPublishedOID)
      if try objectRevision(ref) == nil,
        journal.replacementAcknowledgements?.contains(replacedOID) == true
      {
        return
      }
      try requireObjectRef(ref, oid: replacedOID)
      if journal.replacementAcknowledgements?.contains(replacedOID) != true {
        let previous = try publicationBytes(journal)
        journal.replacementAcknowledgements =
          (journal.replacementAcknowledgements ?? []) + [replacedOID]
        try savePublication(journal, replacing: previous)
      }
      try git.transaction(
        "start\nverify \(registration.branch) \(expectedPublishedOID)\ndelete \(ref) \(replacedOID)\nprepare\n",
        at: URL(fileURLWithPath: identity.main.path),
        gitDirectory: URL(fileURLWithPath: identity.common.path),
        message: "computer-mcp acknowledged replacement"
      ) {
        try lock.verify()
        try authorize(record)
        guard try store.records().first(where: { $0.projectID == projectID }) == record else {
          throw DerivedProjectStoreError.revisionConflict
        }
        try requireDirectRef(registration.branch, oid: expectedPublishedOID)
        try requireObjectRef(ref, oid: replacedOID)
      }
    }
  }
}
