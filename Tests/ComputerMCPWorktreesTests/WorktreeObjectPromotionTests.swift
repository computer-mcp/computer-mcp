import Foundation
import Testing

@testable import ComputerMCPWorktrees

struct WorktreeObjectPromotionTests {
  @Test(arguments: ["sha1", "sha256"], [false, true])
  func exactClosurePublishesLooseAndPackedObjects(format: String, packed: Bool) throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory, format: format)
      let service = try f.service()
      let created = try service.create(name: "publication")
      _ = try f.privateCommit(service, projectID: created.projectID)
      let topology = try service.topology(projectID: created.projectID)
      let privateGit = PrivateWorktreeGit(f: f, topology: topology)
      try Data([0, 255, 128, 10, 0]).write(to: created.path.appendingPathComponent("binary"))
      try privateGit.run(["add", "binary"])
      try privateGit.run(["commit", "-m", "binary"])
      let tip = try privateGit.run(["rev-parse", "HEAD"])
      let unused = try privateGit.run(
        ["hash-object", "-w", "--stdin"], input: Data([0, 255, 10, 31]))
      if packed { _ = try privateGit.run(["repack", "-ad", "--cruft"]) }
      let result = try service.publish(projectID: created.projectID) { _ in }
      #expect(result.oid == tip)
      #expect(try f.raw(["rev-parse", "refs/heads/" + created.branch]) == tip)
      let shared = try f.raw(["cat-file", "--batch-all-objects", "--batch-check=%(objectname)"])
      #expect(!shared.split(separator: "\n").contains(Substring(unused)))
      _ = try f.service().topology(projectID: created.projectID)
      #expect(try f.store.records().first?.worktree?.publishedOID == tip)
      #expect(try service.readPublication(created.projectID)?.phase == .finished)
    }
  }
}

struct PrivateWorktreeGit {
  let f: WorktreeFixture
  let topology: VerifiedWorktreeTopology

  @discardableResult func run(_ args: [String], input: Data = Data()) throws -> String {
    var environment = HostGitConfiguration.environment(home: f.directory)
    environment["GIT_ALLOW_PROTOCOL"] = "file"
    environment["GIT_AUTHOR_NAME"] = "Fixture"
    environment["GIT_AUTHOR_EMAIL"] = "fixture@example.invalid"
    environment["GIT_COMMITTER_NAME"] = "Fixture"
    environment["GIT_COMMITTER_EMAIL"] = "fixture@example.invalid"
    let result = try f.executor.execute(
      .init(
        arguments: HostGitConfiguration.arguments + [
          "--git-dir=" + topology.gitDirectory.url.path,
          "--work-tree=" + topology.root.url.path,
        ] + args,
        directory: topology.root.url, environment: environment, input: input,
        timeoutMilliseconds: 10_000, maxOutputBytes: 1_048_576))
    guard result.exitCode == 0 else {
      throw WorktreeError.commandFailed(String(decoding: result.error, as: UTF8.self))
    }
    return String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .newlines)
  }
}

