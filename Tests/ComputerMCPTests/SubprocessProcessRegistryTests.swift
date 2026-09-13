import Foundation
import Testing

@testable import ComputerMCP

@Suite(.serialized)

final class SubprocessProcessRegistryTests {
  @Test
  func testSpawnReadAndListUseSubprocessSessionRuntime() async throws {
    let registry = SubprocessProcessRegistry()
    let id = try registry.spawn(
      executable: "/bin/sh",
      arguments: ["-c", "printf process-ready"],
      workingDirectory: nil,
      environment: [:],
      maxOutputBytes: 4_096
    )

    let snapshot = try await waitForSnapshot(id: id, registry: registry) { $0.exitCode != nil }
    #expect(!(snapshot.isRunning))
    #expect((snapshot.exitCode) == (0))
    #expect((snapshot.stdout) == ("process-ready"))
    #expect((try registry.list().map(\.processID)) == ([id]))
  }

  @Test
  func testCancelTerminatesProcessGroupSession() async throws {
    let registry = SubprocessProcessRegistry()
    let id = try registry.spawn(
      executable: "/bin/sh",
      arguments: ["-c", "sleep 30"],
      workingDirectory: nil,
      environment: [:],
      maxOutputBytes: 4_096
    )

    let result = try registry.cancel(processID: id)
    #expect((result.processID) == (id))
    #expect(result.cancelled)
    let snapshot = try await waitForSnapshot(id: id, registry: registry) { !$0.isRunning }
    #expect(!snapshot.isRunning)
  }

  @Test
  func testUnknownProcessFailsDeterministically() {
    let registry = SubprocessProcessRegistry()

    expectThrows(try registry.read(processID: "missing")) { error in
      #expect((error as? ProcessRegistryError) == (.unknownProcess("missing")))
    }
  }

  private func waitForSnapshot(
    id: String,
    registry: SubprocessProcessRegistry,
    matches: (ManagedProcessSnapshot) -> Bool
  ) async throws -> ManagedProcessSnapshot {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      let snapshot = try registry.read(processID: id)
      if matches(snapshot) {
        return snapshot
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("Process did not reach the expected snapshot before the test deadline.")
    return try registry.read(processID: id)
  }
}
