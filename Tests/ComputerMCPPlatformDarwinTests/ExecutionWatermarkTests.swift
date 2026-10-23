import ComputerMCPSandbox
import ComputerMCPTestSupport
import Darwin
import Foundation
import Testing

@testable import ComputerMCPPlatformDarwin

@Suite(.nativeIntegration) struct ExecutionWatermarkTests {
  @Test(.timeLimit(.minutes(1)), arguments: ProbeOutcome.allCases)
  func kernelWatermarkRoundsReapEveryProbe(outcome: ProbeOutcome) async throws {
    var probes = Set<DarwinProcessIdentity>()
    for _ in 0..<64 {
      let spawned = AsyncStream<Void>.makeStream()
      let release = DispatchSemaphore(value: 0)
      let round = Task.detached {
        var probe: DarwinProcessIdentity?
        defer { spawned.continuation.finish() }
        let result = Result {
          try DarwinExecutionProcessTable.identityWatermark { pid in
            if outcome == .exited {
              var info = siginfo_t()
              var waited: Int32
              repeat {
                waited = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT)
              } while waited == -1 && errno == EINTR
              try #require(waited == 0 && info.si_pid == pid)
              #expect(DarwinProcessIdentity.current(pid: pid) == nil)
            }
            let identity = try #require(
              DarwinProcessIdentity.current(pid: pid, includingZombies: true)?.identity)
            probe = identity
            spawned.continuation.yield(())
            switch outcome {
            case .immediate, .exited:
              return identity
            case .unreadable:
              return nil
            case .readFailure:
              throw ProbeReadFailure.injected
            case .cancelled:
              try #require(release.wait(timeout: .now() + 5) == .success)
              try Task.checkCancellation()
              return identity
            }
          }
        }
        return (result, probe)
      }
      if outcome == .cancelled {
        for await _ in spawned.stream { break }
        round.cancel()
        release.signal()
      }
      let (result, observed) = await round.value
      let probe = try #require(observed)
      #expect(probes.insert(probe).inserted)
      switch outcome {
      case .immediate, .exited:
        #expect(try result.get() == probe.uniqueID)
      case .unreadable:
        #expect(throws: ExecutionEnvironmentError.self) { try result.get() }
      case .readFailure:
        #expect(throws: ProbeReadFailure.self) { try result.get() }
      case .cancelled:
        #expect(throws: CancellationError.self) { try result.get() }
      }
      #expect(
        DarwinProcessIdentity.current(pid: probe.pid, includingZombies: true)?.identity != probe)
      var status: Int32 = 0
      let waited = waitpid(probe.pid, &status, WNOHANG)
      let waitError = errno
      #expect(waited == -1 && waitError == ECHILD, "Probe must already be reaped")
    }

    let estimate = proc_listallpids(nil, 0)
    try #require(estimate > 0)
    var pids = [pid_t](repeating: -1, count: max(1024, Int(estimate) * 4))
    let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    try #require(count > 0 && count < pids.count)
    // Search every parent, including launchd, and include unreaped zombies.
    let remaining = pids.prefix(Int(count)).compactMap {
      DarwinProcessIdentity.current(pid: $0, includingZombies: true)?.identity
    }.filter { probes.contains($0) }
    #expect(remaining.isEmpty, "Probe identities still in the process table: \(remaining)")
  }

  enum ProbeOutcome: CaseIterable, Sendable {
    case immediate, exited, unreadable, readFailure, cancelled
  }
}

private enum ProbeReadFailure: Error { case injected }
