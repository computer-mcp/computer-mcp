import Foundation
import NIOConcurrencyHelpers

/// One awaited call owns its cancellation, including cancellation before SDK dispatch returns.
/// The installed action captures the native request identity, never a reusable gateway selector.
final class MCPCallCancellation: Sendable {
  private struct State {
    var cancelled = false
    var finished = false
    var action: (id: UUID, run: @Sendable () async -> Void)?
    var delivery: Task<Void, Never>?
  }
  private let state = NIOLockedValueBox(State())
  private let deliveryTimeout: Duration

  init(deliveryTimeout: Duration = .seconds(30)) {
    self.deliveryTimeout = deliveryTimeout
  }

  func checkCancellation() throws {
    try whileActive {}
  }

  func whileActive<Result>(_ operation: () throws -> Result) throws -> Result {
    try state.withLockedValue {
      if $0.cancelled { throw CancellationError() }
      return try operation()
    }
  }

  @discardableResult
  func install(
    onDeliveryFailure: (@Sendable () -> Void)?,
    _ send: @escaping @Sendable () async throws -> Void
  ) -> UUID {
    let id = UUID()
    let action: @Sendable () async -> Void = { [deliveryTimeout] in
      await Self.deliver(within: deliveryTimeout, onDeliveryFailure: onDeliveryFailure, send)
    }
    state.withLockedValue {
      guard !$0.finished, $0.delivery == nil else { return }
      if $0.cancelled {
        $0.delivery = Task { await action() }
      } else {
        $0.action = (id, action)
      }
    }
    return id
  }

  func clear(_ id: UUID) {
    state.withLockedValue {
      if $0.action?.id == id { $0.action = nil }
    }
  }

  static func deliver(
    within timeout: Duration, onDeliveryFailure: (@Sendable () -> Void)?,
    _ send: @escaping @Sendable () async throws -> Void
  ) async {
    let (outcomes, outcome) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let writer = Task {
      do {
        try await send()
        outcome.yield(true)
      } catch { outcome.yield(false) }
    }
    let deadline = Task {
      do {
        try await Task.sleep(for: timeout)
        outcome.yield(false)
      } catch {}
    }
    for await delivered in outcomes {
      if !delivered { onDeliveryFailure?() }
      break
    }
    outcome.finish()
    deadline.cancel()
    writer.cancel()
    // Advisory delivery may have reached transport-owned frame I/O. The connection
    // keeps that frame indivisible and the caller can leave at the delivery deadline.
    if onDeliveryFailure != nil { await writer.value }
  }

  func cancel() {
    state.withLockedValue {
      guard !$0.finished, !$0.cancelled else { return }
      $0.cancelled = true
      if let action = $0.action {
        $0.action = nil
        $0.delivery = Task { await action.run() }
      }
    }
  }

  func finish() async {
    let delivery = state.withLockedValue {
      $0.finished = true
      $0.action = nil
      return $0.delivery
    }
    await delivery?.value
  }
}
