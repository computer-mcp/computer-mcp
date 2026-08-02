import Darwin
import Foundation
import Subprocess
import System

internal enum ShellLaunchMode: String, Codable, Sendable {
  case shell
  case argv
}

package enum ShellStreamEncoding: String, Codable, Sendable {
  case utf8
  case base64
}

internal struct ShellLaunchRequest: Codable, Equatable, Sendable {
  internal var mode: ShellLaunchMode
  internal var command: String?
  internal var executable: String?
  internal var argv: [String]
  internal var shell: String?
  internal var workingDirectory: String?
  internal var environment: [String: String]

  internal init(
    mode: ShellLaunchMode = .shell,
    command: String? = nil,
    executable: String? = nil,
    argv: [String] = [],
    shell: String? = nil,
    workingDirectory: String? = nil,
    environment: [String: String] = [:]
  ) {
    self.mode = mode
    self.command = command
    self.executable = executable
    self.argv = argv
    self.shell = shell
    self.workingDirectory = workingDirectory
    self.environment = environment
  }

  fileprivate func resolved(defaultShell: String, defaultWorkingDirectory: URL) throws
    -> ResolvedShellLaunch
  {
    for (key, value) in environment {
      guard !key.isEmpty, !key.contains("="), !key.contains("\0"), !value.contains("\0") else {
        throw ShellRuntimeError.invalidRequest("Environment contains an invalid key or value.")
      }
    }

    let directory: URL
    if let workingDirectory {
      guard !workingDirectory.isEmpty, !workingDirectory.contains("\0") else {
        throw ShellRuntimeError.invalidRequest("cwd must not be empty or contain NUL.")
      }
      if workingDirectory.hasPrefix("/") {
        directory = URL(fileURLWithPath: workingDirectory)
      } else {
        directory = defaultWorkingDirectory.appendingPathComponent(workingDirectory)
      }
    } else {
      directory = defaultWorkingDirectory
    }

    switch mode {
    case .shell:
      guard let command, !command.isEmpty, !command.contains("\0") else {
        throw ShellRuntimeError.invalidRequest(
          "Shell mode requires a non-empty command without NUL."
        )
      }
      let shell = shell ?? defaultShell
      guard shell.hasPrefix("/"), !shell.contains("\0") else {
        throw ShellRuntimeError.invalidRequest("shell must be an absolute executable path.")
      }
      return ResolvedShellLaunch(
        executable: shell,
        arguments: ["-lc", command],
        workingDirectory: directory.standardizedFileURL,
        environment: environment
      )

    case .argv:
      guard let executable, !executable.isEmpty, !executable.contains("\0") else {
        throw ShellRuntimeError.invalidRequest(
          "Argv mode requires a non-empty executable without NUL."
        )
      }
      guard argv.allSatisfy({ !$0.contains("\0") }) else {
        throw ShellRuntimeError.invalidRequest("argv values must not contain NUL.")
      }
      return ResolvedShellLaunch(
        executable: executable,
        arguments: argv,
        workingDirectory: directory.standardizedFileURL,
        environment: environment
      )
    }
  }
}

package struct ShellStreamRead: Codable, Equatable, Sendable {
  package var requestedCursor: Int64
  package var startCursor: Int64
  package var nextCursor: Int64
  package var endCursor: Int64
  package var missedBytes: Bool
  package var truncated: Bool
  package var encoding: ShellStreamEncoding
  package var text: String?
  package var base64: String?

  private enum CodingKeys: String, CodingKey {
    case requestedCursor = "requested_cursor"
    case startCursor = "start_cursor"
    case nextCursor = "next_cursor"
    case endCursor = "end_cursor"
    case missedBytes = "missed_bytes"
    case truncated
    case encoding
    case text
    case base64
  }
}

package struct ShellSessionSnapshot: Codable, Equatable, Sendable {
  package var sessionID: String
  package var processID: Int32?
  package var isRunning: Bool
  package var exitCode: Int32?
  package var signal: Int32?
  package var timedOut: Bool
  package var cancelled: Bool
  package var startedAt: Date
  package var finishedAt: Date?
  package var launchError: String?
  package var streamErrors: [String]
  package var stdout: ShellStreamRead
  package var stderr: ShellStreamRead

  private enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case processID = "process_id"
    case isRunning = "is_running"
    case exitCode = "exit_code"
    case signal
    case timedOut = "timed_out"
    case cancelled
    case startedAt = "started_at"
    case finishedAt = "finished_at"
    case launchError = "launch_error"
    case streamErrors = "stream_errors"
    case stdout
    case stderr
  }

  internal var json: JSONValue {
    (try? JSONValue.encoded(self)) ?? .object([:])
  }
}