extension WorktreeObjectPromotionTests {
  @Test(arguments: [
    "corrupt", "false-name", "missing", "symlink", "hardlink", "alternate", "shadow", "pack-index",
    "corrupt-pack", "replace", "head-symlink", "input-limit", "count-limit", "inflate-limit",
    "pack-inflate-limit",
  ])
  func hostileOrIncompleteObjectsNeverReachSharedStorage(kind: String) throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let service = try f.service()
      let created = try service.create(name: "reject")
      let base = try f.raw(["rev-parse", "HEAD"])
      let tip = try f.privateCommit(service, projectID: created.projectID)
      let topology = try service.topology(projectID: created.projectID)
      let privateGit = PrivateWorktreeGit(f: f, topology: topology)
      let commit = topology.objects.url.appendingPathComponent(String(tip.prefix(2)))
        .appendingPathComponent(String(tip.dropFirst(2)))
      let original = try Data(contentsOf: commit)
      var limits = WorktreePromotionLimits()
      switch kind {
      case "corrupt":
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: commit.path)
        try Data([1, 2, 3]).write(to: commit)
      case "false-name":
        try original.write(
          to: commit.deletingLastPathComponent().appendingPathComponent(
            String(repeating: "0", count: 38)))
      case "missing": try FileManager.default.removeItem(at: commit)
      case "symlink":
        let outside = directory.appendingPathComponent("outside")
        try original.write(to: outside)
        try FileManager.default.removeItem(at: commit)
        try FileManager.default.createSymbolicLink(at: commit, withDestinationURL: outside)
      case "hardlink":
        try FileManager.default.linkItem(
          at: commit, to: directory.appendingPathComponent("hardlink"))
      case "alternate":
        let info = topology.objects.url.appendingPathComponent("info")
        try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        try Data((directory.path + "\n").utf8).write(to: info.appendingPathComponent("alternates"))
      case "shadow":
        let folder = topology.objects.url.appendingPathComponent(String(base.prefix(2)))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let shadow = folder.appendingPathComponent(String(base.dropFirst(2)))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: shadow.path)
        try original.write(to: shadow)
      case "head-symlink":
        let head = topology.gitDirectory.url.appendingPathComponent("HEAD")
        let outside = directory.appendingPathComponent("head")
        try Data(contentsOf: head).write(to: outside)
        try FileManager.default.removeItem(at: head)
        try FileManager.default.createSymbolicLink(at: head, withDestinationURL: outside)
      case "replace":
        try f.raw(["update-ref", "refs/replace/" + base, base])
      case "pack-index", "corrupt-pack":
        try privateGit.run(["repack", "-ad"])
        let pack = topology.objects.url.appendingPathComponent("pack")
        let index = try FileManager.default.contentsOfDirectory(
          at: pack, includingPropertiesForKeys: nil
        ).first { $0.pathExtension == (kind == "pack-index" ? "idx" : "pack") }!
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
        var data = try Data(contentsOf: index)
        data[data.count - 1] ^= 1
        try data.write(to: index)
      case "input-limit": limits.inputBytes = 1
      case "count-limit": limits.objectCount = 1
      case "inflate-limit", "pack-inflate-limit":
        let blob = Data(repeating: 0, count: 1_048_576)
        _ = try privateGit.run(["hash-object", "-w", "--stdin"], input: blob)
        if kind == "pack-inflate-limit" { try privateGit.run(["repack", "-ad", "--cruft"]) }
        limits.objectBytes = 1024
      default: Issue.record("Unknown fixture")
      }
      let before = try f.raw(["cat-file", "--batch-all-objects", "--batch-check=%(objectname)"])
      do {
        _ = try service.publish(projectID: created.projectID, limits: limits) { _ in }
        Issue.record("Invalid input was published")
      } catch {
        if kind == "head-symlink" {
          switch error {
          case WorktreeError.busy: break
          default: Issue.record("Mutable HEAD capture failure must be retryable busy")
          }
        }
      }
      #expect(try f.raw(["rev-parse", "refs/heads/" + created.branch]) == base)
      if kind == "corrupt" {
        #expect(try service.readPublication(created.projectID)?.rejection?.isEmpty == false)
      }
      #expect(
        try f.raw(["cat-file", "--batch-all-objects", "--batch-check=%(objectname)"]) == before)
    }
  }

  @Test func capturedHeadSurvivesConcurrentCommitAndRepack() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let original = try f.service()
      let created = try original.create(name: "concurrent")
      let first = try f.privateCommit(original, projectID: created.projectID)
      let topology = try original.topology(projectID: created.projectID)
      let privateGit = PrivateWorktreeGit(f: f, topology: topology)
      let hook = PublicationTestGit(base: f.executor) { command in
        if command.arguments.contains("fsck") {
          try privateGit.run(["commit", "--allow-empty", "-m", "later"])
          try privateGit.run(["gc", "--prune=now"])
        }
      }
      let service = try f.service(executor: hook)
      let result = try service.publish(projectID: created.projectID) { _ in }
      #expect(result.oid == first)
      #expect(try privateGit.run(["rev-parse", "HEAD"]) != first)
      let later = try service.publish(projectID: created.projectID) { _ in }
      #expect(later.oid == (try privateGit.run(["rev-parse", "HEAD"])))
    }
  }

  @Test(arguments: ["amend", "rebase"])
  func rewrittenPublishedTipRetainsRecoveryRoot(rewrite: String) throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let service = try f.service()
      let created = try service.create(name: "amend")
      let first = try f.privateCommit(service, projectID: created.projectID)
      _ = try service.publish(projectID: created.projectID) { _ in }
      let privateGit = PrivateWorktreeGit(
        f: f, topology: try service.topology(projectID: created.projectID))
      if rewrite == "amend" {
        try privateGit.run(["commit", "--amend", "--allow-empty", "-m", "replacement"])
      } else {
        try f.raw(["commit", "--allow-empty", "-m", "advance main"])
        try privateGit.run(["fetch", "origin"])
        try privateGit.run(["rebase", "origin/main"])
      }
      let second = try service.publish(projectID: created.projectID) { _ in }
      #expect(first != second.oid)
      let before = try #require(try f.recoveryRecords().first { $0.oid == first })
      #expect(before.claims.contains { $0.reason == .publishedReplacement })
      try f.raw(["gc", "--prune=now"])
      let recovery = try f.recoveryGitDirectory()
      #expect(try f.raw(["--git-dir=" + recovery.path, "cat-file", "-t", first]) == "commit")
      try service.acknowledgeReplacement(
        projectID: created.projectID, replacedOID: first,
        expectedPublishedOID: second.oid
      ) { _ in }
      try service.acknowledgeReplacement(
        projectID: created.projectID, replacedOID: first,
        expectedPublishedOID: second.oid
      ) { _ in }
      let after = try #require(try f.recoveryRecords().first { $0.id == before.id })
      #expect(!after.claims.contains { $0.reason == .publishedReplacement })
      #expect(!after.acknowledgements.isEmpty)
      #expect(try f.raw(["for-each-ref", "refs/computer-mcp/recovery/"]).isEmpty)
    }
  }
}

