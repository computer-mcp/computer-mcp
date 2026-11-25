import Foundation
import Testing

@testable import ComputerMCPWorktrees

private enum HandoffTestFailure: Error { case interrupted, denied }

// Git produces and indexes the actual fixture pack; process limits have separate tests.
private struct HandoffFixtureGit: WorktreeGitExecuting {
  let base: WorktreeTestGit

  func execute(_ command: WorktreeGitCommand) throws -> WorktreeGitResult {
    try base.execute(command)
  }

  func executeBounded(
    _ command: WorktreeGitCommand, fileOutput: WorktreeGitFileOutput?, fileSizeLimit: Int?
  ) throws -> WorktreeGitResult {
    let result = try base.execute(command)
    if let fileOutput {
      guard result.output.count <= fileOutput.byteLimit else {
        throw WorktreeError.commandFailed("Fixture pack exceeds bound")
      }
      try FileHandle(fileDescriptor: fileOutput.descriptor, closeOnDealloc: false)
        .write(contentsOf: result.output)
      return .init(output: Data(), error: result.error, exitCode: result.exitCode)
    }
    return result
  }

  func withPreparedTransaction(_ command: WorktreeGitCommand, _ body: () throws -> Void) throws {
    try base.withPreparedTransaction(command, body)
  }
}

private final class HandoffPackInterruption: @unchecked Sendable {
  let directory: URL
  private(set) var fired = false

  init(_ directory: URL) { self.directory = directory }

  func check() throws {
    guard !fired, let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
      names.contains(where: { $0.hasSuffix(".pack") }),
      !names.contains(where: { $0.hasSuffix(".idx") })
    else { return }
    fired = true
    throw HandoffTestFailure.interrupted
  }
}

private struct HandoffJournal {
  let directory: WorktreeDirectory
  private let io = WorktreeJournalIO()
  private let name = "handoff.json"

  func write(_ value: WorktreeRecoveryHandoff) throws {
    let bytes = try recoveryJSON(value)
    let previous = try io.read(name, in: directory, limit: WorktreeRecoveryCatalog.byteLimit)
    try io.write(bytes, name: name, in: directory, replacing: previous)
  }

  func read() throws -> WorktreeRecoveryHandoff {
    let bytes = try #require(io.read(name, in: directory, limit: WorktreeRecoveryCatalog.byteLimit))
    return try JSONDecoder().decode(WorktreeRecoveryHandoff.self, from: bytes)
  }
}