internal struct ShellWriteResult: Codable, Equatable, Sendable {
  internal var sessionID: String
  internal var bytesWritten: Int
  internal var inputClosed: Bool

  private enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case bytesWritten = "bytes_written"
    case inputClosed = "input_closed"
  }

  internal var json: JSONValue {
    (try? JSONValue.encoded(self)) ?? .object([:])
  }
}

internal struct ShellCancelResult: Codable, Equatable, Sendable {
  internal var sessionID: String
  internal var cancellationRequested: Bool
  internal var isRunning: Bool

  private enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case cancellationRequested = "cancellation_requested"
    case isRunning = "is_running"
  }

  internal var json: JSONValue {
    (try? JSONValue.encoded(self)) ?? .object([:])
  }
}

internal protocol ShellManaging: Sendable {
  func run(
    request: ShellLaunchRequest,
    defaultShell: String,
    defaultWorkingDirectory: URL,
    standardInput: Data,
    timeoutMilliseconds: Int,
    maxOutputBytes: Int,
    maxSessions: Int,
    terminationGraceMilliseconds: Int
  ) throws -> ShellSessionSnapshot

  func spawn(
    request: ShellLaunchRequest,
    defaultShell: String,
    defaultWorkingDirectory: URL,
    timeoutMilliseconds: Int?,
    maxOutputBytes: Int,
    maxSessions: Int,
    terminationGraceMilliseconds: Int
  ) throws -> String

  func list(
    maxReadBytes: Int,
    encoding: ShellStreamEncoding
  ) throws -> [ShellSessionSnapshot]

  func read(
    sessionID: String,
    stdoutCursor: Int64,
    stderrCursor: Int64,
    maxReadBytes: Int,
    encoding: ShellStreamEncoding
  ) throws -> ShellSessionSnapshot

  func write(sessionID: String, data: Data, close: Bool) throws -> ShellWriteResult
  func cancel(sessionID: String) throws -> ShellCancelResult
}

internal final class SubprocessShellRuntime: ShellManaging, @unchecked Sendable {
  private let lock = NSLock()
  private var sessions: [String: ShellSession] = [:]

  internal init() {}

  internal func run(
    request: ShellLaunchRequest,
    defaultShell: String,
    defaultWorkingDirectory: URL,
    standardInput: Data = Data(),
    timeoutMilliseconds: Int,
    maxOutputBytes: Int,
    maxSessions: Int,
    terminationGraceMilliseconds: Int
  ) throws -> ShellSessionSnapshot {
    let sessionID = try spawn(
      request: request,
      defaultShell: defaultShell,
      defaultWorkingDirectory: defaultWorkingDirectory,
      timeoutMilliseconds: timeoutMilliseconds,
      maxOutputBytes: maxOutputBytes,
      maxSessions: maxSessions,
      terminationGraceMilliseconds: terminationGraceMilliseconds
    )
    do {
      _ = try write(sessionID: sessionID, data: standardInput, close: true)
    } catch ShellRuntimeError.sessionNotRunning where standardInput.isEmpty {
      // A command that never reads stdin may finish before the close reaches its pipe.
    }
    let session = try requireSession(sessionID)
    let waitMilliseconds = timeoutMilliseconds + max(terminationGraceMilliseconds, 250) + 2_000
    if !session.waitForCompletion(timeoutMilliseconds: waitMilliseconds) {
      _ = try? cancel(sessionID: sessionID)
      throw ShellRuntimeError.timeoutWaitingForTermination(sessionID)
    }
    return session.snapshot(
      stdoutCursor: 0,
      stderrCursor: 0,
      maxReadBytes: maxOutputBytes,
      encoding: .utf8
    )
  }

