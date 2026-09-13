import Foundation
import Testing

@testable import ComputerMCP

@Suite(.serialized)

final class ShellSessionRuntimeTests {
  private let workspace = URL(fileURLWithPath: NSTemporaryDirectory())

  @Test
  func testRunCapturesStdoutAndStderr() async throws {
    let runtime = SubprocessShellRuntime()
    let result = try await BlockingOperationExecutor(label: "test.shell-call").perform {
      [workspace] in
      try runtime.run(
        request: ShellLaunchRequest(
          command: #"printf "stdout"; printf "stderr" >&2"#
        ),
        defaultShell: "/bin/zsh",
        defaultWorkingDirectory: workspace,
        timeoutMilliseconds: 2_000,
        maxOutputBytes: 1_024,
        maxSessions: 4,
        terminationGraceMilliseconds: 100
      )
    }

    #expect(!(result.isRunning))
    #expect((result.exitCode) == (0))
    #expect((result.stdout.text) == ("stdout"))
    #expect((result.stderr.text) == ("stderr"))
    #expect(!(result.timedOut))
  }

  @Test
  func testArgvModeSupportsEnvironmentAndWorkingDirectory() async throws {
    let runtime = SubprocessShellRuntime()
    let result = try await BlockingOperationExecutor(label: "test.shell-call").perform {
      [workspace] in
      try runtime.run(
        request: ShellLaunchRequest(
          mode: .argv,
          executable: "/usr/bin/env",
          argv: [],
          workingDirectory: workspace.path,
          environment: ["COMPUTER_MCP_TEST_VALUE": "present"]
        ),
        defaultShell: "/bin/zsh",
        defaultWorkingDirectory: URL(fileURLWithPath: "/"),
        timeoutMilliseconds: 2_000,
        maxOutputBytes: 64 * 1_024,
        maxSessions: 4,
        terminationGraceMilliseconds: 100
      )
    }

    #expect((result.exitCode) == (0))
    #expect(result.stdout.text?.contains("COMPUTER_MCP_TEST_VALUE=present") == true)
  }

  @Test
  func testRunWritesStandardInputAndClosesPipe() async throws {
    let runtime = SubprocessShellRuntime()
    let result = try await BlockingOperationExecutor(label: "test.shell-call").perform {
      [workspace] in
      try runtime.run(
        request: ShellLaunchRequest(mode: .argv, executable: "/bin/cat"),
        defaultShell: "/bin/zsh",
        defaultWorkingDirectory: workspace,
        standardInput: Data("stdin-payload".utf8),
        timeoutMilliseconds: 2_000,
        maxOutputBytes: 1_024,
        maxSessions: 4,
        terminationGraceMilliseconds: 100
      )
    }

    #expect((result.exitCode) == (0))
    #expect((result.stdout.text) == ("stdin-payload"))
    #expect((result.streamErrors) == ([]))
    #expect((result.launchError) == nil)
  }

  @Test
  func testSpawnWriteCloseAndIncrementalRead() async throws {
    let runtime = SubprocessShellRuntime()
    let sessionID = try await BlockingOperationExecutor(label: "test.shell-call").perform {
      [workspace] in
      try runtime.spawn(
        request: ShellLaunchRequest(mode: .argv, executable: "/bin/cat"),
        defaultShell: "/bin/zsh",
        defaultWorkingDirectory: workspace,
        timeoutMilliseconds: nil,
        maxOutputBytes: 1_024,
        maxSessions: 4,
        terminationGraceMilliseconds: 100
      )
    }

    let write = try await BlockingOperationExecutor(label: "test.shell-call").perform {
      try runtime.write(
        sessionID: sessionID,
        data: Data("hello\n".utf8),
        close: true
      )
    }
    #expect((write.bytesWritten) == (6))
    #expect(write.inputClosed)

    let result = try await waitForExit(runtime: runtime, sessionID: sessionID)
    #expect((result.exitCode) == (0))
    #expect((result.stdout.text) == ("hello\n"))

    let incremental = try runtime.read(
      sessionID: sessionID,
      stdoutCursor: result.stdout.nextCursor,
      stderrCursor: result.stderr.nextCursor,
      maxReadBytes: 1_024,
      encoding: .utf8
    )
    #expect((incremental.stdout.text) == (""))
    #expect((incremental.stdout.nextCursor) == (result.stdout.nextCursor))
  }

