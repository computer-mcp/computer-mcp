import ComputerMCPCore
import ComputerMCPPlatformPOSIX
import ComputerMCPSandbox
import Foundation
import NIOConcurrencyHelpers

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

package struct ManagedLineProcessSnapshot: Codable, Equatable, Sendable {
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
  package let exitCode: Int32?
  package let signal: Int32?
  let terminationEscalated: Bool
  let pendingWrites: Int
  package let hasExited: Bool
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

package enum ManagedLineProcessError: Error, LocalizedError, Sendable {
  case closed
  case invalidConfiguration
  case bufferOverflow
  case launchFailed(String)
  case oversizedMessage(Int)
  case unterminatedOutput
  case terminationTimedOut(processID: Int32?)

  package var errorDescription: String? {
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
    case .unterminatedOutput:
      return "Managed process stdout ended within a protocol line."
    case .terminationTimedOut(let processID):
      return
        "Managed process \(processID.map(String.init) ?? "unknown") did not exit after SIGKILL."
    }
  }
}

/// Owns one process generation. The lock protects closeTask; all process state is actor-owned.
/// Stream readers and descriptor input own their I/O locks; no host process is adopted.
package final class ManagedLineProcess: @unchecked Sendable {
  private let prepared: PreparedExecutionContext?

  package struct Configuration: Sendable {
    var executable: String
    var arguments: [String]
    var environment: [String: String]
    /// Host-selected protocol provenance, separate from the command environment.
    var hostProtocolMetadata: [String: String]
    var workingDirectory: URL
    var terminationGraceMilliseconds: Int
    var killGraceMilliseconds: Int
    var maximumMessageBytes: Int
    var ownerProcessID: Int32
    var closesInputOnLaunch: Bool
    var requiresCompleteOutputLines: Bool
    /// Explicit descriptors inherited only by the owned command, never its watchdog.
    var inheritedDescriptors: [Int32: FileHandle]
    /// Retained through prepared execution completion. Owner-administration
    /// supervisors and their cleanup watchdog inherit it; the vendor command does not.
    var ownershipHandle: FileHandle?

    package init(
      executable: String,
      arguments: [String] = [],
      environment: [String: String] = ProcessInfo.processInfo.environment,
      hostProtocolMetadata: [String: String] = [:],
      workingDirectory: URL,
      terminationGraceMilliseconds: Int = 1_000,
      killGraceMilliseconds: Int = 2_000,
      maximumMessageBytes: Int = 1_024 * 1_024,
      ownerProcessID: Int32 = getpid(),
      closesInputOnLaunch: Bool = false,
      requiresCompleteOutputLines: Bool = false,
      inheritedDescriptors: [Int32: FileHandle] = [:],
      ownershipHandle: FileHandle? = nil
    ) {
      self.executable = executable
      self.arguments = arguments
      self.environment = environment
      self.hostProtocolMetadata = hostProtocolMetadata
      self.workingDirectory = workingDirectory.standardizedFileURL
      self.terminationGraceMilliseconds = terminationGraceMilliseconds
      self.killGraceMilliseconds = killGraceMilliseconds
      self.maximumMessageBytes = maximumMessageBytes
      self.ownerProcessID = ownerProcessID
      self.closesInputOnLaunch = closesInputOnLaunch
      self.requiresCompleteOutputLines = requiresCompleteOutputLines
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

  package let inboundLines: AsyncThrowingStream<String, Error>

  private let configuration: Configuration
  private let state: ManagedLineProcessState
  private let launchTask: Task<Void, Never>
  private let closeLock = NSLock()
  private var closeTask: Task<Void, Never>?

  package init(launcher: ExecutionLauncher, configuration: Configuration) throws {
    try configuration.validate()
    installBrokenPipeHandler()
    // Copy while the caller still owns its descriptors. Launch and shutdown may race,
    // so asynchronous spawn must never refer to a descriptor the caller can close/reuse.
    self.prepared = try PreparedExecutionContext.current()
    if prepared?.provider != nil {
      guard configuration.inheritedDescriptors.isEmpty,
        configuration.hostProtocolMetadata["COMPUTER_MCP_HOST_FD"] == nil
      else { throw ManagedLineProcessError.invalidConfiguration }
    }
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
    self.launchTask = ExecutionTasks.start(priority: .userInitiated) { [configuration] in
      await Self.launch(launcher: launcher, configuration: configuration, state: state)
    }
  }

  package func sendLine(
    _ line: String, beforeWrite: (@Sendable () async throws -> Void)? = nil,
    onInputAuthorized: (@Sendable () -> Void)? = nil,
    onWriteCompleted: (@Sendable () -> Void)? = nil
  ) async throws {
    if let prepared {
      let checking: any ExecutionAccessChecking
      if let current = InvocationExecution.current {
        guard let authority = current as? any ExecutionAccessChecking else {
          throw ExecutionEnvironmentError.unavailable(
            "The current invocation cannot authorize input to this execution")
        }
        checking = authority
      } else {
        checking = prepared
      }
      _ = try checking.accessExecution(prepared.executionID, operation: .writeInput)
    }
    onInputAuthorized?()
    try await state.send(line: line, beforeWrite: beforeWrite, onWriteCompleted: onWriteCompleted)
  }

  package func close() async {
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
    let writing = await state.beginShutdown()
    let finishInput = Task { await state.finishInput() }

    // Wait for the exact launch to publish its identity before teardown. Owner
    // administration also waits for its supervisor's child-group publication.
    let startupDeadline = ContinuousClock.now + .seconds(35)
    while !(await state.canSignalOwnedProcess()) {
      if ContinuousClock.now >= startupDeadline {
        await state.failTerminationTimeout()
        return
      }
      try? await Task.sleep(for: .milliseconds(10))
    }

    // Idle input can deliver EOF first. A blocked writer needs termination now;
    // joining it must never delay the signal escalation that releases its I/O.
    if !writing, await waitForExit(milliseconds: configuration.terminationGraceMilliseconds) {
      await launchTask.value
      await finishInput.value
      return
    }

    if prepared != nil {
      if let execution = await state.runningExecution() { await execution.cancelAndWait() }
      guard await waitForExit(milliseconds: configuration.killGraceMilliseconds) else {
        await state.failTerminationTimeout()
        return
      }
      await launchTask.value
      await finishInput.value
      return
    }

    if !(await state.signalChildGroup(SIGTERM)), let execution = await state.runningExecution() {
      await execution.cancelAndWait()
    }
    if await waitForExit(milliseconds: configuration.terminationGraceMilliseconds) {
      await launchTask.value
      await finishInput.value
      return
    }

    if let execution = await state.runningExecution() {
      await state.recordTerminationEscalation()
      _ = await state.signalChildGroup(SIGKILL)
      // A terminated command can leave supervisor resources alive in other groups.
      // Completion requires the ownership handle to settle all recorded members.
      await execution.cancelAndWait()
    }

    if !(await waitForExit(milliseconds: configuration.killGraceMilliseconds)) {
      await state.failTerminationTimeout()
      return
    }
    await launchTask.value
    await finishInput.value
  }

  package func snapshot() async -> ManagedLineProcessSnapshot {
    await state.snapshot()
  }

  internal func inputSnapshot() async -> ChildProcessInput.Snapshot {
    await state.inputSnapshot()
  }

  internal func observeInput(_ observer: @escaping @Sendable (ChildProcessInput.Event) -> Void)
    async
  {
    await state.observeInput(observer)
  }

  internal func beforeInputWriteSettles(_ hook: @escaping @Sendable () async -> Void) async {
    await state.beforeInputWriteSettles(hook)
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
    launcher: ExecutionLauncher, configuration: Configuration,
    state: ManagedLineProcessState
  ) async {
    var supervisorDirectory: URL?
    defer {
      for handle in configuration.inheritedDescriptors.values { try? handle.close() }
      try? configuration.ownershipHandle?.close()
    }
    do {
      if await state.isShuttingDown() {
        await state.finish(status: ExecutionExit(status: 0))
        return
      }
      let prepared = try PreparedExecutionContext.current()
      let supervisor = try prepared == nil ? makeSupervisor(configuration: configuration) : nil
      supervisorDirectory = supervisor?.directory
      #if os(Linux)
        let supervisorExecutable = "/bin/bash"
      #else
        let supervisorExecutable = "/bin/sh"
      #endif
      var inheritedDescriptors = configuration.inheritedDescriptors.mapValues(\.fileDescriptor)
      if supervisor != nil, let handle = configuration.ownershipHandle {
        inheritedDescriptors[9] = handle.fileDescriptor
      }
      let standardInput = Pipe()
      let standardOutput = Pipe()
      let standardError = Pipe()
      let writer: DescriptorInputWriter?
      if configuration.closesInputOnLaunch {
        try standardInput.fileHandleForWriting.close()
        writer = nil
      } else {
        writer = try DescriptorInputWriter(handle: standardInput.fileHandleForWriting)
      }
      let outputReader = try ProcessOutputReader(
        handle: standardOutput.fileHandleForReading,
        consume: { try await state.appendStandardOutput($0) },
        onError: { await state.recordStreamError($0) })
      let errorReader = try ProcessOutputReader(
        handle: standardError.fileHandleForReading, consume: { _ in },
        onError: { await state.recordStreamError($0) })
      outputReader.start()
      errorReader.start()
      let owner = NIOLockedValueBox<(any ExecutionOwnership)?>(nil)
      let root = NIOLockedValueBox<Int32?>(nil)
      do {
        let execution = try await launcher.start(
          executable: SandboxPath(
            supervisor == nil ? configuration.executable : supervisorExecutable),
          arguments: supervisor?.arguments ?? configuration.arguments,
          directory: SandboxPath(configuration.workingDirectory.path),
          environment: ExecutionEnvironment(fullAccessVariables: configuration.environment),
          mode: .fullAccess,
          input: standardInput.fileHandleForReading.fileDescriptor,
          output: standardOutput.fileHandleForWriting.fileDescriptor,
          error: standardError.fileHandleForWriting.fileDescriptor,
          inheritedDescriptors: inheritedDescriptors,
          hostProtocolMetadata: configuration.hostProtocolMetadata,
          bindOwnership: { handle in
            owner.withLockedValue { $0 = handle }
            handle.beforeStart { member in root.withLockedValue { $0 = member.processID } }
          })
        try standardInput.fileHandleForReading.close()
        try standardOutput.fileHandleForWriting.close()
        try standardError.fileHandleForWriting.close()
        for handle in configuration.inheritedDescriptors.values { try? handle.close() }
        if supervisor != nil { try? configuration.ownershipHandle?.close() }
        await state.attach(
          execution: execution,
          supervisorProcessID: supervisor == nil ? nil : root.withLockedValue { $0 },
          inputWriter: writer)
        let processID: Int32?
        if let supervisor {
          processID = await waitForProcessID(at: supervisor.processIDFile)
        } else {
          processID = root.withLockedValue { $0 }
        }
        guard let processID else {
          throw ManagedLineProcessError.launchFailed(
            "The owned launch did not report its process identity.")
        }
        await state.attachChild(processID: processID)
        if await state.isShuttingDown() {
          if prepared != nil {
            await execution.cancelAndWait()
          } else {
            _ = await state.signalChildGroup(SIGTERM)
          }
        }
        let outcome = try await execution.waitForExit()
        writer?.cancel()
        await state.finishInput()
        await state.inputBodyReturning()
        await outputReader.stop(drainRemainingOutput: true)
        await errorReader.stop(drainRemainingOutput: true)
        await state.finish(
          status: outcome, requiresCompleteOutputLines: configuration.requiresCompleteOutputLines)
      } catch {
        writer?.cancel()
        if let execution = owner.withLockedValue({ $0 }) { await execution.cancelAndWait() }
        try? standardInput.fileHandleForReading.close()
        try? standardOutput.fileHandleForWriting.close()
        try? standardError.fileHandleForWriting.close()
        await state.finishInput()
        try? await writer?.finish()
        await state.inputBodyReturning()
        await outputReader.stop(drainRemainingOutput: false)
        await errorReader.stop(drainRemainingOutput: false)
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
      grace_seconds=$3
      shift 3

      child=
      watchdog=
      timer=
      cleanup_timer() {
        if [ -n "$timer" ]; then
          kill -KILL "$timer" 2>/dev/null || true
          wait "$timer" 2>/dev/null || true
          timer=
        fi
      }
      terminate_group() {
        kill -TERM -- -"$child" 2>/dev/null || true
        # One owned timer measures elapsed grace independently of polling cost.
        /bin/sleep "$grace_seconds" \(configuration.ownershipHandle == nil ? "" : "9>&-") &
        timer=$!
        while kill -0 -- -"$child" 2>/dev/null; do
          if ! kill -0 "$timer" 2>/dev/null; then
            kill -KILL -- -"$child" 2>/dev/null || true
            break
          fi
          /bin/sleep 0.01 \(configuration.ownershipHandle == nil ? "" : "9>&-")
        done
        cleanup_timer
      }
      cleanup() {
        trap - EXIT HUP INT TERM
        if [ -n "$child" ]; then
          if kill -0 -- -"$child" 2>/dev/null; then
            terminate_group
          fi
          wait "$child" 2>/dev/null || true
        fi
        if [ -n "$watchdog" ]; then
          kill -CONT "$watchdog" 2>/dev/null || true
          kill -TERM "$watchdog" 2>/dev/null || true
          wait "$watchdog" 2>/dev/null || true
        fi
      }
      trap cleanup EXIT HUP INT TERM

      "$@" <&0 >&1 2>&2 \(configuration.ownershipHandle == nil ? "" : "9>&-") &
      child=$!
      # Only the command needs a separate group. Supervision helpers must stay
      # in the supervisor's owned group so cancellation also joins the watchdog.
      set +m
      exec 0<&-
      \(configuration.inheritedDescriptors.keys.sorted().map { "exec \($0)>&-" }.joined(separator: "\n"))
      if ! printf '%s\n' "$child" > "$pid_file"; then exit 1; fi
      (
        trap '' HUP INT
        trap 'cleanup_timer; exit' TERM
        while kill -0 "$owner_pid" 2>/dev/null; do
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
    let graceSeconds = Double(configuration.terminationGraceMilliseconds) / 1_000
    return SupervisorLaunch(
      directory: directory,
      processIDFile: processIDFile,
      arguments: [
        script.path,
        processIDFile.path,
        String(configuration.ownerProcessID),
        String(graceSeconds),
        configuration.executable,
      ] + configuration.arguments
    )
  }

  private static func waitForProcessID(at file: URL) async -> Int32? {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
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

private actor ManagedLineProcessState {
  private let continuation: AsyncThrowingStream<String, Error>.Continuation
  private let maximumMessageBytes: Int
  private let ownerProcessID: Int32
  private var state: ManagedLineProcessSnapshot.State = .starting
  private var execution: (any ExecutionOwnership)?
  private let input = ChildProcessInput(
    closedError: ManagedLineProcessError.closed, inputClosedError: ManagedLineProcessError.closed)
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
  private var launchFinished = false

  init(
    continuation: AsyncThrowingStream<String, Error>.Continuation,
    maximumMessageBytes: Int,
    ownerProcessID: Int32
  ) {
    self.continuation = continuation
    self.maximumMessageBytes = maximumMessageBytes
    self.ownerProcessID = ownerProcessID
  }

  func attach(
    execution: any ExecutionOwnership, supervisorProcessID: Int32?,
    inputWriter: DescriptorInputWriter?
  ) async {
    self.execution = execution
    if let inputWriter {
      await input.attach(inputWriter, ready: false)
    } else {
      await input.finish()
    }
    self.supervisorProcessID = supervisorProcessID
    startedAt = Date()
    if shutdownRequested {
      state = .stopping
      input.stop()
    }
  }

  func attachChild(processID: Int32) async {
    self.processID = processID
    guard !shutdownRequested else { return }
    state = .running
    await input.activate()
  }

  func send(
    line: String, beforeWrite: (@Sendable () async throws -> Void)?,
    onWriteCompleted: (@Sendable () -> Void)?
  ) async throws {
    try Task.checkCancellation()
    guard state == .starting || state == .running else {
      if state == .failed {
        throw ManagedLineProcessError.launchFailed(lastError ?? "Unknown launch failure.")
      }
      throw ManagedLineProcessError.closed
    }
    guard line.utf8.count <= maximumMessageBytes else {
      throw ManagedLineProcessError.oversizedMessage(maximumMessageBytes)
    }
    guard !line.contains("\n") else { throw ManagedLineProcessError.invalidConfiguration }
    _ = try await input.write(
      Data((line + "\n").utf8), close: false, beforeWrite: beforeWrite,
      onWriteCompleted: onWriteCompleted)
  }

  func inputSnapshot() -> ChildProcessInput.Snapshot { input.snapshot }

  func observeInput(_ observer: @escaping @Sendable (ChildProcessInput.Event) -> Void) async {
    await input.observe(observer)
  }

  func beforeInputWriteSettles(_ hook: @escaping @Sendable () async -> Void) async {
    await input.beforeWriteSettles(hook)
  }

  func finishInput() async { await input.finish() }

  func inputBodyReturning() async { await input.bodyReturning() }

  func appendStandardOutput(_ data: Data) throws {
    guard !data.isEmpty else { return }
    outputBuffer.append(data)
    guard outputBuffer.count <= maximumMessageBytes || outputBuffer.contains(0x0A) else {
      throw ManagedLineProcessError.oversizedMessage(maximumMessageBytes)
    }

    while let newline = outputBuffer.firstIndex(of: 0x0A) {
      var line = outputBuffer[..<newline]
      if line.last == 0x0D {
        line = line.dropLast()
      }
      outputBuffer.removeSubrange(...newline)
      guard line.count <= maximumMessageBytes else {
        throw ManagedLineProcessError.oversizedMessage(maximumMessageBytes)
      }
      guard let text = String(data: line, encoding: .utf8) else {
        throw ManagedLineProcessError.launchFailed(
          "Managed process stdout was not valid UTF-8."
        )
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

  func beginShutdown() -> Bool {
    shutdownRequested = true
    input.stop()
    if state == .starting || state == .running {
      state = .stopping
    }
    return input.snapshot.pendingWrites > 0
  }

  func runningExecution() -> (any ExecutionOwnership)? {
    guard !hasFinished() else { return nil }
    return execution
  }

  func isShuttingDown() -> Bool { shutdownRequested }

  func canSignalOwnedProcess() -> Bool { processID != nil || hasFinished() }

  func signalChildGroup(_ signal: Int32) -> Bool {
    guard let processID, processID > 1 else { return false }
    return signalProcessGroup(-processID, signal) == 0 || errno == ESRCH
  }

  func recordTerminationEscalation() {
    terminationEscalated = true
  }

  func recordStreamError(_ error: Error) {
    guard state != .stopped, lastError == nil else { return }
    lastError = Self.safeMessage(error)
    continuation.finish(throwing: error)
  }

  func finish(status: ExecutionExit, requiresCompleteOutputLines: Bool = false) {
    launchFinished = true
    exitCode = status.signal == nil ? status.status : nil
    signal = status.signal
    input.stop()
    execution = nil
    stoppedAt = Date()
    if requiresCompleteOutputLines, !outputBuffer.isEmpty {
      recordStreamError(ManagedLineProcessError.unterminatedOutput)
    }
    outputBuffer.removeAll()
    if state != .failed {
      state = .stopped
    }
    continuation.finish()
  }

  func failLaunch(_ error: Error) {
    guard !hasFinished() else { return }
    launchFinished = true
    state = .failed
    lastError = Self.safeMessage(error)
    stoppedAt = Date()
    execution = nil
    let launchError = ManagedLineProcessError.launchFailed(
      Self.safeMessage(error)
    )
    input.stop(throwing: launchError)
    continuation.finish(throwing: launchError)
  }

  func failTerminationTimeout() {
    guard !hasFinished() else { return }
    state = .failed
    let error = ManagedLineProcessError.terminationTimedOut(processID: processID)
    lastError = Self.safeMessage(error)
    stoppedAt = Date()
    input.stop(throwing: error)
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
      pendingWrites: input.snapshot.pendingWrites,
      hasExited: hasFinished(),
      lastError: lastError
    )
  }

  private static func safeMessage(_ error: Error) -> String {
    // Only the bootstrap diagnostic envelope bypasses generic I/O redaction.
    if let launch = error as? ExecutionEnvironmentError, case .bootstrapFailed = launch {
      return launch.description
    }
    // Generic I/O errors can contain argv, environment values or protocol payloads.
    guard let error = error as? ManagedLineProcessError else {
      return "Managed process I/O failed."
    }
    return error.localizedDescription
  }
}

/// `kill(2)` for a process group; the libc module name differs between platforms.
private func signalProcessGroup(_ group: pid_t, _ signal: Int32) -> Int32 {
  #if canImport(Darwin)
    Darwin.kill(group, signal)
  #else
    Glibc.kill(group, signal)
  #endif
}
