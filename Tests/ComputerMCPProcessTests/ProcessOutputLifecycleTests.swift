import ComputerMCPPlatform
import ComputerMCPTestSupport
import Foundation
import Testing

@testable import ComputerMCPProcess

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

@Suite(.nativeIntegration)
struct ProcessOutputLifecycleTests {
  enum SourceState: CaseIterable, Sendable {
    case inactive, active, suspended
  }

  @Test(arguments: SourceState.allCases)
  func sourceOwnsDescriptorUntilCancellationCompletes(_ state: SourceState) async throws {
    let pipe = Pipe()
    let handle = pipe.fileHandleForReading
    let descriptor = handle.fileDescriptor
    let queue = DispatchQueue(label: "test.output-source-cancellation")
    queue.suspend()
    var source: ProcessOutputSource? = ProcessOutputSource(handle: handle, queue: queue) {}
    if state != .inactive { source?.resume() }
    if state == .suspended { source?.suspend() }
    source?.cancel()
    source?.cancel()
    #expect(source?.isSuspended == false)
    let pendingSource = WeakReference(source)
    source = nil
    #expect(pendingSource.value != nil)
    #expect(fcntl(descriptor, F_GETFD) >= 0)
    queue.resume()
    try pipe.fileHandleForWriting.close()

    let deadline = ContinuousClock.now + .seconds(2)
    while pendingSource.value != nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    #expect(pendingSource.value == nil)
    #expect(throws: (any Error).self) { try handle.read(upToCount: 1) }
  }

  enum Shutdown: CaseIterable, Sendable {
    case endOfFile, stop, drain, consumerFailure, deinitialize
  }

