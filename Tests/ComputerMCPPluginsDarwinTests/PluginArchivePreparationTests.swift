import ComputerMCPPlatformDarwin
import ComputerMCPTestSupport
import CryptoKit
import Darwin
import Foundation
import Testing

@testable import ComputerMCPPlatform
@testable import ComputerMCPPlugins

@Suite(.nativeIntegration, .timeLimit(.minutes(1)))
struct PluginArchivePreparationTests {
  @Test(arguments: ["mac.zip", "intel.zip", "unknown.zip", ""])
  func archiveTargetMustPermitThisHostBeforeActivation(name: String) async throws {
    let fixture = try await PreparationFixture.make(
      directoryFactory: DarwinPluginArchiveDirectoryFactory(),
      manifest: PreparationFixture.platformManifest)
    defer { fixture.files.remove() }
    if name == "mac.zip" {
      _ = try await fixture.preparation.withPreparedPackage(
        archive: fixture.archive, expectedSHA256: fixture.digest, pluginID: "combined",
        version: PluginVersion("1.2.3"), hostVersion: PluginVersion("1.0.0"),
        architecture: "arm64", artifactName: name
      ) { package, _ in package.manifest.id }
    } else {
      await #expect(throws: PluginArchiveError.incompatiblePackage) {
        try await fixture.preparation.withPreparedPackage(
          archive: fixture.archive, expectedSHA256: fixture.digest, pluginID: "combined",
          version: PluginVersion("1.2.3"), hostVersion: PluginVersion("1.0.0"),
          architecture: "arm64", artifactName: name.isEmpty ? nil : name
        ) { _, _ in Issue.record("Incompatible archive reached activation") }
      }
    }
    #expect(try fixture.stagingContents().isEmpty)
  }

  @Test(arguments: ["tar", "tar.gz", "zip", "zip-stored"])
  func realWorkerPreparesCombinedPackageAndReclaimsItsScope(format: String) async throws {
    let fixture = try await PreparationFixture.make(
      directoryFactory: DarwinPluginArchiveDirectoryFactory(), format: format)
    defer { fixture.files.remove() }
    var before = rlimit()
    try #require(getrlimit(RLIMIT_CPU, &before) == 0)
    let result = try await fixture.prepare { package, receipt in
      #expect(package.manifest.mcp.count == 1)
      #expect(package.manifest.cli.count == 1)
      #expect(package.manifest.skills.count == 1)
      #expect(receipt.sha256 == fixture.digest)
      let archiveBytes = try Data(contentsOf: fixture.archive).count
      #expect(receipt.archiveBytes == archiveBytes)
      #expect(receipt.entries == 3)
      #expect(receipt.extractedBytes > 0)
      #expect(
        !FileManager.default.fileExists(
          atPath: package.root.deletingLastPathComponent().appendingPathComponent("input").path))
      #expect(
        !FileManager.default.fileExists(
          atPath: package.root.appendingPathComponent("executed").path))
      return package.manifest.id
    }
    #expect(result == "combined")
    #expect(try fixture.stagingContents().isEmpty)
    #expect(FileManager.default.fileExists(atPath: fixture.archive.path))
    var after = rlimit()
    try #require(getrlimit(RLIMIT_CPU, &after) == 0)
    #expect(after.rlim_cur == before.rlim_cur && after.rlim_max == before.rlim_max)
  }

  @Test(arguments: [
    "checksum", "identity", "version", "architecture", "host", "manifest", "archive",
  ])
  func validationFailuresDoNotReachActivationOrKeepPartialPackages(failure: String) async throws {
    let manifest = failure == "manifest" ? "invalid manifest" : PreparationFixture.manifest
    let fixture = try await PreparationFixture.make(
      directoryFactory: DarwinPluginArchiveDirectoryFactory(), manifest: manifest)
    defer { fixture.files.remove() }
    if failure == "archive" { try Data("invalid archive".utf8).write(to: fixture.archive) }
    let digest =
      failure == "checksum" ? String(repeating: "0", count: 64) : try fixture.currentDigest()
    let expected: PluginArchiveError =
      switch failure {
      case "checksum": .checksumMismatch
      case "identity", "version": .identityMismatch
      case "architecture", "host": .incompatiblePackage
      case "manifest": .invalidPackage
      default: .invalidArchive
      }
    await #expect(throws: expected) {
      try await fixture.preparation.withPreparedPackage(
        archive: fixture.archive, expectedSHA256: digest,
        pluginID: failure == "identity" ? "different" : "combined",
        version: PluginVersion(failure == "version" ? "2.0.0" : "1.2.3"),
        hostVersion: PluginVersion(failure == "host" ? "0.0.9" : "1.0.0"),
        architecture: failure == "architecture" ? "x86_64" : "arm64"
      ) { _, _ in Issue.record("Invalid package reached activation") }
    }
    #expect(try fixture.stagingContents().isEmpty)
    #expect(FileManager.default.fileExists(atPath: fixture.archive.path))
  }

  @Test
  func failedActivationCleansStagingAndPreservesUnrelatedFiles() async throws {
    let fixture = try await PreparationFixture.make(
      directoryFactory: DarwinPluginArchiveDirectoryFactory(), )
    defer { fixture.files.remove() }
    let sibling = fixture.staging.appendingPathComponent("user-owned")
    try Data("keep".utf8).write(to: sibling)
    await #expect(throws: PluginArchiveError.conflictingPath) {
      try await fixture.prepare { _, _ in throw PluginArchiveError.conflictingPath }
    }
    #expect(try fixture.stagingContents() == ["user-owned"])
    #expect(try String(contentsOf: sibling, encoding: .utf8) == "keep")
  }

  @Test
  func workerReceivesOnlyExplicitEnvironmentReadOnlyInputAndPrivateCWD() async throws {
    let fixture = try await PreparationFixture.make(
      directoryFactory: DarwinPluginArchiveDirectoryFactory(), )
    defer { fixture.files.remove() }
    let report = fixture.files.root.appendingPathComponent("report.json")
    let input = open(fixture.archive.path, O_RDONLY)
    defer { close(input) }
    let sentinel = fcntl(input, F_DUPFD, 256)
    try #require(sentinel >= 256)
    defer { close(sentinel) }
    let worker = try await fixture.stub(
      """
      import fcntl, json, os, stat, sys
      result = {'environment': sorted(os.environ.keys()), 'cwd': os.getcwd(),
        'read_only': fcntl.fcntl(0, fcntl.F_GETFL) & os.O_ACCMODE == os.O_RDONLY,
        'regular': stat.S_ISREG(os.fstat(0).st_mode), 'mode': stat.S_IMODE(os.stat('.').st_mode)}
      try:
        os.fstat(\(sentinel))
        result['inherited_descriptor'] = True
      except OSError:
        result['inherited_descriptor'] = False
      with open(\(try fixture.literal(report.path)), 'w') as f: json.dump(result, f)
      print('"invalid_archive"')
      sys.exit(1)
      """)
    await #expect(throws: PluginArchiveError.invalidArchive) {
      try await fixture.prepare(worker: worker) { _, _ in Issue.record("Stub reached activation") }
    }
    let values = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any])
    let environment = try #require(values["environment"] as? [String])
    // CoreFoundation synthesizes this encoding key even under env -i.
    #expect(environment.filter { $0 != "__CF_USER_TEXT_ENCODING" } == ["LANG", "PATH", "TMPDIR"])
    #expect(values["read_only"] as? Bool == true)
    #expect(values["regular"] as? Bool == true)
    #expect(values["mode"] as? Int == 0o700)
    #expect(values["inherited_descriptor"] as? Bool == false)
    #expect(fcntl(sentinel, F_GETFD) >= 0)
    let cwd = try #require(values["cwd"] as? String)
    let actualParent = URL(fileURLWithPath: cwd).deletingLastPathComponent()
      .resolvingSymlinksInPath().path
    let expectedParent = fixture.staging.resolvingSymlinksInPath().path
    #expect(actualParent == expectedParent)
    #expect(try fixture.stagingContents().isEmpty)
  }

  @Test(arguments: [
    "invalid-json", "oversized-output", "nonzero", "unknown-field", "wrong-hash", "negative-size",
  ])
  func rejectsInvalidWorkerReceipts(failure: String) async throws {
    let fixture = try await PreparationFixture.make(
      directoryFactory: DarwinPluginArchiveDirectoryFactory(), )
    defer { fixture.files.remove() }
    let worker = try await fixture.stub(
      """
      import json, sys
      failure = \(try fixture.literal(failure))
      receipt = {'sha256': sys.argv[-1], 'archive_bytes': 1, 'extracted_bytes': 1, 'entries': 1}
      if failure == 'unknown-field': receipt['extra'] = True
      if failure == 'wrong-hash': receipt['sha256'] = '0' * 64
      if failure == 'negative-size': receipt['extracted_bytes'] = -1
      if failure in ['unknown-field', 'wrong-hash', 'negative-size']: print(json.dumps(receipt))
      else: print('x' * \(failure == "oversized-output" ? 32_768 : 1))
      sys.exit(\(failure == "nonzero" ? 9 : 0))
      """)
    await #expect(throws: PluginArchiveError.workerFailed) {
      try await fixture.prepare(worker: worker) { _, _ in
        Issue.record("Invalid receipt reached activation")
      }
    }
    #expect(try fixture.stagingContents().isEmpty)
  }

  @Test(arguments: [false, true])
  func timeoutAndCancellationReapTheWorkerBeforeCleanup(cancel: Bool) async throws {
    let fixture = try await PreparationFixture.make(
      directoryFactory: DarwinPluginArchiveDirectoryFactory(), )
    defer { fixture.files.remove() }
    let report = fixture.files.root.appendingPathComponent("pid")
    let worker = try await fixture.stub(
      """
      import os, signal, time
      signal.alarm(15)
      os.mkdir('partial')
      report = \(try fixture.literal(report.path))
      with open(report + '.pending', 'w') as f: f.write(str(os.getpid()))
      os.replace(report + '.pending', report)
      time.sleep(30)
      """)
    let task = Task {
      try await fixture.prepare(worker: worker, timeout: cancel ? .seconds(10) : .seconds(2)) {
        _, _ in Issue.record("Incomplete worker reached activation")
      }
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !FileManager.default.fileExists(atPath: report.path), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    // Always join the task, including if the readiness assertion cannot be met.
    if cancel { task.cancel() }
    if cancel {
      await #expect(throws: CancellationError.self) { try await task.value }
    } else {
      await #expect(throws: PluginArchiveError.timedOut) { try await task.value }
    }
    let pid = try #require(Int32(String(contentsOf: report, encoding: .utf8)))
    errno = 0
    #expect(kill(pid, 0) == -1 && errno == ESRCH)
    #expect(try fixture.stagingContents().isEmpty)
  }
}
