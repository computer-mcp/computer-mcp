import ComputerMCPCore
import Foundation

package struct ManagedProcessSnapshot: Codable, Equatable, Sendable {
  package var execution: ShellSessionSnapshot? = nil
  internal var processID: String
  internal var isRunning: Bool
  internal var exitCode: Int32?
  internal var stdout: String
  internal var stderr: String
  internal var stdoutTruncated: Bool
  internal var stderrTruncated: Bool

  private enum CodingKeys: String, CodingKey {
    case execution
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
  func read(processID: String, stdoutCursor: Int64, stderrCursor: Int64, maxReadBytes: Int) throws
    -> ManagedProcessSnapshot
  func write(processID: String, data: Data, close: Bool) throws -> ShellWriteResult
  func cancel(processID: String) throws -> ManagedProcessCancelResult
}

extension ProcessManaging {
  package func read(processID: String) throws -> ManagedProcessSnapshot {
    try read(
      processID: processID, stdoutCursor: 0, stderrCursor: 0,
      maxReadBytes: ExecutionLimits.defaultOutputBytes)
  }
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

package final class ManagedProcessRegistry: ProcessManaging, Sendable {
  private let shellManager: ShellSessionRuntime
  private let maxSessions: Int

  package init(
    launcher: ExecutionLauncher = ExecutionLauncher(),
    shellManager: ShellSessionRuntime? = nil,
    maxSessions: Int = 32
  ) {
    self.shellManager = shellManager ?? ShellSessionRuntime(launcher: launcher)
    self.maxSessions = maxSessions
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
      maxSessions: maxSessions)
  }

  package func list() throws -> [ManagedProcessSnapshot] {
    shellManager.processSnapshots()
  }

  package func read(processID: String, stdoutCursor: Int64, stderrCursor: Int64, maxReadBytes: Int)
    throws -> ManagedProcessSnapshot
  {
    try shellManager.processSnapshot(
      processID, stdoutCursor: stdoutCursor,
      stderrCursor: stderrCursor, maxReadBytes: maxReadBytes)
  }

  package func write(processID: String, data: Data, close: Bool) throws -> ShellWriteResult {
    _ = try shellManager.processSnapshot(processID)
    return try shellManager.write(sessionID: processID, data: data, close: close)
  }

  package func cancel(processID: String) throws -> ManagedProcessCancelResult {
    try shellManager.cancelProcess(processID)
  }
}
