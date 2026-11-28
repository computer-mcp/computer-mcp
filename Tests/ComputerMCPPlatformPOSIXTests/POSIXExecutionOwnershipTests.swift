#if os(Linux)
  import ComputerMCPSandbox
  import Foundation
  import Glibc
  import Testing

  @testable import ComputerMCPPlatformPOSIX

  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct POSIXExecutionOwnershipTests {
    @Test(arguments: [false, true])
    func callerExpiryLeavesOtherWaitersPending(cancel: Bool) async throws {
      let fixture = try ExecutionFixture()
      defer { fixture.release() }
      let laterDone = CompletionFlag()
      let unboundedDone = CompletionFlag()
      let later = Task {
        defer { laterDone.finish() }
        return try await fixture.owner.wait(until: .now.advanced(by: .milliseconds(450)))
      }
      let unbounded = Task {
        defer { unboundedDone.finish() }
        return try await fixture.owner.wait()
      }
      await #expect(throws: ExecutionWaitExpired.self) {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(150))
        if cancel { return try await fixture.owner.cancel(until: deadline) }
        return try await fixture.owner.wait(until: deadline)
      }
      #expect(!laterDone.isFinished)
      #expect(!unboundedDone.isFinished)
      await #expect(throws: ExecutionWaitExpired.self) { try await later.value }
      #expect(!unboundedDone.isFinished)
      fixture.release()
      #expect(try await unbounded.value.signal != nil)
      #expect(try await fixture.owner.members().isEmpty)
    }

    @Test func cancellationBudgetSurvivesCallerExpiryAndRetries() async throws {
      let fixture = try ExecutionFixture()
      defer { fixture.release() }
      let started = ContinuousClock.now
      let unbounded = Task { try await fixture.owner.wait() }
      for _ in 0..<10 {
        await #expect(throws: ExecutionWaitExpired.self) {
          try await fixture.owner.cancel(until: .now.advanced(by: .milliseconds(100)))
        }
      }
      let failure = try await completionFailure {
        try await fixture.owner.cancel(until: started.advanced(by: .seconds(7)))
      }
      #expect(ContinuousClock.now - started >= .seconds(5))
      #expect(ContinuousClock.now - started < .milliseconds(5_800))
      #expect(failure.bestEffort)
      #expect(!failure.members.isEmpty)
      #expect(failure.reasons.contains { $0.contains("Termination") })
      _ = try await completionFailure { try await unbounded.value }
      #expect(fixture.signals.observed.contains(SIGTERM))
      #expect(fixture.signals.observed.contains(SIGKILL))
      let retained = try await failure.ownership.members()
      #expect(try await fixture.owner.members() == retained)
      fixture.release()
      #expect(
        try await failure.ownership.wait(until: .now.advanced(by: .seconds(3))).signal == SIGKILL)
      #expect(try await fixture.owner.members().isEmpty)
    }

    @Test func terminationFailureReachesAllWaitersBeforeSimultaneousExpiry() async throws {
      let fixture = try ExecutionFixture()
      defer { fixture.release() }
      let deadline = ContinuousClock.now.advanced(by: .milliseconds(800))
      fixture.owner.requestCancellation(until: deadline)
      let later = Task { try await fixture.owner.wait(until: .now.advanced(by: .seconds(3))) }
      let unbounded = Task { try await fixture.owner.wait() }
      _ = try await completionFailure { try await fixture.owner.wait(until: deadline) }
      _ = try await completionFailure { try await later.value }
      _ = try await completionFailure { try await unbounded.value }
      fixture.release()
      #expect(try await fixture.owner.wait(until: .now.advanced(by: .seconds(3))).signal == SIGKILL)
    }

    @Test func cancellingAWaiterStartsOwnedTermination() async throws {
      let fixture = try ExecutionFixture()
      defer { fixture.release() }
      let waiting = Task { try await fixture.owner.wait() }
      waiting.cancel()
      for _ in 0..<100 where !fixture.signals.observed.contains(SIGTERM) {
        try await Task.sleep(for: .milliseconds(10))
      }
      try #require(fixture.signals.observed.contains(SIGTERM))
      // A shorter platform budget keeps this task-cancellation case bounded.
      fixture.owner.requestCancellation(until: .now.advanced(by: .milliseconds(800)))
      _ = try await completionFailure { try await waiting.value }
      fixture.release()
      #expect(try await fixture.owner.wait(until: .now.advanced(by: .seconds(3))).signal == SIGKILL)
    }

    private func completionFailure(
      _ operation: () async throws -> ExecutionExit
    ) async throws -> ExecutionCompletionFailure {
      do {
        _ = try await operation()
      } catch let failure as ExecutionCompletionFailure {
        return failure
      }
      throw POSIXTestError.expectedCompletionFailure
    }
  }

  private enum POSIXTestError: Error {
    case expectedCompletionFailure
  }

  private struct ExecutionFixture {
    let signals = GroupSignals()
    let owner: POSIXExecutionOwnership

    init() throws {
      let signals = self.signals
      owner = POSIXExecutionOwnership(signalGroup: { signals.send($0, $1) })
      let descriptor = open("/dev/null", O_RDWR | O_CLOEXEC)
      try #require(descriptor >= 0)
      defer { close(descriptor) }
      do {
        try owner.launch(
          .init(
            executable: SandboxPath("/bin/sleep"), arguments: ["30"],
            directory: SandboxPath("/"), environment: [:]),
          input: descriptor, output: descriptor, error: descriptor)
      } catch {
        signals.allow()
        owner.failedLaunch(error)
        throw error
      }
    }

    func release() {
      signals.allow()
      owner.requestCancellation()
    }
  }

  /// Suppresses delivery to a real group to model a member that survives TERM and KILL.
  private final class GroupSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = false
    private var sent: Set<Int32> = []
    var observed: Set<Int32> { lock.withLock { sent } }

    func send(_ group: pid_t, _ signal: Int32) {
      let deliver = lock.withLock {
        sent.insert(signal)
        return allowed
      }
      if deliver { _ = kill(-group, signal) }
    }

    func allow() { lock.withLock { allowed = true } }
  }

  private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    var isFinished: Bool { lock.withLock { finished } }
    func finish() { lock.withLock { finished = true } }
  }
#endif
