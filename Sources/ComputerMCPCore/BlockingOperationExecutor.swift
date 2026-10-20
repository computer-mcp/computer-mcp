import Foundation

/// Runs synchronous operations away from Swift's cooperative executor.
///
/// Callers remain responsible for exposing an asynchronous, cancellation-aware
/// API around the blocking operation.
package final class BlockingOperationExecutor: @unchecked Sendable {
  private let queue: DispatchQueue

  package init(label: String, serial: Bool = true) {
    queue = DispatchQueue(
      label: label,
      qos: .userInitiated,
      attributes: serial ? [] : .concurrent
    )
  }

  package func perform<Value: Sendable>(
    _ operation: @escaping @Sendable () throws -> Value
  ) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        do {
          continuation.resume(returning: try operation())
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
}