  @Test(arguments: [false, true])
  func testSpawnExposesShortOutputBeforeProcessExit(standardError: Bool) async throws {
    let runtime = SubprocessShellRuntime()
    let sessionID = try await BlockingOperationExecutor(label: "test.shell-call").perform {
      [workspace] in
      try runtime.spawn(
        request: ShellLaunchRequest(
          mode: .argv,
          executable: "/bin/sh",
          argv: [
            "-c", standardError ? "printf live-output >&2; sleep 5" : "printf live-output; sleep 5",
          ]
        ),
        defaultShell: "/bin/zsh",
        defaultWorkingDirectory: workspace,
        timeoutMilliseconds: nil,
        maxOutputBytes: 1_024,
        maxSessions: 4,
        terminationGraceMilliseconds: 100
      )
    }
    defer { _ = try? runtime.cancel(sessionID: sessionID) }

    let deadline = Date().addingTimeInterval(1)
    var snapshot = try runtime.read(
      sessionID: sessionID,
      stdoutCursor: 0,
      stderrCursor: 0,
      maxReadBytes: 1_024,
      encoding: .utf8
    )
    while Date() < deadline
      && (standardError ? snapshot.stderr.text : snapshot.stdout.text) != "live-output"
    {
      try await Task.sleep(for: .milliseconds(10))
      snapshot = try runtime.read(
        sessionID: sessionID,
        stdoutCursor: 0,
        stderrCursor: 0,
        maxReadBytes: 1_024,
        encoding: .utf8
      )
    }

    #expect(snapshot.isRunning)
    #expect((standardError ? snapshot.stderr.text : snapshot.stdout.text) == "live-output")
  }

