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
    try administration(command) {
      let result = try ManagedCommandRunner(launcher: launcher).runData(
        executable: executable,
        invocation: .init(arguments: command.arguments, standardInput: command.input),
        workingDirectory: command.directory, environment: command.environment,
        timeoutMilliseconds: command.timeoutMilliseconds, maxOutputBytes: command.maxOutputBytes)
      guard !result.timedOut, !result.stdoutTruncated, !result.stderrTruncated,
        let code = result.exitCode
      else { throw WorktreeError.busy("Host Git exceeded its command bounds.") }
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
    let ownership = try GatewaySynchronousOperation.run {
      try await InvocationExecution.$current.withValue(nil) {
        try await ExecutionAdministration.$current.withValue(scope) {
          try await launcher.start(
            executable: SandboxPath(executable), arguments: command.arguments,
            directory: SandboxPath(command.directory.path), environment: scope.environment,
            mode: scope.mode, input: input, output: output, error: error)
        }
      }
    }
    let deadline = session.deadline
    let watchdog = Task {
      do { try await ContinuousClock().sleep(until: deadline) } catch { return }
      _ = try? await ownership.cancel()
    }
    defer { watchdog.cancel() }
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
      let exit = try GatewaySynchronousOperation.run { try await ownership.wait(until: deadline) }
      guard exit.status == 0, exit.signal == nil else {
        throw WorktreeError.commandFailed("Git reference transaction failed.")
      }
    } catch {
      try? session.write(Data("abort\n".utf8))
      try? session.input.fileHandleForWriting.close()
      // Reaping is required before a caller may interpret the released locks.
      _ = try GatewaySynchronousOperation.run { try await ownership.cancel() }
      throw error
    }
  }
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
      try pollOutput()
    }
  }

  private func check() throws {
    guard ContinuousClock.now < deadline, total <= limit, diagnostics <= limit else {
      throw WorktreeError.busy("Git reference transaction exceeded its bounds.")
    }
  }

  private func pollOutput() throws {
    var descriptors = [
      pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0),
      pollfd(fd: errors.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0),
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
      } else if index == 0, count == 0 {
        throw WorktreeError.commandFailed("Git ended before its transaction acknowledgement.")
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
