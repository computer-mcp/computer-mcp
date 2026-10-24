#if canImport(Glibc)
  import Foundation
  import Glibc
  import Testing

  @testable import ComputerMCPPlatformPOSIX

  struct LinuxSystemCallsTests {
    @Test(arguments: ["file", "directory", "symlink"])
    func exclusiveRenameNeverReplacesAnExistingEntry(kind: String) throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: root) }
      let source = root.appendingPathComponent("source")
      let target = root.appendingPathComponent("target")
      try Data("source".utf8).write(to: source)
      switch kind {
      case "directory":
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
      case "symlink":
        try FileManager.default.createSymbolicLink(
          atPath: target.path, withDestinationPath: "source")
      default: try Data("target".utf8).write(to: target)
      }
      let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      try #require(descriptor >= 0)
      defer { close(descriptor) }
      var before = stat()
      try #require(fstatat(descriptor, "target", &before, AT_SYMLINK_NOFOLLOW) == 0)
      #expect(LinuxSystemCalls.renameExclusive(descriptor, "source", descriptor, "target") == -1)
      #expect(errno == EEXIST)
      var after = stat()
      try #require(fstatat(descriptor, "target", &after, AT_SYMLINK_NOFOLLOW) == 0)
      #expect(after.st_ino == before.st_ino)
      #expect(after.st_mode == before.st_mode)
      #expect(try Data(contentsOf: source) == Data("source".utf8))
      try #require(
        LinuxSystemCalls.renameExclusive(descriptor, "source", descriptor, "published") == 0)
      #expect(!FileManager.default.fileExists(atPath: source.path))
      #expect(try Data(contentsOf: root.appendingPathComponent("published")) == Data("source".utf8))
    }

    @Test
    func metadataCopyRemovesDestinationOnlyAttributes() throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: root) }
      let input = open(
        root.appendingPathComponent("input").path, O_CREAT | O_RDWR | O_EXCL | O_CLOEXEC, 0o640)
      let output = open(
        root.appendingPathComponent("output").path, O_CREAT | O_RDWR | O_EXCL | O_CLOEXEC, 0o600)
      try #require(input >= 0 && output >= 0)
      defer {
        close(input)
        close(output)
      }
      try LinuxFileMetadata.set("user.foreign", value: Data("inherited".utf8), descriptor: output)
      try LinuxFileMetadata.set("user.empty", value: Data(), descriptor: input)
      var original = stat()
      try #require(fstat(input, &original) == 0)
      try LinuxFileMetadata.copy(input, to: output, original: original)
      #expect(try LinuxFileMetadata.names(output) == ["user.empty"])
      #expect(try LinuxFileMetadata.value("user.empty", descriptor: output).isEmpty)
      var copied = stat()
      try #require(fstat(output, &copied) == 0)
      #expect(copied.st_mode == original.st_mode)
      #expect(copied.st_atim.tv_sec == original.st_atim.tv_sec)
      #expect(copied.st_atim.tv_nsec == original.st_atim.tv_nsec)
      #expect(copied.st_mtim.tv_sec == original.st_mtim.tv_sec)
      #expect(copied.st_mtim.tv_nsec == original.st_mtim.tv_nsec)
    }
  }
#endif
