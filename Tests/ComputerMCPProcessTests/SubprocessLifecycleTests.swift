import ComputerMCPCore
import ComputerMCPPlatformPOSIX
import ComputerMCPTestSupport
import Foundation
import Subprocess
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
  func managedOverlappingWritesDeliverCompleteFramesInOrder() async throws {
    let child = try GatedInputChild()
    let process = try ManagedLineProcess(
      configuration: .init(
        executable: "/bin/sh", arguments: ["-c", GatedInputChild.command],
        workingDirectory: child.directory.url,
        terminationGraceMilliseconds: 100, maximumMessageBytes: 2_097_152))
    do {
      var lines = process.inboundLines.makeAsyncIterator()
      try #require(try await lines.next() == "ready")
      let payloads = ["a", "b", "c"].map { String(repeating: $0, count: 1_048_576) }
      var writes: [Task<Void, Error>] = []
      for payload in payloads {
        writes.append(Task { try await process.sendLine(payload) })
        let count = writes.count
        try await waitUntil { await process.snapshot().pendingWrites == count }
      }
      try await child.releaseInput()
      for write in writes { try await write.value }
      for payload in payloads {
        #expect(try await lines.next() == payload)
      }
      let result = await process.snapshot()
      #expect(result.pendingWrites == 0 && result.state == .running && !result.hasExited)
      #expect(kill(try #require(result.processID), 0) == 0)
      await process.close()
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
      try await waitUntil { await process.snapshot().pendingWrites == 1 }
      let queued = Task { try await process.sendLine("queued") }
      try await waitUntil { await process.snapshot().pendingWrites == 2 }
      let cleanupStarted = ContinuousClock.now
      async let first: Void = process.close()
      async let second: Void = process.close()
      _ = await (first, second)
      switch await writing.result {
      case .failure(ManagedLineProcessError.closed):
        break
      case .failure(let error as SubprocessError):
        #expect(error.code == .failedToWriteToSubprocess)
      case let result:
        Issue.record("Expected a blocked input write failure, got \(result).")
      }
      switch await queued.result {
      case .failure(ManagedLineProcessError.closed):
        break
      case let result:
        Issue.record("Expected a queued input write to fail as closed, got \(result).")
      }
      #expect(cleanupStarted.duration(to: .now) < .seconds(10))
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

  @Test(arguments: [false, true])
  func shellOverlappingWritesDeliverCompletePayloadsBeforeEOF(closeWithData: Bool) async throws {
    let child = try GatedInputChild()
    let directory = child.directory.url
    let runtime = SubprocessShellRuntime()
    let blocking = BlockingOperationExecutor(label: "test.shell-write-order", serial: false)
    let payloads = ["a", "b", "c"].map {
      Data((String(repeating: $0, count: 1_048_576) + "\n").utf8)
    }
    let expected =
      Data("ready\n".utf8) + payloads.reduce(into: Data()) { $0.append($1) }
      + Data("eof\n".utf8)
    let outputBytes = expected.count
    do {
      let id = try await blocking.perform {
        try runtime.spawn(
          request: .init(
            mode: .argv, executable: "/bin/sh", argv: ["-c", GatedInputChild.command]),
          defaultShell: "/bin/sh", defaultWorkingDirectory: directory,
          timeoutMilliseconds: nil, maxOutputBytes: outputBytes, maxSessions: 1,
          terminationGraceMilliseconds: 100)
      }
      try await waitUntil {
        try runtime.read(
          sessionID: id, stdoutCursor: 0, stderrCursor: 0, maxReadBytes: 0, encoding: .utf8
        ).stdout.endCursor == 6
      }
      var writes: [Task<ShellWriteResult, Error>] = []
      for (index, payload) in payloads.enumerated() {
        let close = closeWithData && index == payloads.count - 1
        writes.append(
          Task {
            try await blocking.perform {
              try runtime.write(sessionID: id, data: payload, close: close)
            }
          })
        let count = writes.count
        try await waitUntil { try runtime.pendingWrites(sessionID: id) == count }
      }
      if !closeWithData {
        writes.append(
          Task {
            try await blocking.perform {
              try runtime.write(sessionID: id, data: Data(), close: true)
            }
          })
        try await waitUntil { try runtime.pendingWrites(sessionID: id) == 4 }
      }
      try await child.releaseInput()
      for (index, write) in writes.enumerated() {
        let result = try await write.value
        #expect(result.bytesWritten == (index < payloads.count ? payloads[index].count : 0))
        #expect(result.inputClosed == (index == writes.count - 1))
      }
      try await waitUntil {
        try runtime.read(
          sessionID: id, stdoutCursor: 0, stderrCursor: 0, maxReadBytes: 0, encoding: .utf8
        ).stdout.endCursor == outputBytes
      }
      let result = try runtime.read(
        sessionID: id, stdoutCursor: 0, stderrCursor: 0,
        maxReadBytes: outputBytes, encoding: .utf8)
      #expect(result.stdout.text == String(decoding: expected, as: UTF8.self))
      #expect(result.isRunning && result.streamErrors.isEmpty)
      #expect(kill(try #require(result.processID), 0) == 0)
      #expect(try runtime.pendingWrites(sessionID: id) == 0)
      await runtime.shutdown()
    } catch {
      await runtime.shutdown()
      throw error
    }
  }

  @Test
  func shellCancellationReleasesBlockedWriterBeforeShutdownReturns() async throws {
    let runtime = SubprocessShellRuntime()
    let blocking = BlockingOperationExecutor(label: "test.shell-blocked-writer", serial: false)
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
      try await waitUntil { try runtime.pendingWrites(sessionID: id) == 1 }
      let queued = Task {
        try await blocking.perform {
          try runtime.write(sessionID: id, data: Data("queued".utf8), close: true)
        }
      }
      try await waitUntil { try runtime.pendingWrites(sessionID: id) == 2 }
      let cleanupStarted = ContinuousClock.now
      #expect(try runtime.cancel(sessionID: id).cancellationRequested)
      await runtime.shutdown()
      switch await writing.result {
      case .failure(let error as ShellRuntimeError):
        #expect(error == .sessionNotRunning(id))
      case .failure(let error as SubprocessError):
        #expect(error.code == .failedToWriteToSubprocess)
      case let result:
        Issue.record("Expected a blocked input write failure, got \(result).")
      }
      switch await queued.result {
      case .failure(let error as ShellRuntimeError):
        #expect(error == .sessionNotRunning(id))
      case let result:
        Issue.record("Expected a queued input write to fail as not running, got \(result).")
      }
      #expect(cleanupStarted.duration(to: .now) < .seconds(10))
      #expect(try runtime.pendingWrites(sessionID: id) == 0)
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

  private func waitUntil(_ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(20)
    while !(try await condition()) {
      try #require(ContinuousClock.now < deadline, "Timed out waiting for child-input state.")
      try Task.checkCancellation()
      await Task.yield()
    }
  }
}

private struct GatedInputChild {
  let directory: ScopedTemporaryDirectory

  static let command = """
    printf 'ready\\n'
    IFS= read -r gate < input-gate
    /bin/cat
    printf 'eof\\n'
    IFS= read -r gate < exit-gate
    """

  init() throws {
    directory = try ScopedTemporaryDirectory()
    for name in ["input-gate", "exit-gate"] {
      try #require(mkfifo(directory.url.appendingPathComponent(name).path, 0o600) == 0)
    }
  }

  func releaseInput() async throws {
    let url = directory.url.appendingPathComponent("input-gate")
    try await BlockingOperationExecutor(label: "test.child-input-gate").perform {
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      try handle.write(contentsOf: Data("read\n".utf8))
    }
  }
}
