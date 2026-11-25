import Foundation
import Testing

@testable import ComputerMCPWorktrees

struct WorktreeJournalTests {
  @Test func exclusiveCreationAndExpectedContentReplacement() throws {
    try fixture { root in
      let directory = try WorktreeDirectory(root)
      let io = WorktreeJournalIO()
      let first = Data("intent".utf8)
      let next = Data("observed".utf8)
      try io.write(first, name: "operation.json", in: directory, replacing: nil)
      #expect(try io.read("operation.json", in: directory, limit: 100) == first)
      #expect(throws: WorktreeError.self) {
        try io.write(next, name: "operation.json", in: directory, replacing: nil)
      }
      #expect(try io.read("operation.json", in: directory, limit: 100) == first)
      #expect(throws: WorktreeError.self) {
        try io.write(next, name: "operation.json", in: directory, replacing: next)
      }
      try io.write(next, name: "operation.json", in: directory, replacing: first)
      #expect(try io.read("operation.json", in: directory, limit: 100) == next)
      #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["operation.json"])
    }
  }

  @Test func failedPreparationLeavesNoPublicJournal() throws {
    try fixture { root in
      let directory = try WorktreeDirectory(root)
      let data = Data("intent".utf8)
      let before = WorktreeJournalIO(beforePublication: { throw POSIXError(.ENOSPC) })
      #expect(throws: POSIXError.self) {
        try before.write(data, name: "operation.json", in: directory, replacing: nil)
      }
      #expect(try before.read("operation.json", in: directory, limit: 100) == nil)
      #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
  }

  @Test func firstPublicationBeforeDirectorySyncReplaysTheSameInode() throws {
    try fixture { root in
      let directory = try WorktreeDirectory(root)
      let name = "operation.json"
      let path = root.appendingPathComponent(name).path
      let data = Data("intent".utf8)
      let io = WorktreeJournalIO()
      let interrupted = WorktreeJournalIO(
        beforePublication: {
          let directory = try WorktreeDirectory(root)
          let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
          let temporary = try #require(entries.first)
          #expect(entries.count == 1)
          #expect(temporary.hasPrefix(".journal-"))
          #expect(try io.read(temporary, in: directory, limit: data.count) == data)
          #expect(try io.read(name, in: directory, limit: data.count) == nil)
        },
        beforeDirectorySync: {
          let directory = try WorktreeDirectory(root)
          #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [name])
          #expect(try io.read(name, in: directory, limit: data.count) == data)
          throw POSIXError(.EIO)
        })
      #expect(throws: POSIXError(.EIO)) {
        try interrupted.write(data, name: name, in: directory, replacing: nil)
      }
      let attributes = try FileManager.default.attributesOfItem(atPath: path)
      let inode = try #require(attributes[.systemFileNumber] as? NSNumber)
      let mode = try #require(attributes[.posixPermissions] as? NSNumber)
      #expect(mode.intValue & 0o077 == 0)
      #expect(throws: WorktreeError.self) {
        try io.synchronize(name, in: directory, expecting: Data("other!".utf8))
      }
      try io.synchronize(name, in: directory, expecting: data)
      let replayed = try FileManager.default.attributesOfItem(atPath: path)
      #expect(replayed[.systemFileNumber] as? NSNumber == inode)
      #expect(try io.read(name, in: directory, limit: data.count) == data)
    }
  }

  @Test func hostileTargetsAndSizeLimitsRefuse() throws {
    try fixture { root in
      let directory = try WorktreeDirectory(root)
      let io = WorktreeJournalIO()
      let path = root.appendingPathComponent("operation.json")
      let target = root.appendingPathComponent("target")
      try Data("retained".utf8).write(to: target)
      try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
      #expect(throws: (any Error).self) {
        try io.write(Data(), name: "operation.json", in: directory, replacing: nil)
      }
      #expect(try String(contentsOf: target, encoding: .utf8) == "retained")
      #expect(throws: WorktreeError.self) { try io.read("../target", in: directory, limit: 100) }
      #expect(throws: WorktreeError.self) { try io.read("target", in: directory, limit: 2) }
    }
  }
}
