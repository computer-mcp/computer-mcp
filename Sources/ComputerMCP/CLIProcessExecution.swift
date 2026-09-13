import Foundation
import os

/// Owns only CLI invocations started here, never the caller's interactive shell sessions.
final class CLIProcessExecution: Sendable {
  private struct State {
    var stopped = false
    var calls: [UUID: CLIProcessCall] = [:]
  }

  private let state = OSAllocatedUnfairLock(initialState: State())
  private let blocking = BlockingOperationExecutor(label: "computer-mcp.cli", serial: false)
  private let maxConcurrentCalls: Int
  private let inheritsEnvironment: Bool

  init(maxConcurrentCalls: Int = 32, inheritsEnvironment: Bool = true) {
    self.maxConcurrentCalls = max(1, maxConcurrentCalls)
    self.inheritsEnvironment = inheritsEnvironment
  }

  func run(
    executable: String, invocation: CLIInvocation, cwd: URL, environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int, executableChecks: [CLIExecutableCheck] = []
  ) throws -> ShellSessionSnapshot {
    let (id, call) = try begin()
    defer { _ = state.withLock { $0.calls.removeValue(forKey: id) } }
    return try call.run(
      executable: executable, invocation: invocation, cwd: cwd, environment: environment,
      timeoutMilliseconds: timeoutMilliseconds, maxOutputBytes: maxOutputBytes,
      executableChecks: executableChecks)
  }

  func runAsync(
    executable: String, invocation: CLIInvocation, cwd: URL, environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int, executableChecks: [CLIExecutableCheck] = []
  ) async throws -> ShellSessionSnapshot {
    try Task.checkCancellation()
    let (id, call) = try begin()
    defer { _ = state.withLock { $0.calls.removeValue(forKey: id) } }
    return try await withTaskCancellationHandler {
      let result = try await blocking.perform {
        try call.run(
          executable: executable, invocation: invocation, cwd: cwd, environment: environment,
          timeoutMilliseconds: timeoutMilliseconds, maxOutputBytes: maxOutputBytes,
          executableChecks: executableChecks)
      }
      try Task.checkCancellation()
      return result
    } onCancel: {
      call.cancel()
    }
  }

  func shutdown() async {
    let calls = state.withLock { state in
      state.stopped = true
      return Array(state.calls.values)
    }
    for call in calls { call.cancel() }
    while state.withLock({ !$0.calls.isEmpty }) {
      // Cleanup is independent of cancellation of the shutdown caller.
      _ = try? await blocking.perform { Thread.sleep(forTimeInterval: 0.02) }
    }
  }

  private func begin() throws -> (UUID, CLIProcessCall) {
    try state.withLock { state in
      guard !state.stopped else { throw CancellationError() }
      guard state.calls.count < maxConcurrentCalls else {
        throw CLITreeError.invalid("CLI invocation limit reached.")
      }
      let id = UUID()
      let call = CLIProcessCall(inheritsEnvironment: inheritsEnvironment)
      state.calls[id] = call
      return (id, call)
    }
  }
}

private final class CLIProcessCall: Sendable {
  private struct State {
    var cancelled = false
    var sessionID: String?
  }
  private let state = OSAllocatedUnfairLock(initialState: State())
  private let runtime = SubprocessShellRuntime()
  private let inheritsEnvironment: Bool

  init(inheritsEnvironment: Bool) { self.inheritsEnvironment = inheritsEnvironment }

  func cancel() {
    let id = state.withLock { state in
      state.cancelled = true
      return state.sessionID
    }
    if let id { _ = try? runtime.cancel(sessionID: id) }
  }

