import ComputerMCPSandbox
import Foundation

/// A deliberately selected launch context for local host administration. Provider
/// calls use durable PreparedExecutionContext authority instead.
package struct ExecutionAdministration: Sendable {
  package let mode: ExecutionMode
  package let environment: ExecutionEnvironment

  package init(mode: ExecutionMode, environment: ExecutionEnvironment) {
    self.mode = mode
    self.environment = environment
  }

  @TaskLocal package static var current: Self?
}