  internal func spawn(
    request: ShellLaunchRequest,
    defaultShell: String,
    defaultWorkingDirectory: URL,
    timeoutMilliseconds: Int?,
    maxOutputBytes: Int,
    maxSessions: Int,
    terminationGraceMilliseconds: Int
  ) throws -> String {
    let resolved = try request.resolved(
      defaultShell: defaultShell,
      defaultWorkingDirectory: defaultWorkingDirectory
    )
    guard maxOutputBytes > 0 else {
      throw ShellRuntimeError.invalidRequest("maxOutputBytes must be greater than zero.")
    }
    guard maxSessions > 0 else {
      throw ShellRuntimeError.invalidRequest("maxSessions must be greater than zero.")
    }

    let session = ShellSession(
      id: UUID().uuidString,
      maxOutputBytes: maxOutputBytes,
      terminationGraceMilliseconds: terminationGraceMilliseconds
    )

    lock.lock()
    let activeCount = sessions.values.filter(\.isRunningOrStarting).count
    guard activeCount < maxSessions else {
      lock.unlock()
      throw ShellRuntimeError.sessionLimitReached(maxSessions)
    }
    sessions[session.id] = session
    lock.unlock()

    Task.detached(priority: .userInitiated) {
      await Self.launch(resolved, session: session)
    }

    guard session.waitForStart(timeoutMilliseconds: 10_000) else {
      _ = try? cancel(sessionID: session.id)
      throw ShellRuntimeError.launchFailed("Timed out while starting shell session.")
    }
    if let launchError = session.launchError {
      throw ShellRuntimeError.launchFailed(launchError)
    }

    if let timeoutMilliseconds, timeoutMilliseconds > 0 {
      Task.detached {
        try? await Task.sleep(for: .milliseconds(timeoutMilliseconds))
        session.timeoutIfRunning()
      }
    }

    return session.id
  }

  internal func list(
    maxReadBytes: Int = 0,
    encoding: ShellStreamEncoding = .utf8
  ) throws -> [ShellSessionSnapshot] {
    lock.lock()
    let sessions = self.sessions.values.sorted { $0.id < $1.id }
    lock.unlock()
    return sessions.map {
      $0.snapshot(
        stdoutCursor: $0.stdoutEndCursor,
        stderrCursor: $0.stderrEndCursor,
        maxReadBytes: max(0, maxReadBytes),
        encoding: encoding
      )
    }
  }

  internal func read(
    sessionID: String,
    stdoutCursor: Int64,
    stderrCursor: Int64,
    maxReadBytes: Int,
    encoding: ShellStreamEncoding
  ) throws -> ShellSessionSnapshot {
    guard stdoutCursor >= 0, stderrCursor >= 0, maxReadBytes >= 0 else {
      throw ShellRuntimeError.invalidRequest(
        "Stream cursors and maxReadBytes must be non-negative."
      )
    }
    return try requireSession(sessionID).snapshot(
      stdoutCursor: stdoutCursor,
      stderrCursor: stderrCursor,
      maxReadBytes: maxReadBytes,
      encoding: encoding
    )
  }

  internal func write(sessionID: String, data: Data, close: Bool) throws -> ShellWriteResult {
    try requireSession(sessionID).write(data: data, close: close)
  }

  internal func cancel(sessionID: String) throws -> ShellCancelResult {
    let session = try requireSession(sessionID)
    let requested = session.cancel()
    return ShellCancelResult(
      sessionID: sessionID,
      cancellationRequested: requested,
      isRunning: session.isRunningOrStarting
    )
  }

  private func requireSession(_ id: String) throws -> ShellSession {
    lock.lock()
    defer { lock.unlock() }
    guard let session = sessions[id] else {
      throw ShellRuntimeError.unknownSession(id)
    }
    return session
  }

  private static func launch(_ launch: ResolvedShellLaunch, session: ShellSession) async {
    do {
      let environmentOverrides = Dictionary(
        uniqueKeysWithValues: launch.environment.map { key, value in
          (Subprocess.Environment.Key(rawValue: key)!, Optional(value))
        }
      )
      let executable: Executable =
        launch.executable.contains("/")
        ? .path(FilePath(launch.executable))
        : .name(launch.executable)
      var platformOptions = PlatformOptions()
      platformOptions.processGroupID = 0
      let outcome = try await Subprocess.run(
        executable,
        arguments: Arguments(launch.arguments),
        environment: .inherit.updating(environmentOverrides),
        workingDirectory: FilePath(launch.workingDirectory.path),
        platformOptions: platformOptions,
        // DispatchIO waits for the preferred size before yielding while the
        // pipe remains open. A single-byte preference preserves live output;
        // CursorDataBuffer still coalesces and bounds the stored stream.
        preferredBufferSize: 1
      ) { execution, inputWriter, stdout, stderr in
        session.attach(execution: execution, inputWriter: inputWriter)
        await withTaskGroup(of: Void.self) { group in
          group.addTask {
            do {
              for try await buffer in stdout {
                session.appendStdout(Self.data(from: buffer))
              }
            } catch {
              session.recordStreamError("stdout: \(error.localizedDescription)")
            }
          }
          group.addTask {
            do {
              for try await buffer in stderr {
                session.appendStderr(Self.data(from: buffer))
              }
            } catch {
              session.recordStreamError("stderr: \(error.localizedDescription)")
            }
          }
        }
      }
      session.finish(status: outcome.terminationStatus)
    } catch {
      session.failLaunchOrExecution(error.localizedDescription)
    }
  }

