import Foundation
import Testing

@testable import ComputerMCPWorktrees

struct WorktreeInventoryTests {
  @Test func privateHeadCountsDirtyAndForeignCheckout() throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let foreign = directory.appendingPathComponent("foreign checkout")
      try f.raw(["worktree", "add", "-b", "foreign", foreign.path])
      let service = try f.service()
      let created = try service.create(name: "inventory")
      _ = try f.privateCommit(service, projectID: created.projectID)
      try f.raw(["commit", "--allow-empty", "-m", "base advances"])
      try Data("untracked\n".utf8).write(to: created.path.appendingPathComponent("untracked"))
      let items = try service.inventory { _ in true }
      #expect(items.count == 3)
      let host = try #require(items.first { $0.projectID == created.projectID })
      #expect(host.path == created.path.path)
      #expect(host.branch == created.branch && host.base == "main")
      #expect(host.ahead == 1 && host.behind == 1 && host.dirty == true)
      #expect(host.unavailable == nil)
      let external = try #require(items.first { $0.path == foreign.path })
      #expect(external.projectID == nil && external.base == nil && external.ahead == nil)
      #expect(external.branch == "foreign" && external.dirty == false)
      #expect(external.unavailable != nil)
      #expect(try f.store.records().count == 1)
      let hidden = try service.inventory { $0.path != foreign.path }
      let redacted = try #require(hidden.first { $0.path == nil })
      #expect(redacted.projectID == nil && redacted.branch == nil && redacted.dirty == nil)
    }
  }

  @Test(arguments: ["missing", "moved", "backlink", "head", "indirection", "alternate"])
  func invalidTopologyIsUnavailableAndRetained(fault: String) throws {
    try fixture { directory in
      let f = try WorktreeFixture(directory)
      let service = try f.service()
      let created = try service.create(name: "topology")
      let topology = try service.topology(projectID: created.projectID)
      switch fault {
      case "missing":
        try FileManager.default.moveItem(
          at: topology.gitDirectory.url, to: directory.appendingPathComponent("retained-gitdir"))
      case "moved":
        let old = topology.gitDirectory.url
        try FileManager.default.moveItem(at: old, to: old.appendingPathExtension("moved"))
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false)
      case "backlink":
        try Data((f.repository.path + "/.git\n").utf8).write(
          to: topology.gitDirectory.url.appendingPathComponent("gitdir"))
      case "alternate":
        let info = topology.objects.url.appendingPathComponent("info")
        try FileManager.default.createDirectory(at: info, withIntermediateDirectories: false)
        try Data((topology.sharedObjects.url.path + "\n").utf8).write(
          to: info.appendingPathComponent("alternates"))
      case "head":
        try Data("ref: refs/heads/main\n".utf8).write(
          to: topology.gitDirectory.url.appendingPathComponent("HEAD"))
      default:
        let pointer = created.path.appendingPathComponent(".git")
        let retained = directory.appendingPathComponent("retained-pointer")
        try FileManager.default.moveItem(at: pointer, to: retained)
        try FileManager.default.createSymbolicLink(at: pointer, withDestinationURL: retained)
      }
      #expect(throws: (any Error).self) { try service.topology(projectID: created.projectID) }
      if fault == "backlink" {
        // A backlink aimed at main produces duplicate paths in Git's inventory.
        // Refuse the ambiguous inventory instead of attaching either registration.
        #expect(throws: WorktreeError.self) { try service.inventory { _ in true } }
      } else {
        let items = try service.inventory { _ in true }
        for item in items where item.path == created.path.path {
          #expect(item.projectID == nil && item.unavailable != nil)
        }
      }
      #expect(
        FileManager.default.fileExists(atPath: created.path.appendingPathComponent("file.txt").path)
      )
      #expect(try f.store.records().count == 1)
    }
  }

  @Test func parserPreservesNulPathsAndRefusesMalformedInventory() throws {
    let data = Data(
      "worktree /fixture/space path\0HEAD abc\0branch refs/heads/main\0\0worktree /fixture/new\nline\0HEAD def\0detached\0locked reason\0\0"
        .utf8)
    let entries = try WorktreeInventoryEntry.parse(data)
    #expect(entries.map(\.path) == ["/fixture/space path", "/fixture/new\nline"])
    for bad in [
      "worktree relative\0bare\0\0", "worktree /a\0bare\0bare\0\0", "worktree /a\0HEAD x\0\0",
      "worktree /a",
    ] {
      #expect(throws: WorktreeError.self) { try WorktreeInventoryEntry.parse(Data(bad.utf8)) }
    }
  }
}
