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
final class ShellToolProviderTests {
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
    let provider = ShellToolProvider(
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
    let provider = ShellToolProvider(
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

  @Test
  func testShellRunIsDisabledByDefault() {
    let provider = ShellToolProvider(environment: ToolEnvironment(configuration: .fixture()))

    expectThrows(
      try provider.callTool(
        .init(
          name: "shell.run",
          arguments: .object(["command": .string("echo nope")]), context: .empty
        ))
    ) { error in
      #expect(error.localizedDescription.contains("disabled"))
    }
  }

  @Test
  func testGatewayExposesCompleteShellSurfaceOnlyWhenEnabled() async throws {
    let disabled = ShellToolProvider(
      environment: ToolEnvironment(
        configuration: .fixture(policy: PolicyConfig(shellEnabled: false))
      ))
    #expect(!(try disabled.definitions().map(\.tool).contains { $0.name.hasPrefix("shell.") }))

    let enabled = ShellToolProvider(
      environment: ToolEnvironment(
        configuration: .fixture(policy: PolicyConfig(shellEnabled: true))
      ))
    let names = Set(try enabled.definitions().map(\.tool).map(\.name))
    #expect(
      Set([
        "shell.run",
        "shell.spawn",
        "shell.list",
        "shell.read",
        "shell.write",
        "shell.cancel",
      ]).isSubset(of: names))

    let result = try await BlockingOperationExecutor(label: "test.shell-call").perform {
      try enabled.callTool(
        .init(
          name: "shell.run",
          arguments: .object([
            "mode": .string("argv"),
            "executable": .string("/bin/cat"),
            "stdin_text": .string("gateway"),
          ]), context: .empty
        ))
    }
    let envelope = try #require(result.objectValue)
    #expect((envelope["isError"]) == (.bool(false)))
    let payload = try #require(
      envelope["structuredContent"]?.objectValue?["result"]?.objectValue
    )
    #expect((payload["exit_code"]) == (.number(0)))
    #expect((payload["is_running"]) == (.bool(false)))
    #expect((payload["exitCode"]) == nil)
    #expect((payload["stdout"]?.objectValue?["text"]) == (.string("gateway")))
    #expect(
      (try enabled.definitions().map(\.tool)
        .first(where: { $0.name == "shell.run" })?
        .inputSchema.objectValue?["properties"]?
        .objectValue?["stdin_text"]) != nil)
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
