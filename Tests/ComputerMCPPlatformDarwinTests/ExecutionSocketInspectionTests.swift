import ComputerMCPProcess
import ComputerMCPSandbox
import Darwin
import Foundation
import Testing

@testable import ComputerMCPPlatformDarwin

@Suite(.serialized)
struct ExecutionSocketInspectionTests {
  @Test(.timeLimit(.minutes(1)), arguments: ExecutionLaunchMethod.allCases)
  func descriptorInspectionPreservesBootstrapHandoff(method: ExecutionLaunchMethod) async throws {
    let fixture = try SeatbeltFixture()
    defer { fixture.remove() }
    for _ in 0..<20 {
      let inspector = SocketDescriptorInspector()
      defer { inspector.stop() }
      let exit = try await ExecutionAdministration.$current.withValue(
        .init(mode: .fullAccess, environment: .init(fullAccessVariables: [:]))
      ) {
        try await ExecutionLauncher(
          platform: DarwinExecutionPlatform(
            bootstrapExecutable: try SeatbeltFixture.executionBootstrap)
        ).run(
          executable: .init("/usr/bin/git"), arguments: ["--version"],
          directory: .init(fixture.root.path), environment: .init(fullAccessVariables: [:]),
          mode: .fullAccess, method: method, bindOwnership: { _ in inspector.start() })
      }
      try #require(exit.status == 0)
    }
  }
}

/// Like descriptor inspection tools, this holds transient kernel references while
/// launch descriptors are being handed to a child process.
private final class SocketDescriptorInspector: @unchecked Sendable {
  private let lock = NSLock()
  private var stopped = false
  private var running = false
  private let finished = DispatchSemaphore(value: 0)
  private let existing = SocketDescriptorInspector.descriptors()

  func start() {
    lock.withLock { running = true }
    let descriptors = Self.descriptors().subtracting(existing)
    let started = DispatchSemaphore(value: 0)
    DispatchQueue(label: "bootstrap-descriptor-inspection").async { [self] in
      var info = socket_fdinfo()
      var first = true
      while !lock.withLock({ stopped }) {
        for descriptor in descriptors {
          _ = proc_pidfdinfo(
            getpid(), descriptor, PROC_PIDFDSOCKETINFO, &info,
            Int32(MemoryLayout<socket_fdinfo>.size))
        }
        if first {
          first = false
          started.signal()
        }
      }
      finished.signal()
    }
    started.wait()
  }

  func stop() {
    let running = lock.withLock {
      stopped = true
      return self.running
    }
    if running { finished.wait() }
  }

  private static func descriptors() -> Set<Int32> {
    var entries = [proc_fdinfo](repeating: .init(), count: 4096)
    let count = entries.withUnsafeMutableBytes {
      proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
    }
    return Set(entries.prefix(max(0, Int(count)) / MemoryLayout<proc_fdinfo>.stride).map(\.proc_fd))
  }
}
