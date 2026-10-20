import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPPlatformPOSIX
import Foundation
import NIOConcurrencyHelpers

/// Only execution consumes argv/stdin. Diagnostics must not serialize this value.
package struct CLIInvocation: Sendable {
  package let arguments: [String]
  package let standardInput: Data

  package init(arguments: [String], standardInput: Data) {
    self.arguments = arguments
    self.standardInput = standardInput
  }
}

/// A launch was refused before the target command ran.
package enum ProcessLaunchError: Error, Equatable, LocalizedError {
  case invalid(String)

  package var errorDescription: String? {
    switch self {
    case .invalid(let reason): reason
    }
  }
}

/// A resolved launch, before its target command runs.
package struct ResolvedProcessLaunch: Sendable {
  /// The executable as requested, before resolution.
  package let executable: String
  package let cwd: URL
  /// The complete child environment.
  package let environment: [String: String]
  package let interpreterBindings: [String: String]
  package let timeoutMilliseconds: Int
}

/// Admits a resolved launch. It may run commands through `call`, and returns the
/// executable to launch or throws to refuse the launch.
package protocol LaunchVerification: Sendable {
  func verify(_ launch: ResolvedProcessLaunch, call: BoundedProcessCall) throws -> String
}

/// Owns only CLI invocations started here, never the caller's interactive shell sessions.
package final class CLIProcessExecution: Sendable {
  private struct State {
    var stopped = false
    var calls: [UUID: BoundedProcessCall] = [:]
  }

  private let state = NIOLockedValueBox(State())
  private let blocking = BlockingOperationExecutor(label: "computer-mcp.cli", serial: false)
  private let maxConcurrentCalls: Int
  private let inheritsEnvironment: Bool

  package init(maxConcurrentCalls: Int = 32, inheritsEnvironment: Bool = true) {
    self.maxConcurrentCalls = max(1, maxConcurrentCalls)
    self.inheritsEnvironment = inheritsEnvironment
  }

  package func launch(
    executable: String, invocation: CLIInvocation, cwd: URL, environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int, verification: (any LaunchVerification)? = nil,
    interpreterBindings: [String: String] = [:]
  ) throws -> ShellSessionSnapshot {
    let (id, call) = try begin()
    defer { _ = state.withLockedValue { $0.calls.removeValue(forKey: id) } }
    return try call.run(
      executable: executable, invocation: invocation, cwd: cwd, environment: environment,
      timeoutMilliseconds: timeoutMilliseconds, maxOutputBytes: maxOutputBytes,
      verification: verification, interpreterBindings: interpreterBindings,
      inheritsEnvironment: inheritsEnvironment)
  }

  package func launchAsync(
    executable: String, invocation: CLIInvocation, cwd: URL, environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int, verification: (any LaunchVerification)? = nil,
    interpreterBindings: [String: String] = [:]
  ) async throws -> ShellSessionSnapshot {
    try Task.checkCancellation()
    let (id, call) = try begin()
    defer { _ = state.withLockedValue { $0.calls.removeValue(forKey: id) } }
    let inheritsEnvironment = inheritsEnvironment
    return try await withTaskCancellationHandler {
      let result = try await blocking.perform {
        try call.run(
          executable: executable, invocation: invocation, cwd: cwd, environment: environment,
          timeoutMilliseconds: timeoutMilliseconds, maxOutputBytes: maxOutputBytes,
          verification: verification, interpreterBindings: interpreterBindings,
          inheritsEnvironment: inheritsEnvironment)
      }
      try Task.checkCancellation()
      return result
    } onCancel: {
      call.cancel()
    }
  }

  package func shutdown() async {
    let calls = state.withLockedValue { state in
      state.stopped = true
      return Array(state.calls.values)
    }
    for call in calls { call.cancel() }
    while state.withLockedValue({ !$0.calls.isEmpty }) {
      // Cleanup is independent of cancellation of the shutdown caller.
      _ = try? await blocking.perform { Thread.sleep(forTimeInterval: 0.02) }
    }
  }

  private func begin() throws -> (UUID, BoundedProcessCall) {
    try state.withLockedValue { state in
      guard !state.stopped else { throw CancellationError() }
      guard state.calls.count < maxConcurrentCalls else {
        throw ProcessLaunchError.invalid("CLI invocation limit reached.")
      }
      let id = UUID()
      let call = BoundedProcessCall()
      state.calls[id] = call
      return (id, call)
    }
  }
}

