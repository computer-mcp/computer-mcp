import Foundation
import Testing

@testable import ComputerMCPPlatform
@testable import ComputerMCPPlatformPOSIX

struct PlatformWorkspacePathResolverTests {
  @Test
  func resolvesExistingAndMissingUnicodeChildrenWithoutCreatingThem() throws {
    let fixture = try WorkspacePathFixture()
    defer { fixture.cleanup() }
    let child = try fixture.directory("workspace/资料 空间")
    let file = child.appendingPathComponent("content.txt")
    try Data("untouched".utf8).write(to: file)
    for path in ["资料 空间/content.txt", file.path, "资料 空间/../资料 空间/content.txt"] {
      let result = try WorkspacePathResolver.resolve(path, relativeTo: fixture.workspace)
      #expect(try Data(contentsOf: result) == Data("untouched".utf8))
    }
    let future = try WorkspacePathResolver.resolve(
      "资料 空间/new/deep/file.txt", relativeTo: fixture.workspace)
    #expect(!FileManager.default.fileExists(atPath: future.path))
    #expect(future.lastPathComponent == "file.txt")
    #expect(try FileManager.default.contentsOfDirectory(atPath: child.path) == ["content.txt"])
  }

  @Test
  func rejectsParentTraversalAndSamePrefixSibling() throws {
    let fixture = try WorkspacePathFixture()
    defer { fixture.cleanup() }
    let sibling = try fixture.directory("workspace-other")
    for path in ["../outside/absent.txt", sibling.appendingPathComponent("future.txt").path] {
      #expect(throws: WorkspacePathResolutionError.escapesWorkspace) {
        try WorkspacePathResolver.resolve(path, relativeTo: fixture.workspace)
      }
    }
    #expect(!WorkspacePathResolver.contains(sibling, in: fixture.workspace))
  }

  @Test
  func followsInternalLinksAndRejectsExistingMissingAndDanglingEscapes() throws {
    let fixture = try WorkspacePathFixture()
    defer { fixture.cleanup() }
    let inside = try fixture.directory("workspace/inside")
    try fixture.link("workspace/local", to: inside)
    try fixture.link("workspace/escape", to: fixture.outside)
    try fixture.link("workspace/dangling", to: fixture.outside.appendingPathComponent("missing"))
    try Data("outside".utf8).write(to: fixture.outside.appendingPathComponent("existing.txt"))
    let result = try WorkspacePathResolver.resolve("local/new.txt", relativeTo: fixture.workspace)
    #expect(result.deletingLastPathComponent().lastPathComponent == "inside")
    for path in ["escape/existing.txt", "escape/missing/deep.txt", "dangling/new.txt"] {
      #expect(throws: (any Error).self) {
        try WorkspacePathResolver.resolve(path, relativeTo: fixture.workspace)
      }
    }
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.outside.path) == ["existing.txt"])
  }

  @Test
  func acceptsBothLexicalAndPhysicalPathsForLinkedWorkspaceRoot() throws {
    let fixture = try WorkspacePathFixture()
    defer { fixture.cleanup() }
    let alias = fixture.root.appendingPathComponent("alias")
    try fixture.link("alias", to: fixture.workspace)
    let physical = try WorkspacePathResolver.canonicalWorkspace(alias)
    for path in [
      "future/file.txt", alias.appendingPathComponent("future/file.txt").path,
      physical.appendingPathComponent("future/file.txt").path,
    ] {
      let result = try WorkspacePathResolver.resolve(path, relativeTo: alias)
      #expect(result.lastPathComponent == "file.txt")
      #expect(result.deletingLastPathComponent().deletingLastPathComponent().path == physical.path)
    }
  }

}

private struct WorkspacePathFixture {
  let root: URL
  let workspace: URL
  let outside: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "computer-mcp-path-\(UUID())")
    workspace = root.appendingPathComponent("workspace")
    outside = root.appendingPathComponent("outside")
    for url in [workspace, outside] {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
  }

  func directory(_ name: String) throws -> URL {
    let url = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func link(_ name: String, to destination: URL) throws {
    let url = root.appendingPathComponent(name)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
  }

  func cleanup() { try? FileManager.default.removeItem(at: root) }

}
