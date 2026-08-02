import Foundation
import Testing

@testable import ComputerMCP

@Suite(.serialized)

final class SubprocessProcessRegistryTests {
  @Test
  func testSpawnReadAndListUseSubprocessSessionRuntime() throws {
    let registry = SubprocessProcessRegistry()
    let id = try registry.spawn(
      executable: "/bin/sh",
      arguments: ["-c", "printf process-ready"],
      workingDirectory: nil,
      environment: [:],
      maxOutputBytes: 4_096
    )

    let snapshot = try waitForExit(id: id, registry: registry)
    #expect(!(snapshot.isRunning))
    #expect((snapshot.exitCode) == (0))
    #expect((snapshot.stdout) == ("process-ready"))
    #expect((try registry.list().map(\.processID)) == ([id]))
  }

  @Test
  func testCancelTerminatesProcessGroupSession() throws {
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
    #expect(!(try waitForExit(id: id, registry: registry).isRunning))
  }

  @Test
  func testUnknownProcessFailsDeterministically() {
    let registry = SubprocessProcessRegistry()

    expectThrows(try registry.read(processID: "missing")) { error in
      #expect((error as? ProcessRegistryError) == (.unknownProcess("missing")))
    }
  }

  private func waitForExit(
    id: String,
    registry: SubprocessProcessRegistry
  ) throws -> ManagedProcessSnapshot {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      let snapshot = try registry.read(processID: id)
      if !snapshot.isRunning {
        return snapshot
      }
      Thread.sleep(forTimeInterval: 0.02)
    }
    Issue.record("Process did not exit before the test deadline.")
    return try registry.read(processID: id)
  }
}
