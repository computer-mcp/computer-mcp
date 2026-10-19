import ComputerMCPCore
import Foundation

package struct ManagedProcessSnapshot: Codable, Equatable, Sendable {
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

  package var json: JSONValue {
    (try? JSONValue.encoded(self)) ?? .object([:])
  }
}

package struct ManagedProcessCancelResult: Codable, Equatable, Sendable {
  internal var processID: String
  internal var cancelled: Bool
  internal var exitCode: Int32?

  private enum CodingKeys: String, CodingKey {
    case processID = "process_id"
    case cancelled
    case exitCode = "exit_code"
  }

  package var json: JSONValue {
    (try? JSONValue.encoded(self)) ?? .object([:])
  }
}

package protocol ProcessManaging: Sendable {
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

package enum ProcessRegistryError: Error, LocalizedError, Equatable {
  case unknownProcess(String)
  case launchFailed(String)

  package var errorDescription: String? {
    switch self {
    case .unknownProcess(let id):
      return "Unknown process id: \(id). Results may have expired or been evicted."
    case .launchFailed(let message):
      return message
    }
  }
}

package final class ManagedProcessRegistry: ProcessManaging, @unchecked Sendable {
  private let lock = NSLock()
  private var processes: [String: ManagedProcess] = [:]

  package init() {}

  package func spawn(
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

  package func read(processID: String) throws -> ManagedProcessSnapshot {
    let process = try managed(processID)
    return process.snapshot()
  }

  package func list() throws -> [ManagedProcessSnapshot] {
    lock.lock()
    let processes = self.processes.values.sorted { $0.id < $1.id }
    lock.unlock()
    return processes.map { $0.snapshot() }
  }

  package func cancel(processID: String) throws -> ManagedProcessCancelResult {
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

package final class SubprocessProcessRegistry: ProcessManaging, Sendable {
  private let shellManager: SubprocessShellRuntime
  private let maxSessions: Int
  private let terminationGraceMilliseconds: Int

  package init(
    shellManager: SubprocessShellRuntime = SubprocessShellRuntime(),
    maxSessions: Int = 32,
    terminationGraceMilliseconds: Int = 1_000
  ) {
    self.shellManager = shellManager
    self.maxSessions = maxSessions
    self.terminationGraceMilliseconds = terminationGraceMilliseconds
  }

  package func spawn(
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String],
    maxOutputBytes: Int
  ) throws -> String {
    let defaultDirectory =
      workingDirectory
      ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    return try shellManager.spawnProcess(
      request: ShellLaunchRequest(
        mode: .argv, executable: executable, argv: arguments,
        workingDirectory: defaultDirectory.path, environment: environment),
      defaultWorkingDirectory: defaultDirectory, maxOutputBytes: maxOutputBytes,
      maxSessions: maxSessions, terminationGraceMilliseconds: terminationGraceMilliseconds)
  }

  package func list() throws -> [ManagedProcessSnapshot] {
    shellManager.processSnapshots()
  }

  package func read(processID: String) throws -> ManagedProcessSnapshot {
    try shellManager.processSnapshot(processID)
  }

  package func cancel(processID: String) throws -> ManagedProcessCancelResult {
    try shellManager.cancelProcess(processID)
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
