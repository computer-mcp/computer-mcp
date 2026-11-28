import Foundation
import Testing

@testable import ComputerMCPWorktrees

struct WorktreePrivateRepositoryTests {
  @Test func metadataBoundsIncludeEmptyDirectoriesAndExpiredDeadlines() throws {
    try fixture { directory in
      let root = directory.appendingPathComponent("private")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try Data((String(repeating: "a", count: 40) + "\n").utf8).write(
        to: root.appendingPathComponent("HEAD"))
      for group in 0..<8 {
        for child in 0..<8 {
          try FileManager.default.createDirectory(
            at: root.appendingPathComponent("refs/g\(group)/d\(child)"),
            withIntermediateDirectories: true)
        }
      }
      let opened = try WorktreeDirectory(root)
      #expect(throws: WorktreeError.self) {
        try WorktreePrivateMetadata(
          directory: opened, format: .sha1, io: .init(), limit: 64,
          deadline: .now.advanced(by: .seconds(5)))
      }
      #expect(throws: WorktreeError.self) {
        try WorktreePrivateMetadata(
          directory: opened, format: .sha1, io: .init(), limit: 1024, deadline: .now)
      }
    }
  }

  @Test(arguments: [false, true])
  func independentStoreSurvivesOwnerPruneAndPublishesPrivateBranch(clone: Bool) throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      try f.raw(["switch", "-c", "feature"])
      try Data("feature".utf8).write(to: f.repository.appendingPathComponent("feature"))
      try f.raw(["add", "."])
      try f.raw(["commit", "-m", "feature"])
      let feature = try f.raw(["rev-parse", "HEAD"])
      try f.raw(["switch", "main"])
      let service = try WorktreeRepository(
        source: f.source, store: f.store, storage: f.storage,
        executor: f.executor, registeredProjectRoots: [f.repository], timeoutMilliseconds: 10_000,
        maxOutputBytes: 1_048_576, lockTimeout: .seconds(1), cloneCreationObjects: clone)
      let created = try service.create(name: "independent", base: "feature")
      let topology = try service.topology(projectID: created.projectID)
      let privateGit = PrivateWorktreeGit(f: f, topology: topology)
      try privateGit.run(["switch", "-c", "private"])
      let tip = try f.privateCommit(service, projectID: created.projectID)
      #expect(try !f.raw(["worktree", "list", "--porcelain"]).contains(created.path.path))
      try f.raw(["log", "--all", "--oneline"])
      try f.raw(["branch", "-D", "feature"])
      try f.raw(["reflog", "expire", "--expire=now", "--all"])
      try f.raw(["gc", "--prune=now"])
      try f.raw(["fsck", "--full", "--strict"])
      try privateGit.run(["gc"])
      try privateGit.run(["fsck", "--full", "--strict"])
      #expect(try privateGit.run(["cat-file", "-t", feature]) == "commit")
      #expect(try service.publish(projectID: created.projectID) { _ in }.oid == tip)
      #expect(try f.raw(["rev-parse", created.branch]) == tip)
    }
  }

  @Test(arguments: [
    "commondir", "config.worktree", "info/grafts", "shallow",
    "objects/info/alternates", "objects/info/http-alternates", "hooks/pre-commit",
    "refs/replace/root", "refs/heads/linked", "logs/HEAD", "index",
  ])
  func untrustedControlAndLinkedMetadataRefusePublication(path: String) throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let service = try f.service()
      let created = try service.create(name: "control")
      let tip = try f.privateCommit(service, projectID: created.projectID)
      let topology = try service.topology(projectID: created.projectID)
      let target = topology.gitDirectory.url.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      if ["refs/heads/linked", "logs/HEAD", "index"].contains(path) {
        let external = directory.appendingPathComponent("external")
        try Data((tip + "\n").utf8).write(to: external)
        if FileManager.default.fileExists(atPath: target.path) {
          try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: external)
      } else {
        try Data((tip + "\n").utf8).write(to: target)
      }
      #expect(throws: (any Error).self) {
        try service.publish(projectID: created.projectID) { _ in }
      }
      #expect(try f.raw(["rev-parse", created.branch]) != tip)
      #expect(FileManager.default.fileExists(atPath: created.path.path))
    }
  }

  @Test func allPrivateObjectRootsSurviveRemoval() async throws {
    try await removalFixture { f in
      let service = try f.service()
      let created = try service.create(name: "roots")
      let tip = try f.privateCommit(service, projectID: created.projectID)
      let topology = try service.topology(projectID: created.projectID)
      let git = PrivateWorktreeGit(f: f, topology: topology)
      try git.run(["branch", "private-branch"])
      try git.run(["tag", "-a", "private-tag", "-m", "retained"])
      let tag = try git.run(["rev-parse", "private-tag"])
      let blob = try git.run(["hash-object", "-w", "--stdin"], input: Data("retained blob".utf8))
      try git.run(["update-ref", "refs/tags/blob", blob])
      try Data("stash\n".utf8).write(to: created.path.appendingPathComponent("file.txt"))
      try git.run(["stash", "push"])
      let stash = try git.run(["rev-parse", "refs/stash"])
      try git.run(["commit", "--amend", "-m", "amended"])
      _ = try await service.remove(
        projectID: created.projectID, terminate: { _, _ in }, authorize: { _, _ in })
      let retained = try f.recoveryRecords()
      let recovery = try f.recoveryGitDirectory()
      for oid in [tip, tag, blob, stash] {
        #expect(retained.contains { $0.oid == oid })
        try f.raw(["--git-dir=" + recovery.path, "cat-file", "-e", oid])
      }
      #expect(try f.store.records().isEmpty)
    }
  }

  @Test func sourceRepackDuringCopyIsRetryableAndDoesNotActivatePartialStore() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let storage = f.storage
      let source = f.repository
      let executor = f.executor
      let marker = directory.appendingPathComponent("repacked")
      let io = WorktreeJournalIO(beforePublication: {
        guard !FileManager.default.fileExists(atPath: marker.path),
          let entries = FileManager.default.enumerator(atPath: storage.repositories.path),
          entries.allObjects.compactMap({ $0 as? String }).contains(where: {
            $0.contains("/repository/objects/") && $0.hasSuffix(".tmp")
          })
        else { return }
        try Data().write(to: marker)
        let result = try executor.execute(
          .init(
            arguments: ["repack", "-ad"], directory: source,
            environment: HostGitConfiguration.environment(home: directory),
            timeoutMilliseconds: 10_000, maxOutputBytes: 1_048_576))
        guard result.exitCode == 0 else {
          throw WorktreeError.commandFailed("Fixture repack failed.")
        }
        _ = try executor.execute(
          .init(
            arguments: ["prune-packed"], directory: source,
            environment: HostGitConfiguration.environment(home: directory),
            timeoutMilliseconds: 10_000, maxOutputBytes: 1_048_576))
      })
      let service = try WorktreeRepository(
        source: f.source, store: f.store, storage: storage,
        executor: executor, registeredProjectRoots: [source], timeoutMilliseconds: 10_000,
        maxOutputBytes: 1_048_576, lockTimeout: .seconds(1), journalIO: io,
        cloneCreationObjects: false)
      #expect(throws: WorktreeError.self) { try service.create(name: "repack") }
      #expect(FileManager.default.fileExists(atPath: marker.path))
      let record = try #require(f.store.records().first)
      #expect(record.state == .creating)
      let journal = try #require(try service.readJournal(record.projectID))
      #expect(try FileManager.default.contentsOfDirectory(atPath: journal.objects!.path).isEmpty)
      try f.service().recover()
      _ = try f.service().topology(projectID: record.projectID)
    }
  }

  @Test func copyBudgetFailureLeavesNoPartialObjectCopyAndCanRecover() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      var limits = WorktreePromotionLimits()
      limits.inputBytes = 1
      let service = try WorktreeRepository(
        source: f.source, store: f.store, storage: f.storage,
        executor: f.executor, registeredProjectRoots: [f.repository], timeoutMilliseconds: 10_000,
        maxOutputBytes: 1_048_576, lockTimeout: .seconds(1), creationLimits: limits,
        cloneCreationObjects: false)
      #expect(throws: WorktreeError.self) { try service.create(name: "bounded") }
      let record = try #require(f.store.records().first)
      let journal = try #require(try service.readJournal(record.projectID))
      #expect(journal.phase == .directories)
      let objects = try #require(journal.objects)
      #expect(try FileManager.default.contentsOfDirectory(atPath: objects.path).isEmpty)
      try f.service().recover()
      _ = try f.service().topology(projectID: record.projectID)
    }
  }
}
