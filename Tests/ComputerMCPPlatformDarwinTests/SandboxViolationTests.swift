import ComputerMCPSandbox
import Darwin
import Foundation
import Testing

@testable import ComputerMCPPlatformDarwin

@Suite struct SandboxViolationTests {
  @Test(arguments: [
    "file-read-data", "file-read-metadata", "file-read-xattr", "file-write-create",
    "file-write-unlink",
  ])
  func kernelRecordUsesOffenderPIDAndPreservesPath(operation: String) throws {
    let path = "/Users/example/Downloads/a file (77) deny(1) file-read-data /other"
    let report = try #require(
      DarwinSandboxViolationReport.parse(
        encoded(["eventMessage": "Sandbox: My Program(42) deny(1) \(operation) \(path)"]),
        streamBootID: "BOOT"))
    #expect(report.processID == 42)
    #expect(report.bootID == "boot")
    #expect(report.timestamp == 150)
    #expect(report.violation == .init(operation: operation, path: path))
  }

  @Test func kernelSenderMetadataIsRequired() throws {
    let cases: [[String: Any]] = [
      ["processID": 42],
      ["processImagePath": "/tmp/kernel"],
      ["senderImagePath": "/tmp/Sandbox"],
      ["senderImagePath": "/System/Library/Extensions/Sandbox.kext/Contents/MacOS/Sandbox/other"],
      ["eventType": "activityCreateEvent"],
      ["bootUUID": "different-boot"],
      ["machTimestamp": 0],
    ]
    for overrides in cases {
      #expect(
        DarwinSandboxViolationReport.parse(try encoded(overrides), streamBootID: "boot") == nil)
    }
    #expect(
      DarwinSandboxViolationReport.parse(
        Data("Sandbox: tool(42) deny(1) file-read-data /Users/example/Downloads/file".utf8),
        streamBootID: "boot") == nil)
  }

  @Test func ambiguousUnsupportedAndRedactedMessagesProduceNothing() throws {
    for message in [
      "Sandbox: tool(42) deny(0) file-read-data /Users/example/Downloads/file",
      "Sandbox: tool(0) deny(1) file-read-data /Users/example/Downloads/file",
      "Sandbox: tool(42) deny(1) file-read-data relative/file",
      "Sandbox: tool(42) deny(1) file-read-data /Users/<private>/file",
      "Sandbox: tool(42) deny(1) file-read-data /Users/example/line\nfile",
      "Sandbox: tool(42) deny(1) file-map-executable /Users/example/Downloads/file",
      "Sandbox: tool(777) odd(42) deny(1) file-read-data /Users/example/Downloads/file",
      "Sandbox: tool(42) deny(1) network-outbound 127.0.0.1:80",
    ] {
      #expect(
        DarwinSandboxViolationReport.parse(
          try encoded(["eventMessage": message]), streamBootID: "boot") == nil)
    }
  }

  @Test func launchAdmissionAndKernelConfirmationBoundAttribution() {
    var ledger = DarwinSandboxViolationLedger(bootID: "boot")
    ledger.admit(sample(start: 50, observed: 100), at: 100)
    #expect(!ledger.attributes(report(at: 99)))
    #expect(ledger.attributes(report(at: 100)))
    #expect(!ledger.attributes(report(at: 150)))
    ledger.observe(sample(start: 50, observed: 160))
    #expect(ledger.attributes(report(at: 150)))
    #expect(!ledger.attributes(report(at: 161)))
    #expect(!ledger.attributes(report(at: 150, boot: "other")))
    #expect(!ledger.attributes(report(at: 150, pid: 77)))
  }

  @Test func exitedMembersRetainTheirHistoricalInterval() {
    var ledger = DarwinSandboxViolationLedger(bootID: "boot")
    ledger.admit(sample(start: 50, observed: 100), at: 100)
    ledger.observe(sample(start: 50, observed: 190, exited: true))
    #expect(ledger.attributes(report(at: 179)))
    #expect(ledger.attributes(report(at: 190)))
    #expect(!ledger.attributes(report(at: 191)))
    ledger.observe(sample(start: 50, observed: 300))
    #expect(!ledger.attributes(report(at: 200)))
  }

  @Test func kernelIdentityAndContinuousClockBoundsRemainSeparate() {
    var ledger = DarwinSandboxViolationLedger(bootID: "boot")
    // A sleep offset separates kernel absolute start time from continuous log timestamps.
    ledger.admit(sample(start: 50, observed: 10_100), at: 10_100)
    ledger.observe(sample(start: 50, observed: 10_200))
    #expect(ledger.attributes(report(at: 10_150)))
    #expect(!ledger.attributes(report(at: 150)))
    #expect(!ledger.attributes(report(at: 10_201)))
  }

  @Test func reusedPIDCannotExtendTheOldMemberOrConsumeItsDelayedReport() {
    var ledger = DarwinSandboxViolationLedger(bootID: "boot")
    ledger.admit(sample(start: 50, observed: 100), at: 100)
    ledger.observe(sample(start: 50, observed: 150))
    ledger.observe(sample(start: 200, observed: 250, member: 2))
    #expect(ledger.attributes(report(at: 125)))
    #expect(!ledger.attributes(report(at: 175)))
    #expect(!ledger.attributes(report(at: 225)))
    ledger.admit(sample(start: 200, observed: 250, member: 2), at: 210)
    #expect(ledger.attributes(report(at: 125)))
    #expect(ledger.attributes(report(at: 225)))
    #expect(!ledger.attributes(report(at: 205)))
  }

  @Test func independentMemberIdentityAndUnambiguousIntervalsAreRequired() {
    var ledger = DarwinSandboxViolationLedger(bootID: "boot")
    ledger.admit(sample(start: 50, observed: 100), at: 100)
    ledger.observe(sample(start: 50, observed: 200, member: 2))
    #expect(!ledger.attributes(report(at: 150)))
    ledger.observe(sample(start: 50, observed: 200))
    ledger.admit(sample(start: 120, observed: 200, member: 2), at: 130)
    #expect(!ledger.attributes(report(at: 150)))
  }

  @Test func newlyProvenDescendantDoesNotRetroactivelyOwnReports() {
    var ledger = DarwinSandboxViolationLedger(bootID: "boot")
    ledger.admit(sample(start: 50, observed: 160, pid: 77), at: 160)
    #expect(!ledger.attributes(report(at: 150, pid: 77)))
    ledger.observe(sample(start: 50, observed: 180, pid: 77))
    #expect(ledger.attributes(report(at: 170, pid: 77)))
  }

  @Test func ledgerAndInputRetentionAreBounded() {
    var ledger = DarwinSandboxViolationLedger(bootID: "boot", limit: 1)
    ledger.admit(sample(start: 50, observed: 100), at: 100)
    ledger.admit(sample(start: 50, observed: 100, pid: 77), at: 100)
    #expect(!ledger.attributes(report(at: 100, pid: 77)))
    var framer = DarwinSandboxViolationFramer()
    var lines: [Data] = []
    framer.append([UInt8](repeating: 65, count: 70_000)) { lines.append($0) }
    #expect(lines.isEmpty)
    framer.append(Array("\nfirst\npar".utf8)) { lines.append($0) }
    framer.append(Array("tial\n".utf8)) { lines.append($0) }
    #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["first", "partial"])
  }

  @Test func absentOrIncompleteReportsProduceNothing() {
    var framer = DarwinSandboxViolationFramer()
    var lines: [Data] = []
    framer.append([]) { lines.append($0) }
    framer.append(Array("incomplete diagnostic".utf8)) { lines.append($0) }
    #expect(lines.isEmpty)
    #expect(!DarwinSandboxViolationLedger(bootID: "boot").attributes(report(at: 150)))
  }

  @Test func uncertainOrApproximateClockModeIsRejected() {
    #expect(DarwinSandboxViolationClock.precise(flags: 1))
    #expect(!DarwinSandboxViolationClock.precise(flags: nil))
    #expect(!DarwinSandboxViolationClock.precise(flags: 0x80))
    #expect(!DarwinSandboxViolationClock.precise(flags: 0x81))
  }

  @Test func kernelSampleUsesStableIdentityAndKernelStartTime() throws {
    let before = try #require(DarwinProcessIdentity.current(pid: getpid()))
    let sample = try #require(DarwinViolationProcessSample.read(getpid()))
    #expect(sample.identity == before.identity)
    #expect(sample.kernelStartTime > 0)
    #expect(sample.kernelStartTime <= mach_absolute_time())
    #expect(sample.observedAt <= mach_continuous_time())
    #expect(!sample.hasExited)
    #expect(DarwinViolationProcessSample.bootID()?.isEmpty == false)
  }

  @Test func exitedRootSampleRemainsAvailableUntilReaped() throws {
    let arguments = [strdup("/usr/bin/true"), nil]
    defer { free(arguments[0]) }
    var pid: pid_t = 0
    try #require(posix_spawn(&pid, "/usr/bin/true", nil, nil, arguments, [nil]) == 0)
    defer {
      var status: Int32 = 0
      var reaped: pid_t
      repeat { reaped = waitpid(pid, &status, 0) } while reaped < 0 && errno == EINTR
    }
    var terminal = siginfo_t()
    var observed: Int32
    repeat {
      observed = waitid(P_PID, id_t(pid), &terminal, WEXITED | WNOWAIT)
    } while observed < 0 && errno == EINTR
    try #require(observed == 0 && terminal.si_code == CLD_EXITED)
    let sample = try #require(DarwinViolationProcessSample.read(pid))
    #expect(sample.hasExited)
    #expect(sample.kernelStartTime > 0)
    #expect(sample.identity.pid == pid)
  }

  private func encoded(_ overrides: [String: Any] = [:]) throws -> Data {
    var fields: [String: Any] = [
      "processID": 0, "processImagePath": "/kernel",
      "senderImagePath": "/System/Library/Extensions/Sandbox.kext/Contents/MacOS/Sandbox",
      "eventType": "logEvent", "machTimestamp": 150, "bootUUID": "",
      "eventMessage": "Sandbox: tool(42) deny(1) file-read-data /Users/example/Downloads/file",
    ]
    fields.merge(overrides) { _, new in new }
    return try JSONSerialization.data(withJSONObject: fields)
  }

  private func sample(
    start: UInt64, observed: UInt64, exited: Bool = false, pid: pid_t = 42, member: UInt64 = 1
  ) -> DarwinViolationProcessSample {
    .init(
      identity: .init(pid: pid, uniqueID: member), kernelStartTime: start,
      observedAt: observed, hasExited: exited)
  }

  private func report(at timestamp: UInt64, boot: String = "boot", pid: pid_t = 42)
    -> DarwinSandboxViolationReport
  {
    .init(
      bootID: boot, timestamp: timestamp, processID: pid,
      violation: .init(operation: "file-read-data", path: "/Users/example/Downloads/file"))
  }
}
