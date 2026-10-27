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
      #expect(throws: WorktreeError.self) {
        try io.write(next, name: "operation.json", in: directory, replacing: next)
      }
      try io.write(next, name: "operation.json", in: directory, replacing: first)
      #expect(try io.read("operation.json", in: directory, limit: 100) == next)
      #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["operation.json"])
    }
  }

  @Test func publicationAndDirectorySyncFailuresRetainObservedState() throws {
    try fixture { root in
      let directory = try WorktreeDirectory(root)
      let data = Data("intent".utf8)
      let before = WorktreeJournalIO(beforePublication: { throw POSIXError(.ENOSPC) })
      #expect(throws: POSIXError.self) {
        try before.write(data, name: "operation.json", in: directory, replacing: nil)
      }
      #expect(try before.read("operation.json", in: directory, limit: 100) == nil)
      let after = WorktreeJournalIO(beforeDirectorySync: { throw POSIXError(.EIO) })
      #expect(throws: POSIXError.self) {
        try after.write(data, name: "operation.json", in: directory, replacing: nil)
      }
      #expect(try after.read("operation.json", in: directory, limit: 100) == data)
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
