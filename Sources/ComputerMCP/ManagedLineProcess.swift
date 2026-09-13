import Darwin
import Foundation
import Subprocess
import System

struct ManagedLineProcessSnapshot: Codable, Equatable, Sendable {
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
  let pendingWrites: Int
  let hasExited: Bool
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
    case pendingWrites = "pending_writes"
    case hasExited = "has_exited"
    case lastError = "last_error"
  }

}

enum ManagedLineProcessError: Error, LocalizedError, Sendable {
  case closed
  case invalidConfiguration
  case bufferOverflow
  case launchFailed(String)
  case oversizedMessage(Int)
  case terminationTimedOut(processID: Int32?)

  var errorDescription: String? {
    switch self {
    case .closed:
      return "The gateway-owned process transport is closed."
    case .invalidConfiguration:
      return "Managed process requires absolute executable/cwd paths and bounded process settings."
    case .bufferOverflow:
      return "Managed process output exceeded the bounded inbound queue."
    case .launchFailed(let message):
      return "Could not launch the gateway-owned process: \(message)"
    case .oversizedMessage(let limit):
      return "Managed process emitted a protocol line larger than \(limit) bytes."
    case .terminationTimedOut(let processID):
      return
        "Managed process \(processID.map(String.init) ?? "unknown") did not exit after SIGKILL."
    }
  }
}

/// Owns one supervisor generation. The lock protects closeTask; all process state is actor-owned.
/// Foundation's callback reader is the only other lock boundary; no host process is adopted.
final class ManagedLineProcess: @unchecked Sendable {
  struct Configuration: Sendable {
    var executable: String
    var arguments: [String]
    var environment: [String: String]
    var workingDirectory: URL
    var terminationGraceMilliseconds: Int
    var killGraceMilliseconds: Int
    var maximumMessageBytes: Int
    var ownerProcessID: Int32
    /// Explicit descriptors inherited only by the owned command, never its watchdog.
    var inheritedDescriptors: [Int32: FileHandle]
    /// Inherited by the supervisor and its cleanup watchdog, not the vendor command.
    var ownershipHandle: FileHandle?

    init(
      executable: String,
      arguments: [String] = [],
      environment: [String: String] = ProcessInfo.processInfo.environment,
      workingDirectory: URL,
      terminationGraceMilliseconds: Int = 1_000,
      killGraceMilliseconds: Int = 2_000,
      maximumMessageBytes: Int = 1_024 * 1_024,
      ownerProcessID: Int32 = getpid(),
      inheritedDescriptors: [Int32: FileHandle] = [:],
      ownershipHandle: FileHandle? = nil
    ) {
      self.executable = executable
      self.arguments = arguments
      self.environment = environment
      self.workingDirectory = workingDirectory.standardizedFileURL
      self.terminationGraceMilliseconds = terminationGraceMilliseconds
      self.killGraceMilliseconds = killGraceMilliseconds
      self.maximumMessageBytes = maximumMessageBytes
      self.ownerProcessID = ownerProcessID
      self.inheritedDescriptors = inheritedDescriptors
      self.ownershipHandle = ownershipHandle
    }

    func validate() throws {
      guard executable.hasPrefix("/"), !executable.contains("\0"),
        workingDirectory.isFileURL, workingDirectory.path.hasPrefix("/"),
        !workingDirectory.path.contains("\0"),
        arguments.allSatisfy({ !$0.contains("\0") }),
        environment.allSatisfy({
          !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0")
            && !$0.value.contains("\0")
        }),
        (0...30_000).contains(terminationGraceMilliseconds),
        (100...30_000).contains(killGraceMilliseconds),
        (1...16_777_216).contains(maximumMessageBytes), ownerProcessID > 1
      else { throw ManagedLineProcessError.invalidConfiguration }
      if let ownershipHandle {
        guard inheritedDescriptors[9] == nil,
          fcntl(ownershipHandle.fileDescriptor, F_GETFD) >= 0
        else { throw ManagedLineProcessError.invalidConfiguration }
      }
      guard
        inheritedDescriptors.allSatisfy({ destination, handle in
          (3...9).contains(destination) && fcntl(handle.fileDescriptor, F_GETFD) >= 0
        })
      else { throw ManagedLineProcessError.invalidConfiguration }
    }
  }

  let inboundLines: AsyncThrowingStream<String, Error>

