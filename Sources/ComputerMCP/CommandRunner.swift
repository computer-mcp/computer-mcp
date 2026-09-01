import Foundation

package struct CommandResult: Codable, Equatable, Sendable {
  package var executable: String
  package var arguments: [String]
  package var exitCode: Int32?
  package var timedOut: Bool
  package var stdout: String
  package var stderr: String
  package var stdoutTruncated: Bool
  package var stderrTruncated: Bool

  private enum CodingKeys: String, CodingKey {
    case executable
    case arguments
    case exitCode = "exit_code"
    case timedOut = "timed_out"
    case stdout
    case stderr
    case stdoutTruncated = "stdout_truncated"
    case stderrTruncated = "stderr_truncated"
  }

  package init(
    executable: String,
    arguments: [String],
    exitCode: Int32?,
    timedOut: Bool,
    stdout: String,
    stderr: String,
    stdoutTruncated: Bool,
    stderrTruncated: Bool
  ) {
    self.executable = executable
    self.arguments = arguments
    self.exitCode = exitCode
    self.timedOut = timedOut
    self.stdout = stdout
    self.stderr = stderr
    self.stdoutTruncated = stdoutTruncated
    self.stderrTruncated = stderrTruncated
  }

  package var json: JSONValue {
    (try? JSONValue.encoded(self)) ?? .object([:])
  }
}

package struct CommandDataResult: Equatable, Sendable {
  package var executable: String
  package var arguments: [String]
  package var exitCode: Int32?
  package var timedOut: Bool
  package var stdout: Data
  package var stderr: Data
  package var stdoutTruncated: Bool
  package var stderrTruncated: Bool

  package init(
    executable: String,
    arguments: [String],
    exitCode: Int32?,
    timedOut: Bool,
    stdout: Data,
    stderr: Data,
    stdoutTruncated: Bool,
    stderrTruncated: Bool
  ) {
    self.executable = executable
    self.arguments = arguments
    self.exitCode = exitCode
    self.timedOut = timedOut
    self.stdout = stdout
    self.stderr = stderr
    self.stdoutTruncated = stdoutTruncated
    self.stderrTruncated = stderrTruncated
  }

  package var stdoutString: String {
    String(decoding: stdout, as: UTF8.self)
  }

  package var stderrString: String {
    String(decoding: stderr, as: UTF8.self)
  }
}

package protocol CommandRunning: Sendable {
  func run(
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String],
    timeoutMilliseconds: Int,
    maxOutputBytes: Int
  ) throws -> CommandResult

  func runData(
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String],
    timeoutMilliseconds: Int,
    maxOutputBytes: Int
  ) throws -> CommandDataResult
}

package enum CommandRunnerError: Error, LocalizedError, Equatable {
  case launchFailed(String)

  package var errorDescription: String? {
    switch self {
    case .launchFailed(let message):
      return message
    }
  }
}

package final class ProcessCommandRunner: CommandRunning, @unchecked Sendable {
  package init() {}

  package func run(
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String],
    timeoutMilliseconds: Int,
    maxOutputBytes: Int
  ) throws -> CommandResult {
    let result = try runData(
      executable: executable,
      arguments: arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      timeoutMilliseconds: timeoutMilliseconds,
      maxOutputBytes: maxOutputBytes
    )
    return CommandResult(
      executable: result.executable,
      arguments: result.arguments,
      exitCode: result.exitCode,
      timedOut: result.timedOut,
      stdout: result.stdoutString,
      stderr: result.stderrString,
      stdoutTruncated: result.stdoutTruncated,
      stderrTruncated: result.stderrTruncated
    )
  }

  package func runData(
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String],
    timeoutMilliseconds: Int,
    maxOutputBytes: Int
  ) throws -> CommandDataResult {
    let process = Process()
    configure(process: process, executable: executable, arguments: arguments)
    process.currentDirectoryURL = workingDirectory
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

    let perStreamLimit = max(1, maxOutputBytes)
    let stdout = OutputCollector(limit: perStreamLimit)
    let stderr = OutputCollector(limit: perStreamLimit)
    process.standardOutput = stdout.pipe
    process.standardError = stderr.pipe

    let termination = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in termination.signal() }

    do {
      try process.run()
    } catch {
      throw CommandRunnerError.launchFailed(error.localizedDescription)
    }

    let waitResult = termination.wait(timeout: .now() + .milliseconds(timeoutMilliseconds))
    var timedOut = false
    if waitResult == .timedOut {
      timedOut = true
      process.terminate()
      _ = termination.wait(timeout: .now() + .seconds(2))
      if process.isRunning {
        process.interrupt()
      }
    }

    let processHasExited = !process.isRunning
    stdout.stop(processHasExited: processHasExited)
    stderr.stop(processHasExited: processHasExited)

    return CommandDataResult(
      executable: executable,
      arguments: arguments,
      exitCode: process.isRunning ? nil : process.terminationStatus,
      timedOut: timedOut,
      stdout: stdout.dataValue,
      stderr: stderr.dataValue,
      stdoutTruncated: stdout.truncated,
      stderrTruncated: stderr.truncated
    )
  }
}

func configure(process: Process, executable: String, arguments: [String]) {
  if executable.contains("/") {
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
  } else {
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [executable] + arguments
  }
}

final class OutputCollector: @unchecked Sendable {
  let pipe = Pipe()
  private let limit: Int
  private let lock = NSLock()
  private let endOfFile = DispatchSemaphore(value: 0)
  private var data = Data()
  private(set) var truncated = false

  init(limit: Int) {
    self.limit = limit
    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty else {
        self?.endOfFile.signal()
        return
      }
      self?.append(chunk)
    }
  }

  var stringValue: String {
    lock.lock()
    defer { lock.unlock() }
    return String(decoding: data, as: UTF8.self)
  }

  var dataValue: Data {
    lock.lock()
    defer { lock.unlock() }
    return data
  }

  func stop(processHasExited: Bool) {
    if processHasExited {
      // Process termination can race the final readability callback. Waiting for
      // EOF ensures every earlier callback has appended its bytes before the
      // result snapshot is created.
      _ = endOfFile.wait(timeout: .now() + .seconds(2))
    }
    pipe.fileHandleForReading.readabilityHandler = nil
    if processHasExited {
      append(pipe.fileHandleForReading.readDataToEndOfFile())
    }
  }

  private func append(_ chunk: Data) {
    lock.lock()
    defer { lock.unlock() }

    guard !chunk.isEmpty else {
      return
    }

    let remaining = limit - data.count
    if remaining <= 0 {
      truncated = true
      return
    }

    if chunk.count > remaining {
      data.append(chunk.prefix(remaining))
      truncated = true
    } else {
      data.append(chunk)
    }
  }
}
