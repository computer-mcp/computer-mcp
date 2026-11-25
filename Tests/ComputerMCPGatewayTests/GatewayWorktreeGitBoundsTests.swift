import ComputerMCPTestSupport
import ComputerMCPWorktrees
import Foundation
import Testing

@testable import ComputerMCPGateway
@testable import ComputerMCPWorktrees

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

@Suite(.nativeIntegration, .serialized, .timeLimit(.minutes(1)))
struct GatewayWorktreeGitBoundsTests {
  @Test func gitPackAndIndexLimitsThroughGateway() throws {
    let fixture = try WorktreeServiceFixture()
    defer { fixture.remove() }
    let git = fixture.executor
    #expect(git.executable == fixture.platform.gitExecutable)
    #expect(git.executable == (try testExecutable("git")))
    let version = try fixture.git(["--version"]).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(version.hasPrefix("git version "))
    print("Bounded Git fixture executable: \(git.executable); \(version)")
    let head = try fixture.git(["rev-parse", "HEAD"]).trimmingCharacters(
      in: .whitespacesAndNewlines)
    let objectNames = try fixture.git(["rev-list", "--objects", "--no-object-names", head])
    let objects = Set(objectNames.split(separator: "\n").map(String.init))
    #expect(objects.count >= 3)
    let command = WorktreeGitCommand(
      arguments: HostGitConfiguration.arguments + [
        "pack-objects", "--stdout", "--no-reuse-object", "--no-reuse-delta", "--window=0",
        "--threads=1", "--compression=6",
      ], directory: fixture.source,
      environment: HostGitConfiguration.environment(home: fixture.root),
      input: Data(objectNames.utf8), timeoutMilliseconds: 30_000, maxOutputBytes: 1_048_576)
    let packURL = fixture.root.appendingPathComponent("objects.pack")
    let fd = open(packURL.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    try #require(fd >= 0)
    defer { close(fd) }
    #expect(throws: (any Error).self) {
      try git.executeBounded(
        command, fileOutput: .init(descriptor: fd, byteLimit: 1), fileSizeLimit: nil)
    }
    #expect(try Data(contentsOf: packURL).count <= 1)
    #expect(ftruncate(fd, 0) == 0)
    #expect(lseek(fd, 0, SEEK_SET) == 0)
    let packed = try git.executeBounded(
      command, fileOutput: .init(descriptor: fd, byteLimit: 65_536), fileSizeLimit: nil)
    #expect(packed.exitCode == 0)
    let pack = try Data(contentsOf: packURL)
    #expect(pack.count > 1 && pack.count <= 65_536)
    let readOnly = open(packURL.path, O_RDONLY | O_CLOEXEC)
    try #require(readOnly >= 0)
    defer { close(readOnly) }
    #expect(throws: (any Error).self) {
      try git.executeBounded(
        command, fileOutput: .init(descriptor: readOnly, byteLimit: 65_536), fileSizeLimit: nil)
    }
    #expect(try Data(contentsOf: packURL) == pack)

    func indexCommand(_ destination: URL) -> WorktreeGitCommand {
      .init(
        arguments: HostGitConfiguration.arguments + [
          "index-pack", "--strict", "--index-version=2", "--no-rev-index", "-o",
          destination.path, packURL.path,
        ], directory: fixture.source,
        environment: HostGitConfiguration.environment(home: fixture.root),
        timeoutMilliseconds: 30_000, maxOutputBytes: 1_048_576)
    }
    #if canImport(Darwin)
      let resource = RLIMIT_FSIZE
    #else
      let resource = Int32(RLIMIT_FSIZE.rawValue)
    #endif
    var before = rlimit()
    try #require(getrlimit(resource, &before) == 0)
    let shortIndex = fixture.root.appendingPathComponent("short.idx")
    let failed = try git.executeBounded(
      indexCommand(shortIndex), fileOutput: nil, fileSizeLimit: 64)
    #expect(failed.exitCode != 0)
    if FileManager.default.fileExists(atPath: shortIndex.path) {
      #expect(try Data(contentsOf: shortIndex).count <= 64)
    }
    var after = rlimit()
    try #require(getrlimit(resource, &after) == 0)
    #expect(after.rlim_cur == before.rlim_cur)
    #expect(after.rlim_max == before.rlim_max)
    let parentFile = fixture.root.appendingPathComponent("parent-output")
    try Data(repeating: 7, count: 256).write(to: parentFile)
    #expect(try Data(contentsOf: parentFile).count == 256)
    let index = fixture.root.appendingPathComponent("objects.idx")
    let indexed = try git.executeBounded(
      indexCommand(index), fileOutput: nil, fileSizeLimit: 65_536)
    #expect(indexed.exitCode == 0)
    let indexBytes = try Data(contentsOf: index).count
    #expect(indexBytes > 64 && indexBytes <= 65_536)
    let inventory = try fixture.git(["verify-pack", "-v", index.path])
    let packedObjects = inventory.split(separator: "\n").compactMap { line -> String? in
      let fields = line.split(whereSeparator: { $0.isWhitespace })
      guard let first = fields.first, first.count == head.count,
        first.allSatisfy({ $0.isHexDigit })
      else { return nil }
      return String(first)
    }
    #expect(Set(packedObjects) == objects)
  }
}