  func run(
    executable: String, invocation: CLIInvocation, cwd: URL, environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int, executableChecks: [CLIExecutableCheck]
  ) throws -> ShellSessionSnapshot {
    guard (1...3_600_000).contains(timeoutMilliseconds), (1...32_000_000).contains(maxOutputBytes)
    else {
      throw CLITreeError.invalid("CLI execution limits are out of bounds.")
    }
    guard !state.withLock({ $0.cancelled }) else { throw CancellationError() }
    let childEnvironment =
      inheritsEnvironment
      ? ProcessInfo.processInfo.environment.merging(environment) { _, value in value }
      : environment
    let inspection = ExecutableInspection.inspect(
      executable, workingDirectory: cwd, environment: childEnvironment)
    guard !inspection.hasKnownFailure, var resolvedExecutable = inspection.path else {
      throw CLITreeError.invalid(inspection.message)
    }
    guard executableChecks.count <= 4 else {
      throw CLITreeError.invalid("Too many executable checks.")
    }
    for check in executableChecks { try check.validate() }
    if !executableChecks.isEmpty {
      let deadline = ContinuousClock.now.advanced(
        by: .milliseconds(min(timeoutMilliseconds, 5_000)))
      let identity = try CLIExecutableIdentity.capture(
        executable: executable, cwd: cwd, environment: childEnvironment)
      resolvedExecutable = identity.executable
      for check in executableChecks {
        guard !state.withLock({ $0.cancelled }) else { throw CancellationError() }
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else {
          throw CLITreeError.invalid("CLI compatibility check timed out.")
        }
        let parts = remaining.components
        let milliseconds = max(
          1, Int(parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000))
        let result: ShellSessionSnapshot
        do {
          result = try execute(
            executable: identity.executable,
            invocation: .init(arguments: check.args, standardInput: Data()),
            cwd: cwd, environment: childEnvironment, timeoutMilliseconds: milliseconds,
            maxOutputBytes: 4_194_304)
        } catch {
          guard !state.withLock({ $0.cancelled }) else { throw CancellationError() }
          throw CLITreeError.invalid(
            "CLI executable compatibility check could not run; target command was not executed.")
        }
        guard !state.withLock({ $0.cancelled }) else { throw CancellationError() }
        guard check.matches(result), ContinuousClock.now < deadline else {
          throw CLITreeError.invalid(
            "CLI executable failed its compatibility check; target command was not executed.")
        }
        guard
          try CLIExecutableIdentity.capture(
            executable: executable, cwd: cwd, environment: childEnvironment) == identity
        else {
          throw CLITreeError.invalid(
            "CLI executable or interpreter changed during compatibility checks; retry after the update completes."
          )
        }
      }
    }
    guard !state.withLock({ $0.cancelled }) else { throw CancellationError() }
    return try execute(
      executable: resolvedExecutable, invocation: invocation, cwd: cwd,
      environment: childEnvironment,
      timeoutMilliseconds: timeoutMilliseconds, maxOutputBytes: maxOutputBytes)
  }

  private func execute(
    executable: String, invocation: CLIInvocation, cwd: URL, environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> ShellSessionSnapshot {
    let id = try runtime.spawn(
      request: .init(
        mode: .argv, executable: executable, argv: invocation.arguments,
        workingDirectory: cwd.path, environment: environment, inheritsEnvironment: false),
      defaultShell: "/bin/sh", defaultWorkingDirectory: cwd,
      timeoutMilliseconds: timeoutMilliseconds, maxOutputBytes: maxOutputBytes,
      maxSessions: 1, terminationGraceMilliseconds: 250)
    let cancelled = state.withLock { state in
      state.sessionID = id
      return state.cancelled
    }
    do {
      if cancelled {
        _ = try runtime.cancel(sessionID: id)
      } else {
        do {
          _ = try runtime.write(sessionID: id, data: invocation.standardInput, close: true)
        } catch ShellRuntimeError.sessionNotRunning where invocation.standardInput.isEmpty {
          // Commands that do not consume stdin can finish before the pipe is closed.
        }
      }
      return try runtime.wait(
        sessionID: id, timeoutMilliseconds: timeoutMilliseconds + 2_250,
        maxReadBytes: maxOutputBytes, encoding: .base64)
    } catch {
      _ = try? runtime.cancel(sessionID: id)
      _ = try? runtime.wait(
        sessionID: id, timeoutMilliseconds: 2_250, maxReadBytes: 0, encoding: .base64)
      throw error
    }
  }
}
