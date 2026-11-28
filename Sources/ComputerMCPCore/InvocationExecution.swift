import Foundation

/// Host-created invocation state. Concrete execution policy belongs to the process
/// service; Core carries it across routing and blocking boundaries without widening it.
package protocol InvocationExecutionAuthority: Sendable {
  var pathAccess: (any HostPathAccessChecking)? { get }
}

package enum InvocationExecution {
  @TaskLocal package static var current: (any InvocationExecutionAuthority)?
}
