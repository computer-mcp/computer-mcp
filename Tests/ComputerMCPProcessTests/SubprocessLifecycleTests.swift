import ComputerMCPCore
import ComputerMCPPlatformPOSIX
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPProcess

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

@Suite(.nativeIntegration, .timeLimit(.minutes(1)))
struct SubprocessLifecycleTests {
  @Test
  func managedWriterRemainsOpenAcrossRequestsAndDeliversEOF() async throws {
    let process = try ManagedLineProcess(
      configuration: .init(
        executable: "/bin/sh",
        arguments: [
          "-c", #"while IFS= read -r line; do printf '%s\n' "$line"; done; printf 'eof\n'"#,
        ],
        workingDirectory: FileManager.default.temporaryDirectory,
        terminationGraceMilliseconds: 2_000))
    do {
      var lines = process.inboundLines.makeAsyncIterator()
      for line in ["first", "second"] {
        try await process.sendLine(line)
        #expect(try await lines.next() == line)
      }
      await process.close()
      #expect(try await lines.next() == "eof")
      #expect(try await lines.next() == nil)
      let result = await process.snapshot()
      #expect(result.hasExited && result.exitCode == 0)
      #expect(!result.terminationEscalated && result.pendingWrites == 0)
    } catch {
      await process.close()
      throw error
    }
  }

  @Test
  func managedCloseReleasesBlockedWriterAndKillsStubbornGroup() async throws {
    let process = try ManagedLineProcess(
      configuration: .init(
        executable: "/bin/sh",
        arguments: [
          "-c",
          #"trap '' TERM; /bin/sh -c 'trap "" TERM; sleep 30' & printf '%s\n' "$!"; wait"#,
        ],
        workingDirectory: FileManager.default.temporaryDirectory,
        terminationGraceMilliseconds: 100, maximumMessageBytes: 2_097_152))
    do {
      var lines = process.inboundLines.makeAsyncIterator()
      let ready = try #require(try await lines.next())
      let child = try #require(Int32(ready))
      let writing = Task { try await process.sendLine(String(repeating: "x", count: 1_048_576)) }
      let deadline = ContinuousClock.now + .seconds(2)
      while await process.snapshot().pendingWrites == 0, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(await process.snapshot().pendingWrites == 1)
      async let first: Void = process.close()
      async let second: Void = process.close()
      _ = await (first, second)
      guard case .failure = await writing.result else {
        Issue.record("The blocked write unexpectedly completed.")
        return
      }
      let result = await process.snapshot()
      #expect(result.hasExited && result.terminationEscalated)
      #expect(result.pendingWrites == 0)
      #expect(ProcessTable.hasExited(child))
      #expect(ProcessTable.hasExited(try #require(result.processID)))
      #expect(kill(try #require(result.supervisorProcessID), 0) == -1 && errno == ESRCH)
    } catch {
      await process.close()
      throw error
    }
  }

