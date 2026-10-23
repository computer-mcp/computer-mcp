import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPToolsFiles

@Suite(.nativeIntegration)
struct FileMutationRaceTests {
  private func provider(
    _ root: URL,
    observer: (@Sendable (String, URL, ProjectFileAccess.MutationPhase) throws -> Void)? = nil
  ) -> FilesToolProvider {
    FilesToolProvider(
      environment: ToolEnvironment(
        configuration: .init(
          builtin: .init(enabled: [
            "file.move", "file.copy", "file.write", "file.mkdir", "file.write_files",
          ]),
          projectDirectory: root)), fileMutationObserver: observer)
  }

  private func call(_ tools: FilesToolProvider, _ name: String, _ arguments: [String: JSONValue])
    throws
  {
    _ = try tools.callTool(.init(name: name, arguments: .object(arguments), context: .empty))
  }

  @Test(arguments: ["file", "parent", "hardlink"])
  func copyRejectsAChangedSourceAndCleansItsStaging(change: String) throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url.appendingPathComponent("project")
    let parent = root.appendingPathComponent("parent")
    let source = parent.appendingPathComponent("source")
    let outside = temporary.url.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try Data("original".utf8).write(to: source)
    let target = root.appendingPathComponent("target")
    try Data("destination".utf8).write(to: target)
    let mover = FileGuardDirectoryMover(from: change == "parent" ? parent : source, to: outside)
    let tools = provider(root) { operation, _, phase in
      guard operation == "fcopyfile", phase == .didMutate else { return }
      if change == "hardlink" {
        try FileManager.default.linkItem(at: source, to: outside)
      } else {
        try mover.move()
      }
    }
    #expect(throws: (any Error).self) {
      try call(
        tools, "file.copy",
        [
          "source": .string("parent/source"), "destination": .string("target"),
          "overwrite": .bool(true),
        ])
    }
    #expect(try Data(contentsOf: target) == Data("destination".utf8))
    #expect(
      try Data(contentsOf: change == "parent" ? outside.appendingPathComponent("source") : outside)
        == Data("original".utf8))
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy {
        !$0.hasSuffix(".tmp")
      })
  }

  @Test(arguments: [ProjectFileAccess.MutationPhase.willCheck, .willMutate, .didMutate])
  func movePreservesAReplacementSource(phase: ProjectFileAccess.MutationPhase) throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url
    let source = root.appendingPathComponent("source")
    let target = root.appendingPathComponent("target")
    let retained = root.appendingPathComponent("retained")
    try Data("original".utf8).write(to: source)
    let mover = FileGuardDirectoryMover(from: source, to: retained)
    let tools = provider(root) { operation, url, step in
      guard operation == "renameatx_np", url == source, step == phase else { return }
      if phase != .didMutate { try mover.move() }
      try Data("replacement".utf8).write(to: source)
      if phase == .didMutate { throw CocoaError(.fileWriteUnknown) }
    }
    #expect(throws: (any Error).self) {
      try call(tools, "file.move", ["source": .string("source"), "destination": .string("target")])
    }
    #expect(try Data(contentsOf: source) == Data("replacement".utf8))
    #expect(try Data(contentsOf: phase == .didMutate ? target : retained) == Data("original".utf8))
    if phase != .didMutate { #expect(!FileManager.default.fileExists(atPath: target.path)) }
  }

  @Test
  func copyCleanupPreservesAReplacementTemporaryAndNamesItsStaging() throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url
    let source = root.appendingPathComponent("source")
    let retained = root.appendingPathComponent("retained")
    try Data("original".utf8).write(to: source)
    let tools = provider(root) { operation, _, phase in
      guard operation == "fcopyfile", phase == .willMutate else { return }
      try FileGuardConcurrentAction.run {
        let stagingName = try #require(
          FileManager.default.contentsOfDirectory(atPath: root.path).first { $0.hasSuffix(".tmp") })
        let staging = root.appendingPathComponent(stagingName)
        let temporaryName = try #require(
          FileManager.default.contentsOfDirectory(atPath: staging.path).first)
        let output = staging.appendingPathComponent(temporaryName)
        try FileManager.default.moveItem(at: output, to: retained)
        try Data("foreign".utf8).write(to: output)
      }
    }
    let error = #expect(throws: (any Error).self) {
      try call(tools, "file.copy", ["source": .string("source"), "destination": .string("output")])
    }
    let name = try #require(
      FileManager.default.contentsOfDirectory(atPath: root.path).first { $0.hasSuffix(".tmp") })
    let staging = root.appendingPathComponent(name)
    let replacement = staging.appendingPathComponent(
      try #require(FileManager.default.contentsOfDirectory(atPath: staging.path).first))
    #expect(String(describing: error).contains(staging.path))
    #expect(String(describing: error).contains(replacement.path))
    #expect(try Data(contentsOf: replacement) == Data("foreign".utf8))
    #expect(try Data(contentsOf: retained) == Data("original".utf8))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("output").path))
  }

  @Test
  func failedCopyPublicationPreservesAForeignDirectoryMovedIntoStaging() throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url
    let source = root.appendingPathComponent("source")
    let foreign = root.appendingPathComponent("foreign")
    for directory in [source, foreign] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    try Data("original".utf8).write(to: source.appendingPathComponent("member"))
    try Data("foreign".utf8).write(to: foreign.appendingPathComponent("member"))
    try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: foreign.path)
    let tools = provider(root) { operation, url, phase in
      guard operation == "renameatx_np", phase == .willMutate, url.lastPathComponent == "copy",
        FileManager.default.fileExists(atPath: url.path)
      else { return }
      try FileGuardConcurrentAction.run {
        try FileManager.default.moveItem(at: foreign, to: url.appendingPathComponent("foreign"))
      }
      throw CocoaError(.fileWriteUnknown)
    }
    let error = #expect(throws: (any Error).self) {
      try call(tools, "file.copy", ["source": .string("source"), "destination": .string("output")])
    }
    let name = try #require(
      FileManager.default.contentsOfDirectory(atPath: root.path).first { $0.hasSuffix(".tmp") })
    let staging = root.appendingPathComponent(name)
    let replacement = staging.appendingPathComponent("copy/foreign")
    #expect(String(describing: error).contains(staging.path))
    #expect(String(describing: error).contains(replacement.path))
    #expect(
      try Data(contentsOf: replacement.appendingPathComponent("member")) == Data("foreign".utf8))
    #expect(
      try FileManager.default.attributesOfItem(atPath: replacement.path)[.posixPermissions]
        as? NSNumber == 0o750)
    #expect(
      try FileManager.default.contentsOfDirectory(
        atPath: replacement.deletingLastPathComponent().path) == ["foreign"])
    #expect(try Data(contentsOf: source.appendingPathComponent("member")) == Data("original".utf8))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("output").path))
  }

  @Test(arguments: [ProjectFileAccess.MutationPhase.didMutate, .didCheck])
  func moveRollbackLeavesAReplacementDestinationInPlace(phase: ProjectFileAccess.MutationPhase)
    throws
  {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url
    let source = root.appendingPathComponent("source")
    let target = root.appendingPathComponent("target")
    let retained = root.appendingPathComponent("retained")
    try Data("original".utf8).write(to: source)
    let mover = FileGuardDirectoryMover(from: target, to: retained)
    let tools = provider(root) { operation, _, step in
      guard operation == "renameatx_np", step == phase else { return }
      try mover.move()
      try Data("replacement".utf8).write(to: target)
      if phase == .didCheck { throw CocoaError(.fileWriteUnknown) }
    }
    let error = #expect(throws: (any Error).self) {
      try call(tools, "file.move", ["source": .string("source"), "destination": .string("target")])
    }
    #expect(String(describing: error).contains("changed concurrently"))
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(try Data(contentsOf: target) == Data("replacement".utf8))
    #expect(try Data(contentsOf: retained) == Data("original".utf8))
  }

  @Test
  func moveValidationRollbackPreservesAReplacementAfterThePostCheck() throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url
    let source = root.appendingPathComponent("source")
    let target = root.appendingPathComponent("target")
    let retained = root.appendingPathComponent("retained")
    try Data("original".utf8).write(to: source)
    let mover = FileGuardDirectoryMover(from: target, to: retained)
    let tools = provider(root) { operation, _, phase in
      guard operation == "renameatx_np", phase == .didCheck else { return }
      try mover.move()
      try FileManager.default.createSymbolicLink(at: target, withDestinationURL: retained)
    }
    let error = #expect(throws: (any Error).self) {
      try call(tools, "file.move", ["source": .string("source"), "destination": .string("target")])
    }
    #expect(String(describing: error).contains("changed concurrently"))
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == retained.path)
    #expect(try Data(contentsOf: retained) == Data("original".utf8))
  }

  @Test(arguments: ["mkdirat", "openat", "renameatx_np"])
  func creationRollbackPreservesReplacementEntries(operation: String) throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url
    let target = root.appendingPathComponent("output")
    let retained = root.appendingPathComponent("retained")
    let tools = provider(root) { name, _, phase in
      guard name == operation, phase == .didCheck else { return }
      let path: URL
      if operation == "openat" {
        let name = try #require(
          FileManager.default.contentsOfDirectory(atPath: root.path).first { $0.hasSuffix(".tmp") })
        path = root.appendingPathComponent(name)
      } else {
        path = target
      }
      try FileGuardDirectoryMover(from: path, to: retained).move()
      if operation == "mkdirat" {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        try Data("replacement".utf8).write(to: path.appendingPathComponent("member"))
      } else {
        try Data("replacement".utf8).write(to: path)
      }
      throw CocoaError(.fileWriteUnknown)
    }
    let error = #expect(throws: (any Error).self) {
      try call(
        tools, operation == "mkdirat" ? "file.mkdir" : "file.write",
        ["path": .string("output"), "content": .string("generated")])
    }
    #expect(String(describing: error).contains("changed concurrently"))
    let replacement: URL
    if operation == "openat" {
      let name = try #require(
        FileManager.default.contentsOfDirectory(atPath: root.path).first { $0.hasSuffix(".tmp") })
      replacement = root.appendingPathComponent(name)
    } else {
      replacement = operation == "mkdirat" ? target.appendingPathComponent("member") : target
    }
    #expect(try Data(contentsOf: replacement) == Data("replacement".utf8))
    #expect(FileManager.default.fileExists(atPath: retained.path))
  }

  @Test
  func overwriteRollbackDoesNotRestoreAReplacementBackup() throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url
    let target = root.appendingPathComponent("output")
    let retained = root.appendingPathComponent("retained")
    try Data("original".utf8).write(to: target)
    let tools = provider(root) { operation, _, phase in
      guard operation == "unlinkat", phase == .willMutate else { return }
      let name = try #require(
        FileManager.default.contentsOfDirectory(atPath: root.path).first { $0.hasSuffix(".tmp") })
      let backup = root.appendingPathComponent(name)
      try FileGuardDirectoryMover(from: backup, to: retained).move()
      try Data("replacement".utf8).write(to: backup)
    }
    let error = #expect(throws: (any Error).self) {
      try call(tools, "file.write", ["path": .string("output"), "content": .string("generated")])
    }
    #expect(String(describing: error).contains("changed concurrently"))
    #expect(!FileManager.default.fileExists(atPath: target.path))
    #expect(try Data(contentsOf: retained) == Data("original".utf8))
    let name = try #require(
      FileManager.default.contentsOfDirectory(atPath: root.path).first { $0.hasSuffix(".tmp") })
    #expect(try Data(contentsOf: root.appendingPathComponent(name)) == Data("replacement".utf8))
  }

  @Test(arguments: [ProjectFileAccess.MutationPhase.didMutate, .didCheck])
  func overwriteRestoresItsOwnRecreatedBackup(phase: ProjectFileAccess.MutationPhase) throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url.appendingPathComponent("project")
    let parent = root.appendingPathComponent("parent")
    let outside = temporary.url.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let target = parent.appendingPathComponent("output")
    try Data("original".utf8).write(to: target)
    let mover = FileGuardDirectoryMover(from: parent, to: outside)
    let tools = provider(root) { operation, _, step in
      guard operation == "unlinkat", step == phase else { return }
      try mover.move()
      if phase == .didCheck { throw CocoaError(.fileWriteUnknown) }
    }
    #expect(throws: (any Error).self) {
      try call(
        tools, "file.write", ["path": .string("parent/output"), "content": .string("generated")])
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["output"])
    #expect(try Data(contentsOf: outside.appendingPathComponent("output")) == Data("original".utf8))
  }

  @Test
  func batchWritesStayBoundedInALargeProject() throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url
    for index in 0..<200 {
      let directory = root.appendingPathComponent("unrelated-\(index)")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      try Data("principal data".utf8).write(to: directory.appendingPathComponent(".git"))
      for member in 0..<20 {
        try Data().write(to: directory.appendingPathComponent("member-\(member)"))
      }
    }
    let entries: [JSONValue] = try (0..<50).map { index in
      let path = "output-\(index)"
      try Data("original".utf8).write(to: root.appendingPathComponent(path))
      return .object(["path": .string(path), "content": .string("changed")])
    }
    let start = ContinuousClock.now
    try call(
      provider(root), "file.write_files",
      [
        "files": .array(entries), "overwrite": .bool(true), "dry_run": .bool(false),
        "confirm_write": .bool(true),
      ])
    #expect(start.duration(to: .now) < .seconds(10))
    for index in 0..<50 {
      #expect(
        try Data(contentsOf: root.appendingPathComponent("output-\(index)")) == Data("changed".utf8)
      )
    }
  }
}
