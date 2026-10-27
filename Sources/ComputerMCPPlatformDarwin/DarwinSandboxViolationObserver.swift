import ComputerMCPSandbox
import Darwin
import Foundation

/// Observing a denial can only suggest a retry. Missing logs or uncertain membership produce nothing.
final class DarwinSandboxViolationObserver: @unchecked Sendable {
  // Bounds collection after kernel ownership ends, independently of the
  // permission store's window after the complete execution is retained.
  static let completedReportWindow: TimeInterval = 5
  private let lock = NSLock()
  private let stream: DarwinSandboxViolationStream
  private var ledger: DarwinSandboxViolationLedger
  private var marker: ExecutionSandboxMarker?
  private var root: (identity: DarwinProcessIdentity, admittedAt: UInt64)?
  private var handler: (@Sendable (ExecutionSandboxViolation) -> Void)?
  private var subscription: UUID?
  private var finished = false
  private var receiving = false

  init?(
    marker: ExecutionSandboxMarker,
    handler: @escaping @Sendable (ExecutionSandboxViolation) -> Void
  ) {
    let stream = DarwinSandboxViolationStream.shared
    guard let bootID = stream.bootID else { return nil }
    self.stream = stream
    self.ledger = .init(bootID: bootID)
    self.marker = marker
    self.handler = handler
    subscription = stream.subscribe { [weak self] report in self?.offer(report) }
  }

  func admitRoot(_ identity: DarwinProcessIdentity) {
    let admittedAt = mach_continuous_time()
    lock.withLock { root = (identity, admittedAt) }
    observeRoot()
  }

  /// Called before the launch backend reaps the root, so a delayed record can still use the
  /// confirmed PID-generation interval. A missing sample leaves the previous interval intact.
  func observeRoot() {
    guard let root = lock.withLock({ finished ? nil : self.root }),
      let sample = DarwinViolationProcessSample.read(root.identity.pid),
      sample.identity == root.identity
    else { return }
    lock.withLock {
      guard !finished else { return }
      ledger.admit(sample, at: root.admittedAt)
      ledger.observe(sample)
    }
  }

  func finish() {
    let schedule = lock.withLock {
      guard !finished else { return false }
      finished = true
      marker = nil
      return true
    }
    guard schedule else { return }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.completedReportWindow) {
      self.stop()
    }
  }

  private func offer(_ report: DarwinSandboxViolationReport) {
    let accepted = lock.withLock {
      guard handler != nil, !receiving else { return false }
      receiving = true
      return true
    }
    guard accepted else { return }
    // A libproc query can wait for an exec transition. One in-flight attribution per
    // execution bounds work without blocking the log reader or another execution's launch.
    DispatchQueue.global(qos: .utility).async {
      self.receive(report)
      self.lock.withLock { self.receiving = false }
    }
  }

  private func receive(_ report: DarwinSandboxViolationReport) {
    let state = lock.withLock { (finished, root, marker) }
    if !state.0, let sample = DarwinViolationProcessSample.read(report.processID) {
      if let root = state.1, sample.identity == root.identity {
        lock.withLock {
          guard !finished else { return }
          ledger.admit(sample, at: root.admittedAt)
          ledger.observe(sample)
        }
      } else if lock.withLock({ ledger.contains(sample) }) {
        lock.withLock {
          guard !finished else { return }
          ledger.observe(sample)
        }
      } else if let marker = state.2, (try? marker.contains(report.processID)) == true,
        let confirmed = DarwinViolationProcessSample.read(report.processID),
        sample.identity == confirmed.identity,
        sample.kernelStartTime == confirmed.kernelStartTime
      {
        // The kernel marker proves current membership; it does not prove when an unobserved
        // child joined. Only records emitted after this admission can use that membership.
        lock.withLock {
          guard !finished else { return }
          ledger.admit(confirmed, at: confirmed.observedAt)
        }
      }
    }
    let callback = lock.withLock { ledger.attributes(report) ? handler : nil }
    callback?(report.violation)
  }

  private func stop() {
    let subscription = lock.withLock {
      let subscription = self.subscription
      self.subscription = nil
      handler = nil
      return subscription
    }
    if let subscription { stream.unsubscribe(subscription) }
  }

  deinit {
    if let subscription { stream.unsubscribe(subscription) }
  }
}

