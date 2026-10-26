import ComputerMCPCore
import ComputerMCPSandbox
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPProcess

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.nativeIntegration, .timeLimit(.minutes(1)))
struct ShellLaunchFailureTests {
  @Test func cancellationBeforeStartupReplyRetainsCancelledResult() async throws {
    let platform = CancelledLaunchPlatform()
    let runtime = ShellSessionRuntime(launcher: ExecutionLauncher(platform: platform))
    let starting = Task {
      try await BlockingOperationExecutor(label: "test.cancelled-startup").perform {
        try runtime.spawn(
          request: .init(mode: .argv, executable: "/bin/cat", inheritsEnvironment: false),
          defaultShell: "/bin/sh", defaultWorkingDirectory: FileManager.default.temporaryDirectory,
          timeoutMilliseconds: nil, maxOutputBytes: 1024, maxSessions: 1)
      }
    }
    for await _ in platform.bound.stream { break }
    await runtime.shutdown()
    let id = try await starting.value
    let result = try runtime.read(
      sessionID: id, stdoutCursor: 0, stderrCursor: 0, maxReadBytes: 1024, encoding: .utf8)
    #expect(result.cancelled && !result.isRunning && result.finishedAt != nil)
    #expect(result.endReason == .cancelled && result.launchError == nil)
  }

  @Test func boundLaunchFailureCompletesShutdown() async throws {
    let runtime = ShellSessionRuntime(launcher: ExecutionLauncher(platform: FailedBoundPlatform()))
    let started = ContinuousClock.now
    #expect(throws: ShellRuntimeError.self) {
      try runtime.run(
        request: .init(mode: .argv, executable: "/bin/sh", argv: [], inheritsEnvironment: false),
        defaultShell: "/bin/sh", defaultWorkingDirectory: FileManager.default.temporaryDirectory,
        timeoutMilliseconds: 1000, maxOutputBytes: 1024, maxSessions: 1)
    }
    await runtime.shutdown()
    #expect(started.duration(to: .now) < .seconds(5))
  }

  /// A launch that fails after its output pipes exist stops both readers and reports the
  /// failure instead of waiting on them.
  @Test func failedLaunchReportsPromptly() throws {
    let root = try ScopedTemporaryDirectory()
    let runtime = ShellSessionRuntime(launcher: testExecutionLauncher())
    let started = ContinuousClock.now
    #expect(throws: ShellRuntimeError.self) {
      try runtime.run(
        request: .init(
          mode: .argv, executable: "/bin/sh", argv: ["-c", "exit 0"],
          workingDirectory: root.url.appendingPathComponent("missing").path,
          inheritsEnvironment: false),
        defaultShell: "/bin/sh", defaultWorkingDirectory: root.url, timeoutMilliseconds: 5_000,
        maxOutputBytes: 1_024, maxSessions: 1)
    }
    #expect(started.duration(to: .now) < .seconds(5))
  }
}

private struct FailedBoundPlatform: ExecutionPlatform {
  func start(
    _ command: ExecutionCommand, sandbox: SandboxConfiguration?, method: ExecutionLaunchMethod,
    input: Int32, output: Int32, error: Int32,
    bindOwnership: @Sendable (any ExecutionOwnership) -> Void
  ) async throws -> any ExecutionOwnership {
    bindOwnership(FailedBoundOwnership())
    throw ExecutionEnvironmentError.launchFailed("bound launch failed")
  }
}

private struct FailedBoundOwnership: ExecutionOwnership {
  func beforeStart(_ handler: @escaping @Sendable (ExecutionMember) throws -> Void) {}
  func onCancellation(_ handler: @escaping @Sendable () -> Void) {}
  func members() async throws -> [ExecutionMember] { [] }
  func cancel(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit {
    throw ExecutionEnvironmentError.launchFailed("bound launch failed")
  }
  func wait(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit {
    throw ExecutionEnvironmentError.launchFailed("bound launch failed")
  }
}

private final class CancelledLaunchPlatform: ExecutionPlatform, Sendable {
  let bound = AsyncStream<Void>.makeStream()
  private let owner = CancelledLaunchOwnership()
  func start(
    _ command: ExecutionCommand, sandbox: SandboxConfiguration?, method: ExecutionLaunchMethod,
    input: Int32, output: Int32, error: Int32,
    bindOwnership: @Sendable (any ExecutionOwnership) -> Void
  ) async throws -> any ExecutionOwnership {
    bindOwnership(owner)
    bound.continuation.yield(())
    bound.continuation.finish()
    for await _ in owner.cancelled.stream {}
    throw ExecutionEnvironmentError.launchFailed("Bootstrap cancelled before handshake")
  }
}

private final class CancelledLaunchOwnership: ExecutionOwnership, Sendable {
  let cancelled = AsyncStream<Void>.makeStream()
  func beforeStart(_ handler: @escaping @Sendable (ExecutionMember) throws -> Void) {}
  func onCancellation(_ handler: @escaping @Sendable () -> Void) {}
  func members() async throws -> [ExecutionMember] { [] }
  func cancel(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit {
    cancelled.continuation.finish()
    return .init(status: 143, signal: 15)
  }
  func wait(until deadline: ContinuousClock.Instant) async throws -> ExecutionExit {
    for await _ in cancelled.stream {}
    return .init(status: 143, signal: 15)
  }
}
