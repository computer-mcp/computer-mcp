import Foundation
import Testing

@testable import ComputerMCPWorktrees

struct WorktreeRecoveryPackBoundedTests {
  @Test(arguments: ["sha1", "sha256"])
  func exactManifestPackAndDurableReservation(format: String) throws {
    try fixture { root in
      let f = try WorktreeFixture(root, format: format)
      let service = try f.service(executor: PackFixtureGit(base: f.executor))
      let created = try service.create(name: "pack-bounds")
      _ = try f.privateCommit(service, projectID: created.projectID)
      let topology = try service.topology(projectID: created.projectID)
      let git = PrivateWorktreeGit(f: f, topology: topology)
      let blob = try git.run(["hash-object", "-w", "--stdin"], input: Data("side blob".utf8))
      try git.run(["update-ref", "refs/tags/side", blob])
      try git.run(["tag", "-a", "annotated", "-m", "fixture"])
      let tag = try git.run(["rev-parse", "refs/tags/annotated"])
      let expected = try f.raw(["rev-parse", "HEAD"])
      let parentURL = root.appendingPathComponent("staging")
      try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: false)
      let parent = try WorktreeDirectory(parentURL)
      let generation = UUID()
      let stage = try WorktreeRecoveryStaging(
        parent: parent, operationID: UUID(), generation: generation,
        format: try #require(WorktreeObjectFormat(rawValue: format)),
        inputLimit: WorktreePromotionLimits().inputBytes, completionBytes: 4096, io: .init(),
        verifyStore: {})
      let receipt = parentURL.appendingPathComponent("reservation.json")
      let initial = try Data(contentsOf: receipt)
      var budget = try WorktreeObjectBudget(.init())
      let capture = try service.captureRecoveryObjects(
        topology, expectedOID: expected, in: stage.directory, budget: &budget)
      try stage.sealCapture(bytes: budget.input)
      #expect(try Data(contentsOf: receipt) != initial)
      let artifact = try capture.privateObjects.generatePack(
        capture.privateManifest, slot: .recovery, staging: stage)
      let bounds = try WorktreePackBounds.manifest(
        capture.privateManifest, format: try #require(WorktreeObjectFormat(rawValue: format)))
      #expect(artifact.pack.bytes <= bounds.packBytes)
      #expect(artifact.index.bytes <= bounds.indexBytes)
      let inventory = try f.raw([
        "verify-pack", "-v", artifact.directory.url.appendingPathComponent("objects.idx").path,
      ])
      let lines = inventory.split(separator: "\n").map {
        $0.split(whereSeparator: { $0.isWhitespace })
      }
      let objectFormat = try #require(WorktreeObjectFormat(rawValue: format))
      let objects = lines.filter { !$0.isEmpty && objectFormat.contains(String($0[0])) }
      #expect(Set(objects.map { String($0[0]) }) == Set(capture.privateManifest.oids))
      #expect(capture.privateManifest.entries[blob]?.type == .blob)
      #expect(capture.privateManifest.entries[tag]?.type == .tag)
      #expect(throws: WorktreeError.self) {
        try stage.reservePack(.recovery, bounds: bounds)
      }
      let unknown = artifact.directory.url.appendingPathComponent("unknown")
      try Data("unowned".utf8).write(to: unknown)
      #expect(throws: WorktreeError.self) { try stage.finish() }
      #expect(FileManager.default.fileExists(atPath: unknown.path))
      #expect(throws: WorktreeError.self) {
        try WorktreeRecoveryStaging(
          parent: parent, operationID: UUID(), generation: generation,
          format: try #require(WorktreeObjectFormat(rawValue: format)),
          inputLimit: 1, completionBytes: 1, io: .init(), verifyStore: {})
      }
      #expect(FileManager.default.fileExists(atPath: receipt.path))
      try FileManager.default.removeItem(at: unknown)
      try stage.finish()
      #expect(try parent.entries(limit: 2).isEmpty)
    }
  }
}

// This fixture exercises Git's real pack/index generation; process enforcement is tested separately.
private struct PackFixtureGit: WorktreeGitExecuting {
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
