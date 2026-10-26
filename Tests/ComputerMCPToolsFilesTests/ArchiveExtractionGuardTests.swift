import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPToolsFiles

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

@Suite(.nativeIntegration)
struct ArchiveExtractionGuardTests {
  @discardableResult
  private func extract(
    _ root: URL, runner: ArchiveExtractionRunner, archive: String = "input.tar",
    destination: String = "output", overwrite: Bool = false,
    observer: (@Sendable (String, URL, ProjectFileAccess.MutationPhase) throws -> Void)? = nil
  )
    throws -> Bool
  {
    let tools = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: .init(builtin: .init(enabled: ["archive.extract"]), projectDirectory: root),
        commandRunner: runner,
        builtinExecutables: ArchiveFixture.extractionExecutables),
      fileMutationObserver: observer)
    let invocation = ToolInvocation(
      name: "archive.extract",
      arguments: .object([
        "path": .string(archive), "destination": .string(destination),
        "overwrite": .bool(overwrite),
        "create_directories": .bool(true), "dry_run": .bool(false),
        "confirm_extract": .bool(true),
        "max_output_bytes": .integer(1_048_576),
      ]), context: .empty)
    if archive.hasSuffix(".zip"), !ArchiveFixture.zipExtractionAvailable {
      let before = try FileManager.default.contentsOfDirectory(atPath: root.path)
      #expect(
        throws: GatewayToolError.disabled(
          "Builtin command 'bsdtar' is unavailable on this platform.")
      ) {
        _ = try tools.callTool(invocation)
      }
      #expect(runner.calls == 0)
      #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == before)
      return false
    }
    _ = try tools.callTool(invocation)
    return true
  }

  @Test(
    arguments: ["tar", "tar.gz", "zip", "zip-reordered", "zip-dos"], ["new", "existing", "project"])
  func publishedMembersKeepArchiveModesAndModificationTimes(format: String, destination: String)
    throws
  {
    let fixture = try ArchiveFixture()
    let output =
      destination == "project" ? fixture.root : fixture.root.appendingPathComponent("output")
    defer {
      for path in [".", "parent", "parent/nested"] {
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o700], ofItemAtPath: output.appendingPathComponent(path).path)
      }
      fixture.remove()
    }
    var entries: [ArchiveFixture.Entry] = [
      .init(
        name: "./", kind: "directory", mode: 0o555, modificationSeconds: 946_684_801,
        modificationNanoseconds: format.hasPrefix("zip") ? 0 : 1),
      .init(
        name: "parent/", kind: "directory", mode: 0o555, modificationSeconds: 978_307_202,
        modificationNanoseconds: format.hasPrefix("zip") ? 0 : 23),
      .init(
        name: "parent/nested/file", content: "archived", modificationSeconds: 1_009_843_203,
        modificationNanoseconds: format.hasPrefix("zip") ? 0 : 123_456_789),
      .init(
        name: "parent/nested/", kind: "directory", mode: 0o700, modificationSeconds: 1_041_379_204,
        modificationNanoseconds: format.hasPrefix("zip") ? 0 : 7),
      .init(name: "parent/empty", content: "", modificationSeconds: 1_072_915_205),
      .init(name: "empty/", kind: "directory", mode: 0o755, modificationSeconds: 1_104_537_606),
    ]
    if format == "zip-dos" {
      for index in entries.indices {
        // DOS timestamps store local wall time in two-second increments.
        let seconds = try #require(entries[index].modificationSeconds)
        entries[index].modificationSeconds = seconds - seconds % 2
      }
    }
    let source = try fixture.archive(entries, format: format)
    let name = "input." + (format.hasPrefix("zip") ? "zip" : format)
    try FileManager.default.moveItem(at: source, to: fixture.root.appendingPathComponent(name))
    if destination == "existing" {
      try FileManager.default.createDirectory(
        at: output.appendingPathComponent("parent/nested"), withIntermediateDirectories: true)
      try Data("previous".utf8).write(to: output.appendingPathComponent("parent/nested/file"))
    }
    let runner = ArchiveExtractionRunner(
      base: ToolEnvironment(configuration: .init()).commandRunner)
    guard
      try extract(
        fixture.root, runner: runner, archive: name,
        destination: destination == "project" ? "." : "output", overwrite: destination == "existing"
      )
    else { return }
    #expect(
      try Data(contentsOf: output.appendingPathComponent("parent/nested/file"))
        == Data("archived".utf8))
    for entry in entries where entry.name != "./" || destination == "new" {
      var info = stat()
      try #require(lstat(output.appendingPathComponent(entry.name).path, &info) == 0)
      if format != "zip-dos" {
        #expect(Int(info.st_mode & 0o777) == entry.mode, "\(entry.name) mode")
      }
      #if canImport(Darwin)
        let modified = info.st_mtimespec
      #else
        let modified = info.st_mtim
      #endif
      #expect(
        Int64(modified.tv_sec) == (try #require(entry.modificationSeconds)), "\(entry.name) seconds"
      )
      #expect(modified.tv_nsec == entry.modificationNanoseconds, "\(entry.name) nanoseconds")
    }
  }

  @Test(
    arguments: ["tar", "zip"],
    [(".", 0), (".", 0o555), ("output", 0), ("output", 0o555)])
  func existingDestinationKeepsModeAndTimes(
    format: String, scenario: (destination: String, rootMode: Int)
  ) throws {
    let (destination, rootMode) = scenario
    let fixture = try ArchiveFixture()
    let output = fixture.root.appendingPathComponent(destination)
    defer {
      for path in ["parent", "parent/nested"] {
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o700], ofItemAtPath: output.appendingPathComponent(path).path)
      }
      fixture.remove()
    }
    let entries: [ArchiveFixture.Entry] = [
      .init(
        name: ".//./", kind: "directory", mode: rootMode, modificationSeconds: 946_684_801),
      .init(name: "parent/", kind: "directory", mode: 0o555, modificationSeconds: 978_307_202),
      .init(name: "parent/nested/member", content: "archived"),
      .init(
        name: "parent/nested/", kind: "directory", mode: 0, modificationSeconds: 1_041_379_204),
    ]
    let archive = try fixture.archive(entries, format: format)
    let name = "input." + format
    try FileManager.default.moveItem(at: archive, to: fixture.root.appendingPathComponent(name))
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let fd = open(output.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    try #require(fd >= 0)
    defer { close(fd) }
    try #require(fchmod(fd, 0o750) == 0)
    let times = [
      timespec(tv_sec: 1_500_000_010, tv_nsec: 11), timespec(tv_sec: 1_500_000_020, tv_nsec: 22),
    ]
    try #require(futimens(fd, times) == 0)
    var original = stat()
    try #require(fstat(fd, &original) == 0)
    let runner = ArchiveExtractionRunner(
      base: ToolEnvironment(configuration: .init()).commandRunner)
    guard try extract(fixture.root, runner: runner, archive: name, destination: destination) else {
      return
    }
    var published = stat()
    try #require(lstat(output.path, &published) == 0)
    #expect(published.st_dev == original.st_dev && published.st_ino == original.st_ino)
    #expect(published.st_mode == original.st_mode)
    #if canImport(Darwin)
      let accessed = published.st_atimespec
      let modified = published.st_mtimespec
    #else
      let accessed = published.st_atim
      let modified = published.st_mtim
    #endif
    #expect(accessed.tv_sec == 1_500_000_010 && accessed.tv_nsec == 11)
    #expect(modified.tv_sec == 1_500_000_020 && modified.tv_nsec == 22)
    for entry in entries.dropFirst() where entry.kind == "directory" {
      var info = stat()
      try #require(lstat(output.appendingPathComponent(entry.name).path, &info) == 0)
      #expect(Int(info.st_mode & 0o777) == entry.mode, "\(entry.name) mode")
      #if canImport(Darwin)
        let modified = info.st_mtimespec
      #else
        let modified = info.st_mtim
      #endif
      #expect(Int64(modified.tv_sec) == entry.modificationSeconds, "\(entry.name) seconds")
      #expect(modified.tv_nsec == 0, "\(entry.name) nanoseconds")
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: output.appendingPathComponent("parent/nested").path)
    #expect(
      try Data(contentsOf: output.appendingPathComponent("parent/nested/member"))
        == Data("archived".utf8))
  }

  @Test
  func destinationCreatedAfterPreflightKeepsItsMetadata() throws {
    let fixture = try ArchiveFixture()
    defer { fixture.remove() }
    let output = fixture.root.appendingPathComponent("output")
    let archive = try fixture.archive([
      .init(name: "./", kind: "directory", mode: 0, modificationSeconds: 946_684_801),
      .init(name: "member", content: "archived"),
    ])
    try FileManager.default.moveItem(
      at: archive, to: fixture.root.appendingPathComponent("input.tar"))
    let runner = ArchiveExtractionRunner(
      base: ToolEnvironment(configuration: .init()).commandRunner)
    try extract(fixture.root, runner: runner) { operation, url, phase in
      if operation == "mkdirat", phase == .willMutate, url.lastPathComponent == "output",
        !FileManager.default.fileExists(atPath: url.path)
      {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        try #require(fd >= 0)
        defer { close(fd) }
        try #require(fchmod(fd, 0o750) == 0)
        let times = [
          timespec(tv_sec: 1_500_000_010, tv_nsec: 11),
          timespec(tv_sec: 1_500_000_020, tv_nsec: 22),
        ]
        try #require(futimens(fd, times) == 0)
      }
    }
    var published = stat()
    try #require(lstat(output.path, &published) == 0)
    #expect(published.st_mode & 0o777 == 0o750)
    #if canImport(Darwin)
      let accessed = published.st_atimespec
      let modified = published.st_mtimespec
    #else
      let accessed = published.st_atim
      let modified = published.st_mtim
    #endif
    #expect(accessed.tv_sec == 1_500_000_010 && accessed.tv_nsec == 11)
    #expect(modified.tv_sec == 1_500_000_020 && modified.tv_nsec == 22)
    #expect(try Data(contentsOf: output.appendingPathComponent("member")) == Data("archived".utf8))
  }

  @Test(arguments: ["staging", "metadata"])
  func replacingACreatedDestinationRefusesForeignDirectoryMetadata(boundary: String) throws {
    let fixture = try ArchiveFixture()
    defer { fixture.remove() }
    let output = fixture.root.appendingPathComponent("output")
    let moved = fixture.root.appendingPathComponent("original-output")
    let changedTime = fixture.root.appendingPathComponent("foreign-ctime")
    let archive = try fixture.archive([
      .init(name: "./", kind: "directory", mode: 0, modificationSeconds: 946_684_801),
      .init(name: "member", content: "archived"),
      .init(name: "child/", kind: "directory", mode: 0o755, modificationSeconds: 978_307_202),
    ])
    try FileManager.default.moveItem(
      at: archive, to: fixture.root.appendingPathComponent("input.tar"))
    let runner = ArchiveExtractionRunner(
      base: ToolEnvironment(configuration: .init()).commandRunner)
    #expect(throws: (any Error).self) {
      try extract(fixture.root, runner: runner) { operation, url, phase in
        let replacing =
          (boundary == "staging" && operation == "mkdirat" && url.lastPathComponent == "output")
          || (boundary == "metadata" && operation == "futimens" && url.lastPathComponent == "child")
        if replacing, phase == .didCheck,
          !FileManager.default.fileExists(atPath: moved.path)
        {
          try FileManager.default.moveItem(at: output, to: moved)
          try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
          try FileManager.default.setAttributes(
            [
              .posixPermissions: 0o750,
              .modificationDate: Date(timeIntervalSince1970: 1_500_000_020),
            ],
            ofItemAtPath: output.path)
          var info = stat()
          try #require(lstat(output.path, &info) == 0)
          #if canImport(Darwin)
            let changed = info.st_ctimespec
          #else
            let changed = info.st_ctim
          #endif
          try Data("\(changed.tv_sec):\(changed.tv_nsec)".utf8).write(to: changedTime)
        }
      }
    }
    var info = stat()
    try #require(lstat(output.path, &info) == 0)
    #expect(info.st_mode & 0o777 == 0o750)
    #if canImport(Darwin)
      let modified = info.st_mtimespec
      let changed = info.st_ctimespec
    #else
      let modified = info.st_mtim
      let changed = info.st_ctim
    #endif
    #expect(modified.tv_sec == 1_500_000_020 && modified.tv_nsec == 0)
    #expect(try Data(contentsOf: changedTime) == Data("\(changed.tv_sec):\(changed.tv_nsec)".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    #expect(
      FileManager.default.fileExists(atPath: moved.appendingPathComponent("member").path)
        == (boundary == "metadata"))
  }

  @Test(arguments: [false, true])
  func persistentHardLinkToExtractionContentsFailsAndCleansStaging(duringExtraction: Bool) throws {
    let fixture = try ArchiveFixture()
    defer { fixture.remove() }
    let outside = try ScopedTemporaryDirectory()
    let link = outside.url.appendingPathComponent("contents")
    let payload = String(repeating: "x", count: 1_048_576)
    let archive = try fixture.archive([.init(name: "member", content: payload)])
    try FileManager.default.moveItem(
      at: archive, to: fixture.root.appendingPathComponent("input.tar"))
    let output = fixture.root.appendingPathComponent("output")
    let linkContents: @Sendable () throws -> Void = {
      let staging = output.appendingPathComponent(
        try #require(FileManager.default.contentsOfDirectory(atPath: output.path).first))
      let contents = staging.appendingPathComponent(
        try #require(FileManager.default.contentsOfDirectory(atPath: staging.path).first))
      try FileManager.default.linkItem(at: contents, to: link)
    }
    let runner = ArchiveExtractionRunner(
      base: ToolEnvironment(configuration: .init()).commandRunner,
      extracting: duringExtraction ? linkContents : nil)
    let error = #expect(throws: (any Error).self) {
      try extract(fixture.root, runner: runner) { operation, _, phase in
        if !duringExtraction, operation == "archive.extract", phase == .willMutate {
          try FileGuardConcurrentAction.run(linkContents)
        }
      }
    }
    #expect(String(describing: error).contains("more than one hard link"))
    #expect(runner.calls == 3)
    #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
    #expect(try Data(contentsOf: link) == Data(payload.utf8))
    var info = stat()
    try #require(lstat(link.path, &info) == 0)
    #expect(info.st_nlink == 1)
  }

  @Test(arguments: [
    "unlisted", "symlink", "hardlink", "metadata", "missing", "type", "replacement", "failure",
  ])
  func extractedTreeMustMatchAndCleanupPreservesUnknownEntries(change: String) throws {
    let fixture = try ArchiveFixture()
    defer { fixture.remove() }
    let output = fixture.root.appendingPathComponent("output")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o750, .modificationDate: Date(timeIntervalSince1970: 1_500_000_020)],
      ofItemAtPath: output.path)
    let archive = try fixture.archive([.init(name: "member", content: "original")])
    try FileManager.default.moveItem(
      at: archive, to: fixture.root.appendingPathComponent("input.tar"))
    let runner = ArchiveExtractionRunner(
      base: ToolEnvironment(configuration: .init()).commandRunner)
    let observer: @Sendable (String, URL, ProjectFileAccess.MutationPhase) throws -> Void = {
      operation, staging, phase in
      guard operation == "archive.extract", phase == .didMutate else { return }
      runner.observeMutation()
      let member = staging.appendingPathComponent("member")
      switch change {
      case "unlisted": try Data("extra".utf8).write(to: staging.appendingPathComponent("extra"))
      case "symlink":
        try FileManager.default.createSymbolicLink(
          at: staging.appendingPathComponent("link"), withDestinationURL: member)
      case "hardlink":
        try FileManager.default.linkItem(at: member, to: staging.appendingPathComponent("link"))
      case "metadata": try Data("metadata".utf8).write(to: staging.appendingPathComponent(".git"))
      case "missing": try FileManager.default.removeItem(at: member)
      case "type":
        try FileManager.default.removeItem(at: member)
        try FileManager.default.createDirectory(at: member, withIntermediateDirectories: false)
      case "replacement":
        try FileManager.default.removeItem(at: member)
        try Data("foreign".utf8).write(to: member)
      default: throw CocoaError(.fileWriteUnknown)
      }
    }
    let error = #expect(throws: (any Error).self) {
      try extract(fixture.root, runner: runner, observer: observer)
    }
    #expect(runner.calls == 3)
    #expect(runner.observedMutation)
    var info = stat()
    try #require(lstat(output.path, &info) == 0)
    #expect(info.st_mode & 0o777 == 0o750)
    #if canImport(Darwin)
      let modified = info.st_mtimespec
    #else
      let modified = info.st_mtim
    #endif
    #expect(modified.tv_sec == 1_500_000_020 && modified.tv_nsec == 0)
    let remaining = try FileManager.default.contentsOfDirectory(atPath: output.path)
    if ["missing", "hardlink", "failure"].contains(change) {
      #expect(remaining.isEmpty)
    } else {
      let staging = output.appendingPathComponent(
        try #require(remaining.first, "\(String(describing: error))"))
      #expect(remaining.count == 1)
      #expect(String(describing: error).contains(staging.path))
      #expect(try !FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
      switch change {
      case "unlisted":
        #expect(try Data(contentsOf: staging.appendingPathComponent("extra")) == Data("extra".utf8))
      case "metadata":
        #expect(
          try Data(contentsOf: staging.appendingPathComponent(".git")) == Data("metadata".utf8))
      case "replacement":
        #expect(
          try Data(contentsOf: staging.appendingPathComponent("member")) == Data("foreign".utf8))
      case "symlink":
        #expect(
          try FileManager.default.destinationOfSymbolicLink(
            atPath: staging.appendingPathComponent("link").path)
            == staging.appendingPathComponent("member").path)
      case "type":
        var directory = ObjCBool(false)
        #expect(
          FileManager.default.fileExists(
            atPath: staging.appendingPathComponent("member").path, isDirectory: &directory))
        #expect(directory.boolValue)
      default: break
      }
    }
  }

  @Test(arguments: [false, true])
  func extractionPinsItsWorkingDirectoryWhenStagingBecomesAnOutsideSymlink(duringExtraction: Bool)
    throws
  {
    let fixture = try ArchiveFixture()
    defer { fixture.remove() }
    let outside = try ScopedTemporaryDirectory()
    let outsideURL = outside.url
    let sentinel = outsideURL.appendingPathComponent("sentinel")
    try Data("untouched".utf8).write(to: sentinel)
    let archive = try fixture.archive([
      .init(name: "member", content: String(repeating: "x", count: 1_048_576))
    ])
    try FileManager.default.moveItem(
      at: archive, to: fixture.root.appendingPathComponent("input.tar"))
    let output = fixture.root.appendingPathComponent("output")
    let replace: @Sendable () throws -> Void = {
      let name = try #require(
        FileManager.default.contentsOfDirectory(atPath: output.path).first { $0.hasSuffix(".tmp") })
      let staging = output.appendingPathComponent(name)
      try FileManager.default.moveItem(at: staging, to: output.appendingPathComponent("retained"))
      try FileManager.default.createSymbolicLink(at: staging, withDestinationURL: outsideURL)
    }
    let runner = ArchiveExtractionRunner(
      base: ToolEnvironment(configuration: .init()).commandRunner,
      extracting: duringExtraction ? replace : nil)
    let error = #expect(throws: (any Error).self) {
      try extract(fixture.root, runner: runner) { operation, _, phase in
        guard !duringExtraction, operation == "archive.extract", phase == .willMutate else {
          return
        }
        try FileGuardConcurrentAction.run(replace)
      }
    }
    #expect(runner.calls == 3)
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.url.path) == ["sentinel"])
    #expect(try Data(contentsOf: sentinel) == Data("untouched".utf8))
    let staging = try #require(
      FileManager.default.contentsOfDirectory(atPath: output.path).first { $0.hasSuffix(".tmp") })
    #expect(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: output.appendingPathComponent(staging).path) == outside.url.path)
    #expect(String(describing: error).contains(staging))
    #expect(
      try FileManager.default.contentsOfDirectory(
        atPath: output.appendingPathComponent("retained").path
      ).isEmpty)
  }

  @Test
  func publicationFailureCleansStagingInAMovedDestination() throws {
    let fixture = try ArchiveFixture()
    defer { fixture.remove() }
    let outside = try ScopedTemporaryDirectory()
    let moved = outside.url.appendingPathComponent("moved")
    let archive = try fixture.archive([.init(name: "member")])
    try FileManager.default.moveItem(
      at: archive, to: fixture.root.appendingPathComponent("input.tar"))
    let mover = FileGuardDirectoryMover(
      from: fixture.root.appendingPathComponent("output"), to: moved)
    let tools = FilesToolProvider(
      environment: ToolEnvironment(
        configuration: .init(
          builtin: .init(enabled: ["archive.extract"]), projectDirectory: fixture.root),
        builtinExecutables: ["tar": "tar"]),
      fileMutationObserver: { operation, _, phase in
        if operation == "renameatx_np", phase == .didMutate { try mover.move() }
      })
    #expect(throws: (any Error).self) {
      _ = try tools.callTool(
        .init(
          name: "archive.extract",
          arguments: .object([
            "path": .string("input.tar"), "destination": .string("output"),
            "create_directories": .bool(true), "dry_run": .bool(false),
            "confirm_extract": .bool(true),
          ]), context: .empty))
    }
    #expect(mover.didMove)
    #expect(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
  }

  @Test
  func publishedDirectoryCanHaveNoOwnerAccess() throws {
    let fixture = try ArchiveFixture()
    defer { fixture.remove() }
    let directory = fixture.root.appendingPathComponent("output/locked")
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    let archive = try fixture.archive([
      .init(name: "locked/", kind: "directory", mode: 0),
      .init(name: "locked/member", content: "archived"),
    ])
    try FileManager.default.moveItem(
      at: archive, to: fixture.root.appendingPathComponent("input.tar"))
    let runner = ArchiveExtractionRunner(
      base: ToolEnvironment(configuration: .init()).commandRunner)
    try extract(fixture.root, runner: runner)
    var info = stat()
    try #require(lstat(directory.path, &info) == 0)
    #expect(info.st_mode & 0o777 == 0)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    #expect(
      try Data(contentsOf: directory.appendingPathComponent("member")) == Data("archived".utf8))
  }

  @Test
  func largeArchivesUseConstantProcessesAndScaleWithEntries() throws {
    let fixture = try ArchiveFixture()
    defer { fixture.remove() }
    var elapsed: [Double] = []
    for count in [256, 1_024] {
      let archive = try fixture.archive(
        (0..<count).map {
          .init(name: "nested/member-\($0)", content: String(repeating: "x", count: 4_096))
        })
      let name = "input-\(count).tar"
      try FileManager.default.moveItem(at: archive, to: fixture.root.appendingPathComponent(name))
      let runner = ArchiveExtractionRunner(
        base: ToolEnvironment(configuration: .init()).commandRunner)
      let started = ContinuousClock.now
      try extract(fixture.root, runner: runner, archive: name)
      let duration = started.duration(to: .now).components
      elapsed.append(Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
      #expect(runner.calls == 3)
      #expect(
        try FileManager.default.contentsOfDirectory(
          atPath: fixture.root.appendingPathComponent("output/nested").path
        ).count == count)
      try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("output"))
    }
    print("Archive extraction 256/1024 entries: \(elapsed) seconds; three processes each")
    #expect(elapsed[1] < elapsed[0] * 6 + 2)
    #expect(elapsed[1] < 30)
  }

  @Test(arguments: ["zip", "zip-reordered", "zip-dos"])
  func zipContentsFollowTheReadersEntryOrder(format: String) throws {
    let fixture = try ArchiveFixture()
    defer { fixture.remove() }
    let archive = try fixture.archive(
      [
        .init(name: "first", content: "aa"), .init(name: "second", content: "bb"),
        .init(name: "empty", content: ""),
      ], format: format)
    try FileManager.default.moveItem(
      at: archive, to: fixture.root.appendingPathComponent("input.zip"))
    let runner = ArchiveExtractionRunner(
      base: ToolEnvironment(configuration: .init()).commandRunner)
    guard try extract(fixture.root, runner: runner, archive: "input.zip") else { return }
    let output = fixture.root.appendingPathComponent("output")
    #expect(try Data(contentsOf: output.appendingPathComponent("first")) == Data("aa".utf8))
    #expect(try Data(contentsOf: output.appendingPathComponent("second")) == Data("bb".utf8))
    #expect(try Data(contentsOf: output.appendingPathComponent("empty")).isEmpty)
    #expect(runner.calls == 3)
  }

  @Test(arguments: ["tar", "tar.gz"])
  func sparseMembersPreserveLogicalBytesBetweenOrdinaryMembers(format: String) throws {
    let fixture = try ArchiveFixture()
    defer { fixture.remove() }
    let archive = try fixture.archive(
      [
        .init(name: "first", content: "before"), .init(name: "sparse", kind: "sparse"),
        .init(name: "tail", kind: "sparse-tail"), .init(name: "last", content: "after"),
      ], format: format)
    let name = "input." + format
    try FileManager.default.moveItem(at: archive, to: fixture.root.appendingPathComponent(name))
    let runner = ArchiveExtractionRunner(
      base: ToolEnvironment(configuration: .init()).commandRunner)
    try extract(fixture.root, runner: runner, archive: name)
    let output = fixture.root.appendingPathComponent("output")
    var sparse = Data(repeating: 0, count: 2_048)
    sparse[0] = 120
    sparse[2_047] = 120
    var tail = Data(repeating: 0, count: 1_024)
    tail[0] = 120
    #expect(try Data(contentsOf: output.appendingPathComponent("first")) == Data("before".utf8))
    #expect(try Data(contentsOf: output.appendingPathComponent("sparse")) == sparse)
    #expect(try Data(contentsOf: output.appendingPathComponent("tail")) == tail)
    #expect(try Data(contentsOf: output.appendingPathComponent("last")) == Data("after".utf8))
    #expect(runner.calls == 3)
  }

  @Test(arguments: ["tar", "tar.gz", "zip"])
  func escapedListingNamesPreserveTheirOriginalBytes(format: String) throws {
    let fixture = try ArchiveFixture()
    defer { fixture.remove() }
    let names =
      ["café.txt", "中文.txt", "tab\tname", "line\nname", " leading", "trailing "]
      + (format == "zip" ? [] : ["back\\slash", "\\056git"])
    let archive = try fixture.archive(
      names.enumerated().map {
        .init(
          name: $0.element, content: String($0.offset), modificationSeconds: 1_009_843_203,
          modificationNanoseconds: format != "zip" && $0.offset == 0 ? 123_456_789 : 0)
      }, format: format
    )
    let name = "input." + format
    try FileManager.default.moveItem(at: archive, to: fixture.root.appendingPathComponent(name))
    let runner = ArchiveExtractionRunner(
      base: ToolEnvironment(configuration: .init()).commandRunner)
    guard try extract(fixture.root, runner: runner, archive: name) else { return }
    let output = fixture.root.appendingPathComponent("output")
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: output.path)) == Set(names))
    for (index, name) in names.enumerated() {
      #expect(try Data(contentsOf: output.appendingPathComponent(name)) == Data(String(index).utf8))
    }
    #expect(runner.calls == 3)
  }
}

