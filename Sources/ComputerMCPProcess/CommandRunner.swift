import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

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

/// Collects one output pipe, up to `limit` bytes. One read source watches the read end;
/// reads are nonblocking and drain the pipe, and the source's cancel handler closes the
/// descriptor once the source no longer monitors it.
final class OutputCollector: @unchecked Sendable {
  let pipe = Pipe()
  private let limit: Int
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "computer-mcp.command-output")
  private let endOfFile = DispatchSemaphore(value: 0)
  /// Accessed only on `queue`, apart from initialization and deinitialization.
  private var source: DispatchSourceRead?
  /// End of file was read, or collection stopped.
  private var ended = false
  private var data = Data()
  private(set) var truncated = false

  init(limit: Int) {
    self.limit = limit
    let handle = pipe.fileHandleForReading
    let flags = fcntl(handle.fileDescriptor, F_GETFL)
    if flags >= 0 { _ = fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) }
    let source = DispatchSource.makeReadSource(fileDescriptor: handle.fileDescriptor, queue: queue)
    source.setEventHandler { [weak self] in self?.drain() }
    source.setCancelHandler { try? handle.close() }
    self.source = source
    source.resume()
  }

  deinit {
    source?.cancel()
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

  /// Stops collecting. When the process has exited, waits briefly for end of file, so every
  /// earlier read has appended its bytes before the result snapshot is created, then reads
  /// what remains. Later calls return at once.
  func stop(processHasExited: Bool) {
    if processHasExited, !lock.withLock({ ended }) {
      _ = endOfFile.wait(timeout: .now() + .seconds(2))
    }
    queue.sync {
      if processHasExited { drain() }
      source?.cancel()
      source = nil
    }
    lock.withLock { ended = true }
  }

  /// Reads until the pipe would block or ends. Runs on `queue`.
  private func drain() {
    guard let source else { return }
    var bytes = [UInt8](repeating: 0, count: 65_536)
    while true {
      let count = read(pipe.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
      if count > 0 {
        append(Data(bytes.prefix(count)))
        continue
      }
      if count < 0, errno == EINTR { continue }
      if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
      lock.withLock { ended = true }
      endOfFile.signal()
      source.cancel()
      self.source = nil
      return
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
