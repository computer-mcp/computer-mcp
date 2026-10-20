import Foundation

/// Host authorization for one downstream tool call, never supplied by tool arguments.
package struct InvocationAdmission: Sendable {
  package let reference: MCPToolReference
  package let risk: CapabilityRisk
  package let hostServiceAction: MCPHostServiceAction?
  package let hostInvocationID: UUID?

  package init?(descriptor: CapabilityDescriptor, hostInvocationID: UUID? = nil) {
    guard let reference = descriptor.mcpReference else { return nil }
    self.reference = reference
    risk = descriptor.risk
    hostServiceAction = descriptor.hostServiceAction
    self.hostInvocationID = hostInvocationID
  }
}

/// Host-selected routing evidence; the route does not confer authority.
package protocol ContinuationRoute: Sendable {}

package struct InvocationContext: Sendable {
  package let admission: InvocationAdmission?
  /// The live authority is retained so checks observe restriction and revocation.
  package let session: (any GatewaySessionAuthority)?
  package let continuation: (any ContinuationRoute)?

  package static let empty = InvocationContext()

  package init(
    admission: InvocationAdmission? = nil,
    session: (any GatewaySessionAuthority)? = nil,
    continuation: (any ContinuationRoute)? = nil
  ) {
    self.admission = admission
    self.session = session
    self.continuation = continuation
  }
}

package struct ToolInvocation: Sendable {
  package let name: String
  package let arguments: JSONValue?
  package let context: InvocationContext

  package init(name: String, arguments: JSONValue?, context: InvocationContext = .empty) {
    self.name = name
    self.arguments = arguments
    self.context = context
  }
}
