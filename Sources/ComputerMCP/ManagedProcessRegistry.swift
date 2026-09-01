import Foundation

internal struct ManagedProcessSnapshot: Codable, Equatable, Sendable {
  internal var processID: String
  internal var isRunning: Bool
  internal var exitCode: Int32?
  internal var stdout: String
  internal var stderr: String
  internal var stdoutTruncated: Bool
  internal var stderrTruncated: Bool

  private enum CodingKeys: String, CodingKey {
    case processID = "process_id"
    case isRunning = "is_running"
    case exitCode = "exit_code"
    case stdout
    case stderr
    case stdoutTruncated = "stdout_truncated"
    case stderrTruncated = "stderr_truncated"
  }

  internal var json: JSONValue {
    (try? JSONValue.encoded(self)) ?? .object([:])
  }
}

internal struct ManagedProcessCancelResult: Codable, Equatable, Sendable {
  internal var processID: String
  internal var cancelled: Bool
  internal var exitCode: Int32?

  private enum CodingKeys: String, CodingKey {
    case processID = "process_id"
    case cancelled
    case exitCode = "exit_code"
  }

  internal var json: JSONValue {
    (try? JSONValue.encoded(self)) ?? .object([:])
  }
}

internal protocol ProcessManaging: Sendable {
  func spawn(
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String],
    maxOutputBytes: Int
  ) throws -> String
  func list() throws -> [ManagedProcessSnapshot]
  func read(processID: String) throws -> ManagedProcessSnapshot
  func cancel(processID: String) throws -> ManagedProcessCancelResult
}

internal enum ProcessRegistryError: Error, LocalizedError, Equatable {
  case unknownProcess(String)
  case launchFailed(String)

  internal var errorDescription: String? {
    switch self {
    case .unknownProcess(let id):
      return "Unknown process id: \(id)"
    case .launchFailed(let message):
      return message
    }
  }
}

internal final class ManagedProcessRegistry: ProcessManaging, @unchecked Sendable {
  private let lock = NSLock()
  private var processes: [String: ManagedProcess] = [:]

  internal init() {}

  internal func spawn(
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String],
    maxOutputBytes: Int
  ) throws -> String {
    let id = UUID().uuidString
    let process = Process()
    configure(process: process, executable: executable, arguments: arguments)
    process.currentDirectoryURL = workingDirectory
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

    let stdout = OutputCollector(limit: maxOutputBytes)
    let stderr = OutputCollector(limit: maxOutputBytes)
    process.standardOutput = stdout.pipe
    process.standardError = stderr.pipe

    let managed = ManagedProcess(id: id, process: process, stdout: stdout, stderr: stderr)
    process.terminationHandler = { [weak managed] _ in
      managed?.markTerminated()
    }

    do {
      try process.run()
    } catch {
      throw ProcessRegistryError.launchFailed(error.localizedDescription)
    }

    lock.lock()
    processes[id] = managed
    lock.unlock()
    return id
  }

  internal func read(processID: String) throws -> ManagedProcessSnapshot {
    let process = try managed(processID)
    return process.snapshot()
  }

  internal func list() throws -> [ManagedProcessSnapshot] {
    lock.lock()
    let processes = self.processes.values.sorted { $0.id < $1.id }
    lock.unlock()
    return processes.map { $0.snapshot() }
  }

  internal func cancel(processID: String) throws -> ManagedProcessCancelResult {
    let process = try managed(processID)
    return process.cancel()
  }

  private func managed(_ id: String) throws -> ManagedProcess {
    lock.lock()
    defer { lock.unlock() }
    guard let process = processes[id] else {
      throw ProcessRegistryError.unknownProcess(id)
    }
    return process
  }
}

internal final class SubprocessProcessRegistry: ProcessManaging, @unchecked Sendable {
  private let shellManager: any ShellManaging
  private let maxSessions: Int
  private let terminationGraceMilliseconds: Int
  private let lock = NSLock()
  private var outputLimits: [String: Int] = [:]

  internal init(
    shellManager: any ShellManaging = SubprocessShellRuntime(),
    maxSessions: Int = 32,
    terminationGraceMilliseconds: Int = 1_000
  ) {
    self.shellManager = shellManager
    self.maxSessions = maxSessions
    self.terminationGraceMilliseconds = terminationGraceMilliseconds
  }

