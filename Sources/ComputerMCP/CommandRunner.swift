import ComputerMCPPlatform
import Foundation

package typealias CommandResult = ComputerMCPPlatform.CommandResult
package typealias CommandDataResult = ComputerMCPPlatform.CommandDataResult
package typealias CommandRunning = ComputerMCPPlatform.CommandRunning
package typealias CommandRunnerError = ComputerMCPPlatform.CommandRunnerError

extension CommandResult {
  package var json: JSONValue {
    (try? JSONValue.encoded(self)) ?? .object([:])
  }
}

package final class ProcessCommandRunner: CommandRunning, @unchecked Sendable {
  private let baseEnvironment: [String: String]

  package init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    baseEnvironment = environment
  }

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
    let cwd = workingDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let childEnvironment = baseEnvironment.merging(environment) { _, new in new }
    let inspection = ExecutableInspection.inspect(
      executable, workingDirectory: cwd, environment: childEnvironment)
    guard !inspection.hasKnownFailure, let path = inspection.path else {
      throw CommandRunnerError.launchFailed(inspection.message)
    }
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.currentDirectoryURL = cwd
    process.environment = childEnvironment

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
