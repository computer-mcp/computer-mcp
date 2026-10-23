import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPToolsFiles

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

@Suite(.nativeIntegration, .serialized)
struct FileMoveMetadataTests {
  #if canImport(Darwin)
    @Test(arguments: ["file.move", "file.copy"])
    func transferPreservesMetadata(tool: String) throws {
      let temporary = try ScopedTemporaryDirectory()
      let root = temporary.url
      let destination = root.appendingPathComponent("destination")
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      let tools = ToolEnvironment(
        configuration: .init(builtin: .init(enabled: [tool]), projectDirectory: root))
      let source = root.appendingPathComponent("source")
      let target = destination.appendingPathComponent("target")
      try Data("contents".utf8).write(to: source)
      let attributes = [
        "com.example.move": Data("attribute value".utf8),
        "com.apple.ResourceFork": Data("resource fork contents".utf8),
      ]
      for (key, value) in attributes {
        try value.withUnsafeBytes { bytes in
          try #require(setxattr(source.path, key, bytes.baseAddress, bytes.count, 0, 0) == 0)
        }
      }
      let permission = try tools.commandRunner.run(
        executable: testExecutable("chmod"),
        arguments: ["+a", "everyone allow read,readattr,readextattr,readsecurity", source.path],
        workingDirectory: root, environment: [:], timeoutMilliseconds: 10_000, maxOutputBytes: 4096)
      try #require(permission.exitCode == 0)
      let fd = open(source.path, O_RDWR | O_NOFOLLOW)
      try #require(fd >= 0)
      defer { close(fd) }
      try #require(fchmod(fd, 0o640) == 0)
      let times = [
        timespec(tv_sec: 1_600_000_000, tv_nsec: 0), timespec(tv_sec: 1_600_000_100, tv_nsec: 0),
      ]
      try #require(futimens(fd, times) == 0)
      func acl(_ url: URL) throws -> String {
        let value = try #require(acl_get_file(url.path, ACL_TYPE_EXTENDED))
        defer { acl_free(UnsafeMutableRawPointer(value)) }
        let text = try #require(acl_to_text(value, nil))
        defer { acl_free(text) }
        return String(cString: text)
      }
      let originalACL = try acl(source)
      var original = stat()
      try #require(lstat(source.path, &original) == 0)
      _ = try FilesToolProvider(environment: tools).callTool(
        .init(
          name: tool,
          arguments: .object(["source": .string(source.path), "destination": .string(target.path)]),
          context: .empty))
      #expect(FileManager.default.fileExists(atPath: source.path) == (tool == "file.copy"))
      for (key, value) in attributes {
        var bytes = [UInt8](repeating: 0, count: 1_024)
        let count = getxattr(target.path, key, &bytes, bytes.count, 0, 0)
        try #require(count >= 0)
        #expect(Data(bytes.prefix(count)) == value)
      }
      var moved = stat()
      try #require(lstat(target.path, &moved) == 0)
      #expect(
        (moved.st_dev == original.st_dev && moved.st_ino == original.st_ino)
          == (tool == "file.move"))
      #expect(moved.st_mode == original.st_mode)
      #expect(moved.st_atimespec.tv_sec == original.st_atimespec.tv_sec)
      #expect(moved.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec)
      #expect(try acl(target) == originalACL)
      #expect(try Data(contentsOf: target) == Data("contents".utf8))
    }

    @Test
    func crossVolumeMovesRefuseBeforeChangingEitherVolume() throws {
      let temporary = try ScopedTemporaryDirectory()
      let root = temporary.url.appendingPathComponent("project")
      let destination = root.appendingPathComponent("destination")
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      let tools = ToolEnvironment(
        configuration: .init(
          builtin: .init(enabled: ["file.move", "file.copy"]), projectDirectory: root))
      let utility = try testExecutable("hdiutil")
      func disk(_ args: [String]) throws {
        let result = try tools.commandRunner.run(
          executable: utility, arguments: args, workingDirectory: root,
          environment: [:], timeoutMilliseconds: 30_000, maxOutputBytes: 65_536)
        try #require(result.exitCode == 0, "\(result.stderr)")
      }
      let image = temporary.url.appendingPathComponent("volume.sparseimage")
      try disk([
        "create", "-size", "16m", "-fs", "HFS+", "-type", "SPARSE", "-volname", "MoveFixture",
        image.path,
      ])
      try disk(["attach", "-nobrowse", "-mountpoint", destination.path, image.path])
      defer { try? disk(["detach", destination.path]) }
      let provider = FilesToolProvider(environment: tools)
      for directory in [false, true] {
        for reverse in [false, true] {
          let input = reverse ? destination : root
          let output = reverse ? root : destination
          let source = input.appendingPathComponent("source-\(directory)-\(reverse)")
          if directory {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            try Data("original".utf8).write(to: source.appendingPathComponent("member"))
          } else {
            try Data("original".utf8).write(to: source)
          }
          for existing in [false, true] {
            let target = output.appendingPathComponent(
              existing ? "target" : "missing/parent/target")
            if existing { try Data("destination".utf8).write(to: target) }
            let error = #expect(throws: (any Error).self) {
              _ = try provider.callTool(
                .init(
                  name: "file.move",
                  arguments: .object([
                    "source": .string(source.path), "destination": .string(target.path),
                    "overwrite": .bool(true), "create_directories": .bool(true),
                  ]), context: .empty))
            }
            #expect(String(describing: error).contains("copy and then delete"))
            #expect(
              try Data(contentsOf: directory ? source.appendingPathComponent("member") : source)
                == Data("original".utf8))
            if existing {
              #expect(try Data(contentsOf: target) == Data("destination".utf8))
              try FileManager.default.removeItem(at: target)
            } else {
              #expect(
                !FileManager.default.fileExists(
                  atPath: output.appendingPathComponent("missing").path))
            }
          }
        }
      }
      let source = root.appendingPathComponent("mount-source")
      let sentinel = destination.appendingPathComponent("sentinel")
      try Data("original".utf8).write(to: source)
      try Data("destination".utf8).write(to: sentinel)
      let error = #expect(throws: (any Error).self) {
        _ = try provider.callTool(
          .init(
            name: "file.move",
            arguments: .object([
              "source": .string(source.path), "destination": .string(destination.path),
              "overwrite": .bool(true),
            ]), context: .empty))
      }
      #expect(String(describing: error).contains("copy and then delete"))
      #expect(try Data(contentsOf: source) == Data("original".utf8))
      #expect(try Data(contentsOf: sentinel) == Data("destination".utf8))
      let resource = Data("cross-volume resource".utf8)
      try resource.withUnsafeBytes {
        try #require(
          setxattr(source.path, "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, 0) == 0)
      }
      let copied = destination.appendingPathComponent("copied")
      _ = try provider.callTool(
        .init(
          name: "file.copy",
          arguments: .object([
            "source": .string(source.path), "destination": .string(copied.path),
          ]), context: .empty))
      var bytes = Data(count: resource.count)
      let count = bytes.withUnsafeMutableBytes {
        getxattr(copied.path, "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, 0)
      }
      #expect(count == resource.count && bytes == resource)
      #expect(try Data(contentsOf: copied) == Data("original".utf8))

    }
  #endif
}
