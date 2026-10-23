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

  package func runIsolated(
    executable: String, arguments: [String], workingDirectory: URL?,
    environment: [String: String], timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult {
    try ProcessCommandRunner(environment: [:]).run(
      executable: executable, arguments: arguments, workingDirectory: workingDirectory,
      environment: environment, timeoutMilliseconds: timeoutMilliseconds,
      maxOutputBytes: maxOutputBytes)
  }

  package func runToFile(
    executable: String, arguments: [String], workingDirectory: URL?,
    environment: [String: String], timeoutMilliseconds: Int, maxOutputBytes: Int,
    outputDescriptor: Int32
  ) throws -> CommandResult {
    let result = try execute(
      executable: executable, arguments: arguments, workingDirectory: workingDirectory,
      environment: environment, timeoutMilliseconds: timeoutMilliseconds,
      maxOutputBytes: maxOutputBytes, outputDescriptor: outputDescriptor)
    return CommandResult(
      executable: result.executable, arguments: result.arguments, exitCode: result.exitCode,
      timedOut: result.timedOut, stdout: result.stdoutString, stderr: result.stderrString,
      stdoutTruncated: result.stdoutTruncated, stderrTruncated: result.stderrTruncated)
  }

  package func runData(
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String],
    timeoutMilliseconds: Int,
    maxOutputBytes: Int
  ) throws -> CommandDataResult {
    try execute(
      executable: executable, arguments: arguments, workingDirectory: workingDirectory,
      environment: environment, timeoutMilliseconds: timeoutMilliseconds,
      maxOutputBytes: maxOutputBytes, outputDescriptor: nil)
  }

  package func runInDirectory(
    executable: String, arguments: [String], directoryDescriptor: Int32,
    inputDescriptor: Int32, outputDescriptor: Int32, environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult {
    let childEnvironment = baseEnvironment.merging(environment) { _, new in new }
    let inspection = ExecutableInspection.inspect(
      executable, workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
      environment: childEnvironment)
    guard !inspection.hasKnownFailure, let path = inspection.path else {
      throw CommandRunnerError.launchFailed(inspection.message)
    }
    func checked(_ result: Int32) throws {
      guard result == 0 else {
        throw CommandRunnerError.launchFailed(String(cString: strerror(result)))
      }
    }
    #if canImport(Darwin)
      var actions: posix_spawn_file_actions_t?
      var attributes: posix_spawnattr_t?
    #else
      var actions = posix_spawn_file_actions_t()
      var attributes = posix_spawnattr_t()
    #endif
    try checked(posix_spawn_file_actions_init(&actions))
    defer { posix_spawn_file_actions_destroy(&actions) }
    try checked(posix_spawnattr_init(&attributes))
    defer { posix_spawnattr_destroy(&attributes) }
    // fchdir precedes the stdio dup actions, which may reuse its descriptor number.
    try checked(posix_spawn_file_actions_addfchdir_np(&actions, directoryDescriptor))
    // A pipe makes producers emit sparse holes as bytes instead of seeking within
    // the destination descriptor, so consecutive member streams remain contiguous.
    let stdout = OutputCollector(limit: 1, outputDescriptor: outputDescriptor)
    let stderr = OutputCollector(limit: max(1, maxOutputBytes))
    for (source, target) in [
      (inputDescriptor, STDIN_FILENO),
      (stdout.pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO),
      (stderr.pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO),
    ] {
      try checked(posix_spawn_file_actions_adddup2(&actions, source, target))
    }
    var flags = Int16(POSIX_SPAWN_SETPGROUP)
    #if canImport(Darwin)
      flags |= Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
    #endif
    try checked(posix_spawnattr_setflags(&attributes, flags))
    try checked(posix_spawnattr_setpgroup(&attributes, 0))
    let argv = ([path] + arguments).map { strdup($0) } + [nil]
    let envp =
      childEnvironment.sorted(by: { $0.key < $1.key }).map { strdup("\($0.key)=\($0.value)") } + [
        nil
      ]
    defer {
      for pointer in argv + envp { free(pointer) }
    }
    var pid: pid_t = 0
    try checked(posix_spawn(&pid, path, &actions, &attributes, argv, envp))
    try? stdout.pipe.fileHandleForWriting.close()
    try? stderr.pipe.fileHandleForWriting.close()
    var status: Int32 = 0
    var timedOut = false
    var deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMilliseconds))
    while true {
      let waited = waitpid(pid, &status, WNOHANG)
      if waited == pid { break }
      if waited < 0, errno != EINTR {
        _ = kill(-pid, SIGKILL)
        throw CommandRunnerError.launchFailed("Cannot wait for descriptor-based command.")
      }
      if ContinuousClock.now >= deadline {
        _ = kill(-pid, timedOut ? SIGKILL : SIGTERM)
        timedOut = true
        deadline = ContinuousClock.now.advanced(by: .seconds(2))
      }
      usleep(5_000)
    }
    stdout.stop(processHasExited: true)
    stderr.stop(processHasExited: true)
    if let error = stdout.writeError { throw error }
    return CommandResult(
      executable: executable, arguments: arguments,
      exitCode: status & 0x7f == 0 ? (status >> 8) & 0xff : status & 0x7f,
      timedOut: timedOut, stdout: "", stderr: stderr.stringValue,
      stdoutTruncated: false, stderrTruncated: stderr.truncated)
  }

  private func execute(
    executable: String, arguments: [String], workingDirectory: URL?,
    environment: [String: String], timeoutMilliseconds: Int, maxOutputBytes: Int,
    outputDescriptor: Int32?
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
    let stdout = outputDescriptor == nil ? OutputCollector(limit: perStreamLimit) : nil
    let stderr = OutputCollector(limit: perStreamLimit)
    if let outputDescriptor {
      process.standardOutput = FileHandle(fileDescriptor: outputDescriptor, closeOnDealloc: false)
    } else {
      process.standardOutput = stdout!.pipe
    }
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
    stdout?.stop(processHasExited: processHasExited)
    stderr.stop(processHasExited: processHasExited)

    return CommandDataResult(
      executable: executable,
      arguments: arguments,
      exitCode: process.isRunning ? nil : process.terminationStatus,
      timedOut: timedOut,
      stdout: stdout?.dataValue ?? Data(),
      stderr: stderr.dataValue,
      stdoutTruncated: stdout?.truncated ?? false,
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

/// Collects a pipe up to `limit` bytes, or streams all bytes to an opened descriptor.
/// Nonblocking reads drain the pipe;
/// the source's cancel handler owns descriptor cleanup after monitoring ends.
final class OutputCollector: @unchecked Sendable {
  let pipe = Pipe()
  private let limit: Int
  private let outputDescriptor: Int32?
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "computer-mcp.command-output")
  private let endOfFile = DispatchSemaphore(value: 0)
  /// Accessed only on `queue`, apart from initialization and deinitialization.
  private var source: ProcessOutputSource?
  /// End of file was read, or collection stopped.
  private var ended = false
  private var data = Data()
  private var outputError: (any Error)?
  private(set) var truncated = false

  init(limit: Int, outputDescriptor: Int32? = nil) {
    self.limit = limit
    self.outputDescriptor = outputDescriptor
    let handle = pipe.fileHandleForReading
    let flags = fcntl(handle.fileDescriptor, F_GETFL)
    if flags >= 0 { _ = fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) }
    let source = ProcessOutputSource(handle: handle, queue: queue) { [weak self] in self?.drain() }
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

  var writeError: (any Error)? { lock.withLock { outputError } }

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

    if let outputDescriptor {
      if outputError == nil {
        do {
          try FileHandle(fileDescriptor: outputDescriptor, closeOnDealloc: false).write(
            contentsOf: chunk)
        } catch { outputError = error }
      }
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
