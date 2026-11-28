import ComputerMCPCore
import Darwin

enum LocalCLIExecutionIdentity {
  enum Surface: String {
    case stdio
    case ownerTools = "owner-tools"
  }

  /// The local process owns this composition boundary. Reconnecting stdio clients
  /// retain their OS principal; offline owner inspection has a separate namespace.
  static func bind(_ context: ExecutionContext, surface: Surface) -> ExecutionContext {
    var context = context
    context.trustedPrincipalID = "computer-mcp.local.\(surface.rawValue):uid:\(geteuid())"
    return context
  }
}
