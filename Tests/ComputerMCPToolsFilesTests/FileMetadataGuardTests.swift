import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPToolsFiles

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

#if canImport(Darwin)
  @Suite(.nativeIntegration)
  struct FileMetadataGuardTests {
    @Test(
      arguments: ["file.chmod", "file.touch", "file.remove_xattr"],
      ["file", "parent", "hardlink"])
    func metadataRestoresTheOpenedInode(tool: String, change: String) throws {
      let temporary = try ScopedTemporaryDirectory()
      let root = temporary.url.appendingPathComponent("project")
      let parent = root.appendingPathComponent("parent")
      let outside = temporary.url.appendingPathComponent("outside")
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
      let source = parent.appendingPathComponent("file")
      try Data("original".utf8).write(to: source)
      let fd = open(source.path, O_RDWR | O_NOFOLLOW)
      try #require(fd >= 0)
      defer { close(fd) }
      try #require(fchmod(fd, 0o640) == 0)
      let times = [
        timespec(tv_sec: 1_600_000_000, tv_nsec: 123),
        timespec(tv_sec: 1_600_000_100, tv_nsec: 456),
      ]
      try #require(futimens(fd, times) == 0)
      let value = Data("attribute".utf8)
      try value.withUnsafeBytes {
        try #require(fsetxattr(fd, "com.example.guard", $0.baseAddress, $0.count, 0, 0) == 0)
        try #require(fsetxattr(fd, "com.example.retained", $0.baseAddress, $0.count, 0, 0) == 0)
      }
      var before = stat()
      try #require(fstat(fd, &before) == 0)
      let mover = FileGuardDirectoryMover(from: change == "parent" ? parent : source, to: outside)
      let operation =
        tool == "file.chmod" ? "fchmod" : (tool == "file.touch" ? "futimens" : "fremovexattr")
      let provider = FilesToolProvider(
        environment: ToolEnvironment(
          configuration: .init(builtin: .init(enabled: [tool]), projectDirectory: root),
          extendedAttributes: GuardTestAttributes()),
        fileMutationObserver: { name, _, phase in
          guard name == operation, phase == .didMutate else { return }
          if change == "hardlink" {
            try FileManager.default.linkItem(at: source, to: outside)
          } else {
            try mover.move()
          }
        })
      #expect(throws: (any Error).self) {
        _ = try provider.callTool(
          .init(
            name: tool,
            arguments: .object([
              "path": .string("parent/file"), "mode": .string("0600"),
              "name": .string("com.example.guard"),
            ]), context: .empty))
      }
      var after = stat()
      try #require(fstat(fd, &after) == 0)
      #expect(after.st_mode == before.st_mode)
      #expect(after.st_atimespec.tv_sec == before.st_atimespec.tv_sec)
      #expect(after.st_atimespec.tv_nsec == before.st_atimespec.tv_nsec)
      #expect(after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec)
      #expect(after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec)
      for key in ["com.example.guard", "com.example.retained"] {
        var bytes = Data(count: value.count)
        let count = bytes.withUnsafeMutableBytes {
          fgetxattr(fd, key, $0.baseAddress, $0.count, 0, 0)
        }
        #expect(count == value.count)
        #expect(bytes == value)
      }
    }
  }

  private struct GuardTestAttributes: ExtendedAttributes {
    func names(at url: URL) throws -> [String] { ["com.example.guard", "com.example.retained"] }
    func size(of name: String, at url: URL) throws -> Int { getxattr(url.path, name, nil, 0, 0, 0) }
    func value(of name: String, at url: URL, size: Int, maxBytes: Int) throws -> Data { Data() }
    func remove(_ name: String, descriptor: Int32) throws {
      try #require(fremovexattr(descriptor, name, 0) == 0)
    }
  }
#endif