  internal func spawn(
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String],
    maxOutputBytes: Int
  ) throws -> String {
    let defaultDirectory =
      workingDirectory
      ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let id = try shellManager.spawn(
      request: ShellLaunchRequest(
        mode: .argv,
        executable: executable,
        argv: arguments,
        workingDirectory: defaultDirectory.path,
        environment: environment
      ),
      defaultShell: "/bin/zsh",
      defaultWorkingDirectory: defaultDirectory,
      timeoutMilliseconds: nil,
      maxOutputBytes: maxOutputBytes,
      maxSessions: maxSessions,
      terminationGraceMilliseconds: terminationGraceMilliseconds
    )
    lock.lock()
    outputLimits[id] = maxOutputBytes
    lock.unlock()
    return id
  }

  internal func list() throws -> [ManagedProcessSnapshot] {
    lock.lock()
    let sessions = outputLimits.sorted { $0.key < $1.key }
    lock.unlock()
    return try sessions.map { id, maxOutputBytes in
      try snapshot(processID: id, maxOutputBytes: maxOutputBytes)
    }
  }

  internal func read(processID: String) throws -> ManagedProcessSnapshot {
    lock.lock()
    let maxOutputBytes = outputLimits[processID]
    lock.unlock()
    guard let maxOutputBytes else {
      throw ProcessRegistryError.unknownProcess(processID)
    }
    return try snapshot(processID: processID, maxOutputBytes: maxOutputBytes)
  }

  internal func cancel(processID: String) throws -> ManagedProcessCancelResult {
    lock.lock()
    let known = outputLimits[processID] != nil
    lock.unlock()
    guard known else {
      throw ProcessRegistryError.unknownProcess(processID)
    }
    let result = try shellManager.cancel(sessionID: processID)
    return ManagedProcessCancelResult(
      processID: processID,
      cancelled: result.cancellationRequested,
      exitCode: nil
    )
  }

  private func snapshot(processID: String, maxOutputBytes: Int) throws
    -> ManagedProcessSnapshot
  {
    let snapshot = try shellManager.read(
      sessionID: processID,
      stdoutCursor: 0,
      stderrCursor: 0,
      maxReadBytes: maxOutputBytes,
      encoding: .utf8
    )
    return ManagedProcessSnapshot(
      processID: processID,
      isRunning: snapshot.isRunning,
      exitCode: snapshot.exitCode,
      stdout: snapshot.stdout.text ?? "",
      stderr: snapshot.stderr.text ?? "",
      stdoutTruncated: snapshot.stdout.truncated,
      stderrTruncated: snapshot.stderr.truncated
    )
  }
}

private final class ManagedProcess: @unchecked Sendable {
  let id: String
  let process: Process
  let stdout: OutputCollector
  let stderr: OutputCollector
  private let lock = NSLock()
  private var terminated = false

  init(id: String, process: Process, stdout: OutputCollector, stderr: OutputCollector) {
    self.id = id
    self.process = process
    self.stdout = stdout
    self.stderr = stderr
  }

  func markTerminated() {
    lock.lock()
    terminated = true
    lock.unlock()
    stdout.stop(processHasExited: true)
    stderr.stop(processHasExited: true)
  }

  func snapshot() -> ManagedProcessSnapshot {
    lock.lock()
    let isTerminated = terminated || !process.isRunning
    lock.unlock()

    if isTerminated {
      stdout.stop(processHasExited: true)
      stderr.stop(processHasExited: true)
    }

    return ManagedProcessSnapshot(
      processID: id,
      isRunning: !isTerminated,
      exitCode: isTerminated ? process.terminationStatus : nil,
      stdout: stdout.stringValue,
      stderr: stderr.stringValue,
      stdoutTruncated: stdout.truncated,
      stderrTruncated: stderr.truncated
    )
  }

  func cancel() -> ManagedProcessCancelResult {
    if process.isRunning {
      process.terminate()
      Thread.sleep(forTimeInterval: 0.05)
      if process.isRunning {
        process.interrupt()
      }
    }
    markTerminated()
    return ManagedProcessCancelResult(
      processID: id,
      cancelled: true,
      exitCode: process.terminationStatus
    )
  }
}