struct WorktreeRecoveryHandoffTests {
  @Test(arguments: [false, true])
  func retentionPrecedesSourceInstallationAndAuthorityDenial(deny: Bool) throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let service = try f.service(executor: HandoffFixtureGit(base: f.executor))
      let created = try service.create(name: "handoff-order")
      let base = try f.raw(["rev-parse", "refs/heads/" + created.branch])
      let tip = try f.privateCommit(service, projectID: created.projectID)
      let topology = try service.topology(projectID: created.projectID)
      let record = try #require(f.store.records().first { $0.projectID == created.projectID })
      let operation = UUID()
      let journal = HandoffJournal(directory: try WorktreeDirectory(directory))
      let recovery = WorktreeRecoveryStore(storage: f.storage)
      let lock = try service.acquireLock()
      defer { lock.release() }
      var sourceChecks = 0
      var budget = try WorktreeObjectBudget(.init())
      try recovery.withExclusive(repository: service.identity, create: true) { store in
        let sourcePack = f.repository.appendingPathComponent(".git/objects/pack")
        let originalEntries = try FileManager.default.contentsOfDirectory(atPath: sourcePack.path)
          .sorted()
        let perform = {
          try service.beginRecoveryHandoff(
            operationID: operation, kind: .publication, record: record, topology: topology,
            store: store, budget: &budget, persist: journal.write,
            revalidate: { try lock.verify() },
            verifySource: {
              sourceChecks += 1
              if sourceChecks == 1 {
                let saved = try journal.read()
                #expect(saved.phase == .retained)
                #expect(saved.retention.operationID == operation)
                let catalog = try store.catalog()
                #expect(catalog.intents.contains { $0.id == operation && $0.kind == .publication })
                let retained = try #require(catalog.records.first { $0.oid == tip })
                #expect(retained.state == .retained)
                #expect(retained.dependencies.contains(operation))
                #expect(retained.owner == saved.retention.owner)
                #expect(retained.claims.contains { $0.reason == .privateHead && $0.rootOID == tip })
                try expectRecoveryObject(f, identity: service.identity, record: retained)
                let pack = try store.packDirectory()
                let names = try pack.entries(limit: 100)
                #expect(names.contains { $0.hasSuffix(".pack") })
                #expect(names.contains { $0.hasSuffix(".idx") })
                #expect(try f.raw(["rev-parse", "refs/heads/" + created.branch]) == base)
                #expect(
                  try FileManager.default.contentsOfDirectory(atPath: sourcePack.path).sorted()
                    == originalEntries)
              }
              if deny { throw HandoffTestFailure.denied }
            })
        }
        if deny {
          #expect(throws: HandoffTestFailure.self) { try perform() }
          #expect(try journal.read().phase == .retained)
          #expect(
            try FileManager.default.contentsOfDirectory(atPath: sourcePack.path).sorted()
              == originalEntries)
        } else {
          let result = try perform()
          #expect(result.phase == .sourceInstalled)
          #expect(try journal.read() == result)
        }
        #expect(sourceChecks > 0)
        #expect(try f.raw(["rev-parse", "refs/heads/" + created.branch]) == base)
        try expectNoSourceRecoveryRefs(f)
      }
    }
  }

  @Test(arguments: [false, true])
  func interruptedPackHandoffReopensOrRefusesReplacement(conflict: Bool) throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let normal = try f.service(executor: HandoffFixtureGit(base: f.executor))
      let created = try normal.create(name: "handoff-replay")
      let base = try f.raw(["rev-parse", "refs/heads/" + created.branch])
      let tip = try f.privateCommit(normal, projectID: created.projectID)
      let topology = try normal.topology(projectID: created.projectID)
      let record = try #require(f.store.records().first { $0.projectID == created.projectID })
      let operation = UUID()
      let key = try WorktreeRecoveryStore.key(for: normal.identity)
      let packURL = f.storage.recovery.appendingPathComponent(
        "stores/\(key)/repository.git/objects/pack")
      let failure = HandoffPackInterruption(packURL)
      var recovery = WorktreeRecoveryStore(storage: f.storage)
      try recovery.withExclusive(repository: normal.identity, create: true) { _ in }
      recovery.io = WorktreeJournalIO(beforeDirectorySync: { try failure.check() })
      let interrupted = try f.service(
        executor: HandoffFixtureGit(base: f.executor),
        journalIO: .init(beforeDirectorySync: { try failure.check() }))
      let journal = HandoffJournal(directory: try WorktreeDirectory(directory))
      do {
        let lock = try interrupted.acquireLock()
        defer { lock.release() }
        var budget = try WorktreeObjectBudget(.init())
        try recovery.withExclusive(repository: interrupted.identity) { store in
          #expect(throws: HandoffTestFailure.self) {
            try interrupted.beginRecoveryHandoff(
              operationID: operation, kind: .publication, record: record, topology: topology,
              store: store, budget: &budget, persist: journal.write,
              revalidate: { try lock.verify() }, verifySource: { try lock.verify() })
          }
        }
      }
      #expect(failure.fired)
      let saved = try journal.read()
      #expect(saved.phase == .retaining)
      #expect(saved.retention.operationID == operation)
      let install = try #require(saved.recoveryInstallation)
      #expect(install.operationID == operation)
      #expect(install.generation == saved.retention.generation)
      let pack = packURL.appendingPathComponent("pack-\(saved.recoveryArtifact.hash).pack")
      let index = packURL.appendingPathComponent("pack-\(saved.recoveryArtifact.hash).idx")
      let keep = packURL.appendingPathComponent("pack-\(saved.recoveryArtifact.hash).keep")
      #expect(FileManager.default.fileExists(atPath: pack.path))
      #expect(!FileManager.default.fileExists(atPath: index.path))
      let installed = try WorktreeRecoveryStageFile.read(
        pack.lastPathComponent, in: WorktreeDirectory(packURL),
        limit: saved.recoveryArtifact.pack.bytes)
      #expect(installed == saved.recoveryArtifact.pack)
      let keepAttributes = try FileManager.default.attributesOfItem(atPath: keep.path)
      #expect((keepAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
      #expect(try f.raw(["rev-parse", "refs/heads/" + created.branch]) == base)
      let originalIDs = saved.retention.admitted.map(\.id)
      var replacement = Data()
      if conflict {
        replacement = Data(repeating: 0x5a, count: saved.recoveryArtifact.pack.bytes)
        try FileManager.default.removeItem(at: pack)
        try replacement.write(to: pack)
      }
      let candidateInode =
        (try FileManager.default.attributesOfItem(atPath: pack.path)[.systemFileNumber] as? NSNumber)?
        .uint64Value
      var reopened = try journal.read()
      let lock = try normal.acquireLock()
      defer { lock.release() }
      let freshStore = WorktreeRecoveryStore(storage: f.storage)
      try freshStore.withExclusive(repository: normal.identity) { store in
        let before = try store.catalog()
        #expect(before.intents.contains { $0.id == operation })
        #expect(Set(before.records.map(\.id)) == Set(originalIDs))
        if conflict {
          #expect(throws: (any Error).self) {
            try normal.resumeRecoveryHandoff(
              &reopened, store: store, budget: WorktreeObjectBudget(.init()),
              persist: journal.write, revalidate: { try lock.verify() },
              verifySource: { try lock.verify() })
          }
          #expect(try Data(contentsOf: pack) == replacement)
          #expect(
            (try FileManager.default.attributesOfItem(atPath: pack.path)[.systemFileNumber]
              as? NSNumber)?.uint64Value == candidateInode)
          #expect(FileManager.default.fileExists(atPath: keep.path))
          let after = try store.catalog()
          #expect(after.intents.contains { $0.id == operation })
          #expect(Set(after.records.map(\.id)) == Set(originalIDs))
        } else {
          try normal.resumeRecoveryHandoff(
            &reopened, store: store, budget: WorktreeObjectBudget(.init()),
            persist: journal.write, revalidate: { try lock.verify() },
            verifySource: { try lock.verify() })
          #expect(reopened.phase == .sourceInstalled)
          #expect(reopened.retention.operationID == operation)
          #expect(reopened.retention.admitted.map(\.id) == originalIDs)
          let retained = try #require(store.catalog().records.first { $0.oid == tip })
          #expect(retained.dependencies.contains(operation))
          try expectRecoveryObject(f, identity: normal.identity, record: retained)
          #expect(FileManager.default.fileExists(atPath: index.path))
          #expect(
            try WorktreeRecoveryStageFile.read(
              pack.lastPathComponent, in: WorktreeDirectory(packURL),
              limit: saved.recoveryArtifact.pack.bytes) == installed)
        }
        #expect(try f.raw(["rev-parse", "refs/heads/" + created.branch]) == base)
        try expectNoSourceRecoveryRefs(f)
      }
    }
  }
}
