import CodexAppServerRuntime
import Darwin
import Foundation
import Subprocess
import System

struct CodexAppServerProcessSnapshot: Codable, Equatable, Sendable {
  enum State: String, Codable, Equatable, Sendable {
    case starting
    case running
    case stopping
    case stopped
    case failed
  }

  let state: State
  let processID: Int32?
  let supervisorProcessID: Int32?
  let parentProcessID: Int32
  let processGroupID: Int32?
  let startedAt: Date?
  let stoppedAt: Date?
  let exitCode: Int32?
  let signal: Int32?
  let terminationEscalated: Bool
  let lastError: String?

  private enum CodingKeys: String, CodingKey {
    case state
    case processID = "process_id"
    case supervisorProcessID = "supervisor_process_id"
    case parentProcessID = "parent_process_id"
    case processGroupID = "process_group_id"
    case startedAt = "started_at"
    case stoppedAt = "stopped_at"
    case exitCode = "exit_code"
    case signal
    case terminationEscalated = "termination_escalated"
    case lastError = "last_error"
  }

  var json: JSONValue {
    (try? JSONValue.encoded(self)) ?? .object([:])
  }
}

enum CodexAppServerProcessTransportError: Error, LocalizedError, Sendable {
  case closed
  case launchFailed(String)
  case oversizedMessage(Int)
  case terminationTimedOut(processID: Int32?)

  var errorDescription: String? {
    switch self {
    case .closed:
      return "The Computer MCP-owned Codex App Server transport is closed."
    case .launchFailed(let message):
      return "Could not launch the Computer MCP-owned Codex App Server: \(message)"
    case .oversizedMessage(let limit):
      return "Codex App Server emitted a protocol line larger than \(limit) bytes."
    case .terminationTimedOut(let processID):
      return
        "Codex App Server process \(processID.map(String.init) ?? "unknown") did not exit after SIGKILL."
    }
  }
}

/// A Computer MCP-owned App Server transport with observable, bounded process-group teardown.
final class ManagedCodexAppServerTransport: CodexAppServerLinePeer, @unchecked Sendable {
  struct Configuration: Sendable {
    var executable: String
    var arguments: [String]
    var environment: [String: String]
    var workingDirectory: URL
    var terminationGraceMilliseconds: Int
    var killGraceMilliseconds: Int
    var maximumMessageBytes: Int
    var ownerProcessID: Int32

    init(
      executable: String,
      arguments: [String] = ["app-server", "--listen", "stdio://"],
      environment: [String: String] = ProcessInfo.processInfo.environment,
      workingDirectory: URL,
      terminationGraceMilliseconds: Int = 1_000,
      killGraceMilliseconds: Int = 2_000,
      maximumMessageBytes: Int = 16 * 1_024 * 1_024,
      ownerProcessID: Int32 = getpid()
    ) {
      self.executable = executable
      self.arguments = arguments
      self.environment = environment
      self.workingDirectory = workingDirectory.standardizedFileURL
      self.terminationGraceMilliseconds = max(0, terminationGraceMilliseconds)
      self.killGraceMilliseconds = max(1, killGraceMilliseconds)
      self.maximumMessageBytes = max(1, maximumMessageBytes)
      self.ownerProcessID = ownerProcessID
    }
  }

  let inboundLines: AsyncThrowingStream<String, Error>

  private let configuration: Configuration
  private let state: ManagedCodexAppServerProcessState
  private let launchTask: Task<Void, Never>
  private let closeLock = NSLock()
  private var closeTask: Task<Void, Never>?

  init(configuration: Configuration) {
    self.configuration = configuration
    let streamAndContinuation = AsyncThrowingStream<String, Error>.makeStream()
    self.inboundLines = streamAndContinuation.stream
    let state = ManagedCodexAppServerProcessState(
      continuation: streamAndContinuation.continuation,
      maximumMessageBytes: configuration.maximumMessageBytes,
      ownerProcessID: configuration.ownerProcessID
    )
    self.state = state
    self.launchTask = Task.detached(priority: .userInitiated) {
      await Self.launch(configuration: configuration, state: state)
    }
  }

