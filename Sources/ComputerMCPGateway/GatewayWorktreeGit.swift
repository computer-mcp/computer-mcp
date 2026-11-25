import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import ComputerMCPProcess
import ComputerMCPSandbox
import ComputerMCPWorktrees
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Only lifecycle services construct commands for this pinned host Git adapter.
struct GatewayWorktreeGit: WorktreeGitExecuting, CommandRunning {
  let launcher: ExecutionLauncher
  let executable: String

  func run(
    executable _: String, arguments: [String], workingDirectory: URL?,
    environment: [String: String], timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandResult {
    guard let workingDirectory else {
      throw WorktreeError.invalidRequest("Git requires a repository directory.")
    }
    let result = try execute(
      .init(
        arguments: arguments, directory: workingDirectory,
        environment: environment, timeoutMilliseconds: timeoutMilliseconds,
        maxOutputBytes: maxOutputBytes))
    return .init(
      executable: executable, arguments: arguments, exitCode: result.exitCode, timedOut: false,
      stdout: String(decoding: result.output, as: UTF8.self),
      stderr: String(decoding: result.error, as: UTF8.self),
      stdoutTruncated: false, stderrTruncated: false)
  }

  func runData(
    executable _: String, arguments: [String], workingDirectory: URL?,
    environment: [String: String], timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> CommandDataResult {
    guard let workingDirectory else {
      throw WorktreeError.invalidRequest("Git requires a repository directory.")
    }
    let result = try execute(
      .init(
        arguments: arguments, directory: workingDirectory,
        environment: environment, timeoutMilliseconds: timeoutMilliseconds,
        maxOutputBytes: maxOutputBytes))
    return .init(
      executable: executable, arguments: arguments, exitCode: result.exitCode, timedOut: false,
      stdout: result.output, stderr: result.error, stdoutTruncated: false, stderrTruncated: false)
  }

  func execute(_ command: WorktreeGitCommand) throws -> WorktreeGitResult {
    // A checkout child can modify files while the parent owns source guards.
    // Use the collector whose return joins execution even on a failed command.
    try executeBounded(command, fileOutput: nil, fileSizeLimit: nil)
  }

  func executeBounded(
    _ command: WorktreeGitCommand, fileOutput: WorktreeGitFileOutput?, fileSizeLimit: Int?
  ) throws -> WorktreeGitResult {
    try administration(command) {
      let constraint = try fileSizeLimit.map { limit in
        guard let bytes = UInt64(exactly: limit) else {
          throw WorktreeError.invalidRequest("Invalid Git index file-size limit.")
        }
        return try ExecutionFileSizeLimit(bytes: bytes)
      }
      let result = try ManagedCommandRunner(launcher: launcher).runBounded(
        executable: executable,
        invocation: .init(arguments: command.arguments, standardInput: command.input),
        workingDirectory: command.directory, environment: command.environment,
        timeoutMilliseconds: command.timeoutMilliseconds, maxOutputBytes: command.maxOutputBytes,
        fileOutput: fileOutput.map { ($0.descriptor, $0.byteLimit) },
        fileSizeLimit: constraint)
      guard let code = result.exitCode else {
        throw WorktreeError.busy("Bounded host Git did not confirm its exit.")
      }
      return .init(output: result.stdout, error: result.stderr, exitCode: code)
    }
  }

  private func administration<T>(_ command: WorktreeGitCommand, _ body: () throws -> T) throws -> T
  {
    let scope = try ExecutionAdministration(
      mode: .fullAccess, environment: .init(fullAccessVariables: command.environment))
    return try InvocationExecution.$current.withValue(nil) {
      try ExecutionAdministration.$current.withValue(scope) {
        try HostCommandEnvironment.$current.withValue(command.environment, operation: body)
      }
    }
  }

  func withPreparedTransaction(_ command: WorktreeGitCommand, _ body: () throws -> Void) throws {
    let session = try GatewayGitTransaction(command)
    let scope = try ExecutionAdministration(
      mode: .fullAccess, environment: .init(fullAccessVariables: command.environment))
    let input = session.input.fileHandleForReading.fileDescriptor
    let output = session.output.fileHandleForWriting.fileDescriptor
    let error = session.errors.fileHandleForWriting.fileDescriptor
    let launch = GatewayGitLaunchOwnership()
    let ownership: any ExecutionOwnership
    do {
      ownership = try GatewaySynchronousOperation.run {
        try await InvocationExecution.$current.withValue(nil) {
          try await ExecutionAdministration.$current.withValue(scope) {
            try await launcher.start(
              executable: SandboxPath(executable), arguments: command.arguments,
              directory: SandboxPath(command.directory.path), environment: scope.environment,
              mode: scope.mode, input: input, output: output, error: error,
              bindOwnership: launch.bind)
          }
        }
      }
    } catch {
      if let owner = launch.ownership { try Self.settleFailedTransaction(owner) }
      throw error
    }
    let deadline = session.deadline
    let watchdog = Task {
      do { try await ContinuousClock().sleep(until: deadline) } catch { return }
      _ = try? await ownership.cancel()
    }
    defer {
      watchdog.cancel()
      _ = try? GatewaySynchronousOperation.run { await watchdog.value }
    }
    do {
      try session.closeChildEnds()
      try session.write(command.input)
      guard try session.line() == "start: ok\n", try session.line() == "prepare: ok\n" else {
        throw WorktreeError.commandFailed("Git did not prepare the reference transaction.")
      }
      try body()
      try session.write(Data("commit\n".utf8))
      guard try session.line() == "commit: ok\n" else {
        throw WorktreeError.commandFailed("Git did not acknowledge the reference transaction.")
      }
      try session.input.fileHandleForWriting.close()
      try session.finishOutput()
      let exit = try GatewaySynchronousOperation.run { try await ownership.wait(until: deadline) }
      guard exit.status == 0, exit.signal == nil else {
        throw WorktreeError.commandFailed("Git reference transaction failed.")
      }
    } catch {
      try? session.write(Data("abort\n".utf8))
      try? session.input.fileHandleForWriting.close()
      try Self.settleFailedTransaction(ownership)
      throw error
    }
  }

  /// The command deadline stops issuing protocol operations. It does not
  /// release the caller's journal and filesystem protection on a failed wait.
  private static func settleFailedTransaction(_ owner: any ExecutionOwnership) throws {
    try GatewaySynchronousOperation.run {
      while true {
        do {
          _ = try await owner.cancel()
          return
        } catch {
          try? await Task.sleep(for: .milliseconds(100))
        }
      }
    }
  }
}

private final class GatewayGitLaunchOwnership: @unchecked Sendable {
  private let lock = NSLock()
  private var owner: (any ExecutionOwnership)?

  var ownership: (any ExecutionOwnership)? { lock.withLock { owner } }

  func bind(_ owner: any ExecutionOwnership) { lock.withLock { self.owner = owner } }
}

/// Nonblocking pipe I/O bounds acknowledgements, diagnostics and writes together.
private final class GatewayGitTransaction {
  let input = Pipe()
  let output = Pipe()
  let errors = Pipe()
  let deadline: ContinuousClock.Instant
  private let limit: Int
  private var received = Data()
  private var total = 0
  private var diagnostics = 0
  private var stdoutOpen = true
  private var stderrOpen = true

  init(_ command: WorktreeGitCommand) throws {
    installBrokenPipeHandler()
    deadline = .now.advanced(by: .milliseconds(command.timeoutMilliseconds))
    limit = command.maxOutputBytes
    for handle in [
      input.fileHandleForWriting, output.fileHandleForReading, errors.fileHandleForReading,
    ] {
      let flags = fcntl(handle.fileDescriptor, F_GETFL)
      guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
        throw WorktreeError.commandFailed("Cannot configure Git transaction pipes.")
      }
    }
  }

  func closeChildEnds() throws {
    try input.fileHandleForReading.close()
    try output.fileHandleForWriting.close()
    try errors.fileHandleForWriting.close()
  }

  func write(_ data: Data) throws {
    var offset = 0
    while offset < data.count {
      try check()
      let count = data.withUnsafeBytes { bytes in
        systemWrite(
          input.fileHandleForWriting.fileDescriptor, bytes.baseAddress!.advanced(by: offset),
          data.count - offset)
      }
      if count > 0 {
        offset += count
      } else if count < 0, errno != EAGAIN, errno != EINTR {
        throw WorktreeError.commandFailed("Git transaction input closed.")
      } else {
        try pollOutput()
      }
    }
  }

  func line() throws -> String {
    while true {
      try check()
      if let end = received.firstIndex(of: 10) {
        let data = received.prefix(through: end)
        let value = String(decoding: data, as: UTF8.self)
        received.removeSubrange(...end)
        return value
      }
      guard stdoutOpen else {
        throw WorktreeError.commandFailed("Git ended before its transaction acknowledgement.")
      }
      try pollOutput()
    }
  }

  func finishOutput() throws {
    while stdoutOpen || stderrOpen { try pollOutput() }
    guard received.isEmpty else {
      throw WorktreeError.commandFailed("Unexpected output after Git committed the transaction.")
    }
  }

  private func check() throws {
    try Task.checkCancellation()
    guard ContinuousClock.now < deadline, total <= limit, diagnostics <= limit else {
      throw WorktreeError.busy("Git reference transaction exceeded its bounds.")
    }
  }

  private func pollOutput() throws {
    try check()
    var descriptors = [
      pollfd(
        fd: stdoutOpen ? output.fileHandleForReading.fileDescriptor : -1,
        events: Int16(POLLIN), revents: 0),
      pollfd(
        fd: stderrOpen ? errors.fileHandleForReading.fileDescriptor : -1,
        events: Int16(POLLIN), revents: 0),
    ]
    let ready = poll(&descriptors, 2, 10)
    guard ready >= 0 || errno == EINTR else {
      throw WorktreeError.commandFailed("Cannot read Git transaction acknowledgement.")
    }
    for index in descriptors.indices where descriptors[index].revents != 0 {
      var bytes = [UInt8](repeating: 0, count: 8192)
      let count = read(descriptors[index].fd, &bytes, bytes.count)
      if count > 0 {
        if index == 0 {
          total += count
          received.append(contentsOf: bytes.prefix(count))
        } else {
          diagnostics += count
        }
      } else if count == 0 {
        if index == 0 { stdoutOpen = false } else { stderrOpen = false }
      } else if count < 0, errno != EAGAIN, errno != EINTR {
        throw WorktreeError.commandFailed("Cannot read Git transaction output.")
      }
    }
    try check()
  }
}

private func systemWrite(_ descriptor: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int {
  #if canImport(Darwin)
    Darwin.write(descriptor, bytes, count)
  #else
    Glibc.write(descriptor, bytes, count)
  #endif
}
