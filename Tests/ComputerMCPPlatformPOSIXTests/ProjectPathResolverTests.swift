import Foundation
import Testing

@testable import ComputerMCPPlatform
@testable import ComputerMCPPlatformPOSIX

struct PlatformProjectPathResolverTests {
  @Test
  func testProjectPathResolverAcceptsEquivalentCanonicalAbsolutePath() throws {
    let fixture = try ProjectPathFixture()
    defer { fixture.cleanup() }
    let project = fixture.project
    let canonicalProject = try ProjectPathResolver.canonicalProject(project)
    let canonicalTarget = canonicalProject.appendingPathComponent("future/file.txt")

    let resolved = try ProjectPathResolver.resolve(
      canonicalTarget.path,
      relativeTo: project
    )

    #expect(resolved.path == project.appendingPathComponent("future/file.txt").path)
  }

  @Test
  func resolvesExistingAndMissingUnicodeChildrenWithoutCreatingThem() throws {
    let fixture = try ProjectPathFixture()
    defer { fixture.cleanup() }
    let child = try fixture.directory("project/资料 空间")
    let file = child.appendingPathComponent("content.txt")
    try Data("untouched".utf8).write(to: file)
    for path in ["资料 空间/content.txt", file.path, "资料 空间/../资料 空间/content.txt"] {
      let result = try ProjectPathResolver.resolve(path, relativeTo: fixture.project)
      #expect(try Data(contentsOf: result) == Data("untouched".utf8))
    }
    let future = try ProjectPathResolver.resolve(
      "资料 空间/new/deep/file.txt", relativeTo: fixture.project)
    #expect(!FileManager.default.fileExists(atPath: future.path))
    #expect(future.lastPathComponent == "file.txt")
    #expect(try FileManager.default.contentsOfDirectory(atPath: child.path) == ["content.txt"])
  }

  @Test
  func rejectsParentTraversalAndSamePrefixSibling() throws {
    let fixture = try ProjectPathFixture()
    defer { fixture.cleanup() }
    let sibling = try fixture.directory("project-other")
    for path in ["../outside/absent.txt", sibling.appendingPathComponent("future.txt").path] {
      #expect(throws: ProjectPathResolutionError.escapesProject) {
        try ProjectPathResolver.resolve(path, relativeTo: fixture.project)
      }
    }
    #expect(!ProjectPathResolver.contains(sibling, in: fixture.project))
  }

  @Test
  func followsInternalLinksAndRejectsExistingMissingAndDanglingEscapes() throws {
    let fixture = try ProjectPathFixture()
    defer { fixture.cleanup() }
    let inside = try fixture.directory("project/inside")
    try fixture.link("project/local", to: inside)
    try fixture.link("project/escape", to: fixture.outside)
    try fixture.link("project/dangling", to: fixture.outside.appendingPathComponent("missing"))
    try Data("outside".utf8).write(to: fixture.outside.appendingPathComponent("existing.txt"))
    let result = try ProjectPathResolver.resolve("local/new.txt", relativeTo: fixture.project)
    #expect(result.deletingLastPathComponent().lastPathComponent == "inside")
    for path in ["escape/existing.txt", "escape/missing/deep.txt", "dangling/new.txt"] {
      #expect(throws: (any Error).self) {
        try ProjectPathResolver.resolve(path, relativeTo: fixture.project)
      }
    }
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: fixture.outside.path) == ["existing.txt"])
  }

  @Test
  func acceptsBothLexicalAndPhysicalPathsForLinkedProjectRoot() throws {
    let fixture = try ProjectPathFixture()
    defer { fixture.cleanup() }
    let alias = fixture.root.appendingPathComponent("alias")
    try fixture.link("alias", to: fixture.project)
    let physical = try ProjectPathResolver.canonicalProject(alias)
    for path in [
      "future/file.txt", alias.appendingPathComponent("future/file.txt").path,
      physical.appendingPathComponent("future/file.txt").path,
    ] {
      let result = try ProjectPathResolver.resolve(path, relativeTo: alias)
      #expect(result.lastPathComponent == "file.txt")
      #expect(result.deletingLastPathComponent().deletingLastPathComponent().path == physical.path)
    }
  }

}

private struct ProjectPathFixture {
  let root: URL
  let project: URL
  let outside: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "computer-mcp-path-\(UUID())")
    project = root.appendingPathComponent("project")
    outside = root.appendingPathComponent("outside")
    for url in [project, outside] {
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