  func sendLine(_ line: String) async throws {
    try await state.send(line: line)
  }

  func close() async {
    let task = closeLock.withLock { () -> Task<Void, Never> in
      if let closeTask {
        return closeTask
      }
      let task = Task { [weak self] in
        if let self {
          await self.performClose()
        }
      }
      closeTask = task
      return task
    }
    await task.value
  }

  private func performClose() async {
    let handles = await state.beginShutdown()
    if let writer = handles.writer {
      Task {
        try? await writer.finish()
      }
    }

    // Start EOF delivery without waiting for a back-pressured pipe writer. The
    // bounded process wait and signal escalation below remain authoritative.
    if await waitForExit(milliseconds: configuration.terminationGraceMilliseconds) {
      await launchTask.value
      return
    }

    if !(await state.signalAppServerGroup(SIGTERM)), let execution = handles.execution {
      try? execution.send(signal: .terminate, toProcessGroup: true)
    }
    if await waitForExit(milliseconds: configuration.terminationGraceMilliseconds) {
      await launchTask.value
      return
    }

    if let execution = await state.runningExecution() {
      await state.recordTerminationEscalation()
      if !(await state.signalAppServerGroup(SIGKILL)) {
        try? execution.send(signal: .kill, toProcessGroup: true)
      }
    }

    if !(await waitForExit(milliseconds: configuration.killGraceMilliseconds)) {
      await state.failTerminationTimeout()
      return
    }
    await launchTask.value
  }

  func snapshot() async -> CodexAppServerProcessSnapshot {
    await state.snapshot()
  }

