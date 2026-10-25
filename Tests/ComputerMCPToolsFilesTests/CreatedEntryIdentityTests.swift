import ComputerMCPConfiguration
import ComputerMCPCore
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
struct CreatedEntryIdentityTests {
  @Test
  func cleanupRejectsReusedInodeWithDifferentBirthNanoseconds() throws {
    let temporary = try ScopedTemporaryDirectory()
    var replaced = false
    // Model allocator reuse deterministically: only the regular file's inode is
    // reused, while its birth time differs by one nanosecond in the same second.
    let files = try ProjectFileAccess(
      project: temporary.url,
      identityReader: { fd in
        var identity = try ProjectFileAccess.createdIdentity(fd)
        var value = stat()
        try #require(fstat(fd, &value) == 0)
        if value.st_mode & S_IFMT == S_IFREG {
          identity.inode = 42
          identity.birthTime = .init(seconds: 123, nanoseconds: replaced ? 2 : 1)
        }
        return identity
      })
    var replacement: URL?
    var treeRejected = false
    let error = #expect(throws: (any Error).self) {
      try files.withStagingDirectory(in: temporary.url) { staging, _ in
        let file = staging.appendingPathComponent("member")
        replacement = file
        try files.write(Data("owned".utf8), to: file)
        try FileManager.default.removeItem(at: file)
        replaced = true
        try Data("foreign".utf8).write(to: file)
        do { _ = try files.tree(staging) } catch { treeRejected = true }
      }
    }
    #expect(treeRejected)
    let file = try #require(replacement)
    #expect(String(describing: error).contains(file.path))
    #expect(try Data(contentsOf: file) == Data("foreign".utf8))
  }

  @Test
  func fallbackBudgetStopsCreationAndCleansStaging() async {
    await #expect(processExitsWith: .success) {
      try Self.limitDescriptors(to: 192)
      let temporary = try ScopedTemporaryDirectory()
      let files = try ProjectFileAccess(
        project: temporary.url,
        identityReader: { fd in
          var identity = try ProjectFileAccess.createdIdentity(fd)
          identity.birthTime = nil
          return identity
        })
      var completed = 0
      let error = #expect(throws: (any Error).self) {
        try files.withStagingDirectory(in: temporary.url) { staging, _ in
          for index in 0..<1_000 {
            try files.write(
              Data("entry".utf8), to: staging.appendingPathComponent("entry-\(index)"))
            completed += 1
          }
        }
      }
      try #require(completed == ProjectFileAccess.fallbackDescriptorLimit - 1)
      try #require(String(describing: error).contains("descriptor limit (64)"))
      try #require(FileManager.default.contentsOfDirectory(atPath: temporary.url.path).isEmpty)
    }
  }

  @Test(arguments: [false, true])
  func failedMetadataRollbackPreservesBirthTime(postCheck: Bool) throws {
    let temporary = try ScopedTemporaryDirectory()
    let files = try ProjectFileAccess(
      project: temporary.url,
      mutationObserver: { operation, _, phase in
        if postCheck, operation == "metadata", phase == .didMutate { throw POSIXError(.EIO) }
      })
    try files.withStagingDirectory(in: temporary.url) { staging, _ in
      let file = staging.appendingPathComponent("member")
      try files.write(Data("owned".utf8), to: file)
      try files.setArchiveMetadata(file, seconds: 946_684_801, nanoseconds: 123)
      #expect(throws: (any Error).self) {
        try files.withDescriptor(file) { _ in
          if !postCheck { throw POSIXError(.EIO) }
        }
      }
      #expect(try files.tree(staging) == ["member": false])
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.url.path).isEmpty)
  }

  @Test
  func cleanupPreservesForeignFIFOWithoutBlocking() async {
    await #expect(processExitsWith: .success) {
      // Bound a blocking-open regression in the child without affecting other tests.
      alarm(10)
      defer { alarm(0) }
      let temporary = try ScopedTemporaryDirectory()
      let files = try ProjectFileAccess(project: temporary.url)
      var foreign: URL?
      let error = #expect(throws: (any Error).self) {
        try files.withStagingDirectory(in: temporary.url) { staging, _ in
          let fifo = staging.appendingPathComponent("foreign")
          try #require(mkfifo(fifo.path, 0o600) == 0)
          foreign = fifo
        }
      }
      let fifo = try #require(foreign)
      try #require(String(describing: error).contains(fifo.path))
      var value = stat()
      try #require(lstat(fifo.path, &value) == 0)
      try #require(value.st_mode & S_IFMT == S_IFIFO)
    }
  }

  @Test
  func creationRollbackDoesNotBlockOnFIFOReplacement() async {
    await #expect(processExitsWith: .success) {
      alarm(10)
      defer { alarm(0) }
      let temporary = try ScopedTemporaryDirectory()
      var replacement: URL?
      let files = try ProjectFileAccess(
        project: temporary.url,
        mutationObserver: { operation, _, phase in
          guard operation == "openat", phase == .didMutate else { return }
          let name = try #require(
            FileManager.default.contentsOfDirectory(atPath: temporary.url.path).first)
          let fifo = temporary.url.appendingPathComponent(name)
          try FileManager.default.removeItem(at: fifo)
          try #require(mkfifo(fifo.path, 0o600) == 0)
          replacement = fifo
          throw POSIXError(.EIO)
        })
      #expect(throws: (any Error).self) {
        try files.write(Data("owned".utf8), to: temporary.url.appendingPathComponent("output"))
      }
      let fifo = try #require(replacement)
      var value = stat()
      try #require(lstat(fifo.path, &value) == 0)
      try #require(value.st_mode & S_IFMT == S_IFIFO)
    }
  }

  @Test
  func identityReadFailureCleansTheAnchoredCreation() throws {
    let temporary = try ScopedTemporaryDirectory()
    let files = try ProjectFileAccess(
      project: temporary.url,
      identityReader: { _ in
        throw POSIXError(.EIO)
      })
    #expect(throws: (any Error).self) {
      try files.write(Data("entry".utf8), to: temporary.url.appendingPathComponent("output"))
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.url.path).isEmpty)
  }

  @Test
  func recursiveCopyThousandsOfEntriesWithLowDescriptorLimit() async {
    await #expect(processExitsWith: .success) {
      try Self.limitDescriptors(to: 96)
      let temporary = try ScopedTemporaryDirectory()
      let source = temporary.url.appendingPathComponent("source")
      try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
      for index in 0..<2_048 {
        try Data("entry-\(index)".utf8).write(to: source.appendingPathComponent("entry-\(index)"))
      }
      let tools = FilesToolProvider(
        environment: ToolEnvironment(
          configuration: .init(
            builtin: .init(enabled: ["file.copy"]), projectDirectory: temporary.url)))
      _ = try tools.callTool(
        .init(
          name: "file.copy",
          arguments: .object([
            "source": .string("source"), "destination": .string("output"),
          ]), context: .empty))
      let output = temporary.url.appendingPathComponent("output")
      try #require(FileManager.default.contentsOfDirectory(atPath: output.path).count == 2_048)
      for index in 0..<2_048 {
        try #require(
          Data(contentsOf: output.appendingPathComponent("entry-\(index)"))
            == Data("entry-\(index)".utf8))
      }
      try #require(
        Set(FileManager.default.contentsOfDirectory(atPath: temporary.url.path)) == [
          "source", "output",
        ])
    }
  }

  private static func limitDescriptors(to count: rlim_t) throws {
    #if canImport(Darwin)
      let resource = RLIMIT_NOFILE
    #else
      let resource = Int32(RLIMIT_NOFILE.rawValue)
    #endif
    var limits = rlimit()
    try #require(getrlimit(resource, &limits) == 0)
    limits.rlim_cur = min(count, limits.rlim_max)
    try #require(setrlimit(resource, &limits) == 0)
  }
}