final class PublicationTestGit: WorktreeGitExecuting, @unchecked Sendable {
  let base: WorktreeTestGit
  let action: (WorktreeGitCommand) throws -> Void
  var fired = false
  init(base: WorktreeTestGit, action: @escaping (WorktreeGitCommand) throws -> Void) {
    self.base = base
    self.action = action
  }
  func execute(_ command: WorktreeGitCommand) throws -> WorktreeGitResult {
    if !fired && command.arguments.contains("fsck") {
      fired = true
      try action(command)
    }
    return try base.execute(command)
  }
  func executeBounded(
    _ command: WorktreeGitCommand, fileOutput: WorktreeGitFileOutput?, fileSizeLimit: Int?
  ) throws -> WorktreeGitResult {
    try base.executeBounded(command, fileOutput: fileOutput, fileSizeLimit: fileSizeLimit)
  }
  func withPreparedTransaction(_ command: WorktreeGitCommand, _ body: () throws -> Void) throws {
    try base.withPreparedTransaction(command, body)
  }
}

extension WorktreeObjectPromotionTests {
  @Test func generatedPackCannotPromoteUnlistedObjects() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let original = try f.service()
      let created = try original.create(name: "extra")
      let base = try f.raw(["rev-parse", "HEAD"])
      _ = try f.privateCommit(original, projectID: created.projectID)
      let privateGit = PrivateWorktreeGit(
        f: f, topology: try original.topology(projectID: created.projectID))
      let unused = try privateGit.run(["hash-object", "-w", "--stdin"], input: Data("unused".utf8))
      let service = try f.service(executor: ExtraPackObject(base: f.executor, oid: unused))
      #expect(throws: WorktreeError.self) {
        try service.publish(projectID: created.projectID) { _ in }
      }
      #expect(try f.raw(["rev-parse", "refs/heads/" + created.branch]) == base)
    }
  }

  @Test(arguments: ["tree", "parent"])
  func missingCommitDependenciesAreRejected(dependency: String) throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let service = try f.service()
      let created = try service.create(name: "missing")
      let base = try f.raw(["rev-parse", "HEAD"])
      let topology = try service.topology(projectID: created.projectID)
      let privateGit = PrivateWorktreeGit(f: f, topology: topology)
      let missing = String(repeating: "1", count: 40)
      let tree = dependency == "tree" ? missing : try privateGit.run(["rev-parse", "HEAD^{tree}"])
      let parent = dependency == "parent" ? missing : base
      let content =
        "tree \(tree)\nparent \(parent)\nauthor Fixture <fixture@example.invalid> 1700000000 +0000\ncommitter Fixture <fixture@example.invalid> 1700000000 +0000\n\nmissing\n"
      let tip = try privateGit.run(
        ["hash-object", "-w", "-t", "commit", "--stdin"], input: Data(content.utf8))
      try Data((tip + "\n").utf8).write(
        to: topology.gitDirectory.url.appendingPathComponent("HEAD"))
      #expect(throws: WorktreeError.self) {
        try service.publish(projectID: created.projectID) { _ in }
      }
      #expect(try f.raw(["rev-parse", "refs/heads/" + created.branch]) == base)
    }
  }
}

