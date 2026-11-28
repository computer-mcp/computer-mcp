import Foundation
import Testing

@testable import ComputerMCPWorktrees

struct WorktreeMergeTests {
  @Test(arguments: ["sha1", "sha256"])
  func fastForwardPreservesUnrelatedTrackedAndStagedEdits(format: String) throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory, format: format)
      for name in ["staged", "unstaged"] {
        try Data("base\n".utf8).write(to: f.repository.appendingPathComponent(name))
      }
      try f.raw(["add", "."])
      try f.raw(["commit", "-m", "unrelated"])
      let service = try f.service()
      let created = try service.create(name: "merge")
      let tip = try f.privateCommit(service, projectID: created.projectID)
      try f.raw(["branch", "other"])
      for name in ["staged", "unstaged"] {
        try Data("owner\n".utf8).write(to: f.repository.appendingPathComponent(name))
      }
      try f.raw(["add", "staged"])
      var lockedChecks = 0
      let result = try service.merge(projectID: created.projectID) { _, paths in
        guard !paths.isEmpty else { return }
        #expect(paths == [f.repository.appendingPathComponent("file.txt")])
        if FileManager.default.fileExists(
          atPath: f.repository.appendingPathComponent(".git/HEAD.lock").path)
        {
          lockedChecks += 1
          #expect(
            FileManager.default.fileExists(
              atPath: f.repository.appendingPathComponent(".git/index.lock").path))
          #expect(throws: (any Error).self) {
            try f.raw(["symbolic-ref", "HEAD", "refs/heads/other"])
          }
          #expect(throws: (any Error).self) { try f.raw(["update-ref", "refs/heads/main", tip]) }
          #expect(throws: (any Error).self) { try f.raw(["switch", "other"]) }
        }
      }
      #expect(lockedChecks > 0)
      #expect(result.oid == tip)
      #expect(try f.raw(["rev-parse", "HEAD"]) == tip)
      #expect(try f.raw(["diff", "--cached", "--name-only"]) == "staged")
      #expect(try f.raw(["diff", "--name-only"]) == "unstaged")
      #expect(try f.store.records().first?.worktree?.mergedOID == tip)
      #expect(try service.readMerge(created.projectID)?.phase == .finished)
      // A later publication retains the merge receipt and immutable base identity.
      _ = try service.publish(projectID: created.projectID) { _ in }
      #expect(try f.store.records().first?.worktree?.mergedOID == tip)
      _ = try service.topology(projectID: created.projectID)
    }
  }

  @Test(arguments: ["tracked", "staged", "untracked", "ignored", "index-lock", "assume-unchanged"])
  func overwriteHazardsRefuseWithoutChangingMain(kind: String) throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let service = try f.service()
      let created = try service.create(name: "hazard")
      let base = try f.raw(["rev-parse", "HEAD"])
      _ = try f.privateCommit(service, projectID: created.projectID)
      let privateGit = PrivateWorktreeGit(
        f: f, topology: try service.topology(projectID: created.projectID))
      try Data("incoming\n".utf8).write(to: created.path.appendingPathComponent("incoming"))
      try privateGit.run(["add", "incoming"])
      try privateGit.run(["commit", "-m", "incoming"])
      let collision = ["untracked", "ignored"].contains(kind) ? "incoming" : "file.txt"
      try Data("owner\n".utf8).write(to: f.repository.appendingPathComponent(collision))
      if kind == "staged" { try f.raw(["add", "file.txt"]) }
      if kind == "ignored" {
        try Data("incoming\n".utf8).write(
          to: f.repository.appendingPathComponent(".git/info/exclude"))
      }
      if kind == "index-lock" {
        try Data("foreign\n".utf8).write(to: f.repository.appendingPathComponent(".git/index.lock"))
      }
      if kind == "assume-unchanged" {
        try f.raw(["update-index", "--assume-unchanged", "file.txt"])
      }
      let index = try Data(contentsOf: f.repository.appendingPathComponent(".git/index"))
      #expect(throws: (any Error).self) {
        try service.merge(projectID: created.projectID) { _, _ in }
      }
      #expect(try f.raw(["rev-parse", "HEAD"]) == base)
      #expect(
        try Data(contentsOf: f.repository.appendingPathComponent(collision)) == Data("owner\n".utf8)
      )
      #expect(try Data(contentsOf: f.repository.appendingPathComponent(".git/index")) == index)
      if kind == "index-lock" {
        #expect(
          try String(
            contentsOf: f.repository.appendingPathComponent(".git/index.lock"), encoding: .utf8)
            == "foreign\n")
      }
    }
  }

  @Test(arguments: ["non-ff", "detached", "wrong-base", "symbolic-base", "head-chain", "pseudoref"])
  func baseAndHeadConstraintsRefuse(kind: String) throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let service = try f.service()
      let created = try service.create(name: "base")
      _ = try f.privateCommit(service, projectID: created.projectID)
      let old = try f.raw(["rev-parse", "HEAD"])
      try f.raw(["branch", "other"])
      switch kind {
      case "non-ff": try f.raw(["commit", "--allow-empty", "-m", "owner"])
      case "detached": try f.raw(["checkout", "--detach"])
      case "wrong-base": try f.raw(["symbolic-ref", "HEAD", "refs/heads/other"])
      case "symbolic-base": try f.raw(["symbolic-ref", "refs/heads/main", "refs/heads/other"])
      case "head-chain":
        try f.raw(["symbolic-ref", "refs/heads/other", "refs/heads/main"])
        try f.raw(["symbolic-ref", "HEAD", "refs/heads/other"])
      default: try f.raw(["symbolic-ref", "ORIG_HEAD", "refs/heads/other"])
      }
      let main = try f.raw(["rev-parse", "HEAD"])
      #expect(throws: (any Error).self) {
        try service.merge(projectID: created.projectID) { _, _ in }
      }
      #expect(try f.raw(["rev-parse", "HEAD"]) == main)
      #expect(try f.raw(["rev-parse", "other"]) == old)
      #expect(
        try String(contentsOf: f.repository.appendingPathComponent("file.txt"), encoding: .utf8)
          == "initial\n")
    }
  }

  @Test(arguments: ["current", "incoming", "info", "global"])
  func filterAttributesNeverRunPrograms(location: String) throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      if location == "current" {
        try Data("file.txt filter=sentinel\n".utf8).write(
          to: f.repository.appendingPathComponent(".gitattributes"))
        try f.raw(["add", ".gitattributes"])
        try f.raw(["commit", "-m", "attributes"])
      }
      let service = try f.service()
      let created = try service.create(name: "filter")
      _ = try f.privateCommit(service, projectID: created.projectID)
      if location == "incoming" {
        let privateGit = PrivateWorktreeGit(
          f: f, topology: try service.topology(projectID: created.projectID))
        try Data("file.txt filter=sentinel\n".utf8).write(
          to: created.path.appendingPathComponent(".gitattributes"))
        try privateGit.run(["add", ".gitattributes"])
        try privateGit.run(["commit", "-m", "incoming attributes"])
      }
      if location == "info" {
        try Data("file.txt filter=sentinel\n".utf8).write(
          to: f.repository.appendingPathComponent(".git/info/attributes"))
      }
      if location == "global" {
        let attributes = directory.appendingPathComponent("global-attributes")
        try Data("file.txt filter=sentinel\n".utf8).write(to: attributes)
        try f.raw(["config", "core.attributesFile", attributes.path])
      }
      let marker = directory.appendingPathComponent("executed")
      try f.raw(["config", "filter.sentinel.smudge", "touch " + marker.path])
      try f.raw(["config", "filter.sentinel.clean", "touch " + marker.path])
      try f.raw(["config", "filter.sentinel.required", "true"])
      #expect(throws: (any Error).self) {
        try service.merge(projectID: created.projectID) { _, _ in }
      }
      #expect(!FileManager.default.fileExists(atPath: marker.path))
      #expect(
        try String(contentsOf: f.repository.appendingPathComponent("file.txt"), encoding: .utf8)
          == "initial\n")
    }
  }

  @Test func nestedDestinationNeedsItsOwnCurrentAuthority() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let service = try f.service(roots: [
        f.repository, f.repository.appendingPathComponent("nested"),
      ])
      let created = try service.create(name: "nested")
      let privateGit = PrivateWorktreeGit(
        f: f, topology: try service.topology(projectID: created.projectID))
      try FileManager.default.createDirectory(
        at: created.path.appendingPathComponent("nested"), withIntermediateDirectories: false)
      try Data("nested\n".utf8).write(to: created.path.appendingPathComponent("nested/file"))
      try privateGit.run(["add", "nested"])
      try privateGit.run(["commit", "-m", "nested project"])
      let old = try f.raw(["rev-parse", "HEAD"])
      var checked = false
      #expect(throws: CancellationError.self) {
        try service.merge(projectID: created.projectID) { _, paths in
          if paths.contains(f.repository.appendingPathComponent("nested/file")) {
            checked = true
            throw CancellationError()
          }
        }
      }
      #expect(checked)
      #expect(try f.raw(["rev-parse", "HEAD"]) == old)
      #expect(
        !FileManager.default.fileExists(atPath: f.repository.appendingPathComponent("nested").path))
      let result = try service.merge(projectID: created.projectID) { _, _ in }
      #expect(try f.raw(["rev-parse", "HEAD"]) == result.oid)
    }
  }
}