  private static func data(from buffer: AsyncBufferSequence.Buffer) -> Data {
    buffer.withUnsafeBytes { Data($0) }
  }
}

private struct ResolvedShellLaunch: Sendable {
  var executable: String
  var arguments: [String]
  var workingDirectory: URL
  var environment: [String: String]
}

private final class ShellSession: @unchecked Sendable {
  let id: String
  private let condition = NSCondition()
  private let maxOutputBytes: Int
  private let terminationGraceMilliseconds: Int
  private var execution: Execution?
  private var inputWriter: StandardInputWriter?
  private var stdout = CursorDataBuffer()
  private var stderr = CursorDataBuffer()
  private var processID: Int32?
  private var exitCode: Int32?
  private var signal: Int32?
  private var timedOut = false
  private var cancelled = false
  private var started = false
  private var finished = false
  private var inputClosed = false
  private var streamErrors: [String] = []
  private var _launchError: String?
  private let startedAt = Date()
  private var finishedAt: Date?
  private var launcherExitObservedAt: Date?

  init(id: String, maxOutputBytes: Int, terminationGraceMilliseconds: Int) {
    self.id = id
    self.maxOutputBytes = maxOutputBytes
    self.terminationGraceMilliseconds = max(0, terminationGraceMilliseconds)
  }

  var launchError: String? {
    condition.lock()
    defer { condition.unlock() }
    return _launchError
  }

  var isRunningOrStarting: Bool {
    condition.lock()
    defer { condition.unlock() }
    return !finished
  }

  var stdoutEndCursor: Int64 {
    condition.lock()
    defer { condition.unlock() }
    return stdout.endCursor
  }

  var stderrEndCursor: Int64 {
    condition.lock()
    defer { condition.unlock() }
    return stderr.endCursor
  }

  func attach(execution: Execution, inputWriter: StandardInputWriter) {
    condition.lock()
    self.execution = execution
    self.inputWriter = inputWriter
    self.processID = Int32(execution.processIdentifier.value)
    started = true
    condition.broadcast()
    condition.unlock()
  }

  func appendStdout(_ data: Data) {
    condition.lock()
    stdout.append(data, limit: maxOutputBytes)
    condition.broadcast()
    condition.unlock()
  }

  func appendStderr(_ data: Data) {
    condition.lock()
    stderr.append(data, limit: maxOutputBytes)
    condition.broadcast()
    condition.unlock()
  }

  func recordStreamError(_ message: String) {
    condition.lock()
    streamErrors.append(message)
    condition.unlock()
  }

  func finish(status: TerminationStatus) {
    condition.lock()
    switch status {
    case .exited(let code):
      exitCode = code
    case .signaled(let code):
      signal = code
    }
    finished = true
    finishedAt = Date()
    condition.broadcast()
    condition.unlock()
  }

  func failLaunchOrExecution(_ message: String) {
    condition.lock()
    if !started {
      _launchError = message
    } else {
      streamErrors.append(message)
    }
    finished = true
    finishedAt = Date()
    condition.broadcast()
    condition.unlock()
  }

