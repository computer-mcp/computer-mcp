import ComputerMCPSandbox
import Darwin
import Foundation

/// A record from the host's live unified-log reader. Caller output never enters this parser.
struct DarwinSandboxViolationReport: Sendable {
  let bootID: String
  let timestamp: UInt64
  let processID: pid_t
  let violation: ExecutionSandboxViolation

  private struct Record: Decodable {
    let processID: Int32
    let processImagePath: String
    let senderImagePath: String
    let eventType: String
    let eventMessage: String
    let machTimestamp: UInt64
    let bootUUID: String?
  }

  private static let expression = try? NSRegularExpression(
    pattern:
      #"^Sandbox: [^\x00-\x1f()/]+\(([1-9][0-9]*)\) deny\(1\) (file-(?:read|write)-[a-z-]+) (/.*)$"#
  )
  private static let operations: Set<String> = [
    "file-read-data", "file-read-metadata", "file-read-xattr",
    "file-write-create", "file-write-data", "file-write-mode", "file-write-owner",
    "file-write-flags", "file-write-xattr", "file-write-times", "file-write-unlink",
  ]

  static func parse(_ data: Data, streamBootID: String) -> Self? {
    guard !streamBootID.isEmpty, data.count <= 65_536,
      let record = try? JSONDecoder().decode(Record.self, from: data),
      record.processID == 0, record.processImagePath == "/kernel",
      record.senderImagePath == "/System/Library/Extensions/Sandbox.kext/Contents/MacOS/Sandbox",
      record.eventType == "logEvent", record.machTimestamp > 0,
      record.bootUUID.map({ $0.isEmpty || $0.lowercased() == streamBootID.lowercased() }) ?? true
    else { return nil }
    let message = record.eventMessage
    let range = NSRange(message.startIndex..., in: message)
    guard let match = expression?.firstMatch(in: message, range: range), match.range == range,
      let pidRange = Range(match.range(at: 1), in: message),
      let operationRange = Range(match.range(at: 2), in: message),
      let pathRange = Range(match.range(at: 3), in: message),
      let pid = pid_t(message[pidRange]), pid > 0
    else { return nil }
    let operation = String(message[operationRange])
    let path = String(message[pathRange])
    guard operations.contains(operation), path.utf8.count <= 4096,
      !path.contains("<private>"),
      !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    else { return nil }
    // Live log records can omit bootUUID. The host-owned reader cannot span boots, so its
    // kernel boot-session identity supplies that missing field; a conflicting UUID is rejected.
    return Self(
      bootID: streamBootID.lowercased(), timestamp: record.machTimestamp, processID: pid,
      violation: .init(operation: operation, path: path))
  }
}

enum DarwinSandboxViolationClock {
  static func precise(flags: UInt32?) -> Bool {
    flags.map { $0 & 0x80 == 0 } ?? false
  }

  static func precise() -> Bool {
    let host = mach_host_self()
    defer { _ = mach_port_deallocate(mach_task_self_, host) }
    var flags: UInt32 = 0
    guard host_get_atm_diagnostic_flag(host, &flags) == KERN_SUCCESS else { return false }
    // XNU libkern/firehose/tracepoint_private.h selects approximate timestamps for this bit.
    return precise(flags: flags)
  }
}

struct DarwinViolationProcessSample: Sendable {
  let identity: DarwinProcessIdentity
  /// Kernel process identity uses the absolute clock; ledger bounds use the continuous clock.
  let kernelStartTime: UInt64
  let observedAt: UInt64
  let hasExited: Bool

