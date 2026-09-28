#if os(Windows)
  import Foundation
  import Testing
  import WinSDK

  @testable import ComputerMCPPlatform

  struct PlatformCommandRunnerTests {
    @Test
    func deliversArgumentsEnvironmentAndWorkingDirectoryWithoutAShell() async throws {
      let fixture = try WindowsCommandFixture()
      defer { fixture.cleanup() }
      let arguments = ["", "two words", "汉字 🐈", "a\"b", "end\\", "slash\\\"quote", "a&b|c;d"]
      let value = try await fixture.run(
        ["echo"] + arguments, environment: ["fixture_value": "覆盖 值"])
      #expect(value.exitCode == 0 && !value.timedOut)
      #expect(!value.stdoutTruncated && !value.stderrTruncated)
      let object = try #require(JSONSerialization.jsonObject(with: value.stdout) as? [String: Any])
      #expect(object["arguments"] as? [String] == arguments)
      #expect(object["value"] as? String == "覆盖 值")
      let cwd = try #require(object["cwd"] as? String)
      #expect(URL(fileURLWithPath: cwd).standardizedFileURL == fixture.root.standardizedFileURL)
    }

    @Test
    func customEnvironmentDoesNotInheritUnspecifiedValues() async throws {
      let fixture = try WindowsCommandFixture()
      defer { fixture.cleanup() }
      // Swift's runtime DLLs require the configured PATH, independently of command lookup.
      let path = try #require(
        ProcessInfo.processInfo.environment.first {
          $0.key.lowercased() == "path"
        }?.value)
      let runner = ProcessCommandRunner(environment: ["PATH": path, "FIXTURE_VALUE": "base"])
      let value = try await fixture.run(
        ["echo"], runner: runner, environment: ["fixture_value": "override"])
      let object = try #require(JSONSerialization.jsonObject(with: value.stdout) as? [String: Any])
      #expect(object["value"] as? String == "override")
      #expect(object["userProfile"] as? String == "")
      #expect(object["path"] as? String == path)
    }

    @Test
    func anAbsentChildPathDoesNotFallBackToTheParent() async throws {
      var directory = [WCHAR](repeating: 0, count: 32_768)
      let count = GetSystemDirectoryW(&directory, UINT(directory.count))
      #expect(count > 0 && count < directory.count)
      let executable = String(decoding: directory.prefix(Int(count)), as: UTF16.self) + "\\cmd.exe"
      let result = try await ProcessCommandRunner(environment: [:]).runDataAsync(
        executable: executable,
        arguments: ["/d", "/c", "if defined PATH (exit /b 41) else (exit /b 0)"],
        workingDirectory: nil, environment: [:], timeoutMilliseconds: 10_000, maxOutputBytes: 256)
      #expect(result.exitCode == 0 && !result.timedOut)
    }

    @Test
    func nativeLaunchFailureDoesNotBecomeSuccessOrTimeout() async throws {
      let fixture = try WindowsCommandFixture()
      defer { fixture.cleanup() }
      let invalid = fixture.root.appendingPathComponent("invalid.exe")
      try Data("MZnot-a-PE-image".utf8).write(to: invalid)
      await #expect(throws: (any Error).self) {
        try await ProcessCommandRunner().runDataAsync(
          executable: invalid.path, arguments: [], workingDirectory: fixture.root,
          environment: [:], timeoutMilliseconds: 10_000, maxOutputBytes: 256)
      }
    }

    @Test(arguments: [1, 256, 257, 8_192])
    func drainsBothBinaryStreamsBeyondTheirCaptureLimits(limit: Int) async throws {
      let fixture = try WindowsCommandFixture()
      defer { fixture.cleanup() }
      let marker = fixture.root.appendingPathComponent("drained")
      let value = try await fixture.run(["output", "2048", marker.path], limit: limit)
      #expect(value.exitCode == 0 && !value.timedOut)
      #expect(value.stdout.count == limit && value.stderr.count == limit)
      #expect(value.stdoutTruncated && value.stderrTruncated)
      #expect(Array(value.stdout) == (0..<limit).map { UInt8($0 % 256) })
      #expect(Array(value.stderr) == (0..<limit).map { UInt8(255 - $0 % 256) })
      #expect(try String(contentsOf: marker, encoding: .utf8) == "drained")
    }

    @Test
    func exactLimitIsNotTruncationAndExitCodePreservesAllBits() throws {
      let fixture = try WindowsCommandFixture()
      defer { fixture.cleanup() }
      let runner: any CommandRunning = ProcessCommandRunner()
      let value = try runner.runData(
        executable: fixture.executable,
        arguments: ["output", "1", fixture.root.appendingPathComponent("drained").path],
        workingDirectory: fixture.root, environment: [:], timeoutMilliseconds: 10_000,
        maxOutputBytes: 256)
      #expect(value.stdout.count == 256 && value.stderr.count == 256)
      #expect(!value.stdoutTruncated && !value.stderrTruncated)
      let status = try runner.run(
        executable: fixture.executable, arguments: ["exit", String(UInt32.max)],
        workingDirectory: fixture.root,
        environment: [:], timeoutMilliseconds: 10_000, maxOutputBytes: 256)
      #expect(status.exitCode == -1 && !status.timedOut)
    }

    @Test(arguments: ["timeout", "cancel", "root_exit"])
    func joinsTheEntireOwnedProcessTree(reason: String) async throws {
      let fixture = try WindowsCommandFixture()
      defer { fixture.cleanup() }
      let task = Task {
        try await fixture.run(
          [reason == "root_exit" ? "tree_exit" : "tree", fixture.root.path],
          timeout: reason == "timeout" ? 5_000 : 20_000)
      }
      defer { task.cancel() }
      try await fixture.waitFor("root")
      let handles = try ["root", "branch", "leaf"].map { try fixture.openProcess($0) }
      defer { for handle in handles { CloseHandle(handle) } }
      if reason == "cancel" { task.cancel() }
      if reason == "root_exit" {
        try Data().write(to: fixture.root.appendingPathComponent("release"))
      }
      do {
        let value = try await task.value
        #expect(reason != "cancel")
        #expect(value.timedOut == (reason == "timeout"))
        if reason == "root_exit" { #expect(value.exitCode == 0) }
      } catch is CancellationError { #expect(reason == "cancel") }
      for handle in handles { #expect(WaitForSingleObject(handle, 0) == DWORD(WAIT_OBJECT_0)) }
    }

    @Test
    func cancellationDoesNotStopAnotherInvocation() async throws {
      let first = try WindowsCommandFixture()
      let second = try WindowsCommandFixture()
      defer {
        first.cleanup()
        second.cleanup()
      }
      let runner = ProcessCommandRunner()
      let a = Task {
        try await first.run(["tree", first.root.path], runner: runner, timeout: 20_000)
      }
      let b = Task {
        try await second.run(["tree_exit", second.root.path], runner: runner, timeout: 20_000)
      }
      defer {
        a.cancel()
        b.cancel()
      }
      try await first.waitFor("root")
      try await second.waitFor("root")
      let other = try second.openProcess("leaf")
      defer { CloseHandle(other) }
      a.cancel()
      do {
        _ = try await a.value
        Issue.record("Cancelled command returned success.")
      } catch is CancellationError {}
      #expect(WaitForSingleObject(other, 0) == DWORD(WAIT_TIMEOUT))
      try Data().write(to: second.root.appendingPathComponent("release"))
      #expect(try await b.value.exitCode == 0)
      #expect(WaitForSingleObject(other, 0) == DWORD(WAIT_OBJECT_0))
    }

    @Test
    func rejectsInvalidInputAndPrecancelledCallsBeforeLaunching() async throws {
      let fixture = try WindowsCommandFixture()
      defer { fixture.cleanup() }
      await #expect(throws: CommandRunnerError.self) {
        try await fixture.run(["echo", "bad\0argument"])
      }
      await #expect(throws: CommandRunnerError.self) {
        try await fixture.run(["echo"], environment: ["NAME": "one", "name": "two"])
      }
      await #expect(throws: CommandRunnerError.self) {
        try await fixture.run(["echo"], environment: ["NAME": "bad\0value"])
      }
      let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await fixture.run(["leaf", fixture.root.path])
      }
      do {
        _ = try await task.value
        Issue.record("Precancelled command returned success.")
      } catch is CancellationError {}
      #expect(
        !FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("leaf").path))
    }
  }

  private struct WindowsCommandFixture: Sendable {
    let root: URL
    let executable: String

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("command-测试-\(UUID())")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let binary = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        .appendingPathComponent("PlatformProcessFixture.exe")
      executable = try #require(WindowsFilePath.native(binary))
      #expect(FileManager.default.fileExists(atPath: binary.path))
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func run(
      _ arguments: [String], runner: ProcessCommandRunner = ProcessCommandRunner(),
      environment: [String: String] = [:], timeout: Int = 10_000, limit: Int = 65_536
    ) async throws -> CommandDataResult {
      try await runner.runDataAsync(
        executable: executable, arguments: arguments, workingDirectory: root,
        environment: environment, timeoutMilliseconds: timeout, maxOutputBytes: limit)
    }

    func waitFor(_ file: String) async throws {
      let deadline = ContinuousClock.now.advanced(by: .seconds(10))
      while !FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path) {
        guard ContinuousClock.now < deadline else {
          throw CommandRunnerError.launchFailed("Native process fixture did not become ready.")
        }
        try await Task.sleep(for: .milliseconds(10))
      }
    }

    func openProcess(_ file: String) throws -> HANDLE {
      let pid = try #require(
        DWORD(String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)))
      return try #require(OpenProcess(DWORD(SYNCHRONIZE), false, pid))
    }
  }
#endif
