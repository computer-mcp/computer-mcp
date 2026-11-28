import ComputerMCPCore
import ComputerMCPProcess
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
    let files = try fileAccess(
      project: root, checker: checker,
      mutationObserver: { operation, url, phase in
        if operation == "renameatx_np", url == target,
          phase == (revokeAfterMutation ? .didMutate : .willMutate)
        {
          checker.deny(target)
        }
      })
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
    let files = try fileAccess(project: root, checker: checker)
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

  @Test(arguments: [1, 2, 4])
  func injectedCheckerRechecksFileReadAfterPreflight(trigger: Int) throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url.resolvingSymlinksInPath()
    let allowed = root.appendingPathComponent("allowed")
    let denied = root.appendingPathComponent("denied")
    for directory in [allowed, denied] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data("private payload".utf8).write(to: directory.appendingPathComponent("file"))
    }
    let checker = EntryReadChecker(allowed: allowed, denied: denied, trigger: trigger)
    let provider = FilesToolProvider(
      environment: .init(
        launcher: testExecutionLauncher(),
        configuration: .init(builtin: .init(enabled: ["file.read"]), projectDirectory: root),
        pathAccess: checker))
    #expect(throws: (any Error).self) {
      try provider.callTool(
        .init(
          name: "file.read",
          arguments: .object(["path": .string("allowed/file")]), context: .empty))
    }
    #expect(checker.checks > trigger)
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

  private func fileAccess(
    project: URL, checker: any HostPathAccessChecking,
    mutationObserver: ((String, URL, ProjectFileAccess.MutationPhase) throws -> Void)? = nil
  ) throws -> ProjectFileAccess {
    let administration = ExecutionAdministration(
      mode: .fullAccess,
      environment: try .init(fullAccessVariables: ["PATH": systemUtilityPath]))
    // Initialization runs the fixed Git-layout probe; mutation tests use their injected checker.
    return try ExecutionAdministration.$current.withValue(administration) {
      try ProjectFileAccess(
        project: project, launcher: testExecutionLauncher(),
        mutationObserver: mutationObserver, pathAccess: checker)
    }
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

private final class EntryReadChecker: HostPathAccessChecking, @unchecked Sendable {
  let allowed: URL
  let denied: URL
  let trigger: Int
  private(set) var checks = 0
  init(allowed: URL, denied: URL, trigger: Int) {
    self.allowed = allowed
    self.denied = denied
    self.trigger = trigger
  }
  func check(_ path: URL, operation: HostPathOperation) throws {
    checks += 1
    if checks > trigger,
      trigger > 2 || path.resolvingSymlinksInPath().path.hasPrefix(denied.path + "/")
    {
      throw CocoaError(.fileReadNoPermission)
    }
    if checks == trigger, trigger <= 2 {
      try FileManager.default.moveItem(at: allowed, to: allowed.appendingPathExtension("retired"))
      try FileManager.default.createSymbolicLink(at: allowed, withDestinationURL: denied)
    }
  }
}
