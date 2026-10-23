import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@Suite(.nativeIntegration)
struct ProjectFileMutationTests {
  @Test
  func unlinkRechecksHardLinksImmediatelyBeforeMutation() throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = root.appendingPathComponent("existing")
    let link = temporary.url.appendingPathComponent("linked")
    try Data("original".utf8).write(to: target)
    let files = try ProjectFileAccess(project: root) { operation, _, phase in
      if operation == "unlinkat", phase == .willMutate {
        let name = try #require(
          FileManager.default.contentsOfDirectory(atPath: root.path).first { $0.hasSuffix(".tmp") })
        try FileManager.default.linkItem(at: root.appendingPathComponent(name), to: link)
      }
    }
    #expect(throws: (any Error).self) { try files.write(Data("replacement".utf8), to: target) }
    #expect(try Data(contentsOf: target) == Data("original".utf8))
    #expect(try Data(contentsOf: link) == Data("original".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["existing"])
  }

  @Test(
    arguments: ["mkdirat", "openat", "renameatx_np", "unlinkat"],
    [ProjectFileAccess.MutationPhase.willCheck, .willMutate, .didMutate])
  func movedParentRollsBackEveryMutation(
    operation: String, phase: ProjectFileAccess.MutationPhase
  ) throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url.appendingPathComponent("project")
    let parent = root.appendingPathComponent("parent")
    let outside = temporary.url.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let target = parent.appendingPathComponent("existing")
    try Data("original".utf8).write(to: target)
    let mover = FileGuardDirectoryMover(from: parent, to: outside)
    let files = try ProjectFileAccess(project: root) { name, url, step in
      let expected = operation == "mkdirat" ? "leaf" : "existing"
      if name == operation, step == phase, url.lastPathComponent == expected { try mover.move() }
    }
    #expect(throws: (any Error).self) {
      if operation == "mkdirat" {
        try files.mkdir(parent.appendingPathComponent("new/leaf"), recursive: true)
      } else {
        try files.write(Data("replacement".utf8), to: target)
      }
    }
    #expect(mover.didMove)
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["existing"])
    #expect(
      try Data(contentsOf: outside.appendingPathComponent("existing")) == Data("original".utf8))
  }

  @Test(arguments: [false, true])
  func moveRollsBackWhenEitherParentLeavesProject(destinationMoves: Bool) throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url.appendingPathComponent("project")
    let input = root.appendingPathComponent("input")
    let output = root.appendingPathComponent("output")
    for directory in [input, output] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try Data("original".utf8).write(to: input.appendingPathComponent("source"))
    let outside = temporary.url.appendingPathComponent("outside")
    let mover = FileGuardDirectoryMover(from: destinationMoves ? output : input, to: outside)
    let files = try ProjectFileAccess(project: root) { operation, _, phase in
      if operation == "renameatx_np", phase == .didMutate { try mover.move() }
    }
    #expect(throws: (any Error).self) {
      try files.move(
        input.appendingPathComponent("source"), to: output.appendingPathComponent("target"),
        overwrite: false, createDirectories: false)
    }
    #expect(mover.didMove)
    let original = (destinationMoves ? input : outside).appendingPathComponent("source")
    #expect(try Data(contentsOf: original) == Data("original".utf8))
    #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("target").path))
    #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("target").path))
  }

  @Test
  func failedProducerDoesNotDeleteAReplacementInAMovedDirectory() throws {
    let temporary = try ScopedTemporaryDirectory()
    let root = temporary.url.appendingPathComponent("project")
    let parent = root.appendingPathComponent("parent")
    let outside = temporary.url.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let files = try ProjectFileAccess(project: root)
    var replacement: String?
    #expect(throws: (any Error).self) {
      try files.writeGenerated(
        to: parent.appendingPathComponent("output"), overwrite: false, createDirectories: false
      ) { _ in
        let name = try #require(FileManager.default.contentsOfDirectory(atPath: parent.path).first)
        replacement = name
        let path = parent.appendingPathComponent(name)
        try FileManager.default.removeItem(at: path)
        try Data("replacement".utf8).write(to: path)
        try FileGuardDirectoryMover(from: parent, to: outside).move()
      }
    }
    let name = try #require(replacement)
    #expect(try Data(contentsOf: outside.appendingPathComponent(name)) == Data("replacement".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == [name])
  }
}

/// The worker moves the directory while the operation is paused at a syscall boundary.
final class FileGuardDirectoryMover: @unchecked Sendable {
  private let source: URL
  private let destination: URL
  private let lock = NSLock()
  private var result: Result<Void, any Error>?

  init(from source: URL, to destination: URL) {
    self.source = source
    self.destination = destination
  }

  var didMove: Bool { lock.withLock { result != nil } }

  func move() throws {
    if didMove { return }
    let completed = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      let outcome = Result {
        try FileManager.default.moveItem(at: self.source, to: self.destination)
      }
      self.lock.withLock { self.result = outcome }
      completed.signal()
    }
    guard completed.wait(timeout: .now() + .seconds(10)) == .success else {
      throw CocoaError(.fileWriteUnknown)
    }
    try lock.withLock { try result!.get() }
  }
}

final class FileGuardConcurrentAction: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<Void, any Error>?
  private let completed = DispatchSemaphore(value: 0)

  init(_ body: @escaping @Sendable () throws -> Void) {
    Thread.detachNewThread {
      let result = Result { try body() }
      self.lock.withLock { self.result = result }
      self.completed.signal()
    }
  }

  func wait() throws {
    guard completed.wait(timeout: .now() + .seconds(10)) == .success else {
      throw CocoaError(.fileWriteUnknown)
    }
    try lock.withLock { try result!.get() }
  }

  static func run(_ body: @escaping @Sendable () throws -> Void) throws {
    try FileGuardConcurrentAction(body).wait()
  }
}