/// The sole input is stdout of the fixed system log reader, with a clean environment. The
/// predicate reduces traffic; authentication still checks each record's kernel sender metadata.
private final class DarwinSandboxViolationStream: @unchecked Sendable {
  static let shared = DarwinSandboxViolationStream()
  let bootID = DarwinViolationProcessSample.bootID()
  private let queue = DispatchQueue(label: "execution.sandbox-violations", qos: .utility)
  private var subscribers: [UUID: @Sendable (DarwinSandboxViolationReport) -> Void] = [:]
  private var process: Process?
  private var source: (any DispatchSourceRead)?
  private var framer = DarwinSandboxViolationFramer()
  private var startedAt: UInt64 = 0
  private var resetAt: UInt64 = 0
  private var emitted = 0

  func subscribe(_ handler: @escaping @Sendable (DarwinSandboxViolationReport) -> Void) -> UUID? {
    queue.sync {
      guard subscribers.count < 128 else { return nil }
      let id = UUID()
      subscribers[id] = handler
      if source == nil { start() }
      return id
    }
  }

  func unsubscribe(_ id: UUID) {
    queue.async {
      self.subscribers.removeValue(forKey: id)
      if self.subscribers.isEmpty { self.stop() }
    }
  }

  private func start() {
    guard bootID != nil, DarwinSandboxViolationClock.precise() else { return }
    let pipe = Pipe()
    let reader = pipe.fileHandleForReading
    let descriptor = reader.fileDescriptor
    guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    process.arguments = [
      "stream", "--style", "ndjson", "--level", "debug", "--predicate",
      #"processID == 0 AND senderImagePath == "/System/Library/Extensions/Sandbox.kext/Contents/MacOS/Sandbox""#,
    ]
    process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
    process.currentDirectoryURL = URL(fileURLWithPath: "/")
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = pipe.fileHandleForWriting
    process.standardError = FileHandle.nullDevice
    startedAt = mach_continuous_time()
    do { try process.run() } catch { return }
    try? pipe.fileHandleForWriting.close()
    let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
    source.setEventHandler { [weak self] in self?.drain(descriptor) }
    source.setCancelHandler { try? reader.close() }
    self.process = process
    self.source = source
    framer = DarwinSandboxViolationFramer()
    source.resume()
  }

  private func drain(_ descriptor: Int32) {
    var bytes = [UInt8](repeating: 0, count: 8192)
    for _ in 0..<16 {
      let count = read(descriptor, &bytes, bytes.count)
      if count < 0, errno == EINTR { continue }
      guard count > 0 else {
        if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK) { stop() }
        return
      }
      var lines: [Data] = []
      framer.append(Array(bytes.prefix(count))) { lines.append($0) }
      for line in lines { emit(line) }
    }
  }

  private func emit(_ line: Data) {
    guard source != nil else { return }
    let now = DispatchTime.now().uptimeNanoseconds
    if now >= resetAt {
      resetAt = now &+ 1_000_000_000
      emitted = 0
    }
    guard emitted < 256, let bootID,
      let report = DarwinSandboxViolationReport.parse(line, streamBootID: bootID),
      report.timestamp >= startedAt, report.timestamp <= mach_continuous_time()
    else { return }
    guard DarwinSandboxViolationClock.precise() else {
      stop()
      return
    }
    emitted += 1
    for handler in subscribers.values { handler(report) }
  }

  private func stop() {
    source?.cancel()
    source = nil
    if let process, process.isRunning { process.terminate() }
    process = nil
    framer = DarwinSandboxViolationFramer()
  }
}
