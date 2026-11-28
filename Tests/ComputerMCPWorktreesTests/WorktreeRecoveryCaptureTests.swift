import Foundation
import Testing

@testable import ComputerMCPWorktrees

struct WorktreeRecoveryCaptureTests {
  @Test(arguments: ["sha1", "sha256"])
  func capturesAllRootsAndSeparateExpectedClosure(format: String) throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory, format: format)
      let service = try f.service()
      let created = try service.create(name: "capture")
      let head = try f.privateCommit(service, projectID: created.projectID)
      let topology = try service.topology(projectID: created.projectID)
      let git = PrivateWorktreeGit(f: f, topology: topology)
      let blob = try git.run(["hash-object", "-w", "--stdin"], input: Data("ref blob".utf8))
      let old = try git.run(["hash-object", "-w", "--stdin"], input: Data("old endpoint".utf8))
      let new = try git.run(["hash-object", "-w", "--stdin"], input: Data("new endpoint".utf8))
      let tree = try git.run(["rev-parse", "HEAD^{tree}"])
      try git.run(["update-ref", "refs/tags/blob", blob])
      try git.run(["update-ref", "refs/tags/tree", tree])
      try git.run(["tag", "-a", "annotated", "-m", "capture"])
      let tag = try git.run(["rev-parse", "refs/tags/annotated"])
      let log = topology.gitDirectory.url.appendingPathComponent("logs/capture")
      try FileManager.default.createDirectory(
        at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("\(old) \(new) Fixture <fixture@example.invalid> 1700000000 +0000\ttest\n".utf8)
        .write(to: log)
      try f.raw(["commit", "--allow-empty", "-m", "source expected"])
      let expected = try f.raw(["rev-parse", "HEAD"])
      let before = try f.raw(["cat-file", "--batch-all-objects", "--batch-check=%(objectname)"])
      var budget = try WorktreeObjectBudget(.init())
      let capture = try service.captureRecoveryObjects(
        topology, expectedOID: expected, in: staging(directory, "capture"), budget: &budget)
      let rootSet = Set(
        [capture.metadata.head] + Array(capture.metadata.refs.values)
          + capture.metadata.reflogRoots.values.flatMap { $0 })
      #expect(Set(capture.metadata.roots) == rootSet)
      #expect(capture.metadata.head == head)
      #expect(capture.metadata.refs["refs/tags/blob"] == blob)
      #expect(capture.metadata.refs["refs/tags/tree"] == tree)
      #expect(capture.metadata.refs["refs/tags/annotated"] == tag)
      #expect(Set(capture.metadata.reflogRoots["capture"] ?? []) == Set([old, new]))
      let privateOIDs = try closure(
        git.run(["rev-list", "--objects", "--no-object-names"] + capture.metadata.roots))
      let headOIDs = try closure(git.run(["rev-list", "--objects", "--no-object-names", head]))
      let expectedOIDs = try closure(
        f.raw(["rev-list", "--objects", "--no-object-names", expected]))
      #expect(Set(capture.privateManifest.oids) == privateOIDs)
      #expect(Set(capture.headManifest.oids) == headOIDs)
      #expect(Set(capture.expectedManifest.oids) == expectedOIDs)
      #expect(!capture.privateManifest.oids.contains(expected))
      #expect(capture.expectedObjects.directory.url.lastPathComponent == "source-objects")
      #expect(Set(capture.sourceExpectedManifest?.oids ?? []) == expectedOIDs)
      #expect(Set(capture.recoveryManifest.oids) == privateOIDs.union(expectedOIDs))
      #expect(Set(capture.sourceManifest.oids) == headOIDs.subtracting(expectedOIDs))
      #expect(
        try f.raw(["cat-file", "--batch-all-objects", "--batch-check=%(objectname)"]) == before)
      #expect(try f.raw(["rev-parse", created.branch]) != head)
    }
  }

  @Test func missingPrivateDependencyCannotBeRepairedFromSource() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let service = try f.service()
      let created = try service.create(name: "broken")
      let topology = try service.topology(projectID: created.projectID)
      let git = PrivateWorktreeGit(f: f, topology: topology)
      try Data("source only".utf8).write(to: f.repository.appendingPathComponent("source-only"))
      try f.raw(["add", "source-only"])
      let sourceTree = try f.raw(["write-tree"])
      let expected = try f.raw(["rev-parse", "HEAD"])
      let content =
        "tree \(sourceTree)\nparent \(expected)\nauthor Fixture <fixture@example.invalid> 1700000000 +0000\ncommitter Fixture <fixture@example.invalid> 1700000000 +0000\n\nbroken\n"
      let head = try git.run(
        ["hash-object", "-w", "-t", "commit", "--stdin"], input: Data(content.utf8))
      try Data((head + "\n").utf8).write(
        to: topology.gitDirectory.url.appendingPathComponent("HEAD"))
      #expect(try f.raw(["cat-file", "-t", sourceTree]) == "tree")
      var budget = try WorktreeObjectBudget(.init())
      #expect(throws: WorktreeError.self) {
        try service.captureRecoveryObjects(
          topology, expectedOID: expected, in: staging(directory, "broken"), budget: &budget)
      }
      #expect(try f.raw(["rev-parse", created.branch]) == expected)
    }
  }

  @Test func privateExpectedDoesNotProveSourcePossession() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let service = try f.service()
      let created = try service.create(name: "source-missing")
      let head = try f.privateCommit(service, projectID: created.projectID)
      let topology = try service.topology(projectID: created.projectID)
      let expected = try f.raw(["rev-parse", "HEAD"])
      let object = f.repository.appendingPathComponent(
        ".git/objects/\(expected.prefix(2))/\(expected.dropFirst(2))")
      try FileManager.default.removeItem(at: object)
      var budget = try WorktreeObjectBudget(.init())
      let capture = try service.captureRecoveryObjects(
        topology, expectedOID: expected, in: staging(directory, "absent"), budget: &budget)
      #expect(capture.metadata.head == head)
      #expect(capture.expectedManifest.entries[expected]?.type == .commit)
      #expect(capture.sourceExpectedManifest == nil)
      #expect(capture.sourceManifest == capture.headManifest)
      #expect(
        capture.recoveryManifest == (try capture.privateManifest.union(capture.expectedManifest)))
    }
  }

  @Test(arguments: [false, true])
  func retainedExpectedUsesIndependentSourcePossession(sourceHasExpected: Bool) throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let service = try f.service()
      let created = try service.create(name: "retained")
      let head = try f.privateCommit(service, projectID: created.projectID)
      let topology = try service.topology(projectID: created.projectID)
      let git = PrivateWorktreeGit(f: f, topology: topology)
      let side = try git.run(["hash-object", "-w", "--stdin"], input: Data("side root".utf8))
      try git.run(["update-ref", "refs/tags/side", side])
      let expected = try sourceExpectedCommit(f)
      let expectedOIDs = try closure(
        f.raw(["rev-list", "--objects", "--no-object-names", expected]))
      let retained = try retainedPool(f, directory: directory)
      if !sourceHasExpected {
        try FileManager.default.removeItem(
          at: looseObject(f.repository.appendingPathComponent(".git/objects"), expected))
      }
      var budget = try WorktreeObjectBudget(.init())
      let capture = try service.captureRecoveryObjects(
        topology, expectedOID: expected, in: staging(directory, "retained-capture"),
        retainedExpectedObjects: retained, budget: &budget)
      let privateOIDs = try closure(
        git.run(["rev-list", "--objects", "--no-object-names"] + capture.metadata.roots))
      let headOIDs = try closure(git.run(["rev-list", "--objects", "--no-object-names", head]))
      #expect(capture.expectedObjects.directory.url.lastPathComponent == "retained-objects")
      #expect(!privateOIDs.contains(expected))
      #expect(privateOIDs.contains(side))
      #expect(Set(capture.privateManifest.oids) == privateOIDs)
      #expect(Set(capture.expectedManifest.oids) == expectedOIDs)
      #expect(Set(capture.recoveryManifest.oids) == privateOIDs.union(expectedOIDs))
      if sourceHasExpected {
        #expect(Set(capture.sourceExpectedManifest?.oids ?? []) == expectedOIDs)
        #expect(Set(capture.sourceManifest.oids) == headOIDs.subtracting(expectedOIDs))
      } else {
        #expect(capture.sourceExpectedManifest == nil)
        #expect(Set(capture.sourceManifest.oids) == headOIDs)
      }
      #expect(try f.raw(["rev-parse", created.branch]) != head)
    }
  }

  @Test func incompleteRetainedExpectedIsRejectedEvenIfSourceHasIt() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let service = try f.service()
      let created = try service.create(name: "incomplete-retained")
      _ = try f.privateCommit(service, projectID: created.projectID)
      let topology = try service.topology(projectID: created.projectID)
      let expected = try sourceExpectedCommit(f)
      let tree = try f.raw(["rev-parse", "HEAD^{tree}"])
      let retained = try retainedPool(f, directory: directory)
      try FileManager.default.removeItem(at: looseObject(retained.url, tree))
      #expect(try f.raw(["cat-file", "-t", tree]) == "tree")
      let branchBefore = try f.raw(["rev-parse", created.branch])
      var budget = try WorktreeObjectBudget(.init())
      do {
        _ = try service.captureRecoveryObjects(
          topology, expectedOID: expected, in: staging(directory, "incomplete"),
          retainedExpectedObjects: retained, budget: &budget)
        Issue.record("Incomplete retained closure was accepted")
      } catch WorktreeError.recoveryRequired {
      } catch {
        Issue.record("Expected recoveryRequired for the incomplete retained closure: \(error)")
      }
      #expect(
        !FileManager.default.fileExists(
          atPath: directory.appendingPathComponent("incomplete/source-objects").path))
      #expect(try f.raw(["rev-parse", created.branch]) == branchBefore)
    }
  }

  @Test func replacedPrivateObjectDirectoryIsRetryable() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let ordinary = try f.service()
      let created = try ordinary.create(name: "replaced-input")
      _ = try f.privateCommit(ordinary, projectID: created.projectID)
      let topology = try ordinary.topology(projectID: created.projectID)
      let expected = try f.raw(["rev-parse", "HEAD"])
      let sourceBefore = try f.raw([
        "cat-file", "--batch-all-objects", "--batch-check=%(objectname)",
      ])
      let replacement = CaptureInputReplacement(
        objects: topology.objects.url, staging: directory.appendingPathComponent("replaced"))
      let service = try f.service(
        journalIO: .init(beforePublication: { try replacement.replace() }))
      var budget = try WorktreeObjectBudget(.init())
      do {
        _ = try service.captureRecoveryObjects(
          topology, expectedOID: expected, in: staging(directory, "replaced"), budget: &budget)
        Issue.record("Replaced live input was accepted")
      } catch WorktreeError.busy {
      } catch {
        Issue.record("Expected retryable busy after input replacement: \(error)")
      }
      #expect(replacement.fired)
      #expect(
        !FileManager.default.fileExists(
          atPath: directory.appendingPathComponent("replaced/source-objects").path))
      #expect(try f.raw(["rev-parse", created.branch]) == expected)
      #expect(
        try f.raw(["cat-file", "--batch-all-objects", "--batch-check=%(objectname)"])
          == sourceBefore)
    }
  }

  @Test(arguments: ["input", "inflated", "count"])
  func acquisitionSharesBudgetAcrossPools(bound: String) throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let service = try f.service()
      let created = try service.create(name: "budget")
      _ = try f.privateCommit(service, projectID: created.projectID)
      let topology = try service.topology(projectID: created.projectID)
      let expected = try f.raw(["rev-parse", "HEAD"])
      var baseline = try WorktreeObjectBudget(.init())
      _ = try service.captureRecoveryObjects(
        topology, expectedOID: expected, in: staging(directory, "baseline"), budget: &baseline)
      var limits = WorktreePromotionLimits()
      switch bound {
      case "input": limits.inputBytes = baseline.input - 1
      case "inflated": limits.inflatedBytes = baseline.inflated - 1
      default: limits.objectCount = baseline.objects - 1
      }
      var bounded = try WorktreeObjectBudget(limits)
      #expect(throws: WorktreeError.self) {
        try service.captureRecoveryObjects(
          topology, expectedOID: expected, in: staging(directory, "bounded"), budget: &bounded)
      }
      #expect(
        FileManager.default.fileExists(
          atPath: directory.appendingPathComponent("bounded/source-objects").path))
      #expect(try f.raw(["rev-parse", created.branch]) == expected)
    }
  }

  @Test func deadlineCoversPrivateVerificationAndSourceAcquisition() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let ordinary = try f.service()
      let created = try ordinary.create(name: "deadline")
      _ = try f.privateCommit(ordinary, projectID: created.projectID)
      let topology = try ordinary.topology(projectID: created.projectID)
      let expected = try f.raw(["rev-parse", "HEAD"])
      let delayed = CaptureDeadlineGit(base: f.executor)
      let service = try f.service(executor: delayed)
      var limits = WorktreePromotionLimits()
      limits.duration = .seconds(5)
      var expired = try WorktreeObjectBudget(limits)
      #expect(throws: WorktreeError.self) {
        try service.captureRecoveryObjects(
          topology, expectedOID: expected, in: staging(directory, "expired"), budget: &expired)
      }
      #expect(delayed.fired)
      #expect(
        !FileManager.default.fileExists(
          atPath: directory.appendingPathComponent("expired/source-objects").path))
      #expect(try f.raw(["rev-parse", created.branch]) == expected)
    }
  }
}