private struct ExtraPackObject: WorktreeGitExecuting {
  let base: WorktreeTestGit
  let oid: String
  func execute(_ original: WorktreeGitCommand) throws -> WorktreeGitResult {
    var command = original
    if command.arguments.contains("pack-objects") { command.input.append(Data((oid + "\n").utf8)) }
    return try base.execute(command)
  }
  func executeBounded(
    _ original: WorktreeGitCommand, fileOutput: WorktreeGitFileOutput?, fileSizeLimit: Int?
  ) throws -> WorktreeGitResult {
    var command = original
    if command.arguments.contains("pack-objects") { command.input.append(Data((oid + "\n").utf8)) }
    return try base.executeBounded(command, fileOutput: fileOutput, fileSizeLimit: fileSizeLimit)
  }

}

extension WorktreeObjectPromotionTests {
  @Test func repackDuringDescriptorCopyIsRetryable() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let original = try f.service()
      let created = try original.create(name: "copy-race")
      let tip = try f.privateCommit(original, projectID: created.projectID)
      let privateGit = PrivateWorktreeGit(
        f: f, topology: try original.topology(projectID: created.projectID))
      let mutation = CopyRace(f: f, projectID: created.projectID, git: privateGit)
      let service = try f.service(journalIO: .init(beforePublication: { try mutation.check() }))
      do {
        #expect(try service.publish(projectID: created.projectID) { _ in }.oid == tip)
      } catch WorktreeError.busy {
        #expect(try original.publish(projectID: created.projectID) { _ in }.oid == tip)
      }
      #expect(mutation.fired)
      #expect(try f.raw(["rev-parse", "refs/heads/" + created.branch]) == tip)
    }
  }
}

private final class CopyRace: @unchecked Sendable {
  let f: WorktreeFixture
  let projectID: String
  let git: PrivateWorktreeGit
  var fired = false
  init(f: WorktreeFixture, projectID: String, git: PrivateWorktreeGit) {
    self.f = f
    self.projectID = projectID
    self.git = git
  }
  func check() throws {
    guard !fired,
      let data = try? Data(
        contentsOf: f.storage.journals.appendingPathComponent("publications/" + projectID + ".json")
      ),
      let journal = try? JSONDecoder().decode(WorktreePublicationJournal.self, from: data),
      journal.phase == .captured,
      let key = try? WorktreeRecoveryStore.key(for: journal.repository),
      let enumerator = FileManager.default.enumerator(
        atPath: f.storage.recovery.appendingPathComponent(
          "stores/" + key + "/staging/" + journal.operationID.uuidString.lowercased()
            + "/private-objects"
        ).path),
      enumerator.allObjects.contains(where: { ($0 as? String)?.contains(".journal-") == true })
    else { return }
    fired = true
    try git.run(["gc", "--prune=now"])
    try git.run(["repack", "-ad"])
  }
}
