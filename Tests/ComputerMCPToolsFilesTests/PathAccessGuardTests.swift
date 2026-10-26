import ComputerMCPCore
import ComputerMCPTestSupport
import ComputerMCPToolKit
import ComputerMCPToolsFiles
import Foundation
import Testing

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.nativeIntegration) struct PathAccessGuardTests {
  @Test(arguments: [false, true])
  func revocationAtMutationRollsBack(revokeAfterMutation: Bool) throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url.resolvingSymlinksInPath()
    let target = root.appendingPathComponent("target")
    try Data("original".utf8).write(to: target)
    let checker = MutablePathChecker()
    let files = try ProjectFileAccess(
      project: root, launcher: testExecutionLauncher(),
      mutationObserver: { operation, url, phase in
        if operation == "renameatx_np", url == target,
          phase == (revokeAfterMutation ? .didMutate : .willMutate)
        {
          checker.deny(target)
        }
      }, pathAccess: checker)
    #expect(throws: (any Error).self) { try files.write(Data("changed".utf8), to: target) }
    #expect(try Data(contentsOf: target) == Data("original".utf8))
  }

  @Test(arguments: [false, true])
  func copyChecksEverySourceAndDestination(denySource: Bool) throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url.resolvingSymlinksInPath()
    let source = root.appendingPathComponent("source")
    let destination = root.appendingPathComponent("destination")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let secret = source.appendingPathComponent("secret")
    try Data("secret".utf8).write(to: secret)
    let checker = MutablePathChecker()
    checker.deny(denySource ? secret : destination)
    let files = try ProjectFileAccess(
      project: root, launcher: testExecutionLauncher(), pathAccess: checker)
    #expect(throws: (any Error).self) {
      try files.copy(source, to: destination, overwrite: false, createDirectories: false)
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }

  @Test func listingFiltersDeniedDescendantsAndReadsCheckSymlinkTargets() throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url.resolvingSymlinksInPath()
    let secret = root.appendingPathComponent("secret")
    let visible = root.appendingPathComponent("visible")
    let link = root.appendingPathComponent("link")
    try Data("secret".utf8).write(to: secret)
    try Data("visible".utf8).write(to: visible)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
    let checker = MutablePathChecker()
    checker.deny(secret)
    try HostPathAccess.$current.withValue(checker) {
      let names = try sortedDirectoryChildren(root, includeHidden: true).map(\.lastPathComponent)
      #expect(names == ["visible"])
      #expect(throws: (any Error).self) {
        try readBoundedFileData(url: link, path: "link", maxBytes: 100)
      }
    }
  }

  @Test func realListingsTraverseAncestorsWithoutExposingTheirOtherChildren() throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url.resolvingSymlinksInPath()
    let project = root.appendingPathComponent("Downloads/project")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try Data("visible".utf8).write(to: project.appendingPathComponent("file"))
    try Data("secret".utf8).write(to: root.appendingPathComponent("Downloads/secret"))
    let provider = FilesToolProvider(
      environment: .init(
        launcher: testExecutionLauncher(),
        configuration: .init(
          builtin: .init(enabled: ["file.read", "file.list", "file.tree"]), projectDirectory: root))
    )
    try HostPathAccess.$current.withValue(TraversalPathChecker(root: project)) {
      for tool in ["file.list", "file.tree"] {
        let result = try provider.callTool(
          .init(
            name: tool,
            arguments: .object([
              "path": .string("."), "max_depth": .integer(4), "recursive_depth": .integer(4),
            ]), context: .empty))
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(encoded.contains("project"))
        #expect(encoded.contains("file"))
        #expect(!encoded.contains("secret"))
      }
    }
  }

  @Test func descriptorReadRechecksAfterAnAccessCheckChangesTheLink() throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url.resolvingSymlinksInPath()
    let allowed = root.appendingPathComponent("allowed")
    let secret = root.appendingPathComponent("secret")
    let link = root.appendingPathComponent("link")
    try Data("allowed".utf8).write(to: allowed)
    try Data("secret".utf8).write(to: secret)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: allowed)
    let checker = SwappingPathChecker(link: link, secret: secret)
    HostPathAccess.$current.withValue(checker) {
      #expect(throws: (any Error).self) {
        try readBoundedFileData(url: link, path: "link", maxBytes: 100)
      }
    }
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: allowed)
    let toolChecker = SwappingPathChecker(link: allowed, secret: secret)
    let provider = FilesToolProvider(
      environment: .init(
        launcher: testExecutionLauncher(),
        configuration: .init(
          builtin: .init(enabled: ["file.read", "file.list", "file.tree"]), projectDirectory: root))
    )
    HostPathAccess.$current.withValue(toolChecker) {
      #expect(throws: (any Error).self) {
        try provider.callTool(
          .init(name: "file.read", arguments: .object(["path": .string("link")]), context: .empty))
      }
    }
    #expect(toolChecker.lock.withLock { toolChecker.swapped })
  }
}

private final class MutablePathChecker: HostPathAccessChecking, @unchecked Sendable {
  private let lock = NSLock()
  private var denied: URL?
  func deny(_ path: URL) { lock.withLock { denied = path } }
  func check(_ path: URL, operation: HostPathOperation) throws {
    let path = path.resolvingSymlinksInPath().path
    if lock.withLock({ denied.map { path == $0.path || path.hasPrefix($0.path + "/") } ?? false }) {
      throw CocoaError(.fileReadNoPermission)
    }
  }
}

private final class SwappingPathChecker: HostPathAccessChecking, @unchecked Sendable {
  let link: URL
  let secret: URL
  let lock = NSLock()
  var swapped = false
  init(link: URL, secret: URL) {
    self.link = link
    self.secret = secret
  }
  func check(_ path: URL, operation: HostPathOperation) throws {
    try lock.withLock {
      guard path.resolvingSymlinksInPath() != secret else {
        throw CocoaError(.fileReadNoPermission)
      }
      if !swapped, path == link {
        swapped = true
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
      }
    }
  }
}

private struct TraversalPathChecker: HostPathAccessChecking {
  let root: URL
  func check(_ url: URL, operation: HostPathOperation) throws {
    let path = url.resolvingSymlinksInPath().path
    if path == root.path || path.hasPrefix(root.path + "/") { return }
    if operation == .openDirectory || operation == .listDirectory,
      root.path.hasPrefix(path == "/" ? "/" : path + "/")
    {
      return
    }
    throw CocoaError(.fileReadNoPermission)
  }
}
