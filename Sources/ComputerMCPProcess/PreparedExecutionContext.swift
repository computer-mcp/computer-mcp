import ComputerMCPCore
import ComputerMCPPermissions
import ComputerMCPSandbox
import Foundation
import NIOConcurrencyHelpers

/// The authority owns durable reservation and completion. Ownership callbacks must
/// only install handlers; the bootstrap invokes persistence before releasing code.
package protocol ExecutionAuthorizing: Sendable {
  var executionID: UUID { get }
  var authorizationIDs: Set<UUID> { get }
  func reserveChild(_ id: UUID) throws
  func bindChild(_ id: UUID, ownership: any ExecutionOwnership)
  func launchFailed(_ id: UUID)
  func finishAdmission() throws
  func access(_ executionID: UUID, operation: ExecutionOperation) throws -> EffectiveExecutionLimits
}

package protocol ExecutionAccessChecking: InvocationExecutionAuthority {
  func accessExecution(_ id: UUID, operation: ExecutionOperation) throws -> EffectiveExecutionLimits
}

package protocol ExecutionRecoveryAuthorizing: Sendable {
  func recoveredExecution(_ id: UUID) throws -> EffectiveExecutionLimits?
  func observeExecutionLimits(
    _ id: UUID, _ observer: @escaping @Sendable (EffectiveExecutionLimits) -> Void) throws
}

/// One logical execution may start several host helpers or background children.
/// Its immutable launch policy takes precedence over provider risk classifications.
package final class PreparedExecutionContext: ExecutionAccessChecking, Sendable {
  package let authority: any ExecutionAuthorizing
  package let mode: ComputerMCPSandbox.ExecutionMode
  package let environment: ExecutionEnvironment
  package let pathAccess: (any HostPathAccessChecking)?
  private struct State: Sendable {
    var limits: EffectiveExecutionLimits
    var endReason: ExecutionLimitEndReason?
    var observers: [@Sendable (EffectiveExecutionLimits) -> Void] = []
  }
  private let state: NIOLockedValueBox<State>

  package init(
    authority: any ExecutionAuthorizing, mode: ComputerMCPSandbox.ExecutionMode,
    environment: ExecutionEnvironment,
    limits: EffectiveExecutionLimits, pathAccess: (any HostPathAccessChecking)? = nil
  ) {
    self.authority = authority
    self.mode = mode
    self.environment = environment
    self.pathAccess = pathAccess
    state = .init(State(limits: limits))
  }

  package var executionID: UUID { authority.executionID }
  package var limits: EffectiveExecutionLimits { state.withLockedValue { $0.limits } }
  package var limitEndReason: ExecutionLimitEndReason? { state.withLockedValue { $0.endReason } }

  package static func current() throws -> PreparedExecutionContext? {
    guard let scope = InvocationExecution.current else { return nil }
    guard let prepared = scope as? PreparedExecutionContext else {
      throw ExecutionEnvironmentError.unavailable(
        "Execution authority has no prepared launch context")
    }
    return prepared
  }

  package func withValue<Value>(_ body: () throws -> Value) rethrows -> Value {
    try InvocationExecution.$current.withValue(self) {
      try HostPathAccess.$current.withValue(pathAccess, operation: body)
    }
  }

  package func withValue<Value: Sendable>(_ body: @Sendable () async throws -> Value) async rethrows
    -> Value
  {
    try await InvocationExecution.$current.withValue(self) {
      try await HostPathAccess.$current.withValue(pathAccess) { try await body() }
    }
  }

  package func accessExecution(_ id: UUID, operation: ExecutionOperation) throws
    -> EffectiveExecutionLimits
  {
    try authority.access(id, operation: operation)
  }

  package func finishAdmission() throws { try authority.finishAdmission() }

  package func observeLimits(_ observer: @escaping @Sendable (EffectiveExecutionLimits) -> Void) {
    let limits = state.withLockedValue {
      $0.observers.append(observer)
      return $0.limits
    }
    observer(limits)
  }

  package func applyLimits(
    _ limits: EffectiveExecutionLimits, endReason: ExecutionLimitEndReason? = nil
  ) {
    let delivery = state.withLockedValue {
      $0.endReason = $0.endReason ?? endReason
      let applied = limits.tightening($0.limits)
      guard $0.limits != applied else {
        return (applied, [@Sendable (EffectiveExecutionLimits) -> Void]())
      }
      $0.limits = applied
      return (applied, $0.observers)
    }
    for observer in delivery.1 { observer(delivery.0) }
  }
}
