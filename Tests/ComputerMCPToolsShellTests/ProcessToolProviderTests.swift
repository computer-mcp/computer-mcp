import ComputerMCPConfiguration
import ComputerMCPCore
import ComputerMCPPlatform
import ComputerMCPTestSupport
import ComputerMCPToolKit
import Foundation
import Testing

@testable import ComputerMCPProcess
@testable import ComputerMCPToolsShell

@Suite(.nativeIntegration, .serialized)
final class ProcessToolProviderTests {
  @Test
  func alreadyCancelledSpawnDoesNotReachManager() async {
    let runner = RecordingCommandRunner()
    let processes = FakeProcessManager()
    let provider = ProcessToolProvider(
      environment: ToolEnvironment(
        configuration: .fixture(), commandRunner: runner, processManager: processes))
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await provider.callToolAsync(
        .init(
          name: "process.spawn",
          arguments: .object(["id": .string("echo"), "argv": .array([.string("hello")])]),
          context: .empty))
    }

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(runner.calls.isEmpty)
    #expect(processes.spawnedIDs.isEmpty)
  }

  @Test
  func testProcessListReturnsGatewayManagedSessions() throws {
    let processManager = FakeProcessManager()
    processManager.snapshots = [
      ManagedProcessSnapshot(
        processID: "proc-1",
        isRunning: true,
        exitCode: nil,
        stdout: "ready\n",
        stderr: "",
        stdoutTruncated: false,
        stderrTruncated: false
      )
    ]
    let provider = ProcessToolProvider(
      environment: ToolEnvironment(
        configuration: .fixture(),
        processManager: processManager
      ))

    let result = try provider.callTool(
      .init(
        name: "process.list", arguments: .object([:]), context: .empty))
    let payload = try decodeTextPayload(result)
    let process = try #require(payload.objectValue?["processes"]?.arrayValue?.first?.objectValue)

    #expect((process["process_id"]) == (.string("proc-1")))
    #expect((process["is_running"]) == (.bool(true)))
    #expect((process["stdout"]) == (.string("ready\n")))
  }

  @Test
  func testProcessSpawnRejectsCommandThatDisallowsArbitraryArgs() {
    let provider = ProcessToolProvider(
      environment: ToolEnvironment(
        configuration: .fixture(
          cli: CLISectionConfig(commands: [
            CLICommandConfig(id: "echo", executable: "/bin/echo", allowAnyArgs: false)
          ])
        )
      ))

    expectThrows(
      try provider.callTool(
        .init(
          name: "process.spawn",
          arguments: .object([
            "id": .string("echo"),
            "argv": .array([.string("hello")]),
          ]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("does not allow arbitrary args"))
    }
  }

  private func decodeTextPayload(_ value: JSONValue) throws -> JSONValue {
    let text = try #require(
      value.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
    return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
  }
}

private final class FakeProcessManager: ProcessManaging, @unchecked Sendable {
  var snapshots: [ManagedProcessSnapshot] = []
  var spawnedIDs: [String] = []
  var cancelledIDs: [String] = []

  func spawn(
    executable: String,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String],
    maxOutputBytes: Int
  ) throws -> String {
    let id = "proc-\(spawnedIDs.count + 1)"
    spawnedIDs.append(id)
    return id
  }

  func list() throws -> [ManagedProcessSnapshot] {
    snapshots
  }

  func read(processID: String) throws -> ManagedProcessSnapshot {
    guard let snapshot = snapshots.first(where: { $0.processID == processID }) else {
      throw ProcessRegistryError.unknownProcess(processID)
    }
    return snapshot
  }

  func cancel(processID: String) throws -> ManagedProcessCancelResult {
    cancelledIDs.append(processID)
    return ManagedProcessCancelResult(
      processID: processID,
      cancelled: true,
      exitCode: nil
    )
  }
}