  func waitForStart(timeoutMilliseconds: Int) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1_000)
    while !started && _launchError == nil && !finished {
      if !condition.wait(until: deadline) {
        return false
      }
    }
    return started || _launchError != nil
  }

  func waitForCompletion(timeoutMilliseconds: Int) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1_000)
    while !finished {
      if !condition.wait(until: deadline) {
        return false
      }
    }
    return true
  }

  func timeoutIfRunning() {
    condition.lock()
    guard !finished else {
      condition.unlock()
      return
    }
    timedOut = true
    let execution = self.execution
    condition.unlock()
    requestTermination(execution)
  }

  func cancel() -> Bool {
    condition.lock()
    guard !finished else {
      condition.unlock()
      return false
    }
    cancelled = true
    let execution = self.execution
    condition.unlock()
    requestTermination(execution)
    return true
  }

  func write(data: Data, close: Bool) throws -> ShellWriteResult {
    condition.lock()
    guard !finished else {
      condition.unlock()
      throw ShellRuntimeError.sessionNotRunning(id)
    }
    guard !inputClosed else {
      condition.unlock()
      throw ShellRuntimeError.inputClosed(id)
    }
    guard let writer = inputWriter else {
      condition.unlock()
      throw ShellRuntimeError.sessionNotReady(id)
    }
    if close {
      inputClosed = true
    }
    condition.unlock()

    let bytesWritten: Int = try blockingAsync {
      var count = 0
      if !data.isEmpty {
        count = try await writer.write(Array(data))
      }
      if close {
        try await writer.finish()
      }
      return count
    }
    return ShellWriteResult(sessionID: id, bytesWritten: bytesWritten, inputClosed: close)
  }

  func snapshot(
    stdoutCursor: Int64,
    stderrCursor: Int64,
    maxReadBytes: Int,
    encoding: ShellStreamEncoding
  ) -> ShellSessionSnapshot {
    condition.lock()
    let stdoutRead = stdout.read(cursor: stdoutCursor, maxBytes: maxReadBytes)
    let stderrRead = stderr.read(cursor: stderrCursor, maxBytes: maxReadBytes)
    // A launcher can exit while one of its descendants keeps an inherited
    // stdout or stderr pipe open. `Subprocess.run` then continues draining the
    // pipe and has not yet delivered its termination status, even though the
    // launcher is already a zombie. Do not report that launcher as healthy:
    // supervisors need to cancel the old process group and restart it.
    let launcherHasExited = !finished && processID.map(Self.processHasExited) == true
    if launcherHasExited, launcherExitObservedAt == nil {
      launcherExitObservedAt = Date()
    }
    // A short-lived process becomes a zombie just before Subprocess has
    // drained its pipes and committed the termination status. Under concurrent
    // build or provider load that finalization can legitimately take longer
    // than a scheduler timeslice. Treating the transient state as terminal
    // exposes an impossible snapshot (not running, but with no exit status and
    // possibly incomplete output). Allow a bounded one-second floor while
    // retaining a two-second ceiling for inherited-pipe failure detection.
    let finalizationGraceMilliseconds = min(max(terminationGraceMilliseconds, 1_000), 2_000)
    let launcherExitedBeforeStreamsClosed =
      launcherHasExited
      && launcherExitObservedAt.map {
        Date().timeIntervalSince($0) * 1_000 >= Double(finalizationGraceMilliseconds)
      } == true
    var snapshotStreamErrors = streamErrors
    if launcherExitedBeforeStreamsClosed {
      snapshotStreamErrors.append("Process exited before inherited output streams closed.")
    }
    let snapshot = ShellSessionSnapshot(
      sessionID: id,
      processID: processID,
      isRunning: !finished && !launcherExitedBeforeStreamsClosed,
      exitCode: exitCode,
      signal: signal,
      timedOut: timedOut,
      cancelled: cancelled,
      startedAt: startedAt,
      finishedAt: finishedAt,
      launchError: _launchError,
      streamErrors: snapshotStreamErrors,
      stdout: stdoutRead.encoded(encoding),
      stderr: stderrRead.encoded(encoding)
    )
    condition.unlock()
    return snapshot
  }

  private static func processHasExited(_ processID: Int32) -> Bool {
    var info = proc_bsdinfo()
    let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
    errno = 0
    let actualSize = proc_pidinfo(
      processID,
      PROC_PIDTBSDINFO,
      0,
      &info,
      expectedSize
    )
    if actualSize == expectedSize {
      return info.pbi_status == SZOMB
    }
    return actualSize <= 0 && errno == ESRCH
  }

  private func requestTermination(_ execution: Execution?) {
    guard let execution else {
      return
    }
    try? execution.send(signal: .terminate, toProcessGroup: true)
    let grace = terminationGraceMilliseconds
    Task.detached {
      if grace > 0 {
        try? await Task.sleep(for: .milliseconds(grace))
      }
      if self.shouldEscalateTermination() {
        try? execution.send(signal: .kill, toProcessGroup: true)
      }
    }
  }

  private func shouldEscalateTermination() -> Bool {
    condition.lock()
    defer { condition.unlock() }
    return !finished
  }
}

