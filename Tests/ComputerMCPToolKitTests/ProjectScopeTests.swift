import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

struct ProjectScopeTests {
  @Test
  func resolvesPathsAndRejectsSiblingPrefixes() throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url.resolvingSymlinksInPath()
    let meta: JSONValue = .object(["input": .string("metadata")])
    let scope = ProjectScope(configuration: .init(projectDirectory: root), toolMeta: meta)
    #expect(scope.toolMeta == meta)
    #expect(try scope.resolvedProjectURL(".") == root)
    #expect(try scope.resolvedProjectURL("a/../b").path == root.appendingPathComponent("b").path)
    #expect(scope.projectRelativePath(root) == ".")
    #expect(scope.projectURL(forRelativeDirectory: ".") == root)
    #expect(
      scope.projectURL(forRelativeDirectory: "a").path == root.appendingPathComponent("a").path)
    let outside = root.path + "-sibling/file"
    #expect(
      throws: GatewayToolError.invalidArguments(
        "[policy.project_denied] Path escapes project: \(outside)")
    ) {
      try scope.resolvedProjectURL(outside)
    }
    #expect(!scope.isProjectContained(URL(fileURLWithPath: outside)))
    #expect(
      throws: GatewayToolError.invalidArguments(
        "[policy.project_denied] Path escapes project: ../outside")
    ) {
      try scope.lexicalProjectURL("../outside")
    }
  }

  @Test
  func symlinkMetadataPreservesItsLexicalProjectPath() throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url.resolvingSymlinksInPath()
    let target = root.appendingPathComponent("target.txt")
    try Data("contents".utf8).write(to: target)
    let link = root.appendingPathComponent("link.txt")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "target.txt")
    let scope = ProjectScope(configuration: .init(projectDirectory: root), toolMeta: nil)
    #expect(try scope.resolvedProjectURL("link.txt") == target)
    #expect(try scope.resolvedProjectURLPreservingFinalSymlink("link.txt") == link)
    #expect(scope.projectRelativePath(link) == "target.txt")
    #expect(scope.projectRelativePathPreservingSymlinks(link) == "link.txt")
    let info = try scope.fileInfo(url: link)
    #expect(info.isSymlink && info.type == "symlink")
    #expect(info.path == link.path && info.projectRelativePath == "link.txt")
    #expect(info.symlinkDestination == "target.txt")
    #expect(info.json.objectValue?["symlink_destination"] == .string("target.txt"))
    let targetInfo = try scope.fileInfo(url: target)
    #expect(targetInfo.size == 8 && !targetInfo.isSymlink)
    #expect(targetInfo.json.objectValue?["project_relative_path"] == .string("target.txt"))
  }

  @Test
  func parentSymlinksCannotEscapeButFinalLinksCanBeInspected() throws {
    let temporary = try ScopedTemporaryDirectory()
    let outside = try ScopedTemporaryDirectory()
    let root = temporary.url.resolvingSymlinksInPath()
    let scope = ProjectScope(configuration: .init(projectDirectory: root), toolMeta: nil)
    let link = root.appendingPathComponent("outside")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.url)
    #expect(try scope.lexicalProjectURL("outside").path == link.path)
    #expect(try scope.resolvedProjectURLPreservingFinalSymlink("outside") == link)
    #expect(
      throws: GatewayToolError.invalidArguments(
        "[policy.project_denied] Path escapes project: outside/file")
    ) {
      try scope.resolvedProjectURL("outside/file")
    }
    #expect(
      throws: GatewayToolError.invalidArguments(
        "[policy.project_denied] Path escapes project through parent symlink: outside/file")
    ) {
      try scope.resolvedProjectURLPreservingFinalSymlink("outside/file")
    }
  }

  @Test
  func instructionScopeUsesDirectoryHintsAndWalksFromTheRoot() throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url.resolvingSymlinksInPath()
    let nested = root.appendingPathComponent("a/b")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let file = nested.appendingPathComponent("file")
    try Data().write(to: file)
    let scope = ProjectScope(configuration: .init(projectDirectory: root), toolMeta: nil)
    #expect(
      try scope.projectInstructionScopeURL(
        targetURL: file, pathIsDirectory: nil, targetExists: true
      ).path == nested.path)
    #expect(
      try scope.projectInstructionScopeURL(
        targetURL: file, pathIsDirectory: true, targetExists: true) == file)
    #expect(
      try scope.projectInstructionScopeURL(
        targetURL: nested, originalPath: "a/b/", pathIsDirectory: nil, targetExists: false)
        == nested)
    #expect(
      try scope.projectInstructionScopeURL(
        targetURL: file, originalPath: "a/b/file", pathIsDirectory: nil, targetExists: false
      ).path
        == nested.path)
    #expect(
      scope.projectInstructionScopeDirectories(scopeURL: nested).map(\.path)
        == [root, root.appendingPathComponent("a"), nested].map(\.path))
    #expect(
      scope.projectInstructionScopeDirectories(scopeURL: root.deletingLastPathComponent()) == [
        root
      ])
    #expect(relativePath(fromDirectoryPath: root.path, to: file) == "a/b/file")
    #expect(
      relativePath(fromDirectoryPath: root.path, to: URL(fileURLWithPath: "/outside/file"))
        == "file")
  }

  @Test
  func aSymlinkedProjectRootKeepsCanonicalContainment() throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = try ProjectPathResolver.canonicalProject(temporary.url)
    let real = root.appendingPathComponent("real")
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
    let scope = ProjectScope(configuration: .init(projectDirectory: alias), toolMeta: nil)
    #expect(try scope.resolvedProjectURL("file").path == real.appendingPathComponent("file").path)
    #expect(
      try scope.resolvedProjectURLPreservingFinalSymlink(
        real.appendingPathComponent("file").path
      ).path
        == real.appendingPathComponent("file").path)
  }
}
