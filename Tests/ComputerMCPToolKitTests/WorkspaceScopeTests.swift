import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

struct WorkspaceScopeTests {
  @Test
  func resolvesPathsAndRejectsSiblingPrefixes() throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url.resolvingSymlinksInPath()
    let meta: JSONValue = .object(["input": .string("metadata")])
    let scope = WorkspaceScope(configuration: .init(workspaceDirectory: root), toolMeta: meta)
    #expect(scope.toolMeta == meta)
    #expect(try scope.resolvedWorkspaceURL(".") == root)
    #expect(try scope.resolvedWorkspaceURL("a/../b").path == root.appendingPathComponent("b").path)
    #expect(scope.workspaceRelativePath(root) == ".")
    #expect(scope.workspaceURL(forRelativeDirectory: ".") == root)
    #expect(
      scope.workspaceURL(forRelativeDirectory: "a").path == root.appendingPathComponent("a").path)
    let outside = root.path + "-sibling/file"
    #expect(
      throws: GatewayToolError.invalidArguments(
        "[policy.workspace_denied] Path escapes workspace: \(outside)")
    ) {
      try scope.resolvedWorkspaceURL(outside)
    }
    #expect(!scope.isWorkspaceContained(URL(fileURLWithPath: outside)))
    #expect(
      throws: GatewayToolError.invalidArguments(
        "[policy.workspace_denied] Path escapes workspace: ../outside")
    ) {
      try scope.lexicalWorkspaceURL("../outside")
    }
  }

  @Test
  func symlinkMetadataPreservesItsLexicalWorkspacePath() throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url.resolvingSymlinksInPath()
    let target = root.appendingPathComponent("target.txt")
    try Data("contents".utf8).write(to: target)
    let link = root.appendingPathComponent("link.txt")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "target.txt")
    let scope = WorkspaceScope(configuration: .init(workspaceDirectory: root), toolMeta: nil)
    #expect(try scope.resolvedWorkspaceURL("link.txt") == target)
    #expect(try scope.resolvedWorkspaceURLPreservingFinalSymlink("link.txt") == link)
    #expect(scope.workspaceRelativePath(link) == "target.txt")
    #expect(scope.workspaceRelativePathPreservingSymlinks(link) == "link.txt")
    let info = try scope.fileInfo(url: link)
    #expect(info.isSymlink && info.type == "symlink")
    #expect(info.path == link.path && info.workspaceRelativePath == "link.txt")
    #expect(info.symlinkDestination == "target.txt")
    #expect(info.json.objectValue?["symlink_destination"] == .string("target.txt"))
    let targetInfo = try scope.fileInfo(url: target)
    #expect(targetInfo.size == 8 && !targetInfo.isSymlink)
    #expect(targetInfo.json.objectValue?["workspace_relative_path"] == .string("target.txt"))
  }

  @Test
  func parentSymlinksCannotEscapeButFinalLinksCanBeInspected() throws {
    let temporary = try ScopedTemporaryDirectory()
    let outside = try ScopedTemporaryDirectory()
    let root = temporary.url.resolvingSymlinksInPath()
    let scope = WorkspaceScope(configuration: .init(workspaceDirectory: root), toolMeta: nil)
    let link = root.appendingPathComponent("outside")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.url)
    #expect(try scope.lexicalWorkspaceURL("outside").path == link.path)
    #expect(try scope.resolvedWorkspaceURLPreservingFinalSymlink("outside") == link)
    #expect(
      throws: GatewayToolError.invalidArguments(
        "[policy.workspace_denied] Path escapes workspace: outside/file")
    ) {
      try scope.resolvedWorkspaceURL("outside/file")
    }
    #expect(
      throws: GatewayToolError.invalidArguments(
        "[policy.workspace_denied] Path escapes workspace through parent symlink: outside/file")
    ) {
      try scope.resolvedWorkspaceURLPreservingFinalSymlink("outside/file")
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
    let scope = WorkspaceScope(configuration: .init(workspaceDirectory: root), toolMeta: nil)
    #expect(
      try scope.workspaceInstructionScopeURL(
        targetURL: file, pathIsDirectory: nil, targetExists: true
      ).path == nested.path)
    #expect(
      try scope.workspaceInstructionScopeURL(
        targetURL: file, pathIsDirectory: true, targetExists: true) == file)
    #expect(
      try scope.workspaceInstructionScopeURL(
        targetURL: nested, originalPath: "a/b/", pathIsDirectory: nil, targetExists: false)
        == nested)
    #expect(
      try scope.workspaceInstructionScopeURL(
        targetURL: file, originalPath: "a/b/file", pathIsDirectory: nil, targetExists: false
      ).path
        == nested.path)
    #expect(
      scope.workspaceInstructionScopeDirectories(scopeURL: nested).map(\.path)
        == [root, root.appendingPathComponent("a"), nested].map(\.path))
    #expect(
      scope.workspaceInstructionScopeDirectories(scopeURL: root.deletingLastPathComponent()) == [
        root
      ])
    #expect(relativePath(fromDirectoryPath: root.path, to: file) == "a/b/file")
    #expect(
      relativePath(fromDirectoryPath: root.path, to: URL(fileURLWithPath: "/outside/file"))
        == "file")
  }

  @Test
  func aSymlinkedWorkspaceRootKeepsCanonicalContainment() throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = try WorkspacePathResolver.canonicalWorkspace(temporary.url)
    let real = root.appendingPathComponent("real")
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
    let scope = WorkspaceScope(configuration: .init(workspaceDirectory: alias), toolMeta: nil)
    #expect(try scope.resolvedWorkspaceURL("file").path == real.appendingPathComponent("file").path)
    #expect(
      try scope.resolvedWorkspaceURLPreservingFinalSymlink(
        real.appendingPathComponent("file").path
      ).path
        == real.appendingPathComponent("file").path)
  }
}
