#if canImport(Glibc)
  import ComputerMCPConfiguration
  import ComputerMCPCore
  import ComputerMCPPlatform
  import ComputerMCPPlatformPOSIX
  import ComputerMCPTestSupport
  import ComputerMCPToolKit
  import ComputerMCPToolsFiles
  import Foundation
  import Glibc
  import Testing

  @Suite(.nativeIntegration)
  struct LinuxFileGuardTests {
    @Test(arguments: ["file.copy", "file.move"], [false, true])
    func transferPreservesMetadata(tool: String, directory: Bool) throws {
      let temporary = try ScopedTemporaryDirectory()
      let source = temporary.url.appendingPathComponent("source")
      let target = temporary.url.appendingPathComponent("target")
      if directory {
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("contents".utf8).write(to: source.appendingPathComponent("member"))
      } else {
        try Data("contents".utf8).write(to: source)
      }
      let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      try #require(input >= 0)
      defer { close(input) }
      let attributes = ["user.empty": Data(), "user.binary": Data([0, 1, 255, 0])]
      for (name, value) in attributes {
        try LinuxFileMetadata.set(name, value: value, descriptor: input)
      }
      try LinuxFileMetadata.set(
        "system.posix_acl_access", value: accessACL(directory: directory), descriptor: input)
      try #require(fchmod(input, directory ? 0o550 : 0o440) == 0)
      let acl = try LinuxFileMetadata.value("system.posix_acl_access", descriptor: input)
      let times = [
        timespec(tv_sec: 1_600_000_000, tv_nsec: 123),
        timespec(tv_sec: 1_600_000_100, tv_nsec: 456),
      ]
      try #require(futimens(input, times) == 0)
      var original = stat()
      try #require(fstat(input, &original) == 0)
      let provider = FilesToolProvider(
        environment: ToolEnvironment(
          configuration: .init(builtin: .init(enabled: [tool]), projectDirectory: temporary.url)))
      _ = try provider.callTool(
        .init(
          name: tool,
          arguments: .object(["source": .string("source"), "destination": .string("target")]),
          context: .empty))
      let output = open(target.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      try #require(output >= 0)
      defer {
        if directory { _ = fchmod(output, 0o700) }
        close(output)
      }
      var copied = stat()
      try #require(fstat(output, &copied) == 0)
      #expect(copied.st_mode == original.st_mode)
      #expect(copied.st_mtim.tv_sec == times[1].tv_sec)
      #expect(copied.st_mtim.tv_nsec == times[1].tv_nsec)
      if !directory {
        #expect(copied.st_atim.tv_sec == times[0].tv_sec)
        #expect(copied.st_atim.tv_nsec == times[0].tv_nsec)
      }
      #expect(try LinuxFileMetadata.value("system.posix_acl_access", descriptor: output) == acl)
      for (name, value) in attributes {
        #expect(try LinuxFileMetadata.value(name, descriptor: output) == value)
      }
      #expect(
        try Data(contentsOf: directory ? target.appendingPathComponent("member") : target)
          == Data("contents".utf8))
      #expect(FileManager.default.fileExists(atPath: source.path) == (tool == "file.copy"))
      #expect((copied.st_ino == original.st_ino) == (tool == "file.move"))
      if directory, tool == "file.copy" { try #require(fchmod(input, 0o700) == 0) }
    }

    @Test(arguments: ["file.chmod", "file.touch", "file.remove_xattr"])
    func metadataRollbackRestoresTheOpenedInode(tool: String) throws {
      let temporary = try ScopedTemporaryDirectory()
      let root = temporary.url.appendingPathComponent("project")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let source = root.appendingPathComponent("file")
      let outside = temporary.url.appendingPathComponent("outside")
      try Data("original".utf8).write(to: source)
      let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      try #require(input >= 0)
      defer { close(input) }
      let value = Data([0, 255, 0])
      try LinuxFileMetadata.set("user.guard", value: value, descriptor: input)
      try #require(fchmod(input, 0o640) == 0)
      try #require(
        futimens(
          input,
          [
            timespec(tv_sec: 1_600_000_000, tv_nsec: 123),
            timespec(tv_sec: 1_600_000_100, tv_nsec: 456),
          ]) == 0)
      var original = stat()
      try #require(fstat(input, &original) == 0)
      let provider = FilesToolProvider(
        environment: ToolEnvironment(
          configuration: .init(builtin: .init(enabled: [tool]), projectDirectory: root),
          extendedAttributes: LinuxGuardAttributes()),
        fileMutationObserver: { _, _, phase in
          if phase == .didMutate { try FileManager.default.linkItem(at: source, to: outside) }
        })
      #expect(throws: (any Error).self) {
        _ = try provider.callTool(
          .init(
            name: tool,
            arguments: .object([
              "path": .string("file"), "mode": .string("0600"), "name": .string("user.guard"),
            ]),
            context: .empty))
      }
      var restored = stat()
      try #require(fstat(input, &restored) == 0)
      #expect(restored.st_nlink == 2)
      #expect(restored.st_mode == original.st_mode)
      #expect(restored.st_atim.tv_sec == original.st_atim.tv_sec)
      #expect(restored.st_atim.tv_nsec == original.st_atim.tv_nsec)
      #expect(restored.st_mtim.tv_sec == original.st_mtim.tv_sec)
      #expect(restored.st_mtim.tv_nsec == original.st_mtim.tv_nsec)
      #expect(try LinuxFileMetadata.value("user.guard", descriptor: input) == value)
    }

    // Linux's posix_acl_xattr UAPI uses a little-endian version and (tag, permissions, id) entries.
    private func accessACL(directory: Bool) -> Data {
      var data = Data([2, 0, 0, 0])
      let permission: UInt16 = directory ? 5 : 4
      let entries: [(UInt16, UInt16, UInt32)] = [
        (1, permission, .max), (2, permission, 65534), (4, permission, .max),
        (16, permission, .max), (32, 0, .max),
      ]
      for (tag, rights, id) in entries {
        for value in [tag.littleEndian, rights.littleEndian] {
          withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        }
        withUnsafeBytes(of: id.littleEndian) { data.append(contentsOf: $0) }
      }
      return data
    }
  }

  private struct LinuxGuardAttributes: ExtendedAttributes {
    func names(at url: URL) throws -> [String] { ["user.guard"] }
    func size(of name: String, at url: URL) throws -> Int { 3 }
    func value(of name: String, at url: URL, size: Int, maxBytes: Int) throws -> Data { Data() }
    func remove(_ name: String, descriptor: Int32) throws {
      try LinuxFileMetadata.remove(name, descriptor: descriptor)
    }
  }
#endif
