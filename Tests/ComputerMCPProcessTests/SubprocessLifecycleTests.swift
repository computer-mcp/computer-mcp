import ComputerMCPCore
import ComputerMCPPlatformPOSIX
import ComputerMCPTestSupport
import Foundation
import Subprocess
import Testing

@testable import ComputerMCPProcess

#if os(macOS)
  import ComputerMCPDarwinTestSupport
#endif

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
        if count == 1 {
          try await waitUntil {
            await process.inputSnapshot().writeInProgress && child.hasSeenInput
          }
        }
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
    let childInput = try GatedInputChild()
    let events = InputEvents()
    let settlement = InputSettlement()
    defer { settlement.release() }
    let process = try ManagedLineProcess(
      configuration: .init(
        executable: "/bin/sh",
        arguments: [
          "-c",
          #"trap '' TERM; /bin/sh -c 'trap "" TERM; sleep 30' & printf '%s\n' "$!"; /bin/dd bs=1 count=1 of=input-prefix 2>/dev/null; printf seen > input-seen; wait"#,
        ],
        workingDirectory: childInput.directory.url,
        terminationGraceMilliseconds: 100, maximumMessageBytes: 2_097_152))
    await process.observeInput { events.append($0) }
    await process.beforeInputWriteSettles { await settlement.pause() }
    do {
      var lines = process.inboundLines.makeAsyncIterator()
      let ready = try #require(try await lines.next())
      let child = try #require(Int32(ready))
      let writing = Task { try await process.sendLine(String(repeating: "x", count: 1_048_576)) }
      try await waitUntil {
        await process.inputSnapshot().writeInProgress && childInput.hasSeenInput
      }
      let queued = Task { try await process.sendLine("queued") }
      try await waitUntil { await process.snapshot().pendingWrites == 2 }
      let cleanupStarted = ContinuousClock.now
      let closing = Task {
        async let first: Void = process.close()
        async let second: Void = process.close()
        _ = await (first, second)
      }
      try await waitUntil {
        settlement.hasEntered && events.reachedTeardown
      }
      #expect(!events.values.contains(.finishStarted))
      #expect(!events.values.contains(.bodyReturning))
      switch await queued.result {
      case .failure(ManagedLineProcessError.closed): break
      case let result:
        Issue.record("Expected queued input to fail before settlement, got \(result).")
      }
      #expect(await process.inputSnapshot().pendingWrites == 1)
      settlement.release()
      await closing.value
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
      events.expectSettledBeforeFinish()
      #expect(ProcessTable.hasExited(child))
      #expect(ProcessTable.hasExited(try #require(result.processID)))
      #expect(kill(try #require(result.supervisorProcessID), 0) == -1 && errno == ESRCH)
    } catch {
      settlement.release()
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
    let runtime = ShellSessionRuntime(launcher: testExecutionLauncher())
    let blocking = BlockingOperationExecutor(label: "test.shell-writer-lifetime")
    do {
      let id = try await blocking.perform {
        try runtime.spawn(
          request: .init(mode: .argv, executable: "/bin/cat"),
          defaultShell: "/bin/sh", defaultWorkingDirectory: FileManager.default.temporaryDirectory,
          timeoutMilliseconds: nil, maxOutputBytes: 8, maxSessions: 1)
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
    let runtime = ShellSessionRuntime(launcher: testExecutionLauncher())
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
          timeoutMilliseconds: nil, maxOutputBytes: outputBytes, maxSessions: 1)
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
        if count == 1 {
          try await waitUntil {
            try runtime.inputSnapshot(sessionID: id).writeInProgress && child.hasSeenInput
          }
        }
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
    let child = try GatedInputChild()
    let directory = child.directory.url
    let events = InputEvents()
    let settlement = InputSettlement()
    defer { settlement.release() }
    let runtime = ShellSessionRuntime(launcher: testExecutionLauncher())
    let blocking = BlockingOperationExecutor(label: "test.shell-blocked-writer", serial: false)
    do {
      let id = try await blocking.perform {
        try runtime.spawn(
          request: .init(
            mode: .argv, executable: "/bin/sh",
            argv: [
              "-c",
              "trap '' TERM; printf 'ready\\n'; /bin/dd bs=1 count=1 of=input-prefix 2>/dev/null; printf seen > input-seen; exec sleep 30",
            ]),
          defaultShell: "/bin/sh", defaultWorkingDirectory: directory,
          timeoutMilliseconds: nil, maxOutputBytes: 64, maxSessions: 1)
      }
      try await runtime.observeInput(sessionID: id) { events.append($0) }
      try await runtime.beforeInputWriteSettles(sessionID: id) { await settlement.pause() }
      try await waitUntil {
        try runtime.read(
          sessionID: id, stdoutCursor: 0, stderrCursor: 0, maxReadBytes: 64, encoding: .utf8
        ).stdout.text == "ready\n"
      }
      let writing = Task {
        try await runtime.writeAsync(
          sessionID: id, data: Data(repeating: 120, count: 1_048_576), close: false)
      }
      try await waitUntil {
        try runtime.inputSnapshot(sessionID: id).writeInProgress && child.hasSeenInput
      }
      let queued = Task {
        try await blocking.perform {
          try runtime.write(sessionID: id, data: Data("queued".utf8), close: true)
        }
      }
      try await waitUntil { try runtime.pendingWrites(sessionID: id) == 2 }
      let cleanupStarted = ContinuousClock.now
      #expect(try runtime.cancel(sessionID: id).cancellationRequested)
      let shuttingDown = Task { await runtime.shutdown() }
      try await waitUntil { settlement.hasEntered && events.reachedTeardown }
      #expect(!events.values.contains(.finishStarted))
      #expect(!events.values.contains(.bodyReturning))
      switch await queued.result {
      case .failure(let error as ShellRuntimeError): #expect(error == .sessionNotRunning(id))
      case let result:
        Issue.record("Expected queued input to fail before settlement, got \(result).")
      }
      #expect(try runtime.pendingWrites(sessionID: id) == 1)
      settlement.release()
      await shuttingDown.value
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
      events.expectSettledBeforeFinish()
      let result = try runtime.read(
        sessionID: id, stdoutCursor: 0, stderrCursor: 0, maxReadBytes: 64, encoding: .utf8)
      #expect(!result.isRunning && result.cancelled && result.signal != nil)
      #expect(ProcessTable.hasExited(try #require(result.processID)))
    } catch {
      settlement.release()
      await runtime.shutdown()
      throw error
    }
  }

  enum InputOwner: CaseIterable, Sendable {
    case managed, shell
  }

  @Test(arguments: InputOwner.allCases)
  func cancelledQueuedWriterLeavesBeforeBlockedWriteIsReleased(_ owner: InputOwner) async throws {
    let child = try GatedInputChild()
    let client = try await InputClient.start(owner, directory: child.directory.url)
    do {
      try await waitUntil { try await client.output() == "ready\n" }
      let payload = String(repeating: "a", count: 1_048_576)
      let active = Task { try await client.write(payload) }
      try await waitUntil { try await client.snapshot().writeInProgress && child.hasSeenInput }
      let cancelled = Task { try await client.write("cancelled") }
      try await waitUntil { try await client.snapshot().pendingWrites == 2 }
      cancelled.cancel()
      // The child still cannot read the frame, so this requires prompt queue removal.
      try await waitUntil { try await client.snapshot().pendingWrites == 1 }
      await #expect(throws: CancellationError.self) { try await cancelled.value }
      #expect(try await client.snapshot().writeInProgress)
      #expect(try await client.output() == "ready\n")
      try await child.releaseInput()
      try await active.value
      try await client.write("next")
      let expected = "ready\n" + payload + "\nnext\n"
      try await waitUntil { try await client.output().utf8.count == expected.utf8.count }
      #expect(try await client.output() == expected)
      #expect(try await client.snapshot().pendingWrites == 0)
      await client.shutdown()
    } catch {
      await client.shutdown()
      throw error
    }
  }

  @Test(arguments: InputOwner.allCases)
  func cancelledActiveWriterStillDeliversItsWholeFrame(_ owner: InputOwner) async throws {
    let child = try GatedInputChild()
    let client = try await InputClient.start(owner, directory: child.directory.url)
    do {
      try await waitUntil { try await client.output() == "ready\n" }
      let payload = String(repeating: "a", count: 1_048_576)
      let active = Task { try await client.write(payload) }
      try await waitUntil { try await client.snapshot().writeInProgress && child.hasSeenInput }
      active.cancel()
      let next = Task { try await client.write("next") }
      try await waitUntil { try await client.snapshot().pendingWrites == 2 }
      try await child.releaseInput()
      try await active.value
      try await next.value
      let expected = "ready\n" + payload + "\nnext\n"
      try await waitUntil { try await client.output().utf8.count == expected.utf8.count }
      #expect(try await client.output() == expected)
      #expect(try await client.snapshot().pendingWrites == 0)
      #expect(try await client.snapshot().retired == false)
      await client.shutdown()
    } catch {
      await client.shutdown()
      throw error
    }
  }

  @Test(arguments: InputOwner.allCases)
  func alreadyCancelledWriterNeverEntersInput(_ owner: InputOwner) async throws {
    let child = try GatedInputChild()
    let client = try await InputClient.start(owner, directory: child.directory.url)
    do {
      try await waitUntil { try await client.output() == "ready\n" }
      let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await client.write("cancelled")
      }
      await #expect(throws: CancellationError.self) { try await cancelled.value }
      #expect(try await client.snapshot().pendingWrites == 0)
      let next = Task { try await client.write("next") }
      try await waitUntil { child.hasSeenInput }
      try await child.releaseInput()
      try await next.value
      try await waitUntil { try await client.output() == "ready\nnext\n" }
      await client.shutdown()
    } catch {
      await client.shutdown()
      throw error
    }
  }

  @Test(arguments: InputOwner.allCases)
  func processExitDuringWriteRetiresInputBeforeQueuedWriter(_ owner: InputOwner) async throws {
    let child = try GatedInputChild()
    let directory = child.directory.url
    // A separate job retains stdin after the launcher exits. Its output is redirected,
    // so only process I/O cancellation, rather than EPIPE, can end the blocked write.
    let command = """
      set -m
      /bin/sh -c '/bin/dd bs=1 count=1 of=input-prefix 2>/dev/null; printf seen > input-seen; exec sleep 30' <&0 >/dev/null 2>&1 &
      printf '%s\\n' "$!" > holder.pid
      printf 'ready\\n'
      IFS= read -r gate < exit-gate
      """
    let client = try await InputClient.start(
      owner, directory: directory, executable: "/bin/bash", command: command)
    var holder: Int32?
    defer { if let holder { _ = kill(-holder, SIGKILL) } }
    do {
      try await waitUntil { try await client.output() == "ready\n" }
      let holderText = try String(
        contentsOf: directory.appendingPathComponent("holder.pid"), encoding: .utf8)
      let holderID = try #require(Int32(holderText.trimmingCharacters(in: .whitespacesAndNewlines)))
      holder = holderID
      #expect(getpgid(holderID) == holderID)
      let events = InputEvents()
      try await client.observe { events.append($0) }
      let active = Task { try await client.write(String(repeating: "a", count: 1_048_576)) }
      try await waitUntil { try await client.snapshot().writeInProgress && child.hasSeenInput }
      let queued = Task { try await client.write("queued", close: true) }
      try await waitUntil { try await client.snapshot().pendingWrites == 2 }
      try await child.releaseExit()
      await client.expectClosed(active)
      await client.expectClosed(queued)
      let state = try await client.snapshot()
      #expect(state.retired)
      #expect(try #require(state.lastWriteCount) > 0)
      #expect(try #require(state.lastWriteCount) < 1_048_577)
      #expect(state.pendingWrites == 0)
      let later = Task { try await client.write("later", close: true) }
      await client.expectClosed(later)
      #expect(try await client.output() == "ready\n")
      await client.shutdown()
      events.expectSettledBeforeFinish()
      #expect(events.values.filter { $0 == .writeStarted }.count == 1)
    } catch {
      await client.shutdown()
      throw error
    }
  }

  @Test
  func subprocessChildStartsWithDefaultSIGPIPE() async throws {
    let runtime = ShellSessionRuntime(launcher: testExecutionLauncher())
    do {
      let result = try await BlockingOperationExecutor(label: "test.subprocess-sigpipe").perform {
        try runtime.run(
          request: .init(
            mode: .argv, executable: "/bin/sh", argv: ["-c", "kill -PIPE $$; echo survived"]),
          defaultShell: "/bin/sh", defaultWorkingDirectory: FileManager.default.temporaryDirectory,
          timeoutMilliseconds: 2_000, maxOutputBytes: 64, maxSessions: 1)
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

  #if canImport(Darwin)
    /// Foundation's Process on Linux passes the spawning thread's signal mask and ignored
    /// dispositions to children; only Darwin's Process resets them.
    @Test
    func foundationChildStartsWithDefaultSIGPIPE() async throws {
      // Creating a runtime installs the broken-pipe handler before the child is spawned.
      let runtime = ShellSessionRuntime(launcher: testExecutionLauncher())
      let result = try await BlockingOperationExecutor(label: "test.foundation-sigpipe").perform {
        try ProcessCommandRunner(launcher: testExecutionLauncher()).run(
          executable: "/bin/sh", arguments: ["-c", "kill -PIPE $$; echo survived"],
          workingDirectory: FileManager.default.temporaryDirectory, environment: [:],
          timeoutMilliseconds: 2_000, maxOutputBytes: 64)
      }
      #expect(!result.timedOut)
      #expect(result.exitCode == SIGPIPE)
      #expect(result.stdout.isEmpty)
      await runtime.shutdown()
    }
  #endif

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
    /bin/dd bs=1 count=1 of=input-prefix 2>/dev/null
    printf seen > input-seen
    IFS= read -r gate < input-gate
    /bin/cat input-prefix
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

  var hasSeenInput: Bool {
    FileManager.default.fileExists(atPath: directory.url.appendingPathComponent("input-seen").path)
  }

  func releaseInput() async throws { try await release("input-gate") }

  func releaseExit() async throws { try await release("exit-gate") }

  private func release(_ name: String) async throws {
    let url = directory.url.appendingPathComponent(name)
    try await BlockingOperationExecutor(label: "test.child-input-gate").perform {
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      try handle.write(contentsOf: Data("read\n".utf8))
    }
  }
}

private final class InputEvents: @unchecked Sendable {
  // Hooks run on the input actor; the test reads the history concurrently.
  private let lock = NSLock()
  private var history: [ChildProcessInput.Event] = []
  var values: [ChildProcessInput.Event] { lock.withLock { history } }
  func append(_ event: ChildProcessInput.Event) { lock.withLock { history.append(event) } }

  var reachedTeardown: Bool {
    let events = values
    return events.contains(.teardownWaiting) || events.contains(.bodyReturning)
  }

  func expectSettledBeforeFinish() {
    let events = values
    let settled = events.firstIndex { if case .writeSettled = $0 { true } else { false } }
    let finishing = events.firstIndex(of: .finishStarted)
    let returning = events.firstIndex(of: .bodyReturning)
    #expect(settled != nil && finishing != nil && returning != nil)
    if let settled, let finishing, let returning {
      #expect(settled < finishing && finishing < returning)
    }
  }
}

private final class InputSettlement: @unchecked Sendable {
  private let lock = NSLock()
  private var entered = false
  private let gate = AsyncStream<Void>.makeStream()

  var hasEntered: Bool { lock.withLock { entered } }

  func pause() async {
    lock.withLock { entered = true }
    for await _ in gate.stream {}
  }

  func release() { gate.continuation.finish() }
}

private actor InputOutput {
  var text = ""
  func append(_ line: String) { text += line + "\n" }
}

private struct InputClient: Sendable {
  let write: @Sendable (String, Bool) async throws -> Void
  let snapshot: @Sendable () async throws -> ChildProcessInput.Snapshot
  let output: @Sendable () async throws -> String
  let observe:
    @Sendable (@escaping @Sendable (ChildProcessInput.Event) -> Void) async throws -> Void
  let shutdown: @Sendable () async -> Void
  let isClosed: @Sendable (any Error) -> Bool

  func write(_ line: String, close: Bool = false) async throws { try await write(line, close) }

  func expectClosed(_ task: Task<Void, any Error>) async {
    switch await task.result {
    case .failure(let error): #expect(isClosed(error))
    case .success: Issue.record("Expected child input to fail closed.")
    }
  }

  static func start(
    _ owner: SubprocessLifecycleTests.InputOwner, directory: URL,
    executable: String = "/bin/sh", command: String = GatedInputChild.command
  ) async throws -> Self {
    switch owner {
    case .managed:
      let process = try ManagedLineProcess(
        configuration: .init(
          executable: executable, arguments: ["-c", command], workingDirectory: directory,
          terminationGraceMilliseconds: 100, maximumMessageBytes: 2_097_152))
      let output = InputOutput()
      let reading = Task {
        do {
          for try await line in process.inboundLines { await output.append(line) }
        } catch { Issue.record(error) }
      }
      return .init(
        write: { line, _ in try await process.sendLine(line) },
        snapshot: { await process.inputSnapshot() },
        output: { await output.text },
        observe: { await process.observeInput($0) },
        shutdown: {
          await process.close()
          await reading.value
        },
        isClosed: { if case ManagedLineProcessError.closed = $0 { true } else { false } })
    case .shell:
      let runtime = ShellSessionRuntime(launcher: testExecutionLauncher())
      let id = try await BlockingOperationExecutor(label: "test.child-input-spawn").perform {
        try runtime.spawn(
          request: .init(mode: .argv, executable: executable, argv: ["-c", command]),
          defaultShell: "/bin/sh", defaultWorkingDirectory: directory,
          timeoutMilliseconds: nil, maxOutputBytes: 4_194_304, maxSessions: 1)
      }
      return .init(
        write: { line, close in
          _ = try await runtime.writeAsync(
            sessionID: id, data: Data((line + "\n").utf8), close: close)
        },
        snapshot: { try runtime.inputSnapshot(sessionID: id) },
        output: {
          try runtime.read(
            sessionID: id, stdoutCursor: 0, stderrCursor: 0,
            maxReadBytes: 4_194_304, encoding: .utf8
          ).stdout.text ?? ""
        },
        observe: { try await runtime.observeInput(sessionID: id, $0) },
        shutdown: { await runtime.shutdown() },
        isClosed: { ($0 as? ShellRuntimeError) == .sessionNotRunning(id) })
    }
  }
}
