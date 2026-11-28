import Foundation
import Testing

@testable import ComputerMCPGateway

struct MCPHostCallbackCancellationTests {
  @Test func cancellationSealsRacingAdmissionsButCompletionRetainsCreatedWork() throws {
    let revoked = CallbackRevocations()
    let lifetime = GatewayHostCallbackLifetime { revoked.add($0) }
    let admitted = UUID()
    try lifetime.register([admitted])
    lifetime.cancel()
    #expect(revoked.ids == [admitted])
    let racing = UUID()
    #expect(throws: CancellationError.self) { try lifetime.register([racing]) }
    #expect(revoked.ids == [admitted, racing])
    let completed = GatewayHostCallbackLifetime { revoked.add($0) }
    let background = UUID()
    try completed.register([background])
    completed.finish()
    completed.cancel()
    #expect(!revoked.ids.contains(background))
  }
  @Test func failedOrCancelledClaimKeepsProofsCancellationOwned() throws {
    let revoked = CallbackRevocations()
    let lifetime = GatewayHostCallbackLifetime { revoked.add($0) }
    let proof = UUID()
    try lifetime.register([proof])
    #expect(throws: CancellationError.self) {
      try lifetime.claim([proof]) { () throws -> Void in throw CancellationError() }
    }
    #expect(!lifetime.cancel())
    #expect(revoked.ids == [proof])
    #expect(throws: CancellationError.self) {
      try lifetime.claim([proof]) { Issue.record("Preparation ran after cancellation") }
    }
  }

  @Test func claimTransfersOnlyThePreparedProofs() throws {
    let revoked = CallbackRevocations()
    let lifetime = GatewayHostCallbackLifetime { revoked.add($0) }
    let claimed = UUID()
    let unrelated = UUID()
    try lifetime.register([claimed, unrelated])
    try lifetime.claim([claimed]) {}
    #expect(lifetime.cancel())
    #expect(revoked.ids == [unrelated])
    lifetime.finish()
    #expect(!lifetime.cancel())
    #expect(revoked.ids == [unrelated])
  }

  @Test(.timeLimit(.minutes(1)))
  func unclaimedWorkerIsCancelledAndJoinedBeforeChannelReturns() async throws {
    let revoked = CallbackRevocations()
    let lifetime = GatewayHostCallbackLifetime { revoked.add($0) }
    let started = CallbackTestGate()
    let cleaning = CallbackTestGate()
    let release = CallbackTestGate()
    let returned = CallbackRevocations()
    let proof = UUID()
    let request = Task {
      defer { returned.add([proof]) }
      return try await lifetime.run {
        try lifetime.register([proof])
        started.open()
        do { try await Task.sleep(for: .seconds(30)) } catch {
          cleaning.open()
          await release.wait()
          throw error
        }
        return 1
      }
    }
    await started.wait()
    request.cancel()
    await cleaning.wait()
    #expect(returned.ids.isEmpty)
    #expect(revoked.ids == [proof])
    release.open()
    await #expect(throws: CancellationError.self) { try await request.value }
    #expect(returned.ids == [proof])
  }

  @Test(.timeLimit(.minutes(1)))
  func claimedWorkerSurvivesChannelCancellationUntilActualCompletion() async throws {
    let revoked = CallbackRevocations()
    let ownership = GatewayOwnedWork()
    let lifetime = GatewayHostCallbackLifetime { revoked.add($0) }
    let claimed = CallbackTestGate()
    let release = CallbackTestGate()
    let completed = CallbackTestGate()
    let proof = UUID()
    let effects = CallbackRevocations()
    let request = Task {
      try await lifetime.run {
        let lease = try ownership.admitInvocation(
          projectID: "project", resourceID: "git.worktree_remove")
        defer { lease.finish() }
        try lifetime.register([proof])
        try lifetime.claim([proof]) { effects.add([proof]) }
        claimed.open()
        await release.wait()
        #expect(!Task.isCancelled)
        completed.open()
        return 1
      }
    }
    await claimed.wait()
    request.cancel()
    await #expect(throws: CancellationError.self) { try await request.value }
    #expect(revoked.ids.isEmpty)
    #expect(effects.ids == [proof])
    #expect(ownership.snapshot.count == 1)
    let joined = Task { await ownership.joinInvocations() }
    release.open()
    await completed.wait()
    await joined.value
    #expect(ownership.snapshot.isEmpty)
  }

  @Test func channelClosureCancelsInflightCallbacksAndRefusesNewCalls() async throws {
    let admission = MCPHostRequestAdmission()
    let started = AsyncStream<Void>.makeStream()
    let completed = CallbackRevocations()
    let callback = UUID()
    let request = Task {
      try await admission.perform {
        started.continuation.yield(())
        do {
          try await Task.sleep(for: .seconds(30))
        } catch {
          await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value
          completed.add([callback])
          throw error
        }
      }
    }
    var iterator = started.stream.makeAsyncIterator()
    _ = await iterator.next()
    await admission.close()
    #expect(completed.ids == [callback])
    do {
      try await request.value
      Issue.record("Closing the channel left its callback running")
    } catch is CancellationError {}
    await #expect(throws: (any Error).self) { try await admission.perform { 1 } }
  }
}

private final class CallbackRevocations: @unchecked Sendable {
  private let lock = NSLock()
  private var values: Set<UUID> = []
  var ids: Set<UUID> { lock.withLock { values } }
  func add(_ ids: Set<UUID>) { lock.withLock { values.formUnion(ids) } }
}

private final class CallbackTestGate: @unchecked Sendable {
  private let lock = NSLock()
  private var opened = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func open() {
    let pending = lock.withLock {
      opened = true
      defer { waiters.removeAll() }
      return waiters
    }
    for waiter in pending { waiter.resume() }
  }

  func wait() async {
    await withCheckedContinuation { continuation in
      let ready = lock.withLock {
        if opened { return true }
        waiters.append(continuation)
        return false
      }
      if ready { continuation.resume() }
    }
  }
}
