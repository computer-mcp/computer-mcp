import ComputerMCPSandbox

internal struct HostExecutionSetup: Sendable {
  let mode: ExecutionMode
  let environment: ExecutionEnvironment

  static func prepare() throws -> Self {
    if let prepared = try PreparedExecutionContext.current() {
      return Self(
        mode: prepared.mode,
        environment: try HostCommandEnvironment.applying(to: prepared.environment))
    }
    guard let administration = ExecutionAdministration.current else {
      throw ExecutionEnvironmentError.unavailable("No authorized execution context is installed")
    }
    return Self(
      mode: administration.mode,
      environment: try HostCommandEnvironment.applying(to: administration.environment))
  }
}

/// Opaque host authorization identity, captured at the admitted provider call boundary.
package enum ExecutionRecovery {
  @TaskLocal package static var key: String?
}

/// Only fixed host helper APIs install this complete environment. Tool environment
/// arguments use the prepared launch environment and cannot install this scope.
package enum HostCommandEnvironment {
  @TaskLocal package static var current: [String: String]?
  static func applying(to environment: ExecutionEnvironment) throws -> ExecutionEnvironment {
    try current.map { try environment.forHostHelper(variables: $0) } ?? environment
  }
}
