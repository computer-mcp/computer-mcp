import Foundation
import Testing

@testable import ComputerMCPWorktrees

struct WorktreeRecoveryPackInstallTests {
  @Test func resumesVisiblePackBeforeIndexAndRetiresOnlyOwnedKeep() throws {
    try fixture { root in
      let directory = try WorktreeDirectory(root)
      let stage = try directory.child("stage", create: true)
      let destination = try directory.child("destination", create: true)
      let pack = try artifact(in: stage)
      let prefix = "pack-" + pack.hash
      let packURL = destination.url.appendingPathComponent(prefix + ".pack")
      let indexURL = destination.url.appendingPathComponent(prefix + ".idx")
      let keepURL = destination.url.appendingPathComponent(prefix + ".keep")
      let failure = WorktreeJournalIO(beforeDirectorySync: {
        if FileManager.default.fileExists(atPath: packURL.path),
          !FileManager.default.fileExists(atPath: indexURL.path)
        {
          throw CancellationError()
        }
      })
      var install = WorktreeRecoveryPackInstall(
        operationID: UUID(), generation: UUID(), destination: destination, pack: pack)
      var journal = Data()
      #expect(throws: CancellationError.self) {
        try install.install(
          from: stage, into: destination, format: .sha1, io: failure,
          deadline: .now.advanced(by: .seconds(10)), verify: {},
          persist: { journal = try JSONEncoder().encode($0) })
      }
      #expect(try destination.entries(limit: 3) == [prefix + ".keep", prefix + ".pack"])
      #expect(try stage.entries(limit: 2) == ["objects.idx"])
      install = try JSONDecoder().decode(WorktreeRecoveryPackInstall.self, from: journal)
      try install.install(
        from: stage, into: destination, format: .sha1, io: .init(),
        deadline: .now.advanced(by: .seconds(10)), verify: {}, persist: { _ in })
      #expect(try stage.entries(limit: 0).isEmpty)
      #expect(
        try WorktreeRecoveryStageFile.read(
          prefix + ".pack", in: destination, limit: pack.pack.bytes)
          == pack.pack)
      #expect(
        try WorktreeRecoveryStageFile.read(
          prefix + ".idx", in: destination, limit: pack.index.bytes)
          == pack.index)
      try install.releaseKeep(in: destination, io: .init())
      try install.releaseKeep(in: destination, io: .init())
      #expect(!FileManager.default.fileExists(atPath: keepURL.path))
    }
  }

  @Test func foreignKeepRefusesInstallationWithoutChangingEitherDirectory() throws {
    try fixture { root in
      let directory = try WorktreeDirectory(root)
      let stage = try directory.child("stage", create: true)
      let destination = try directory.child("destination", create: true)
      let pack = try artifact(in: stage)
      let keep = "pack-" + pack.hash + ".keep"
      let bytes = Data("independent operation\n".utf8)
      try WorktreeJournalIO().write(bytes, name: keep, in: destination, replacing: nil)
      var install = WorktreeRecoveryPackInstall(
        operationID: UUID(), generation: UUID(), destination: destination, pack: pack)
      #expect(throws: WorktreeError.self) {
        try install.install(
          from: stage, into: destination, format: .sha1, io: .init(),
          deadline: .now.advanced(by: .seconds(10)), verify: {}, persist: { _ in })
      }
      #expect(try destination.entries(limit: 1) == [keep])
      #expect(try WorktreeJournalIO().read(keep, in: destination, limit: 32) == bytes)
      #expect(try stage.entries(limit: 2) == ["objects.idx", "objects.pack"])
    }
  }

  private func artifact(in stage: WorktreeDirectory) throws -> WorktreeRecoveryPack {
    // This fixture exercises transfer of a verified receipt. Generation and
    // Git pack/index validation belong to the pack-generation tests.
    let pack = Data("pack payload\n".utf8)
    let index = Data("index payload\n".utf8)
    let io = WorktreeJournalIO()
    try io.write(pack, name: "objects.pack", in: stage, replacing: nil)
    try io.write(index, name: "objects.idx", in: stage, replacing: nil)
    return try .init(
      directory: stage, hash: String(repeating: "a", count: 40),
      pack: WorktreeRecoveryStageFile.read("objects.pack", in: stage, limit: pack.count),
      index: WorktreeRecoveryStageFile.read("objects.idx", in: stage, limit: index.count),
      packSHA256: WorktreeObjectSnapshot.digest(pack),
      indexSHA256: WorktreeObjectSnapshot.digest(index))
  }
}