  @Test(arguments: Shutdown.allCases)
  func shutdownWhileConsuming(_ shutdown: Shutdown) async throws {
    let pipe = Pipe()
    let started = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    defer { release.continuation.finish() }
    let consumed = AsyncStream<Void>.makeStream()
    let output = Output()
    var reader: ProcessOutputReader? = try ProcessOutputReader(
      handle: pipe.fileHandleForReading,
      consume: { data in
        await output.append(data)
        started.continuation.finish()
        for await _ in release.stream {}
        consumed.continuation.finish()
        if shutdown == .consumerFailure { throw ConsumerFailure() }
      },
      onError: { _ in await output.recordError() }
    )
    reader?.start()
    try pipe.fileHandleForWriting.write(contentsOf: Data("first".utf8))
    try await withinDeadline {
      for await _ in started.stream {}
    }
    // EOF arrives while the source is suspended and its consumer cannot yet resume it.
    try pipe.fileHandleForWriting.write(contentsOf: Data("last".utf8))
    try pipe.fileHandleForWriting.close()
    if shutdown == .deinitialize {
      let pendingReader = WeakReference(reader)
      reader = nil
      // The event callback may still retain the reader after it enqueues the consumer.
      let deadline = ContinuousClock.now + .seconds(2)
      while pendingReader.value != nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(1))
      }
      #expect(pendingReader.value == nil)
    }
    let activeReader = reader
    try await withinDeadline {
      if shutdown == .stop || shutdown == .drain {
        let stoppingStarted = AsyncStream<Void>.makeStream()
        async let stopping: Void =
          activeReader?.stop(
            drainRemainingOutput: shutdown == .drain,
            onStopping: { stoppingStarted.continuation.finish() }) ?? ()
        for await _ in stoppingStarted.stream {}
        release.continuation.finish()
        await stopping
      } else {
        release.continuation.finish()
        await activeReader?.waitForEnd()
      }
      for await _ in consumed.stream {}
    }
    let data = await output.data
    if shutdown == .endOfFile || shutdown == .drain {
      #expect(data == Data("firstlast".utf8))
    } else {
      #expect(data == Data("first".utf8))
    }
    #expect(await output.errors == (shutdown == .consumerFailure ? 1 : 0))
  }

  @Test
  func deadlineDoesNotWaitForStalledOperation() async throws {
    let blocking = BlockingOperationExecutor(label: "test.deadline-stalled-operation")
    let release = DispatchSemaphore(value: 0)
    let started = AsyncStream<Void>.makeStream()
    let completed = AsyncStream<Void>.makeStream()
    var timedOut = false
    do {
      defer { release.signal() }
      await withKnownIssue("The deadline reports that stalled work may leak.") {
        do {
          try await withinDeadline(timeout: .milliseconds(50)) {
            try await blocking.perform {
              started.continuation.finish()
              release.wait()
            }
            completed.continuation.finish()
          }
        } catch is DeadlineExceeded {
          timedOut = true
        } catch {
          Issue.record(error)
        }
      }
      #expect(timedOut)
      try await withinDeadline {
        for await _ in started.stream {}
      }
    }
    try await withinDeadline {
      for await _ in completed.stream {}
    }
  }

  @Test
  func parallelShortLivedPipes() async throws {
    try await withinDeadline {
      try await withThrowingTaskGroup(of: Void.self) { group in
        for lane in 0..<8 {
          group.addTask {
            let blocking = BlockingOperationExecutor(label: "test.output-churn.\(lane)")
            for _ in 0..<64 {
              try Task.checkCancellation()
              let payload = Data(repeating: UInt8(lane), count: 256)
              let collector = OutputCollector(limit: 64)
              try collector.pipe.fileHandleForWriting.write(contentsOf: payload)
              try collector.pipe.fileHandleForWriting.close()
              try await blocking.perform { collector.stop(processHasExited: true) }
              #expect(collector.dataValue == payload.prefix(64))
              #expect(collector.truncated)

              let pipe = Pipe()
              let output = Output()
              let reader = try ProcessOutputReader(
                handle: pipe.fileHandleForReading,
                consume: { await output.append($0) },
                onError: { _ in await output.recordError() })
              reader.start()
              try pipe.fileHandleForWriting.write(contentsOf: payload)
              try pipe.fileHandleForWriting.close()
              await reader.waitForEnd()
              await reader.stop(drainRemainingOutput: true)
              #expect(await output.data == payload)
              #expect(await output.errors == 0)
            }
          }
        }
        try await group.waitForAll()
      }
    }
  }

  @Test
  func parallelShortLivedCommands() async throws {
    try await withinDeadline {
      try await withThrowingTaskGroup(of: Void.self) { group in
        for lane in 0..<8 {
          group.addTask {
            let blocking = BlockingOperationExecutor(label: "test.command-churn.\(lane)")
            let runner = ManagedCommandRunner()
            for _ in 0..<16 {
              try Task.checkCancellation()
              let result = try await blocking.perform {
                try runner.run(
                  executable: "/bin/sh",
                  arguments: ["-c", "printf '%0128d' 0; printf '%0128d' 0 >&2; exit 7"],
                  workingDirectory: nil, environment: ["PATH": "/usr/bin:/bin"],
                  timeoutMilliseconds: 2000, maxOutputBytes: 64)
              }
              #expect(result.exitCode == 7 && !result.timedOut)
              #expect(result.stdout == String(repeating: "0", count: 64))
              #expect(result.stderr == String(repeating: "0", count: 64))
              #expect(result.stdoutTruncated && result.stderrTruncated)
            }
          }
        }
        try await group.waitForAll()
      }
    }
  }

  private struct ConsumerFailure: Error {}

  private final class WeakReference<Value: AnyObject> {
    weak var value: Value?
    init(_ value: Value?) { self.value = value }
  }

  private actor Output {
    var data = Data()
    var errors = 0
    func append(_ chunk: Data) { data.append(chunk) }
    func recordError() { errors += 1 }
  }

  private func withinDeadline(
    timeout: Duration = .seconds(10),
    _ operation: @escaping @Sendable () async throws -> Void
  ) async throws {
    var work: Task<Void, Never>?
    var timer: Task<Void, Never>?
    defer {
      work?.cancel()
      timer?.cancel()
    }
    try await withCheckedThrowingContinuation { continuation in
      let completion = DeadlineContinuation(continuation)
      work = Task {
        do {
          try await operation()
          await completion.resume(with: .success(()))
        } catch {
          await completion.resume(with: .failure(error))
        }
      }
      timer = Task {
        do {
          try await Task.sleep(for: timeout)
        } catch {
          return
        }
        await completion.resume(with: .failure(DeadlineExceeded()))
      }
    }
  }

  private actor DeadlineContinuation {
    private var continuation: CheckedContinuation<Void, any Error>?

    init(_ continuation: CheckedContinuation<Void, any Error>) {
      self.continuation = continuation
    }

    func resume(with result: Result<Void, any Error>) {
      guard let continuation else { return }
      self.continuation = nil
      if case .failure(let error) = result, error is DeadlineExceeded {
        Issue.record("Operation exceeded its deadline; stalled work may leak after cancellation.")
      }
      continuation.resume(with: result)
    }
  }

  private struct DeadlineExceeded: Error {}
}