  private let configuration: Configuration
  private let state: ManagedLineProcessState
  private let launchTask: Task<Void, Never>
  private let closeLock = NSLock()
  private var closeTask: Task<Void, Never>?

  init(configuration: Configuration) throws {
    try configuration.validate()
    // Copy while the caller still owns its descriptors. Launch and shutdown may race,
    // so asynchronous spawn must never refer to a descriptor the caller can close/reuse.
    var configuration = configuration
    var ownedDescriptors: [Int32: FileHandle] = [:]
    for (destination, handle) in configuration.inheritedDescriptors {
      let descriptor = fcntl(handle.fileDescriptor, F_DUPFD_CLOEXEC, 10)
      guard descriptor >= 0 else { throw ManagedLineProcessError.invalidConfiguration }
      ownedDescriptors[destination] = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    configuration.inheritedDescriptors = ownedDescriptors
    if let handle = configuration.ownershipHandle {
      let descriptor = fcntl(handle.fileDescriptor, F_DUPFD_CLOEXEC, 10)
      guard descriptor >= 0 else { throw ManagedLineProcessError.invalidConfiguration }
      configuration.ownershipHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    self.configuration = configuration
    let streamAndContinuation = AsyncThrowingStream<String, Error>.makeStream(
      bufferingPolicy: .bufferingOldest(16))
    self.inboundLines = streamAndContinuation.stream
    let state = ManagedLineProcessState(
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
    let finishInput = Task {
      try? await handles.writer?.finish()
    }

    // The child has a separate job-control group. Do not kill its supervisor before
    // it publishes that group's identity, or a concurrently spawned child could escape.
    let startupDeadline = ContinuousClock.now + .seconds(5)
    while !(await state.canSignalOwnedProcess()) {
      if ContinuousClock.now >= startupDeadline {
        await state.failTerminationTimeout()
        return
      }
      try? await Task.sleep(for: .milliseconds(10))
    }

    // Start EOF delivery without waiting for a back-pressured pipe writer. The
    // bounded process wait and signal escalation below remain authoritative.
    if await waitForExit(milliseconds: configuration.terminationGraceMilliseconds) {
      await launchTask.value
      await finishInput.value
      return
    }

    if !(await state.signalChildGroup(SIGTERM)), let execution = await state.runningExecution() {
      try? execution.send(signal: .terminate, toProcessGroup: true)
    }
    if await waitForExit(milliseconds: configuration.terminationGraceMilliseconds) {
      await launchTask.value
      await finishInput.value
      return
    }

    if let execution = await state.runningExecution() {
      await state.recordTerminationEscalation()
      if !(await state.signalChildGroup(SIGKILL)) {
        try? execution.send(signal: .kill, toProcessGroup: true)
      }
    }

    if !(await waitForExit(milliseconds: configuration.killGraceMilliseconds)) {
      await state.failTerminationTimeout()
      return
    }
    await launchTask.value
    await finishInput.value
  }

  func snapshot() async -> ManagedLineProcessSnapshot {
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
    state: ManagedLineProcessState
  ) async {
    var supervisorDirectory: URL?
    defer {
      for handle in configuration.inheritedDescriptors.values { try? handle.close() }
      try? configuration.ownershipHandle?.close()
    }
    do {
      if await state.isShuttingDown() {
        await state.finish(status: .exited(0))
        return
      }
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
      var inheritedDescriptors = configuration.inheritedDescriptors
      if let handle = configuration.ownershipHandle { inheritedDescriptors[9] = handle }
      let descriptorMappings = inheritedDescriptors.map {
        (destination: $0.key, source: $0.value.fileDescriptor)
      }.sorted { $0.destination < $1.destination }
      platformOptions.preSpawnProcessConfigurator = { _, actions in
        for mapping in descriptorMappings {
          guard posix_spawn_file_actions_adddup2(&actions, mapping.source, mapping.destination) == 0
          else { throw ManagedLineProcessError.invalidConfiguration }
        }
      }
      let standardOutput = try FileDescriptor.pipe()
      let outputReader = try ProcessOutputReader(
        handle: FileHandle(fileDescriptor: standardOutput.readEnd.rawValue, closeOnDealloc: true),
        consume: { try await state.appendStandardOutput($0) },
        onError: { await state.recordStreamError($0) }
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
          for handle in configuration.inheritedDescriptors.values { try? handle.close() }
          try? configuration.ownershipHandle?.close()
          await state.attach(
            execution: execution,
            inputWriter: inputWriter
          )
          guard let processID = await waitForProcessID(at: supervisor.processIDFile)
          else {
            try? execution.send(signal: .kill, toProcessGroup: true)
            throw ManagedLineProcessError.launchFailed(
              "The process supervisor did not report the child PID."
            )
          }
          await state.attachChild(processID: processID)
          if await state.isShuttingDown() {
            _ = await state.signalChildGroup(SIGTERM)
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
      .appendingPathComponent("computer-mcp-process-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
    )
    let script = directory.appendingPathComponent("supervisor.sh")
    let processIDFile = directory.appendingPathComponent("child.pid")
    try Data(
      """
      #!/bin/sh
      set -m
      pid_file=$1
      owner_pid=$2
      grace_ticks=$3
      shift 3

      child=
      watchdog=
      terminate_group() {
        /bin/kill -TERM -- -"$child" 2>/dev/null || true
        remaining=$grace_ticks
        while /bin/kill -0 -- -"$child" 2>/dev/null; do
          if [ "$remaining" -le 0 ]; then
            /bin/kill -KILL -- -"$child" 2>/dev/null || true
            break
          fi
          /bin/sleep 0.01 \(configuration.ownershipHandle == nil ? "" : "9>&-")
          remaining=$((remaining - 1))
        done
      }
      cleanup() {
        trap - EXIT HUP INT TERM
        if [ -n "$child" ]; then
          if /bin/kill -0 -- -"$child" 2>/dev/null; then
            terminate_group
          fi
          wait "$child" 2>/dev/null || true
        fi
        if [ -n "$watchdog" ]; then
          /bin/kill -KILL "$watchdog" 2>/dev/null || true
          wait "$watchdog" 2>/dev/null || true
        fi
      }
      trap cleanup EXIT HUP INT TERM

      "$@" <&0 >&1 2>&2 \(configuration.ownershipHandle == nil ? "" : "9>&-") &
      child=$!
      exec 0<&-
      \(configuration.inheritedDescriptors.keys.sorted().map { "exec \($0)>&-" }.joined(separator: "\n"))
      if ! printf '%s\n' "$child" > "$pid_file"; then exit 1; fi
      (
        trap '' HUP INT TERM
        while /bin/kill -0 "$owner_pid" 2>/dev/null; do
          /bin/sleep 0.1 \(configuration.ownershipHandle == nil ? "" : "9>&-")
        done
        terminate_group
      ) &
      watchdog=$!

      wait "$child"
      status=$?
      cleanup
      exit "$status"
      """.utf8
    ).write(to: script, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o700))],
      ofItemAtPath: script.path
    )
    let graceTicks = max(10, (configuration.terminationGraceMilliseconds + 9) / 10)
    return SupervisorLaunch(
      directory: directory,
      processIDFile: processIDFile,
      arguments: [
        script.path,
        processIDFile.path,
        String(configuration.ownerProcessID),
        String(graceTicks),
        configuration.executable,
      ] + configuration.arguments
    )
  }

  private static func waitForProcessID(at file: URL) async -> Int32? {
    for _ in 0..<500 {
      if Task.isCancelled { return nil }
      if let text = try? String(contentsOf: file, encoding: .utf8),
        let processID = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
      {
        return processID
      }
      do { try await Task.sleep(for: .milliseconds(10)) } catch { return nil }
    }
    return nil
  }

}

private struct ManagedLineProcessShutdownHandles: Sendable {
  var execution: Execution?
  var writer: StandardInputWriter?
}

private actor ManagedLineProcessState {
  private let continuation: AsyncThrowingStream<String, Error>.Continuation
  private let maximumMessageBytes: Int
  private let ownerProcessID: Int32
  private var state: ManagedLineProcessSnapshot.State = .starting
  private var execution: Execution?
  private var inputWriter: StandardInputWriter?
  private var processID: Int32?
  private var supervisorProcessID: Int32?
  private var startedAt: Date?
  private var stoppedAt: Date?
  private var exitCode: Int32?
  private var signal: Int32?
  private var terminationEscalated = false
  private var pendingWrites = 0
  private var lastError: String?
  private var outputBuffer = Data()
  private var shutdownRequested = false
  private var launchFinished = false
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

  func attach(execution: Execution, inputWriter: StandardInputWriter) {
    self.execution = execution
    self.inputWriter = inputWriter
    supervisorProcessID = Int32(execution.processIdentifier.value)
    startedAt = Date()
    if shutdownRequested {
      state = .stopping
      failReadyWaiters(ManagedLineProcessError.closed)
    }
  }

  func attachChild(processID: Int32) {
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
      throw ManagedLineProcessError.closed
    }
    guard line.utf8.count <= maximumMessageBytes else {
      throw ManagedLineProcessError.oversizedMessage(maximumMessageBytes)
    }
    guard !line.contains("\n") else { throw ManagedLineProcessError.invalidConfiguration }
    let frame = Data((line + "\n").utf8)
    pendingWrites += 1
    defer { pendingWrites -= 1 }
    _ = try await inputWriter.write(Array(frame))
  }

  func appendStandardOutput(_ data: Data) throws {
    guard !data.isEmpty else { return }
    outputBuffer.append(data)
    guard outputBuffer.count <= maximumMessageBytes || outputBuffer.contains(0x0A) else {
      let error = ManagedLineProcessError.oversizedMessage(maximumMessageBytes)
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
        let error = ManagedLineProcessError.oversizedMessage(maximumMessageBytes)
        continuation.finish(throwing: error)
        throw error
      }
      guard let text = String(data: line, encoding: .utf8) else {
        let error = ManagedLineProcessError.launchFailed(
          "Managed process stdout was not valid UTF-8."
        )
        continuation.finish(throwing: error)
        throw error
      }
      switch continuation.yield(text) {
      case .enqueued: break
      case .dropped: throw ManagedLineProcessError.bufferOverflow
      case .terminated: throw ManagedLineProcessError.closed
      @unknown default: throw ManagedLineProcessError.closed
      }
    }
    guard outputBuffer.count <= maximumMessageBytes else {
      throw ManagedLineProcessError.oversizedMessage(maximumMessageBytes)
    }
  }

  func beginShutdown() -> ManagedLineProcessShutdownHandles {
    shutdownRequested = true
    failReadyWaiters(ManagedLineProcessError.closed)
    if state == .starting || state == .running {
      state = .stopping
    }
    return .init(execution: execution, writer: inputWriter)
  }

  func runningExecution() -> Execution? {
    guard !hasFinished() else { return nil }
    return execution
  }

  func isShuttingDown() -> Bool { shutdownRequested }

  func canSignalOwnedProcess() -> Bool { processID != nil || hasFinished() }

  func signalChildGroup(_ signal: Int32) -> Bool {
    guard let processID, processID > 1 else { return false }
    return Darwin.kill(-processID, signal) == 0 || errno == ESRCH
  }

  func recordTerminationEscalation() {
    terminationEscalated = true
  }

  func recordStreamError(_ error: Error) {
    guard state != .stopped else { return }
    lastError = Self.safeMessage(error)
    continuation.finish(throwing: error)
  }

  func finish(status: TerminationStatus) {
    launchFinished = true
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
    failReadyWaiters(ManagedLineProcessError.closed)
    continuation.finish()
  }

  func failLaunch(_ error: Error) {
    guard !hasFinished() else { return }
    launchFinished = true
    state = .failed
    lastError = Self.safeMessage(error)
    stoppedAt = Date()
    inputWriter = nil
    execution = nil
    let launchError = ManagedLineProcessError.launchFailed(
      Self.safeMessage(error)
    )
    failReadyWaiters(launchError)
    continuation.finish(throwing: launchError)
  }

  func failTerminationTimeout() {
    guard !hasFinished() else { return }
    state = .failed
    let error = ManagedLineProcessError.terminationTimedOut(processID: processID)
    lastError = Self.safeMessage(error)
    stoppedAt = Date()
    failReadyWaiters(error)
    continuation.finish(throwing: error)
  }

  func hasFinished() -> Bool {
    launchFinished && execution == nil
  }

  func snapshot() -> ManagedLineProcessSnapshot {
    ManagedLineProcessSnapshot(
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
      pendingWrites: pendingWrites,
      hasExited: hasFinished(),
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
      throw ManagedLineProcessError.closed
    case .failed:
      throw ManagedLineProcessError.launchFailed(
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

  private static func safeMessage(_ error: Error) -> String {
    // Generic I/O errors can contain argv, environment values or protocol payloads.
    guard let error = error as? ManagedLineProcessError else {
      return "Managed process I/O failed."
    }
    return error.localizedDescription
  }
}
