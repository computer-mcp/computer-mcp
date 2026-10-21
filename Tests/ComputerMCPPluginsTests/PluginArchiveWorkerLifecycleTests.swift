import ComputerMCPPlatform
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPPlugins

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

@Suite(.nativeIntegration, .timeLimit(.minutes(1)))
struct PluginArchiveWorkerLifecycleTests {
  @Test(arguments: [false, true], [false, true])
  func outputLimitsAreInclusiveAndOverflowReapsWorker(stderr: Bool, overflow: Bool) async throws {
    let fixture = try await PreparationFixture.make(directoryFactory: WorkerDirectoryFactory())
    defer { fixture.files.remove() }
    let report = fixture.files.root.appendingPathComponent("pid")
    let limit = stderr ? 4_096 : 16_384
    let worker = try await fixture.stub(
      """
      import os, signal, sys, time
      signal.alarm(15)
      signal.signal(signal.SIGTERM, signal.SIG_IGN)
      with open(\(try fixture.literal(report.path)), 'w') as f: f.write(str(os.getpid()))
      failure = '"invalid_archive"'
      sys.stdout.write(failure)
      sys.stdout.flush()
      stream = sys.\(stderr ? "stderr" : "stdout")
      stream.write(' ' * (\(limit + (overflow ? 1 : 0)) - \(stderr ? 0 : 17)))
      stream.flush()
      \(overflow ? "time.sleep(30)" : "sys.exit(1)")
      """)
    await #expect(throws: overflow ? PluginArchiveError.workerFailed : .invalidArchive) {
      try await fixture.prepare(worker: worker) { _, _ in Issue.record("Worker reached activation.")
      }
    }
    let pid = try #require(Int32(String(contentsOf: report, encoding: .utf8)))
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
    #expect(try fixture.stagingContents().isEmpty)
    #expect(FileManager.default.fileExists(atPath: fixture.archive.path))
  }

  @Test(arguments: [false, true])
  func cancellationAndTimeoutJoinWorkerBeforeDiscard(cancel: Bool) async throws {
    let fixture = try await PreparationFixture.make(directoryFactory: WorkerDirectoryFactory())
    defer { fixture.files.remove() }
    let report = fixture.files.root.appendingPathComponent("pid")
    let worker = try await fixture.stub(
      """
      import os, signal, time
      signal.alarm(15)
      signal.signal(signal.SIGTERM, signal.SIG_IGN)
      os.mkdir('partial')
      with open(\(try fixture.literal(report.path)), 'w') as f: f.write(str(os.getpid()))
      time.sleep(30)
      """)
    let task = Task {
      try await fixture.prepare(worker: worker, timeout: cancel ? .seconds(10) : .seconds(2)) {
        _, _ in Issue.record("Incomplete worker reached activation.")
      }
    }
    let deadline = ContinuousClock.now + .seconds(5)
    while !FileManager.default.fileExists(atPath: report.path), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    if cancel {
      task.cancel()
      await #expect(throws: CancellationError.self) { try await task.value }
    } else {
      await #expect(throws: PluginArchiveError.timedOut) { try await task.value }
    }
    let pid = try #require(Int32(String(contentsOf: report, encoding: .utf8)))
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
    #expect(try fixture.stagingContents().isEmpty)
  }

  @Test
  func explicitInheritanceBorrowsDescriptorAndPreservesCallerFlags() async throws {
    let fixture = try await PreparationFixture.make(directoryFactory: WorkerDirectoryFactory())
    defer { fixture.files.remove() }
    let descriptor = open(fixture.archive.path, O_RDONLY | O_CLOEXEC)
    try #require(descriptor >= 0)
    defer { close(descriptor) }
    let borrowed = fcntl(descriptor, F_DUPFD_CLOEXEC, 256)
    try #require(borrowed >= 256)
    defer { close(borrowed) }
    let flags = fcntl(borrowed, F_GETFD)
    let worker = try await fixture.stub(
      """
      import os, sys
      assert os.fstat(0).st_ino == os.fstat(\(borrowed)).st_ino
      print('"invalid_archive"')
      sys.exit(1)
      """)
    var preparation = PluginArchivePreparation(
      workerExecutable: worker, stagingParent: fixture.staging,
      directoryFactory: WorkerDirectoryFactory())
    preparation.inheritedLockDescriptor = borrowed
    #if canImport(Darwin)
      let expected = PluginArchiveError.invalidArchive
    #else
      let expected = PluginArchiveError.workerFailed
    #endif
    await #expect(throws: expected) {
      try await preparation.withPreparedPackage(
        archive: fixture.archive, expectedSHA256: fixture.digest, pluginID: "combined",
        version: PluginVersion("1.2.3"), hostVersion: PluginVersion("1.0.0"), architecture: "arm64"
      ) { _, _ in Issue.record("Invalid archive reached activation.") }
    }
    #expect(fcntl(borrowed, F_GETFD) == flags)
    var byte: UInt8 = 0
    #expect(read(borrowed, &byte, 1) == 1)
    #expect(try fixture.stagingContents().isEmpty)
  }
}

/// Worker failures exercise creation and discard without invoking a platform archive extractor.
private struct WorkerDirectoryFactory: PluginArchiveDirectoryFactory {
  func create(at url: URL) throws -> any PluginArchiveStagingDirectory {
    try WorkerDirectory(url: url)
  }

  func recover(_ identity: PluginDirectoryIdentity) throws -> any PluginArchiveStagingDirectory {
    throw PluginArchiveError.workerFailed
  }

  func identity(url: URL, status: stat, descriptor: Int32) throws -> PluginDirectoryIdentity {
    throw PluginArchiveError.workerFailed
  }

  func matches(_ identity: PluginDirectoryIdentity, status: stat, descriptor: Int32) throws -> Bool
  {
    throw PluginArchiveError.workerFailed
  }

  func renameExclusively(
    from source: String, in sourceDirectory: Int32,
    to destination: String, in destinationDirectory: Int32
  ) throws {
    throw PluginArchiveError.workerFailed
  }
}

private final class WorkerDirectory: PluginArchiveStagingDirectory {
  let url: URL
  let descriptor: Int32

  init(url: URL) throws {
    self.url = url
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    try #require(descriptor >= 0)
  }

  deinit { close(descriptor) }

  func createDirectory(_ parts: [String]) throws { throw PluginArchiveError.workerFailed }
  func createFile(
    _ parts: [String], executable: Bool, readOnly: Bool, write: (Int32) throws -> Void
  ) throws { throw PluginArchiveError.workerFailed }
  func finish() throws { throw PluginArchiveError.workerFailed }
  func identity() throws -> PluginDirectoryIdentity { throw PluginArchiveError.workerFailed }
  func removeStaging() throws { throw PluginArchiveError.workerFailed }
  func discard() throws { try FileManager.default.removeItem(at: url) }
}