  @Test
  func testSpawnDoesNotReportZombieLauncherAsRunningWhenDescendantKeepsPipeOpen() async throws {
    let runtime = SubprocessShellRuntime()
    let sessionID = try await BlockingOperationExecutor(label: "test.shell-call").perform {
      [workspace] in
      try runtime.spawn(
        request: ShellLaunchRequest(
          mode: .argv,
          executable: "/bin/sh",
          argv: ["-c", "sleep 30 &"]
        ),
        defaultShell: "/bin/zsh",
        defaultWorkingDirectory: workspace,
        timeoutMilliseconds: nil,
        maxOutputBytes: 1_024,
        maxSessions: 4,
        terminationGraceMilliseconds: 100
      )
    }
    defer { _ = try? runtime.cancel(sessionID: sessionID) }

    let deadline = Date().addingTimeInterval(2)
    var snapshot = try runtime.read(
      sessionID: sessionID,
      stdoutCursor: 0,
      stderrCursor: 0,
      maxReadBytes: 1_024,
      encoding: .utf8
    )
    while Date() < deadline && snapshot.isRunning {
      try await Task.sleep(for: .milliseconds(10))
      snapshot = try runtime.read(
        sessionID: sessionID,
        stdoutCursor: 0,
        stderrCursor: 0,
        maxReadBytes: 1_024,
        encoding: .utf8
      )
    }

    #expect(!(snapshot.isRunning))
    #expect(
      snapshot.streamErrors.contains("Process exited before inherited output streams closed."))
  }

  @Test
  func testTimeoutTerminatesProcessGroup() async throws {
    let runtime = SubprocessShellRuntime()
    let result = try await BlockingOperationExecutor(label: "test.shell-call").perform {
      [workspace] in
      try runtime.run(
        request: ShellLaunchRequest(command: "sleep 5"),
        defaultShell: "/bin/zsh",
        defaultWorkingDirectory: workspace,
        timeoutMilliseconds: 100,
        maxOutputBytes: 1_024,
        maxSessions: 4,
        terminationGraceMilliseconds: 100
      )
    }

    #expect(result.timedOut)
    #expect(!(result.isRunning))
    #expect((result.signal) != nil)
  }

  @Test
  func testRingBufferReportsMissedBytesWithAbsoluteCursor() async throws {
    let runtime = SubprocessShellRuntime()
    let result = try await BlockingOperationExecutor(label: "test.shell-call").perform {
      [workspace] in
      try runtime.run(
        request: ShellLaunchRequest(command: "printf 0123456789"),
        defaultShell: "/bin/zsh",
        defaultWorkingDirectory: workspace,
        timeoutMilliseconds: 2_000,
        maxOutputBytes: 4,
        maxSessions: 4,
        terminationGraceMilliseconds: 100
      )
    }

    #expect((result.stdout.text) == ("6789"))
    #expect(result.stdout.missedBytes)
    #expect(result.stdout.truncated)
    #expect((result.stdout.startCursor) == (6))
    #expect((result.stdout.nextCursor) == (10))
  }

  @Test(arguments: [false, true])
  func bulkOutputFinishesWithinItsBudgetWhileRetentionStaysBounded(standardError: Bool) async throws
  {
    let runtime = SubprocessShellRuntime()
    let command = "/bin/dd if=/dev/zero bs=1048576 count=5 2>/dev/null"
    let result = try await BlockingOperationExecutor(label: "test.shell-bulk").perform {
      [workspace] in
      try runtime.run(
        request: ShellLaunchRequest(command: standardError ? "{ \(command); } >&2" : command),
        defaultShell: "/bin/sh", defaultWorkingDirectory: workspace,
        timeoutMilliseconds: 5_000, maxOutputBytes: 4_096, maxSessions: 1,
        terminationGraceMilliseconds: 250)
    }
    #expect(result.exitCode == 0)
    #expect(!result.timedOut)
    #expect(result.streamErrors.isEmpty)
    let output = standardError ? result.stderr : result.stdout
    #expect(output.endCursor == 5 * 1_024 * 1_024)
    #expect(output.truncated && output.missedBytes)
    #expect(output.text?.utf8.count == 4_096)
  }

  @Test
  func testGatewayExposesCompleteShellSurfaceOnlyWhenEnabled() async throws {
    let disabled = GatewayToolRegistry(
      configuration: .fixture(policy: PolicyConfig(shellEnabled: false))
    )
    #expect(!(try disabled.listTools().contains { $0.name.hasPrefix("shell.") }))

    let enabled = GatewayToolRegistry(
      configuration: .fixture(policy: PolicyConfig(shellEnabled: true))
    )
    let names = Set(try enabled.listTools().map(\.name))
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
        name: "shell.run",
        arguments: .object([
          "mode": .string("argv"),
          "executable": .string("/bin/cat"),
          "stdin_text": .string("gateway"),
        ])
      )
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
      (try enabled.listTools()
        .first(where: { $0.name == "shell.run" })?
        .inputSchema.objectValue?["properties"]?
        .objectValue?["stdin_text"]) != nil)
  }

  private func waitForExit(
    runtime: SubprocessShellRuntime,
    sessionID: String
  ) async throws -> ShellSessionSnapshot {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
      let snapshot = try runtime.read(
        sessionID: sessionID,
        stdoutCursor: 0,
        stderrCursor: 0,
        maxReadBytes: 1_024,
        encoding: .utf8
      )
      if !snapshot.isRunning {
        return snapshot
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Shell session did not exit before the test deadline.")
    return try runtime.read(
      sessionID: sessionID,
      stdoutCursor: 0,
      stderrCursor: 0,
      maxReadBytes: 1_024,
      encoding: .utf8
    )
  }
}
