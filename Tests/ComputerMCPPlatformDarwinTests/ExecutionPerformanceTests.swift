import ComputerMCPProcess
import ComputerMCPSandbox
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPPlatformDarwin

@Suite(.nativeIntegration) struct ExecutionPerformanceTests {
  @Test func fullAccessShortCommandsAvoidGlobalInspection() async throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    let counter = ExecutionInspectionCounter()
    let system = DarwinExecutionProcessTable.system(watermark: {
      counter.record(.probe)
      return try DarwinExecutionProcessTable.identityWatermark()
    })
    let table = DarwinExecutionProcessTable(
      list: { deadline, sentinel in
        counter.record(.snapshot)
        return try system.list(deadline, sentinel)
      },
      read: system.read, signal: system.signal,
      contains: { pid, marker in
        counter.record(.membership)
        return try system.contains(pid, marker)
      })
    let platform = try DarwinExecutionPlatform(
      bootstrapExecutable: SeatbeltFixture.executionBootstrap, table: table,
      makeSentinel: {
        counter.record(.sentinel)
        return try await DarwinExecutionSentinel.create()
      })
    let launcher = ExecutionLauncher(platform: platform)
    let runner = ManagedCommandRunner(launcher: launcher)
    let pairStart = ContinuousClock.now
    let pairWork = try await runShortCommands(runner, directory: fixture.root, count: 2)
    let pairDuration = pairStart.duration(to: .now)
    let concurrentStart = ContinuousClock.now
    let longestLane = try await withThrowingTaskGroup(of: Duration.self) { group in
      for _ in 0..<8 {
        group.addTask { try await runShortCommands(runner, directory: fixture.root, count: 16) }
      }
      var longest = Duration.zero
      for try await duration in group { longest = max(longest, duration) }
      return longest
    }
    print(
      "Full access short commands: pair=\(pairDuration), 128 across 8 lanes=\(concurrentStart.duration(to: .now)); worker pair=\(pairWork), longest lane=\(longestLane)"
    )
    #expect(counter.count(.snapshot) == 0)
    #expect(counter.count(.probe) == 0)
    #expect(counter.count(.sentinel) == 0)
    #expect(counter.count(.membership) == 0)

    // A sandboxed control proves that the injected counters observe the real kernel boundary.
    _ = try await runShortCommands(
      ManagedCommandRunner(launcher: launcher, policy: .readOnly), directory: fixture.root,
      count: 1)
    #expect(counter.count(.snapshot) > 0)
    #expect(counter.count(.probe) > 0)
    #expect(counter.count(.sentinel) == 1)
    #expect(counter.count(.membership) > 0)
  }

  private func runShortCommands(_ runner: ManagedCommandRunner, directory: URL, count: Int)
    async throws -> Duration
  {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Duration, Error>) in
      DispatchQueue(label: "test.short-commands").async {
        continuation.resume(
          with: Result {
            // Native cases can delay the async test's resumption after this worker has finished.
            let start = ContinuousClock.now
            for _ in 0..<count {
              let result = try runner.run(
                executable: "/usr/bin/true", arguments: [], workingDirectory: directory,
                environment: ["PATH": "/usr/bin:/bin"], timeoutMilliseconds: 5_000,
                maxOutputBytes: 1024)
              try #require(result.exitCode == 0)
            }
            return start.duration(to: .now)
          })
      }
    }
  }
}

private final class ExecutionInspectionCounter: @unchecked Sendable {
  enum Operation: Hashable { case snapshot, probe, sentinel, membership }
  private let lock = NSLock()
  private var counts: [Operation: Int] = [:]
  func record(_ operation: Operation) { lock.withLock { counts[operation, default: 0] += 1 } }
  func count(_ operation: Operation) -> Int { lock.withLock { counts[operation, default: 0] } }
}