private final class CaptureDeadlineGit: WorktreeGitExecuting, @unchecked Sendable {
  let base: WorktreeTestGit
  var fired = false

  init(base: WorktreeTestGit) { self.base = base }

  func execute(_ command: WorktreeGitCommand) throws -> WorktreeGitResult {
    let result = try base.execute(command)
    if !fired && command.arguments.contains("fsck") {
      fired = true
      Thread.sleep(forTimeInterval: 5.1)
    }
    return result
  }
}

private final class CaptureInputReplacement: @unchecked Sendable {
  let objects: URL
  let staging: URL
  var fired = false

  init(objects: URL, staging: URL) {
    self.objects = objects
    self.staging = staging
  }

  func replace() throws {
    guard !fired,
      let paths = FileManager.default.enumerator(
        atPath: staging.appendingPathComponent("private-objects").path),
      paths.allObjects.contains(where: { ($0 as? String)?.contains(".journal-") == true })
    else { return }
    fired = true
    try FileManager.default.moveItem(
      at: objects, to: objects.deletingLastPathComponent().appendingPathComponent("objects-moved"))
    try FileManager.default.createDirectory(at: objects, withIntermediateDirectories: false)
  }
}

private func sourceExpectedCommit(_ f: WorktreeFixture) throws -> String {
  try Data("expected content".utf8).write(to: f.repository.appendingPathComponent("expected"))
  try f.raw(["add", "expected"])
  try f.raw(["commit", "-m", "expected"])
  return try f.raw(["rev-parse", "HEAD"])
}

private func retainedPool(_ f: WorktreeFixture, directory: URL) throws -> WorktreeDirectory {
  let pool = directory.appendingPathComponent("retained-pool")
  try FileManager.default.copyItem(
    at: f.repository.appendingPathComponent(".git/objects"), to: pool)
  return try WorktreeDirectory(pool)
}

private func looseObject(_ directory: URL, _ oid: String) -> URL {
  directory.appendingPathComponent(String(oid.prefix(2))).appendingPathComponent(
    String(oid.dropFirst(2)))
}

private func staging(_ directory: URL, _ name: String) throws -> WorktreeDirectory {
  let path = directory.appendingPathComponent(name)
  try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
  return try WorktreeDirectory(path)
}

private func closure(_ output: String) throws -> Set<String> {
  Set(output.split(separator: "\n").map(String.init))
}
