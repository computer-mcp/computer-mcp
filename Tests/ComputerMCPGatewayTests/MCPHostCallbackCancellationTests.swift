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
