import ComputerMCPCore
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPConfiguration
@testable import ComputerMCPGateway
@testable import ComputerMCPPlatform
@testable import ComputerMCPProcess

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

@Suite(.serialized)

final class ShellSessionRuntimeTests {
  private let project = URL(fileURLWithPath: NSTemporaryDirectory())

  @Test
  func testRunCapturesStdoutAndStderr() async throws {
    let runtime = ShellSessionRuntime(launcher: testExecutionLauncher())
    let result = try await BlockingOperationExecutor(label: "test.shell-call").perform {
      [project] in
      try runtime.run(
        request: ShellLaunchRequest(
          command: #"printf "stdout"; printf "stderr" >&2"#
        ),
        defaultShell: "/bin/zsh",
        defaultWorkingDirectory: project,
        timeoutMilliseconds: 2_000,
        maxOutputBytes: 1_024,
        maxSessions: 4
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
    let runtime = ShellSessionRuntime(launcher: testExecutionLauncher())
    let result = try await BlockingOperationExecutor(label: "test.shell-call").perform {
      [project] in
      try runtime.run(
        request: ShellLaunchRequest(
          mode: .argv,
          executable: "/usr/bin/env",
          argv: [],
          workingDirectory: project.path,
          environment: ["COMPUTER_MCP_TEST_VALUE": "present"]
        ),
        defaultShell: "/bin/zsh",
        defaultWorkingDirectory: URL(fileURLWithPath: "/"),
        timeoutMilliseconds: 2_000,
        maxOutputBytes: 64 * 1_024,
        maxSessions: 4
      )
    }

    #expect((result.exitCode) == (0))
    #expect(result.stdout.text?.contains("COMPUTER_MCP_TEST_VALUE=present") == true)
  }

  @Test
  func testRunWritesStandardInputAndClosesPipe() async throws {
    let runtime = ShellSessionRuntime(launcher: testExecutionLauncher())
    let result = try await BlockingOperationExecutor(label: "test.shell-call").perform {
      [project] in
      try runtime.run(
        request: ShellLaunchRequest(mode: .argv, executable: "/bin/cat"),
        defaultShell: "/bin/zsh",
        defaultWorkingDirectory: project,
        standardInput: Data("stdin-payload".utf8),
        timeoutMilliseconds: 2_000,
        maxOutputBytes: 1_024,
        maxSessions: 4
      )
    }

    #expect((result.exitCode) == (0))
    #expect((result.stdout.text) == ("stdin-payload"))
    #expect((result.streamErrors) == ([]))
    #expect((result.launchError) == nil)
  }

  @Test
  func testSpawnWriteCloseAndIncrementalRead() async throws {
    let runtime = ShellSessionRuntime(launcher: testExecutionLauncher())
    let sessionID = try await BlockingOperationExecutor(label: "test.shell-call").perform {
      [project] in
      try runtime.spawn(
        request: ShellLaunchRequest(mode: .argv, executable: "/bin/cat"),
        defaultShell: "/bin/zsh",
        defaultWorkingDirectory: project,
        timeoutMilliseconds: nil,
        maxOutputBytes: 1_024,
        maxSessions: 4
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

  @Test
  func processOwnershipOutlivesSpawnAndEndsAfterProcessCleanup() async throws {
    let ownedWork = GatewayOwnedWork()
    let runtime = ShellSessionRuntime(
      launcher: testExecutionLauncher(), ownedWork: ownedWork, projectID: "fixture")
    let sessionID = try await BlockingOperationExecutor(label: "test.shell-call").perform {
      [project] in
      try runtime.spawn(
        request: ShellLaunchRequest(mode: .argv, executable: "/bin/cat"),
        defaultShell: "/bin/zsh", defaultWorkingDirectory: project,
        timeoutMilliseconds: nil, maxOutputBytes: 1_024, maxSessions: 4)
    }
    defer { _ = try? runtime.cancel(sessionID: sessionID) }
    let record = try #require(ownedWork.snapshot.first)
    #expect(record.kind == .shell)
    #expect(record.projectID == "fixture")
    #expect(record.resourceID == sessionID)
    #expect(!record.uncertain)

    _ = try await BlockingOperationExecutor(label: "test.shell-call").perform {
      try runtime.write(sessionID: sessionID, data: Data("owned\n".utf8), close: true)
    }
    let result = try await waitForExit(runtime: runtime, sessionID: sessionID)
    #expect(result.exitCode == 0)
    #expect(result.stdout.text == "owned\n")
    let deadline = ContinuousClock.now + .seconds(2)
    while !ownedWork.snapshot.isEmpty && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(ownedWork.snapshot.isEmpty)
  }

  @Test(arguments: [false, true])
  func testSpawnExposesShortOutputBeforeProcessExit(standardError: Bool) async throws {
    let runtime = ShellSessionRuntime(launcher: testExecutionLauncher())
    let sessionID = try await BlockingOperationExecutor(label: "test.shell-call").perform {
      [project] in
      try runtime.spawn(
        request: ShellLaunchRequest(
          mode: .argv,
          executable: "/bin/sh",
          argv: [
            "-c", standardError ? "printf live-output >&2; sleep 5" : "printf live-output; sleep 5",
          ]
        ),
        defaultShell: "/bin/zsh",
        defaultWorkingDirectory: project,
        timeoutMilliseconds: nil,
        maxOutputBytes: 1_024,
        maxSessions: 4
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
  func testSpawnOwnsDescendantsAfterLauncherExits() async throws {
    let observations = ExecutionObservations()
    let runtime = ShellSessionRuntime(launcher: testExecutionLauncher(observations: observations))
    let sessionID = try await BlockingOperationExecutor(label: "test.shell-call").perform {
      [project] in
      try runtime.spawn(
        request: ShellLaunchRequest(
          mode: .argv,
          executable: "/bin/sh",
          argv: ["-c", "sleep 30 & read token"]
        ),
        defaultShell: "/bin/zsh",
        defaultWorkingDirectory: project,
        timeoutMilliseconds: nil,
        maxOutputBytes: 1_024,
        maxSessions: 4
      )
    }
    defer { _ = try? runtime.cancel(sessionID: sessionID) }

    let owner = try #require(observations.ownerships.first)
    let discoveryDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    var members = try await owner.members()
    while members.count < 2 && ContinuousClock.now < discoveryDeadline {
      try await Task.sleep(for: .milliseconds(10))
      members = try await owner.members()
    }
    try #require(members.count >= 2)
    _ = try await runtime.writeAsync(sessionID: sessionID, data: Data("exit\n".utf8), close: true)

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

    #expect(snapshot.isRunning)
    _ = try runtime.cancel(sessionID: sessionID)
    await runtime.shutdown()
    snapshot = try runtime.read(
      sessionID: sessionID, stdoutCursor: 0, stderrCursor: 0,
      maxReadBytes: 1024, encoding: .utf8)
    #expect(!snapshot.isRunning)
    #expect(snapshot.endReason == .cancelled)
    #expect(snapshot.streamErrors.isEmpty)
  }

  @Test
  func testTimeoutTerminatesProcessGroup() async throws {
    let runtime = ShellSessionRuntime(launcher: testExecutionLauncher())
    let result = try await BlockingOperationExecutor(label: "test.shell-call").perform {
      [project] in
      try runtime.run(
        request: ShellLaunchRequest(command: "sleep 5"),
        defaultShell: "/bin/zsh",
        defaultWorkingDirectory: project,
        timeoutMilliseconds: 100,
        maxOutputBytes: 1_024,
        maxSessions: 4
      )
    }

    #expect(result.timedOut)
    #expect(!(result.isRunning))
    #expect((result.signal) != nil)
  }

  @Test
  func testRingBufferReportsMissedBytesWithAbsoluteCursor() async throws {
    let runtime = ShellSessionRuntime(launcher: testExecutionLauncher())
    let result = try await BlockingOperationExecutor(label: "test.shell-call").perform {
      [project] in
      try runtime.run(
        request: ShellLaunchRequest(command: "printf 0123456789"),
        defaultShell: "/bin/zsh",
        defaultWorkingDirectory: project,
        timeoutMilliseconds: 2_000,
        maxOutputBytes: 4,
        maxSessions: 4
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
    let runtime = ShellSessionRuntime(launcher: testExecutionLauncher())
    let command = "/bin/dd if=/dev/zero bs=1048576 count=5 2>/dev/null"
    let result = try await BlockingOperationExecutor(label: "test.shell-bulk").perform {
      [project] in
      try runtime.run(
        request: ShellLaunchRequest(command: standardError ? "{ \(command); } >&2" : command),
        defaultShell: "/bin/sh", defaultWorkingDirectory: project,
        timeoutMilliseconds: 5_000, maxOutputBytes: 4_096, maxSessions: 1)
    }
    #expect(result.exitCode == 0)
    #expect(!result.timedOut)
    #expect(result.streamErrors.isEmpty)
    let output = standardError ? result.stderr : result.stdout
    #expect(output.endCursor == 5 * 1_024 * 1_024)
    #expect(output.truncated && output.missedBytes)
    #expect(output.text?.utf8.count == 4_096)
  }

  private func waitForExit(
    runtime: ShellSessionRuntime,
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