private final class ArchiveExtractionRunner: CommandRunning, @unchecked Sendable {
  let base: any CommandRunning
  let extracting: (@Sendable () throws -> Void)?
  private let lock = NSLock()
  private var count = 0
  private var mutationObserved = false
  var observedMutation: Bool { lock.withLock { mutationObserved } }

  func observeMutation() { lock.withLock { mutationObserved = true } }
  var calls: Int { lock.withLock { count } }

  init(base: any CommandRunning, extracting: (@Sendable () throws -> Void)? = nil) {
    self.base = base
    self.extracting = extracting
  }

  func run(
    executable: String, arguments: [String], workingDirectory: URL?, environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult {
    lock.withLock { count += 1 }
    let result = try base.run(
      executable: executable, arguments: arguments, workingDirectory: workingDirectory,
      environment: environment, timeoutMilliseconds: timeoutMilliseconds,
      maxOutputBytes: maxOutputBytes)
    return result
  }

  func runInDirectory(
    executable: String, arguments: [String], directoryDescriptor: Int32,
    inputDescriptor: Int32, outputDescriptor: Int32, environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult {
    lock.withLock { count += 1 }
    #expect(!arguments.contains("-P"))
    #expect(arguments.contains("--no-same-owner"))
    #expect(arguments.contains("--no-same-permissions"))
    #expect(arguments.prefix(2) == ["-xOf", "-"])
    if let extracting {
      let pipe = Pipe()
      let writer = pipe.fileHandleForWriting
      let feeder = FileGuardConcurrentAction {
        defer { try? writer.close() }
        let input = FileHandle(fileDescriptor: inputDescriptor, closeOnDealloc: false)
        // Tar produces stdout, then blocks on the remaining archive while the
        // worker replaces staging. This proves the process is already extracting.
        let initial = try input.read(upToCount: 16_384)
        try writer.write(contentsOf: try #require(initial))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var status = stat()
        while fstat(outputDescriptor, &status) == 0, status.st_size == 0,
          ContinuousClock.now < deadline
        {
          Thread.sleep(forTimeInterval: 0.001)
        }
        try #require(status.st_size > 0)
        try extracting()
        while let data = try input.read(upToCount: 65_536), !data.isEmpty {
          try writer.write(contentsOf: data)
        }
      }
      let result = Result {
        try base.runInDirectory(
          executable: executable, arguments: arguments, directoryDescriptor: directoryDescriptor,
          inputDescriptor: pipe.fileHandleForReading.fileDescriptor,
          outputDescriptor: outputDescriptor,
          environment: environment, timeoutMilliseconds: timeoutMilliseconds,
          maxOutputBytes: maxOutputBytes)
      }
      try feeder.wait()
      return try result.get()
    }
    return try base.runInDirectory(
      executable: executable, arguments: arguments, directoryDescriptor: directoryDescriptor,
      inputDescriptor: inputDescriptor, outputDescriptor: outputDescriptor,
      environment: environment,
      timeoutMilliseconds: timeoutMilliseconds, maxOutputBytes: maxOutputBytes)
  }

  func runData(
    executable: String, arguments: [String], workingDirectory: URL?, environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandDataResult {
    try base.runData(
      executable: executable, arguments: arguments, workingDirectory: workingDirectory,
      environment: environment, timeoutMilliseconds: timeoutMilliseconds,
      maxOutputBytes: maxOutputBytes)
  }
}