/// A sequence of argv executions. Cancelling stops the running one and refuses later ones.
package final class BoundedProcessCall: Sendable {
  private struct State {
    var cancelled = false
    var sessionID: String?
  }
  private let state = NIOLockedValueBox(State())
  private let runtime = SubprocessShellRuntime()

  package var isCancelled: Bool { state.withLockedValue { $0.cancelled } }

  package func cancel() {
    let id = state.withLockedValue { state in
      state.cancelled = true
      return state.sessionID
    }
    if let id { _ = try? runtime.cancel(sessionID: id) }
  }

  fileprivate func run(
    executable: String, invocation: CLIInvocation, cwd: URL, environment: [String: String],
    timeoutMilliseconds: Int, maxOutputBytes: Int, verification: (any LaunchVerification)?,
    interpreterBindings: [String: String], inheritsEnvironment: Bool
  ) throws -> ShellSessionSnapshot {
    guard (1...3_600_000).contains(timeoutMilliseconds), (1...32_000_000).contains(maxOutputBytes)
    else {
      throw ProcessLaunchError.invalid("CLI execution limits are out of bounds.")
    }
    guard !isCancelled else { throw CancellationError() }
    let childEnvironment =
      inheritsEnvironment
      ? ProcessInfo.processInfo.environment.merging(environment) { _, value in value }
      : environment
    let launch = ExecutableInspection.invocation(
      executable, workingDirectory: cwd, environment: childEnvironment,
      interpreterBindings: interpreterBindings)
    let inspection = launch.inspection
    guard !inspection.hasKnownFailure, var resolvedExecutable = launch.executable else {
      throw ProcessLaunchError.invalid(inspection.message)
    }
    if let verification {
      resolvedExecutable = try verification.verify(
        .init(
          executable: executable, cwd: cwd, environment: childEnvironment,
          interpreterBindings: interpreterBindings, timeoutMilliseconds: timeoutMilliseconds),
        call: self)
    }
    guard !isCancelled else { throw CancellationError() }
    return try execute(
      executable: resolvedExecutable, arguments: launch.arguments + invocation.arguments,
      standardInput: invocation.standardInput, cwd: cwd, environment: childEnvironment,
      timeoutMilliseconds: timeoutMilliseconds, maxOutputBytes: maxOutputBytes)
  }

  /// Runs `executable` without a shell, writes `standardInput` and closes it, and waits
  /// for the exit or the timeout.
  package func execute(
    executable: String, arguments: [String], standardInput: Data, cwd: URL,
    environment: [String: String], timeoutMilliseconds: Int, maxOutputBytes: Int
  ) throws -> ShellSessionSnapshot {
    let id = try runtime.spawn(
      request: .init(
        mode: .argv, executable: executable, argv: arguments,
        workingDirectory: cwd.path, environment: environment, inheritsEnvironment: false),
      defaultShell: "/bin/sh", defaultWorkingDirectory: cwd,
      timeoutMilliseconds: timeoutMilliseconds, maxOutputBytes: maxOutputBytes,
      maxSessions: 1, terminationGraceMilliseconds: 250)
    let cancelled = state.withLockedValue { state in
      state.sessionID = id
      return state.cancelled
    }
    do {
      if cancelled {
        _ = try runtime.cancel(sessionID: id)
      } else {
        do {
          _ = try runtime.write(sessionID: id, data: standardInput, close: true)
        } catch ShellRuntimeError.sessionNotRunning where standardInput.isEmpty {
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
