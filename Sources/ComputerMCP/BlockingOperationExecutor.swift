import Foundation

/// Runs synchronous system APIs away from Swift's cooperative executor.
///
/// This is intentionally internal. Callers remain responsible for exposing an
/// asynchronous, cancellation-aware caller API around the blocking operation.
final class BlockingOperationExecutor: @unchecked Sendable {
  private let queue: DispatchQueue

  init(label: String, serial: Bool = true) {
    queue = DispatchQueue(
      label: label,
      qos: .userInitiated,
      attributes: serial ? [] : .concurrent
    )
  }

  func perform<Value: Sendable>(
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
