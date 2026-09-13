import Foundation
import os

/// One awaited call owns its cancellation, including cancellation before SDK dispatch returns.
/// The installed action captures the native request identity, never a reusable gateway selector.
final class MCPCallCancellation: Sendable {
  private struct State {
    var cancelled = false
    var finished = false
    var action: (@Sendable () async -> Void)?
    var delivery: Task<Void, Never>?
  }
  private let state = OSAllocatedUnfairLock(initialState: State())

  func checkCancellation() throws {
    if state.withLock({ $0.cancelled }) { throw CancellationError() }
  }

  func install(
    onDeliveryFailure: @escaping @Sendable () -> Void,
    _ send: @escaping @Sendable () async throws -> Void
  ) {
    let action: @Sendable () async -> Void = {
      await withTaskGroup(of: Bool.self) { group in
        group.addTask {
          do {
            try await send()
            return true
          } catch { return false }
        }
        group.addTask {
          do { try await Task.sleep(for: .milliseconds(250)) } catch { return true }
          return false
        }
        if await group.next() == false { onDeliveryFailure() }
        group.cancelAll()
        // Failure retires the connection, unblocking a transport write that ignored cancellation.
        await group.waitForAll()
      }
    }
    state.withLock {
      guard !$0.finished else { return }
      if $0.cancelled {
        $0.delivery = Task { await action() }
      } else {
        $0.action = action
      }
    }
  }

  func cancel() {
    state.withLock {
      guard !$0.finished, !$0.cancelled else { return }
      $0.cancelled = true
      if let action = $0.action {
        $0.action = nil
        $0.delivery = Task { await action() }
      }
    }
  }

  func finish() async {
    let delivery = state.withLock {
      $0.finished = true
      $0.action = nil
      return $0.delivery
    }
    await delivery?.value
  }
}
