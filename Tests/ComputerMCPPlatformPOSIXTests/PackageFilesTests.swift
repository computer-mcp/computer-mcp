import ComputerMCPPlatform
import Foundation
import Testing

@testable import ComputerMCPPlatformPOSIX

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

struct PackageFilesTests {
  @Test(arguments: [0, 16_384, 32_769])
  func readsUpToTheExactLimit(maximumBytes: Int) throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let content = Data(repeating: 42, count: maximumBytes)
    try content.write(to: root.appendingPathComponent("content"))
    let files = try PackageFiles(root: root)
    #expect(try files.read("content", maximumBytes: maximumBytes) == content)
    if maximumBytes > 0 {
      #expect(throws: PackageFileError.invalid("Package file exceeds its read limit: content.")) {
        try files.read("content", maximumBytes: maximumBytes - 1)
      }
    }
  }

  @Test(arguments: [-1, Int.max])
  func rejectsInvalidReadLimits(maximumBytes: Int) throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try PackageFiles(root: root)
    #expect(throws: PackageFileError.invalid("Invalid package read limit.")) {
      try files.read("content", maximumBytes: maximumBytes)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func rejectsDirectoriesAndFIFOsAsFilesWithoutBlocking() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(mkfifo(root.appendingPathComponent("fifo").path, 0o600) == 0)
    let files = try PackageFiles(root: root)
    try files.validate("skills", kind: .directory)
    for path in ["skills", "fifo"] {
      let error = PackageFileError.invalid("Unexpected package file type: \(path).")
      #expect(throws: error) { try files.read(path, maximumBytes: 100) }
      #expect(throws: error) { try files.validate(path, kind: .file) }
      #expect(throws: error) { try files.validate(path, kind: .executable) }
    }
  }

  @Test
  func executableValidationRequiresAnExecuteBit() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("helper")
    try Data("helper".utf8).write(to: file)
    try #require(chmod(file.path, 0o600) == 0)
    let files = try PackageFiles(root: root)
    try files.validate("helper", kind: .file)
    #expect(throws: PackageFileError.invalid("Package helper is not executable: helper.")) {
      try files.validate("helper", kind: .executable)
    }
    try #require(chmod(file.path, 0o700) == 0)
    try files.validate("helper", kind: .executable)
    #expect(throws: PackageFileError.invalid("Cannot safely open package path: helper.")) {
      try files.validate("helper", kind: .directory)
    }
  }

  @Test(arguments: [
    "", "/etc", "../escape", "folder/../escape", "./folder", "a//b", "a/", "~/skills", "a\\b",
    "a\0b",
  ])
  func rejectsUnnormalizedPaths(path: String) throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try PackageFiles(root: root)
    #expect(throws: PackageFileError.invalid("Package paths must be normalized relative paths.")) {
      try files.read(path, maximumBytes: 100)
    }
  }

  @Test
  func rejectsNonFileRoots() throws {
    let root = try #require(URL(string: "https://example.test/package"))
    #expect(throws: PackageFileError.invalid("Package root must be a file URL.")) {
      try PackageFiles(root: root)
    }
  }

  @Test
  func externalAndDanglingSymlinksFailButContainedSymlinksRemainUsable() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let sibling = try fixture()
    defer { try? FileManager.default.removeItem(at: sibling) }
    try "inside".write(
      to: root.appendingPathComponent("content"), atomically: true, encoding: .utf8)
    try "outside".write(
      to: sibling.appendingPathComponent("content"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      atPath: root.appendingPathComponent("link").path, withDestinationPath: "content")
    try FileManager.default.createSymbolicLink(
      atPath: root.appendingPathComponent("escape").path, withDestinationPath: sibling.path)
    try FileManager.default.createSymbolicLink(
      atPath: root.appendingPathComponent("dangling").path, withDestinationPath: "missing")
    let files = try PackageFiles(root: root)
    #expect(try files.read("link", maximumBytes: 6) == Data("inside".utf8))
    #expect(throws: (any Error).self) { try files.read("escape/content", maximumBytes: 100) }
    #expect(throws: (any Error).self) { try files.read("dangling", maximumBytes: 100) }
    #expect(throws: PackageFileError.self) { try files.read("content", maximumBytes: 5) }
    #expect(throws: PackageFileError.self) { try files.read("skills", maximumBytes: 100) }
  }

  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "package-files-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("skills"), withIntermediateDirectories: true)
    return root
  }
}