  static func read(_ pid: pid_t) -> Self? {
    let observedAt = mach_continuous_time()
    let absoluteObservedAt = mach_absolute_time()
    guard let before = DarwinProcessIdentity.current(pid: pid, includingZombies: true) else {
      return nil
    }
    var info = rusage_info_v0()
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(pid, RUSAGE_INFO_V0, $0)
      }
    }
    guard result == 0,
      let after = DarwinProcessIdentity.current(pid: pid, includingZombies: true),
      before.identity == after.identity,
      info.ri_proc_start_abstime > 0, info.ri_proc_start_abstime <= absoluteObservedAt,
      info.ri_proc_exit_abstime == 0
        || (info.ri_proc_exit_abstime >= info.ri_proc_start_abstime
          && info.ri_proc_exit_abstime <= mach_absolute_time())
    else { return nil }
    return Self(
      identity: after.identity, kernelStartTime: info.ri_proc_start_abstime,
      observedAt: observedAt,
      hasExited: info.ri_proc_exit_abstime != 0)
  }

  static func bootID() -> String? {
    var buffer = [CChar](repeating: 0, count: 128)
    var count = buffer.count
    guard sysctlbyname("kern.bootsessionuuid", &buffer, &count, nil, 0) == 0 else { return nil }
    return String(cString: buffer).lowercased()
  }
}

/// XNU firehose timestamps use mach_continuous_time; rusage process start/exit times use
/// mach_absolute_time. Start time is only an identity key. Bounds come from continuous-clock
/// admission and identity-checked samples while the PID is reserved, including unreaped zombies.
/// An already reaped exit leaves its unconfirmed tail excluded.
struct DarwinSandboxViolationLedger {
  struct Identity: Hashable {
    let bootID: String
    let processID: pid_t
    let kernelStartTime: UInt64
  }

  private struct Entry {
    let identity: Identity
    let memberID: UInt64
    let admittedAt: UInt64
    var confirmedUntil: UInt64
    var closed: Bool
  }

  let bootID: String
  let limit: Int
  private var entries: [Identity: Entry] = [:]

  init(bootID: String, limit: Int = 256) {
    self.bootID = bootID.lowercased()
    self.limit = limit
  }

  mutating func admit(_ sample: DarwinViolationProcessSample, at admittedAt: UInt64) {
    let key = key(sample)
    guard entries[key] == nil, entries.count < limit, sample.identity.pid > 0,
      sample.identity.uniqueID > 0, sample.kernelStartTime > 0,
      admittedAt > 0, admittedAt <= sample.observedAt
    else { return }
    entries[key] = Entry(
      identity: key, memberID: sample.identity.uniqueID, admittedAt: admittedAt,
      confirmedUntil: sample.observedAt, closed: sample.hasExited)
  }

  mutating func observe(_ sample: DarwinViolationProcessSample) {
    let key = key(sample)
    guard var entry = entries[key], entry.memberID == sample.identity.uniqueID,
      sample.observedAt >= entry.admittedAt, !entry.closed
    else { return }
    entry.confirmedUntil = max(entry.confirmedUntil, sample.observedAt)
    entry.closed = sample.hasExited
    entries[key] = entry
  }

  func contains(_ sample: DarwinViolationProcessSample) -> Bool {
    entries[key(sample)]?.memberID == sample.identity.uniqueID
  }

  func attributes(_ report: DarwinSandboxViolationReport) -> Bool {
    let matching = entries.values.filter {
      $0.identity.bootID == report.bootID && $0.identity.processID == report.processID
        && report.timestamp >= $0.admittedAt && report.timestamp <= $0.confirmedUntil
    }
    return matching.count == 1
  }

  private func key(_ sample: DarwinViolationProcessSample) -> Identity {
    Identity(
      bootID: bootID, processID: sample.identity.pid, kernelStartTime: sample.kernelStartTime)
  }
}

/// Oversized or incomplete lines are discarded as a unit, without retaining their contents.
struct DarwinSandboxViolationFramer {
  private var pending = Data()
  private var dropping = false

  mutating func append(_ bytes: [UInt8], emit: (Data) -> Void) {
    for byte in bytes {
      if byte == 10 {
        if !dropping && !pending.isEmpty { emit(pending) }
        pending.removeAll(keepingCapacity: true)
        dropping = false
      } else if !dropping {
        if pending.count < 65_536 {
          pending.append(byte)
        } else {
          pending.removeAll(keepingCapacity: true)
          dropping = true
        }
      }
    }
  }
}
