import CryptoKit
import Darwin
import Foundation
import Testing

@testable import ComputerMCP

@Suite(.timeLimit(.minutes(1)))
struct PluginArchivePreparationTests {
  @Test(arguments: ["tar", "tar.gz", "zip", "zip-stored"])
  func realWorkerPreparesCombinedPackageAndReclaimsItsScope(format: String) async throws {
    let fixture = try await PreparationFixture.make(format: format)
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
    let fixture = try await PreparationFixture.make(manifest: manifest)
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
        hostVersion: PluginVersion(failure == "host" ? "0.1.0" : "1.0.0"),
        architecture: failure == "architecture" ? "x86_64" : "arm64"
      ) { _, _ in Issue.record("Invalid package reached activation") }
    }
    #expect(try fixture.stagingContents().isEmpty)
    #expect(FileManager.default.fileExists(atPath: fixture.archive.path))
  }

  @Test
  func failedActivationCleansStagingAndPreservesUnrelatedFiles() async throws {
    let fixture = try await PreparationFixture.make()
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
    let fixture = try await PreparationFixture.make()
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
    let fixture = try await PreparationFixture.make()
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
    let fixture = try await PreparationFixture.make()
    defer { fixture.files.remove() }
    let report = fixture.files.root.appendingPathComponent("pid")
    let worker = try await fixture.stub(
      """
      import os, signal, time
      signal.alarm(15)
      os.mkdir('partial')
      with open(\(try fixture.literal(report.path)), 'w') as f: f.write(str(os.getpid()))
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

struct PreparationFixture: Sendable {
  let files: ArchiveFixture
  let archive: URL
  let digest: String
  let staging: URL

  static let manifest = """
    id = 'combined'
    name = 'Combined'
    version = '1.2.3'
    [compatibility]
    minimum_host = '1.0.0'
    architectures = ['arm64']
    [[mcp]]
    id = 'native'
    transport = 'stdio'
    executable = { path = 'helper' }
    [[cli]]
    id = 'commands'
    executable = { path = 'helper' }
    [[skills]]
    id = 'guide'
    path = 'skills'
    """

  static func make(manifest: String = Self.manifest, format: String = "tar") async throws -> Self {
    try await blockingFixtureIO { try Self(manifest: manifest, format: format) }
  }

  private init(manifest: String, format: String) throws {
    files = try ArchiveFixture()
    archive = try files.archive(
      [
        .init(name: PluginManifest.filename, content: manifest),
        .init(name: "helper", content: "#!/bin/sh\ntouch executed\n", mode: 0o755),
        .init(name: "skills/SKILL.md", content: "# Fixture"),
      ], format: format)
    digest = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }
      .joined()
    staging = files.root.appendingPathComponent("jobs")
    try FileManager.default.createDirectory(
      at: staging, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
  }

  var preparation: PluginArchivePreparation {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    return PluginArchivePreparation(
      workerExecutable: repository.appendingPathComponent(".build/debug/computer-mcp"),
      stagingParent: staging)
  }

  func prepare<Result: Sendable>(
    worker: URL? = nil, timeout: Duration = .seconds(60),
    operation: @Sendable (PluginPackage, PluginArchiveReceipt) async throws -> Result
  ) async throws -> Result {
    var preparation = preparation
    if let worker {
      preparation = PluginArchivePreparation(workerExecutable: worker, stagingParent: staging)
    }
    preparation.timeout = timeout
    return try await preparation.withPreparedPackage(
      archive: archive, expectedSHA256: digest, pluginID: "combined",
      version: PluginVersion("1.2.3"),
      hostVersion: PluginVersion("1.0.0"), architecture: "arm64", operation: operation)
  }

  func currentDigest() throws -> String {
    SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
  }

  func stagingContents() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: staging.path).sorted()
  }

  func literal(_ value: String) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  func stub(_ script: String) async throws -> URL {
    try await blockingFixtureIO { try writeStub(script) }
  }

  private func writeStub(_ script: String) throws -> URL {
    // Bypass Apple's /usr/bin Python launcher, which injects Xcode toolchain
    // environment variables before executing the actual interpreter.
    let lookup = Process()
    let output = Pipe()
    lookup.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    lookup.arguments = ["--find", "python3"]
    lookup.standardOutput = output
    lookup.standardError = FileHandle.nullDevice
    try lookup.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    lookup.waitUntilExit()
    try #require(lookup.terminationStatus == 0)
    let interpreter = String(decoding: data, as: UTF8.self).trimmingCharacters(
      in: .whitespacesAndNewlines)
    try #require(interpreter.hasPrefix("/") && !interpreter.contains("\n"))
    let executable = files.root.appendingPathComponent("worker")
    try Data(("#!\(interpreter)\n" + script + "\n").utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return executable
  }
}

/// Foundation Process waits used to manufacture fixtures must not occupy Swift
/// cooperative executor threads while unrelated cancellation timers need them.
private func blockingFixtureIO<Result: Sendable>(
  _ operation: @escaping @Sendable () throws -> Result
) async throws -> Result {
  try await withCheckedThrowingContinuation { continuation in
    DispatchQueue.global().async {
      continuation.resume(with: Swift.Result { try operation() })
    }
  }
}