private struct CursorDataBuffer {
  private(set) var data = Data()
  private(set) var startCursor: Int64 = 0
  private(set) var endCursor: Int64 = 0

  mutating func append(_ chunk: Data, limit: Int) {
    guard !chunk.isEmpty else {
      return
    }
    endCursor += Int64(chunk.count)
    data.append(chunk)
    if data.count > limit {
      let overflow = data.count - limit
      data.removeFirst(overflow)
      startCursor += Int64(overflow)
    }
  }

  func read(cursor: Int64, maxBytes: Int) -> CursorRead {
    let safeCursor = min(max(cursor, startCursor), endCursor)
    let offset = Int(safeCursor - startCursor)
    let available = max(0, data.count - offset)
    let count = min(maxBytes, available)
    let lowerBound = data.index(data.startIndex, offsetBy: offset)
    let upperBound = data.index(lowerBound, offsetBy: count)
    let payload = count == 0 ? Data() : data.subdata(in: lowerBound..<upperBound)
    return CursorRead(
      requestedCursor: cursor,
      startCursor: safeCursor,
      nextCursor: safeCursor + Int64(count),
      endCursor: endCursor,
      missedBytes: cursor < startCursor,
      truncated: startCursor > 0,
      data: payload
    )
  }
}

private struct CursorRead {
  var requestedCursor: Int64
  var startCursor: Int64
  var nextCursor: Int64
  var endCursor: Int64
  var missedBytes: Bool
  var truncated: Bool
  var data: Data

  func encoded(_ encoding: ShellStreamEncoding) -> ShellStreamRead {
    switch encoding {
    case .utf8:
      return ShellStreamRead(
        requestedCursor: requestedCursor,
        startCursor: startCursor,
        nextCursor: nextCursor,
        endCursor: endCursor,
        missedBytes: missedBytes,
        truncated: truncated,
        encoding: encoding,
        text: String(decoding: data, as: UTF8.self),
        base64: nil
      )
    case .base64:
      return ShellStreamRead(
        requestedCursor: requestedCursor,
        startCursor: startCursor,
        nextCursor: nextCursor,
        endCursor: endCursor,
        missedBytes: missedBytes,
        truncated: truncated,
        encoding: encoding,
        text: nil,
        base64: data.base64EncodedString()
      )
    }
  }
}

private final class AsyncResultBox<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Result<Value, any Error>?

  func set(_ result: Result<Value, any Error>) {
    lock.lock()
    value = result
    lock.unlock()
  }

  func get() -> Result<Value, any Error>? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

private func blockingAsync<Value: Sendable>(
  _ operation: @escaping @Sendable () async throws -> Value
) throws -> Value {
  let semaphore = DispatchSemaphore(value: 0)
  let box = AsyncResultBox<Value>()
  Task.detached {
    do {
      box.set(.success(try await operation()))
    } catch {
      box.set(.failure(error))
    }
    semaphore.signal()
  }
  semaphore.wait()
  guard let result = box.get() else {
    throw ShellRuntimeError.internalFailure("Async operation completed without a result.")
  }
  return try result.get()
}

internal enum ShellRuntimeError: Error, LocalizedError, Equatable {
  case invalidRequest(String)
  case unknownSession(String)
  case sessionLimitReached(Int)
  case sessionNotReady(String)
  case sessionNotRunning(String)
  case inputClosed(String)
  case launchFailed(String)
  case timeoutWaitingForTermination(String)
  case internalFailure(String)

  internal var errorDescription: String? {
    switch self {
    case .invalidRequest(let message), .launchFailed(let message),
      .internalFailure(let message):
      return message
    case .unknownSession(let id):
      return "Unknown shell session id: \(id)"
    case .sessionLimitReached(let limit):
      return "Shell session limit reached: \(limit)"
    case .sessionNotReady(let id):
      return "Shell session is not ready for input: \(id)"
    case .sessionNotRunning(let id):
      return "Shell session is not running: \(id)"
    case .inputClosed(let id):
      return "Shell session input is already closed: \(id)"
    case .timeoutWaitingForTermination(let id):
      return "Timed out waiting for shell session to terminate: \(id)"
    }
  }
}
