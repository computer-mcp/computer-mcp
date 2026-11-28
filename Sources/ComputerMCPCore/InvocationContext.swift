import Foundation

/// Host authorization for one downstream tool call, never supplied by tool arguments.
package struct InvocationAdmission: Sendable {
  package let reference: MCPToolReference
  package let risk: CapabilityRisk
  package let hostServiceAction: MCPHostServiceAction?
  package let hostInvocationID: UUID?
  /// Reserved durably before a lifecycle mutation is forwarded.
  package let hostOperationID: UUID?

  package init?(
    descriptor: CapabilityDescriptor, hostInvocationID: UUID? = nil, hostOperationID: UUID? = nil
  ) {
    guard let reference = descriptor.mcpReference else { return nil }
    self.reference = reference
    risk = descriptor.risk
    hostServiceAction = descriptor.hostServiceAction
    self.hostInvocationID = hostInvocationID
    self.hostOperationID = hostOperationID
  }
}

/// Host correlation forwarded to a callback-enabled registration. The IDs select
/// host records; they are not credentials.
package struct HostServiceDispatch: Sendable {
  package let invocationID: UUID
  package let operationID: UUID?
  package let action: MCPHostServiceAction?

  package init(invocationID: UUID, operationID: UUID?, action: MCPHostServiceAction?) {
    self.invocationID = invocationID
    self.operationID = operationID
    self.action = action
  }
}

/// Host-selected routing evidence; the route does not confer authority.
package protocol ContinuationRoute: Sendable {}

package struct InvocationContext: Sendable {
  package let resolvedInvocation: ResolvedToolInvocation?
  package let admission: InvocationAdmission?
  /// The live authority is retained so checks observe restriction and revocation.
  package let session: (any GatewaySessionAuthority)?
  package let continuation: (any ContinuationRoute)?
  package let executionAuthority: (any InvocationExecutionAuthority)?

  /// Host-local waiter cancellation; never part of a provider request.
  package let isDiscoveryCancelled: (@Sendable () -> Bool)?

  /// Host-selected durable authorization identity; nil permits only live result continuation.
  package let executionRecoveryKey: String?

  package static let empty = InvocationContext()

  package init(
    resolvedInvocation: ResolvedToolInvocation? = nil,
    admission: InvocationAdmission? = nil,
    session: (any GatewaySessionAuthority)? = nil,
    continuation: (any ContinuationRoute)? = nil,
    executionRecoveryKey: String? = nil,
    executionAuthority: (any InvocationExecutionAuthority)? = nil,
    isDiscoveryCancelled: (@Sendable () -> Bool)? = nil
  ) {
    self.resolvedInvocation = resolvedInvocation
    self.admission = admission
    self.session = session
    self.continuation = continuation
    self.executionRecoveryKey = executionRecoveryKey
    self.executionAuthority = executionAuthority
    self.isDiscoveryCancelled = isDiscoveryCancelled
  }
}

package struct ToolInvocation: Sendable {
  package let name: String
  package let arguments: JSONValue?
  package let context: InvocationContext

  package init(name: String, arguments: JSONValue?, context: InvocationContext) {
    self.name = name
    self.arguments = arguments
    self.context = context
  }
}
