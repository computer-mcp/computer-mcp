import Foundation
import Testing
import os

@testable import ComputerMCP

@Suite(.timeLimit(.minutes(1)))
struct MCPCallCancellationTests {
  @Test(arguments: [false, true])
  func cancellationBeforeOrAfterRegistrationDeliversOnce(before: Bool) async throws {
    let cancellation = MCPCallCancellation()
    let calls = OSAllocatedUnfairLock(initialState: 0)
    if before { cancellation.cancel() }
    cancellation.install(
      onDeliveryFailure: { Issue.record("Unexpected delivery failure.") },
      { calls.withLock { $0 += 1 } })
    cancellation.cancel()
    cancellation.cancel()
    await cancellation.finish()
    #expect(calls.withLock { $0 } == 1)
    #expect(throws: CancellationError.self) { try cancellation.checkCancellation() }
    cancellation.cancel()
    await cancellation.finish()
    #expect(calls.withLock { $0 } == 1)
  }

  @Test
  func completedCallDoesNotSendALateCancellation() async {
    let cancellation = MCPCallCancellation()
    let calls = OSAllocatedUnfairLock(initialState: 0)
    cancellation.install(
      onDeliveryFailure: { Issue.record("Unexpected delivery failure.") },
      { calls.withLock { $0 += 1 } })
    await cancellation.finish()
    cancellation.cancel()
    #expect(calls.withLock { $0 } == 0)
  }

  @Test(arguments: [false, true])
  func failedOrStuckDeliveryRetiresAndJoinsTheWriter(stuck: Bool) async {
    let cancellation = MCPCallCancellation()
    let failures = OSAllocatedUnfairLock(initialState: 0)
    let completed = OSAllocatedUnfairLock(initialState: false)
    let writer = CancellationWriterGate()
    cancellation.install(
      onDeliveryFailure: {
        failures.withLock { $0 += 1 }
        Task { await writer.release() }
      },
      {
        defer { completed.withLock { $0 = true } }
        if stuck { await writer.wait() } else { throw DeliveryFailure.failed }
      })
    cancellation.cancel()
    await cancellation.finish()
    #expect(failures.withLock { $0 } == 1)
    #expect(completed.withLock { $0 })
  }

  @Test
  func alreadyCancelledCallCannotStartADownstreamProcess() async throws {
    let client = MCPProxyClient()
    let gate = CancellationWriterGate()
    let task = Task {
      await gate.wait()
      return try await client.callToolAsync(
        server: .init(id: "not-started", transport: .stdio, command: "/fixture/not-installed"),
        name: "wait", arguments: .object([:]), requestID: nil)
    }
    task.cancel()
    await gate.release()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    let status = try client.connectionStatus(server: .init(id: "not-started", transport: .stdio))
    #expect(status.objectValue?["state"] == .string("not_started"))
    await client.shutdown()
  }

  private enum DeliveryFailure: Error { case failed }
}

private actor CancellationWriterGate {
  private var released = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    guard !released else { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func release() {
    released = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
}
