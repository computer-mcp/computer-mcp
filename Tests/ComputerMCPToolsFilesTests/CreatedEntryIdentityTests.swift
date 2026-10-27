import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPToolsFiles

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import CSystemPOSIX
  import Glibc
#endif

@Suite(.nativeIntegration)
struct CreatedEntryIdentityTests {
  @Test
  func cleanupRejectsReusedInodeWithDifferentGeneration() throws {
    let temporary = try ScopedTemporaryDirectory()
    var replaced = false
    // Model allocator reuse deterministically: only the regular file's inode number is
    // reused, under a new generation, as ext4 reuses inodes within one clock tick.
    let files = try fixtureProjectFileAccess(
      project: temporary.url,
      identityReader: { fd in
        var identity = try ProjectFileAccess.createdIdentity(fd)
        var value = stat()
        try #require(fstat(fd, &value) == 0)
        if value.st_mode & S_IFMT == S_IFREG {
          identity.inode = 42
          identity.generation = .handle([1, 0, 0, 0, 42, replaced ? 2 : 1])
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
      let files = try fixtureProjectFileAccess(
        project: temporary.url,
        identityReader: { fd in
          var identity = try ProjectFileAccess.createdIdentity(fd)
          identity.generation = .unavailable
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
  func failedMetadataRollbackKeepsCreatedOwnership(postCheck: Bool) throws {
    let temporary = try ScopedTemporaryDirectory()
    let files = try fixtureProjectFileAccess(
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
  func fallbackRollbackRemovesDeepTreeAtDescriptorLimit() async {
    await #expect(processExitsWith: .success) {
      let temporary = try ScopedTemporaryDirectory()
      let files = try fixtureProjectFileAccess(
        project: temporary.url,
        identityReader: { fd in
          var identity = try ProjectFileAccess.createdIdentity(fd)
          identity.generation = .unavailable
          return identity
        })
      // Leave fewer descriptors than two per level, so rollback must rely on its reserve.
      try Self.limitDescriptors(to: rlim_t(Self.openDescriptorCount() + 150))
      let depth = ProjectFileAccess.fallbackDescriptorLimit - 4
      var created = 0
      var exhausted = false
      #expect(throws: (any Error).self) {
        try files.withStagingDirectory(in: temporary.url) { staging, _ in
          var directory = staging
          for level in 0..<depth {
            directory.appendPathComponent("level-\(level)")
            _ = try files.mkdir(directory, recursive: false)
            created += 1
          }
          try Self.exhaustDescriptors()
          exhausted = !Self.exhausted.isEmpty && dup(STDERR_FILENO) < 0
          throw POSIXError(.EIO)
        }
      }
      Self.releaseExhaustedDescriptors()
      try #require(created == depth)
      try #require(exhausted)
      try #require(FileManager.default.contentsOfDirectory(atPath: temporary.url.path).isEmpty)
    }
  }

  @Test
  func cleanupRetainsDirectoryReplacedBeforeDescending() throws {
    let temporary = try ScopedTemporaryDirectory()
    var replaced: URL?
    let files = try fixtureProjectFileAccess(
      project: temporary.url,
      mutationObserver: { operation, url, _ in
        guard operation == "descend", replaced == nil, url.lastPathComponent == "member" else {
          return
        }
        // Replace the owned directory after its identity handle closes, before the walk opens it.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try Data("foreign".utf8).write(to: url.appendingPathComponent("foreign"))
        try #require(chmod(url.path, 0o555) == 0)
        replaced = url
      })
    let error = #expect(throws: (any Error).self) {
      try files.withStagingDirectory(in: temporary.url) { staging, _ in
        let member = staging.appendingPathComponent("member")
        _ = try files.mkdir(member, recursive: false)
        try files.write(Data("owned".utf8), to: member.appendingPathComponent("owned"))
        throw POSIXError(.EIO)
      }
    }
    let directory = try #require(replaced)
    defer { _ = chmod(directory.path, 0o755) }
    #expect(String(describing: error).contains(directory.path))
    var value = stat()
    try #require(lstat(directory.path, &value) == 0)
    #expect(value.st_mode & 0o777 == 0o555)
    #expect(
      try Data(contentsOf: directory.appendingPathComponent("foreign")) == Data("foreign".utf8))
  }

  @Test
  func createdIdentityRecordsAGeneration() throws {
    let temporary = try ScopedTemporaryDirectory()
    let fd = open(temporary.url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    try #require(fd >= 0)
    defer { close(fd) }
    let identity = try ProjectFileAccess.createdIdentity(fd)
    #if canImport(Darwin)
      var volume = statfs()
      try #require(fstatfs(fd, &volume) == 0)
      let type = withUnsafeBytes(of: volume.f_fstypename) {
        String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
      }
      #expect(identity.generation == (type == "apfs" ? .stableInode : .unavailable))
    #else
      var volume = statfs()
      try #require(fstatfs(fd, &volume) == 0)
      // ext4, XFS, Btrfs and tmpfs export handles that encode the inode generation.
      let exporting: Set<Int> = [0xEF53, 0x5846_5342, 0x9123_683E, 0x0102_1994]
      guard exporting.contains(Int(volume.f_type)) else { return }
      guard case .handle(let bytes) = identity.generation else {
        Issue.record("Expected a file handle on filesystem type \(volume.f_type)")
        return
      }
      #expect(bytes.count > 4)
      #expect(try ProjectFileAccess.createdIdentity(fd).generation == identity.generation)
      let other = temporary.url.appendingPathComponent("other")
      try #require(mkdir(other.path, 0o700) == 0)
      let otherFD = open(other.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
      try #require(otherFD >= 0)
      defer { close(otherFD) }
      #expect(try ProjectFileAccess.createdIdentity(otherFD).generation != identity.generation)
    #endif
  }

  @Test
  func cleanupPreservesForeignFIFOWithoutBlocking() async {
    await #expect(processExitsWith: .success) {
      // Bound a blocking-open regression in the child without affecting other tests.
      alarm(10)
      defer { alarm(0) }
      let temporary = try ScopedTemporaryDirectory()
      let files = try fixtureProjectFileAccess(project: temporary.url)
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
      let files = try fixtureProjectFileAccess(
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
    let files = try fixtureProjectFileAccess(
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
          launcher: testExecutionLauncher(),
          configuration: .init(
            builtin: .init(enabled: ["file.copy"]), projectDirectory: temporary.url)))
      _ = try tools.callToolAsFixtureOwner(
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

  nonisolated(unsafe) private static var exhausted: [Int32] = []

  private static func openDescriptorCount() -> Int {
    (0..<Int32(4_096)).filter { fcntl($0, F_GETFD) >= 0 }.count
  }

  private static func exhaustDescriptors() throws {
    while true {
      let fd = dup(STDERR_FILENO)
      guard fd >= 0 else {
        try #require(errno == EMFILE)
        return
      }
      exhausted.append(fd)
    }
  }

  private static func releaseExhaustedDescriptors() {
    for fd in exhausted { close(fd) }
    exhausted.removeAll()
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
