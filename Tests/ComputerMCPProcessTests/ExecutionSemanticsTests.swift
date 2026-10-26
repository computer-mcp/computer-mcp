#if os(macOS)
  import ComputerMCPDarwinTestSupport
  import ComputerMCPPlatform
  import ComputerMCPTestSupport
  import Foundation
  import Testing
  @testable import ComputerMCPProcess

  @Suite(.nativeIntegration, .serialized)
  struct ExecutionSemanticsTests {
    @Test func cursorsRetainNewestOutputAcrossBothStreams() throws {
      let root = try ScopedTemporaryDirectory()
      let runtime = ShellSessionRuntime(launcher: testExecutionLauncher())
      let id = try runtime.spawn(
        request: .init(mode: .argv, executable: "/bin/cat"),
        defaultShell: "/bin/sh", defaultWorkingDirectory: root.url,
        timeoutMilliseconds: nil, maxOutputBytes: 8, maxSessions: 1)
      _ = try runtime.write(sessionID: id, data: Data("abcdefgh".utf8), close: false)
      let first = try wait(runtime, id: id) { $0.stdout.endCursor == 8 }
      _ = try runtime.write(sessionID: id, data: Data("ijklmnop".utf8), close: true)
      let last = try wait(runtime, id: id) { !$0.isRunning }
      #expect(last.stdout.text == "ijklmnop")
      #expect(last.droppedBytes == 8)
      #expect(last.endReason == .exited)
      #expect(last.limits.timeoutMilliseconds == nil)
      #expect(last.limits.outputBytes == 8)
      let continued = try runtime.read(
        sessionID: id, stdoutCursor: first.stdout.nextCursor,
        stderrCursor: 0, maxReadBytes: 8, encoding: .utf8)
      #expect(continued.stdout.text == "ijklmnop")
      #expect(!continued.stdout.missedBytes)
      let both = try runtime.run(
        request: .init(
          mode: .argv, executable: "/bin/sh",
          argv: ["-c", "printf 12345678; sleep 0.1; printf abcdefgh >&2"]),
        defaultShell: "/bin/sh", defaultWorkingDirectory: root.url,
        timeoutMilliseconds: 5_000, maxOutputBytes: 8, maxSessions: 1)
      #expect(both.stdout.text == "")
      #expect(both.stderr.text == "abcdefgh")
      #expect(both.droppedBytes == 8)
    }

    @Test func processInputCursorsAndExitStatus() throws {
      let root = try ScopedTemporaryDirectory()
      let registry = ManagedProcessRegistry(launcher: testExecutionLauncher())
      let id = try registry.spawn(
        executable: "/bin/cat", arguments: [],
        workingDirectory: root.url, environment: [:], maxOutputBytes: 1024)
      _ = try registry.write(processID: id, data: Data("first\n".utf8), close: false)
      var first = try registry.read(processID: id)
      for _ in 0..<100 where first.stdout.isEmpty {
        Thread.sleep(forTimeInterval: 0.02)
        first = try registry.read(processID: id)
      }
      let cursor = try #require(first.execution?.stdout.nextCursor)
      _ = try registry.write(processID: id, data: Data("second\n".utf8), close: true)
      var last = try registry.read(
        processID: id, stdoutCursor: cursor, stderrCursor: 0,
        maxReadBytes: 1024)
      for _ in 0..<250 where last.isRunning {
        Thread.sleep(forTimeInterval: 0.02)
        last = try registry.read(
          processID: id, stdoutCursor: cursor, stderrCursor: 0,
          maxReadBytes: 1024)
      }
      #expect(last.stdout == "second\n")
      #expect(last.exitCode == 0)
      #expect(last.execution?.endReason == .exited)
    }

    @Test func timeoutAndNumericExitAreDistinct() throws {
      let root = try ScopedTemporaryDirectory()
      let runtime = ShellSessionRuntime(launcher: testExecutionLauncher())
      let exited = try runtime.run(
        request: .init(
          mode: .argv, executable: "/bin/sh",
          argv: ["-c", "exit 200"]), defaultShell: "/bin/sh", defaultWorkingDirectory: root.url,
        timeoutMilliseconds: 5_000, maxOutputBytes: 1024, maxSessions: 1)
      #expect(exited.exitCode == 200)
      #expect(exited.signal == nil)
      let timed = try runtime.run(
        request: .init(
          mode: .argv, executable: "/bin/sleep",
          argv: ["30"]), defaultShell: "/bin/sh", defaultWorkingDirectory: root.url,
        timeoutMilliseconds: 100, maxOutputBytes: 1024, maxSessions: 1)
      #expect(timed.timedOut)
      #expect(timed.endReason == .timeout)
      #expect(timed.limits.timeoutMilliseconds == 100)
      #expect(throws: ShellRuntimeError.self) {
        try runtime.spawn(
          request: .init(command: "true"), defaultShell: "/bin/sh",
          defaultWorkingDirectory: root.url, timeoutMilliseconds: 600_001,
          maxOutputBytes: 1024, maxSessions: 1)
      }
      #expect(ExecutionLimits.defaultTimeoutMilliseconds == 120_000)
      #expect(ExecutionLimits.defaultOutputBytes == 8_388_608)
    }

    @Test func readOnlyHostCommandsWriteOnlyTheirTemporaryDirectory() throws {
      let root = try ScopedTemporaryDirectory()
      let marker = root.url.appendingPathComponent("outside")
      let runner = ManagedCommandRunner(launcher: testExecutionLauncher(), policy: .readOnly)
      let result = try runner.run(
        executable: "/bin/sh",
        arguments: [
          "-c",
          "! (echo forbidden > \"$1\") && echo allowed > \"$TMPDIR/allowed\" && test -z \"$SECRET_TOKEN\" && printf '%s' \"$TMPDIR\"",
          "probe", marker.path,
        ],
        workingDirectory: root.url,
        environment: ["PATH": "/bin:/usr/bin", "SECRET_TOKEN": "sentinel"],
        timeoutMilliseconds: 5_000, maxOutputBytes: 4096)
      #expect(result.exitCode == 0, "stdout: \(result.stdout); stderr: \(result.stderr)")
      #expect(!FileManager.default.fileExists(atPath: marker.path))
      #expect(!FileManager.default.fileExists(atPath: result.stdout))
      let noProject = try ProcessCommandRunner(launcher: testExecutionLauncher()).run(
        executable: "/bin/sh",
        arguments: [
          "-c",
          "! (echo forbidden > \"$1\") && echo allowed > \"$TMPDIR/allowed\"", "probe", marker.path,
        ],
        workingDirectory: nil, environment: ["PATH": "/bin:/usr/bin"],
        timeoutMilliseconds: 5_000, maxOutputBytes: 4096)
      #expect(noProject.exitCode == 0, "stdout: \(noProject.stdout); stderr: \(noProject.stderr)")
      #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    private func wait(
      _ runtime: ShellSessionRuntime, id: String,
      until predicate: (ShellSessionSnapshot) -> Bool
    ) throws -> ShellSessionSnapshot {
      var snapshot = try runtime.read(
        sessionID: id, stdoutCursor: 0, stderrCursor: 0,
        maxReadBytes: 1024, encoding: .utf8)
      for _ in 0..<500 where !predicate(snapshot) {
        Thread.sleep(forTimeInterval: 0.02)
        snapshot = try runtime.read(
          sessionID: id, stdoutCursor: 0, stderrCursor: 0,
          maxReadBytes: 1024, encoding: .utf8)
      }
      try #require(predicate(snapshot))
      return snapshot
    }
  }
#elseif os(Linux)
  import ComputerMCPPlatformPOSIX
  import ComputerMCPSandbox
  import Testing

  struct ExecutionAvailabilityTests {
    @Test func sandboxRequestsFailBeforeLaunch() async throws {
      let root = try SandboxPath("/tmp")
      let sandbox = try SandboxConfiguration(
        readOnly: true, worktree: root, temporaryDirectory: root,
        homeDirectory: root, cacheDirectory: root, readableRoots: [root])
      let command = ExecutionCommand(
        executable: try SandboxPath("/bin/true"), arguments: [], directory: root, environment: [:])
      await #expect(
        throws: ExecutionEnvironmentError.unavailable("Linux sandbox execution is unavailable")
      ) {
        try await POSIXExecutionPlatform().start(
          command, sandbox: sandbox, method: .posixSpawn, input: -1, output: -1, error: -1,
          bindOwnership: { _ in
            Issue.record("Unavailable sandbox execution acquired a process owner")
          })
      }
    }
  }
#endif