  @Test(arguments: [false, true])
  func managedOutputRejectsOversizedFrames(newline: Bool) async throws {
    let process = try ManagedLineProcess(
      configuration: .init(
        executable: "/bin/sh",
        arguments: ["-c", newline ? "printf '%065d\\n' 0" : "printf '%065d' 0"],
        workingDirectory: FileManager.default.temporaryDirectory,
        terminationGraceMilliseconds: 100, maximumMessageBytes: 64))
    await #expect(throws: (any Error).self) {
      for try await _ in process.inboundLines { Issue.record("Oversized frame was delivered.") }
    }
    await process.close()
    #expect(await process.snapshot().hasExited)
    #expect(await process.snapshot().lastError?.contains("64 bytes") == true)
  }

  @Test
  func shellWriterRemainsOpenUntilExplicitEOF() async throws {
    let runtime = SubprocessShellRuntime()
    let blocking = BlockingOperationExecutor(label: "test.shell-writer-lifetime")
    do {
      let id = try await blocking.perform {
        try runtime.spawn(
          request: .init(mode: .argv, executable: "/bin/cat"),
          defaultShell: "/bin/sh", defaultWorkingDirectory: FileManager.default.temporaryDirectory,
          timeoutMilliseconds: nil, maxOutputBytes: 8, maxSessions: 1,
          terminationGraceMilliseconds: 100)
      }
      for text in ["first", "second"] {
        let result = try await blocking.perform {
          try runtime.write(sessionID: id, data: Data(text.utf8), close: false)
        }
        #expect(result.bytesWritten == text.utf8.count && !result.inputClosed)
      }
      let closed = try await blocking.perform {
        try runtime.write(sessionID: id, data: Data(), close: true)
      }
      #expect(closed.bytesWritten == 0 && closed.inputClosed)
      let result = try await blocking.perform {
        try runtime.wait(
          sessionID: id, timeoutMilliseconds: 2_000, maxReadBytes: 8, encoding: .utf8)
      }
      #expect(result.exitCode == 0 && result.streamErrors.isEmpty)
      #expect(result.stdout.text == "stsecond")
      #expect(result.stdout.startCursor == 3 && result.stdout.endCursor == 11)
      #expect(result.stdout.truncated && result.stdout.missedBytes)
      await runtime.shutdown()
    } catch {
      await runtime.shutdown()
      throw error
    }
  }

  @Test
  func shellCancellationReleasesBlockedWriterBeforeShutdownReturns() async throws {
    let runtime = SubprocessShellRuntime()
    let blocking = BlockingOperationExecutor(label: "test.shell-blocked-writer")
    do {
      let id = try await blocking.perform {
        try runtime.spawn(
          request: .init(
            mode: .argv, executable: "/bin/sh", argv: ["-c", "trap '' TERM; exec sleep 30"]),
          defaultShell: "/bin/sh", defaultWorkingDirectory: FileManager.default.temporaryDirectory,
          timeoutMilliseconds: nil, maxOutputBytes: 64, maxSessions: 1,
          terminationGraceMilliseconds: 100)
      }
      let writing = Task {
        try await blocking.perform {
          try runtime.write(
            sessionID: id, data: Data(repeating: 120, count: 1_048_576), close: false)
        }
      }
      // Let the write exceed pipe capacity before requesting cancellation.
      try await Task.sleep(for: .milliseconds(100))
      #expect(try runtime.cancel(sessionID: id).cancellationRequested)
      await runtime.shutdown()
      guard case .failure = await writing.result else {
        Issue.record("The blocked write unexpectedly completed.")
        return
      }
      let result = try runtime.read(
        sessionID: id, stdoutCursor: 0, stderrCursor: 0, maxReadBytes: 64, encoding: .utf8)
      #expect(!result.isRunning && result.cancelled && result.signal != nil)
      #expect(ProcessTable.hasExited(try #require(result.processID)))
    } catch {
      await runtime.shutdown()
      throw error
    }
  }

  @Test
  func subprocessChildStartsWithDefaultSIGPIPE() async throws {
    let runtime = SubprocessShellRuntime()
    do {
      let result = try await BlockingOperationExecutor(label: "test.subprocess-sigpipe").perform {
        try runtime.run(
          request: .init(
            mode: .argv, executable: "/bin/sh", argv: ["-c", "kill -PIPE $$; echo survived"]),
          defaultShell: "/bin/sh", defaultWorkingDirectory: FileManager.default.temporaryDirectory,
          timeoutMilliseconds: 2_000, maxOutputBytes: 64, maxSessions: 1,
          terminationGraceMilliseconds: 100)
      }
      #expect(!result.isRunning && !result.timedOut)
      #expect(result.signal == SIGPIPE)
      #expect(result.stdout.text == "")
      await runtime.shutdown()
    } catch {
      await runtime.shutdown()
      throw error
    }
  }

  @Test
  func foundationChildStartsWithDefaultSIGPIPE() async throws {
    let runtime = SubprocessShellRuntime()
    let result = try await BlockingOperationExecutor(label: "test.foundation-sigpipe").perform {
      try ProcessCommandRunner().run(
        executable: "/bin/sh", arguments: ["-c", "kill -PIPE $$; echo survived"],
        workingDirectory: FileManager.default.temporaryDirectory, environment: [:],
        timeoutMilliseconds: 2_000, maxOutputBytes: 64)
    }
    #expect(!result.timedOut)
    #expect(result.exitCode == SIGPIPE)
    #expect(result.stdout.isEmpty)
    await runtime.shutdown()
  }

  #if canImport(Darwin)
    @Test
    func inheritedDescriptorIsCopiedBeforeCallerClosesAndReusesIt() async throws {
      let inherited = Pipe()
      let process = try ManagedLineProcess(
        configuration: .init(
          executable: "/bin/sh",
          arguments: ["-c", "printf inherited >&3; exec 3>&-; while read line; do :; done"],
          workingDirectory: FileManager.default.temporaryDirectory,
          terminationGraceMilliseconds: 100,
          inheritedDescriptors: [3: inherited.fileHandleForWriting]))
      try inherited.fileHandleForWriting.close()
      let replacement = Pipe()
      do {
        let data = try await BlockingOperationExecutor(label: "test.inherited-descriptor").perform {
          try inherited.fileHandleForReading.readToEnd()
        }
        #expect(data == Data("inherited".utf8))
        await process.close()
        try replacement.fileHandleForWriting.write(contentsOf: Data("still-owned".utf8))
        try replacement.fileHandleForWriting.close()
        #expect(try replacement.fileHandleForReading.readToEnd() == Data("still-owned".utf8))
      } catch {
        await process.close()
        throw error
      }
    }
  #endif
}