  private func waitForExit(milliseconds: Int) async -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(max(0, milliseconds))
    repeat {
      if await state.hasFinished() {
        return true
      }
      if ContinuousClock.now >= deadline {
        return false
      }
      try? await Task.sleep(for: .milliseconds(10))
    } while true
  }

  private static func launch(
    configuration: Configuration,
    state: ManagedCodexAppServerProcessState
  ) async {
    var supervisorDirectory: URL?
    do {
      let environment = Dictionary(
        uniqueKeysWithValues: configuration.environment.compactMap { key, value in
          Subprocess.Environment.Key(rawValue: key).map { ($0, value) }
        }
      )
      let supervisor = try makeSupervisor(configuration: configuration)
      supervisorDirectory = supervisor.directory
      let executable: Executable = .path(FilePath("/bin/sh"))
      var platformOptions = PlatformOptions()
      platformOptions.processGroupID = 0
      let standardOutput = try FileDescriptor.pipe()
      let outputReader = ManagedCodexAppServerOutputReader(
        readEnd: standardOutput.readEnd,
        state: state
      )
      outputReader.start()
      do {
        let outcome = try await Subprocess.run(
          executable,
          arguments: Arguments(supervisor.arguments),
          environment: .custom(environment),
          workingDirectory: FilePath(configuration.workingDirectory.path),
          platformOptions: platformOptions,
          output: FileDescriptorOutput.fileDescriptor(
            standardOutput.writeEnd,
            closeAfterSpawningProcess: true
          )
        ) { execution, inputWriter, stderr in
          let stopImmediately = await state.attach(
            execution: execution,
            inputWriter: inputWriter
          )
          guard let processID = await waitForProcessID(at: supervisor.processIDFile) else {
            try? execution.send(signal: .kill, toProcessGroup: true)
            throw CodexAppServerProcessTransportError.launchFailed(
              "The process supervisor did not report the App Server PID."
            )
          }
          await state.attachAppServer(processID: processID)
          if stopImmediately {
            try? await inputWriter.finish()
            try? execution.send(signal: .terminate, toProcessGroup: true)
          }
          do {
            for try await _ in stderr {}
          } catch {
            await state.recordStreamError(error)
          }
        }
        await outputReader.stop(drainRemainingOutput: true)
        await state.finish(status: outcome.terminationStatus)
      } catch {
        await outputReader.stop(drainRemainingOutput: false)
        throw error
      }
    } catch {
      await state.failLaunch(error)
    }
    if let supervisorDirectory {
      try? FileManager.default.removeItem(at: supervisorDirectory)
    }
  }

  private struct SupervisorLaunch {
    let directory: URL
    let processIDFile: URL
    let arguments: [String]
  }

  private static func makeSupervisor(
    configuration: Configuration
  ) throws -> SupervisorLaunch {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("computer-mcp-codex-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
    )
    let script = directory.appendingPathComponent("supervisor.sh")
    let processIDFile = directory.appendingPathComponent("app-server.pid")
    try Data(
      """
      #!/bin/sh
      set -m
      pid_file=$1
      owner_pid=$2
      grace_seconds=$3
      shift 3

      "$@" <&0 >&1 2>&2 &
      child=$!
      exec 0<&-
      printf '%s\n' "$child" > "$pid_file"
      (
        trap '' HUP INT TERM
        while /bin/kill -0 "$owner_pid" 2>/dev/null; do
          /bin/sleep 0.1
        done
        /bin/kill -TERM -- -"$child" 2>/dev/null || true
        /bin/sleep "$grace_seconds"
        /bin/kill -KILL -- -"$child" 2>/dev/null || true
      ) &
      watchdog=$!

      cleanup() {
        trap - EXIT HUP INT TERM
        /bin/kill -TERM -- -"$child" 2>/dev/null || true
        /bin/sleep "$grace_seconds"
        /bin/kill -KILL -- -"$child" 2>/dev/null || true
        /bin/kill -KILL "$watchdog" 2>/dev/null || true
        wait "$child" 2>/dev/null || true
        wait "$watchdog" 2>/dev/null || true
      }
      trap cleanup EXIT HUP INT TERM

      wait "$child"
      status=$?
      /bin/kill -KILL "$watchdog" 2>/dev/null || true
      wait "$watchdog" 2>/dev/null || true
      trap - EXIT HUP INT TERM
      exit "$status"
      """.utf8
    ).write(to: script, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o700))],
      ofItemAtPath: script.path
    )
    let grace = max(0.1, Double(configuration.terminationGraceMilliseconds) / 1_000)
    return SupervisorLaunch(
      directory: directory,
      processIDFile: processIDFile,
      arguments: [
        script.path,
        processIDFile.path,
        String(configuration.ownerProcessID),
        String(format: "%.3f", grace),
        configuration.executable,
      ] + configuration.arguments
    )
  }

  private static func waitForProcessID(at file: URL) async -> Int32? {
    for _ in 0..<500 {
      if let text = try? String(contentsOf: file, encoding: .utf8),
        let processID = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
      {
        return processID
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return nil
  }

}

/// Reads partial stdout chunks so newline-delimited responses do not wait for EOF.
private final class ManagedCodexAppServerOutputReader: @unchecked Sendable {
  private let handle: FileHandle
  private let state: ManagedCodexAppServerProcessState
  private let lock = NSLock()
  private var stopped = false
  private var consumptionTask: Task<Void, Never>?

  init(
    readEnd: FileDescriptor,
    state: ManagedCodexAppServerProcessState
  ) {
    self.handle = FileHandle(fileDescriptor: readEnd.rawValue, closeOnDealloc: true)
    self.state = state
  }

  func start() {
    arm()
  }

  func stop(drainRemainingOutput: Bool) async {
    let task = lock.withLock { () -> Task<Void, Never>? in
      if !stopped {
        stopped = true
        handle.readabilityHandler = nil
        if drainRemainingOutput {
          while true {
            let data = handle.availableData
            guard !data.isEmpty else { break }
            enqueueLocked(data)
          }
        }
        try? handle.close()
      }
      return consumptionTask
    }
    await task?.value
  }

  private func arm() {
    lock.withLock {
      guard !stopped else { return }
      handle.readabilityHandler = { [weak self] handle in
        self?.consumeAvailableData(from: handle)
      }
    }
  }

  private func consumeAvailableData(from handle: FileHandle) {
    lock.withLock {
      guard !stopped else { return }
      handle.readabilityHandler = nil
      let data = handle.availableData
      guard !data.isEmpty else {
        stopped = true
        try? handle.close()
        return
      }
      enqueueLocked(data)
    }
  }

  private func enqueueLocked(_ data: Data) {
    let previous = consumptionTask
    consumptionTask = Task { [weak self, state] in
      await previous?.value
      do {
        try await state.appendStandardOutput(data)
        self?.arm()
      } catch {
        await state.recordStreamError(error)
        self?.stopProducing()
      }
    }
  }

  private func stopProducing() {
    lock.withLock {
      guard !stopped else { return }
      stopped = true
      handle.readabilityHandler = nil
      try? handle.close()
    }
  }
}

private struct ManagedCodexAppServerShutdownHandles: Sendable {
  var execution: Execution?
  var writer: StandardInputWriter?
}

private actor ManagedCodexAppServerProcessState {
  private let continuation: AsyncThrowingStream<String, Error>.Continuation
  private let maximumMessageBytes: Int
  private let ownerProcessID: Int32
  private var state: CodexAppServerProcessSnapshot.State = .starting
  private var execution: Execution?
  private var inputWriter: StandardInputWriter?
  private var processID: Int32?
  private var supervisorProcessID: Int32?
  private var startedAt: Date?
  private var stoppedAt: Date?
  private var exitCode: Int32?
  private var signal: Int32?
  private var terminationEscalated = false
  private var lastError: String?
  private var outputBuffer = Data()
  private var shutdownRequested = false
  private var readyWaiters: [CheckedContinuation<Void, Error>] = []

  init(
    continuation: AsyncThrowingStream<String, Error>.Continuation,
    maximumMessageBytes: Int,
    ownerProcessID: Int32
  ) {
    self.continuation = continuation
    self.maximumMessageBytes = maximumMessageBytes
    self.ownerProcessID = ownerProcessID
  }

  func attach(execution: Execution, inputWriter: StandardInputWriter) -> Bool {
    self.execution = execution
    self.inputWriter = inputWriter
    supervisorProcessID = Int32(execution.processIdentifier.value)
    startedAt = Date()
    if shutdownRequested {
      state = .stopping
      failReadyWaiters(CodexAppServerProcessTransportError.closed)
      return true
    }
    return false
  }

  func attachAppServer(processID: Int32) {
    self.processID = processID
    guard !shutdownRequested else { return }
    state = .running
    let waiters = readyWaiters
    readyWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  func send(line: String) async throws {
    try await waitUntilReady()
    guard state == .running, let inputWriter else {
      throw CodexAppServerProcessTransportError.closed
    }
    guard line.utf8.count <= maximumMessageBytes else {
      throw CodexAppServerProcessTransportError.oversizedMessage(maximumMessageBytes)
    }
    _ = try await inputWriter.write(Array((line + "\n").utf8))
  }

  func appendStandardOutput(_ data: Data) throws {
    guard !data.isEmpty else { return }
    outputBuffer.append(data)
    guard outputBuffer.count <= maximumMessageBytes || outputBuffer.contains(0x0A) else {
      let error = CodexAppServerProcessTransportError.oversizedMessage(maximumMessageBytes)
      continuation.finish(throwing: error)
      throw error
    }

    while let newline = outputBuffer.firstIndex(of: 0x0A) {
      var line = outputBuffer[..<newline]
      if line.last == 0x0D {
        line = line.dropLast()
      }
      outputBuffer.removeSubrange(...newline)
      guard line.count <= maximumMessageBytes else {
        let error = CodexAppServerProcessTransportError.oversizedMessage(maximumMessageBytes)
        continuation.finish(throwing: error)
        throw error
      }
      guard let text = String(data: line, encoding: .utf8) else {
        let error = CodexAppServerProcessTransportError.launchFailed(
          "App Server stdout was not valid UTF-8."
        )
        continuation.finish(throwing: error)
        throw error
      }
      continuation.yield(text)
    }
  }

  func beginShutdown() -> ManagedCodexAppServerShutdownHandles {
    shutdownRequested = true
    if state == .starting || state == .running {
      state = .stopping
    }
    if state == .starting {
      failReadyWaiters(CodexAppServerProcessTransportError.closed)
    }
    return .init(execution: execution, writer: inputWriter)
  }

  func runningExecution() -> Execution? {
    guard !hasFinished() else { return nil }
    return execution
  }

  func signalAppServerGroup(_ signal: Int32) -> Bool {
    guard let processID, processID > 1 else { return false }
    return Darwin.kill(-processID, signal) == 0 || errno == ESRCH
  }

  func recordTerminationEscalation() {
    terminationEscalated = true
  }

  func recordStreamError(_ error: Error) {
    guard state != .stopped else { return }
    lastError = Self.safeMessage(error.localizedDescription)
  }

  func finish(status: TerminationStatus) {
    switch status {
    case .exited(let code):
      exitCode = code
    case .signaled(let code):
      signal = code
    }
    inputWriter = nil
    execution = nil
    stoppedAt = Date()
    if state != .failed {
      state = .stopped
    }
    failReadyWaiters(CodexAppServerProcessTransportError.closed)
    continuation.finish()
  }

  func failLaunch(_ error: Error) {
    guard !hasFinished() else { return }
    state = .failed
    lastError = Self.safeMessage(error.localizedDescription)
    stoppedAt = Date()
    inputWriter = nil
    execution = nil
    let launchError = CodexAppServerProcessTransportError.launchFailed(
      Self.safeMessage(error.localizedDescription)
    )
    failReadyWaiters(launchError)
    continuation.finish(throwing: launchError)
  }

  func failTerminationTimeout() {
    guard !hasFinished() else { return }
    state = .failed
    let error = CodexAppServerProcessTransportError.terminationTimedOut(processID: processID)
    lastError = Self.safeMessage(error.localizedDescription)
    stoppedAt = Date()
    failReadyWaiters(error)
    continuation.finish(throwing: error)
  }

  func hasFinished() -> Bool {
    (state == .stopped || state == .failed) && execution == nil
  }

  func snapshot() -> CodexAppServerProcessSnapshot {
    CodexAppServerProcessSnapshot(
      state: state,
      processID: processID,
      supervisorProcessID: supervisorProcessID,
      parentProcessID: ownerProcessID,
      processGroupID: processID,
      startedAt: startedAt,
      stoppedAt: stoppedAt,
      exitCode: exitCode,
      signal: signal,
      terminationEscalated: terminationEscalated,
      lastError: lastError
    )
  }

  private func waitUntilReady() async throws {
    switch state {
    case .running:
      return
    case .starting:
      try await withCheckedThrowingContinuation { continuation in
        readyWaiters.append(continuation)
      }
    case .stopping, .stopped:
      throw CodexAppServerProcessTransportError.closed
    case .failed:
      throw CodexAppServerProcessTransportError.launchFailed(
        lastError ?? "Unknown launch failure."
      )
    }
  }

  private func failReadyWaiters(_ error: Error) {
    let waiters = readyWaiters
    readyWaiters.removeAll()
    for waiter in waiters {
      waiter.resume(throwing: error)
    }
  }

  private static func safeMessage(_ message: String) -> String {
    CodexApprovalRedactor.redactString(message, maximumCharacters: 2_048)
  }
}
