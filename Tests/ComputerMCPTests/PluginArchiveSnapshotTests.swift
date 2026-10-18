import Darwin
import Foundation
import Testing

@testable import ComputerMCP

struct PluginArchiveSnapshotTests {
  private let abcDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

  @Test
  func knownHashUsesPrivateReadOnlyCopyDespiteOriginalMutation() throws {
    let fixture = try ArchiveFixture()
    defer { fixture.remove() }
    let source = fixture.root.appendingPathComponent("source")
    try Data("abc".utf8).write(to: source)
    let input = open(source.path, O_RDONLY | O_CLOEXEC)
    defer { close(input) }
    let result = try PluginArchiveSnapshot.withVerifiedCopy(
      from: input, inNewDirectory: fixture.output, expectedSHA256: abcDigest
    ) { copy in
      try Data("modified original".utf8).write(to: source)
      #expect(copy.sha256 == abcDigest)
      #expect(copy.bytes == 3)
      #expect(try Data(contentsOf: copy.url) == Data("abc".utf8))
      #expect(try fixture.mode("archive") == 0o400)
      return copy.bytes
    }
    #expect(result == 3)
    #expect(!FileManager.default.fileExists(atPath: fixture.output.path))
    #expect(try String(contentsOf: source, encoding: .utf8) == "modified original")
    #expect(fcntl(input, F_GETFD) >= 0)
  }

  @Test(arguments: [
    "", "abc", String(repeating: "A", count: 64), String(repeating: "g", count: 64),
  ])
  func malformedDigestDoesNotCreateFiles(digest: String) throws {
    let fixture = try ArchiveFixture()
    defer { fixture.remove() }
    #expect(throws: PluginArchiveError.invalidInput) {
      try PluginArchiveSnapshot.withVerifiedCopy(
        from: -1, inNewDirectory: fixture.output, expectedSHA256: digest
      ) { _ in Issue.record("Invalid digest reached the consumer") }
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.output.path))
  }

  @Test
  func mismatchAndConsumerFailureReclaimOnlyTheOwnedCopy() throws {
    let fixture = try ArchiveFixture()
    defer { fixture.remove() }
    let source = fixture.root.appendingPathComponent("source")
    try Data("abc".utf8).write(to: source)
    let input = open(source.path, O_RDONLY | O_CLOEXEC)
    defer { close(input) }
    #expect(throws: PluginArchiveError.checksumMismatch) {
      try PluginArchiveSnapshot.withVerifiedCopy(
        from: input, inNewDirectory: fixture.output,
        expectedSHA256: String(repeating: "0", count: 64)
      ) { _ in Issue.record("Unverified copy reached the consumer") }
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.output.path))
    #expect(throws: PluginArchiveError.invalidArchive) {
      try PluginArchiveSnapshot.withVerifiedCopy(
        from: input, inNewDirectory: fixture.output, expectedSHA256: abcDigest
      ) { _ in throw PluginArchiveError.invalidArchive }
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.output.path))
    #expect(try Data(contentsOf: source) == Data("abc".utf8))
  }

  @Test
  func growthAndCancellationAreBoundedAndCleanPartialCopies() throws {
    let fixture = try ArchiveFixture()
    defer { fixture.remove() }
    let source = fixture.root.appendingPathComponent("source")
    try Data(repeating: 65, count: 131_072).write(to: source)
    let input = open(source.path, O_RDONLY | O_CLOEXEC)
    defer { close(input) }
    var checks = 0
    #expect(throws: CancellationError.self) {
      try PluginArchiveSnapshot.withVerifiedCopy(
        from: input, inNewDirectory: fixture.output, expectedSHA256: abcDigest,
        checkCancellation: {
          checks += 1
          if checks == 3 { throw CancellationError() }
        },
        body: { _ in Issue.record("Cancelled copy reached the consumer") })
    }
    #expect(checks == 3)
    #expect(!FileManager.default.fileExists(atPath: fixture.output.path))
    var limits = PluginArchiveLimits()
    limits.archiveBytes = 131_072
    checks = 0
    #expect(throws: PluginArchiveError.limitExceeded) {
      try PluginArchiveSnapshot.withVerifiedCopy(
        from: input, inNewDirectory: fixture.output, expectedSHA256: abcDigest, limits: limits,
        checkCancellation: {
          checks += 1
          if checks == 2 {
            let writer = try FileHandle(forWritingTo: source)
            defer { try? writer.close() }
            try writer.seekToEnd()
            try writer.write(contentsOf: Data([1]))
          }
        },
        body: { _ in Issue.record("Oversized copy reached the consumer") })
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.output.path))
    #expect(try Data(contentsOf: source).count == 131_073)
  }

  @Test
  func rejectsWritableOrNonRegularInputsWithoutReadingThem() throws {
    let fixture = try ArchiveFixture()
    defer { fixture.remove() }
    let source = fixture.root.appendingPathComponent("source")
    try Data("abc".utf8).write(to: source)
    for (url, flags) in [(source, O_RDWR), (fixture.root, O_RDONLY | O_DIRECTORY)] {
      let input = open(url.path, flags | O_CLOEXEC)
      defer { close(input) }
      #expect(throws: PluginArchiveError.invalidInput) {
        try PluginArchiveSnapshot.withVerifiedCopy(
          from: input, inNewDirectory: fixture.output, expectedSHA256: abcDigest
        ) { _ in Issue.record("Invalid input reached the consumer") }
      }
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.output.path))
  }
}
