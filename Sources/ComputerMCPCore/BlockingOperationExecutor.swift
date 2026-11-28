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
    let authority = InvocationExecution.current
    let pathAccess = HostPathAccess.current ?? authority?.pathAccess
    return try await withCheckedThrowingContinuation { continuation in
      queue.async {
        do {
          let result = try InvocationExecution.$current.withValue(authority) {
            try HostPathAccess.$current.withValue(pathAccess, operation: operation)
          }
          continuation.resume(returning: result)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
}
